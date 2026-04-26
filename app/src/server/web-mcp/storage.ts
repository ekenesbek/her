import { createHash, randomUUID } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import type {
  WebEdge,
  WebGoalState,
  WebNote,
  WebNoteKind,
  WebNoteSummary,
  WebPageLink,
  WebPageSnapshot,
  WebPageSummary,
  WebSiteDetail,
  WebSiteWorkspace,
} from "./types";

type StoredSiteMeta = {
  siteKey: string;
  label: string;
  seedUrl: string;
  primaryHost: string;
  goal: string;
  createdAt: number;
  updatedAt: number;
  lastVisitAt: number | null;
};

type StoredGraph = {
  pages: WebPageSummary[];
  edges: WebEdge[];
};

type StoredNoteIndex = {
  notes: WebNoteSummary[];
};

const DATA_ROOT = path.join(process.cwd(), ".data");
const WEB_MCP_ROOT = path.join(DATA_ROOT, "web-mcp");
const MAX_INJECTED_MEMORY_BYTES = 6_000;
const COMMON_SECOND_LEVEL_TLDS = new Set(["ac", "co", "com", "edu", "gov", "net", "org"]);
const MULTITENANT_SUFFIXES = [
  "firebaseapp.com",
  "github.io",
  "netlify.app",
  "pages.dev",
  "vercel.app",
  "web.app",
];
const VOLATILE_QUERY_KEYS = new Set([
  "from",
  "indoorLevel",
  "ll",
  "lr",
  "mode",
  "rtext",
  "rtt",
  "ruri",
  "source",
  "utm_campaign",
  "utm_content",
  "utm_medium",
  "utm_source",
  "utm_term",
  "z",
]);

function ensureDir(dir: string) {
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
}

function ensureWebMcpRoot() {
  ensureDir(WEB_MCP_ROOT);

  const readmePath = path.join(WEB_MCP_ROOT, "README.md");
  if (!fs.existsSync(readmePath)) {
    fs.writeFileSync(
      readmePath,
      [
        "# web-mcp",
        "",
        "Персистентная память по сайтам.",
        "",
        "- `users/<userId>/sites/<siteKey>/site.json` — метаданные сайта и цель обхода",
        "- `users/<userId>/common.md` — общая web-память пользователя, доступная всем сайтам",
        "- `users/<userId>/sites/<siteKey>/memory.md` — устойчивая память конкретного сайта",
        "- `pages/<host>/<path>/snapshot.json` — снимок страницы",
        "- `pages/<host>/<path>/layout.md` — текстовый макет/структура страницы",
        "- `graph.json` — индекс страниц и ребер графа",
        "- `notes/*.md` и `notes/index.json` — заметки, планы, итоги",
      ].join("\n"),
    );
  }
}

function readJsonFile<T>(filePath: string, fallback: T): T {
  if (!fs.existsSync(filePath)) return fallback;
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8")) as T;
  } catch {
    return fallback;
  }
}

function writeJsonFile(filePath: string, value: unknown) {
  ensureDir(path.dirname(filePath));
  fs.writeFileSync(filePath, JSON.stringify(value, null, 2));
}

function slugifySegment(value: string, max = 64) {
  const normalized = value
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, max);
  return normalized || "item";
}

function sanitizeHost(value: string) {
  return value
    .toLowerCase()
    .replace(/[^a-z0-9.-]+/g, "-")
    .replace(/^-+|-+$/g, "") || "site";
}

function shortHash(value: string) {
  return createHash("sha1").update(value).digest("hex").slice(0, 10);
}

function safeDecode(value: string) {
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}

function normalizeMarkdownLine(value: string) {
  return value.replace(/\s+/g, " ").trim();
}

function normalizeUrl(rawUrl: string) {
  const url = new URL(rawUrl);
  url.hash = "";
  return url;
}

function getSiteFamilyHost(hostname: string) {
  const host = sanitizeHost(hostname);
  if (MULTITENANT_SUFFIXES.some((suffix) => host !== suffix && host.endsWith(`.${suffix}`))) {
    return host;
  }

  const parts = host.split(".").filter(Boolean);
  if (parts.length <= 2) return host;

  const [tld, second, third] = parts.slice(-3).reverse();
  if (tld.length === 2 && COMMON_SECOND_LEVEL_TLDS.has(second) && third) {
    return parts.slice(-3).join(".");
  }

  return parts.slice(-2).join(".");
}

function getSiteFamilyOrigin(url: URL) {
  const familyHost = getSiteFamilyHost(url.hostname);
  return `${url.protocol}//${familyHost}${url.port ? `:${url.port}` : ""}`;
}

type PageIdentity = {
  siteFamilyHost: string;
  pageKey: string;
  pageKind: string;
  canonicalUrl: string;
  artifactSegments: string[];
};

function getPageIdentity(rawUrl: string): PageIdentity {
  const url = normalizeUrl(rawUrl);
  const siteFamilyHost = getSiteFamilyHost(url.hostname);
  const pathSegments = url.pathname
    .split("/")
    .filter(Boolean)
    .map((segment) => slugifySegment(safeDecode(segment)));
  const normalizedPathSegments = pathSegments.length > 0 ? pathSegments : ["_root"];
  const yandexMaps = getYandexMapsPageIdentity(url, siteFamilyHost, normalizedPathSegments);
  if (yandexMaps) return yandexMaps;

  const stableQueryKeys = [...new Set([...url.searchParams.keys()])]
    .filter((key) => !VOLATILE_QUERY_KEYS.has(key) && !key.startsWith("utm_"))
    .sort();
  const queryKeySuffix = stableQueryKeys.length > 0
    ? `?queryKeys=${stableQueryKeys.map((key) => encodeURIComponent(key)).join(",")}`
    : "";
  const pageKind = stableQueryKeys.length > 0 ? `query:${stableQueryKeys.join(",")}` : "page";
  const artifactSegments = stableQueryKeys.length > 0
    ? [...normalizedPathSegments, `_query_${slugifySegment(stableQueryKeys.join("-"), 48)}`]
    : normalizedPathSegments;
  const canonicalPath = `/${normalizedPathSegments.filter((segment) => segment !== "_root").join("/")}`;
  const normalizedCanonicalPath = canonicalPath === "/" ? "/" : canonicalPath.replace(/\/$/, "");

  return {
    siteFamilyHost,
    pageKey: `${siteFamilyHost}${normalizedCanonicalPath}${queryKeySuffix}`,
    pageKind,
    canonicalUrl: `${url.protocol}//${siteFamilyHost}${normalizedCanonicalPath}${queryKeySuffix}`,
    artifactSegments,
  };
}

function getYandexMapsPageIdentity(
  url: URL,
  siteFamilyHost: string,
  pathSegments: string[],
): PageIdentity | null {
  if (siteFamilyHost !== "yandex.ru" || pathSegments[0] !== "maps") return null;

  const baseSegments = pathSegments.slice(0, 3);
  const mode = url.searchParams.get("mode");
  const isRoute = mode === "routes" || url.searchParams.has("rtext") || url.searchParams.has("rtt");
  const kindSegment = isRoute ? "routes" : mode ? `mode-${slugifySegment(mode, 32)}` : "page";
  const pageKind = isRoute ? "maps-route" : mode ? `maps-${slugifySegment(mode, 32)}` : "maps-page";
  const artifactSegments = [...baseSegments, kindSegment];
  const canonicalPath = `/${baseSegments.join("/")}`;
  const canonicalQuery = isRoute ? "?mode=routes" : mode ? `?mode=${encodeURIComponent(mode)}` : "";

  return {
    siteFamilyHost,
    pageKey: `${siteFamilyHost}${canonicalPath}${canonicalQuery}`,
    pageKind,
    canonicalUrl: `${url.protocol}//${siteFamilyHost}${canonicalPath}${canonicalQuery}`,
    artifactSegments,
  };
}

export function getWebMcpRoot() {
  ensureWebMcpRoot();
  return WEB_MCP_ROOT;
}

export function getSiteKeyFromUrl(rawUrl: string) {
  const url = normalizeUrl(rawUrl);
  const familyHost = getSiteFamilyHost(url.hostname);
  return `${sanitizeHost(familyHost)}--${shortHash(getSiteFamilyOrigin(url))}`;
}

function getUserRoot(userId: string) {
  return path.join(getWebMcpRoot(), "users", userId);
}

function getUserCommonMemoryFile(userId: string) {
  return path.join(getUserRoot(userId), "common.md");
}

function getUserSitesRoot(userId: string) {
  return path.join(getUserRoot(userId), "sites");
}

function getSiteRoot(userId: string, siteKey: string) {
  return path.join(getUserSitesRoot(userId), siteKey);
}

function getSiteFile(userId: string, siteKey: string) {
  return path.join(getSiteRoot(userId, siteKey), "site.json");
}

function getGraphFile(userId: string, siteKey: string) {
  return path.join(getSiteRoot(userId, siteKey), "graph.json");
}

function getNotesDir(userId: string, siteKey: string) {
  return path.join(getSiteRoot(userId, siteKey), "notes");
}

function getPagesDir(userId: string, siteKey: string) {
  return path.join(getSiteRoot(userId, siteKey), "pages");
}

function getSiteMemoryFile(userId: string, siteKey: string) {
  return path.join(getSiteRoot(userId, siteKey), "memory.md");
}

function getNotesIndexFile(userId: string, siteKey: string) {
  return path.join(getNotesDir(userId, siteKey), "index.json");
}

function buildDefaultCommonMemory() {
  return [
    "# common.md — общая Web MCP память пользователя",
    "",
    "Этот файл хранит устойчивые факты, которые полезны на разных сайтах: дом/работа, город, предпочитаемые сервисы, ограничения, привычки выбора.",
    "Не записывай сюда пароли, токены, коды MFA, банковские данные и одноразовые детали задач.",
    "",
    "## Common Facts",
    "(например: домашний адрес, рабочий адрес, часовой пояс, базовые ограничения)",
    "",
    "## Preferences",
    "(например: любимые сервисы, транспортные предпочтения, формат результатов)",
    "",
    "## Corrections",
    "(исправления пользователя и устаревшие факты)",
    "",
  ].join("\n");
}

function buildDefaultSiteMemory(meta: StoredSiteMeta) {
  return [
    `# memory.md — ${meta.label}`,
    "",
    `siteKey: ${meta.siteKey}`,
    `primaryHost: ${meta.primaryHost}`,
    `seedUrl: ${meta.seedUrl}`,
    "",
    "Устойчивая память именно для этого сайта: как пользователь предпочитает пользоваться сервисом, какие аккаунты/разделы/flows уже выяснены, какие site-specific факты не надо спрашивать заново.",
    "Не записывай сюда секреты, платежные данные, коды подтверждений или одноразовые состояния страниц.",
    "",
    "## Site-specific Memory",
    "(факты и предпочтения, применимые только к этому сайту)",
    "",
    "## Workflows",
    "(проверенные пути по сайту и ограничения)",
    "",
    "## Open Questions",
    "(что нужно уточнить при следующем релевантном сценарии)",
    "",
  ].join("\n");
}

function appendMarkdownMemory(filePath: string, sectionTitle: string, note: string, source?: string | null) {
  const trimmed = note.trim();
  if (!trimmed) return;

  ensureDir(path.dirname(filePath));
  if (!fs.existsSync(filePath)) {
    fs.writeFileSync(filePath, "");
  }

  const stamp = new Date().toISOString();
  const sourceText = source ? ` source=${normalizeMarkdownLine(source)}` : "";
  const block = `\n- [${stamp}]${sourceText} ${normalizeMarkdownLine(trimmed)}\n`;
  const current = fs.readFileSync(filePath, "utf8");
  const sectionRegex = new RegExp(`(##\\s+${sectionTitle}\\b[^\\n]*\\n)`);
  const next = sectionRegex.test(current)
    ? current.replace(sectionRegex, (match) => `${match}${block}`)
    : `${current.trimEnd()}\n\n## ${sectionTitle}\n${block}`;

  fs.writeFileSync(filePath, next);
}

function normalizePageSummary(page: WebPageSummary): WebPageSummary {
  const identity = getPageIdentity(page.url);
  const stored = page as Partial<WebPageSummary>;
  const firstVisitedAt = stored.firstVisitedAt ?? page.visitedAt;
  const observationCount = Math.max(1, stored.observationCount ?? 1);

  return {
    ...page,
    canonicalUrl: stored.canonicalUrl ?? identity.canonicalUrl,
    pageKey: stored.pageKey ?? identity.pageKey,
    pageKind: stored.pageKind ?? identity.pageKind,
    siteFamilyHost: stored.siteFamilyHost ?? identity.siteFamilyHost,
    firstVisitedAt,
    observationCount,
  };
}

function getStoredPageKey(page: WebPageSummary) {
  return normalizePageSummary(page).pageKey;
}

function dedupePages(pages: WebPageSummary[]) {
  const pageMap = new Map<string, WebPageSummary>();

  for (const rawPage of pages) {
    const page = normalizePageSummary(rawPage);
    const current = pageMap.get(page.pageKey);
    if (!current) {
      pageMap.set(page.pageKey, page);
      continue;
    }

    const observationCount = current.observationCount + page.observationCount;
    const firstVisitedAt = Math.min(current.firstVisitedAt, page.firstVisitedAt);
    const newest = page.visitedAt >= current.visitedAt ? page : current;
    pageMap.set(page.pageKey, {
      ...newest,
      firstVisitedAt,
      observationCount,
    });
  }

  return [...pageMap.values()];
}

function getEdgeKey(edge: WebEdge) {
  try {
    const from = getPageIdentity(edge.fromUrl).pageKey;
    const to = getPageIdentity(edge.toUrl).pageKey;
    return `${from}=>${to}`;
  } catch {
    return `${edge.fromUrl}=>${edge.toUrl}`;
  }
}

function toWorkspace(userId: string, meta: StoredSiteMeta, graph: StoredGraph, notesIndex: StoredNoteIndex): WebSiteWorkspace {
  const siteDir = getSiteRoot(userId, meta.siteKey);
  return {
    ...meta,
    pageCount: dedupePages(graph.pages).length,
    edgeCount: graph.edges.length,
    noteCount: notesIndex.notes.length,
    siteDir,
    pagesDir: getPagesDir(userId, meta.siteKey),
    notesDir: getNotesDir(userId, meta.siteKey),
    memoryFile: getSiteMemoryFile(userId, meta.siteKey),
    graphFile: getGraphFile(userId, meta.siteKey),
  };
}

function readSiteMeta(userId: string, siteKey: string): StoredSiteMeta | null {
  const filePath = getSiteFile(userId, siteKey);
  if (!fs.existsSync(filePath)) return null;
  return readJsonFile<StoredSiteMeta | null>(filePath, null);
}

function readGraph(userId: string, siteKey: string) {
  return readJsonFile<StoredGraph>(getGraphFile(userId, siteKey), { pages: [], edges: [] });
}

function readNotesIndex(userId: string, siteKey: string) {
  return readJsonFile<StoredNoteIndex>(getNotesIndexFile(userId, siteKey), { notes: [] });
}

export function readOrInitCommonWebMemory(userId: string) {
  const filePath = getUserCommonMemoryFile(userId);
  if (!fs.existsSync(filePath)) {
    ensureDir(path.dirname(filePath));
    fs.writeFileSync(filePath, buildDefaultCommonMemory());
  }
  return fs.readFileSync(filePath, "utf8");
}

function readOrInitSiteMemory(userId: string, meta: StoredSiteMeta) {
  const filePath = getSiteMemoryFile(userId, meta.siteKey);
  if (!fs.existsSync(filePath)) {
    ensureDir(path.dirname(filePath));
    fs.writeFileSync(filePath, buildDefaultSiteMemory(meta));
  }
  return fs.readFileSync(filePath, "utf8");
}

export function readOrInitWebSiteMemory(userId: string, siteKey: string) {
  const meta = readSiteMeta(userId, siteKey);
  if (!meta) return null;
  return readOrInitSiteMemory(userId, meta);
}

function writeSiteMeta(userId: string, meta: StoredSiteMeta) {
  writeJsonFile(getSiteFile(userId, meta.siteKey), meta);
}

function writeGraph(userId: string, siteKey: string, graph: StoredGraph) {
  writeJsonFile(getGraphFile(userId, siteKey), graph);
}

function writeNotesIndex(userId: string, siteKey: string, notes: StoredNoteIndex) {
  writeJsonFile(getNotesIndexFile(userId, siteKey), notes);
}

function ensureSiteScaffold(userId: string, meta: StoredSiteMeta) {
  const siteDir = getSiteRoot(userId, meta.siteKey);
  ensureDir(siteDir);
  ensureDir(getPagesDir(userId, meta.siteKey));
  ensureDir(getNotesDir(userId, meta.siteKey));
  readOrInitCommonWebMemory(userId);
  readOrInitSiteMemory(userId, meta);

  if (!fs.existsSync(getGraphFile(userId, meta.siteKey))) {
    writeGraph(userId, meta.siteKey, { pages: [], edges: [] });
  }
  if (!fs.existsSync(getNotesIndexFile(userId, meta.siteKey))) {
    writeNotesIndex(userId, meta.siteKey, { notes: [] });
  }
  writeSiteMeta(userId, meta);
}

function getPageArtifactDir(userId: string, siteKey: string, rawUrl: string) {
  const identity = getPageIdentity(rawUrl);
  return path.join(getPagesDir(userId, siteKey), sanitizeHost(identity.siteFamilyHost), ...identity.artifactSegments);
}

function relativeToSiteDir(siteDir: string, filePath: string) {
  return path.relative(siteDir, filePath) || ".";
}

function sortPages(pages: WebPageSummary[]) {
  return [...pages].sort((a, b) => b.visitedAt - a.visitedAt);
}

function sortNotes(notes: WebNote[]) {
  return [...notes].sort((a, b) => b.createdAt - a.createdAt);
}

function truncateText(value: string, maxLength: number) {
  const normalized = normalizeMarkdownLine(value);
  return normalized.length > maxLength ? `${normalized.slice(0, maxLength - 3)}...` : normalized;
}

export function listWebSites(userId: string): WebSiteWorkspace[] {
  const sitesRoot = getUserSitesRoot(userId);
  ensureDir(sitesRoot);

  const siteKeys = fs
    .readdirSync(sitesRoot, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name);

  return siteKeys
    .map((siteKey) => {
      const meta = readSiteMeta(userId, siteKey);
      if (!meta) return null;
      return toWorkspace(userId, meta, readGraph(userId, siteKey), readNotesIndex(userId, siteKey));
    })
    .filter((site): site is WebSiteWorkspace => Boolean(site))
    .sort((a, b) => b.updatedAt - a.updatedAt);
}

export function upsertWebSiteWorkspace(
  userId: string,
  { url, label, goal }: { url: string; label?: string; goal?: string },
) {
  const normalizedUrl = normalizeUrl(url);
  const siteFamilyHost = getSiteFamilyHost(normalizedUrl.hostname);
  const siteKey = getSiteKeyFromUrl(normalizedUrl.toString());
  const now = Date.now();
  const current = readSiteMeta(userId, siteKey);

  const next: StoredSiteMeta = current
    ? {
        ...current,
        label: label?.trim() || current.label,
        goal: goal?.trim() || current.goal,
        updatedAt: now,
      }
    : {
        siteKey,
        label: label?.trim() || siteFamilyHost,
        seedUrl: normalizedUrl.toString(),
        primaryHost: siteFamilyHost,
        goal: goal?.trim() || "Построить карту сайта, пройти ключевые страницы и накопить память по структуре.",
        createdAt: now,
        updatedAt: now,
        lastVisitAt: null,
      };

  ensureSiteScaffold(userId, next);

  return {
    created: !current,
    site: toWorkspace(userId, next, readGraph(userId, siteKey), readNotesIndex(userId, siteKey)),
  };
}

export function getWebSiteDetail(userId: string, siteKey: string): WebSiteDetail | null {
  const meta = readSiteMeta(userId, siteKey);
  if (!meta) return null;

  const graph = readGraph(userId, siteKey);
  const notesIndex = readNotesIndex(userId, siteKey);
  const siteMemory = readOrInitSiteMemory(userId, meta);
  const notes = notesIndex.notes
    .map((note) => {
      const filePath = path.join(getSiteRoot(userId, siteKey), note.filePath);
      if (!fs.existsSync(filePath)) return null;
      return {
        ...note,
        content: fs.readFileSync(filePath, "utf8"),
      };
    })
    .filter((note): note is WebNote => Boolean(note));

  return {
    site: toWorkspace(userId, meta, graph, notesIndex),
    siteMemory,
    pages: sortPages(dedupePages(graph.pages)),
    edges: [...graph.edges].sort((a, b) => b.discoveredAt - a.discoveredAt),
    notes: sortNotes(notes),
  };
}

export function summarizeWebSitePagePatterns(userId: string, siteKey: string, limit = 6) {
  const meta = readSiteMeta(userId, siteKey);
  if (!meta) return [];

  return sortPages(dedupePages(readGraph(userId, siteKey).pages))
    .slice(0, Math.max(0, limit))
    .map((page) => {
      const parts = [
        `kind=${page.pageKind}`,
        `key=${page.pageKey}`,
        `observations=${page.observationCount}`,
        `canonical=${page.canonicalUrl}`,
        page.summary ? `summary=${truncateText(page.summary, 220)}` : null,
      ].filter(Boolean);
      return parts.join("; ");
    });
}

export function recordWebPageSnapshot(
  userId: string,
  siteKey: string,
  {
    url,
    title = "",
    statusCode = null,
    summary = "",
    layout = "",
    links = [],
    sourceUrl = null,
    plan = "",
    goalState = "visited",
  }: {
    url: string;
    title?: string;
    statusCode?: number | null;
    summary?: string;
    layout?: string;
    links?: WebPageLink[];
    sourceUrl?: string | null;
    plan?: string;
    goalState?: WebGoalState;
  },
) {
  const meta = readSiteMeta(userId, siteKey);
  if (!meta) throw new Error("site_not_found");

  const now = Date.now();
  const siteDir = getSiteRoot(userId, siteKey);
  const artifactDir = getPageArtifactDir(userId, siteKey, url);
  ensureDir(artifactDir);

  const snapshotFile = path.join(artifactDir, "snapshot.json");
  const layoutFile = layout.trim() ? path.join(artifactDir, "layout.md") : null;
  const normalizedUrl = normalizeUrl(url);
  const identity = getPageIdentity(normalizedUrl.toString());
  const graph = readGraph(userId, siteKey);
  const existingPage = graph.pages
    .map(normalizePageSummary)
    .find((page) => page.pageKey === identity.pageKey);

  const snapshot: WebPageSnapshot = {
    url: normalizedUrl.toString(),
    canonicalUrl: identity.canonicalUrl,
    pageKey: identity.pageKey,
    pageKind: identity.pageKind,
    title: title.trim(),
    host: normalizedUrl.hostname,
    siteFamilyHost: identity.siteFamilyHost,
    pathname: normalizedUrl.pathname || "/",
    statusCode,
    summary: summary.trim(),
    plan: plan.trim(),
    sourceUrl: sourceUrl ? normalizeUrl(sourceUrl).toString() : null,
    goalState,
    firstVisitedAt: existingPage?.firstVisitedAt ?? now,
    visitedAt: now,
    observationCount: (existingPage?.observationCount ?? 0) + 1,
    artifactDir: relativeToSiteDir(siteDir, artifactDir),
    snapshotFile: relativeToSiteDir(siteDir, snapshotFile),
    layoutFile: layoutFile ? relativeToSiteDir(siteDir, layoutFile) : null,
    linkCount: links.length,
    links,
    layout,
  };

  writeJsonFile(snapshotFile, snapshot);
  if (layoutFile) {
    fs.writeFileSync(layoutFile, layout);
  }

  const pageSummary: WebPageSummary = {
    url: snapshot.url,
    canonicalUrl: snapshot.canonicalUrl,
    pageKey: snapshot.pageKey,
    pageKind: snapshot.pageKind,
    title: snapshot.title,
    host: snapshot.host,
    siteFamilyHost: snapshot.siteFamilyHost,
    pathname: snapshot.pathname,
    statusCode: snapshot.statusCode,
    summary: snapshot.summary,
    plan: snapshot.plan,
    sourceUrl: snapshot.sourceUrl,
    goalState: snapshot.goalState,
    firstVisitedAt: snapshot.firstVisitedAt,
    visitedAt: snapshot.visitedAt,
    observationCount: snapshot.observationCount,
    artifactDir: snapshot.artifactDir,
    snapshotFile: snapshot.snapshotFile,
    layoutFile: snapshot.layoutFile,
    linkCount: snapshot.linkCount,
  };

  const nextPages = graph.pages.filter((page) => getStoredPageKey(page) !== snapshot.pageKey);
  nextPages.push(pageSummary);

  const edgeMap = new Map<string, WebEdge>();
  for (const edge of graph.edges) {
    edgeMap.set(getEdgeKey(edge), edge);
  }
  for (const link of links) {
    const targetIdentity = getPageIdentity(link.url);
    edgeMap.set(`${snapshot.pageKey}=>${targetIdentity.pageKey}`, {
      fromUrl: snapshot.canonicalUrl,
      toUrl: targetIdentity.canonicalUrl,
      text: link.text.trim(),
      rel: link.rel,
      discoveredAt: now,
    });
  }

  writeGraph(userId, siteKey, {
    pages: sortPages(nextPages),
    edges: [...edgeMap.values()].sort((a, b) => b.discoveredAt - a.discoveredAt),
  });

  writeSiteMeta(userId, {
    ...meta,
    updatedAt: now,
    lastVisitAt: now,
  });

  return snapshot;
}

export function appendWebSiteNote(
  userId: string,
  siteKey: string,
  {
    title,
    content,
    kind = "general",
    url = null,
  }: {
    title: string;
    content: string;
    kind?: WebNoteKind;
    url?: string | null;
  },
) {
  const meta = readSiteMeta(userId, siteKey);
  if (!meta) throw new Error("site_not_found");

  const now = Date.now();
  const noteId = randomUUID();
  const fileName = `${now}-${slugifySegment(title, 40)}-${noteId.slice(0, 8)}.md`;
  const noteFilePath = path.join(getNotesDir(userId, siteKey), fileName);

  const noteBody = [
    `# ${title.trim()}`,
    "",
    `- kind: ${kind}`,
    `- createdAt: ${new Date(now).toISOString()}`,
    url ? `- url: ${normalizeUrl(url).toString()}` : null,
    "",
    content.trim(),
    "",
  ]
    .filter(Boolean)
    .join("\n");

  fs.writeFileSync(noteFilePath, noteBody);

  const noteSummary: WebNoteSummary = {
    id: noteId,
    title: title.trim(),
    kind,
    url: url ? normalizeUrl(url).toString() : null,
    createdAt: now,
    filePath: relativeToSiteDir(getSiteRoot(userId, siteKey), noteFilePath),
  };

  const notesIndex = readNotesIndex(userId, siteKey);
  notesIndex.notes = [...notesIndex.notes, noteSummary].sort((a, b) => b.createdAt - a.createdAt);
  writeNotesIndex(userId, siteKey, notesIndex);

  writeSiteMeta(userId, {
    ...meta,
    updatedAt: now,
  });

  return {
    ...noteSummary,
    content: noteBody,
  };
}

export function appendCommonWebMemoryNote(userId: string, note: string, source?: string | null) {
  const filePath = getUserCommonMemoryFile(userId);
  readOrInitCommonWebMemory(userId);
  appendMarkdownMemory(filePath, "Common Facts", note, source);
}

export function appendWebSiteMemoryNote(
  userId: string,
  siteKey: string,
  note: string,
  sourceUrl?: string | null,
) {
  const meta = readSiteMeta(userId, siteKey);
  if (!meta) throw new Error("site_not_found");

  readOrInitSiteMemory(userId, meta);
  appendMarkdownMemory(getSiteMemoryFile(userId, siteKey), "Site-specific Memory", note, sourceUrl);
  writeSiteMeta(userId, {
    ...meta,
    updatedAt: Date.now(),
  });
}

export function clipWebMemoryForPrompt(content: string, maxBytes = MAX_INJECTED_MEMORY_BYTES) {
  if (content.length <= maxBytes) return content;
  return `${content.slice(0, maxBytes)}\n\n...(truncated; see full memory file on disk)`;
}

export function extractTimestampedMemoryEntries(content: string, maxEntries = 12) {
  const entries = content
    .split(/\r?\n/)
    .map((line) => line.trimEnd())
    .filter((line) => /^-\s+\[\d{4}-\d{2}-\d{2}T/.test(line));

  return entries.slice(-maxEntries).join("\n");
}

const REMEMBER_WEB_COMMON_TAG = /<remember-web-common>([\s\S]*?)<\/remember-web-common>/gi;
const REMEMBER_WEB_SITE_TAG = /<remember-web-site\b([^>]*)>([\s\S]*?)<\/remember-web-site>/gi;

export function extractAndPersistWebMemoryNotes(
  userId: string,
  rawContent: string,
): {
  cleanedContent: string;
  commonNotes: string[];
  siteNotes: Array<{ siteKey: string; note: string }>;
} {
  const commonNotes: string[] = [];
  const siteNotes: Array<{ siteKey: string; note: string }> = [];

  for (const match of rawContent.matchAll(REMEMBER_WEB_COMMON_TAG)) {
    const note = match[1]?.trim();
    if (!note) continue;

    try {
      appendCommonWebMemoryNote(userId, note, "agent");
      commonNotes.push(note);
    } catch (error) {
      console.warn("web-mcp: failed to append common memory", error);
    }
  }

  for (const match of rawContent.matchAll(REMEMBER_WEB_SITE_TAG)) {
    const attrs = parseTagAttributes(match[1] ?? "");
    const note = match[2]?.trim();
    if (!note) continue;

    try {
      const siteKey = attrs.siteKey ?? resolveSiteKeyFromMemoryAttrs(userId, attrs);
      if (!siteKey) continue;

      appendWebSiteMemoryNote(userId, siteKey, note, attrs.url ?? attrs.origin ?? null);
      appendWebSiteNote(userId, siteKey, {
        title: attrs.title ?? "Memory update",
        content: note,
        kind: "memory",
        url: normalizeOptionalUrl(attrs.url ?? attrs.origin),
      });
      siteNotes.push({ siteKey, note });
    } catch (error) {
      console.warn("web-mcp: failed to append site memory", error);
    }
  }

  const cleanedContent = rawContent
    .replace(REMEMBER_WEB_COMMON_TAG, "")
    .replace(REMEMBER_WEB_SITE_TAG, "")
    .replace(/\n{3,}/g, "\n\n")
    .trim();

  return { cleanedContent, commonNotes, siteNotes };
}

function resolveSiteKeyFromMemoryAttrs(userId: string, attrs: Record<string, string>) {
  const rawUrl = attrs.url ?? attrs.origin;
  const normalizedUrl = normalizeOptionalUrl(rawUrl);
  if (!normalizedUrl) return null;

  return upsertWebSiteWorkspace(userId, {
    url: normalizedUrl,
    label: attrs.label,
    goal: "Persist durable site-specific memory for this user.",
  }).site.siteKey;
}

function normalizeOptionalUrl(value: string | undefined) {
  if (!value) return null;
  try {
    return normalizeUrl(value).toString();
  } catch {
    try {
      return normalizeUrl(`https://${value}`).toString();
    } catch {
      return null;
    }
  }
}

function parseTagAttributes(raw: string) {
  const attrs: Record<string, string> = {};
  const attrPattern = /([a-zA-Z][a-zA-Z0-9_-]*)\s*=\s*(?:"([^"]*)"|'([^']*)')/g;
  for (const match of raw.matchAll(attrPattern)) {
    const key = normalizeAttrKey(match[1]);
    const value = match[2] ?? match[3] ?? "";
    attrs[key] = value.trim();
  }
  return attrs;
}

function normalizeAttrKey(key: string) {
  return key.replace(/[-_]([a-zA-Z0-9])/g, (_, char: string) => char.toUpperCase());
}
