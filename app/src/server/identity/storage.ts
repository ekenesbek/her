import fs from "node:fs";
import path from "node:path";
import type { Agent, User } from "@/shared/types";

const DATA_ROOT = path.join(process.cwd(), ".data");
const IDENTITY_ROOT = path.join(DATA_ROOT, "identity");

const MAX_INJECTED_BYTES = 8_000;
const MAX_MEMORY_NOTE_CHARS = 1_200;

type UserWikiPageKey =
  | "profile"
  | "preferences"
  | "people"
  | "places"
  | "projects"
  | "decisions"
  | "corrections"
  | "inbox";

const USER_WIKI_PAGES: Array<{
  key: UserWikiPageKey;
  filename: string;
  title: string;
  summary: string;
}> = [
  {
    key: "profile",
    filename: "profile.md",
    title: "Profile",
    summary: "Identity facts explicitly provided by the user or account record.",
  },
  {
    key: "preferences",
    filename: "preferences.md",
    title: "Preferences",
    summary: "Stable preferences, defaults, constraints, and ranking habits.",
  },
  {
    key: "people",
    filename: "people.md",
    title: "People",
    summary: "User-relevant people and relationships when the user makes them relevant.",
  },
  {
    key: "places",
    filename: "places.md",
    title: "Places",
    summary: "Confirmed places such as home/work/saved destinations; no raw location traces.",
  },
  {
    key: "projects",
    filename: "projects.md",
    title: "Projects",
    summary: "Ongoing projects, repositories, goals, and durable work context.",
  },
  {
    key: "decisions",
    filename: "decisions.md",
    title: "Decisions",
    summary: "Explicit choices, approvals, rejected options, and outcomes.",
  },
  {
    key: "corrections",
    filename: "corrections.md",
    title: "Corrections",
    summary: "User corrections and negative preferences that should steer future behavior.",
  },
  {
    key: "inbox",
    filename: "inbox.md",
    title: "Memory Inbox",
    summary: "Low-confidence candidate notes awaiting corroboration or cleanup.",
  },
];

function ensureDir(dir: string) {
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
}

function getUserRoot(userId: string) {
  return path.join(IDENTITY_ROOT, "users", userId);
}

function getUserMemoryFile(userId: string) {
  return path.join(getUserRoot(userId), "user.md");
}

function getUserWikiRoot(userId: string) {
  return path.join(getUserRoot(userId), "wiki");
}

function getUserWikiFile(userId: string, filename: string) {
  return path.join(getUserWikiRoot(userId), filename);
}

function getUserWikiPageFile(userId: string, key: UserWikiPageKey) {
  const page = USER_WIKI_PAGES.find((candidate) => candidate.key === key);
  if (!page) throw new Error(`unknown_user_wiki_page:${key}`);
  return getUserWikiFile(userId, page.filename);
}

function getSoulFile(userId: string, agentId: string) {
  return path.join(getUserRoot(userId), "agents", agentId, "soul.md");
}

function buildDefaultSoul(agent: Agent) {
  return [
    `# soul.md — ${agent.name}`,
    "",
    "Это твоя живая память о себе. Сюда записывай то, что определяет тебя как агента: имя, цель, ценности, стиль общения, чему ты научился у пользователя.",
    "",
    "## Identity",
    `- name: ${agent.name}`,
    agent.description ? `- description: ${agent.description}` : null,
    `- model: ${agent.model}`,
    `- capabilities: ${agent.capabilities.join(", ") || "none"}`,
    "",
    "## Mission",
    agent.systemPrompt.trim() || "(пусто — задаётся системным промптом)",
    "",
    "## Style",
    "- Краткость > многословность.",
    "- Сначала результат/действие, потом отчёт.",
    "- Никаких необратимых действий без явного подтверждения.",
    "",
    "## Lessons learned",
    "(сюда добавляй наблюдения о собственных промахах и удачных решениях)",
    "",
  ]
    .filter(Boolean)
    .join("\n");
}

function buildDefaultUserMemory(user: User) {
  return [
    "# user.md — user memory summary",
    "",
    "This is a compatibility summary for the local user memory wiki in `wiki/`.",
    "Treat every note as source-bound evidence, not as permission for irreversible actions.",
    "",
    "## Identity",
    `- email: ${user.email}`,
    user.name ? `- name: ${user.name}` : null,
    "",
    "## Preferences",
    "(стиль общения, любимые сервисы, расписание, рабочие инструменты)",
    "",
    "## Context",
    "(текущий проект, роль, окружение, важные люди)",
    "",
    "## Decisions & corrections",
    "(append-only compatibility inbox; canonical pages live under `wiki/`)",
    "",
  ]
    .filter(Boolean)
    .join("\n");
}

function buildUserWikiSchema() {
  return [
    "# schema.md — user memory wiki rules",
    "",
    "This wiki is maintained by the app and LLM agents. Raw sources are chat/task traces, meeting outputs, browser observations, and explicit user statements. Wiki pages are compiled memory, not the raw source of truth.",
    "",
    "## Write policy",
    "- Write one atomic note per durable fact, preference, correction, decision, or project context.",
    "- Prefer explicit user statements and repeated behavior over single inferred observations.",
    "- Mark uncertain notes as candidates by placing them in `inbox.md` or by wording them as provisional.",
    "- Remember credential context only as a redacted reference or vault pointer. Do not store plaintext passwords, tokens, cookies, MFA codes, recovery codes, payment card data, private keys, or raw credential material in LLM-readable memory.",
    "- Do not store sensitive medical, legal, financial, biometric, or location history details unless the user explicitly asks to remember them and the memory is necessary.",
    "- Latest explicit user instruction overrides this wiki.",
    "- Memory is contextual guidance, never permission to send, delete, buy, book, order, reveal secrets, or change account security.",
    "",
    "## Read policy",
    "- Read `index.md` first, then only the pages relevant to the current task.",
    "- Prefer confirmed/repeated notes over candidate notes.",
    "- If a memory is stale, contradicted, or risky, ask or verify instead of acting from it.",
    "",
  ].join("\n");
}

function buildUserWikiIndex() {
  const rows = USER_WIKI_PAGES.map((page) => `- [${page.title}](./${page.filename}) — ${page.summary}`);
  return [
    "# index.md — user memory wiki",
    "",
    "Local-first, user-scoped, LLM-maintained wiki for durable user memory.",
    "",
    "## Pages",
    ...rows,
    "",
    "## Special files",
    "- [schema](./schema.md) — write/read rules for this wiki.",
    "- [log](./log.md) — append-only maintenance log.",
    "",
  ].join("\n");
}

function buildDefaultUserWikiPage(user: User, page: (typeof USER_WIKI_PAGES)[number]) {
  const profileFacts =
    page.key === "profile"
      ? ["", "## Confirmed facts", `- email: ${user.email}`, user.name ? `- name: ${user.name}` : null]
      : ["", "## Confirmed facts", "(none yet)"];

  return [
    `# ${page.title}`,
    "",
    page.summary,
    ...profileFacts,
    "",
    "## Candidate notes",
    "(append-only; promote, rewrite, or delete after user review/corroboration)",
    "",
  ]
    .filter(Boolean)
    .join("\n");
}

function ensureUserWiki(user: User) {
  const root = getUserWikiRoot(user.id);
  ensureDir(root);

  const schemaPath = getUserWikiFile(user.id, "schema.md");
  if (!fs.existsSync(schemaPath)) fs.writeFileSync(schemaPath, buildUserWikiSchema());

  const indexPath = getUserWikiFile(user.id, "index.md");
  if (!fs.existsSync(indexPath)) fs.writeFileSync(indexPath, buildUserWikiIndex());

  const logPath = getUserWikiFile(user.id, "log.md");
  if (!fs.existsSync(logPath)) {
    fs.writeFileSync(logPath, "# log.md — user memory maintenance log\n\n");
  }

  for (const page of USER_WIKI_PAGES) {
    const filePath = getUserWikiFile(user.id, page.filename);
    if (!fs.existsSync(filePath)) fs.writeFileSync(filePath, buildDefaultUserWikiPage(user, page));
  }
}

export function readOrInitUserMemory(user: User) {
  const filePath = getUserMemoryFile(user.id);
  if (!fs.existsSync(filePath)) {
    ensureDir(path.dirname(filePath));
    fs.writeFileSync(filePath, buildDefaultUserMemory(user));
  }
  ensureUserWiki(user);
  return fs.readFileSync(filePath, "utf8");
}

export function readOrInitSoul(userId: string, agent: Agent) {
  const filePath = getSoulFile(userId, agent.id);
  if (!fs.existsSync(filePath)) {
    ensureDir(path.dirname(filePath));
    fs.writeFileSync(filePath, buildDefaultSoul(agent));
  }
  return fs.readFileSync(filePath, "utf8");
}

function appendSection(filePath: string, sectionTitle: string, note: string) {
  if (!fs.existsSync(filePath)) {
    throw new Error("identity_file_missing");
  }
  const trimmed = note.trim();
  if (!trimmed) return;

  const stamp = new Date().toISOString();
  const block = `\n- [${stamp}] ${trimmed.replace(/\n/g, " ")}\n`;
  const current = fs.readFileSync(filePath, "utf8");

  const sectionRegex = new RegExp(`(##\\s+${sectionTitle}\\b[^\\n]*\\n)`);
  const next = sectionRegex.test(current)
    ? current.replace(sectionRegex, (match) => `${match}${block}`)
    : `${current.trimEnd()}\n\n## ${sectionTitle}\n${block}`;

  fs.writeFileSync(filePath, next);
}

function normalizeMemoryNote(note: string) {
  const normalized = redactMemorySecretValues(note).trim().replace(/\s+/g, " ");
  if (!normalized) return null;
  return normalized.length > MAX_MEMORY_NOTE_CHARS
    ? `${normalized.slice(0, MAX_MEMORY_NOTE_CHARS).trimEnd()}…`
    : normalized;
}

function redactMemorySecretValues(value: string) {
  return value
    .replace(/\bgithub_pat_[A-Za-z0-9_]{20,}\b/gi, "[redacted:github_pat]")
    .replace(/\bgh[pousr]_[A-Za-z0-9_]{20,}\b/gi, "[redacted:github_token]")
    .replace(/\bglpat-[A-Za-z0-9_-]{20,}\b/gi, "[redacted:gitlab_token]")
    .replace(/\bxox[baprs]-[A-Za-z0-9-]{20,}\b/gi, "[redacted:slack_token]")
    .replace(/\bsk-[A-Za-z0-9_-]{20,}\b/gi, "[redacted:api_key]")
    .replace(/\bBearer\s+[A-Za-z0-9._~+/=-]{20,}\b/gi, "Bearer [redacted]")
    .replace(/\beyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b/gi, "[redacted:jwt]")
    .replace(
      /\b(password|passwd|api[_-]?key|secret|client[_-]?secret|access[_-]?token|refresh[_-]?token|mfa|otp|recovery[_-]?code)\b\s*(?:is|=|:)\s*['"]?[^'"\s,;]+/gi,
      "$1: [redacted]",
    )
    .replace(
      /\b(card[_-]?number|credit[_-]?card|cvv|cvc)\b\s*(?:is|=|:)\s*['"]?[^'"\s,;]+/gi,
      "$1: [redacted]",
    );
}

function classifyUserMemoryNote(note: string): UserWikiPageKey {
  const lower = note.toLowerCase();
  if (/(?:исправ|ошиб|не надо|никогда|не используй|don't|do not|never|instead|correction|wrong)/i.test(note)) {
    return "corrections";
  }
  if (/(?:предпоч|люблю|не люблю|нравится|не нравится|любимый|по умолчанию|prefer|preference|like|dislike|favorite|default)/i.test(note)) {
    return "preferences";
  }
  if (/(?:решил|решили|выбрал|выбрали|подтверд|соглас|approved|confirmed|selected|decided|decision|agreed)/i.test(note)) {
    return "decisions";
  }
  if (/(?:адрес|дом|работа|офис|город|локац|home|work|office|address|location|place|destination)/i.test(note)) {
    return "places";
  }
  if (/(?:проект|репозитор|задач|roadmap|repo|repository|project|task|milestone|stage)/i.test(note)) {
    return "projects";
  }
  if (/(?:коллег|команд|клиент|друг|жена|муж|сын|дочь|мама|папа|person|people|team|client|friend|wife|husband|partner)/i.test(lower)) {
    return "people";
  }
  return "inbox";
}

function appendUserWikiNote(user: User, pageKey: UserWikiPageKey, note: string) {
  ensureUserWiki(user);
  const stamp = new Date().toISOString();
  const filePath = getUserWikiPageFile(user.id, pageKey);
  appendSection(filePath, "Candidate notes", note);

  const page = USER_WIKI_PAGES.find((candidate) => candidate.key === pageKey);
  const logLine = `## [${stamp}] memory | ${page?.filename ?? pageKey}\n\n- ${note}\n\n`;
  fs.appendFileSync(getUserWikiFile(user.id, "log.md"), logLine);
}

export function appendUserMemoryNote(user: User, note: string) {
  readOrInitUserMemory(user);
  const normalized = normalizeMemoryNote(note);
  if (!normalized) return false;

  const pageKey = classifyUserMemoryNote(normalized);
  appendSection(getUserMemoryFile(user.id), "Decisions & corrections", `[candidate:${pageKey}] ${normalized}`);
  appendUserWikiNote(user, pageKey, normalized);
  return true;
}

export function appendSoulNote(userId: string, agent: Agent, note: string) {
  readOrInitSoul(userId, agent);
  const normalized = normalizeMemoryNote(note);
  if (!normalized) return false;
  appendSection(getSoulFile(userId, agent.id), "Lessons learned", normalized);
  return true;
}

function clipForContext(content: string) {
  if (content.length <= MAX_INJECTED_BYTES) return content;
  return `${content.slice(0, MAX_INJECTED_BYTES)}\n\n…(truncated; see full file on disk)`;
}

function readUserWikiForContext(user: User) {
  readOrInitUserMemory(user);
  ensureUserWiki(user);

  const filenames = [
    "index.md",
    "profile.md",
    "preferences.md",
    "people.md",
    "places.md",
    "projects.md",
    "decisions.md",
    "corrections.md",
    "inbox.md",
  ];

  return filenames
    .map((filename) => {
      const filePath = getUserWikiFile(user.id, filename);
      const content = fs.existsSync(filePath) ? fs.readFileSync(filePath, "utf8").trim() : "";
      return content ? `--- ${filename} ---\n${content}` : "";
    })
    .filter(Boolean)
    .join("\n\n");
}

export function buildIdentityRuntimeContext(user: User, agent: Agent) {
  const soul = clipForContext(readOrInitSoul(user.id, agent));
  const userWiki = clipForContext(readUserWikiForContext(user));

  return [
    "Persistent local identity memory is loaded for this turn:",
    "",
    "=== soul.md (your own identity, mission, style, lessons) ===",
    soul,
    "=== end soul.md ===",
    "",
    "=== user memory wiki (compiled, source-bound memory about this user) ===",
    userWiki,
    "=== end user memory wiki ===",
    "",
    "Use this memory as evidence, not as permission. Latest explicit user instructions and current external evidence override stale or candidate memory.",
    "Prefer confirmed/repeated facts over candidate notes. If a memory is risky, stale, sensitive, or contradicted, verify instead of acting from it.",
    "Remember credential context only as a redacted reference or vault pointer. Never store plaintext passwords, tokens, cookies, MFA codes, recovery codes, payment cards, private keys, or raw credential material in LLM-readable memory.",
    "To update memory, include in your reply one or more tagged blocks (they will be stripped from the user-visible answer and appended to the local wiki):",
    "  <remember-self>short fact about yourself or a lesson learned</remember-self>",
    "  <remember-user>one atomic stable fact, preference, correction, decision, project context, or place about the user</remember-user>",
    "Only write durable, source-grounded memory. Skip ephemeral task chatter and assumptions.",
  ].join("\n");
}

const REMEMBER_SELF_TAG = /<remember-self>([\s\S]*?)<\/remember-self>/gi;
const REMEMBER_USER_TAG = /<remember-user>([\s\S]*?)<\/remember-user>/gi;

export function extractAndPersistMemoryNotes(
  user: User,
  agent: Agent,
  rawContent: string,
): { cleanedContent: string; selfNotes: string[]; userNotes: string[] } {
  const selfNotes: string[] = [];
  const userNotes: string[] = [];

  for (const match of rawContent.matchAll(REMEMBER_SELF_TAG)) {
    const note = match[1]?.trim();
    if (note) selfNotes.push(note);
  }
  for (const match of rawContent.matchAll(REMEMBER_USER_TAG)) {
    const note = match[1]?.trim();
    if (note) userNotes.push(note);
  }

  const persistedSelfNotes: string[] = [];
  for (const note of selfNotes) {
    try {
      if (appendSoulNote(user.id, agent, note)) {
        persistedSelfNotes.push(note);
      }
    } catch (error) {
      console.warn("identity: failed to append soul note", error);
    }
  }
  const persistedUserNotes: string[] = [];
  for (const note of userNotes) {
    try {
      if (appendUserMemoryNote(user, note)) {
        persistedUserNotes.push(note);
      }
    } catch (error) {
      console.warn("identity: failed to append user memory note", error);
    }
  }

  const cleanedContent = rawContent
    .replace(REMEMBER_SELF_TAG, "")
    .replace(REMEMBER_USER_TAG, "")
    .replace(/\n{3,}/g, "\n\n")
    .trim();

  return { cleanedContent, selfNotes: persistedSelfNotes, userNotes: persistedUserNotes };
}

export function getIdentityFilePaths(userId: string, agentId: string) {
  return {
    userMemoryFile: getUserMemoryFile(userId),
    soulFile: getSoulFile(userId, agentId),
  };
}
