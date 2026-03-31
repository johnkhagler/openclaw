import { describe, expect, it, vi } from "vitest";

const loadSessionsMock = vi.fn();
const setLastActiveSessionKeyMock = vi.fn();

vi.mock("./app-chat.ts", () => ({
  CHAT_SESSIONS_ACTIVE_MINUTES: 10,
  flushChatQueueForEvent: vi.fn(),
}));
vi.mock("./app-settings.ts", () => ({
  applySettings: vi.fn(),
  loadCron: vi.fn(),
  refreshActiveTab: vi.fn(),
  setLastActiveSessionKey: setLastActiveSessionKeyMock,
}));
vi.mock("./app-tool-stream.ts", () => ({
  handleAgentEvent: vi.fn(),
  resetToolStream: vi.fn(),
}));
vi.mock("./controllers/agents.ts", () => ({
  loadAgents: vi.fn(),
  loadToolsCatalog: vi.fn(),
}));
vi.mock("./controllers/assistant-identity.ts", () => ({
  loadAssistantIdentity: vi.fn(),
}));
vi.mock("./controllers/chat.ts", () => ({
  loadChatHistory: vi.fn(),
  handleChatEvent: vi.fn(() => "idle"),
}));
vi.mock("./controllers/devices.ts", () => ({
  loadDevices: vi.fn(),
}));
vi.mock("./controllers/exec-approval.ts", () => ({
  addExecApproval: vi.fn(),
  parseExecApprovalRequested: vi.fn(() => null),
  parseExecApprovalResolved: vi.fn(() => null),
  removeExecApproval: vi.fn(),
}));
vi.mock("./controllers/nodes.ts", () => ({
  loadNodes: vi.fn(),
}));
vi.mock("./controllers/sessions.ts", () => ({
  loadSessions: loadSessionsMock,
  subscribeSessions: vi.fn(),
}));
vi.mock("./gateway.ts", () => ({
  GatewayBrowserClient: class {},
  resolveGatewayErrorDetailCode: () => null,
}));

const { handleGatewayEvent } = await import("./app-gateway.ts");

function createHost() {
  return {
    settings: {
      gatewayUrl: "ws://127.0.0.1:18789",
      token: "",
      sessionKey: "main",
      lastActiveSessionKey: "main",
      theme: "claw",
      themeMode: "system",
      chatFocusMode: false,
      chatShowThinking: true,
      chatShowToolCalls: true,
      splitRatio: 0.6,
      navCollapsed: false,
      navWidth: 280,
      navGroupsCollapsed: {},
      borderRadius: 50,
    },
    password: "",
    clientInstanceId: "instance-test",
    client: null,
    connected: true,
    hello: null,
    lastError: null,
    lastErrorCode: null,
    eventLogBuffer: [],
    eventLog: [],
    tab: "overview",
    presenceEntries: [],
    presenceError: null,
    presenceStatus: null,
    agentsLoading: false,
    agentsList: null,
    agentsError: null,
    healthLoading: false,
    healthResult: null,
    healthError: null,
    toolsCatalogLoading: false,
    toolsCatalogError: null,
    toolsCatalogResult: null,
    debugHealth: null,
    assistantName: "OpenClaw",
    assistantAvatar: null,
    assistantAgentId: null,
    serverVersion: null,
    sessionKey: "main",
    chatRunId: null,
    refreshSessionsAfterChat: new Set<string>(),
    execApprovalQueue: [],
    execApprovalError: null,
    updateAvailable: null,
  } as unknown as Parameters<typeof handleGatewayEvent>[0];
}

describe("handleGatewayEvent sessions.changed", () => {
  it("reloads sessions when the gateway pushes a sessions.changed event", () => {
    loadSessionsMock.mockReset();
    const host = createHost();

    handleGatewayEvent(host, {
      type: "event",
      event: "sessions.changed",
      payload: { sessionKey: "agent:main:main", reason: "patch" },
      seq: 1,
    });

    expect(loadSessionsMock).toHaveBeenCalledTimes(1);
    expect(loadSessionsMock).toHaveBeenCalledWith(host);
  });
});

describe("handleGatewayEvent chat last-active session behavior", () => {
  it("ignores heartbeat chat session keys when updating last active session", () => {
    loadSessionsMock.mockReset();
    setLastActiveSessionKeyMock.mockReset();
    const host = createHost();

    handleGatewayEvent(host, {
      type: "event",
      event: "chat",
      payload: {
        runId: "hb-run-1",
        sessionKey: "agent:main:heartbeat",
        state: "final",
      },
      seq: 2,
    });

    expect(setLastActiveSessionKeyMock).not.toHaveBeenCalled();
  });

  it("updates last active session for non-heartbeat chat session keys", () => {
    loadSessionsMock.mockReset();
    setLastActiveSessionKeyMock.mockReset();
    const host = createHost();

    handleGatewayEvent(host, {
      type: "event",
      event: "chat",
      payload: {
        runId: "proj-run-1",
        sessionKey: "agent:main:project-alpha",
        state: "final",
      },
      seq: 3,
    });

    expect(setLastActiveSessionKeyMock).toHaveBeenCalledTimes(1);
    expect(setLastActiveSessionKeyMock).toHaveBeenCalledWith(host, "agent:main:project-alpha");
  });

  it("does not treat non-heartbeat scopes containing heartbeat as heartbeat sessions", () => {
    loadSessionsMock.mockReset();
    setLastActiveSessionKeyMock.mockReset();
    const host = createHost();

    handleGatewayEvent(host, {
      type: "event",
      event: "chat",
      payload: {
        runId: "proj-run-2",
        sessionKey: "agent:main:project-heartbeat-review",
        state: "final",
      },
      seq: 4,
    });

    expect(setLastActiveSessionKeyMock).toHaveBeenCalledTimes(1);
    expect(setLastActiveSessionKeyMock).toHaveBeenCalledWith(
      host,
      "agent:main:project-heartbeat-review",
    );
  });
});
