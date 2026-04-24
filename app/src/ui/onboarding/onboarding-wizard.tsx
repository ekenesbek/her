"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import type { Template } from "@/shared/templates";
import type { AgentDraft, AgentModel, Capability } from "@/shared/types";
import { AGENT_MODELS, CAPABILITY_LABELS, MODEL_LABELS } from "@/shared/types";

type Step = "welcome" | "template" | "customize" | "done";

export default function OnboardingWizard({ templates }: { templates: Template[] }) {
  const router = useRouter();
  const [step, setStep] = useState<Step>("welcome");
  const [draft, setDraft] = useState<AgentDraft | null>(null);
  const [saving, setSaving] = useState(false);
  const [creatingTemplateId, setCreatingTemplateId] = useState<string | null>(null);
  const [createdId, setCreatedId] = useState<string | null>(null);

  async function createDraft(nextDraft: AgentDraft) {
    setSaving(true);
    try {
      const res = await fetch("/api/agents", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(nextDraft),
      });
      if (!res.ok) throw new Error("save failed");
      const agent = await res.json();
      setDraft({ ...nextDraft });
      setCreatedId(agent.id);
      setStep("done");
    } catch (e) {
      alert("Не удалось сохранить. Открой консоль для деталей.");
      console.error(e);
    } finally {
      setSaving(false);
    }
  }

  async function save() {
    if (!draft) return;
    await createDraft(draft);
  }

  async function createFromTemplate(template: Template) {
    setCreatingTemplateId(template.id);
    try {
      await createDraft(template.draft);
    } finally {
      setCreatingTemplateId(null);
    }
  }

  return (
    <div className="flex-1 flex flex-col">
      <ProgressBar step={step} />
      <div className="flex-1 flex flex-col items-center justify-center px-6 py-12">
        <div className="w-full max-w-2xl">
          {step === "welcome" && <Welcome onNext={() => setStep("template")} />}
          {step === "template" && (
            <TemplatePicker
              templates={templates}
              creatingTemplateId={creatingTemplateId}
              onPick={(t) => {
                setDraft({ ...t.draft });
                setStep("customize");
              }}
              onCreate={createFromTemplate}
            />
          )}
          {step === "customize" && draft && (
            <Customize
              draft={draft}
              onChange={setDraft}
              onBack={() => setStep("template")}
              onSave={save}
              saving={saving}
            />
          )}
          {step === "done" && createdId && (
            <Done
              onChat={() => router.push(`/chat/${createdId}`)}
              onDashboard={() => router.push("/dashboard")}
            />
          )}
        </div>
      </div>
    </div>
  );
}

function ProgressBar({ step }: { step: Step }) {
  const steps: Step[] = ["welcome", "template", "customize", "done"];
  const idx = steps.indexOf(step);
  const pct = ((idx + 1) / steps.length) * 100;
  return (
    <div className="h-1 bg-[var(--bg-softer)]">
      <div className="h-full bg-[var(--accent)] transition-all duration-500" style={{ width: `${pct}%` }} />
    </div>
  );
}

function Welcome({ onNext }: { onNext: () => void }) {
  return (
    <div className="text-center space-y-8">
      <div className="inline-block text-7xl mb-4">🤖</div>
      <h1 className="text-4xl md:text-5xl font-semibold tracking-tight">
        Привет. Давай создадим твоего первого агента.
      </h1>
      <p className="text-lg text-[var(--fg-muted)] max-w-xl mx-auto leading-relaxed">
        meta — это конструктор персональных агентов. После подключения Chrome MCP
        они умеют работать с твоим Chrome, искать в вебе, и помогать с задачами —
        от почты до бронирований.
      </p>
      <div className="grid grid-cols-1 md:grid-cols-3 gap-3 pt-4 text-left">
        <Hint icon="🧭" title="Подключённый Chrome" text="Один раз подключаешь, дальше агент использует твою сессию" />
        <Hint icon="🎯" title="Под твои задачи" text="Шаблоны или свой с нуля" />
        <Hint icon="🛡️" title="Безопасно" text="Необратимые действия — с подтверждения" />
      </div>
      <button className="btn btn-primary !px-6 !py-3 text-base mt-6" onClick={onNext}>
        Поехали →
      </button>
    </div>
  );
}

function Hint({ icon, title, text }: { icon: string; title: string; text: string }) {
  return (
    <div className="card p-4">
      <div className="text-2xl mb-2">{icon}</div>
      <div className="font-medium text-sm">{title}</div>
      <div className="text-xs text-[var(--fg-muted)] mt-1">{text}</div>
    </div>
  );
}

function TemplatePicker({
  templates,
  creatingTemplateId,
  onPick,
  onCreate,
}: {
  templates: Template[];
  creatingTemplateId: string | null;
  onPick: (t: Template) => void;
  onCreate: (t: Template) => void;
}) {
  return (
    <div className="space-y-6">
      <div className="text-center space-y-2">
        <h2 className="text-3xl font-semibold tracking-tight">Выбери шаблон</h2>
        <p className="text-[var(--fg-muted)]">Можно создать сразу или подкрутить на следующем шаге</p>
      </div>
      <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
        {templates.map((t) => (
          <div
            key={t.id}
            className="card p-5 text-left hover:border-[var(--accent)] hover:-translate-y-0.5 transition-all"
          >
            <button
              type="button"
              onClick={() => onPick(t)}
              disabled={Boolean(creatingTemplateId)}
              className="w-full text-left cursor-pointer disabled:cursor-not-allowed disabled:opacity-70"
            >
              <div className="flex items-start gap-3">
                <div className="text-3xl">{t.emoji}</div>
                <div className="flex-1 min-w-0">
                  <div className="font-semibold">{t.name}</div>
                  <div className="text-sm text-[var(--fg-muted)] mt-1">{t.tagline}</div>
                </div>
              </div>
            </button>
            <div className="flex flex-wrap items-center gap-2 mt-4">
              <button
                type="button"
                onClick={() => onCreate(t)}
                disabled={Boolean(creatingTemplateId)}
                className="btn btn-primary !py-1.5 !px-3 text-xs"
              >
                {creatingTemplateId === t.id ? "Создаю..." : "Создать в 1 клик"}
              </button>
              <button
                type="button"
                onClick={() => onPick(t)}
                disabled={Boolean(creatingTemplateId)}
                className="btn btn-secondary !py-1.5 !px-3 text-xs"
              >
                Настроить
              </button>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

function Customize({
  draft,
  onChange,
  onBack,
  onSave,
  saving,
}: {
  draft: AgentDraft;
  onChange: (d: AgentDraft) => void;
  onBack: () => void;
  onSave: () => void;
  saving: boolean;
}) {
  const update = <K extends keyof AgentDraft>(key: K, value: AgentDraft[K]) =>
    onChange({ ...draft, [key]: value });

  const toggleCap = (c: Capability) => {
    const has = draft.capabilities.includes(c);
    update("capabilities", has ? draft.capabilities.filter((x) => x !== c) : [...draft.capabilities, c]);
  };

  return (
    <div className="space-y-6">
      <div className="text-center space-y-2">
        <h2 className="text-3xl font-semibold tracking-tight">Настрой под себя</h2>
        <p className="text-[var(--fg-muted)]">Можно изменить потом в любой момент</p>
      </div>

      <div className="card p-6 space-y-5">
        <div className="flex gap-3 items-start">
          <input
            className="input !w-16 text-center text-2xl"
            value={draft.emoji}
            onChange={(e) => update("emoji", e.target.value.slice(0, 4))}
            maxLength={4}
          />
          <div className="flex-1">
            <label className="text-xs text-[var(--fg-muted)] block mb-1">Имя</label>
            <input
              className="input"
              value={draft.name}
              onChange={(e) => update("name", e.target.value)}
              placeholder="Почтовый агент"
            />
          </div>
        </div>

        <div>
          <label className="text-xs text-[var(--fg-muted)] block mb-1">Короткое описание</label>
          <input
            className="input"
            value={draft.description}
            onChange={(e) => update("description", e.target.value)}
            placeholder="Что он делает"
          />
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
            className="input min-h-36 font-mono text-xs leading-relaxed"
            value={draft.systemPrompt}
            onChange={(e) => update("systemPrompt", e.target.value)}
            placeholder="Ты — …"
          />
        </div>
      </div>

      <div className="flex gap-3 justify-between">
        <button className="btn btn-ghost" onClick={onBack}>← Назад</button>
        <button className="btn btn-primary !px-6" onClick={onSave} disabled={saving || !draft.name.trim()}>
          {saving ? "Сохраняю..." : "Создать агента"}
        </button>
      </div>
    </div>
  );
}

function Done({ onChat, onDashboard }: { onChat: () => void; onDashboard: () => void }) {
  return (
    <div className="text-center space-y-6">
      <div className="text-7xl">🎉</div>
      <h2 className="text-4xl font-semibold tracking-tight">Готово</h2>
      <p className="text-[var(--fg-muted)]">
        Агент создан и готов к работе. Запусти чат или смотри всех агентов.
      </p>
      <div className="flex gap-3 justify-center pt-2">
        <button className="btn btn-secondary" onClick={onDashboard}>Ко всем агентам</button>
        <button className="btn btn-primary" onClick={onChat}>Открыть чат →</button>
      </div>
    </div>
  );
}
