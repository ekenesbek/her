import Link from "next/link";
import { requireUser } from "@/server/auth";
import LocationCapture from "@/ui/shell/location-capture";

export const dynamic = "force-dynamic";

export default async function LocationSettingsPage() {
  await requireUser();

  return (
    <div className="flex-1 px-6 py-10 max-w-3xl w-full mx-auto">
      <div className="flex items-center justify-between gap-3 mb-6">
        <Link href="/" className="btn btn-ghost text-sm">← Назад</Link>
        <Link href="/settings/browser" className="btn btn-secondary text-sm">Browser</Link>
      </div>

      <div className="space-y-6">
        <div>
          <h1 className="text-3xl font-semibold tracking-tight">Location</h1>
          <p className="text-sm text-[var(--fg-muted)] mt-2 max-w-2xl leading-relaxed">
            Режим передачи текущей локации агенту для маршрутов, локального поиска, доставки и задач с контекстом места.
          </p>
        </div>

        <div className="card p-6 space-y-4">
          <div>
            <div className="text-sm font-medium">Share location</div>
            <div className="text-xs text-[var(--fg-muted)] mt-1 leading-relaxed">
              `1 раз` очистится после следующего сообщения. `При использовании` живёт в текущей сессии приложения. `Всегда` сохраняется между сессиями.
            </div>
          </div>
          <LocationCapture />
        </div>
      </div>
    </div>
  );
}
