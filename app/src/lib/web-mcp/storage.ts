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

function normalizeUrl(rawUrl: string) {
  const url = new URL(rawUrl);
  url.hash = "";
  return url;
}

export function getWebMcpRoot() {
  ensureWebMcpRoot();
  return WEB_MCP_ROOT;
}

export function getSiteKeyFromUrl(rawUrl: string) {
  const url = normalizeUrl(rawUrl);
  return `${sanitizeHost(url.hostname)}--${shortHash(url.origin)}`;
}

function getUserSitesRoot(userId: string) {
  return path.join(getWebMcpRoot(), "users", userId, "sites");
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

function getNotesIndexFile(userId: string, siteKey: string) {
  return path.join(getNotesDir(userId, siteKey), "index.json");
}

function toWorkspace(userId: string, meta: StoredSiteMeta, graph: StoredGraph, notesIndex: StoredNoteIndex): WebSiteWorkspace {
  const siteDir = getSiteRoot(userId, meta.siteKey);
  return {
    ...meta,
    pageCount: graph.pages.length,
    edgeCount: graph.edges.length,
    noteCount: notesIndex.notes.length,
    siteDir,
    pagesDir: getPagesDir(userId, meta.siteKey),
    notesDir: getNotesDir(userId, meta.siteKey),
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

  if (!fs.existsSync(getGraphFile(userId, meta.siteKey))) {
    writeGraph(userId, meta.siteKey, { pages: [], edges: [] });
  }
  if (!fs.existsSync(getNotesIndexFile(userId, meta.siteKey))) {
    writeNotesIndex(userId, meta.siteKey, { notes: [] });
  }
  writeSiteMeta(userId, meta);
}

function getPageArtifactDir(userId: string, siteKey: string, rawUrl: string) {
  const url = normalizeUrl(rawUrl);
  const segments = url.pathname
    .split("/")
    .filter(Boolean)
    .map((segment) => slugifySegment(safeDecode(segment)));
  const pathSegments = segments.length > 0 ? segments : ["_root"];
  if (url.search) {
    pathSegments.push(`_query_${shortHash(url.search)}`);
  }
  return path.join(getPagesDir(userId, siteKey), sanitizeHost(url.hostname), ...pathSegments);
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
        label: label?.trim() || normalizedUrl.hostname,
        seedUrl: normalizedUrl.toString(),
        primaryHost: normalizedUrl.hostname,
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
    pages: sortPages(graph.pages),
    edges: [...graph.edges].sort((a, b) => b.discoveredAt - a.discoveredAt),
    notes: sortNotes(notes),
  };
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

  const snapshot: WebPageSnapshot = {
    url: normalizedUrl.toString(),
    title: title.trim(),
    host: normalizedUrl.hostname,
    pathname: normalizedUrl.pathname || "/",
    statusCode,
    summary: summary.trim(),
    plan: plan.trim(),
    sourceUrl: sourceUrl ? normalizeUrl(sourceUrl).toString() : null,
    goalState,
    visitedAt: now,
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

  const graph = readGraph(userId, siteKey);
  const pageSummary: WebPageSummary = {
    url: snapshot.url,
    title: snapshot.title,
    host: snapshot.host,
    pathname: snapshot.pathname,
    statusCode: snapshot.statusCode,
    summary: snapshot.summary,
    plan: snapshot.plan,
    sourceUrl: snapshot.sourceUrl,
    goalState: snapshot.goalState,
    visitedAt: snapshot.visitedAt,
    artifactDir: snapshot.artifactDir,
    snapshotFile: snapshot.snapshotFile,
    layoutFile: snapshot.layoutFile,
    linkCount: snapshot.linkCount,
  };

  const nextPages = graph.pages.filter((page) => page.url !== snapshot.url);
  nextPages.push(pageSummary);

  const edgeMap = new Map<string, WebEdge>();
  for (const edge of graph.edges) {
    edgeMap.set(`${edge.fromUrl}=>${edge.toUrl}`, edge);
  }
  for (const link of links) {
    const targetUrl = normalizeUrl(link.url).toString();
    edgeMap.set(`${snapshot.url}=>${targetUrl}`, {
      fromUrl: snapshot.url,
      toUrl: targetUrl,
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
