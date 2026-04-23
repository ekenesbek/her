import { NextRequest } from "next/server";
import { spawn } from "node:child_process";
import { query } from "@anthropic-ai/claude-agent-sdk";
import { getUserFromRequest, unauthorizedJson } from "@/lib/auth";
import { appendMessage, getAgent, listMessages } from "@/lib/db";
import { capabilitiesToTools } from "@/lib/capabilities";
import type { Agent, Capability } from "@/lib/types";
import { getModelProvider } from "@/lib/types";

export const runtime = "nodejs";

type Ctx = { params: Promise<{ id: string }> };

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

  const { message } = (await req.json()) as { message: string };
  if (!message?.trim()) return Response.json({ error: "empty_message" }, { status: 400 });

  appendMessage(id, user.id, "user", message);

  const history = listMessages(id, user.id);
  const conversation = history
    .map((m) => `${m.role === "user" ? "User" : "Assistant"}: ${m.content}`)
    .join("\n\n");
  const runtimeContext = buildRuntimeContext(agent, user.id);

  const encoder = new TextEncoder();
  const stream = new ReadableStream({
    async start(controller) {
      const send = (event: string, data: unknown) => {
        controller.enqueue(encoder.encode(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`));
      };

      let full = "";
      try {
        if (getModelProvider(agent.model) === "codex") {
          full = await streamCodexReply({
            agent,
            conversation,
            runtimeContext,
            send,
            signal: req.signal,
          });
        } else {
          full = await streamClaudeReply({
            agent,
            conversation,
            runtimeContext,
            send,
          });
        }
      } catch (err) {
        const errMsg = err instanceof Error ? err.message : String(err);
        send("error", { message: errMsg });
      } finally {
        if (full) appendMessage(id, user.id, "assistant", full);
        controller.close();
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

async function streamClaudeReply({
  agent,
  conversation,
  runtimeContext,
  send,
}: {
  agent: Agent;
  conversation: string;
  runtimeContext: string;
  send: (event: string, data: unknown) => void;
}) {
  const tools = capabilitiesToTools(agent.capabilities);
  let full = "";

  const q = query({
    prompt: conversation,
    options: {
      model: agent.model,
      systemPrompt: [agent.systemPrompt.trim(), runtimeContext.trim()].filter(Boolean).join("\n\n") || undefined,
      allowedTools: tools,
    },
  });

  for await (const msg of q) {
    if (msg.type === "assistant") {
      const content = msg.message?.content;
      if (Array.isArray(content)) {
        for (const block of content) {
          if (block.type === "text" && block.text) {
            full += block.text;
            send("delta", { text: block.text });
          } else if (block.type === "tool_use") {
            send("tool", { name: block.name, input: block.input });
          }
        }
      }
    } else if (msg.type === "result") {
      send("done", {});
    }
  }

  return full;
}

async function streamCodexReply({
  agent,
  conversation,
  runtimeContext,
  send,
  signal,
}: {
  agent: Agent;
  conversation: string;
  runtimeContext: string;
  send: (event: string, data: unknown) => void;
  signal?: AbortSignal;
}) {
  const args = buildCodexArgs(agent, conversation, runtimeContext);
  const child = spawn("codex", args, {
    cwd: process.cwd(),
    env: process.env,
    stdio: ["ignore", "pipe", "pipe"],
  });

  let stdoutBuffer = "";
  let stderrBuffer = "";
  let finalMessage = "";
  let codexError: string | null = null;

  signal?.addEventListener("abort", () => {
    child.kill("SIGTERM");
  }, { once: true });

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
      const payload = event as {
        type?: string;
        message?: string;
        error?: { message?: string };
        item?: {
          type?: string;
          text?: string;
          command?: string;
        };
      };

      if (payload.type === "item.started" && payload.item?.type === "command_execution") {
        send("tool", { name: "Shell", input: payload.item.command ?? "" });
      }

      if (payload.type === "item.completed" && payload.item?.type === "agent_message" && payload.item.text) {
        finalMessage = payload.item.text;
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

  const exitCode = await new Promise<number>((resolve, reject) => {
    child.on("error", reject);
    child.on("close", resolve);
  });

  if (stdoutBuffer.trim()) {
    try {
      const payload = JSON.parse(stdoutBuffer.trim()) as {
        type?: string;
        item?: { type?: string; text?: string };
      };
      if (payload.type === "item.completed" && payload.item?.type === "agent_message" && payload.item.text) {
        finalMessage = payload.item.text;
      }
    } catch {
      // Ignore incomplete tail.
    }
  }

  if (exitCode !== 0) {
    throw new Error(extractCodexError(codexError, stderrBuffer));
  }

  if (!finalMessage.trim()) {
    throw new Error("Codex не вернул итоговый ответ.");
  }

  send("delta", { text: finalMessage });
  send("done", {});
  return finalMessage;
}

function buildCodexArgs(agent: Agent, conversation: string, runtimeContext: string) {
  const args = [
    ...(agent.capabilities.includes("web_search") || agent.capabilities.includes("web_fetch")
      ? ["--search"]
      : []),
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

  args.push(buildCodexPrompt(agent, conversation, runtimeContext));
  return args;
}

function buildCodexPrompt(agent: Agent, conversation: string, runtimeContext: string) {
  const capabilities = agent.capabilities.length > 0 ? agent.capabilities.join(", ") : "none";

  return [
    `You are the agent "${agent.name}".`,
    agent.systemPrompt.trim() ? `System instructions:\n${agent.systemPrompt.trim()}` : null,
    runtimeContext.trim() ? `Runtime context:\n${runtimeContext.trim()}` : null,
    `Enabled capabilities: ${capabilities}.`,
    "Conversation so far:",
    conversation,
    "Respond to the latest user message. Keep the answer user-facing and concise.",
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

function buildRuntimeContext(agent: Agent, userId: string) {
  const shouldExposeWebMemoryRoot =
    agent.capabilities.includes("file_write") &&
    (agent.capabilities.includes("web_fetch") || agent.capabilities.includes("web_search"));

  if (!shouldExposeWebMemoryRoot) return "";

  return [
    "Persistent web memory is available in this workspace.",
    `User-scoped root: .data/web-mcp/users/${userId}/sites/`,
    "If you are mapping a website, keep site artifacts there so the Web MCP UI can reuse them.",
  ].join("\n");
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
  const { clearMessages } = await import("@/lib/db");
  clearMessages(id, user.id);
  return new Response(null, { status: 204 });
}
