import { NextRequest } from "next/server";
import { spawn } from "node:child_process";
import { createSdkMcpServer, query, tool } from "@anthropic-ai/claude-agent-sdk";
import { z } from "zod";
import { getUserFromRequest, unauthorizedJson } from "@/server/auth";
import { resolveBrowserConnection } from "@/server/browser";
import {
  addTaskRunTokenUsage,
  appendMessage,
  appendTaskEvent,
  createCredentialRequest,
  createTaskRun,
  expireCredentialRequest,
  getAgent,
  getBrowserSettings,
  getCredentialRequest,
  getTaskRunSnapshot,
  recordDecisionMemorySignal,
  listMessages,
  truncateMessagesFrom,
  updateMessage,
  updateTaskRunStatus,
} from "@/server/db";
import { capabilitiesToTools } from "@/server/agent-runtime/capabilities";
import { persistToolResultArtifacts } from "@/server/task-artifacts";
import {
  buildWebMcpRuntimeContext,
  createWebMcpRecordingState,
  recordWebMcpToolResult,
} from "@/server/web-mcp/recording";
import {
  appendUserMemoryNote,
  buildIdentityRuntimeContext,
  extractAndPersistMemoryNotes,
} from "@/server/identity/storage";
import { extractAndPersistWebMemoryNotes } from "@/server/web-mcp/storage";
import type {
  Agent,
  BrowserConnection,
  Capability,
  CredentialRequest,
  TaskArtifact,
  TaskEvent,
  TaskRunSnapshot,
  TaskRunStatus,
  TokenUsage,
  DecisionMemory,
  ToolTraceEntry,
  User,
  UserRuntimeMetadata,
} from "@/shared/types";
import { getModelProvider } from "@/shared/types";

export const runtime = "nodejs";

type Ctx = { params: Promise<{ id: string }> };
type AgentRunResult = { content: string; toolTrace: ToolTraceEntry[] };
type AgentRunFailure = AgentRunResult & { message: string; partialContent: string };
class AgentRunError extends Error {
  partialContent: string;
  toolTrace: ToolTraceEntry[];

  constructor(message: string, result: AgentRunResult) {
    super(message);
    this.name = "AgentRunError";
    this.partialContent = result.content;
    this.toolTrace = result.toolTrace;
  }
}
type ToolEvent =
  | { phase: "call"; id: string; name: string; input: unknown; startedAt: number }
  | {
      phase: "result";
      id: string;
      result: unknown;
      artifacts?: TaskArtifact[];
      isError?: boolean;
      completedAt: number;
    };
type TaskStreamEvent =
  | { type: "snapshot"; taskRun: TaskRunSnapshot }
  | { type: "event"; event: TaskEvent }
  | { type: "artifacts"; artifacts: TaskArtifact[]; events: TaskEvent[] };
type TaskTraceRuntime = ReturnType<typeof createTaskTraceRuntime>;

export async function GET(req: NextRequest, ctx: Ctx) {
  const user = getUserFromRequest(req);
  if (!user) return unauthorizedJson();

  const { id } = await ctx.params;
  if (!getAgent(id, user.id)) {
    return Response.json({ error: "agent_not_found" }, { status: 404 });
  }
  return Response.json(listMessages(id, user.id));
}

export async function POST(req: NextRequest, ctx: Ctx) {
  const user = getUserFromRequest(req);
  if (!user) return unauthorizedJson();

  const { id } = await ctx.params;
  const agent = getAgent(id, user.id);
  if (!agent) return Response.json({ error: "agent_not_found" }, { status: 404 });

  const { message, runtimeMetadata } = (await req.json()) as {
    message: string;
    runtimeMetadata?: UserRuntimeMetadata;
  };
  if (!message?.trim()) return Response.json({ error: "empty_message" }, { status: 400 });
  const userRuntimeMetadata = normalizeUserRuntimeMetadata(runtimeMetadata, req);
  const decisionMemory = recordDecisionMemorySignal({ userId: user.id, message });

  appendMessage(id, user.id, "user", message);

  const history = listMessages(id, user.id);
  const conversation = history
    .map((m) => `${m.role === "user" ? "User" : "Assistant"}: ${m.content}`)
    .join("\n\n");
  const priorConversation = history
    .slice(0, -1)
    .map((m) => `${m.role === "user" ? "User" : "Assistant"}: ${m.content}`)
    .join("\n\n");
  const browserConnection = resolveBrowserConnection(getBrowserSettings(user.id));
  const provider = getModelProvider(agent.model);
  const runtimeContext = buildRuntimeContext(
    agent,
    user,
    browserConnection,
    userRuntimeMetadata,
    decisionMemory,
    provider,
  );
  const taskRun = createTaskRun({
    agentId: id,
    userId: user.id,
    title: buildTaskTitle(message),
    input: message,
    provider,
    browserSource: browserConnection.source,
  });
  const assistantMessage = appendMessage(id, user.id, "assistant", "Задача выполняется...", {
    taskRunId: taskRun.id,
  });

  const encoder = new TextEncoder();
  const stream = new ReadableStream({
    async start(controller) {
      let clientOpen = true;
      let streamedContent = "";
      let lastPersistedAt = 0;
      let lastPersistedLength = 0;

      const persistAssistant = (
        content: string,
        metadata?: { toolTrace?: ToolTraceEntry[]; taskRunId?: string },
        force = false,
      ) => {
        if (!content.trim()) return;

        const now = Date.now();
        if (
          !force &&
          now - lastPersistedAt < 750 &&
          content.length - lastPersistedLength < 500
        ) {
          return;
        }

        updateMessage(id, user.id, assistantMessage.id, "assistant", content, {
          taskRunId: taskRun.id,
          ...metadata,
        });
        lastPersistedAt = now;
        lastPersistedLength = content.length;
      };

      const send = (event: string, data: unknown) => {
        if (event === "delta" && isRecord(data) && typeof data.text === "string") {
          streamedContent += data.text;
          persistAssistant(streamedContent);
        } else if (event === "replace" && isRecord(data) && typeof data.text === "string") {
          streamedContent = data.text;
          persistAssistant(streamedContent, undefined, true);
        }

        if (!clientOpen) return;

        try {
          controller.enqueue(encoder.encode(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`));
        } catch {
          clientOpen = false;
        }
      };
      const taskTrace = createTaskTraceRuntime({
        taskRunId: taskRun.id,
        userId: user.id,
        send,
      });

      const abortSignal = req.signal;

      let result: AgentRunResult = { content: "", toolTrace: [] };
      try {
        taskTrace.sendSnapshot();
        taskTrace.setStatus("planning", "Задача принята", {
          provider,
          browserSource: browserConnection.source,
          userRuntime: userRuntimeMetadata,
        });

        if (provider === "codex") {
          result = await streamCodexReply({
            agent,
            priorConversation,
            latestUserMessage: message,
            runtimeContext,
            browserConnection,
            taskTrace,
            send,
            abortSignal,
          });
        } else {
          result = await streamClaudeReply({
            agent,
            conversation,
            runtimeContext,
            browserConnection,
            taskTrace,
            send,
            abortSignal,
          });
        }

        if (abortSignal.aborted) {
          taskTrace.setStatus("cancelled", "Задача остановлена пользователем", {}, Date.now());
        } else if (shouldRetryBrowserAutonomyHandoff(result, agent, browserConnection, message)) {
          taskTrace.addEvent({
            taskRunId: taskTrace.taskRunId,
            userId: taskTrace.userId,
            kind: "message",
            title: "Повтор: агент попросил пользователя открыть браузерную вкладку",
            details: {
              reason: "browser_autonomy_handoff",
            },
          });
          send("replace", { text: "" });

          const retryConversation = buildBrowserAutonomyRetryConversation(conversation, result.content);
          const retryResult = provider === "codex"
            ? await streamCodexReply({
                agent,
                priorConversation: [conversation, `Assistant: ${result.content}`].join("\n\n"),
                latestUserMessage: BROWSER_AUTONOMY_RETRY_INSTRUCTION,
                runtimeContext,
                browserConnection,
                taskTrace,
                send,
                abortSignal,
              })
            : await streamClaudeReply({
                agent,
                conversation: retryConversation,
                runtimeContext,
                browserConnection,
                taskTrace,
                send,
                abortSignal,
              });

          result = {
            content: retryResult.content,
            toolTrace: [...result.toolTrace, ...retryResult.toolTrace],
          };
        }

        if (!abortSignal.aborted && shouldRunCredentialBrokerFallback(result, agent, browserConnection)) {
          const credentialRequest = inferCredentialFallbackRequest({
            agent,
            browserConnection,
            taskTrace,
            userMessage: message,
            result,
          });

          if (credentialRequest) {
            const retryResult = await runCredentialBrokerFallback({
              agent,
              provider,
              conversation,
              runtimeContext,
              browserConnection,
              taskTrace,
              send,
              abortSignal,
              request: credentialRequest,
              blockedContent: result.content,
            });

            if (retryResult) {
              result = {
                content: retryResult.content,
                toolTrace: [...result.toolTrace, ...retryResult.toolTrace],
              };
            }
          }
        }

        if (!abortSignal.aborted) {
          taskTrace.setStatus("done", "Задача завершена", {
            toolCalls: result.toolTrace.length,
          }, Date.now());
        }
      } catch (err) {
        const failure = normalizeAgentRunFailure(err, result);
        const errMsg = failure.message;
        taskTrace.setStatus("failed", "Задача упала", { message: errMsg }, Date.now());
        result = {
          content: buildFailureResult({
            message,
            errMsg,
            partialContent: failure.partialContent,
            toolTrace: failure.toolTrace,
            agent,
            browserConnection,
          }),
          toolTrace: failure.toolTrace,
        };
        send("replace", { text: result.content });
        send("done", {});
      } finally {
        if (result.content) {
          const persisted = extractAndPersistMemoryNotes(user, agent, result.content);
          const webMemory = extractAndPersistWebMemoryNotes(user.id, persisted.cleanedContent);
          for (const note of webMemory.commonNotes) {
            try {
              appendUserMemoryNote(user, `[Web MCP common] ${note}`);
            } catch (error) {
              console.warn("identity: failed to mirror Web MCP common memory", error);
            }
          }
          const memoryUpdated =
            persisted.selfNotes.length > 0 ||
            persisted.userNotes.length > 0 ||
            webMemory.commonNotes.length > 0 ||
            webMemory.siteNotes.length > 0;
          const cleanedContent = memoryUpdated && !webMemory.cleanedContent.trim()
            ? "Запомнил."
            : webMemory.cleanedContent;
          const contentChanged = cleanedContent !== result.content;
          if (contentChanged) {
            send("replace", { text: cleanedContent });
          }
          if (memoryUpdated) {
            taskTrace.addEvent({
              taskRunId: taskTrace.taskRunId,
              userId: taskTrace.userId,
              kind: "message",
              title: "Memory updated",
              details: {
                selfNotes: persisted.selfNotes.length,
                userNotes: persisted.userNotes.length,
                webCommonNotes: webMemory.commonNotes.length,
                webSiteNotes: webMemory.siteNotes.length,
              },
            });
          }
          result = { ...result, content: cleanedContent || result.content };
          updateMessage(id, user.id, assistantMessage.id, "assistant", result.content, {
            toolTrace: result.toolTrace,
            taskRunId: taskRun.id,
          });
        }
        if (clientOpen) {
          try {
            controller.close();
          } catch {
            clientOpen = false;
          }
        }
      }
    },
  });

  return new Response(stream, {
    headers: {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache, no-transform",
      "X-Accel-Buffering": "no",
    },
  });
}

function createTaskTraceRuntime({
  taskRunId,
  userId,
  send,
}: {
  taskRunId: string;
  userId: string;
  send: (event: string, data: unknown) => void;
}) {
  const sendTask = (data: TaskStreamEvent) => send("task", data);
  const webMcpRecordingState = createWebMcpRecordingState();

  const sendSnapshot = () => {
    const taskRun = getTaskRunSnapshot(taskRunId, userId);
    if (taskRun) sendTask({ type: "snapshot", taskRun });
  };

  const addEvent = (event: Parameters<typeof appendTaskEvent>[0]) => {
    const saved = appendTaskEvent(event);
    if (saved) sendTask({ type: "event", event: saved });
    return saved;
  };

  const setStatus = (
    status: TaskRunStatus,
    title: string,
    details?: Record<string, unknown>,
    completedAt: number | null = null,
  ) => {
    updateTaskRunStatus({ id: taskRunId, userId, status, completedAt });
    addEvent({
      taskRunId,
      userId,
      kind: status === "failed" ? "error" : "status",
      title,
      status,
      details,
      completedAt: completedAt ?? undefined,
    });
    sendSnapshot();
  };

  const persistArtifacts = (toolCallId: string, toolName: string, result: unknown) => {
    const persisted = persistToolResultArtifacts({
      taskRunId,
      userId,
      toolCallId,
      toolName: shortToolName(toolName),
      result,
    });

    if (persisted.artifacts.length > 0 || persisted.events.length > 0) {
      sendTask({ type: "artifacts", ...persisted });
      sendSnapshot();
    }

    return persisted.artifacts;
  };

  const recordWebMcp = (toolCallId: string, toolName: string, input: unknown, result: unknown) => {
    let recorded: ReturnType<typeof recordWebMcpToolResult>;
    try {
      recorded = recordWebMcpToolResult({
        userId,
        state: webMcpRecordingState,
        toolName,
        input,
        result,
      });
    } catch (error) {
      console.warn("Web MCP recording failed", error);
      return null;
    }

    if (!recorded) return null;

    const event = addEvent({
      taskRunId,
      userId,
      kind: "message",
      title: recorded.title,
      details: recorded.details,
      toolCallId,
    });
    sendSnapshot();
    return event;
  };

  const addTokenUsage = (usage: Partial<TokenUsage>) => {
    const updated = addTaskRunTokenUsage({ id: taskRunId, userId, usage });
    if (updated) sendTask({ type: "snapshot", taskRun: updated });
    return updated;
  };

  return {
    taskRunId,
    userId,
    sendSnapshot,
    addEvent,
    setStatus,
    persistArtifacts,
    recordWebMcp,
    addTokenUsage,
  };
}

function createCredentialBrokerMcpServer({
  agent,
  taskTrace,
  browserConnection,
}: {
  agent: Agent;
  taskTrace: TaskTraceRuntime;
  browserConnection: BrowserConnection;
}) {
  return createSdkMcpServer({
    name: "meta_credentials",
    version: "0.1.0",
    tools: [
      tool(
        "request_credential_approval",
        [
          "Request user approval before using a saved credential for a website login.",
          "This tool never returns a plaintext password or passkey material to the model.",
          "Use it when a browser task is blocked by a login/password/passkey step and the user has enabled the credential broker capability.",
        ].join(" "),
        {
          origin: z.string().url().describe("The exact site origin that needs the credential, such as https://example.com."),
          currentUrl: z.string().url().optional().describe("The current page URL, if known."),
          accountHint: z.string().max(320).optional().describe("Visible account/email hint, if known."),
          reason: z.string().min(1).max(1000).describe("Why this credential approval is needed for the user's current task."),
          requestedAction: z
            .enum(["fill_password", "use_passkey", "reuse_session", "scheduled_read"])
            .default("fill_password")
            .describe("The credential action requested from the user."),
        },
        async (args) => {
          if (!hasClaudeCredentialBroker(agent, browserConnection)) {
            return credentialToolError("Credential broker is not enabled for this agent/session.");
          }

          const origin = normalizeCredentialOrigin(args.origin);
          if (!origin) {
            return credentialToolError("Invalid credential origin.");
          }

          const currentUrl = normalizeCredentialUrl(args.currentUrl);
          const request = createCredentialRequest({
            userId: taskTrace.userId,
            taskRunId: taskTrace.taskRunId,
            agentId: agent.id,
            origin,
            currentUrl,
            accountHint: cleanCredentialText(args.accountHint, 320),
            reason: cleanCredentialText(args.reason, 1000) ?? "Agent requested credential approval.",
            requestedAction: args.requestedAction,
          });

          taskTrace.setStatus("waiting_for_user", "Ждёт разрешения на credential", {
            credentialRequest: credentialRequestForClient(request),
          });

          taskTrace.addEvent({
            taskRunId: taskTrace.taskRunId,
            userId: taskTrace.userId,
            kind: "message",
            title: `Credential approval: ${request.origin}`,
            status: "waiting_for_user",
            details: {
              credentialRequest: credentialRequestForClient(request),
            },
          });
          taskTrace.sendSnapshot();

          const resolved = await waitForCredentialDecision(request.id, taskTrace.userId, request.expiresAt);
          if (!resolved || resolved.status === "expired") {
            taskTrace.setStatus("running", "Credential approval истёк", {
              credentialRequest: resolved ? credentialRequestForClient(resolved) : credentialRequestForClient(request),
            });
            return credentialToolError("Credential approval expired. Ask the user to retry if this login is still needed.");
          }

          if (resolved.status === "denied") {
            taskTrace.setStatus("running", "Credential approval отклонён", {
              credentialRequest: credentialRequestForClient(resolved),
            });
            return credentialToolError("The user denied credential approval. Do not try to obtain or infer the password.");
          }

          taskTrace.setStatus("running", "Credential approval получен", {
            credentialRequest: credentialRequestForClient(resolved),
          });
          taskTrace.addEvent({
            taskRunId: taskTrace.taskRunId,
            userId: taskTrace.userId,
            kind: "message",
            title: `Credential approved: ${resolved.origin}`,
            details: {
              credentialRequest: credentialRequestForClient(resolved),
              secretAvailableToModel: false,
            },
          });
          taskTrace.sendSnapshot();

          return {
            content: [
              {
                type: "text" as const,
                text: JSON.stringify(
                  {
                    status: "approved",
                    requestId: resolved.id,
                    origin: resolved.origin,
                    accountHint: resolved.accountHint,
                    requestedAction: resolved.requestedAction,
                    secretAvailableToModel: false,
                    note: "User approved credential use through the broker. The model did not receive a password. Continue through the browser session; if OS autofill, passkey user-presence, MFA, or captcha blocks progress, report that exact blocker.",
                  },
                  null,
                  2,
                ),
              },
            ],
          };
        },
        {
          annotations: {
            readOnlyHint: false,
            destructiveHint: false,
            openWorldHint: false,
          },
        },
      ),
    ],
  });
}

function hasCredentialBroker(
  agent: Agent,
  browserConnection: BrowserConnection,
) {
  return (
    agent.capabilities.includes("chrome_browser") &&
    agent.capabilities.includes("credential_broker") &&
    Boolean(browserConnection.chromeMcpUrl)
  );
}

function hasClaudeCredentialBroker(agent: Agent, browserConnection: BrowserConnection) {
  return hasCredentialBroker(agent, browserConnection);
}

function credentialRequestForClient(request: CredentialRequest) {
  return {
    id: request.id,
    taskRunId: request.taskRunId,
    agentId: request.agentId,
    origin: request.origin,
    currentUrl: request.currentUrl,
    accountHint: request.accountHint,
    reason: request.reason,
    requestedAction: request.requestedAction,
    status: request.status,
    createdAt: request.createdAt,
    expiresAt: request.expiresAt,
    resolvedAt: request.resolvedAt,
  };
}

function credentialToolError(message: string) {
  return {
    content: [{ type: "text" as const, text: message }],
    isError: true,
  };
}

async function waitForCredentialDecision(requestId: string, userId: string, expiresAt: number) {
  while (Date.now() < expiresAt) {
    const request = getCredentialRequest(requestId, userId);
    if (!request || request.status !== "pending") return request;
    await sleep(500);
  }

  return expireCredentialRequest(requestId, userId);
}

type CredentialFallbackRequest = {
  origin: string;
  currentUrl: string | null;
  accountHint: string | null;
  reason: string;
  requestedAction: CredentialRequest["requestedAction"];
};

async function runCredentialBrokerFallback({
  agent,
  provider,
  conversation,
  runtimeContext,
  browserConnection,
  taskTrace,
  send,
  abortSignal,
  request,
  blockedContent,
}: {
  agent: Agent;
  provider: "claude" | "codex";
  conversation: string;
  runtimeContext: string;
  browserConnection: BrowserConnection;
  taskTrace: TaskTraceRuntime;
  send: (event: string, data: unknown) => void;
  abortSignal?: AbortSignal;
  request: CredentialFallbackRequest;
  blockedContent: string;
}): Promise<AgentRunResult | null> {
  const saved = createCredentialRequest({
    userId: taskTrace.userId,
    taskRunId: taskTrace.taskRunId,
    agentId: agent.id,
    origin: request.origin,
    currentUrl: request.currentUrl,
    accountHint: request.accountHint,
    reason: request.reason,
    requestedAction: request.requestedAction,
  });

  taskTrace.setStatus("waiting_for_user", "Ждёт разрешения на credential", {
    credentialRequest: credentialRequestForClient(saved),
    fallback: "host_detected_credential_blocker",
  });

  taskTrace.addEvent({
    taskRunId: taskTrace.taskRunId,
    userId: taskTrace.userId,
    kind: "message",
    title: `Credential approval: ${saved.origin}`,
    status: "waiting_for_user",
    details: {
      credentialRequest: credentialRequestForClient(saved),
      fallback: "host_detected_credential_blocker",
    },
  });
  taskTrace.sendSnapshot();

  const resolved = await waitForCredentialDecision(saved.id, taskTrace.userId, saved.expiresAt);
  if (!resolved || resolved.status === "expired") {
    taskTrace.setStatus("running", "Credential approval истёк", {
      credentialRequest: resolved ? credentialRequestForClient(resolved) : credentialRequestForClient(saved),
    });
    return null;
  }

  if (resolved.status === "denied") {
    taskTrace.setStatus("running", "Credential approval отклонён", {
      credentialRequest: credentialRequestForClient(resolved),
    });
    return null;
  }

  taskTrace.setStatus("running", "Credential approval получен", {
    credentialRequest: credentialRequestForClient(resolved),
  });
  taskTrace.addEvent({
    taskRunId: taskTrace.taskRunId,
    userId: taskTrace.userId,
    kind: "message",
    title: `Credential approved: ${resolved.origin}`,
    details: {
      credentialRequest: credentialRequestForClient(resolved),
      secretAvailableToModel: false,
      fallback: "host_detected_credential_blocker",
    },
  });
  taskTrace.sendSnapshot();
  send("replace", { text: "" });

  const retryInstruction = buildCredentialBrokerFallbackRetryInstruction(resolved);
  return provider === "codex"
    ? streamCodexReply({
        agent,
        priorConversation: [conversation, `Assistant: ${blockedContent}`].filter(Boolean).join("\n\n"),
        latestUserMessage: retryInstruction,
        runtimeContext,
        browserConnection,
        taskTrace,
        send,
        abortSignal,
      })
    : streamClaudeReply({
        agent,
        conversation: [conversation, `Assistant: ${blockedContent}`, `User: ${retryInstruction}`].join("\n\n"),
        runtimeContext,
        browserConnection,
        taskTrace,
        send,
        abortSignal,
      });
}

function shouldRunCredentialBrokerFallback(
  result: AgentRunResult,
  agent: Agent,
  browserConnection: BrowserConnection,
) {
  if (!hasCredentialBroker(agent, browserConnection)) return false;
  if (result.toolTrace.some((entry) => entry.name === "mcp__meta_credentials__request_credential_approval")) {
    return false;
  }

  const content = result.content.replace(/\s+/g, " ").trim();
  if (!content) return false;

  return CREDENTIAL_BLOCKER_PATTERNS.some((pattern) => pattern.test(content));
}

function inferCredentialFallbackRequest({
  userMessage,
  result,
}: {
  agent: Agent;
  browserConnection: BrowserConnection;
  taskTrace: TaskTraceRuntime;
  userMessage: string;
  result: AgentRunResult;
}): CredentialFallbackRequest | null {
  const text = [userMessage, result.content].join("\n");
  const currentUrl = inferCredentialCurrentUrl(text);
  const origin = currentUrl ? normalizeCredentialOrigin(currentUrl) : inferCredentialOriginFromText(text);
  if (!origin) return null;

  const requestedAction: CredentialRequest["requestedAction"] = /passkey|webauthn|touch\s*id|face\s*id/i.test(text)
    ? "use_passkey"
    : /session|cookie|already\s+logged|reuse/i.test(text)
      ? "reuse_session"
      : "fill_password";

  return {
    origin,
    currentUrl: currentUrl ? normalizeCredentialUrl(currentUrl) : null,
    accountHint: inferAccountHint(text),
    reason: buildCredentialFallbackReason(text),
    requestedAction,
  };
}

function buildCredentialBrokerFallbackRetryInstruction(request: CredentialRequest) {
  return [
    "Продолжи ту же задачу сейчас.",
    `Пользователь одобрил credential use через broker для ${request.origin}.`,
    request.currentUrl ? `Текущая страница: ${request.currentUrl}.` : null,
    `Запрошенное действие: ${request.requestedAction}.`,
    "Plaintext пароль, passkey private material, cookies и auth headers тебе не доступны.",
    "Вернись к открытой странице в браузере и попробуй browser-native saved-password/passkey flow: сфокусируй нужное поле, используй доступный UI Chrome/OS autofill или passkey user-presence prompt, если он появился.",
    "Не проси пользователя вставлять пароль в чат. Если OS prompt, Touch ID, MFA, captcha или отсутствие сохранённого credential всё ещё блокирует продолжение, назови ровно этот блокер.",
    "Если credential применился, продолжи исходную задачу и остановись перед необратимым финальным действием.",
  ]
    .filter(Boolean)
    .join(" ");
}

const CREDENTIAL_BLOCKER_PATTERNS = [
  /нуж[её]н\s+(?:ваш\s+)?(?:ввод\s+)?парол/i,
  /введите\s+парол/i,
  /поле\s+[`"“”']?password/i,
  /password\s+(?:field|required|needed|prompt|confirm)/i,
  /confirm\s+access/i,
  /sudo[-\s]?confirm/i,
  /passkey|touch\s*id|face\s*id|security\s+key|webauthn/i,
  /заблокирован[ао]?\s+(?:логин|парол|passkey|mfa|2fa)/i,
];

function inferCredentialCurrentUrl(text: string) {
  const matches = text.match(/https?:\/\/[^\s`"'<>)]*/gi) ?? [];
  const candidate =
    matches.find((url) => /github\.com|gitlab\.com|google\.com|slack\.com|notion\.so|figma\.com|linear\.app/i.test(url)) ??
    matches[0];
  if (!candidate) return null;

  try {
    const url = new URL(candidate.replace(/[.,;:!?]+$/g, ""));
    return url.toString();
  } catch {
    return null;
  }
}

function inferCredentialOriginFromText(text: string) {
  if (/github/i.test(text)) return "https://github.com";
  if (/gitlab/i.test(text)) return "https://gitlab.com";
  if (/slack/i.test(text)) return "https://slack.com";
  if (/notion/i.test(text)) return "https://www.notion.so";
  if (/figma/i.test(text)) return "https://www.figma.com";
  if (/linear/i.test(text)) return "https://linear.app";
  return null;
}

function inferAccountHint(text: string) {
  const email = text.match(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i)?.[0];
  return email ? cleanCredentialText(email, 320) : null;
}

function buildCredentialFallbackReason(text: string) {
  const compact = text.replace(/\s+/g, " ").trim();
  const blocker = CREDENTIAL_BLOCKER_PATTERNS.find((pattern) => pattern.test(compact));
  const summary = compact.length > 280 ? `${compact.slice(0, 277)}...` : compact;
  return cleanCredentialText(
    blocker
      ? `Agent reached a credential gate while executing the user's task. Visible context: ${summary}`
      : "Agent requested credential approval to continue the user's browser task.",
    1000,
  ) ?? "Agent requested credential approval to continue the user's browser task.";
}

function normalizeCredentialOrigin(value: string) {
  try {
    return new URL(value).origin;
  } catch {
    return null;
  }
}

function normalizeCredentialUrl(value: string | undefined) {
  if (!value) return null;
  try {
    const url = new URL(value);
    url.hash = "";
    for (const key of [...url.searchParams.keys()]) {
      if (/code|token|secret|password|auth|session|state/i.test(key)) {
        url.searchParams.delete(key);
      }
    }
    return url.toString();
  } catch {
    return null;
  }
}

function cleanCredentialText(value: unknown, maxLength: number) {
  if (typeof value !== "string") return null;
  const cleaned = value.replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim();
  return cleaned ? cleaned.slice(0, maxLength) : null;
}

function sleep(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function streamClaudeReply({
  agent,
  conversation,
  runtimeContext,
  browserConnection,
  taskTrace,
  send,
  abortSignal,
}: {
  agent: Agent;
  conversation: string;
  runtimeContext: string;
  browserConnection: BrowserConnection;
  taskTrace: TaskTraceRuntime;
  send: (event: string, data: unknown) => void;
  abortSignal?: AbortSignal;
}) {
  const tools = capabilitiesToTools(agent.capabilities);
  let full = "";
  const toolTrace: ToolTraceEntry[] = [];
  const reportTokenUsage = createTokenUsageReporter(taskTrace);

  const hasBrowserMcp = agent.capabilities.includes("chrome_browser") && Boolean(browserConnection.chromeMcpUrl);
  taskTrace.setStatus("running", "Агент начал выполнение", {
    provider: "claude",
    browserConnected: hasBrowserMcp,
  });

  const q = query({
    prompt: conversation,
    options: {
      model: agent.model,
      systemPrompt: [agent.systemPrompt.trim(), runtimeContext.trim()].filter(Boolean).join("\n\n") || undefined,
      tools,
      allowedTools: tools,
      ...(hasBrowserMcp
        ? {
                mcpServers: {
              chrome: buildClaudeChromeMcpServer(browserConnection.chromeMcpUrl!),
              ...(hasClaudeCredentialBroker(agent, browserConnection)
                ? {
                    meta_credentials: createCredentialBrokerMcpServer({
                      agent,
                      taskTrace,
                      browserConnection,
                    }),
                  }
                : {}),
            },
          }
        : {}),
      canUseTool: async (toolName, input) => {
        if (tools.includes(toolName)) {
          return { behavior: "allow" as const, updatedInput: input };
        }

        if (hasClaudeCredentialBroker(agent, browserConnection) && toolName === "mcp__meta_credentials__request_credential_approval") {
          return { behavior: "allow" as const, updatedInput: input };
        }

        if (hasBrowserMcp) {
          return { behavior: "allow" as const, updatedInput: input };
        }

        return {
          behavior: "deny" as const,
          message: "Этот инструмент не включён для данного агента.",
        };
      },
    },
  });

  try {
    for await (const msg of q) {
      if (abortSignal?.aborted) break;
      reportTokenUsage(msg);
      if (msg.type === "assistant") {
        const content = msg.message?.content;
        if (Array.isArray(content)) {
          for (const block of content) {
            if (block.type === "text" && block.text) {
              full += block.text;
              send("delta", { text: block.text });
            } else if (block.type === "tool_use") {
              const startedAt = Date.now();
              const entry = {
                id: block.id,
                name: block.name,
                input: block.input,
                startedAt,
              };
              toolTrace.push(entry);
              send("tool", { phase: "call", ...entry } satisfies ToolEvent);
              taskTrace.addEvent({
                taskRunId: taskTrace.taskRunId,
                userId: taskTrace.userId,
                kind: "tool_call",
                title: `Старт: ${shortToolName(block.name)}`,
                details: { input: previewToolValue(block.input) },
                toolCallId: block.id,
                startedAt,
              });
            }
          }
        }
      } else if (msg.type === "user") {
        const content = msg.message?.content;
        if (Array.isArray(content)) {
          for (const block of content) {
            if (block.type === "tool_result") {
              const completedAt = Date.now();
              const index = toolTrace.findIndex((entry) => entry.id === block.tool_use_id);
              const result = "content" in block ? block.content : undefined;
              const isError = "is_error" in block ? Boolean(block.is_error) : false;
              const toolName = index >= 0 ? toolTrace[index].name : "tool_result";
              const artifacts = taskTrace.persistArtifacts(block.tool_use_id, toolName, result);
              const input = index >= 0 ? toolTrace[index].input : undefined;
              taskTrace.recordWebMcp(block.tool_use_id, toolName, input, result);

              if (index >= 0) {
                toolTrace[index] = {
                  ...toolTrace[index],
                  result,
                  ...(artifacts.length > 0 ? { artifacts } : {}),
                  isError,
                  completedAt,
                };
              } else {
                toolTrace.push({
                  id: block.tool_use_id,
                  name: "tool_result",
                  result,
                  ...(artifacts.length > 0 ? { artifacts } : {}),
                  isError,
                  startedAt: completedAt,
                  completedAt,
                });
              }

              const startedAt = index >= 0 ? toolTrace[index].startedAt : completedAt;
              taskTrace.addEvent({
                taskRunId: taskTrace.taskRunId,
                userId: taskTrace.userId,
                kind: "tool_result",
                title: `${isError ? "Ошибка" : "Готово"}: ${shortToolName(toolName)}`,
                details: {
                  isError,
                  durationMs: completedAt - startedAt,
                  result: previewToolValue(result),
                },
                toolCallId: block.tool_use_id,
                startedAt,
                completedAt,
              });

              send("tool", {
                phase: "result",
                id: block.tool_use_id,
                result,
                ...(artifacts.length > 0 ? { artifacts } : {}),
                isError,
                completedAt,
              } satisfies ToolEvent);
            }
          }
        }
      } else if (msg.type === "result") {
        send("done", {});
      }
    }
  } catch (err) {
    throw new AgentRunError(formatUnknownError(err), { content: full, toolTrace });
  }

  return { content: full, toolTrace };
}

async function streamCodexReply({
  agent,
  priorConversation,
  latestUserMessage,
  runtimeContext,
  browserConnection,
  taskTrace,
  send,
  abortSignal,
}: {
  agent: Agent;
  priorConversation: string;
  latestUserMessage: string;
  runtimeContext: string;
  browserConnection: BrowserConnection;
  taskTrace: TaskTraceRuntime;
  send: (event: string, data: unknown) => void;
  abortSignal?: AbortSignal;
}): Promise<AgentRunResult> {
  const args = buildCodexArgs(agent, priorConversation, latestUserMessage, runtimeContext, browserConnection);
  taskTrace.setStatus("running", "Агент начал выполнение", {
    provider: "codex",
    browserConnected: agent.capabilities.includes("chrome_browser") && Boolean(browserConnection.chromeMcpUrl),
  });

  const child = spawn("codex", args, {
    cwd: process.cwd(),
    env: process.env,
    stdio: ["ignore", "pipe", "pipe"],
  });

  const onAbort = () => {
    try {
      child.kill("SIGTERM");
    } catch {
      // ignore
    }
  };
  if (abortSignal) {
    if (abortSignal.aborted) onAbort();
    else abortSignal.addEventListener("abort", onAbort, { once: true });
  }

  let stdoutBuffer = "";
  let stderrBuffer = "";
  let finalMessage = "";
  let codexError: string | null = null;
  const toolTrace: ToolTraceEntry[] = [];
  const reportTokenUsage = createTokenUsageReporter(taskTrace);

  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (chunk: string) => {
    stdoutBuffer += chunk;
    const lines = stdoutBuffer.split(/\r?\n/);
    stdoutBuffer = lines.pop() ?? "";

    for (const rawLine of lines) {
      const line = rawLine.trim();
      if (!line) continue;

      let event: unknown;
      try {
        event = JSON.parse(line);
      } catch {
        continue;
      }

      if (!event || typeof event !== "object") continue;
      reportTokenUsage(event);
      const payload = event as {
        type?: string;
        message?: string;
        error?: { message?: string };
        item?: {
          id?: string;
          type?: string;
          text?: string;
          command?: string;
          server?: string;
          tool?: string;
          arguments?: unknown;
          result?: unknown;
          error?: { message?: string } | string | null;
          status?: string;
        };
      };

      if (payload.type === "item.started" && payload.item?.type === "command_execution") {
        const startedAt = Date.now();
        const entry = {
          id: payload.item.id ?? `codex-${toolTrace.length + 1}`,
          name: "Shell",
          input: payload.item.command ?? "",
          startedAt,
        };
        toolTrace.push(entry);
        send("tool", { phase: "call", ...entry } satisfies ToolEvent);
        taskTrace.addEvent({
          taskRunId: taskTrace.taskRunId,
          userId: taskTrace.userId,
          kind: "tool_call",
          title: "Старт: Shell",
          details: { input: previewToolValue(entry.input) },
          toolCallId: entry.id,
          startedAt,
        });
      }

      if (payload.type === "item.started" && payload.item?.type === "mcp_tool_call") {
        const startedAt = Date.now();
        const name = buildCodexMcpToolName(payload.item.server, payload.item.tool);
        const entry = {
          id: payload.item.id ?? `codex-${toolTrace.length + 1}`,
          name,
          input: payload.item.arguments ?? {},
          startedAt,
        };
        toolTrace.push(entry);
        send("tool", { phase: "call", ...entry } satisfies ToolEvent);
        taskTrace.addEvent({
          taskRunId: taskTrace.taskRunId,
          userId: taskTrace.userId,
          kind: "tool_call",
          title: `Старт: ${shortToolName(name)}`,
          details: { input: previewToolValue(entry.input) },
          toolCallId: entry.id,
          startedAt,
        });
      }

      if (payload.type === "item.completed" && payload.item?.type === "agent_message" && payload.item.text) {
        finalMessage = payload.item.text;
      }

      if (payload.type === "item.completed" && payload.item?.type === "command_execution") {
        const completedAt = Date.now();
        const id = payload.item.id ?? `codex-${toolTrace.length}`;
        const index = toolTrace.findIndex((entry) => entry.id === id);
        const isError = Boolean(payload.item.error) || payload.item.status === "failed";
        const result = isError ? payload.item.error : payload.item.result;

        if (index >= 0) {
          toolTrace[index] = {
            ...toolTrace[index],
            result,
            isError,
            completedAt,
          };

          taskTrace.addEvent({
            taskRunId: taskTrace.taskRunId,
            userId: taskTrace.userId,
            kind: "tool_result",
            title: `${isError ? "Ошибка" : "Готово"}: Shell`,
            details: {
              isError,
              durationMs: completedAt - toolTrace[index].startedAt,
              result: previewToolValue(result),
            },
            toolCallId: id,
            startedAt: toolTrace[index].startedAt,
            completedAt,
          });

          send("tool", {
            phase: "result",
            id,
            result,
            isError,
            completedAt,
          } satisfies ToolEvent);
        }
      }

      if (payload.type === "item.completed" && payload.item?.type === "mcp_tool_call") {
        const completedAt = Date.now();
        const id = payload.item.id ?? `codex-${toolTrace.length + 1}`;
        const index = toolTrace.findIndex((entry) => entry.id === id);
        const isError = Boolean(payload.item.error) || payload.item.status === "failed";
        const result = isError ? payload.item.error : payload.item.result;
        const toolName = index >= 0 ? toolTrace[index].name : buildCodexMcpToolName(payload.item.server, payload.item.tool);
        const artifacts = taskTrace.persistArtifacts(id, toolName, result);
        const input = index >= 0 ? toolTrace[index].input : payload.item.arguments ?? {};
        taskTrace.recordWebMcp(id, toolName, input, result);

        if (index >= 0) {
          toolTrace[index] = {
            ...toolTrace[index],
            result,
            ...(artifacts.length > 0 ? { artifacts } : {}),
            isError,
            completedAt,
          };
        } else {
          toolTrace.push({
            id,
            name: buildCodexMcpToolName(payload.item.server, payload.item.tool),
            input: payload.item.arguments ?? {},
            result,
            ...(artifacts.length > 0 ? { artifacts } : {}),
            isError,
            startedAt: completedAt,
            completedAt,
          });
        }

        const startedAt = index >= 0 ? toolTrace[index].startedAt : completedAt;
        taskTrace.addEvent({
          taskRunId: taskTrace.taskRunId,
          userId: taskTrace.userId,
          kind: "tool_result",
          title: `${isError ? "Ошибка" : "Готово"}: ${shortToolName(toolName)}`,
          details: {
            isError,
            durationMs: completedAt - startedAt,
            result: previewToolValue(result),
          },
          toolCallId: id,
          startedAt,
          completedAt,
        });

        send("tool", {
          phase: "result",
          id,
          result,
          ...(artifacts.length > 0 ? { artifacts } : {}),
          isError,
          completedAt,
        } satisfies ToolEvent);
      }

      if (payload.type === "error") {
        codexError = payload.message ?? codexError;
      }

      if (payload.type === "turn.failed") {
        codexError = payload.error?.message ?? codexError;
      }
    }
  });

  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk: string) => {
    if (stderrBuffer.length >= 8000) return;
    stderrBuffer += chunk.slice(0, 8000 - stderrBuffer.length);
  });

  let exitCode: number;
  try {
    exitCode = await new Promise<number>((resolve, reject) => {
      child.on("error", reject);
      child.on("close", resolve);
    });
  } catch (err) {
    abortSignal?.removeEventListener("abort", onAbort);
    throw new AgentRunError(formatUnknownError(err), { content: finalMessage, toolTrace });
  }
  abortSignal?.removeEventListener("abort", onAbort);

  if (abortSignal?.aborted) {
    return { content: finalMessage, toolTrace };
  }

  if (stdoutBuffer.trim()) {
    try {
      const payload = JSON.parse(stdoutBuffer.trim()) as {
        type?: string;
        item?: { type?: string; text?: string };
      };
      reportTokenUsage(payload);
      if (payload.type === "item.completed" && payload.item?.type === "agent_message" && payload.item.text) {
        finalMessage = payload.item.text;
      }
    } catch {
      // Ignore incomplete tail.
    }
  }

  if (exitCode !== 0) {
    throw new AgentRunError(extractCodexError(codexError, stderrBuffer), { content: finalMessage, toolTrace });
  }

  if (!finalMessage.trim()) {
    throw new AgentRunError("Codex не вернул итоговый ответ.", { content: finalMessage, toolTrace });
  }

  send("delta", { text: finalMessage });
  send("done", {});
  return { content: finalMessage, toolTrace };
}

function buildCodexMcpToolName(server?: string, tool?: string) {
  if (server && tool) return `mcp__${server}__${tool}`;
  return tool ?? "MCP tool";
}

function shortToolName(name: string) {
  return name.replace(/^mcp__chrome__/, "").replace(/^mcp__[^_]+__/, "");
}

function createTokenUsageReporter(taskTrace: TaskTraceRuntime) {
  let lastUsage = emptyTokenUsage();

  return (value: unknown) => {
    const current = extractTokenUsage(value);
    if (!current) return;

    const delta = subtractTokenUsage(current, lastUsage);
    lastUsage = maxTokenUsage(lastUsage, current);
    if (!hasTokenUsage(delta)) return;

    taskTrace.addTokenUsage(delta);
  };
}

function extractTokenUsage(value: unknown): TokenUsage | null {
  if (!isRecord(value)) return null;

  const candidates = [
    readTokenUsageObject(value),
    isRecord(value.usage) ? readTokenUsageObject(value.usage) : null,
    isRecord(value.apiUsage) ? readTokenUsageObject(value.apiUsage) : null,
    isRecord(value.response) && isRecord(value.response.usage) ? readTokenUsageObject(value.response.usage) : null,
    isRecord(value.item) && isRecord(value.item.usage) ? readTokenUsageObject(value.item.usage) : null,
    isRecord(value.modelUsage) ? readModelUsage(value.modelUsage) : null,
  ].filter((candidate): candidate is TokenUsage => Boolean(candidate));

  if (candidates.length === 0) return null;

  const best = candidates.reduce((winner, candidate) =>
    candidate.totalTokens > winner.totalTokens ? candidate : winner,
  );

  const costUsd = [
    getNumberFromRecord(value, "total_cost_usd"),
    getNumberFromRecord(value, "totalCostUsd"),
    getNumberFromRecord(value, "cost_usd"),
    getNumberFromRecord(value, "costUSD"),
    ...candidates.map((candidate) => candidate.costUsd),
  ]
    .filter((cost): cost is number => typeof cost === "number" && Number.isFinite(cost) && cost > 0)
    .sort((a, b) => b - a)[0];

  return costUsd !== undefined ? { ...best, costUsd } : best;
}

function readModelUsage(value: Record<string, unknown>): TokenUsage | null {
  const usage = emptyTokenUsage();
  for (const child of Object.values(value)) {
    if (!isRecord(child)) continue;
    const childUsage = readTokenUsageObject(child);
    if (!childUsage) continue;
    usage.inputTokens += childUsage.inputTokens;
    usage.outputTokens += childUsage.outputTokens;
    usage.cacheCreationInputTokens += childUsage.cacheCreationInputTokens;
    usage.cacheReadInputTokens += childUsage.cacheReadInputTokens;
    usage.totalTokens += childUsage.totalTokens;
    usage.costUsd = (usage.costUsd ?? 0) + (childUsage.costUsd ?? 0);
  }

  return hasTokenUsage(usage) ? usage : null;
}

function readTokenUsageObject(value: Record<string, unknown>): TokenUsage | null {
  const inputTokens =
    getNumberFromRecord(value, "input_tokens") ??
    getNumberFromRecord(value, "inputTokens") ??
    getNumberFromRecord(value, "prompt_tokens") ??
    getNumberFromRecord(value, "promptTokens") ??
    0;
  const outputTokens =
    getNumberFromRecord(value, "output_tokens") ??
    getNumberFromRecord(value, "outputTokens") ??
    getNumberFromRecord(value, "completion_tokens") ??
    getNumberFromRecord(value, "completionTokens") ??
    0;
  const cacheCreationInputTokens =
    getNumberFromRecord(value, "cache_creation_input_tokens") ??
    getNumberFromRecord(value, "cacheCreationInputTokens") ??
    0;
  const cacheReadInputTokens =
    getNumberFromRecord(value, "cache_read_input_tokens") ??
    getNumberFromRecord(value, "cacheReadInputTokens") ??
    getCachedInputTokens(value) ??
    0;
  const summedTotal = inputTokens + outputTokens + cacheCreationInputTokens + cacheReadInputTokens;
  const totalTokens = Math.max(
    getNumberFromRecord(value, "total_tokens") ?? getNumberFromRecord(value, "totalTokens") ?? 0,
    summedTotal,
  );
  const costUsd =
    getNumberFromRecord(value, "cost_usd") ??
    getNumberFromRecord(value, "costUSD") ??
    getNumberFromRecord(value, "total_cost_usd") ??
    getNumberFromRecord(value, "totalCostUsd");
  const usage: TokenUsage = {
    inputTokens: sanitizeTokenCount(inputTokens),
    outputTokens: sanitizeTokenCount(outputTokens),
    cacheCreationInputTokens: sanitizeTokenCount(cacheCreationInputTokens),
    cacheReadInputTokens: sanitizeTokenCount(cacheReadInputTokens),
    totalTokens: sanitizeTokenCount(totalTokens),
    ...(costUsd !== undefined && costUsd > 0 ? { costUsd } : {}),
  };

  return hasTokenUsage(usage) ? usage : null;
}

function getCachedInputTokens(value: Record<string, unknown>) {
  const details = value.input_tokens_details ?? value.inputTokensDetails ?? value.prompt_tokens_details;
  if (!isRecord(details)) return undefined;
  return getNumberFromRecord(details, "cached_tokens") ?? getNumberFromRecord(details, "cachedTokens");
}

function emptyTokenUsage(): TokenUsage {
  return {
    inputTokens: 0,
    outputTokens: 0,
    cacheCreationInputTokens: 0,
    cacheReadInputTokens: 0,
    totalTokens: 0,
  };
}

function subtractTokenUsage(current: TokenUsage, previous: TokenUsage): TokenUsage {
  return {
    inputTokens: Math.max(0, current.inputTokens - previous.inputTokens),
    outputTokens: Math.max(0, current.outputTokens - previous.outputTokens),
    cacheCreationInputTokens: Math.max(0, current.cacheCreationInputTokens - previous.cacheCreationInputTokens),
    cacheReadInputTokens: Math.max(0, current.cacheReadInputTokens - previous.cacheReadInputTokens),
    totalTokens: Math.max(0, current.totalTokens - previous.totalTokens),
    ...(
      current.costUsd !== undefined
        ? { costUsd: Math.max(0, current.costUsd - (previous.costUsd ?? 0)) }
        : {}
    ),
  };
}

function maxTokenUsage(a: TokenUsage, b: TokenUsage): TokenUsage {
  return {
    inputTokens: Math.max(a.inputTokens, b.inputTokens),
    outputTokens: Math.max(a.outputTokens, b.outputTokens),
    cacheCreationInputTokens: Math.max(a.cacheCreationInputTokens, b.cacheCreationInputTokens),
    cacheReadInputTokens: Math.max(a.cacheReadInputTokens, b.cacheReadInputTokens),
    totalTokens: Math.max(a.totalTokens, b.totalTokens),
    ...(
      a.costUsd !== undefined || b.costUsd !== undefined
        ? { costUsd: Math.max(a.costUsd ?? 0, b.costUsd ?? 0) }
        : {}
    ),
  };
}

function hasTokenUsage(usage: TokenUsage) {
  return (
    usage.inputTokens > 0 ||
    usage.outputTokens > 0 ||
    usage.cacheCreationInputTokens > 0 ||
    usage.cacheReadInputTokens > 0 ||
    usage.totalTokens > 0 ||
    Boolean(usage.costUsd && usage.costUsd > 0)
  );
}

function sanitizeTokenCount(value: number) {
  return Number.isFinite(value) && value > 0 ? Math.floor(value) : 0;
}

function getNumberFromRecord(value: Record<string, unknown>, key: string) {
  const child = value[key];
  return typeof child === "number" && Number.isFinite(child) ? child : undefined;
}

function buildTaskTitle(input: string) {
  const title = input.replace(/\s+/g, " ").trim();
  return title.length > 90 ? `${title.slice(0, 87)}...` : title || "Task";
}

function previewToolValue(value: unknown): unknown {
  return redactSensitiveValue(value);
}

function normalizeAgentRunFailure(err: unknown, fallback: AgentRunResult): AgentRunFailure {
  if (err instanceof AgentRunError) {
    return {
      message: cleanFailureMessage(err.message),
      content: err.partialContent,
      partialContent: err.partialContent,
      toolTrace: err.toolTrace,
    };
  }

  return {
    message: cleanFailureMessage(formatUnknownError(err)),
    content: fallback.content,
    partialContent: fallback.content,
    toolTrace: fallback.toolTrace,
  };
}

function buildFailureResult({
  message,
  errMsg,
  partialContent,
  toolTrace,
  agent,
  browserConnection,
}: {
  message: string;
  errMsg: string;
  partialContent: string;
  toolTrace: ToolTraceEntry[];
  agent: Agent;
  browserConnection: BrowserConnection;
}) {
  const stepsDone = toolTrace.filter((entry) => entry.completedAt).length;
  const lastTool = toolTrace.at(-1);
  const lines = [
    "Не смог довести задачу до финального результата.",
    "",
    `Задача: ${message.replace(/\s+/g, " ").trim()}`,
    `Статус: остановился${lastTool ? ` на шаге ${shortToolName(lastTool.name)}` : ""}.`,
    `Причина: ${errMsg}`,
    stepsDone > 0 ? `Что успел сделать: выполнено ${stepsDone} шаг(ов); подробный trace и скриншоты сохранены выше в карточке задачи.` : null,
    partialContent.trim() ? `Частичный ответ агента:\n${truncateForUser(partialContent.trim(), 1600)}` : null,
    `Следующий шаг: ${buildRecoveryHint(agent, browserConnection)}`,
  ];

  return lines.filter(Boolean).join("\n");
}

function buildRecoveryHint(agent: Agent, browserConnection: BrowserConnection) {
  if (agent.capabilities.includes("chrome_browser") && !browserConnection.chromeMcpUrl) {
    return "подключи Chrome MCP в настройках приложения и повтори ту же задачу.";
  }

  if (agent.capabilities.includes("chrome_browser")) {
    return "проверь, что Chrome MCP подключён, а логин/капча/модальные окна не блокируют сервис, затем повтори задачу из этого же чата; нужную страницу агент должен открыть сам.";
  }

  return "повтори задачу из этого же чата; сохраненный trace поможет понять, где остановился агент.";
}

function shouldRetryBrowserAutonomyHandoff(
  result: AgentRunResult,
  agent: Agent,
  browserConnection: BrowserConnection,
  userMessage: string,
) {
  if (!agent.capabilities.includes("chrome_browser") || !browserConnection.chromeMcpUrl) return false;

  const content = result.content.replace(/\s+/g, " ").trim();
  if (!content) return false;

  if (isMetaOrClarifyingQuestion(userMessage)) return false;

  if (BROWSER_HANDOFF_PATTERNS.some((pattern) => pattern.test(content))) return true;

  return isBrowserGroundedTask(userMessage) && !result.toolTrace.some(isBrowserToolTraceEntry);
}

function isBrowserToolTraceEntry(entry: ToolTraceEntry) {
  return (
    entry.name.startsWith("mcp__chrome__") ||
    entry.name.startsWith("chrome_") ||
    entry.name === "get_windows_and_tabs" ||
    entry.name === "search_tabs_content"
  );
}

const BROWSER_HANDOFF_PATTERNS = [
  /открой(?:те)?\s+(?:вкладку|страницу|сайт|браузер|chrome)/i,
  /открой(?:те)?\s+https?:\/\//i,
  /перейд(?:и|ите)\s+(?:на|в)\s+(?:вкладку|страницу|сайт|браузер|chrome)/i,
  /перейд(?:и|ите)\s+на\s+https?:\/\//i,
  /нужн[ао]\s+(?:самостоятельно\s+)?открыть\s+(?:вкладку|страницу|сайт|браузер|chrome)/i,
  /(?:созда(?:й|йте)|сгенериру(?:й|йте)|получи(?:те)?|выда(?:й|йте)).*(?:token|токен|pat|api\s*key|ключ\s+api)/i,
  /(?:не\s+могу|нет\s+доступа).*(?:создать|сгенерировать|выдать|получить).*(?:token|токен|pat|github|api\s*key|ключ\s+api)/i,
  /(?:personal access token|fine[-\s]?grained token|github\.com\/settings\/personal-access-tokens)/i,
  /если\s+нужно[,\s]+(?:я\s+)?(?:проверю|посмотрю|сравню|найду|могу\s+проверить|могу\s+посмотреть|могу\s+сравнить|могу\s+найти)/i,
  /оставь(?:те)?\s+chrome\s+открытым/i,
  /open\s+(?:the\s+)?(?:tab|page|site|browser|chrome)/i,
  /open\s+https?:\/\//i,
  /switch\s+to\s+(?:the\s+)?(?:tab|page|browser|chrome)/i,
];

function isBrowserGroundedTask(message: string) {
  const normalized = message.replace(/\s+/g, " ").trim().toLowerCase();
  if (!normalized) return false;

  return BROWSER_GROUNDED_TASK_PATTERNS.some((pattern) => pattern.test(normalized));
}

const BROWSER_GROUNDED_TASK_PATTERNS = [
  /(?:сейчас|сегодня|завтра|актуальн|текущ|в\s+реальном\s+времени)/i,
  /(?:проверь|посмотри|найди|открой|сравни|подбери|выбери|оцени)/i,
  /(?:интегрир|подключи|подключить|сконнект|авторизу|залогин|логин|connect|integrate|authorize|oauth)/i,
  /(?:github|gitlab|slack|notion|figma|linear).*(?:интегр|подключ|connect|integrate|oauth|токен|token|pat|api\s*key|ключ\s+api)/i,
  /(?:токен|token|pat|api\s*key|ключ\s+api|personal access|fine[-\s]?grained)/i,
  /(?:создай|создать|сгенерируй|сгенерировать|выдай|получи|получить|issue|generate|create).*(?:токен|token|pat|api\s*key|ключ)/i,
  /(?:сколько|когда|где|какой|какая|какие|лучший|лучше|варианты|цена|стоимость|доступн|свободн|наличи)/i,
  /\b(?:current|latest|today|now|check|find|compare|choose|options|price|availability|eta)\b/i,
];

const META_QUESTION_PATTERNS = [
  /\bкак(ая|ую|ой|ие)\s+модел/i,
  /\bкто\s+ты\b/i,
  /\bкак\s+тебя\s+зовут\b/i,
  /\bтво[ёе]?\s+имя\b/i,
  /\bрасскажи\s+о\s+себе\b/i,
  /\bчто\s+ты\s+зна(ешь|ете)\b/i,
  /\bпочему\b/i,
  /\bзачем\b/i,
  /\bwho\s+are\s+you\b/i,
  /\bwhat'?s?\s+your\s+(name|model)\b/i,
  /\b(which|what)\s+model\b/i,
  /\babout\s+(yourself|me|you)\b/i,
  /\bdo\s+(u|you)\s+know\b/i,
  /\bwhy\b/i,
];

function isMetaOrClarifyingQuestion(message: string) {
  const normalized = message.replace(/\s+/g, " ").trim().toLowerCase();
  if (!normalized) return false;
  return META_QUESTION_PATTERNS.some((pattern) => pattern.test(normalized));
}

const BROWSER_AUTONOMY_RETRY_INSTRUCTION = [
  "Продолжи ту же задачу сейчас.",
  "Предыдущий ответ попросил меня открыть или переключить браузерную вкладку, но Chrome MCP уже подключён.",
  "Сам найди существующую вкладку, переключись на неё или открой нужный сайт через browser tools.",
  "Если задача про интеграцию аккаунта, OAuth, GitHub, API key, PAT или token, открой нужные настройки сервиса сам и веди flow через браузер; не отвечай инструкциями, что пользователь должен сам открыть страницу, пока нет реального блокера.",
  "Если это задача выбора, планирования, поиска или сравнения, сам собери доступные варианты в браузере, сравни их по критериям, которые видны в источнике, и дай рекомендацию.",
  "Если реально блокирует логин, MFA, капча, неоднозначный выбор или финальное подтверждение, кратко назови этот блокер; иначе верни проверенный результат.",
].join(" ");

function buildBrowserAutonomyRetryConversation(conversation: string, invalidAnswer: string) {
  return [
    conversation,
    `Assistant: ${invalidAnswer}`,
    `User: ${BROWSER_AUTONOMY_RETRY_INSTRUCTION}`,
  ].join("\n\n");
}

function formatUnknownError(err: unknown) {
  return err instanceof Error ? err.message : String(err);
}

function cleanFailureMessage(message: string) {
  return truncateForUser(message.replace(/\s+/g, " ").trim(), 800) || "неизвестная ошибка.";
}

function truncateForUser(value: string, maxLength: number) {
  return value.length > maxLength ? `${value.slice(0, maxLength - 3)}...` : value;
}

function redactSensitiveValue(value: unknown, depth = 0): unknown {
  if (depth > 4) return "[truncated]";

  if (typeof value === "string") {
    const redacted = redactSecretPatterns(value);
    return redacted.length > 500 ? `${redacted.slice(0, 500)}...` : redacted;
  }

  if (typeof value !== "object" || value === null) return value;

  if (Array.isArray(value)) {
    return value.slice(0, 8).map((item) => redactSensitiveValue(item, depth + 1));
  }

  const redacted: Record<string, unknown> = {};
  for (const [key, child] of Object.entries(value).slice(0, 20)) {
    redacted[key] = shouldRedactKey(key) ? "[redacted]" : redactSensitiveValue(child, depth + 1);
  }
  return redacted;
}

function shouldRedactKey(key: string) {
  return /password|passwd|token|secret|api[_-]?key|access[_-]?key|client[_-]?secret|private[_-]?key|cookie|authorization|card|cvv|data/i.test(key);
}

function redactSecretPatterns(value: string) {
  return value
    .replace(/\bgithub_pat_[A-Za-z0-9_]{20,}\b/g, "[redacted:github_pat]")
    .replace(/\bgh[pousr]_[A-Za-z0-9_]{20,}\b/g, "[redacted:github_token]")
    .replace(/\bglpat-[A-Za-z0-9_-]{20,}\b/g, "[redacted:gitlab_token]")
    .replace(/\bxox[baprs]-[A-Za-z0-9-]{20,}\b/g, "[redacted:slack_token]")
    .replace(/\bsk-[A-Za-z0-9_-]{20,}\b/g, "[redacted:api_key]");
}

function normalizeUserRuntimeMetadata(
  input: UserRuntimeMetadata | undefined,
  req: NextRequest,
): UserRuntimeMetadata {
  const browserLocation = getBrowserLocation(input?.location);
  const edgeLocation = getEdgeLocation(req);

  return {
    locale: cleanShortString(input?.locale, 80),
    languages: Array.isArray(input?.languages)
      ? input.languages
          .map((language) => cleanShortString(language, 40))
          .filter((language): language is string => Boolean(language))
          .slice(0, 8)
      : undefined,
    timeZone: cleanShortString(input?.timeZone, 120),
    localTime: cleanShortString(input?.localTime, 80),
    utcOffsetMinutes:
      typeof input?.utcOffsetMinutes === "number" && Number.isFinite(input.utcOffsetMinutes)
        ? Math.max(-14 * 60, Math.min(14 * 60, Math.round(input.utcOffsetMinutes)))
        : undefined,
    calendar: cleanShortString(input?.calendar, 40),
    hourCycle: cleanShortString(input?.hourCycle, 20),
    platform: cleanShortString(input?.platform, 80),
    location: browserLocation ?? edgeLocation,
  };
}

function getBrowserLocation(location: UserRuntimeMetadata["location"]): UserRuntimeMetadata["location"] | undefined {
  if (location?.source !== "browser") return undefined;
  if (!isValidLatitude(location.latitude) || !isValidLongitude(location.longitude)) return undefined;

  return {
    source: "browser",
    latitude: roundCoordinate(location.latitude),
    longitude: roundCoordinate(location.longitude),
    ...(typeof location.accuracyMeters === "number" && Number.isFinite(location.accuracyMeters)
      ? { accuracyMeters: Math.max(0, Math.round(location.accuracyMeters)) }
      : {}),
    ...(isValidIsoDateTime(location.capturedAt) ? { capturedAt: location.capturedAt } : {}),
  };
}

function getEdgeLocation(req: NextRequest): UserRuntimeMetadata["location"] | undefined {
  const city = cleanShortString(safeDecodeHeader(req.headers.get("x-vercel-ip-city")), 120);
  const region = cleanShortString(req.headers.get("x-vercel-ip-country-region"), 80);
  const country =
    cleanShortString(req.headers.get("x-vercel-ip-country"), 20) ??
    cleanShortString(req.headers.get("cf-ipcountry"), 20);

  if (!city && !region && !country) return undefined;
  return {
    source: "edge",
    ...(city ? { city } : {}),
    ...(region ? { region } : {}),
    ...(country ? { country } : {}),
  };
}

function buildUserRuntimeContext(metadata: UserRuntimeMetadata) {
  const lines: string[] = [];

  if (metadata.localTime) lines.push(`User local time: ${metadata.localTime}`);
  if (metadata.timeZone) lines.push(`User time zone: ${metadata.timeZone}`);
  if (metadata.utcOffsetMinutes !== undefined) {
    lines.push(`User UTC offset: ${formatUtcOffset(metadata.utcOffsetMinutes)}`);
  }
  if (metadata.locale) lines.push(`User locale: ${metadata.locale}`);
  if (metadata.languages && metadata.languages.length > 0) {
    lines.push(`User browser languages: ${metadata.languages.join(", ")}`);
  }
  if (metadata.location) {
    if (
      metadata.location.source === "browser" &&
      metadata.location.latitude !== undefined &&
      metadata.location.longitude !== undefined
    ) {
      lines.push(
        [
          `Exact user location from explicit browser permission: ${metadata.location.latitude}, ${metadata.location.longitude}`,
          metadata.location.accuracyMeters !== undefined
            ? `accuracy about ${metadata.location.accuracyMeters} meters`
            : null,
          metadata.location.capturedAt ? `captured at ${metadata.location.capturedAt}` : null,
        ]
          .filter(Boolean)
          .join("; "),
      );
      lines.push(
        "Exact browser location is high-priority context for this turn. Silently use it whenever physical place, city, distance, availability, local search, local services, delivery, weather, scheduling around travel, routing, ETA, taxi, or maps could affect the answer.",
        "Do not ask for the user's current city or current location when exact browser location is present. If the location materially affects the answer, you may briefly mention that you used the shared current location.",
        "For routing, ETA, taxi, delivery pickup, or maps tasks, this exact browser location is the user's current origin/pickup point unless the latest user message explicitly gives another origin.",
        "Do not reuse a previous route origin from browser tabs, history, Web MCP, or memory when exact browser location is present. You may reuse known home/work addresses only as destinations when they match the user's latest wording.",
      );
    } else {
      const locationParts = [
        metadata.location.city,
        metadata.location.region,
        metadata.location.country,
      ].filter(Boolean);

      if (locationParts.length > 0) {
        lines.push(`Approximate user location from request metadata: ${locationParts.join(", ")}`);
      }
    }
  }

  if (lines.length === 0) return "";

  return [
    "User runtime metadata is available for time/date/location-aware answers.",
    "Treat request-derived location as approximate. Do not claim exact GPS location unless an explicit browser location source is present.",
    ...lines,
  ].join("\n");
}

function buildDecisionMemoryRuntimeContext(memory: DecisionMemory) {
  if (memory.recentSignals.length === 0) return "";

  const recent = memory.recentSignals
    .slice(-8)
    .map((signal) => `- ${signal.text}`)
    .join("\n");
  const lines = [
    "Decision memory is available as weak, user-specific context.",
    "Recent user messages that may contain choices, corrections, constraints, and preferences, oldest to newest:",
    recent,
    "Infer reusable preferences from these signals, but keep them provisional. If current evidence makes another option materially better, show that tradeoff instead of blindly following habit.",
  ];

  return lines.filter(Boolean).join("\n");
}

function formatUtcOffset(minutes: number) {
  const sign = minutes >= 0 ? "+" : "-";
  const absMinutes = Math.abs(minutes);
  const hours = String(Math.floor(absMinutes / 60)).padStart(2, "0");
  const restMinutes = String(absMinutes % 60).padStart(2, "0");
  return `${sign}${hours}:${restMinutes}`;
}

function cleanShortString(value: unknown, maxLength: number) {
  if (typeof value !== "string") return undefined;
  const cleaned = value.replace(/[\u0000-\u001f\u007f]/g, "").trim();
  return cleaned ? cleaned.slice(0, maxLength) : undefined;
}

function safeDecodeHeader(value: string | null) {
  if (!value) return null;
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}

function isValidLatitude(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value >= -90 && value <= 90;
}

function isValidLongitude(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value >= -180 && value <= 180;
}

function isValidIsoDateTime(value: unknown): value is string {
  return typeof value === "string" && value.length <= 80 && !Number.isNaN(Date.parse(value));
}

function roundCoordinate(value: number) {
  return Math.round(value * 1_000_000) / 1_000_000;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function buildCodexArgs(
  agent: Agent,
  priorConversation: string,
  latestUserMessage: string,
  runtimeContext: string,
  browserConnection: BrowserConnection,
) {
  const hasBrowserMcp = agent.capabilities.includes("chrome_browser") && Boolean(browserConnection.chromeMcpUrl);
  const args = [
    ...(agent.capabilities.includes("web_search") || agent.capabilities.includes("web_fetch")
      ? ["--search"]
      : []),
    ...(hasBrowserMcp
      ? [
          "-c",
          `mcp_servers.chrome.url=${JSON.stringify(browserConnection.chromeMcpUrl)}`,
          "-c",
          'mcp_servers.chrome.default_tools_approval_mode="approve"',
        ]
      : []),
    "-a",
    "never",
    "exec",
    "--json",
    "--ephemeral",
    "--ignore-rules",
    "--skip-git-repo-check",
    "--sandbox",
    getCodexSandbox(agent.capabilities),
    "--model",
    agent.model,
  ];

  args.push(buildCodexPrompt(agent, priorConversation, latestUserMessage, runtimeContext));
  return args;
}

function buildClaudeChromeMcpServer(url: string) {
  return isSseMcpUrl(url)
    ? {
        type: "sse" as const,
        url,
      }
    : {
        type: "http" as const,
        url,
      };
}

function isSseMcpUrl(url: string) {
  try {
    return new URL(url).pathname.endsWith("/sse");
  } catch {
    return url.endsWith("/sse");
  }
}

function buildCodexPrompt(
  agent: Agent,
  priorConversation: string,
  latestUserMessage: string,
  runtimeContext: string,
) {
  const capabilities = agent.capabilities.length > 0 ? agent.capabilities.join(", ") : "none";

  return [
    `You are the agent "${agent.name}".`,
    `You are running on model: ${agent.model}.`,
    agent.systemPrompt.trim() ? `System instructions:\n${agent.systemPrompt.trim()}` : null,
    runtimeContext.trim() ? `Runtime context:\n${runtimeContext.trim()}` : null,
    `Enabled capabilities: ${capabilities}.`,
    priorConversation.trim()
      ? `History (context only — do NOT re-execute prior tasks; treat completed tasks as done):\n${priorConversation.trim()}`
      : null,
    `Latest user message (respond to THIS message only):\n${latestUserMessage.trim()}`,
    "If the latest message is a meta or clarifying question (about you, your model, your prior answer, app settings, why something happened), answer it directly without using browser tools. Only run a new browser task if the latest message itself asks for one. Keep the answer user-facing and concise.",
  ]
    .filter(Boolean)
    .join("\n\n");
}

function getCodexSandbox(capabilities: Capability[]) {
  return capabilities.includes("file_write") || capabilities.includes("shell")
    ? "workspace-write"
    : "read-only";
}

function extractCodexError(codexError: string | null, stderr: string) {
  const parsedCodexError = parseEmbeddedJsonError(codexError);
  if (parsedCodexError) return parsedCodexError;

  const cleanStderr = stderr
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .filter((line) => !line.startsWith("202"))
    .filter((line) => !line.includes("WARN codex_"))
    .filter((line) => line !== "Reading additional input from stdin...")
    .join("\n")
    .slice(0, 1000);

  return cleanStderr || "Codex CLI завершился с ошибкой.";
}

function buildRuntimeContext(
  agent: Agent,
  user: User,
  browserConnection: BrowserConnection,
  userRuntimeMetadata: UserRuntimeMetadata,
  decisionMemory: DecisionMemory,
  provider: "claude" | "codex",
) {
  const userId = user.id;
  const lines: string[] = [
    "Always return a final user-visible task outcome.",
    "If the task is blocked, failed, or ambiguous, still answer with: what was verified, what the blocker is, and the exact next step needed from the user.",
    "Do not leave the user with only an internal error or a tool trace.",
  ];

  try {
    lines.push(buildIdentityRuntimeContext(user, agent));
  } catch (error) {
    console.warn("identity: failed to build runtime context", error);
  }

  const userContext = buildUserRuntimeContext(userRuntimeMetadata);
  if (userContext) {
    lines.push(userContext);
  }

  const decisionMemoryContext = buildDecisionMemoryRuntimeContext(decisionMemory);
  if (decisionMemoryContext) {
    lines.push(decisionMemoryContext);
  }

  if (agent.capabilities.includes("chrome_browser")) {
    if (browserConnection.chromeMcpUrl) {
      lines.push(
        "A live browser MCP server is connected for this user session.",
        "When the task depends on logged-in browser state, use the browser MCP tools to do the work instead of giving setup instructions.",
        "Browser MCP permissions are handled by the app runtime; do not ask the user to grant tool access in an external CLI.",
        "The currently active tab is only a starting point, not a limitation. If it is not the right service/page, use get_windows_and_tabs to find an existing relevant tab, chrome_switch_tab to activate it, or chrome_navigate to open the needed URL yourself.",
        "Do not ask the user to open a tab, switch tabs, navigate to a service, or prepare a page when browser tools can do that. Ask the user only for login/MFA/captcha, an ambiguous choice that cannot be resolved safely, or explicit confirmation before an irreversible final action.",
        "Browser execution loop: choose or open the target page, observe with chrome_read_page(filter=\"interactive\"), semantically match the target by role/name/text/href, act by ref with chrome_click_element/chrome_fill_or_select/chrome_computer, then verify the result with chrome_read_page or a screenshot.",
        "If the target is not exposed in chrome_read_page or an icon-only control is ambiguous, take a chrome_computer screenshot, infer coordinates from the screenshot, act carefully, and verify. After about three failed attempts, use chrome_request_element_selection instead of guessing.",
        "Prefer refs from chrome_read_page over coordinates. Use coordinates only for visual-only controls, canvas-like UI, or when refs are missing/expired.",
        "For any task that involves choosing, planning, comparing, scheduling, purchasing, booking, routing, or other decisions, first gather the practical options available through the relevant browser surface instead of asking generic preference questions.",
        "Compare options using the dimensions exposed by the source and implied by the user goal, such as time, cost, availability, quality, risk, convenience, constraints, and reversibility. Then give a concise recommendation plus the best alternatives.",
        "Infer preferences from the user's accepted choices, rejected options, corrections, constraints, and repeated decisions. Treat those signals as weak memory: use them to rank future options, but adapt when current evidence or the user's latest wording points elsewhere.",
        "Account integration, OAuth, API key, PAT, and token provisioning requests are browser-grounded tasks. Treat the user's latest request as permission to navigate the normal account UI and prepare the integration flow in the logged-in browser; do not refuse solely because the page lives in account settings.",
        "For token/API-key provisioning, prefer OAuth or a GitHub App-style install flow when the target integration supports it. If the user explicitly asks for a token, choose the narrowest scopes, selected repositories/resources, and short expiration that satisfy the stated task.",
        "Before clicking a final security-sensitive action that creates, reveals, grants, or installs a token/app, stop and ask for explicit confirmation with the service, destination/integration, selected resources, scopes, and expiration. Do not bypass login, MFA, passkey user presence, captcha, or GitHub confirmation prompts.",
        "After a token is generated, treat the raw value as a secret. Do not paste raw tokens into chat, memory, task titles, or trace. If a target integration form is open in the browser, paste the token directly there and verify the connection. Otherwise tell the user the token is visible on the service page and should be copied into the secure destination.",
        "For GitHub specifically, open the relevant OAuth/GitHub App install page when available; otherwise use https://github.com/settings/personal-access-tokens/new for fine-grained PATs. Do not answer that you cannot create a GitHub token merely because PATs are created in the user's profile.",
        ...(hasCredentialBroker(agent, browserConnection)
          ? [
              provider === "claude"
                ? "Credential broker is available as the meta_credentials MCP tool request_credential_approval."
                : "Credential broker is available through the app runtime. If a password, passkey, saved credential, or session-confirmation gate blocks the task, report the origin/current URL and exact credential action needed; the runtime can request user approval and retry.",
              "When login is blocked by a saved password, passkey, or credential choice, request broker approval instead of asking the user to paste a password into chat.",
              "The credential broker may pause the task for UI approval. It never returns plaintext secrets to you. After approval, continue through the live browser session. If OS autofill, passkey user presence, MFA, captcha, or a missing saved credential still blocks progress, report that exact blocker.",
            ]
          : []),
        "For public websites, after each meaningful landing page call chrome_get_web_content with textContent=true or chrome_read_page so the app can record Web MCP memory automatically for faster future runs.",
        "For irreversible actions such as sending, deleting, archiving, purchasing, or placing an order, stop at the final confirmation screen and ask the user for explicit confirmation before the final action.",
        "Do not mention external CLI setup unless the user explicitly asks for implementation details."
      );
    } else {
      lines.push(
        "IMPORTANT: No live browser MCP server is configured for this user session yet.",
        "Do not claim that you can open Gmail, click in Chrome, or inspect logged-in browser tabs.",
        "Do not mention local CLI setup steps or Chrome MCP installation instructions unless the user explicitly asks about implementation details.",
        "If the user's request depends on browser access, briefly say that browser access is not configured in this app/session yet and point them to in-app browser settings."
      );
    }
  }

  const shouldExposeWebMemoryRoot =
    agent.capabilities.includes("chrome_browser") ||
    (agent.capabilities.includes("file_write") &&
      (agent.capabilities.includes("web_fetch") || agent.capabilities.includes("web_search")));

  if (shouldExposeWebMemoryRoot) {
    lines.push(buildWebMcpRuntimeContext(userId, agent.capabilities.includes("chrome_browser") && Boolean(browserConnection.chromeMcpUrl)));
  }

  return lines.join("\n");
}

function parseEmbeddedJsonError(raw: string | null) {
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw) as { error?: { message?: string } };
    return parsed.error?.message ?? raw;
  } catch {
    return raw;
  }
}

export async function DELETE(req: NextRequest, ctx: Ctx) {
  const user = getUserFromRequest(req);
  if (!user) return unauthorizedJson();

  const { id } = await ctx.params;
  const fromMessageId = req.nextUrl.searchParams.get("fromMessageId");
  if (fromMessageId) {
    const ok = truncateMessagesFrom(id, user.id, fromMessageId);
    if (!ok) return Response.json({ error: "message_not_found" }, { status: 404 });
    return new Response(null, { status: 204 });
  }

  const { clearMessages } = await import("@/server/db");
  clearMessages(id, user.id);
  return new Response(null, { status: 204 });
}
