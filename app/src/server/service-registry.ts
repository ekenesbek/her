import { randomUUID } from "node:crypto";
import { getDb } from "./db";
import { getSiteFamilyHost } from "./web-mcp/core/url";

export type ServiceKind =
  | "unknown"
  | "mail"
  | "calendar"
  | "contacts"
  | "chat"
  | "docs"
  | "project"
  | "code"
  | "crm"
  | "finance"
  | "social"
  | "media"
  | "search"
  | "shopping"
  | "travel"
  | "taxi"
  | "maps"
  | "delivery"
  | "weather"
  | "local_services";

type FingerprintRule = {
  match: RegExp;
  kind: ServiceKind;
  mcpSlug?: string;
};

const RULES: FingerprintRule[] = [
  { match: /^(mail\.google\.com|gmail\.com)$/i, kind: "mail", mcpSlug: "gmail" },
  { match: /^calendar\.google\.com$/i, kind: "calendar", mcpSlug: "google-calendar" },
  { match: /^contacts\.google\.com$/i, kind: "contacts", mcpSlug: "google-contacts" },
  { match: /^(drive|docs|sheets|slides)\.google\.com$/i, kind: "docs", mcpSlug: "google-drive" },
  { match: /^(www\.)?notion\.(so|com)$/i, kind: "docs", mcpSlug: "notion" },
  { match: /^(www\.)?linear\.app$/i, kind: "project", mcpSlug: "linear" },
  { match: /^(www\.)?figma\.com$/i, kind: "docs", mcpSlug: "figma" },
  { match: /^(www\.)?github\.com$/i, kind: "code", mcpSlug: "github" },
  { match: /^(www\.)?gitlab\.com$/i, kind: "code", mcpSlug: "gitlab" },
  { match: /^(app\.)?slack\.com$/i, kind: "chat", mcpSlug: "slack" },
  { match: /^(web\.)?telegram\.org$/i, kind: "chat" },
  { match: /^(www\.)?youtube\.com$/i, kind: "media" },
  { match: /^(www\.)?(duckduckgo|bing|google)\.com$/i, kind: "search" },
  { match: /^(www\.)?amazon\.(com|co\.uk|de|fr)$/i, kind: "shopping" },
  { match: /(?:^|\.)uber\.com$/i, kind: "taxi" },
  { match: /(?:^|\.)bolt\.eu$/i, kind: "taxi" },
  { match: /(?:^|\.)yango\.com$/i, kind: "taxi" },
  { match: /(?:^|\.)taxi\.yandex\./i, kind: "taxi" },
  { match: /(?:^|\.)maps\.(google|yandex)\./i, kind: "maps" },
  { match: /(?:^|\.)weather\./i, kind: "weather" },
  { match: /(?:doordash|ubereats|wolt|glovo|deliveroo)\./i, kind: "delivery" },
  { match: /\.(bank|chase|revolut|wise)\./i, kind: "finance" },
];

export function fingerprintOrigin(origin: string): { kind: ServiceKind; mcpSlug?: string } {
  const host = safeHost(origin);
  if (!host) return { kind: "unknown" };
  for (const rule of RULES) {
    if (rule.match.test(host)) return { kind: rule.kind, mcpSlug: rule.mcpSlug };
  }
  return { kind: "unknown" };
}

function safeHost(origin: string): string | null {
  try {
    return new URL(origin).hostname;
  } catch {
    return null;
  }
}

export type ServiceRegistryRow = {
  userId: string;
  origin: string;
  kind: ServiceKind;
  loggedIn: boolean;
  hasMcp: boolean;
  mcpSlug: string | null;
  autoProvisioned: boolean;
  firstSeen: number;
  lastSeen: number;
  visitCount: number;
};

export function observeVisit(params: {
  userId: string;
  origin: string;
  loggedIn: boolean;
}): ServiceRegistryRow {
  const db = getDb();
  const { userId, loggedIn } = params;
  const origin = normalizeServiceOrigin(params.origin);
  const fp = fingerprintOrigin(origin);
  const now = Date.now();

  const existing = db
    .prepare(
      "SELECT * FROM service_registry WHERE user_id = ? AND origin = ?",
    )
    .get(userId, origin) as
    | {
        user_id: string;
        origin: string;
        kind: ServiceKind;
        logged_in: number;
        has_mcp: number;
        mcp_slug: string | null;
        auto_provisioned: number;
        first_seen: number;
        last_seen: number;
        visit_count: number;
      }
    | undefined;

  if (existing) {
    db.prepare(
      `UPDATE service_registry
         SET last_seen = ?, visit_count = visit_count + 1, logged_in = ?
       WHERE user_id = ? AND origin = ?`,
    ).run(now, loggedIn ? 1 : existing.logged_in, userId, origin);
    return {
      userId,
      origin,
      kind: existing.kind,
      loggedIn: loggedIn || Boolean(existing.logged_in),
      hasMcp: Boolean(existing.has_mcp),
      mcpSlug: existing.mcp_slug,
      autoProvisioned: Boolean(existing.auto_provisioned),
      firstSeen: existing.first_seen,
      lastSeen: now,
      visitCount: existing.visit_count + 1,
    };
  }

  db.prepare(
    `INSERT INTO service_registry
       (user_id, origin, kind, logged_in, has_mcp, mcp_slug, auto_provisioned, first_seen, last_seen, visit_count)
     VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?, 1)`,
  ).run(
    userId,
    origin,
    fp.kind,
    loggedIn ? 1 : 0,
    fp.mcpSlug ? 1 : 0,
    fp.mcpSlug ?? null,
    now,
    now,
  );

  return {
    userId,
    origin,
    kind: fp.kind,
    loggedIn,
    hasMcp: Boolean(fp.mcpSlug),
    mcpSlug: fp.mcpSlug ?? null,
    autoProvisioned: false,
    firstSeen: now,
    lastSeen: now,
    visitCount: 1,
  };
}

export function listServices(userId: string): ServiceRegistryRow[] {
  const db = getDb();
  const rows = db
    .prepare(
      "SELECT * FROM service_registry WHERE user_id = ? ORDER BY last_seen DESC",
    )
    .all(userId) as Array<{
    user_id: string;
    origin: string;
    kind: ServiceKind;
    logged_in: number;
    has_mcp: number;
    mcp_slug: string | null;
    auto_provisioned: number;
    first_seen: number;
    last_seen: number;
    visit_count: number;
  }>;
  return rows.map((r) => ({
    userId: r.user_id,
    origin: r.origin,
    kind: r.kind,
    loggedIn: Boolean(r.logged_in),
    hasMcp: Boolean(r.has_mcp),
    mcpSlug: r.mcp_slug,
    autoProvisioned: Boolean(r.auto_provisioned),
    firstSeen: r.first_seen,
    lastSeen: r.last_seen,
    visitCount: r.visit_count,
  }));
}

export function markAutoProvisioned(userId: string, origin: string) {
  const normalizedOrigin = normalizeServiceOrigin(origin);
  getDb()
    .prepare(
      "UPDATE service_registry SET auto_provisioned = 1 WHERE user_id = ? AND origin = ?",
    )
    .run(userId, normalizedOrigin);
}

export function appendSiteKnowledge(params: {
  userId: string;
  origin: string;
  kind: "observation" | "recording" | "mcp_export" | "user_fact";
  contentMd: string;
  source?: string;
  confidence?: number;
}): string {
  const db = getDb();
  const now = Date.now();
  const id = randomUUID();
  const origin = normalizeServiceOrigin(params.origin);
  db.prepare(
    `INSERT INTO site_knowledge
       (id, user_id, origin, kind, content_md, source, confidence, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  ).run(
    id,
    params.userId,
    origin,
    params.kind,
    params.contentMd,
    params.source ?? "agent",
    params.confidence ?? 0.5,
    now,
    now,
  );
  return id;
}

export function normalizeServiceOrigin(origin: string) {
  const url = new URL(origin);
  const siteFamilyHost = getSiteFamilyHost(url.hostname);
  if (siteFamilyHost === "notion.so") {
    url.hostname = siteFamilyHost;
  }
  url.pathname = "/";
  url.search = "";
  url.hash = "";
  return url.origin;
}

export function upsertKnowledgePage(params: {
  userId: string;
  type: string;
  title: string;
  contentMd: string;
  confidence?: number;
  sources?: string[];
}): string {
  const db = getDb();
  const now = Date.now();
  const existing = db
    .prepare(
      "SELECT id, confidence, sources FROM knowledge_pages WHERE user_id = ? AND type = ? AND title = ? AND superseded_by IS NULL",
    )
    .get(params.userId, params.type, params.title) as
    | { id: string; confidence: number; sources: string }
    | undefined;

  if (existing) {
    const prevSources = safeParseArray(existing.sources);
    const nextSources = Array.from(new Set([...prevSources, ...(params.sources ?? [])]));
    const nextConfidence = Math.min(
      1,
      Math.max(existing.confidence, params.confidence ?? 0.5, nextSources.length >= 2 ? 0.75 : 0.5),
    );
    db.prepare(
      `UPDATE knowledge_pages
         SET content_md = ?, confidence = ?, sources = ?, updated_at = ?
       WHERE id = ?`,
    ).run(params.contentMd, nextConfidence, JSON.stringify(nextSources), now, existing.id);
    return existing.id;
  }

  const id = randomUUID();
  db.prepare(
    `INSERT INTO knowledge_pages
       (id, user_id, type, title, content_md, confidence, sources, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  ).run(
    id,
    params.userId,
    params.type,
    params.title,
    params.contentMd,
    params.confidence ?? 0.5,
    JSON.stringify(params.sources ?? []),
    now,
    now,
  );
  return id;
}

function safeParseArray(raw: string): string[] {
  try {
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed.filter((x): x is string => typeof x === "string") : [];
  } catch {
    return [];
  }
}
