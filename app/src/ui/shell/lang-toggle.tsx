"use client";

import { useLang } from "@/client/i18n";

export default function LangToggle({ className = "" }: { className?: string }) {
  const [lang, setLang] = useLang();

  return (
    <div
      className={`inline-flex items-center rounded-full p-0.5 text-[10px] font-mono tracking-wider ${className}`}
      style={{ background: "var(--bg-soft)", border: "1px solid var(--border)" }}
      role="group"
      aria-label="Language"
    >
      <button
        type="button"
        onClick={() => setLang("en")}
        aria-pressed={lang === "en"}
        className="px-2 py-0.5 rounded-full transition-colors"
        style={
          lang === "en"
            ? { background: "var(--fg)", color: "var(--bg)" }
            : { color: "var(--fg-dim)" }
        }
      >
        EN
      </button>
      <button
        type="button"
        onClick={() => setLang("ru")}
        aria-pressed={lang === "ru"}
        className="px-2 py-0.5 rounded-full transition-colors"
        style={
          lang === "ru"
            ? { background: "var(--fg)", color: "var(--bg)" }
            : { color: "var(--fg-dim)" }
        }
      >
        RU
      </button>
    </div>
  );
}
