"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState } from "react";
import type { BrowserConnection, BrowserSettings } from "@/shared/types";

const DEFAULT_CHROME_MCP_URL = "http://127.0.0.1:12306/mcp";

export default function BrowserSettingsForm({
  initialSettings,
  initialConnection,
}: {
  initialSettings: BrowserSettings;
  initialConnection: BrowserConnection;
}) {
  const router = useRouter();
  const [chromeMcpUrl, setChromeMcpUrl] = useState(initialSettings.chromeMcpUrl ?? "");
  const [connection, setConnection] = useState(initialConnection);
  const [saving, setSaving] = useState(false);
  const [savedAt, setSavedAt] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function save() {
    setSaving(true);
    setError(null);

    try {
      const res = await fetch("/api/settings/browser", {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ chromeMcpUrl }),
      });

      if (!res.ok) {
        throw new Error(`HTTP ${res.status}`);
      }

      const payload = (await res.json()) as {
        settings: BrowserSettings;
        connection: BrowserConnection;
      };

      setChromeMcpUrl(payload.settings.chromeMcpUrl ?? "");
      setConnection(payload.connection);
      setSavedAt(Date.now());
      router.refresh();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Не удалось сохранить настройки браузера");
    } finally {
      setSaving(false);
    }
  }

  const connected = Boolean(connection.chromeMcpUrl);

  return (
    <div className="flex-1 px-6 py-10 max-w-3xl w-full mx-auto">
      <div className="flex items-center gap-3 mb-6">
        <Link href="/" className="btn btn-ghost text-sm">← Назад</Link>
        <Link href="/settings/location" className="btn btn-secondary text-sm">Location</Link>
      </div>

      <div className="space-y-6">
        <div>
          <h1 className="text-3xl font-semibold tracking-tight">Browser</h1>
          <p className="text-sm text-[var(--fg-muted)] mt-2 max-w-2xl leading-relaxed">
            По умолчанию Her использует локальный Chrome MCP на 127.0.0.1:12306/mcp и managed Chrome
            из launch-процесса. Свой URL нужен только для кастомного браузерного рантайма.
          </p>
        </div>

        <div
          className={`card p-4 ${
            connected
              ? "border-[var(--accent)] bg-[var(--accent-soft)]"
              : "border-[var(--border)]"
          }`}
        >
          <div className="text-sm font-medium">
            {connected ? "Браузер подключён" : "Браузер пока не подключён"}
          </div>
          <div className="text-xs text-[var(--fg-muted)] mt-1">
            {connection.source === "user" && "Используется твой сохранённый MCP URL."}
            {connection.source === "env" && "Сейчас используется глобальный MCP URL из окружения приложения."}
            {connection.source === "auto" && "Используется автоматический локальный Chrome MCP URL."}
            {connection.source === "none" && "Без MCP URL агент не сможет открыть Gmail или работать с логинами в Chrome."}
          </div>
        </div>

        <div className="card p-6 space-y-4">
          <div>
            <label className="text-xs text-[var(--fg-muted)] block mb-1">Chrome MCP URL</label>
            <input
              className="input"
              value={chromeMcpUrl}
              onChange={(e) => setChromeMcpUrl(e.target.value)}
              placeholder={DEFAULT_CHROME_MCP_URL}
            />
            <div className="text-xs text-[var(--fg-muted)] mt-2 leading-relaxed">
              Ожидается полный URL локального Chrome MCP сервера. Для `mcp-chrome-bridge`
              обычно это `{DEFAULT_CHROME_MCP_URL}`. Пустое значение
              удалит твой персональный override и вернёт приложение к глобальному env URL, если он задан.
            </div>
          </div>

          {error && (
            <div className="card p-3 border-[var(--danger)] text-[var(--danger)] text-sm">
              Ошибка: {error}
            </div>
          )}
        </div>

        <div className="card p-6 space-y-3">
          <div className="text-sm font-medium">Что дальше</div>
          <div className="text-sm text-[var(--fg-muted)] leading-relaxed">
            1. Установи и подключи расширение Chrome MCP, затем нажми Connect в popup.
          </div>
          <div className="text-sm text-[var(--fg-muted)] leading-relaxed">
            2. Сохрани здесь `{DEFAULT_CHROME_MCP_URL}`, если расширение не показывает другой URL.
          </div>
          <div className="text-sm text-[var(--fg-muted)] leading-relaxed">
            3. Открой браузерного агента и давай ему задачу напрямую, например поиск письма в Gmail.
          </div>
        </div>

        <div className="flex items-center justify-end gap-3">
          {savedAt && <span className="text-xs text-[var(--fg-muted)]">Сохранено</span>}
          <button className="btn btn-primary" onClick={save} disabled={saving}>
            {saving ? "Сохраняю..." : "Сохранить"}
          </button>
        </div>
      </div>
    </div>
  );
}
