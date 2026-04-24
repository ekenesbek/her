import fs from "node:fs";
import path from "node:path";
import type { Agent, User } from "@/shared/types";

const DATA_ROOT = path.join(process.cwd(), ".data");
const IDENTITY_ROOT = path.join(DATA_ROOT, "identity");

const MAX_INJECTED_BYTES = 8_000;

function ensureDir(dir: string) {
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
}

function getUserRoot(userId: string) {
  return path.join(IDENTITY_ROOT, "users", userId);
}

function getUserMemoryFile(userId: string) {
  return path.join(getUserRoot(userId), "user.md");
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
    "# user.md — что я знаю о пользователе",
    "",
    "Эта память переживает чаты и шарится между всеми моими агентами. Сюда записываются устойчивые факты, привычки, контекст и предпочтения пользователя.",
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
    "(значимые выборы, исправления, повторяющиеся паттерны)",
    "",
  ]
    .filter(Boolean)
    .join("\n");
}

export function readOrInitUserMemory(user: User) {
  const filePath = getUserMemoryFile(user.id);
  if (!fs.existsSync(filePath)) {
    ensureDir(path.dirname(filePath));
    fs.writeFileSync(filePath, buildDefaultUserMemory(user));
  }
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

export function appendUserMemoryNote(user: User, note: string) {
  readOrInitUserMemory(user);
  appendSection(getUserMemoryFile(user.id), "Decisions & corrections", note);
}

export function appendSoulNote(userId: string, agent: Agent, note: string) {
  readOrInitSoul(userId, agent);
  appendSection(getSoulFile(userId, agent.id), "Lessons learned", note);
}

function clipForContext(content: string) {
  if (content.length <= MAX_INJECTED_BYTES) return content;
  return `${content.slice(0, MAX_INJECTED_BYTES)}\n\n…(truncated; see full file on disk)`;
}

export function buildIdentityRuntimeContext(user: User, agent: Agent) {
  const soul = clipForContext(readOrInitSoul(user.id, agent));
  const userMemory = clipForContext(readOrInitUserMemory(user));

  return [
    "Persistent identity memory is loaded for this turn:",
    "",
    "=== soul.md (your own identity, mission, style, lessons) ===",
    soul,
    "=== end soul.md ===",
    "",
    "=== user.md (what you persistently know about this user across chats) ===",
    userMemory,
    "=== end user.md ===",
    "",
    "Use these files as ground truth about who you are and who the user is. They override transient context but not the user's latest explicit instruction.",
    "To update them, include in your reply one or more tagged blocks (they will be stripped from the user-visible answer and appended to the corresponding file):",
    "  <remember-self>short fact about yourself or a lesson learned</remember-self>",
    "  <remember-user>short stable fact, preference, or correction about the user</remember-user>",
    "Only write things that should persist across chats. Skip ephemeral task chatter.",
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

  for (const note of selfNotes) {
    try {
      appendSoulNote(user.id, agent, note);
    } catch (error) {
      console.warn("identity: failed to append soul note", error);
    }
  }
  for (const note of userNotes) {
    try {
      appendUserMemoryNote(user, note);
    } catch (error) {
      console.warn("identity: failed to append user memory note", error);
    }
  }

  const cleanedContent = rawContent
    .replace(REMEMBER_SELF_TAG, "")
    .replace(REMEMBER_USER_TAG, "")
    .replace(/\n{3,}/g, "\n\n")
    .trim();

  return { cleanedContent, selfNotes, userNotes };
}

export function getIdentityFilePaths(userId: string, agentId: string) {
  return {
    userMemoryFile: getUserMemoryFile(userId),
    soulFile: getSoulFile(userId, agentId),
  };
}
