"use client";

import { useRef, useState } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import type { Agent, AgentDraft, AgentModel, Capability } from "@/shared/types";
import { AGENT_MODELS, CAPABILITY_LABELS, MODEL_LABELS } from "@/shared/types";
import LangToggle from "@/ui/shell/lang-toggle";
import { useLang, t, type Lang } from "@/client/i18n";

const MODEL_HINT_KEYS: Record<AgentModel, Parameters<typeof t>[1]> = {
  "claude-haiku-4-5-20251001": "model.haiku.hint",
  "claude-sonnet-4-6": "model.sonnet.hint",
  "claude-opus-4-7": "model.opus.hint",
  "gpt-5.3-codex": "model.codex.hint",
};

const CAP_KEYS: Record<Capability, { label: Parameters<typeof t>[1]; hint: Parameters<typeof t>[1] }> = {
  web_search: { label: "cap.web_search.label", hint: "cap.web_search.hint" },
  web_fetch: { label: "cap.web_fetch.label", hint: "cap.web_fetch.hint" },
  chrome_browser: { label: "cap.chrome_browser.label", hint: "cap.chrome_browser.hint" },
  credential_broker: { label: "cap.credential_broker.label", hint: "cap.credential_broker.hint" },
  file_read: { label: "cap.file_read.label", hint: "cap.file_read.hint" },
  file_write: { label: "cap.file_write.label", hint: "cap.file_write.hint" },
  shell: { label: "cap.shell.label", hint: "cap.shell.hint" },
};

function capLabel(lang: Lang, c: Capability) {
  return t(lang, CAP_KEYS[c].label);
}

export default function AgentEditor({ agent }: { agent: Agent }) {
  const router = useRouter();
  const [lang] = useLang();
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
  const fileInputRef = useRef<HTMLInputElement>(null);

  const update = <K extends keyof AgentDraft>(key: K, value: AgentDraft[K]) =>
    setDraft((d) => ({ ...d, [key]: value }));

  const toggleCap = (c: Capability) => {
    const has = draft.capabilities.includes(c);
    update("capabilities", has ? draft.capabilities.filter((x) => x !== c) : [...draft.capabilities, c]);
  };

  const handleFile = (file: File) => {
    const reader = new FileReader();
    reader.onload = () => {
      if (typeof reader.result === "string") update("emoji", reader.result);
    };
    reader.readAsDataURL(file);
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
    if (!confirm(t(lang, "settings.deleteConfirm", { name: agent.name }))) return;
    await fetch(`/api/agents/${agent.id}`, { method: "DELETE" });
    router.push("/");
    router.refresh();
  }

  return (
    <div className="flex-1 px-6 py-10 max-w-3xl w-full mx-auto">
      <div className="flex items-center gap-3 mb-6">
        <Link href={`/chat/${agent.id}`} className="btn btn-ghost text-sm">{t(lang, "settings.backToChat")}</Link>
        <div className="flex-1" />
        <LangToggle />
        <Link href={`/chat/${agent.id}`} className="btn btn-secondary">{t(lang, "settings.openChat")}</Link>
      </div>

      <h1 className="text-2xl font-semibold mb-6">{t(lang, "settings.title")}</h1>

      <div className="card p-6 space-y-5">
        <div className="flex gap-3 items-start">
          <div className="flex flex-col items-center gap-1.5">
            <button
              type="button"
              onClick={() => fileInputRef.current?.click()}
              className="w-16 h-16 rounded-md overflow-hidden grid place-items-center text-xl font-medium"
              style={{ background: "var(--fg)", color: "var(--bg)", border: "1px solid var(--border-strong)" }}
              aria-label={t(lang, "settings.avatarUpload")}
            >
              {draft.emoji?.startsWith("data:") ? (
                // eslint-disable-next-line @next/next/no-img-element
                <img src={draft.emoji} alt="" className="w-full h-full object-cover" />
              ) : (
                draft.emoji || "M"
              )}
            </button>
            <input
              ref={fileInputRef}
              type="file"
              accept="image/*"
              className="hidden"
              onChange={(e) => {
                const f = e.target.files?.[0];
                if (f) handleFile(f);
              }}
            />
            <input
              className="input !w-16 text-center text-lg !py-1 !px-1"
              placeholder={t(lang, "settings.iconPlaceholder")}
              value={draft.emoji?.startsWith("data:") ? "" : draft.emoji}
              onChange={(e) => update("emoji", e.target.value.slice(0, 4))}
            />
          </div>
          <div className="flex-1">
            <label className="text-xs text-[var(--fg-muted)] block mb-1">{t(lang, "settings.name")}</label>
            <input className="input" value={draft.name} onChange={(e) => update("name", e.target.value)} />
          </div>
        </div>

        <div>
          <label className="text-xs text-[var(--fg-muted)] block mb-1">{t(lang, "settings.description")}</label>
          <input className="input" value={draft.description} onChange={(e) => update("description", e.target.value)} />
        </div>

        <div>
          <label className="text-xs text-[var(--fg-muted)] block mb-2">{t(lang, "settings.model")}</label>
          <div className="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-3 gap-2">
            {AGENT_MODELS.map((m: AgentModel) => (
              <button
                key={m}
                onClick={() => update("model", m)}
                className={`card p-3 text-left cursor-pointer ${draft.model === m ? "!border-[var(--accent)] !bg-[var(--accent-soft)]" : ""}`}
              >
                <div className="text-sm font-medium">{MODEL_LABELS[m].label}</div>
                <div className="text-xs text-[var(--fg-muted)] mt-0.5">{t(lang, MODEL_HINT_KEYS[m])}</div>
              </button>
            ))}
          </div>
        </div>

        <div>
          <label className="text-xs text-[var(--fg-muted)] block mb-2">{t(lang, "settings.capabilities")}</label>
          <div className="flex flex-wrap gap-2">
            {(Object.keys(CAPABILITY_LABELS) as Capability[]).map((c) => (
              <button
                key={c}
                onClick={() => toggleCap(c)}
                className={`chip ${draft.capabilities.includes(c) ? "chip-active" : ""}`}
              >
                <span>{capLabel(lang, c)}</span>
              </button>
            ))}
          </div>
        </div>

        <div>
          <label className="text-xs text-[var(--fg-muted)] block mb-1">{t(lang, "settings.systemPrompt")}</label>
          <textarea
            className="input min-h-48 font-mono text-xs leading-relaxed"
            value={draft.systemPrompt}
            onChange={(e) => update("systemPrompt", e.target.value)}
          />
        </div>
      </div>

      <div className="flex gap-3 justify-between mt-6">
        <button className="btn btn-ghost text-sm text-[var(--danger)]" onClick={remove}>
          {t(lang, "settings.delete")}
        </button>
        <div className="flex gap-3 items-center">
          {savedAt && <span className="text-xs text-[var(--fg-muted)]">{t(lang, "settings.saved")}</span>}
          <button className="btn btn-primary" onClick={save} disabled={saving}>
            {saving ? t(lang, "settings.saving") : t(lang, "settings.save")}
          </button>
        </div>
      </div>
    </div>
  );
}
