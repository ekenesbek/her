import Link from "next/link";
import { requireUser } from "@/server/auth";
import { listWebSites, readOrInitCommonWebMemory } from "@/server/web-mcp/storage";
import CreateSiteForm from "@/ui/web-mcp/create-site-form";

export const dynamic = "force-dynamic";

export default async function WebMcpPage() {
  const user = await requireUser();
  const sites = listWebSites(user.id);
  const commonMemory = readOrInitCommonWebMemory(user.id);
  const totals = sites.reduce(
    (acc, site) => ({
      pages: acc.pages + site.pageCount,
      edges: acc.edges + site.edgeCount,
      notes: acc.notes + site.noteCount,
    }),
    { pages: 0, edges: 0, notes: 0 },
  );

  return (
    <div className="flex-1 px-6 py-10 max-w-6xl w-full mx-auto space-y-8">
      <nav className="flex items-center justify-between gap-3">
        <Link href="/" className="btn btn-ghost text-sm">
          ← Назад в чат
        </Link>
        <Link href="/settings/browser" className="btn btn-secondary text-sm">
          Chrome MCP
        </Link>
      </nav>

      <div className="flex items-end justify-between gap-6">
        <div>
          <h1 className="text-3xl font-semibold tracking-tight">Web MCP</h1>
          <p className="text-sm text-[var(--fg-muted)] mt-2 max-w-2xl leading-relaxed">
            Память по сайтам: отдельный workspace на каждый домен, граф переходов, заметки и снимки страниц.
          </p>
        </div>
      </div>

      <section className="grid grid-cols-1 sm:grid-cols-4 gap-3">
        <Metric label="Sites" value={String(sites.length)} />
        <Metric label="Pages" value={String(totals.pages)} />
        <Metric label="Edges" value={String(totals.edges)} />
        <Metric label="Notes" value={String(totals.notes)} />
      </section>

      <CreateSiteForm />

      <section className="card p-5">
        <div className="flex items-center justify-between gap-3 mb-3">
          <h2 className="text-lg font-medium">Common memory</h2>
          <code className="text-[11px] text-[var(--fg-dim)] break-all">
            .data/web-mcp/users/{user.id}/common.md
          </code>
        </div>
        <pre className="max-h-72 overflow-y-auto text-xs leading-relaxed whitespace-pre-wrap font-mono text-[var(--fg-muted)]">
          {commonMemory}
        </pre>
      </section>

      <section className="space-y-4">
        <div className="flex items-center justify-between">
          <h2 className="text-lg font-medium">Сайты</h2>
          <div className="text-xs text-[var(--fg-muted)]">{sites.length} workspace</div>
        </div>

        {sites.length === 0 ? (
          <div className="card p-8 text-center text-[var(--fg-muted)]">
            Пока пусто. Создай первый сайт и начни копить web memory отдельно по домену.
          </div>
        ) : (
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-3">
            {sites.map((site) => (
              <Link
                key={site.siteKey}
                href={`/web-mcp/${site.siteKey}`}
                className="card p-5 hover:border-[var(--accent)] transition-colors"
              >
                <div className="flex items-start justify-between gap-4">
                  <div className="min-w-0">
                    <div className="font-semibold truncate">{site.label}</div>
                    <div className="text-xs text-[var(--fg-muted)] mt-1 truncate">{site.seedUrl}</div>
                  </div>
                  <span className="text-[10px] uppercase tracking-wide text-[var(--fg-dim)]">
                    {site.primaryHost}
                  </span>
                </div>

                <div className="text-sm text-[var(--fg-muted)] mt-4 line-clamp-3">
                  {site.goal}
                </div>

                <div className="flex flex-wrap gap-2 mt-4 text-xs text-[var(--fg-muted)]">
                  <span className="chip chip-active">{site.pageCount} pages</span>
                  <span className="chip">{site.edgeCount} edges</span>
                  <span className="chip">{site.noteCount} notes</span>
                </div>
              </Link>
            ))}
          </div>
        )}
      </section>
    </div>
  );
}

function Metric({ label, value }: { label: string; value: string }) {
  return (
    <div className="card p-4">
      <div className="text-xs uppercase tracking-wide text-[var(--fg-dim)]">{label}</div>
      <div className="text-2xl font-semibold mt-2">{value}</div>
    </div>
  );
}
