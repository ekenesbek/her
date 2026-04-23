"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";

export default function CreateSiteForm() {
  const router = useRouter();
  const [url, setUrl] = useState("");
  const [goal, setGoal] = useState("");
  const [label, setLabel] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function submit() {
    if (!url.trim()) return;
    setSaving(true);
    setError(null);
    try {
      const res = await fetch("/api/web-mcp/sites", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          url: url.trim(),
          goal: goal.trim() || undefined,
          label: label.trim() || undefined,
        }),
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const site = await res.json() as { siteKey: string };
      router.push(`/web-mcp/${site.siteKey}`);
      router.refresh();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Не удалось создать workspace");
    } finally {
      setSaving(false);
    }
  }

  return (
    <div className="card p-5 space-y-4">
      <div>
        <div className="text-sm font-medium">Новый сайт</div>
        <div className="text-xs text-[var(--fg-muted)] mt-1">
          Создаёт отдельный workspace под граф страниц, заметки и снимки layout.
        </div>
      </div>

      <div className="grid grid-cols-1 gap-3">
        <input
          className="input"
          placeholder="https://example.com"
          value={url}
          onChange={(e) => setUrl(e.target.value)}
        />
        <input
          className="input"
          placeholder="Короткое имя, если не хочешь использовать hostname"
          value={label}
          onChange={(e) => setLabel(e.target.value)}
        />
        <textarea
          className="input min-h-24"
          placeholder="Цель обхода: что агент должен понять, куда дойти, что сохранить"
          value={goal}
          onChange={(e) => setGoal(e.target.value)}
        />
      </div>

      {error && <div className="text-sm text-[var(--danger)]">{error}</div>}

      <div className="flex justify-end">
        <button className="btn btn-primary" onClick={submit} disabled={saving || !url.trim()}>
          {saving ? "Создаю..." : "Создать workspace"}
        </button>
      </div>
    </div>
  );
}
