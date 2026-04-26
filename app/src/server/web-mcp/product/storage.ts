import { randomUUID } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import {
  getPageIdentity,
  getSiteFamilyHost,
  getSiteKeyFromUrl as buildSiteKeyFromUrl,
  normalizeUrl,
  sanitizeHost,
  shortHash,
  slugifySegment,
} from "../core/url";
import type {
  WebActionKind,
  WebEdge,
  WebGoalState,
  WebNote,
  WebNoteKind,
  WebNoteSummary,
  WebPageAction,
  WebPageLink,
  WebPageSnapshot,
  WebPageSummary,
  WebSiteCategory,
  WebSiteDetail,
  WebSiteWorkspace,
} from "../core/types";

type StoredSiteMeta = {
  siteKey: string;
  label: string;
  seedUrl: string;
  primaryHost: string;
  goal: string;
  category: WebSiteCategory;
  tags: string[];
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

type WebPageActionInput = Partial<WebPageAction> & {
  href?: string | null;
  targetUrl?: string | null;
};

const DATA_ROOT = path.join(process.cwd(), ".data");
const WEB_MCP_ROOT = path.join(DATA_ROOT, "web-mcp");
const MAX_INJECTED_MEMORY_BYTES = 6_000;
const MAX_PAGE_ACTIONS = 160;
const WEB_SITE_CATEGORIES = new Set<WebSiteCategory>([
  "unknown",
  "taxi",
  "maps",
  "delivery",
  "mail",
  "calendar",
  "contacts",
  "chat",
  "docs",
  "project",
  "code",
  "finance",
  "social",
  "media",
  "search",
  "shopping",
  "travel",
  "weather",
  "local_services",
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
        "- `snapshot.json.actions` — semantic actions: кнопки, ссылки, поля, табы и формы",
        "- `graph.json` — индекс страниц и action-aware ребер flow-графа",
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

function normalizeMarkdownLine(value: string) {
  return value.replace(/\s+/g, " ").trim();
}

export function getWebMcpRoot() {
  ensureWebMcpRoot();
  return WEB_MCP_ROOT;
}

export function getSiteKeyFromUrl(rawUrl: string) {
  return buildSiteKeyFromUrl(rawUrl);
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
  const actionCount = Math.max(0, stored.actionCount ?? 0);

  return {
    ...page,
    canonicalUrl: stored.canonicalUrl ?? identity.canonicalUrl,
    pageKey: stored.pageKey ?? identity.pageKey,
    pageKind: stored.pageKind ?? identity.pageKind,
    siteFamilyHost: stored.siteFamilyHost ?? identity.siteFamilyHost,
    milestoneGoal: stored.milestoneGoal ?? "",
    flowPlan: stored.flowPlan ?? "",
    firstVisitedAt,
    observationCount,
    actionCount,
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
    const action = edge.actionId ?? edge.actionLabel ?? edge.text ?? "";
    return `${from}=>${to}=>${action}`;
  } catch {
    const action = edge.actionId ?? edge.actionLabel ?? edge.text ?? "";
    return `${edge.fromUrl}=>${edge.toUrl}=>${action}`;
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
  const raw = readJsonFile<Partial<StoredSiteMeta> | null>(filePath, null);
  if (!raw?.siteKey || !raw.seedUrl || !raw.primaryHost) return null;
  return normalizeSiteMeta({
    ...raw,
    siteKey: raw.siteKey,
    seedUrl: raw.seedUrl,
    primaryHost: raw.primaryHost,
  });
}

function normalizeSiteMeta(raw: Partial<StoredSiteMeta> & Pick<StoredSiteMeta, "siteKey" | "seedUrl" | "primaryHost">): StoredSiteMeta {
  const inferred = classifyWebSite({
    url: raw.seedUrl,
    host: raw.primaryHost,
    goal: raw.goal ?? "",
    label: raw.label ?? raw.primaryHost,
  });

  return {
    siteKey: raw.siteKey,
    label: raw.label?.trim() || raw.primaryHost,
    seedUrl: raw.seedUrl,
    primaryHost: raw.primaryHost,
    goal: raw.goal?.trim() || "Построить карту сайта, пройти ключевые страницы и накопить память по структуре.",
    category: normalizeWebSiteCategory(raw.category) ?? inferred.category,
    tags: normalizeWebSiteTags(raw.tags, inferred.tags),
    createdAt: typeof raw.createdAt === "number" ? raw.createdAt : Date.now(),
    updatedAt: typeof raw.updatedAt === "number" ? raw.updatedAt : Date.now(),
    lastVisitAt: typeof raw.lastVisitAt === "number" ? raw.lastVisitAt : null,
  };
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

function classifyWebSite({
  url,
  host,
  goal,
  label,
}: {
  url: string;
  host: string;
  goal: string;
  label: string;
}): { category: WebSiteCategory; tags: string[] } {
  const haystack = `${host} ${url} ${goal} ${label}`.toLowerCase();
  const rules: Array<{ category: WebSiteCategory; tags: string[]; patterns: RegExp[] }> = [
    { category: "taxi", tags: ["mobility", "ride_hailing"], patterns: [/taxi|uber|bolt|gett|lyft|yango|яндекс\s*(go|такси)|такси/i] },
    { category: "maps", tags: ["navigation", "local"], patterns: [/maps|map|route|routing|yandex\.ru\/maps|google\.[^/]+\/maps|карты|маршрут/i] },
    { category: "delivery", tags: ["commerce", "local"], patterns: [/delivery|doordash|ubereats|wolt|glovo|deliveroo|еда|доставка/i] },
    { category: "mail", tags: ["account", "communication"], patterns: [/gmail|mail|inbox|почт/i] },
    { category: "calendar", tags: ["scheduling"], patterns: [/calendar|календар/i] },
    { category: "contacts", tags: ["people"], patterns: [/contacts|адресн|контакт/i] },
    { category: "chat", tags: ["communication"], patterns: [/slack|telegram|discord|whatsapp|chat|чат|сообщени/i] },
    { category: "docs", tags: ["knowledge", "files"], patterns: [/docs|drive|notion|figma|miro|document|документ|файл/i] },
    { category: "project", tags: ["work"], patterns: [/linear|jira|asana|trello|project|задач/i] },
    { category: "code", tags: ["developer"], patterns: [/github|gitlab|bitbucket|repo|code|pull request|репозитор/i] },
    { category: "finance", tags: ["money"], patterns: [/bank|finance|billing|stripe|wise|revolut|банк|сч[её]т|оплат/i] },
    { category: "shopping", tags: ["commerce"], patterns: [/shop|store|cart|checkout|amazon|ozon|wildberries|market|магазин|корзин/i] },
    { category: "travel", tags: ["booking"], patterns: [/booking|airbnb|hotel|flight|travel|trip|avia|отель|билет/i] },
    { category: "weather", tags: ["local"], patterns: [/weather|forecast|погод|прогноз/i] },
    { category: "search", tags: ["discovery"], patterns: [/google\.com|bing\.com|duckduckgo|search|поиск/i] },
    { category: "media", tags: ["content"], patterns: [/youtube|spotify|netflix|media|video|music|видео|музык/i] },
    { category: "social", tags: ["social"], patterns: [/facebook|instagram|x\.com|twitter|linkedin|social|соц/i] },
    { category: "local_services", tags: ["local"], patterns: [/restaurant|clinic|salon|service|local|ресторан|клиник|сервис/i] },
  ];

  for (const rule of rules) {
    if (rule.patterns.some((pattern) => pattern.test(haystack))) {
      return { category: rule.category, tags: normalizeWebSiteTags(rule.tags, []) };
    }
  }

  return { category: "unknown", tags: [] };
}

function normalizeWebSiteCategory(value: unknown): WebSiteCategory | null {
  return typeof value === "string" && WEB_SITE_CATEGORIES.has(value as WebSiteCategory)
    ? value as WebSiteCategory
    : null;
}

function normalizeWebSiteTags(value: unknown, fallback: string[]) {
  const source = Array.isArray(value) && value.length > 0 ? value : fallback;
  return [...new Set(
    source
      .map((tag) => typeof tag === "string" ? tag.toLowerCase().replace(/[^a-z0-9_-]+/g, "-").replace(/^-+|-+$/g, "") : "")
      .filter(Boolean),
  )].slice(0, 20);
}

function normalizePageActions({
  baseUrl,
  links,
  actions,
  existingActions,
  now,
}: {
  baseUrl: URL;
  links: WebPageLink[];
  actions: WebPageActionInput[];
  existingActions: WebPageAction[];
  now: number;
}) {
  const actionMap = new Map<string, WebPageAction>();

  for (const action of existingActions) {
    actionMap.set(action.id, action);
  }

  const incoming = [
    ...links.map((link): WebPageActionInput => ({
      kind: "link",
      label: link.text || link.url,
      text: link.text,
      href: link.url,
      targetUrl: link.url,
      source: "link",
      confidence: 0.75,
    })),
    ...actions,
  ];

  for (const rawAction of incoming) {
    const normalized = normalizePageAction(rawAction, baseUrl, now);
    if (!normalized) continue;

    const current = actionMap.get(normalized.id);
    if (!current) {
      actionMap.set(normalized.id, normalized);
      continue;
    }

    actionMap.set(normalized.id, {
      ...current,
      ...normalized,
      discoveredAt: Math.min(current.discoveredAt, normalized.discoveredAt),
      lastObservedAt: now,
      observationCount: current.observationCount + 1,
      confidence: Math.max(current.confidence, normalized.confidence),
    });
  }

  return [...actionMap.values()]
    .sort((a, b) => b.lastObservedAt - a.lastObservedAt)
    .slice(0, MAX_PAGE_ACTIONS);
}

function normalizePageAction(rawAction: WebPageActionInput, baseUrl: URL, now: number): WebPageAction | null {
  const href = cleanOptionalString(rawAction.href);
  const targetUrl = normalizeActionTarget(rawAction.targetUrl ?? href, baseUrl);
  const text = cleanOptionalString(rawAction.text) ?? "";
  const label = cleanOptionalString(rawAction.label) ?? (text || targetUrl || href || "");
  if (!label) return null;

  const kind = normalizeActionKind(rawAction.kind, href, targetUrl);
  const role = cleanOptionalString(rawAction.role) ?? null;
  const ref = cleanOptionalString(rawAction.ref) ?? null;
  const semanticKey = cleanOptionalString(rawAction.semanticKey) ?? buildActionSemanticKey(kind, label, targetUrl);
  const id = cleanOptionalString(rawAction.id) ?? `${kind}-${shortHash([semanticKey, targetUrl, ref].filter(Boolean).join("|"))}`;
  const confidence = typeof rawAction.confidence === "number" && Number.isFinite(rawAction.confidence)
    ? Math.max(0, Math.min(1, rawAction.confidence))
    : inferActionConfidence(kind, targetUrl, ref);

  return {
    id,
    kind,
    label: truncateText(label, 180),
    role,
    text: truncateText(text, 240),
    href: href ?? null,
    targetUrl,
    ref,
    semanticKey,
    source: cleanOptionalString(rawAction.source) ?? "recording",
    confidence,
    discoveredAt: rawAction.discoveredAt ?? now,
    lastObservedAt: now,
    observationCount: Math.max(1, rawAction.observationCount ?? 1),
  };
}

function cleanOptionalString(value: unknown) {
  if (typeof value !== "string") return undefined;
  const cleaned = normalizeMarkdownLine(value);
  return cleaned || undefined;
}

function normalizeActionTarget(value: string | null | undefined, baseUrl: URL) {
  if (!value) return null;
  try {
    const url = new URL(value, baseUrl);
    if (url.protocol !== "http:" && url.protocol !== "https:") return null;
    url.hash = "";
    return normalizeUrl(url.toString()).toString();
  } catch {
    return null;
  }
}

function normalizeActionKind(
  kind: WebActionKind | undefined,
  href: string | undefined,
  targetUrl: string | null,
): WebActionKind {
  if (kind) return kind;
  if (href || targetUrl) return "link";
  return "unknown";
}

function buildActionSemanticKey(kind: WebActionKind, label: string, targetUrl: string | null) {
  const target = targetUrl ? getPageIdentity(targetUrl).pageKey : "";
  return `${kind}:${normalizeMarkdownLine(label).toLowerCase()}:${target}`;
}

function inferActionConfidence(kind: WebActionKind, targetUrl: string | null, ref: string | null) {
  if (kind === "link" && targetUrl) return 0.82;
  if (ref) return 0.72;
  return 0.55;
}

function readExistingPageActions(siteDir: string, page?: WebPageSummary) {
  if (!page?.snapshotFile) return [];
  const snapshot = readJsonFile<WebPageSnapshot | null>(path.join(siteDir, page.snapshotFile), null);
  return Array.isArray(snapshot?.actions) ? snapshot.actions : [];
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
  {
    url,
    label,
    goal,
    category,
    tags,
  }: {
    url: string;
    label?: string;
    goal?: string;
    category?: WebSiteCategory;
    tags?: string[];
  },
) {
  const normalizedUrl = normalizeUrl(url);
  const siteFamilyHost = getSiteFamilyHost(normalizedUrl.hostname);
  const siteKey = getSiteKeyFromUrl(normalizedUrl.toString());
  const now = Date.now();
  const current = readSiteMeta(userId, siteKey);
  const inferred = classifyWebSite({
    url: normalizedUrl.toString(),
    host: siteFamilyHost,
    goal: goal ?? current?.goal ?? "",
    label: label ?? current?.label ?? siteFamilyHost,
  });
  const resolvedCategory = normalizeWebSiteCategory(category) ?? current?.category ?? inferred.category;
  const resolvedTags = normalizeWebSiteTags(tags, current?.tags?.length ? current.tags : inferred.tags);

  const next: StoredSiteMeta = current
    ? {
        ...current,
        label: label?.trim() || current.label,
        goal: goal?.trim() || current.goal,
        category: resolvedCategory,
        tags: resolvedTags,
        updatedAt: now,
      }
    : {
        siteKey,
        label: label?.trim() || siteFamilyHost,
        seedUrl: normalizedUrl.toString(),
        primaryHost: siteFamilyHost,
        goal: goal?.trim() || "Построить карту сайта, пройти ключевые страницы и накопить память по структуре.",
        category: resolvedCategory,
        tags: resolvedTags,
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
        `actions=${page.actionCount}`,
        `canonical=${page.canonicalUrl}`,
        page.milestoneGoal ? `milestone=${truncateText(page.milestoneGoal, 160)}` : null,
        page.flowPlan ? `plan=${truncateText(page.flowPlan, 180)}` : null,
        page.summary ? `summary=${truncateText(page.summary, 220)}` : null,
      ].filter(Boolean);
      return parts.join("; ");
    });
}

export function summarizeWebSiteFlowHints(userId: string, siteKey: string, limit = 8) {
  const meta = readSiteMeta(userId, siteKey);
  if (!meta) return [];

  return [...readGraph(userId, siteKey).edges]
    .sort((a, b) => (b.lastObservedAt ?? b.discoveredAt) - (a.lastObservedAt ?? a.discoveredAt))
    .slice(0, Math.max(0, limit))
    .map((edge) => {
      const parts = [
        `action=${truncateText(edge.actionLabel ?? edge.text ?? "(unknown)", 140)}`,
        edge.actionKind ? `kind=${edge.actionKind}` : null,
        `from=${edge.sourcePageKey ?? safePageKey(edge.fromUrl)}`,
        `to=${edge.targetPageKey ?? safePageKey(edge.toUrl)}`,
        edge.status ? `status=${edge.status}` : null,
        edge.observationCount ? `observations=${edge.observationCount}` : null,
      ].filter(Boolean);
      return parts.join("; ");
    });
}

function safePageKey(rawUrl: string) {
  try {
    return getPageIdentity(rawUrl).pageKey;
  } catch {
    return rawUrl;
  }
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
    actions = [],
    sourceUrl = null,
    plan = "",
    milestoneGoal = "",
    flowPlan = "",
    goalState = "visited",
  }: {
    url: string;
    title?: string;
    statusCode?: number | null;
    summary?: string;
    layout?: string;
    links?: WebPageLink[];
    actions?: WebPageActionInput[];
    sourceUrl?: string | null;
    plan?: string;
    milestoneGoal?: string;
    flowPlan?: string;
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
  const normalizedActions = normalizePageActions({
    baseUrl: normalizedUrl,
    links,
    actions,
    existingActions: readExistingPageActions(siteDir, existingPage),
    now,
  });

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
    milestoneGoal: milestoneGoal.trim() || meta.goal,
    flowPlan: flowPlan.trim(),
    sourceUrl: sourceUrl ? normalizeUrl(sourceUrl).toString() : null,
    goalState,
    firstVisitedAt: existingPage?.firstVisitedAt ?? now,
    visitedAt: now,
    observationCount: (existingPage?.observationCount ?? 0) + 1,
    artifactDir: relativeToSiteDir(siteDir, artifactDir),
    snapshotFile: relativeToSiteDir(siteDir, snapshotFile),
    layoutFile: layoutFile ? relativeToSiteDir(siteDir, layoutFile) : null,
    linkCount: links.length,
    actionCount: normalizedActions.length,
    links,
    actions: normalizedActions,
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
    milestoneGoal: snapshot.milestoneGoal,
    flowPlan: snapshot.flowPlan,
    sourceUrl: snapshot.sourceUrl,
    goalState: snapshot.goalState,
    firstVisitedAt: snapshot.firstVisitedAt,
    visitedAt: snapshot.visitedAt,
    observationCount: snapshot.observationCount,
    artifactDir: snapshot.artifactDir,
    snapshotFile: snapshot.snapshotFile,
    layoutFile: snapshot.layoutFile,
    linkCount: snapshot.linkCount,
    actionCount: snapshot.actionCount,
  };

  const nextPages = graph.pages.filter((page) => getStoredPageKey(page) !== snapshot.pageKey);
  nextPages.push(pageSummary);

  const edgeMap = new Map<string, WebEdge>();
  for (const edge of graph.edges) {
    edgeMap.set(getEdgeKey(edge), edge);
  }
  for (const action of normalizedActions) {
    if (!action.targetUrl) continue;

    const targetIdentity = getPageIdentity(action.targetUrl);
    const edgeKey = `${snapshot.pageKey}=>${targetIdentity.pageKey}=>${action.id}`;
    const current = edgeMap.get(edgeKey);
    edgeMap.set(edgeKey, {
      fromUrl: snapshot.canonicalUrl,
      sourcePageKey: snapshot.pageKey,
      targetPageKey: targetIdentity.pageKey,
      toUrl: targetIdentity.canonicalUrl,
      text: action.label,
      rel: action.kind === "link" ? "link" : null,
      actionId: action.id,
      actionKind: action.kind,
      actionLabel: action.label,
      confidence: action.confidence,
      status: "discovered",
      discoveredAt: current?.discoveredAt ?? now,
      firstObservedAt: current?.firstObservedAt ?? current?.discoveredAt ?? now,
      lastObservedAt: now,
      observationCount: (current?.observationCount ?? 0) + 1,
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
