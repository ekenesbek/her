"use client";

import { useEffect, useRef, useState } from "react";
import Link from "next/link";
import type {
  Agent,
  BrowserConnection,
  ChatMessage,
  CredentialRequest,
  TaskArtifact,
  TaskEvent,
  TaskRunSnapshot,
  ToolTraceEntry,
  UserRuntimeLocation,
  UserRuntimeMetadata,
} from "@/shared/types";
import { readStoredExactLocation } from "@/client/location";
import { MODEL_LABELS } from "@/shared/types";

type StreamState = {
  streaming: boolean;
  current: string;
  toolCalls: ToolTraceEntry[];
  taskRun?: TaskRunSnapshot;
};

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

export default function ChatClient({
  agent,
  initialMessages,
  browserConnection,
}: {
  agent: Agent;
  initialMessages: ChatMessage[];
  browserConnection: BrowserConnection;
}) {
  const [messages, setMessages] = useState<ChatMessage[]>(initialMessages);
  const [input, setInput] = useState("");
  const [stream, setStream] = useState<StreamState>({ streaming: false, current: "", toolCalls: [] });
  const [error, setError] = useState<string | null>(null);
  const [now, setNow] = useState(0);
  const scrollRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    scrollRef.current?.scrollTo({ top: scrollRef.current.scrollHeight, behavior: "smooth" });
  }, [messages, stream]);

  useEffect(() => {
    if (!stream.streaming) return;
    const interval = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(interval);
  }, [stream.streaming]);

  useEffect(() => {
    if (stream.streaming || !messages.some((message) => isActiveTaskRun(message.taskRun))) return;

    const interval = window.setInterval(async () => {
      try {
        const res = await fetch(`/api/chat/${agent.id}`, { cache: "no-store" });
        if (!res.ok) return;
        const next = (await res.json()) as ChatMessage[];
        setMessages(next);
      } catch {
        // Keep the current local view; the next poll can recover.
      }
    }, 2000);

    return () => window.clearInterval(interval);
  }, [agent.id, messages, stream.streaming]);

  async function send() {
    const text = input.trim();
    if (!text || stream.streaming) return;
    setInput("");
    setError(null);
    setNow(Date.now());
    const userMsg: ChatMessage = {
      id: crypto.randomUUID(),
      agentId: agent.id,
      role: "user",
      content: text,
      createdAt: Date.now(),
    };
    setMessages((m) => [...m, userMsg]);
    setStream({ streaming: true, current: "", toolCalls: [] });

    try {
      const res = await fetch(`/api/chat/${agent.id}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ message: text, runtimeMetadata: collectUserRuntimeMetadata(readStoredExactLocation()) }),
      });
      if (!res.ok || !res.body) throw new Error(`HTTP ${res.status}`);

      const reader = res.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";
      let accumulated = "";
      let toolTrace: ToolTraceEntry[] = [];
      let taskRun: TaskRunSnapshot | undefined;

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        const events = buffer.split("\n\n");
        buffer = events.pop() ?? "";

        for (const evt of events) {
          const lines = evt.split("\n");
          let event = "";
          let data = "";
          for (const l of lines) {
            if (l.startsWith("event: ")) event = l.slice(7);
            if (l.startsWith("data: ")) data += l.slice(6);
          }
          if (!event) continue;
          const payload = data ? JSON.parse(data) : {};
          if (event === "delta") {
            accumulated += payload.text;
            setStream((s) => ({ ...s, current: accumulated }));
          } else if (event === "replace") {
            accumulated = payload.text;
            setStream((s) => ({ ...s, current: accumulated }));
          } else if (event === "tool") {
            toolTrace = applyToolEvent(toolTrace, payload as ToolEvent);
            setStream((s) => ({ ...s, toolCalls: applyToolEvent(s.toolCalls, payload as ToolEvent) }));
          } else if (event === "task") {
            taskRun = applyTaskStreamEvent(taskRun, payload as TaskStreamEvent);
            setStream((s) => ({ ...s, taskRun: applyTaskStreamEvent(s.taskRun, payload as TaskStreamEvent) }));
          } else if (event === "error") {
            setError(payload.message || "Ошибка");
          }
        }
      }

      if (accumulated) {
        const assistantMsg: ChatMessage = {
          id: crypto.randomUUID(),
          agentId: agent.id,
          role: "assistant",
          content: accumulated,
          toolTrace,
          ...(taskRun ? { taskRun } : {}),
          createdAt: Date.now(),
        };
        setMessages((m) => [...m, assistantMsg]);
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : "Ошибка запроса");
    } finally {
      setStream({ streaming: false, current: "", toolCalls: [] });
    }
  }

  async function clearHistory() {
    if (!confirm("Очистить историю чата?")) return;
    await fetch(`/api/chat/${agent.id}`, { method: "DELETE" });
    setMessages([]);
  }

  return (
    <div className="flex-1 flex flex-col h-[calc(100vh-65px)]">
      <div className="border-b border-[var(--border)] px-6 py-3 flex items-center gap-3">
        <div className="text-2xl">{agent.emoji}</div>
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2">
            <div className="font-semibold truncate">{agent.name}</div>
            <span className="text-[10px] uppercase tracking-wide text-[var(--fg-dim)]">
              {MODEL_LABELS[agent.model].label}
            </span>
          </div>
          {agent.description && (
            <div className="text-xs text-[var(--fg-muted)] truncate">{agent.description}</div>
          )}
        </div>
        <button className="btn btn-ghost text-xs" onClick={clearHistory}>Очистить</button>
        <Link href={`/agents/${agent.id}`} className="btn btn-secondary text-xs">Настройки</Link>
      </div>

      <div ref={scrollRef} className="flex-1 overflow-y-auto px-6 py-6">
        <div className="max-w-3xl mx-auto space-y-4">
          {agent.capabilities.includes("chrome_browser") && (
            <BrowserBanner browserConnection={browserConnection} />
          )}
          {messages.length === 0 && !stream.streaming && (
            <div className="text-center text-[var(--fg-muted)] py-20">
              Напиши первое сообщение — {agent.name.toLowerCase()} ждёт.
            </div>
          )}
          {messages.map((m) => (
            <MessageBubble key={m.id} message={m} now={now} />
          ))}
          {stream.streaming && (
            <MessageBubble
              message={{
                id: "streaming",
                agentId: agent.id,
                role: "assistant",
                content: stream.current || "…",
                ...(stream.taskRun ? { taskRun: stream.taskRun } : {}),
                createdAt: 0,
              }}
              streaming
              tools={stream.toolCalls}
              now={now}
            />
          )}
          {error && (
            <div className="card p-4 border-[var(--danger)] text-[var(--danger)] text-sm">
              Ошибка: {error}
            </div>
          )}
        </div>
      </div>

      <div className="border-t border-[var(--border)] p-4">
        <div className="max-w-3xl mx-auto space-y-2">
          <div className="flex gap-2 items-end">
            <textarea
              className="input flex-1 resize-none min-h-[48px] max-h-40"
              placeholder={`Написать ${agent.name.toLowerCase()}…`}
              value={input}
              onChange={(e) => setInput(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter" && !e.shiftKey) {
                  e.preventDefault();
                  send();
                }
              }}
              rows={1}
            />
            <button
              className="btn btn-primary !px-5 !py-3"
              onClick={send}
              disabled={!input.trim() || stream.streaming}
            >
              {stream.streaming ? "…" : "↑"}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}

function applyToolEvent(current: ToolTraceEntry[], event: ToolEvent) {
  if (event.phase === "call") {
    const next = current.filter((entry) => entry.id !== event.id);
    return [
      ...next,
      {
        id: event.id,
        name: event.name,
        input: event.input,
        startedAt: event.startedAt,
      },
    ];
  }

  const index = current.findIndex((entry) => entry.id === event.id);
  if (index < 0) {
    return [
      ...current,
      {
        id: event.id,
        name: "tool_result",
        result: event.result,
        ...(event.artifacts && event.artifacts.length > 0 ? { artifacts: event.artifacts } : {}),
        isError: event.isError,
        startedAt: event.completedAt,
        completedAt: event.completedAt,
      },
    ];
  }

  return current.map((entry, i) =>
    i === index
      ? {
          ...entry,
          result: event.result,
          ...(event.artifacts && event.artifacts.length > 0 ? { artifacts: event.artifacts } : {}),
          isError: event.isError,
          completedAt: event.completedAt,
        }
      : entry,
  );
}

function applyTaskStreamEvent(current: TaskRunSnapshot | undefined, event: TaskStreamEvent) {
  if (event.type === "snapshot") return event.taskRun;
  if (!current) return current;

  if (event.type === "event") {
    return {
      ...current,
      events: upsertById(current.events, event.event),
    };
  }

  return {
    ...current,
    artifacts: upsertById(current.artifacts, ...event.artifacts),
    events: upsertById(current.events, ...event.events),
  };
}

function upsertById<T extends { id: string }>(items: T[], ...updates: T[]) {
  const next = [...items];

  for (const update of updates) {
    const index = next.findIndex((item) => item.id === update.id);
    if (index >= 0) {
      next[index] = update;
    } else {
      next.push(update);
    }
  }

  return next;
}

function isActiveTaskRun(taskRun?: TaskRunSnapshot) {
  return Boolean(
    taskRun &&
      taskRun.status !== "done" &&
      taskRun.status !== "failed" &&
      taskRun.status !== "cancelled",
  );
}

function collectUserRuntimeMetadata(location?: UserRuntimeLocation): UserRuntimeMetadata {
  const resolved = Intl.DateTimeFormat().resolvedOptions();
  const now = new Date();

  return {
    locale: resolved.locale || navigator.language,
    languages: Array.from(navigator.languages ?? []),
    timeZone: resolved.timeZone,
    localTime: formatLocalDateTime(now),
    utcOffsetMinutes: -now.getTimezoneOffset(),
    calendar: resolved.calendar,
    hourCycle: resolved.hourCycle,
    platform: navigator.platform,
    ...(location ? { location } : {}),
  };
}

function formatLocalDateTime(date: Date) {
  const offsetMinutes = -date.getTimezoneOffset();
  const sign = offsetMinutes >= 0 ? "+" : "-";
  const absOffset = Math.abs(offsetMinutes);
  const offsetHours = String(Math.floor(absOffset / 60)).padStart(2, "0");
  const offsetRestMinutes = String(absOffset % 60).padStart(2, "0");
  const local = new Date(date.getTime() + offsetMinutes * 60_000).toISOString().slice(0, 19);

  return `${local}${sign}${offsetHours}:${offsetRestMinutes}`;
}

function BrowserBanner({ browserConnection }: { browserConnection: BrowserConnection }) {
  const connected = Boolean(browserConnection.chromeMcpUrl);

  return (
    <div
      className={`card p-4 ${
        connected
          ? "border-[var(--accent)] bg-[var(--accent-soft)]"
          : "border-[var(--border)]"
      }`}
    >
      <div className="flex items-start justify-between gap-3">
        <div>
          <div className="text-sm font-medium">
            {connected ? "Браузер подключён" : "Браузер не подключён"}
          </div>
          <div className="text-xs text-[var(--fg-muted)] mt-1 leading-relaxed">
            {browserConnection.source === "user" && "Этот агент может использовать твою подключённую Chrome-сессию."}
            {browserConnection.source === "env" && "Этот агент использует глобально настроенную Chrome-сессию."}
            {browserConnection.source === "none" && "Чтобы агент реально открывал Gmail и другие залогиненные сервисы, сначала подключи Chrome MCP в настройках приложения."}
          </div>
        </div>
        {!connected && (
          <Link href="/settings/browser" className="btn btn-secondary text-xs whitespace-nowrap">
            Подключить
          </Link>
        )}
      </div>
    </div>
  );
}

function MessageBubble({
  message,
  streaming,
  tools,
  now,
}: {
  message: ChatMessage;
  streaming?: boolean;
  tools?: ToolTraceEntry[];
  now: number;
}) {
  const isUser = message.role === "user";
  return (
    <div className={`flex ${isUser ? "justify-end" : "justify-start"}`}>
      <div
        className={`max-w-[85%] rounded-2xl px-4 py-3 ${
          isUser
            ? "bg-[var(--accent)] text-black"
            : "bg-[var(--bg-soft)] border border-[var(--border)]"
        }`}
      >
        <TaskRunTimeline taskRun={message.taskRun} now={now} />
        <ToolTrace trace={tools ?? message.toolTrace} />
        <div className="whitespace-pre-wrap text-sm leading-relaxed">
          {message.content}
          {streaming && <span className="inline-block w-2 h-4 bg-current ml-0.5 animate-pulse" />}
        </div>
      </div>
    </div>
  );
}

function TaskRunTimeline({ taskRun, now }: { taskRun?: TaskRunSnapshot; now: number }) {
  if (!taskRun) return null;

  const completed = taskRun.status === "done" || taskRun.status === "failed" || taskRun.status === "cancelled";
  const elapsedUntil = taskRun.completedAt ?? (now || taskRun.startedAt);
  const elapsedMs = taskRun.durationMs ?? elapsedUntil - taskRun.startedAt;
  const lastEvent = taskRun.events.at(-1);

  return (
    <details
      open={!completed}
      className="mb-3 rounded-xl border border-[var(--border)] bg-[var(--bg-softer)]"
    >
      <summary className="cursor-pointer select-none px-3 py-2 text-[11px] text-[var(--fg-muted)]">
        <span className="font-medium text-[var(--fg)]">{taskStatusLabel(taskRun.status)}</span>
        <span className="ml-2">{formatDuration(elapsedMs)}</span>
        <span className="ml-2">{taskRun.events.length} шагов</span>
        {taskRun.artifacts.length > 0 && <span className="ml-2">{taskRun.artifacts.length} скринов</span>}
        {lastEvent && <span className="block mt-1 truncate">{lastEvent.title}</span>}
      </summary>
      <div className="border-t border-[var(--border)] p-3 space-y-3">
        {taskRun.artifacts.length > 0 && (
          <div className="grid grid-cols-2 gap-2">
            {taskRun.artifacts.map((artifact) => (
              <a
                key={artifact.id}
                href={artifact.url}
                target="_blank"
                rel="noreferrer"
                className="overflow-hidden rounded-lg border border-[var(--border)] bg-[var(--bg)]"
              >
                {/* eslint-disable-next-line @next/next/no-img-element */}
                <img src={artifact.url} alt={artifact.label} className="h-28 w-full object-contain p-1" />
                <div className="truncate border-t border-[var(--border)] px-2 py-1 text-[10px] text-[var(--fg-muted)]">
                  {formatTime(artifact.createdAt)} · {formatBytes(artifact.byteSize)}
                </div>
              </a>
            ))}
          </div>
        )}
        <div className="space-y-2">
          {taskRun.events.map((event, index) => (
            <TaskEventRow key={event.id} event={event} index={index} />
          ))}
        </div>
      </div>
    </details>
  );
}

function TaskEventRow({ event, index }: { event: TaskEvent; index: number }) {
  const credentialRequest = getCredentialRequestFromDetails(event.details);

  return (
    <div className="flex gap-2 rounded-lg border border-[var(--border)] bg-[var(--bg-soft)] px-3 py-2 text-[11px]">
      <div className="w-5 shrink-0 font-mono text-[var(--fg-muted)]">{index + 1}</div>
      <div className="min-w-0 flex-1">
        <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
          <span className="font-medium text-[var(--fg)]">{event.title}</span>
          <span className="text-[var(--fg-muted)]">{formatTime(event.createdAt)}</span>
          {event.durationMs !== undefined && (
            <span className="text-[var(--fg-muted)]">{formatDuration(event.durationMs)}</span>
          )}
        </div>
        {credentialRequest && <CredentialApprovalCard request={credentialRequest} />}
        {event.details && !credentialRequest && (
          <pre className="mt-1 max-h-32 overflow-auto whitespace-pre-wrap break-words text-[10px] leading-relaxed text-[var(--fg-muted)]">
            {stringifyToolValue(event.details)}
          </pre>
        )}
      </div>
    </div>
  );
}

type CredentialRequestView = Pick<
  CredentialRequest,
  | "id"
  | "origin"
  | "currentUrl"
  | "accountHint"
  | "reason"
  | "requestedAction"
  | "status"
  | "createdAt"
  | "expiresAt"
  | "resolvedAt"
>;

function CredentialApprovalCard({ request }: { request: CredentialRequestView }) {
  const [status, setStatus] = useState(request.status);
  const [busy, setBusy] = useState<"approve" | "deny" | null>(null);
  const [error, setError] = useState<string | null>(null);
  const pending = status === "pending";

  async function decide(decision: "approve" | "deny") {
    if (!pending || busy) return;
    setBusy(decision);
    setError(null);
    try {
      const res = await fetch(`/api/credential-requests/${request.id}`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ decision }),
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const payload = (await res.json()) as { request: CredentialRequestView };
      setStatus(payload.request.status);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Не удалось отправить решение");
    } finally {
      setBusy(null);
    }
  }

  return (
    <div className="mt-2 rounded-lg border border-[var(--accent)] bg-[var(--accent-soft)] p-3 text-xs">
      <div className="font-medium text-[var(--fg)]">Credential approval</div>
      <div className="mt-1 text-[var(--fg-muted)] leading-relaxed">
        {credentialActionLabel(request.requestedAction)} для <span className="font-mono">{request.origin}</span>
        {request.accountHint ? <> · {request.accountHint}</> : null}
      </div>
      <div className="mt-2 text-[var(--fg-muted)] leading-relaxed">{request.reason}</div>
      {request.currentUrl && (
        <div className="mt-2 break-all font-mono text-[10px] text-[var(--fg-dim)]">{request.currentUrl}</div>
      )}
      <div className="mt-3 flex flex-wrap items-center gap-2">
        <span className={`chip ${status === "approved" ? "chip-active" : ""}`}>{credentialStatusLabel(status)}</span>
        {pending && (
          <>
            <button className="btn btn-primary !py-1.5 !px-3 text-xs" onClick={() => decide("approve")} disabled={Boolean(busy)}>
              {busy === "approve" ? "Разрешаю..." : "Разрешить"}
            </button>
            <button className="btn btn-secondary !py-1.5 !px-3 text-xs" onClick={() => decide("deny")} disabled={Boolean(busy)}>
              {busy === "deny" ? "Отклоняю..." : "Отклонить"}
            </button>
          </>
        )}
      </div>
      {error && <div className="mt-2 text-[var(--danger)]">{error}</div>}
    </div>
  );
}

function ToolTrace({ trace }: { trace?: ToolTraceEntry[] }) {
  if (!trace || trace.length === 0) return null;

  const browserActions = trace.filter((entry) => entry.name.startsWith("mcp__chrome__"));
  const title = browserActions.length === trace.length ? "Browser actions" : "Tool calls";
  const path = trace.map((entry) => shortToolName(entry.name)).join(" → ");

  return (
    <details className="mb-3 rounded-xl border border-[var(--border)] bg-[var(--bg-softer)]">
      <summary className="cursor-pointer select-none px-3 py-2 text-[11px] text-[var(--fg-muted)]">
        <span className="font-medium text-[var(--fg)]">{title}</span>
        <span className="ml-2">{trace.length} calls</span>
        <span className="block mt-1 font-mono truncate">{path}</span>
      </summary>
      <div className="border-t border-[var(--border)] p-2 space-y-2">
        {trace.map((entry, index) => (
          <ToolTraceEntryView key={`${entry.id}-${index}`} entry={entry} index={index} />
        ))}
      </div>
    </details>
  );
}

function ToolTraceEntryView({ entry, index }: { entry: ToolTraceEntry; index: number }) {
  const status = entry.completedAt ? (entry.isError ? "error" : "done") : "running";

  return (
    <details className="rounded-lg border border-[var(--border)] bg-[var(--bg-soft)]">
      <summary className="cursor-pointer select-none px-3 py-2 text-[11px]">
        <span className="font-mono text-[var(--fg)]">
          {index + 1}. {shortToolName(entry.name)}
        </span>
        <span className="ml-2 text-[var(--fg-muted)]">{status}</span>
      </summary>
      <div className="border-t border-[var(--border)] p-3 space-y-2">
        {entry.artifacts && entry.artifacts.length > 0 && (
          <div className="grid grid-cols-2 gap-2">
            {entry.artifacts.map((artifact) => (
              <a
                key={artifact.id}
                href={artifact.url}
                target="_blank"
                rel="noreferrer"
                className="overflow-hidden rounded-md border border-[var(--border)] bg-[var(--bg)]"
              >
                {/* eslint-disable-next-line @next/next/no-img-element */}
                <img src={artifact.url} alt={artifact.label} className="h-32 w-full object-contain p-1" />
              </a>
            ))}
          </div>
        )}
        <ToolValue title="input" value={entry.input} />
        {"result" in entry && <ToolValue title={entry.isError ? "error result" : "result"} value={entry.result} />}
        <ToolValue title="raw trace" value={entry} collapsed />
      </div>
    </details>
  );
}

function ToolValue({
  title,
  value,
  collapsed = false,
}: {
  title: string;
  value: unknown;
  collapsed?: boolean;
}) {
  if (value === undefined) return null;

  return (
    <details open={!collapsed} className="rounded-md border border-[var(--border)] bg-[var(--bg)]">
      <summary className="cursor-pointer select-none px-2 py-1 text-[10px] uppercase tracking-wide text-[var(--fg-muted)]">
        {title}
      </summary>
      <div className="border-t border-[var(--border)] p-2 space-y-2">
        <ToolRichValue value={value} />
        <pre className="max-h-96 overflow-auto whitespace-pre-wrap break-words rounded bg-black/5 p-2 text-[10px] leading-relaxed text-[var(--fg-muted)]">
          {stringifyToolValue(value)}
        </pre>
      </div>
    </details>
  );
}

function ToolRichValue({ value }: { value: unknown }) {
  const blocks = Array.isArray(value) ? value : isRecord(value) && Array.isArray(value.content) ? value.content : [];
  if (blocks.length === 0) return null;

  return (
    <div className="space-y-2">
      {blocks.map((block, index) => (
        <ToolContentBlock key={index} block={block} />
      ))}
    </div>
  );
}

function ToolContentBlock({ block }: { block: unknown }) {
  if (!isRecord(block)) return null;

  if (block.type === "text" && typeof block.text === "string") {
    return (
      <pre className="max-h-72 overflow-auto whitespace-pre-wrap break-words rounded border border-[var(--border)] p-2 text-[11px] leading-relaxed">
        {block.text}
      </pre>
    );
  }

  const imageSrc = getImageSrc(block);
  if (imageSrc) {
    return (
      <details className="rounded border border-[var(--border)]">
        <summary className="cursor-pointer select-none px-2 py-1 text-[10px] text-[var(--fg-muted)]">
          screenshot/image
        </summary>
        {/* Tool screenshots arrive as data URLs, so Next Image cannot optimize them. */}
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img src={imageSrc} alt="Tool screenshot" className="max-h-[520px] w-full object-contain p-2" />
      </details>
    );
  }

  return null;
}

function getImageSrc(block: Record<string, unknown>) {
  if (block.type !== "image") return null;

  if (typeof block.data === "string") {
    const mimeType = typeof block.mimeType === "string" ? block.mimeType : "image/png";
    return `data:${mimeType};base64,${block.data}`;
  }

  if (isRecord(block.source) && block.source.type === "base64" && typeof block.source.data === "string") {
    const mediaType = typeof block.source.media_type === "string" ? block.source.media_type : "image/png";
    return `data:${mediaType};base64,${block.source.data}`;
  }

  return null;
}

function taskStatusLabel(status: TaskRunSnapshot["status"]) {
  switch (status) {
    case "created":
      return "Создано";
    case "planning":
      return "Планирование";
    case "running":
      return "Выполняется";
    case "waiting_for_user":
      return "Ждёт подтверждения";
    case "done":
      return "Готово";
    case "failed":
      return "Ошибка";
    case "cancelled":
      return "Отменено";
  }
}

function formatDuration(ms: number) {
  const safeMs = Math.max(0, ms);
  const seconds = Math.floor(safeMs / 1000);
  const minutes = Math.floor(seconds / 60);
  const restSeconds = seconds % 60;

  if (minutes > 0) return `${minutes}m ${restSeconds}s`;
  if (seconds > 0) return `${seconds}s`;
  return `${safeMs}ms`;
}

function formatTime(timestamp: number) {
  return new Intl.DateTimeFormat("ru-RU", {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  }).format(timestamp);
}

function formatBytes(bytes: number) {
  if (bytes >= 1024 * 1024) return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
  if (bytes >= 1024) return `${Math.round(bytes / 1024)} KB`;
  return `${bytes} B`;
}

function shortToolName(name: string) {
  return name.replace(/^mcp__chrome__/, "");
}

function getCredentialRequestFromDetails(details: TaskEvent["details"]): CredentialRequestView | null {
  if (!details || !isRecord(details.credentialRequest)) return null;
  const request = details.credentialRequest;
  if (
    typeof request.id !== "string" ||
    typeof request.origin !== "string" ||
    typeof request.reason !== "string" ||
    !isCredentialAction(request.requestedAction) ||
    !isCredentialStatus(request.status) ||
    typeof request.createdAt !== "number" ||
    typeof request.expiresAt !== "number"
  ) {
    return null;
  }

  return {
    id: request.id,
    origin: request.origin,
    currentUrl: typeof request.currentUrl === "string" ? request.currentUrl : null,
    accountHint: typeof request.accountHint === "string" ? request.accountHint : null,
    reason: request.reason,
    requestedAction: request.requestedAction,
    status: request.status,
    createdAt: request.createdAt,
    expiresAt: request.expiresAt,
    resolvedAt: typeof request.resolvedAt === "number" ? request.resolvedAt : null,
  };
}

function isCredentialAction(value: unknown): value is CredentialRequest["requestedAction"] {
  return (
    value === "fill_password" ||
    value === "use_passkey" ||
    value === "reuse_session" ||
    value === "scheduled_read"
  );
}

function isCredentialStatus(value: unknown): value is CredentialRequest["status"] {
  return (
    value === "pending" ||
    value === "approved" ||
    value === "denied" ||
    value === "expired" ||
    value === "used"
  );
}

function credentialActionLabel(action: CredentialRequest["requestedAction"]) {
  switch (action) {
    case "fill_password":
      return "Ввод сохранённого пароля";
    case "use_passkey":
      return "Использование passkey";
    case "reuse_session":
      return "Использование существующей сессии";
    case "scheduled_read":
      return "Scheduled read-only доступ";
  }
}

function credentialStatusLabel(status: CredentialRequest["status"]) {
  switch (status) {
    case "pending":
      return "ожидает";
    case "approved":
      return "разрешено";
    case "denied":
      return "отклонено";
    case "expired":
      return "истекло";
    case "used":
      return "использовано";
  }
}

function stringifyToolValue(value: unknown) {
  if (typeof value === "string") return value;

  try {
    return JSON.stringify(value, null, 2);
  } catch {
    return String(value);
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}
