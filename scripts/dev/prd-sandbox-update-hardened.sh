#!/usr/bin/env bash
set -euo pipefail

GATEWAY_NAME="nemoclaw"
SANDBOX_NAME="nemo-openclaw-local"
FORWARD_PORT="18789"
TARGET_ENV="PRD"
TARBALL_PATH=""

TS="$(date -u +%Y%m%d-%H%M%S)"
LOG_FILE="/tmp/openclaw-prd-update-${TS}.log"
POLICY_BACKUP_FILE=""
RESTORE_POLICY_FILE=""
TEMP_POLICY_FILE=""
INSTALL_DEST=""
INSTALL_ARTIFACT=""
INSTALL_LOG=""
TEMP_POLICY_APPLIED="0"

usage() {
  cat <<'EOF'
Usage: scripts/dev/prd-sandbox-update-hardened.sh [options]

Options:
  --tarball <path>     Path to openclaw-*.tgz (default: latest in repo root)
  --gateway <name>     OpenShell gateway name (default: nemoclaw)
  --sandbox <name>     Sandbox name (default: nemo-openclaw-local)
  --port <port>        Forward/gateway port (default: 18789)
  -h, --help           Show this help

This script enforces the PRD runbook gates and writes evidence to:
  /tmp/openclaw-prd-update-<timestamp>.log
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tarball)
      TARBALL_PATH="${2:-}"
      shift 2
      ;;
    --gateway)
      GATEWAY_NAME="${2:-}"
      shift 2
      ;;
    --sandbox)
      SANDBOX_NAME="${2:-}"
      shift 2
      ;;
    --port)
      FORWARD_PORT="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$TARBALL_PATH" ]]; then
  TARBALL_PATH="$(ls -1t openclaw-*.tgz 2>/dev/null | head -n 1 || true)"
fi

if [[ -z "$TARBALL_PATH" ]]; then
  echo "No tarball found. Pass --tarball <path>." >&2
  exit 2
fi

if [[ ! -f "$TARBALL_PATH" ]]; then
  echo "Tarball not found: $TARBALL_PATH" >&2
  exit 2
fi

TARBALL_PATH="$(cd "$(dirname "$TARBALL_PATH")" && pwd)/$(basename "$TARBALL_PATH")"
TARBALL_BASENAME="$(basename "$TARBALL_PATH")"

mkdir -p /tmp/policy-backups

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG_FILE"
}

run() {
  log "+ $*"
  "$@" 2>&1 | tee -a "$LOG_FILE"
}

run_ssh() {
  local cmd="$1"
  run ssh \
    -o ProxyCommand="openshell ssh-proxy --gateway-name ${GATEWAY_NAME} --name ${SANDBOX_NAME}" \
    "sandbox@openshell-${SANDBOX_NAME}" \
    "$cmd"
}

rollback_policy_if_needed() {
  if [[ "$TEMP_POLICY_APPLIED" == "1" && -n "$POLICY_BACKUP_FILE" ]]; then
    log "Stop-loss: restoring baseline policy from backup"
    RESTORE_POLICY_FILE="/tmp/policy-backups/${SANDBOX_NAME}-policy-restored-${TS}.yaml"
    awk 'f{print} /^---$/{f=1}' "$POLICY_BACKUP_FILE" > "$RESTORE_POLICY_FILE"
    run openshell policy set -g "$GATEWAY_NAME" "$SANDBOX_NAME" --policy "$RESTORE_POLICY_FILE" --wait || true
  fi
}

on_error() {
  local line="$1"
  local code="$2"
  log "ERROR at line ${line} (exit ${code})"
  rollback_policy_if_needed
  log "FAILED. Evidence log: ${LOG_FILE}"
}

trap 'on_error "$LINENO" "$?"' ERR

log "Gate 0 declaration"
log "target_environment=${TARGET_ENV}"
log "gateway=${GATEWAY_NAME} sandbox=${SANDBOX_NAME} port=${FORWARD_PORT}"
log "tarball=${TARBALL_PATH}"
log "runbook=/memories/repo/runbook-openclaw-sandbox-update.md"

log "Gate 1 preflight"
if ! tar tzf "$TARBALL_PATH" | awk '
  /package\/dist\/control-ui\/index.html/ { found=1 }
  END { exit(found ? 0 : 1) }
'; then
  log "Artifact gate failed: control-ui asset missing in tarball"
  exit 1
fi
log "Artifact gate passed"

run openshell sandbox list -g "$GATEWAY_NAME"
run openshell policy list -g "$GATEWAY_NAME" "$SANDBOX_NAME"

POLICY_BACKUP_FILE="/tmp/policy-backups/${SANDBOX_NAME}-policy-before-npm-${TS}.yaml"
run sh -c "openshell policy get -g '$GATEWAY_NAME' '$SANDBOX_NAME' --full > '$POLICY_BACKUP_FILE'"
log "policy_backup=${POLICY_BACKUP_FILE}"

run_ssh 'echo SSH_OK && command -v ss || true && command -v npm || true && command -v node || true && command -v pkill || true && command -v ps || true && command -v fuser || true'

TEMP_POLICY_FILE="/tmp/policy-backups/${SANDBOX_NAME}-policy-temp-npm-${TS}.yaml"
awk 'f{print} /^---$/{f=1}' "$POLICY_BACKUP_FILE" > "$TEMP_POLICY_FILE"
cat >> "$TEMP_POLICY_FILE" <<'YAML'
  npm_registry_temp:
    name: npm-registry-temp
    endpoints:
    - host: registry.npmjs.org
      port: 443
    - host: "*.npmjs.org"
      port: 443
    binaries:
    - path: /usr/local/bin/node
    - path: /usr/local/bin/npm
YAML

run openshell policy set -g "$GATEWAY_NAME" "$SANDBOX_NAME" --policy "$TEMP_POLICY_FILE" --wait
TEMP_POLICY_APPLIED="1"
run sh -c "openshell policy get -g '$GATEWAY_NAME' '$SANDBOX_NAME' --full | grep -n 'npm_registry_temp\\|npmjs.org\\|/usr/local/bin/npm'"

log "Gate 3 install branch"
INSTALL_DEST="/tmp/openclaw-upload-${TS}"
run openshell sandbox upload -g "$GATEWAY_NAME" "$SANDBOX_NAME" "$TARBALL_PATH" "$INSTALL_DEST"
INSTALL_ARTIFACT="${INSTALL_DEST}/${TARBALL_BASENAME}"
log "install_artifact=${INSTALL_ARTIFACT}"

INSTALL_LOG="/tmp/openclaw-npm-install-${TS}.log"
run_ssh "PREFIX=\$(npm config get prefix 2>/dev/null || true); nohup npm install -g --ignore-scripts '${INSTALL_ARTIFACT}' > '${INSTALL_LOG}' 2>&1 < /dev/null & echo NPM_PREFIX=\$PREFIX; echo INSTALL_LOG='${INSTALL_LOG}'"

attempt="0"
until run_ssh "npm ls -g --depth=0 openclaw >/tmp/openclaw-npm-ls-${TS}.txt 2>&1 && cat /tmp/openclaw-npm-ls-${TS}.txt"; do
  attempt="$((attempt + 1))"
  if [[ "$attempt" -ge 30 ]]; then
    run_ssh "tail -n 120 '${INSTALL_LOG}'"
    log "Install verification timed out"
    exit 1
  fi
  sleep 2
done
run_ssh "tail -n 80 '${INSTALL_LOG}'"

log "Restore baseline policy"
RESTORE_POLICY_FILE="/tmp/policy-backups/${SANDBOX_NAME}-policy-restored-${TS}.yaml"
awk 'f{print} /^---$/{f=1}' "$POLICY_BACKUP_FILE" > "$RESTORE_POLICY_FILE"
run openshell policy set -g "$GATEWAY_NAME" "$SANDBOX_NAME" --policy "$RESTORE_POLICY_FILE" --wait
TEMP_POLICY_APPLIED="0"
run openshell policy list -g "$GATEWAY_NAME" "$SANDBOX_NAME"

log "Gate 3 restart branch"
run_ssh "PID=\$(ss -ltnp | sed -n 's/.*pid=\\([0-9][0-9]*\\).*/\\1/p' | head -n 1); echo PREV_PID=\$PID; if [[ -n \"\$PID\" ]]; then kill -9 \"\$PID\" || true; fi; sleep 1; : > /tmp/openclaw-gateway.log; nohup env OPENCLAW_STATE_DIR=/sandbox/.openclaw-data /usr/local/bin/openclaw gateway run --bind loopback --port '${FORWARD_PORT}' > /tmp/openclaw-gateway.log 2>&1 < /dev/null & sleep 3; ss -ltnp | grep '${FORWARD_PORT}' || true; tail -n 120 /tmp/openclaw-gateway.log"

log "Gate 3 forward branch"
if ! run sh -c "openshell forward list | grep -q '${SANDBOX_NAME}.*${FORWARD_PORT}.*running'"; then
  run openshell forward stop "$FORWARD_PORT" "$SANDBOX_NAME" || true
  run openshell forward start --background "$FORWARD_PORT" "$SANDBOX_NAME"
fi
run openshell forward list

log "Gate 4 acceptance"
http_ok="0"
for attempt in 1 2 3 4 5; do
  log "HTTP acceptance attempt ${attempt}/5"
  set +e
  HTTP_HEADERS="$(curl -sS -m 10 -D - -o /dev/null "http://127.0.0.1:${FORWARD_PORT}/")"
  CURL_STATUS="$?"
  set -e
  printf '%s\n' "$HTTP_HEADERS" | head -n 12 | tee -a "$LOG_FILE"
  if [[ "$CURL_STATUS" -eq 0 ]] && printf '%s\n' "$HTTP_HEADERS" | grep -q '^HTTP/1.1 200'; then
    http_ok="1"
    break
  fi
  sleep 2
done

if [[ "$http_ok" != "1" ]]; then
  log "HTTP acceptance failed: did not observe HTTP/1.1 200 after retries"
  exit 1
fi

run pnpm openclaw channels status --probe
run pnpm openclaw models list

log "SUCCESS"
log "evidence_log=${LOG_FILE}"
