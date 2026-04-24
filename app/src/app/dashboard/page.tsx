import Link from "next/link";
import { requireUser } from "@/server/auth";
import { listAgents } from "@/server/db";
import { CAPABILITY_LABELS, MODEL_LABELS } from "@/shared/types";

export const dynamic = "force-dynamic";

export default async function Dashboard() {
  const user = await requireUser();
  const agents = listAgents(user.id);

  if (agents.length === 0) {
    return (
      <div className="flex-1 flex flex-col items-center justify-center gap-4 text-center">
        <div className="text-6xl">🕊️</div>
        <h2 className="text-2xl font-semibold">Пока ни одного агента</h2>
        <Link href="/onboarding" className="btn btn-primary">Создать первого →</Link>
      </div>
    );
  }

  return (
    <div className="flex-1 px-6 py-10 max-w-5xl w-full mx-auto">
      <div className="flex items-end justify-between mb-8">
        <div>
          <h1 className="text-3xl font-semibold tracking-tight">Твои агенты</h1>
          <p className="text-[var(--fg-muted)] text-sm mt-1">{agents.length} агент(а/ов) готовы к работе</p>
        </div>
        <Link href="/onboarding" className="btn btn-primary">+ Новый</Link>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
        {agents.map((a) => (
          <Link key={a.id} href={`/chat/${a.id}`} className="card p-5 hover:border-[var(--accent)] hover:-translate-y-0.5 transition-all group">
            <div className="flex items-start gap-4">
              <div className="text-4xl">{a.emoji}</div>
              <div className="flex-1 min-w-0">
                <div className="flex items-center gap-2">
                  <div className="font-semibold truncate">{a.name}</div>
                  <span className="text-[10px] uppercase tracking-wide text-[var(--fg-dim)]">
                    {MODEL_LABELS[a.model].label}
                  </span>
                </div>
                <div className="text-sm text-[var(--fg-muted)] mt-1 line-clamp-2">
                  {a.description || "—"}
                </div>
                <div className="flex flex-wrap gap-1.5 mt-3">
                  {a.capabilities.slice(0, 5).map((c) => (
                    <span key={c} className="text-[10px] bg-[var(--bg-softer)] border border-[var(--border)] px-2 py-0.5 rounded-full">
                      {CAPABILITY_LABELS[c].icon} {CAPABILITY_LABELS[c].label}
                    </span>
                  ))}
                </div>
              </div>
            </div>
          </Link>
        ))}
      </div>
    </div>
  );
}
