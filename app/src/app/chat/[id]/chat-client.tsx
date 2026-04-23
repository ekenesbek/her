"use client";

import { useEffect, useRef, useState } from "react";
import Link from "next/link";
import type { Agent, ChatMessage } from "@/lib/types";
import { MODEL_LABELS } from "@/lib/types";

type StreamState = {
  streaming: boolean;
  current: string;
  toolCalls: Array<{ name: string; input: unknown }>;
};

export default function ChatClient({
  agent,
  initialMessages,
}: {
  agent: Agent;
  initialMessages: ChatMessage[];
}) {
  const [messages, setMessages] = useState<ChatMessage[]>(initialMessages);
  const [input, setInput] = useState("");
  const [stream, setStream] = useState<StreamState>({ streaming: false, current: "", toolCalls: [] });
  const [error, setError] = useState<string | null>(null);
  const scrollRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    scrollRef.current?.scrollTo({ top: scrollRef.current.scrollHeight, behavior: "smooth" });
  }, [messages, stream]);

  async function send() {
    const text = input.trim();
    if (!text || stream.streaming) return;
    setInput("");
    setError(null);
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
        body: JSON.stringify({ message: text }),
      });
      if (!res.ok || !res.body) throw new Error(`HTTP ${res.status}`);

      const reader = res.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";
      let accumulated = "";

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
          } else if (event === "tool") {
            setStream((s) => ({ ...s, toolCalls: [...s.toolCalls, payload] }));
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
          {messages.length === 0 && !stream.streaming && (
            <div className="text-center text-[var(--fg-muted)] py-20">
              Напиши первое сообщение — {agent.name.toLowerCase()} ждёт.
            </div>
          )}
          {messages.map((m) => (
            <MessageBubble key={m.id} message={m} />
          ))}
          {stream.streaming && (
            <MessageBubble
              message={{
                id: "streaming",
                agentId: agent.id,
                role: "assistant",
                content: stream.current || "…",
                createdAt: 0,
              }}
              streaming
              tools={stream.toolCalls}
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
        <div className="max-w-3xl mx-auto flex gap-2 items-end">
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
  );
}

function MessageBubble({
  message,
  streaming,
  tools,
}: {
  message: ChatMessage;
  streaming?: boolean;
  tools?: Array<{ name: string; input: unknown }>;
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
        {tools && tools.length > 0 && (
          <div className="mb-2 space-y-1">
            {tools.map((t, i) => (
              <div key={i} className="text-[10px] font-mono text-[var(--fg-muted)] bg-[var(--bg-softer)] px-2 py-1 rounded">
                → {t.name}
              </div>
            ))}
          </div>
        )}
        <div className="whitespace-pre-wrap text-sm leading-relaxed">
          {message.content}
          {streaming && <span className="inline-block w-2 h-4 bg-current ml-0.5 animate-pulse" />}
        </div>
      </div>
    </div>
  );
}
