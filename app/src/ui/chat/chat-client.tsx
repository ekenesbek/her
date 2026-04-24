"use client";

import { useEffect, useRef, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
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
import { useLang, t, type Lang } from "@/client/i18n";

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
  const router = useRouter();
  const [lang] = useLang();
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [messages, setMessages] = useState<ChatMessage[]>(initialMessages);
  const [input, setInput] = useState("");
  const [stream, setStream] = useState<StreamState>({ streaming: false, current: "", toolCalls: [] });
  const [error, setError] = useState<string | null>(null);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [queue, setQueue] = useState<string[]>([]);
  const [now, setNow] = useState(0);
  const scrollRef = useRef<HTMLDivElement>(null);
  const abortRef = useRef<AbortController | null>(null);
  const runGenerationRef = useRef<((text: string) => Promise<void>) | null>(null);

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
    if (!text) return;
    setInput("");
    if (stream.streaming) {
      setQueue((q) => [...q, text]);
      return;
    }
    await runGeneration(text);
  }

  function stop() {
    setQueue([]);
    abortRef.current?.abort();
  }

  function removeFromQueue(index: number) {
    setQueue((q) => q.filter((_, i) => i !== index));
  }

  async function submitEdit(messageId: string, newText: string) {
    const text = newText.trim();
    if (!text) return;
    if (stream.streaming) abortRef.current?.abort();
    setQueue([]);

    const index = messages.findIndex((m) => m.id === messageId);
    if (index < 0) return;

    setEditingId(null);
    setMessages((m) => m.slice(0, index));
    setError(null);

    try {
      const res = await fetch(
        `/api/chat/${agent.id}?fromMessageId=${encodeURIComponent(messageId)}`,
        { method: "DELETE" },
      );
      if (!res.ok && res.status !== 404) throw new Error(`HTTP ${res.status}`);
    } catch (e) {
      setError(e instanceof Error ? e.message : t(lang, "chat.error.http"));
      return;
    }

    await runGeneration(text);
  }

  useEffect(() => {
    runGenerationRef.current = runGeneration;
  });

  useEffect(() => {
    if (stream.streaming || queue.length === 0) return;
    const [next, ...rest] = queue;
    setQueue(rest);
    const run = runGenerationRef.current;
    if (run) void run(next);
  }, [stream.streaming, queue]);

  async function runGeneration(text: string) {
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

    const controller = new AbortController();
    abortRef.current = controller;
    let aborted = false;

    try {
      const res = await fetch(`/api/chat/${agent.id}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ message: text, runtimeMetadata: collectUserRuntimeMetadata(readStoredExactLocation()) }),
        signal: controller.signal,
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
      if (e instanceof DOMException && e.name === "AbortError") {
        aborted = true;
      } else {
        setError(e instanceof Error ? e.message : t(lang, "chat.error.http"));
      }
    } finally {
      if (abortRef.current === controller) abortRef.current = null;
      setStream({ streaming: false, current: "", toolCalls: [] });
      if (aborted) {
        try {
          const res = await fetch(`/api/chat/${agent.id}`, { cache: "no-store" });
          if (res.ok) setMessages((await res.json()) as ChatMessage[]);
        } catch {
          // ignore refresh failure
        }
      }
    }
  }

  async function clearHistory() {
    if (!confirm(t(lang, "chat.clearConfirm"))) return;
    await fetch(`/api/chat/${agent.id}`, { method: "DELETE" });
    setMessages([]);
  }

  async function logout() {
    await fetch("/api/auth/logout", { method: "POST" });
    router.replace("/login");
    router.refresh();
  }

  const msgCount = messages.length;
  const chromeConnected = Boolean(browserConnection.chromeMcpUrl);
  const chromeSrc =
    browserConnection.source === "user"
      ? t(lang, "chat.chrome.personal")
      : browserConnection.source === "env"
        ? t(lang, "chat.chrome.shared")
        : t(lang, "chat.chrome.notLinked");

  return (
    <div className="h-[100dvh] bg-[var(--bg)] relative">
      {/* Backdrop for mobile drawer */}
      {sidebarOpen && (
        <div
          className="fixed inset-0 z-30 bg-[var(--fg)]/30 md:hidden"
          onClick={() => setSidebarOpen(false)}
        />
      )}

      {/* Sidebar — fixed on all sizes, drawer-animated on mobile */}
      <aside
        className={`fixed top-0 left-0 bottom-0 z-40 w-[240px] md:w-[200px] border-r border-[var(--border)] bg-[var(--bg)] px-3 py-4 flex flex-col gap-2 transition-transform md:transition-none ${
          sidebarOpen ? "translate-x-0" : "-translate-x-full md:translate-x-0"
        }`}
      >
        <div className="flex items-center gap-2 px-1 mb-3">
          <span className="label-mono" style={{ fontSize: 11, color: "var(--fg)" }}>
            meta
          </span>
          <button
            type="button"
            onClick={() => setSidebarOpen(false)}
            aria-label="Close menu"
            className="md:hidden ml-auto label-mono p-1"
            style={{ fontSize: 14, color: "var(--fg-dim)" }}
          >
            ×
          </button>
        </div>

        <Link
          href={`/agents/${agent.id}`}
          className="flex items-center gap-2.5 px-1 py-2 mb-1 rounded-lg hover:bg-[var(--bg-soft)]"
        >
          <Avatar agent={agent} size={36} />
          <div className="min-w-0 flex-1">
            <div className="text-[12px] font-medium truncate">{agent.name}</div>
            <div className="label-mono mt-0.5" style={{ fontSize: 9 }}>
              {MODEL_LABELS[agent.model].label}
            </div>
          </div>
        </Link>

        <NavItem icon={<ChatIcon />} label={t(lang, "chat.nav.talk")} active />
        <NavItem icon={<LockIcon />} label={t(lang, "chat.nav.vault")} href="#" muted />
        <NavItem icon={<LayersIcon />} label={t(lang, "chat.nav.tasks")} href="#" muted />

        <div className="mt-auto flex flex-col gap-1.5">
          <Link
            href="/settings/browser"
            className="rounded-lg px-2.5 py-2 border border-[var(--border)] hover:border-[var(--border-strong)]"
          >
            <div className="flex items-center gap-1.5 label-mono" style={{ fontSize: 9 }}>
              <span
                className="w-1.5 h-1.5 rounded-full meta-pulse"
                style={{ background: chromeConnected ? "var(--success)" : "var(--fg-dim)" }}
              />
              Chrome · {chromeConnected ? t(lang, "chat.chrome.online") : t(lang, "chat.chrome.offline")}
            </div>
            <div className="label-mono mt-1" style={{ fontSize: 9 }}>
              {chromeSrc}
            </div>
          </Link>
          <NavItem
            icon={<SettingsIcon />}
            label={t(lang, "chat.nav.settings")}
            href={`/agents/${agent.id}`}
          />
          <button
            type="button"
            onClick={logout}
            className="label-mono text-left px-2 py-1 hover:text-[var(--fg)]"
            style={{ fontSize: 9 }}
          >
            {t(lang, "chat.logout")}
          </button>
        </div>
      </aside>

      {/* Chat column */}
      <div className="h-[100dvh] md:pl-[200px] flex flex-col overflow-hidden">
        <header className="px-4 sm:px-6 py-3 border-b border-[var(--border)] flex items-center gap-2 sm:gap-3">
          <button
            type="button"
            onClick={() => setSidebarOpen(true)}
            aria-label="Open menu"
            className="md:hidden p-1 text-[var(--fg-muted)]"
          >
            <MenuIcon />
          </button>
          <div className="flex-1 min-w-0">
            <div className="text-[13px] font-medium truncate">{agent.name}</div>
            <div className="label-mono mt-0.5" style={{ fontSize: 9 }}>
              {msgCount} {msgCount === 1 ? t(lang, "chat.msg") : t(lang, "chat.msgs")}
            </div>
          </div>
          <span
            className="label-mono px-2 py-1 rounded-md hidden sm:inline-block"
            style={{ fontSize: 10, border: "1px solid var(--border)" }}
          >
            {MODEL_LABELS[agent.model].label}
          </span>
          <button
            type="button"
            onClick={clearHistory}
            className="label-mono hover:text-[var(--fg)]"
            style={{ fontSize: 9 }}
          >
            {t(lang, "chat.clear")}
          </button>
        </header>

        <div ref={scrollRef} className="flex-1 overflow-y-auto px-4 sm:px-6 md:px-8 py-6">
          <div className="max-w-[780px] mx-auto flex flex-col gap-4">
            {messages.length === 0 && !stream.streaming && (
              <EmptyState lang={lang} agentName={agent.name} />
            )}

            {messages.length > 0 && <DayLabel label={t(lang, "chat.day")} />}

            {messages.map((m) =>
              m.role === "user" ? (
                <UserBubble
                  key={m.id}
                  lang={lang}
                  text={m.content}
                  editing={editingId === m.id}
                  onEdit={() => setEditingId(m.id)}
                  onCancelEdit={() => setEditingId(null)}
                  onSubmitEdit={(next) => submitEdit(m.id, next)}
                />
              ) : (
                <AgentBubble key={m.id} lang={lang} message={m} now={now} />
              ),
            )}

            {stream.streaming && (
              <AgentBubble
                lang={lang}
                message={{
                  id: "streaming",
                  agentId: agent.id,
                  role: "assistant",
                  content: stream.current || "",
                  ...(stream.taskRun ? { taskRun: stream.taskRun } : {}),
                  createdAt: 0,
                }}
                streaming
                tools={stream.toolCalls}
                now={now}
              />
            )}

            {error && (
              <div
                className="self-start rounded-xl px-4 py-3 text-[12px]"
                style={{ background: "rgba(193,18,31,0.06)", border: "1px solid var(--danger)", color: "var(--danger)" }}
              >
                {error}
              </div>
            )}
          </div>
        </div>

        <div className="px-4 sm:px-6 md:px-8 py-4 border-t border-[var(--border)]">
          <div className="max-w-[780px] mx-auto flex flex-col gap-2">
            {queue.length > 0 && (
              <QueueList lang={lang} items={queue} onRemove={removeFromQueue} />
            )}
            <Composer
              value={input}
              onChange={setInput}
              onSubmit={send}
              onStop={stop}
              streaming={stream.streaming}
              placeholder={t(lang, "chat.placeholder", { name: agent.name.toLowerCase() })}
            />
          </div>
        </div>
      </div>
    </div>
  );
}

function Avatar({ agent, size = 36 }: { agent: Agent; size?: number }) {
  const initial = agent.name.trim().charAt(0).toUpperCase() || "M";
  const raw = agent.emoji?.trim() ?? "";
  const isImage = raw.startsWith("data:image");

  return (
    <span
      className="rounded-md overflow-hidden grid place-items-center shrink-0 font-medium"
      style={{
        width: size,
        height: size,
        fontSize: size * 0.45,
        background: "var(--fg)",
        color: "var(--bg)",
      }}
    >
      {isImage ? (
        // eslint-disable-next-line @next/next/no-img-element
        <img src={raw} alt="" className="w-full h-full object-cover" />
      ) : (
        raw || initial
      )}
    </span>
  );
}

function Orb({ size = 22 }: { size?: number }) {
  return (
    <span
      className="rounded-full grid place-items-center text-[var(--bg)] font-serif italic font-medium shrink-0"
      style={{
        width: size,
        height: size,
        fontSize: size * 0.52,
        background: "var(--fg)",
      }}
    >
      m
    </span>
  );
}

function NavItem({
  icon,
  label,
  active,
  href,
  muted,
}: {
  icon: React.ReactNode;
  label: string;
  active?: boolean;
  href?: string;
  muted?: boolean;
}) {
  const className = `flex items-center gap-2 px-2 py-1.5 rounded-lg text-[12px] ${
    active
      ? "bg-[var(--accent-soft)] text-[var(--accent)] font-medium"
      : muted
        ? "text-[var(--fg-dim)] cursor-default"
        : "text-[var(--fg-muted)] hover:text-[var(--fg)] hover:bg-[var(--bg-soft)]"
  }`;

  const content = (
    <>
      <span className="w-3.5 h-3.5 inline-flex items-center justify-center">{icon}</span>
      <span className="flex-1">{label}</span>
    </>
  );

  if (href && !muted) {
    return (
      <Link href={href} className={className}>
        {content}
      </Link>
    );
  }

  return <div className={className}>{content}</div>;
}

function EmptyState({ lang, agentName }: { lang: Lang; agentName: string }) {
  return (
    <div className="mt-16 mx-auto max-w-md text-center flex flex-col items-center gap-4">
      <Orb size={56} />
      <h1 className="font-serif text-[32px] leading-tight font-light" style={{ letterSpacing: "-0.5px" }}>
        {t(lang, "chat.empty.title")} <em className="italic text-[var(--accent)]">{t(lang, "chat.empty.titleEm")}</em>?
      </h1>
      <p className="text-[13px] text-[var(--fg-muted)] leading-relaxed max-w-sm">
        {t(lang, "chat.empty.body", { name: agentName })}
      </p>
    </div>
  );
}

function DayLabel({ label }: { label: string }) {
  return (
    <div className="label-mono text-center" style={{ fontSize: 9 }}>
      {label}
    </div>
  );
}

function UserBubble({
  lang,
  text,
  editing,
  onEdit,
  onCancelEdit,
  onSubmitEdit,
}: {
  lang: Lang;
  text: string;
  editing: boolean;
  onEdit: () => void;
  onCancelEdit: () => void;
  onSubmitEdit: (next: string) => void;
}) {
  const [draft, setDraft] = useState(text);
  const textareaRef = useRef<HTMLTextAreaElement>(null);

  useEffect(() => {
    if (editing) {
      setDraft(text);
      const el = textareaRef.current;
      if (el) {
        el.focus();
        el.setSelectionRange(el.value.length, el.value.length);
        el.style.height = "auto";
        el.style.height = `${Math.min(el.scrollHeight, 240)}px`;
      }
    }
  }, [editing, text]);

  if (editing) {
    const canSave = draft.trim().length > 0 && draft.trim() !== text.trim();
    return (
      <div className="flex justify-end">
        <div
          className="max-w-[78%] w-full md:w-[520px] px-3 py-2.5 flex flex-col gap-2"
          style={{
            background: "var(--bg)",
            border: "1px solid var(--border-strong)",
            borderRadius: "14px 14px 2px 14px",
          }}
        >
          <textarea
            ref={textareaRef}
            className="w-full bg-transparent resize-none outline-none text-[13px] leading-[1.5] text-[var(--fg)] placeholder:text-[var(--fg-dim)]"
            rows={1}
            value={draft}
            onChange={(e) => {
              setDraft(e.target.value);
              e.currentTarget.style.height = "auto";
              e.currentTarget.style.height = `${Math.min(e.currentTarget.scrollHeight, 240)}px`;
            }}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.shiftKey) {
                e.preventDefault();
                if (canSave) onSubmitEdit(draft);
              } else if (e.key === "Escape") {
                e.preventDefault();
                onCancelEdit();
              }
            }}
          />
          <div className="flex items-center justify-end gap-2">
            <button
              type="button"
              onClick={onCancelEdit}
              className="label-mono px-2 py-1 text-[var(--fg-muted)] hover:text-[var(--fg)]"
              style={{ fontSize: 10 }}
            >
              {t(lang, "chat.cancel")}
            </button>
            <button
              type="button"
              onClick={() => canSave && onSubmitEdit(draft)}
              disabled={!canSave}
              className="label-mono px-3 py-1 rounded-md disabled:opacity-40"
              style={{ fontSize: 10, background: "var(--fg)", color: "var(--bg)" }}
            >
              {t(lang, "chat.save")}
            </button>
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="group flex justify-end items-end gap-1.5">
      <button
        type="button"
        onClick={onEdit}
        aria-label={t(lang, "chat.edit")}
        className="opacity-0 group-hover:opacity-100 focus:opacity-100 transition-opacity p-1 text-[var(--fg-dim)] hover:text-[var(--fg)]"
      >
        <EditIcon />
      </button>
      <div
        className="max-w-[78%] px-4 py-2.5 text-[13px] leading-[1.5] whitespace-pre-wrap"
        style={{
          background: "var(--fg)",
          color: "var(--bg)",
          borderRadius: "14px 14px 2px 14px",
        }}
      >
        {text}
      </div>
    </div>
  );
}

function AgentBubble({
  lang,
  message,
  streaming,
  tools,
  now,
}: {
  lang: Lang;
  message: ChatMessage;
  streaming?: boolean;
  tools?: ToolTraceEntry[];
  now: number;
}) {
  const trace = tools ?? message.toolTrace;
  const hasBody =
    message.content.trim().length > 0 || streaming || Boolean(message.taskRun) || (trace && trace.length > 0);

  if (!hasBody) return null;

  return (
    <div className="flex gap-2.5 items-start">
      <div className="mt-1">
        <Orb size={22} />
      </div>
      <div
        className="flex-1 px-4 py-3 flex flex-col gap-2.5 max-w-[78%]"
        style={{
          background: "var(--bg-soft)",
          border: "1px solid var(--border)",
          borderRadius: "14px 14px 14px 2px",
        }}
      >
        {message.taskRun && <TaskCard lang={lang} taskRun={message.taskRun} now={now} />}
        {trace && trace.length > 0 && <ToolTrace lang={lang} trace={trace} />}
        {message.content && (
          <div className="text-[13px] leading-[1.55] whitespace-pre-wrap text-[var(--fg)]">
            {message.content}
            {streaming && <span className="inline-block w-1.5 h-4 bg-[var(--accent)] ml-0.5 meta-pulse align-middle" />}
          </div>
        )}
        {!message.content && streaming && (
          <div className="label-mono flex items-center gap-1.5" style={{ fontSize: 9 }}>
            <span className="w-1.5 h-1.5 rounded-full bg-[var(--accent)] meta-pulse" />
            {t(lang, "chat.thinking")}
          </div>
        )}
      </div>
    </div>
  );
}

function TaskCard({ lang, taskRun, now }: { lang: Lang; taskRun: TaskRunSnapshot; now: number }) {
  const completed = taskRun.status === "done" || taskRun.status === "failed" || taskRun.status === "cancelled";
  const elapsedUntil = taskRun.completedAt ?? (now || taskRun.startedAt);
  const elapsedMs = taskRun.durationMs ?? elapsedUntil - taskRun.startedAt;
  const running = !completed;

  const visibleEvents = taskRun.events.slice(-5);
  const hiddenEvents = taskRun.events.slice(0, taskRun.events.length - visibleEvents.length);
  const screenshots = taskRun.artifacts.slice(-3);

  return (
    <div
      className="rounded-[10px] p-2.5"
      style={{ border: "1px solid var(--border-strong)", background: "var(--bg)" }}
    >
      <div className="flex items-center gap-2 label-mono" style={{ fontSize: 10 }}>
        <span
          className="w-1.5 h-1.5 rounded-full"
          style={{
            background: running ? "var(--accent)" : taskRun.status === "failed" ? "var(--danger)" : "var(--success)",
            animation: running ? "meta-pulse 1.4s infinite" : undefined,
          }}
        />
        <span style={{ color: running ? "var(--accent)" : "var(--fg-muted)" }}>
          {taskStatusLabel(lang, taskRun.status).toUpperCase()}
        </span>
        <span className="ml-auto" style={{ color: "var(--fg-dim)" }}>
          {formatDuration(elapsedMs)}
        </span>
      </div>

      {hiddenEvents.length > 0 && (
        <details className="mt-2 group">
          <summary
            className="cursor-pointer select-none list-none flex items-center gap-1 label-mono text-[var(--fg-dim)] hover:text-[var(--fg-muted)] pb-1"
            style={{ fontSize: 10 }}
          >
            <span>{t(lang, "chat.task.previous", { n: hiddenEvents.length })}</span>
            <svg
              width="10"
              height="10"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeWidth="2"
              strokeLinecap="round"
              strokeLinejoin="round"
              className="transition-transform group-open:rotate-90"
            >
              <path d="M9 6l6 6-6 6" />
            </svg>
          </summary>
          <div className="mt-1 flex flex-col gap-1 pb-1 border-b border-[var(--border)]">
            {hiddenEvents.map((event, i) => (
              <TaskStepRow key={event.id} lang={lang} event={event} index={i} />
            ))}
          </div>
        </details>
      )}

      {visibleEvents.length > 0 && (
        <div className="mt-2 flex flex-col gap-1">
          {visibleEvents.map((event, i) => (
            <TaskStepRow
              key={event.id}
              lang={lang}
              event={event}
              index={hiddenEvents.length + i}
              isLast={i === visibleEvents.length - 1 && running}
            />
          ))}
        </div>
      )}

      {screenshots.length > 0 && (
        <div className="mt-2.5 grid grid-cols-3 gap-1">
          {screenshots.map((artifact, i) => (
            <a
              key={artifact.id}
              href={artifact.url}
              target="_blank"
              rel="noreferrer"
              className="relative block overflow-hidden"
              style={{
                aspectRatio: "16 / 10",
                borderRadius: 4,
                border: "1px solid var(--border)",
                background: "var(--bg-soft)",
              }}
            >
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img src={artifact.url} alt={artifact.label} className="absolute inset-0 w-full h-full object-cover" />
              <span
                className="absolute bottom-1 left-1 label-mono"
                style={{ fontSize: 7, color: "var(--fg-dim)", background: "var(--bg)", padding: "0 3px", borderRadius: 2 }}
              >
                shot_{i + 1}
              </span>
            </a>
          ))}
        </div>
      )}

    </div>
  );
}

function TaskStepRow({ lang, event, index, isLast }: { lang: Lang; event: TaskEvent; index: number; isLast?: boolean }) {
  const credentialRequest = getCredentialRequestFromDetails(event.details);
  const status = resolveEventStatus(event, isLast);

  const borderColor =
    status === "done"
      ? "var(--success)"
      : status === "active"
        ? "var(--accent)"
        : status === "error"
          ? "var(--danger)"
          : "var(--fg-dim)";

  const fill = status === "done" || status === "active" || status === "error" ? borderColor : "transparent";

  return (
    <div className="flex flex-col gap-1">
      <div className="flex items-center gap-2 text-[11px]">
        <span
          className="w-3 h-3 rounded-full flex items-center justify-center shrink-0"
          style={{ border: `1px solid ${borderColor}`, background: fill }}
        >
          {status === "done" && <CheckIcon color="var(--bg)" />}
          {status === "active" && (
            <span className="w-1 h-1 rounded-full bg-[var(--bg)] meta-pulse" />
          )}
        </span>
        <span
          className="label-mono shrink-0"
          style={{ fontSize: 9, color: "var(--fg-dim)", width: 18 }}
        >
          {String(index + 1).padStart(2, "0")}
        </span>
        <span className="flex-1 truncate" style={{ color: status === "pending" ? "var(--fg-dim)" : "var(--fg-muted)" }}>
          {event.title}
        </span>
        {event.durationMs !== undefined && (
          <span className="label-mono" style={{ fontSize: 9, color: "var(--fg-dim)" }}>
            {formatDuration(event.durationMs)}
          </span>
        )}
        {status === "waiting" && (
          <span
            className="label-mono"
            style={{
              fontSize: 9,
              color: "var(--accent)",
              background: "var(--accent-soft)",
              padding: "1px 5px",
              borderRadius: 3,
            }}
          >
            {t(lang, "chat.task.waiting")}
          </span>
        )}
      </div>
      {credentialRequest && <CredentialApprovalCard lang={lang} request={credentialRequest} />}
    </div>
  );
}

function resolveEventStatus(event: TaskEvent, isLast?: boolean): "done" | "active" | "error" | "waiting" | "pending" {
  const details = event.details as Record<string, unknown> | undefined;
  const status = typeof details?.status === "string" ? (details.status as string) : undefined;
  const type = typeof details?.type === "string" ? (details.type as string) : undefined;

  if (status === "failed" || status === "error" || type === "error") return "error";
  if (status === "pending" || type === "credential_request") return "waiting";
  if (event.durationMs !== undefined) return "done";
  if (isLast) return "active";
  return "done";
}

function ToolTrace({ lang, trace }: { lang: Lang; trace: ToolTraceEntry[] }) {
  const path = trace.map((entry) => shortToolName(entry.name)).join(" → ");
  const callsLabel = t(
    lang,
    trace.length === 1 ? "chat.toolCalls" : "chat.toolCalls_plural",
    { n: trace.length },
  );

  return (
    <details className="rounded-lg" style={{ border: "1px solid var(--border)", background: "var(--bg)" }}>
      <summary
        className="cursor-pointer select-none px-2.5 py-1.5 label-mono flex items-center gap-1.5"
        style={{ fontSize: 9 }}
      >
        <span style={{ color: "var(--fg-muted)" }}>{callsLabel}</span>
        <span className="truncate normal-case tracking-normal font-mono" style={{ color: "var(--fg-dim)", textTransform: "none" }}>
          {path}
        </span>
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
    <details className="rounded" style={{ border: "1px solid var(--border)", background: "var(--bg-soft)" }}>
      <summary className="cursor-pointer select-none px-2 py-1.5 text-[11px]">
        <span className="font-mono">
          {index + 1}. {shortToolName(entry.name)}
        </span>
        <span className="ml-2 label-mono" style={{ fontSize: 9 }}>
          {status}
        </span>
      </summary>
      <div className="border-t border-[var(--border)] p-2 space-y-2">
        {entry.artifacts && entry.artifacts.length > 0 && (
          <div className="grid grid-cols-2 gap-1.5">
            {entry.artifacts.map((artifact) => (
              <a
                key={artifact.id}
                href={artifact.url}
                target="_blank"
                rel="noreferrer"
                className="overflow-hidden rounded"
                style={{ border: "1px solid var(--border)", background: "var(--bg)" }}
              >
                {/* eslint-disable-next-line @next/next/no-img-element */}
                <img src={artifact.url} alt={artifact.label} className="h-28 w-full object-contain p-1" />
              </a>
            ))}
          </div>
        )}
        <ToolValue title="input" value={entry.input} />
        {"result" in entry && <ToolValue title={entry.isError ? "error" : "result"} value={entry.result} />}
      </div>
    </details>
  );
}

function ToolValue({ title, value }: { title: string; value: unknown }) {
  if (value === undefined) return null;

  return (
    <details className="rounded" style={{ border: "1px solid var(--border)", background: "var(--bg)" }}>
      <summary className="cursor-pointer select-none px-2 py-1 label-mono" style={{ fontSize: 9 }}>
        {title}
      </summary>
      <pre
        className="max-h-60 overflow-auto whitespace-pre-wrap break-words p-2 text-[10px] leading-relaxed"
        style={{ color: "var(--fg-muted)" }}
      >
        {stringifyToolValue(value)}
      </pre>
    </details>
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

function CredentialApprovalCard({ lang, request }: { lang: Lang; request: CredentialRequestView }) {
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
      setError(err instanceof Error ? err.message : t(lang, "chat.error.http"));
    } finally {
      setBusy(null);
    }
  }

  return (
    <div
      className="ml-5 rounded-lg p-2.5 text-[11px]"
      style={{ background: "var(--accent-soft)", border: "1px solid var(--accent)" }}
    >
      <div className="label-mono" style={{ color: "var(--accent)", fontSize: 9 }}>
        CREDENTIAL · {credentialActionLabel(lang, request.requestedAction)}
      </div>
      <div className="mt-1 text-[var(--fg)] leading-relaxed">
        <span className="font-mono text-[11px]">{request.origin}</span>
        {request.accountHint ? <> · {request.accountHint}</> : null}
      </div>
      <div className="mt-1 text-[var(--fg-muted)] leading-relaxed">{request.reason}</div>
      <div className="mt-2 flex items-center gap-2">
        <span className="label-mono" style={{ fontSize: 9 }}>
          {credentialStatusLabel(lang, status)}
        </span>
        {pending && (
          <>
            <button
              type="button"
              onClick={() => decide("approve")}
              disabled={Boolean(busy)}
              className="px-3 py-1 rounded-md text-[11px] font-medium"
              style={{ background: "var(--fg)", color: "var(--bg)" }}
            >
              {busy === "approve" ? "…" : t(lang, "chat.cred.approve")}
            </button>
            <button
              type="button"
              onClick={() => decide("deny")}
              disabled={Boolean(busy)}
              className="px-3 py-1 rounded-md text-[11px]"
              style={{ border: "1px solid var(--border-strong)", color: "var(--fg-muted)" }}
            >
              {busy === "deny" ? "…" : t(lang, "chat.cred.deny")}
            </button>
          </>
        )}
      </div>
      {error && <div className="mt-1 text-[var(--danger)]">{error}</div>}
    </div>
  );
}

function QueueList({
  lang,
  items,
  onRemove,
}: {
  lang: Lang;
  items: string[];
  onRemove: (index: number) => void;
}) {
  return (
    <div className="flex flex-col gap-1.5">
      {items.map((text, i) => (
        <div
          key={`${i}-${text}`}
          className="flex items-center gap-2.5 px-3 py-2.5 rounded-[12px]"
          style={{ background: "var(--bg-soft)", border: "1px solid var(--border)" }}
        >
          <span className="shrink-0 text-[var(--fg-dim)]" aria-hidden="true">
            <QueueItemIcon />
          </span>
          <span
            className="flex-1 min-w-0 text-[13px] leading-[1.4] text-[var(--fg)] truncate"
          >
            {text}
          </span>
          <button
            type="button"
            onClick={() => onRemove(i)}
            aria-label={t(lang, "chat.cancel")}
            className="shrink-0 text-[var(--fg-dim)] hover:text-[var(--fg)] p-1"
          >
            <TrashIcon />
          </button>
        </div>
      ))}
    </div>
  );
}

function Composer({
  value,
  onChange,
  onSubmit,
  onStop,
  streaming,
  placeholder,
}: {
  value: string;
  onChange: (value: string) => void;
  onSubmit: () => void;
  onStop: () => void;
  streaming: boolean;
  placeholder: string;
}) {
  const canSend = value.trim().length > 0 && !streaming;

  return (
    <div
      className="flex items-end gap-2 px-3 py-2 rounded-[14px]"
      style={{ background: "var(--bg)", border: "1px solid var(--border-strong)" }}
    >
      <button
        type="button"
        className="w-7 h-7 grid place-items-center text-[var(--fg-dim)] hover:text-[var(--fg)] shrink-0"
        aria-label="Attach"
      >
        <PlusIcon />
      </button>
      <textarea
        className="flex-1 bg-transparent resize-none outline-none text-[13px] leading-[1.5] placeholder:text-[var(--fg-dim)] py-1.5 max-h-40"
        rows={1}
        value={value}
        placeholder={placeholder}
        onChange={(e) => {
          onChange(e.target.value);
          e.currentTarget.style.height = "auto";
          e.currentTarget.style.height = `${Math.min(e.currentTarget.scrollHeight, 160)}px`;
        }}
        onKeyDown={(e) => {
          if (e.key === "Enter" && !e.shiftKey) {
            e.preventDefault();
            onSubmit();
          }
        }}
      />
      <button
        type="button"
        className="w-7 h-7 grid place-items-center text-[var(--fg-dim)] hover:text-[var(--fg)] shrink-0"
        aria-label="Voice"
      >
        <MicIcon />
      </button>
      {streaming ? (
        <button
          type="button"
          onClick={onStop}
          className="w-8 h-8 rounded-full grid place-items-center shrink-0"
          style={{ background: "var(--fg)", color: "var(--bg)" }}
          aria-label="Stop"
        >
          <StopIcon />
        </button>
      ) : (
        <button
          type="button"
          onClick={onSubmit}
          disabled={!canSend}
          className="w-8 h-8 rounded-full grid place-items-center shrink-0 transition-opacity disabled:opacity-40"
          style={{ background: canSend ? "var(--accent)" : "var(--bg-softer)", color: "var(--bg)" }}
          aria-label="Send"
        >
          <ArrowUpIcon />
        </button>
      )}
    </div>
  );
}

/* ───────────── icons ───────────── */

function ChatIcon() {
  return (
    <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
      <path d="M21 12a8 8 0 01-11.3 7.3L4 21l1.7-5.7A8 8 0 1121 12z" />
    </svg>
  );
}
function LockIcon() {
  return (
    <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
      <rect x="4" y="11" width="16" height="10" rx="2" />
      <path d="M8 11V7a4 4 0 118 0v4" />
    </svg>
  );
}
function LayersIcon() {
  return (
    <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
      <path d="M12 3l9 5-9 5-9-5 9-5z" />
      <path d="M3 13l9 5 9-5" />
    </svg>
  );
}
function SettingsIcon() {
  return (
    <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
      <circle cx="12" cy="12" r="3" />
      <path d="M19.4 15a1.7 1.7 0 00.3 1.8l.1.1a2 2 0 11-2.8 2.8l-.1-.1a1.7 1.7 0 00-1.8-.3 1.7 1.7 0 00-1 1.5V21a2 2 0 01-4 0v-.1a1.7 1.7 0 00-1-1.5 1.7 1.7 0 00-1.8.3l-.1.1a2 2 0 11-2.8-2.8l.1-.1a1.7 1.7 0 00.3-1.8 1.7 1.7 0 00-1.5-1H3a2 2 0 010-4h.1a1.7 1.7 0 001.5-1 1.7 1.7 0 00-.3-1.8l-.1-.1a2 2 0 112.8-2.8l.1.1a1.7 1.7 0 001.8.3 1.7 1.7 0 001-1.5V3a2 2 0 014 0v.1a1.7 1.7 0 001 1.5 1.7 1.7 0 001.8-.3l.1-.1a2 2 0 112.8 2.8l-.1.1a1.7 1.7 0 00-.3 1.8 1.7 1.7 0 001.5 1H21a2 2 0 010 4h-.1a1.7 1.7 0 00-1.5 1z" />
    </svg>
  );
}
function CheckIcon({ color = "currentColor" }: { color?: string }) {
  return (
    <svg width="7" height="7" viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth="3" strokeLinecap="round" strokeLinejoin="round">
      <path d="M5 12l5 5L20 7" />
    </svg>
  );
}
function PlusIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
      <path d="M12 5v14M5 12h14" />
    </svg>
  );
}
function MicIcon() {
  return (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
      <rect x="9" y="3" width="6" height="12" rx="3" />
      <path d="M5 11a7 7 0 0014 0" />
      <path d="M12 18v3" />
    </svg>
  );
}
function MenuIcon() {
  return (
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
      <path d="M4 6h16M4 12h16M4 18h16" />
    </svg>
  );
}
function ArrowUpIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M12 19V5M5 12l7-7 7 7" />
    </svg>
  );
}
function StopIcon() {
  return (
    <svg width="11" height="11" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <rect x="5" y="5" width="14" height="14" rx="2" />
    </svg>
  );
}
function QueueItemIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round">
      <path d="M4 6h10" />
      <path d="M4 12h7" />
      <path d="M4 18h4" />
      <path d="M14 6l3 3 3-3" />
    </svg>
  );
}
function TrashIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round">
      <path d="M3 6h18" />
      <path d="M8 6V4a2 2 0 012-2h4a2 2 0 012 2v2" />
      <path d="M6 6l1 14a2 2 0 002 2h6a2 2 0 002-2l1-14" />
    </svg>
  );
}
function EditIcon() {
  return (
    <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
      <path d="M12 20h9" />
      <path d="M16.5 3.5a2.12 2.12 0 013 3L7 19l-4 1 1-4 12.5-12.5z" />
    </svg>
  );
}

/* ───────────── helpers ───────────── */

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

function taskStatusLabel(lang: Lang, status: TaskRunSnapshot["status"]) {
  switch (status) {
    case "created":
      return t(lang, "chat.status.created");
    case "planning":
      return t(lang, "chat.status.planning");
    case "running":
      return t(lang, "chat.status.running");
    case "waiting_for_user":
      return t(lang, "chat.status.waiting_for_user");
    case "done":
      return t(lang, "chat.status.done");
    case "failed":
      return t(lang, "chat.status.failed");
    case "cancelled":
      return t(lang, "chat.status.cancelled");
  }
}

function formatDuration(ms: number) {
  const safeMs = Math.max(0, ms);
  const seconds = Math.floor(safeMs / 1000);
  const minutes = Math.floor(seconds / 60);
  const restSeconds = seconds % 60;

  if (minutes > 0) return `${minutes}:${String(restSeconds).padStart(2, "0")}`;
  if (seconds > 0) return `0:${String(seconds).padStart(2, "0")}`;
  return `${safeMs}ms`;
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

function credentialActionLabel(lang: Lang, action: CredentialRequest["requestedAction"]) {
  switch (action) {
    case "fill_password":
      return t(lang, "chat.cred.password");
    case "use_passkey":
      return t(lang, "chat.cred.passkey");
    case "reuse_session":
      return t(lang, "chat.cred.session");
    case "scheduled_read":
      return t(lang, "chat.cred.read");
  }
}

function credentialStatusLabel(lang: Lang, status: CredentialRequest["status"]) {
  switch (status) {
    case "pending":
      return t(lang, "chat.cred.pending");
    case "approved":
      return t(lang, "chat.cred.approved");
    case "denied":
      return t(lang, "chat.cred.denied");
    case "expired":
      return t(lang, "chat.cred.expired");
    case "used":
      return t(lang, "chat.cred.used");
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
