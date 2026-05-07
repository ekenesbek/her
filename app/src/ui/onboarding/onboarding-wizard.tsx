"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import type { Template } from "@/shared/templates";
import { useLang, t, type Lang } from "@/client/i18n";
import LangToggle from "@/ui/shell/lang-toggle";

const KEYS_STORAGE = "her.keys.v1";
type KeyId = "apple" | "google" | "contacts" | "calendar";
type KeyStatus = "idle" | "connecting" | "connected";

type Step = "welcome" | "browser" | "keys" | "ready";

const STEPS: Step[] = ["welcome", "browser", "keys", "ready"];
const STEP_TITLE_KEYS: Record<Step, "onb.step.welcome" | "onb.step.browser" | "onb.step.keys" | "onb.step.ready"> = {
  welcome: "onb.step.welcome",
  browser: "onb.step.browser",
  keys: "onb.step.keys",
  ready: "onb.step.ready",
};

const DEFAULT_TEMPLATE_ID = "personal-assistant";
const DEFAULT_KEYS: Record<KeyId, KeyStatus> = {
  apple: "idle",
  google: "idle",
  contacts: "idle",
  calendar: "idle",
};

function readStoredKeys(): Record<KeyId, KeyStatus> {
  if (typeof window === "undefined") return DEFAULT_KEYS;

  try {
    const raw = window.localStorage.getItem(KEYS_STORAGE);
    if (!raw) return DEFAULT_KEYS;
    const parsed = JSON.parse(raw) as Partial<Record<KeyId, KeyStatus>>;
    return { ...DEFAULT_KEYS, ...parsed };
  } catch {
    return DEFAULT_KEYS;
  }
}

export default function OnboardingWizard({ templates }: { templates: Template[] }) {
  const router = useRouter();
  const [lang] = useLang();
  const [step, setStep] = useState<Step>("welcome");
  const [browserConnected, setBrowserConnected] = useState(false);
  const [permissions, setPermissions] = useState({
    readTabs: true,
    fillForms: true,
    openPages: true,
    payments: false,
  });
  const [keys, setKeys] = useState<Record<KeyId, KeyStatus>>(() => readStoredKeys());

  useEffect(() => {
    try {
      window.localStorage.setItem(KEYS_STORAGE, JSON.stringify(keys));
    } catch {
      /* ignore */
    }
  }, [keys]);

  const connectKey = (id: KeyId) => {
    setKeys((k) => {
      if (k[id] === "connected") return { ...k, [id]: "idle" };
      if (k[id] === "connecting") return k;
      return { ...k, [id]: "connecting" };
    });
    window.setTimeout(() => {
      setKeys((k) => (k[id] === "connecting" ? { ...k, [id]: "connected" } : k));
    }, 700);
  };
  const [saving, setSaving] = useState(false);

  const goto = (s: Step) => setStep(s);

  async function finish() {
    const template =
      templates.find((tpl) => tpl.id === DEFAULT_TEMPLATE_ID) ?? templates[0];
    if (!template) {
      alert(t(lang, "onb.fail.noTpl"));
      return;
    }
    setSaving(true);
    try {
      const res = await fetch("/api/agents", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          ...template.draft,
          name: "Her",
          emoji: "◉",
          description:
            lang === "en" ? "Your personal agent." : "Твой персональный агент.",
        }),
      });
      if (!res.ok) throw new Error("save failed");
      const agent = await res.json();
      router.push(`/chat/${agent.id}`);
    } catch (e) {
      alert(t(lang, "onb.fail.save"));
      console.error(e);
      setSaving(false);
    }
  }

  return (
    <div className="flex-1 flex justify-center relative">
      <PaperGrain />
      <div className="absolute top-5 right-5 z-10">
        <LangToggle />
      </div>
      <div className="relative w-full max-w-[460px] flex flex-col px-6 sm:px-8 py-10 min-h-[680px]">
        <ProgressIndicator step={step} lang={lang} />

        <div className="flex-1 flex flex-col mt-7">
          {step === "welcome" && <Welcome lang={lang} onNext={() => goto("browser")} />}
          {step === "browser" && (
            <BrowserStep
              lang={lang}
              connected={browserConnected}
              onConnect={() => setBrowserConnected(true)}
              permissions={permissions}
              onToggle={(k) =>
                setPermissions((p) => ({ ...p, [k]: !p[k as keyof typeof p] }))
              }
              onBack={() => goto("welcome")}
              onNext={() => goto("keys")}
            />
          )}
          {step === "keys" && (
            <KeysStep
              lang={lang}
              keys={keys}
              onConnect={connectKey}
              onBack={() => goto("browser")}
              onNext={() => goto("ready")}
            />
          )}
          {step === "ready" && (
            <ReadyStep
              lang={lang}
              saving={saving}
              onBack={() => goto("keys")}
              onFinish={finish}
            />
          )}
        </div>
      </div>
    </div>
  );
}

function PaperGrain() {
  return (
    <div
      aria-hidden
      className="pointer-events-none absolute inset-0"
      style={{
        background:
          "radial-gradient(circle at 18% 12%, rgba(0,0,0,0.03), transparent 42%), radial-gradient(circle at 82% 88%, rgba(0,0,0,0.02), transparent 42%)",
      }}
    />
  );
}

function ProgressIndicator({ step, lang }: { step: Step; lang: Lang }) {
  const idx = STEPS.indexOf(step);
  const pct = ((idx + 1) / STEPS.length) * 100;
  const num = String(idx + 1).padStart(2, "0");
  const total = String(STEPS.length).padStart(2, "0");
  return (
    <div className="flex items-center gap-2 font-mono text-[10px] tracking-[0.15em] text-[var(--fg-dim)] uppercase">
      <span>
        {num} / {total}
      </span>
      <div className="flex-1 h-[2px] bg-[var(--border)] relative">
        <div
          className="absolute inset-y-0 left-0 bg-[var(--accent)] transition-all duration-500"
          style={{ width: `${pct}%` }}
        />
      </div>
      <span>{t(lang, STEP_TITLE_KEYS[step])}</span>
    </div>
  );
}

/* ─────────── Welcome ─────────── */

function Welcome({ lang, onNext }: { lang: Lang; onNext: () => void }) {
  return (
    <>
      <h1 className="mt-10 font-serif font-light tracking-tight text-[48px] sm:text-[56px] leading-[0.95] text-[var(--fg)]">
        {t(lang, "onb.welcome.hiHead")}
        <br />
        <em className="italic font-normal">{t(lang, "onb.welcome.iAmYour")}</em>
        <br />
        Her.
      </h1>

      <p className="mt-7 text-[14px] leading-[1.55] text-[var(--fg-muted)] max-w-[320px]">
        {t(lang, "onb.welcome.body")}
      </p>

      <div className="mt-auto flex flex-col gap-2.5">
        <StepPreview n={1} label={t(lang, "onb.welcome.s1")} sub={t(lang, "onb.welcome.s1s")} />
        <StepPreview n={2} label={t(lang, "onb.welcome.s2")} sub={t(lang, "onb.welcome.s2s")} />
        <StepPreview n={3} label={t(lang, "onb.welcome.s3")} sub={t(lang, "onb.welcome.s3s")} />

        <div className="flex gap-2.5 mt-4">
          <button
            onClick={onNext}
            className="flex-1 h-12 rounded-full bg-[var(--fg)] text-[var(--bg)] text-sm font-medium tracking-wide cursor-pointer hover:brightness-110 inline-flex items-center justify-center gap-2"
          >
            {t(lang, "onb.welcome.go")}
            <span aria-hidden>→</span>
          </button>
          <button
            className="w-12 h-12 rounded-full border border-[var(--border-strong)] text-[var(--fg-muted)] text-lg leading-none cursor-pointer hover:text-[var(--fg)]"
            aria-label={t(lang, "onb.welcome.later")}
            onClick={onNext}
          >
            ··
          </button>
        </div>
      </div>
    </>
  );
}

function StepPreview({ n, label, sub }: { n: number; label: string; sub: string }) {
  return (
    <div className="flex items-center gap-3 pb-2.5 border-b border-[var(--border)]">
      <div className="font-mono text-[10px] text-[var(--fg-dim)] w-4 tabular-nums">0{n}</div>
      <div className="flex-1 min-w-0">
        <div className="text-[14px] font-medium text-[var(--fg)] leading-tight">{label}</div>
        <div className="text-[11px] font-mono text-[var(--fg-dim)] mt-0.5">{sub}</div>
      </div>
      <span aria-hidden className="text-[var(--fg-dim)] text-sm">
        →
      </span>
    </div>
  );
}

/* ─────────── Browser step ─────────── */

function BrowserStep({
  lang,
  connected,
  onConnect,
  permissions,
  onToggle,
  onBack,
  onNext,
}: {
  lang: Lang;
  connected: boolean;
  onConnect: () => void;
  permissions: Record<string, boolean>;
  onToggle: (k: string) => void;
  onBack: () => void;
  onNext: () => void;
}) {
  const perms: Array<{ key: keyof typeof permissions; label: string; hint?: string }> = [
    { key: "readTabs", label: t(lang, "onb.browser.readTabs") },
    { key: "fillForms", label: t(lang, "onb.browser.fillForms") },
    { key: "openPages", label: t(lang, "onb.browser.openPages") },
    { key: "payments", label: t(lang, "onb.browser.payments"), hint: t(lang, "onb.browser.paymentsHint") },
  ];

  return (
    <>
      <h2 className="mt-8 font-serif text-[36px] sm:text-[40px] leading-[1.02] tracking-tight font-light text-[var(--fg)]">
        {t(lang, "onb.browser.title")}
        <br />
        <em className="italic font-normal text-[var(--fg-muted)]">{t(lang, "onb.browser.titleEm")}</em>
      </h2>

      <p className="mt-4 text-[13px] leading-[1.55] text-[var(--fg-muted)]">
        {t(lang, "onb.browser.body")}
      </p>

      <div className="mt-6 p-5 rounded-2xl bg-[var(--bg-soft)] border border-[var(--border)]">
        <div className="flex items-center gap-3.5">
          <div className="w-11 h-11 rounded-full bg-[var(--bg)] border border-[var(--border-strong)] grid place-items-center text-[var(--fg)]">
            <ChromeIcon />
          </div>
          <div className="relative flex-1 h-px bg-[var(--border)]">
            <span className="absolute -top-[3px] left-[28%] w-[7px] h-[7px] rounded-full bg-[var(--accent)] her-pulse" />
            <span
              className="absolute -top-[3px] left-[62%] w-[7px] h-[7px] rounded-full bg-[var(--accent)] her-pulse"
              style={{ animationDelay: "0.3s" }}
            />
          </div>
          <div className="w-11 h-11 rounded-full bg-[var(--fg)] text-[var(--bg)] grid place-items-center font-serif italic text-base leading-none">
            m
          </div>
        </div>
        <div className="mt-3.5 flex justify-between font-mono text-[10px] text-[var(--fg-dim)] tracking-wide">
          <span>Chrome MCP</span>
          <span>→</span>
          <span>Her</span>
        </div>
        <div className="mt-2.5 font-mono text-[10px] text-[var(--accent)] bg-[var(--accent-soft)] px-2.5 py-1.5 rounded-md">
          127.0.0.1:12306/mcp
        </div>
      </div>

      <div className="mt-5 flex flex-col gap-2.5">
        {perms.map((p) => (
          <ToggleRow
            key={p.key}
            label={p.label}
            on={permissions[p.key]}
            hint={p.hint}
            onToggle={() => onToggle(p.key as string)}
          />
        ))}
      </div>

      <div className="mt-auto pt-6 flex items-center justify-between gap-3">
        <button
          onClick={onBack}
          className="text-[12px] text-[var(--fg-muted)] hover:text-[var(--fg)] cursor-pointer"
        >
          {t(lang, "onb.common.back")}
        </button>
        <div className="flex gap-2">
          {!connected && (
            <button
              onClick={onConnect}
              className="h-11 px-5 rounded-full border border-[var(--border-strong)] text-[var(--fg)] text-sm cursor-pointer hover:border-[var(--fg)]"
            >
              {t(lang, "onb.browser.connect")}
            </button>
          )}
          <button
            onClick={onNext}
            className="h-11 px-5 rounded-full bg-[var(--fg)] text-[var(--bg)] text-sm font-medium cursor-pointer hover:brightness-110 inline-flex items-center gap-2"
          >
            {t(lang, "onb.common.next")}
            <span aria-hidden>→</span>
          </button>
        </div>
      </div>
    </>
  );
}

function ToggleRow({
  label,
  on,
  hint,
  onToggle,
}: {
  label: string;
  on: boolean;
  hint?: string;
  onToggle: () => void;
}) {
  return (
    <button
      onClick={onToggle}
      className="flex items-center gap-3 text-[12px] cursor-pointer text-left"
      type="button"
    >
      <span
        aria-hidden
        className="inline-block w-7 h-4 rounded-full relative transition-colors"
        style={{
          background: on ? "var(--accent)" : "var(--border-strong)",
        }}
      >
        <span
          className="absolute top-0.5 w-3 h-3 rounded-full bg-[var(--bg)] transition-all"
          style={{ left: on ? 14 : 2 }}
        />
      </span>
      <span style={{ color: on ? "var(--fg)" : "var(--fg-dim)" }}>{label}</span>
      {!on && hint && (
        <span className="ml-auto font-mono text-[9px] text-[var(--fg-dim)] tracking-wide">
          {hint}
        </span>
      )}
    </button>
  );
}

function ChromeIcon() {
  return (
    <svg
      width={22}
      height={22}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.5}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
    >
      <path d="M12 3a9 9 0 1 0 7.794 4.5H12M12 3L8 11.5M19.794 7.5L12 12" />
      <circle cx="12" cy="12" r="3" />
    </svg>
  );
}

/* ─────────── Keys step ─────────── */

function KeysStep({
  lang,
  keys,
  onConnect,
  onBack,
  onNext,
}: {
  lang: Lang;
  keys: Record<KeyId, KeyStatus>;
  onConnect: (id: KeyId) => void;
  onBack: () => void;
  onNext: () => void;
}) {
  const items: Array<{
    id: KeyId;
    title: string;
    sub: string;
    glyph: string;
  }> = [
    { id: "apple", title: t(lang, "onb.keys.apple"), sub: t(lang, "onb.keys.appleSub"), glyph: "" },
    { id: "google", title: t(lang, "onb.keys.google"), sub: t(lang, "onb.keys.googleSub"), glyph: "G" },
    { id: "contacts", title: t(lang, "onb.keys.contacts"), sub: t(lang, "onb.keys.contactsSub"), glyph: "" },
    { id: "calendar", title: t(lang, "onb.keys.calendar"), sub: t(lang, "onb.keys.calendarSub"), glyph: "" },
  ];

  return (
    <>
      <h2 className="mt-8 font-serif text-[36px] sm:text-[40px] leading-[1.02] tracking-tight font-light text-[var(--fg)]">
        {t(lang, "onb.keys.title")} <em className="italic">{t(lang, "onb.keys.titleEm")}</em>.
      </h2>

      <p className="mt-4 text-[13px] leading-[1.55] text-[var(--fg-muted)] max-w-[340px]">
        {t(lang, "onb.keys.body")}
      </p>

      <div className="mt-5 flex items-center gap-2 px-3 py-2 rounded-lg bg-[var(--bg-soft)] border border-[var(--border)]">
        <ShieldIcon />
        <span className="text-[11px] text-[var(--fg-muted)] flex-1">
          {t(lang, "onb.keys.shield")}
        </span>
        <span className="font-mono text-[10px] text-[var(--success)] tracking-wide">
          AES-256
        </span>
      </div>

      <div className="mt-5 flex flex-col gap-2">
        {items.map((it) => (
          <KeyCard
            key={it.id}
            title={it.title}
            sub={it.sub}
            glyph={it.glyph}
            iconId={it.id}
            status={keys[it.id]}
            connectLabel={t(lang, "onb.keys.connect")}
            connectingLabel={t(lang, "onb.keys.connecting")}
            connectedLabel={t(lang, "onb.keys.connected")}
            onClick={() => onConnect(it.id)}
          />
        ))}
      </div>

      <div className="mt-auto pt-6 flex items-center justify-between gap-3">
        <button
          onClick={onBack}
          className="text-[12px] text-[var(--fg-muted)] hover:text-[var(--fg)] cursor-pointer"
        >
          {t(lang, "onb.common.back")}
        </button>
        <div className="flex gap-2">
          <button
            onClick={onNext}
            className="h-11 px-3 rounded-full text-[12px] text-[var(--fg-muted)] hover:text-[var(--fg)] cursor-pointer"
          >
            {t(lang, "onb.common.skip")}
          </button>
          <button
            onClick={onNext}
            className="h-11 px-5 rounded-full bg-[var(--fg)] text-[var(--bg)] text-sm font-medium cursor-pointer hover:brightness-110 inline-flex items-center gap-2"
          >
            {t(lang, "onb.common.next")}
            <span aria-hidden>→</span>
          </button>
        </div>
      </div>
    </>
  );
}

function KeyCard({
  title,
  sub,
  glyph,
  iconId,
  status,
  connectLabel,
  connectingLabel,
  connectedLabel,
  onClick,
}: {
  title: string;
  sub: string;
  glyph: string;
  iconId: KeyId;
  status: KeyStatus;
  connectLabel: string;
  connectingLabel: string;
  connectedLabel: string;
  onClick: () => void;
}) {
  const connected = status === "connected";
  const connecting = status === "connecting";
  const label = connecting ? connectingLabel : connected ? connectedLabel : connectLabel;
  return (
    <div
      className={
        "flex items-center gap-3 p-3 border rounded-xl transition-colors " +
        (connected
          ? "bg-[var(--bg)] border-[var(--fg)]"
          : "bg-[var(--bg-soft)] border-[var(--border)]")
      }
    >
      <div className="w-9 h-9 rounded-full bg-[var(--bg)] border border-[var(--border-strong)] grid place-items-center text-[var(--fg)] shrink-0">
        <KeyGlyph id={iconId} glyph={glyph} />
      </div>
      <div className="flex-1 min-w-0">
        <div className="text-[13px] font-medium text-[var(--fg)] leading-tight truncate">{title}</div>
        <div className="text-[11px] font-mono text-[var(--fg-dim)] mt-0.5 truncate">{sub}</div>
      </div>
      <button
        onClick={onClick}
        disabled={connecting}
        className={
          "h-8 px-3 rounded-full text-[11px] font-medium cursor-pointer transition-colors shrink-0 inline-flex items-center gap-1.5 disabled:cursor-wait " +
          (connected
            ? "bg-[var(--fg)] text-[var(--bg)] border border-[var(--fg)]"
            : connecting
              ? "border border-[var(--border-strong)] text-[var(--fg-muted)]"
              : "border border-[var(--border-strong)] text-[var(--fg)] hover:border-[var(--fg)]")
        }
      >
        {connecting && (
          <span
            className="w-1.5 h-1.5 rounded-full bg-[var(--accent)] her-pulse"
            aria-hidden
          />
        )}
        {label}
      </button>
    </div>
  );
}

function KeyGlyph({ id, glyph }: { id: KeyId; glyph: string }) {
  if (id === "apple") return <AppleGlyph />;
  if (id === "contacts") return <ContactsGlyph />;
  if (id === "calendar") return <CalendarGlyph />;
  return <span className="font-serif text-base">{glyph}</span>;
}

function ContactsGlyph() {
  return (
    <svg width={16} height={16} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.6} strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <circle cx="12" cy="8" r="3.5" />
      <path d="M5 20c1.2-3.5 4-5 7-5s5.8 1.5 7 5" />
    </svg>
  );
}

function CalendarGlyph() {
  return (
    <svg width={16} height={16} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.6} strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <rect x="3.5" y="5" width="17" height="15" rx="2" />
      <path d="M3.5 10h17M8 3v4M16 3v4" />
    </svg>
  );
}

function AppleGlyph() {
  return (
    <svg width={16} height={16} viewBox="0 0 24 24" fill="currentColor" aria-hidden>
      <path d="M17.5 12.5c0-3 2.5-4.5 2.5-4.5-1.5-2-4-2-5-2-2 0-3.5 1.2-4.5 1.2-1 0-2.5-1.2-4-1.2C4 6 2 8 2 11.5c0 4 3 9 5 9 1 0 2-1 3.5-1s2 1 3.5 1c1.5 0 3-2 4-4-2 0-3-2-3-4zm-4-10c1-1 2-2 2-4 0 0-2 0-3 2-1 1-1 2-1 4 1 0 2-1 2-2z" />
    </svg>
  );
}

function ShieldIcon() {
  return (
    <svg
      width={14}
      height={14}
      viewBox="0 0 24 24"
      fill="none"
      stroke="var(--success)"
      strokeWidth={1.5}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
    >
      <path d="M12 3l8 3v6c0 5-3.5 8.5-8 9-4.5-.5-8-4-8-9V6l8-3z" />
    </svg>
  );
}

/* ─────────── Ready step ─────────── */

function ReadyStep({
  lang,
  saving,
  onBack,
  onFinish,
}: {
  lang: Lang;
  saving: boolean;
  onBack: () => void;
  onFinish: () => void;
}) {
  return (
    <>
      <h2 className="mt-10 font-serif font-light tracking-tight text-[48px] sm:text-[56px] leading-[0.95] text-[var(--fg)]">
        {t(lang, "onb.ready.title")}
        <br />
        <em className="italic font-normal text-[var(--accent)]">{t(lang, "onb.ready.titleEm")}</em>
      </h2>

      <p className="mt-7 text-[14px] leading-[1.55] text-[var(--fg-muted)] max-w-[320px]">
        {t(lang, "onb.ready.body")}
      </p>

      <div className="mt-6 p-5 rounded-2xl bg-[var(--bg-soft)] border border-[var(--border)] flex items-center gap-4">
        <div className="w-12 h-12 rounded-full bg-[var(--fg)] text-[var(--bg)] grid place-items-center font-serif italic text-xl leading-none">
          h
        </div>
        <div className="flex-1 min-w-0">
          <div className="font-serif text-lg italic">Her</div>
          <div className="text-[11px] font-mono text-[var(--fg-dim)] mt-0.5">
            claude-sonnet-4-6 · chrome · vault
          </div>
        </div>
      </div>

      <div className="mt-auto flex flex-col gap-2.5 pt-6">
        <button
          onClick={onFinish}
          disabled={saving}
          className="h-12 rounded-full bg-[var(--fg)] text-[var(--bg)] text-sm font-medium tracking-wide cursor-pointer hover:brightness-110 disabled:opacity-60 disabled:cursor-not-allowed inline-flex items-center justify-center gap-2"
        >
          {saving ? t(lang, "onb.ready.assembling") : t(lang, "onb.ready.assemble")}
          {!saving && <span aria-hidden>→</span>}
        </button>
        <button
          onClick={onBack}
          disabled={saving}
          className="text-[12px] text-[var(--fg-muted)] hover:text-[var(--fg)] cursor-pointer disabled:opacity-50"
        >
          {t(lang, "onb.common.back")}
        </button>
      </div>
    </>
  );
}
