import { notFound } from "next/navigation";
import { requireUser } from "@/lib/auth";
import { getWebSiteDetail } from "@/lib/web-mcp/storage";

export const dynamic = "force-dynamic";

function formatDate(ts: number | null) {
  if (!ts) return "—";
  return new Date(ts).toLocaleString("ru-RU");
}

export default async function WebMcpSitePage({ params }: { params: Promise<{ siteKey: string }> }) {
  const user = await requireUser();
  const { siteKey } = await params;
  const detail = getWebSiteDetail(user.id, siteKey);
  if (!detail) notFound();

  const { site, pages, edges, notes } = detail;

  return (
    <div className="flex-1 px-6 py-10 max-w-6xl w-full mx-auto space-y-8">
      <section className="card p-6">
        <div className="flex items-start justify-between gap-6">
          <div className="min-w-0">
            <div className="text-xs uppercase tracking-wide text-[var(--fg-dim)]">Web MCP workspace</div>
            <h1 className="text-3xl font-semibold tracking-tight mt-1">{site.label}</h1>
            <div className="text-sm text-[var(--fg-muted)] mt-2 break-all">{site.seedUrl}</div>
          </div>
          <div className="text-right text-xs text-[var(--fg-muted)]">
            <div>Обновлено: {formatDate(site.updatedAt)}</div>
            <div>Последний визит: {formatDate(site.lastVisitAt)}</div>
          </div>
        </div>

        <div className="grid grid-cols-1 lg:grid-cols-4 gap-3 mt-6">
          <Metric label="Pages" value={String(site.pageCount)} />
          <Metric label="Edges" value={String(site.edgeCount)} />
          <Metric label="Notes" value={String(site.noteCount)} />
          <Metric label="Host" value={site.primaryHost} />
        </div>

        <div className="mt-6 space-y-3">
          <div>
            <div className="text-xs text-[var(--fg-muted)] mb-1">Цель</div>
            <div className="text-sm leading-relaxed">{site.goal}</div>
          </div>
          <div>
            <div className="text-xs text-[var(--fg-muted)] mb-1">Папка памяти</div>
            <code className="text-xs bg-[var(--bg-softer)] border border-[var(--border)] rounded-lg px-3 py-2 inline-block break-all">
              {site.siteDir}
            </code>
          </div>
        </div>
      </section>

      <section className="grid grid-cols-1 xl:grid-cols-[1.2fr_0.8fr] gap-6">
        <div className="space-y-6">
          <div className="card p-5">
            <div className="flex items-center justify-between mb-4">
              <h2 className="text-lg font-medium">Страницы</h2>
              <span className="text-xs text-[var(--fg-muted)]">{pages.length} visited</span>
            </div>

            <div className="space-y-3">
              {pages.length === 0 ? (
                <EmptyState text="Снимков страниц пока нет. Их можно писать через `/api/web-mcp/sites/:siteKey/pages`." />
              ) : (
                pages.map((page) => (
                  <div key={page.url} className="border border-[var(--border)] rounded-xl p-4 bg-[var(--bg-softer)]">
                    <div className="flex items-start justify-between gap-4">
                      <div className="min-w-0">
                        <div className="font-medium truncate">{page.title || page.pathname}</div>
                        <div className="text-xs text-[var(--fg-muted)] mt-1 break-all">{page.url}</div>
                      </div>
                      <span className="text-[10px] uppercase tracking-wide text-[var(--fg-dim)]">
                        {page.goalState}
                      </span>
                    </div>
                    {page.summary && (
                      <div className="text-sm text-[var(--fg-muted)] mt-3 leading-relaxed">
                        {page.summary}
                      </div>
                    )}
                    {page.plan && (
                      <div className="text-xs text-[var(--fg-muted)] mt-3 leading-relaxed">
                        План: {page.plan}
                      </div>
                    )}
                    <div className="flex flex-wrap gap-2 mt-4 text-[11px] text-[var(--fg-muted)]">
                      <span className="chip">{page.linkCount} links</span>
                      <span className="chip">{page.host}</span>
                      <span className="chip">{formatDate(page.visitedAt)}</span>
                    </div>
                    <div className="text-[11px] text-[var(--fg-dim)] mt-3 font-mono break-all">
                      {page.snapshotFile}
                    </div>
                  </div>
                ))
              )}
            </div>
          </div>

          <div className="card p-5">
            <div className="flex items-center justify-between mb-4">
              <h2 className="text-lg font-medium">Граф переходов</h2>
              <span className="text-xs text-[var(--fg-muted)]">{edges.length} edges</span>
            </div>

            <div className="space-y-2 max-h-[520px] overflow-y-auto pr-1">
              {edges.length === 0 ? (
                <EmptyState text="Рёбер пока нет. Они появляются автоматически, когда сохраняется страница с outgoing links." />
              ) : (
                edges.map((edge) => (
                  <div key={`${edge.fromUrl}-${edge.toUrl}`} className="text-xs border border-[var(--border)] rounded-lg p-3 bg-[var(--bg-softer)]">
                    <div className="break-all text-[var(--fg)]">{edge.fromUrl}</div>
                    <div className="text-[var(--fg-dim)] my-1">↓</div>
                    <div className="break-all text-[var(--fg-muted)]">{edge.toUrl}</div>
                    {edge.text && <div className="mt-2 text-[var(--fg-dim)]">anchor: {edge.text}</div>}
                  </div>
                ))
              )}
            </div>
          </div>
        </div>

        <div className="card p-5">
          <div className="flex items-center justify-between mb-4">
            <h2 className="text-lg font-medium">Notes</h2>
            <span className="text-xs text-[var(--fg-muted)]">{notes.length} entries</span>
          </div>

          <div className="space-y-3 max-h-[1080px] overflow-y-auto pr-1">
            {notes.length === 0 ? (
              <EmptyState text="Заметок пока нет. Их можно писать через `/api/web-mcp/sites/:siteKey/notes`." />
            ) : (
              notes.map((note) => (
                <div key={note.id} className="border border-[var(--border)] rounded-xl p-4 bg-[var(--bg-softer)]">
                  <div className="flex items-start justify-between gap-3">
                    <div>
                      <div className="font-medium">{note.title}</div>
                      <div className="text-[11px] text-[var(--fg-dim)] mt-1">
                        {note.kind} · {formatDate(note.createdAt)}
                      </div>
                    </div>
                  </div>
                  {note.url && (
                    <div className="text-xs text-[var(--fg-muted)] mt-3 break-all">{note.url}</div>
                  )}
                  <pre className="mt-3 text-xs leading-relaxed whitespace-pre-wrap font-mono text-[var(--fg-muted)]">
                    {note.content}
                  </pre>
                  <div className="text-[11px] text-[var(--fg-dim)] mt-3 font-mono break-all">
                    {note.filePath}
                  </div>
                </div>
              ))
            )}
          </div>
        </div>
      </section>
    </div>
  );
}

function Metric({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-xl border border-[var(--border)] bg-[var(--bg-softer)] p-4">
      <div className="text-xs uppercase tracking-wide text-[var(--fg-dim)]">{label}</div>
      <div className="text-xl font-semibold mt-2">{value}</div>
    </div>
  );
}

function EmptyState({ text }: { text: string }) {
  return (
    <div className="text-sm text-[var(--fg-muted)] border border-dashed border-[var(--border)] rounded-xl p-5">
      {text}
    </div>
  );
}
