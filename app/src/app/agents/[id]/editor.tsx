"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import type { Agent, AgentDraft, AgentModel, Capability } from "@/lib/types";
import { AGENT_MODELS, CAPABILITY_LABELS, MODEL_LABELS } from "@/lib/types";

export default function AgentEditor({ agent }: { agent: Agent }) {
  const router = useRouter();
  const [draft, setDraft] = useState<AgentDraft>({
    name: agent.name,
    emoji: agent.emoji,
    description: agent.description,
    model: agent.model,
    systemPrompt: agent.systemPrompt,
    capabilities: agent.capabilities,
  });
  const [saving, setSaving] = useState(false);
  const [savedAt, setSavedAt] = useState<number | null>(null);

  const update = <K extends keyof AgentDraft>(key: K, value: AgentDraft[K]) =>
    setDraft((d) => ({ ...d, [key]: value }));

  const toggleCap = (c: Capability) => {
    const has = draft.capabilities.includes(c);
    update("capabilities", has ? draft.capabilities.filter((x) => x !== c) : [...draft.capabilities, c]);
  };

  async function save() {
    setSaving(true);
    try {
      const res = await fetch(`/api/agents/${agent.id}`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(draft),
      });
      if (!res.ok) throw new Error("save failed");
      setSavedAt(Date.now());
      router.refresh();
    } finally {
      setSaving(false);
    }
  }

  async function remove() {
    if (!confirm(`Удалить агента «${agent.name}»? Это необратимо.`)) return;
    await fetch(`/api/agents/${agent.id}`, { method: "DELETE" });
    router.push("/dashboard");
    router.refresh();
  }

  return (
    <div className="flex-1 px-6 py-10 max-w-3xl w-full mx-auto">
      <div className="flex items-center gap-3 mb-6">
        <Link href="/dashboard" className="btn btn-ghost text-sm">← Все агенты</Link>
        <div className="flex-1" />
        <Link href={`/chat/${agent.id}`} className="btn btn-secondary">Открыть чат →</Link>
      </div>

      <h1 className="text-2xl font-semibold mb-6">Настройки агента</h1>

      <div className="card p-6 space-y-5">
        <div className="flex gap-3 items-start">
          <input
            className="input !w-16 text-center text-2xl"
            value={draft.emoji}
            onChange={(e) => update("emoji", e.target.value.slice(0, 4))}
          />
          <div className="flex-1">
            <label className="text-xs text-[var(--fg-muted)] block mb-1">Имя</label>
            <input className="input" value={draft.name} onChange={(e) => update("name", e.target.value)} />
          </div>
        </div>

        <div>
          <label className="text-xs text-[var(--fg-muted)] block mb-1">Описание</label>
          <input className="input" value={draft.description} onChange={(e) => update("description", e.target.value)} />
        </div>

        <div>
          <label className="text-xs text-[var(--fg-muted)] block mb-2">Модель</label>
          <div className="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-3 gap-2">
            {AGENT_MODELS.map((m: AgentModel) => (
              <button
                key={m}
                onClick={() => update("model", m)}
                className={`card p-3 text-left cursor-pointer ${draft.model === m ? "!border-[var(--accent)] !bg-[var(--accent-soft)]" : ""}`}
              >
                <div className="text-sm font-medium">{MODEL_LABELS[m].label}</div>
                <div className="text-xs text-[var(--fg-muted)] mt-0.5">{MODEL_LABELS[m].hint}</div>
              </button>
            ))}
          </div>
        </div>

        <div>
          <label className="text-xs text-[var(--fg-muted)] block mb-2">Возможности</label>
          <div className="flex flex-wrap gap-2">
            {(Object.keys(CAPABILITY_LABELS) as Capability[]).map((c) => (
              <button
                key={c}
                onClick={() => toggleCap(c)}
                className={`chip ${draft.capabilities.includes(c) ? "chip-active" : ""}`}
              >
                <span>{CAPABILITY_LABELS[c].icon}</span>
                <span>{CAPABILITY_LABELS[c].label}</span>
              </button>
            ))}
          </div>
        </div>

        <div>
          <label className="text-xs text-[var(--fg-muted)] block mb-1">Системный промпт</label>
          <textarea
            className="input min-h-48 font-mono text-xs leading-relaxed"
            value={draft.systemPrompt}
            onChange={(e) => update("systemPrompt", e.target.value)}
          />
        </div>
      </div>

      <div className="flex gap-3 justify-between mt-6">
        <button className="btn btn-ghost text-sm text-[var(--danger)]" onClick={remove}>
          Удалить агента
        </button>
        <div className="flex gap-3 items-center">
          {savedAt && <span className="text-xs text-[var(--fg-muted)]">Сохранено</span>}
          <button className="btn btn-primary" onClick={save} disabled={saving}>
            {saving ? "Сохраняю..." : "Сохранить"}
          </button>
        </div>
      </div>
    </div>
  );
}
