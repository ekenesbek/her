import Database from "better-sqlite3";
import { randomBytes, randomUUID } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import type {
  Agent,
  AgentDraft,
  AuthChallenge,
  AuthChallengeKind,
  BrowserSettings,
  ChatMessage,
  CredentialRequestedAction,
  CredentialRequest,
  CredentialRequestStatus,
  Session,
  TaskArtifact,
  TaskArtifactKind,
  TaskEvent,
  TaskEventKind,
  TaskRunSnapshot,
  TaskRunStatus,
  DecisionMemory,
  DecisionMemorySignal,
  ToolTraceEntry,
  User,
  WebAuthnCredentialRecord,
} from "@/shared/types";

const DATA_DIR = path.join(process.cwd(), ".data");
if (!fs.existsSync(DATA_DIR)) fs.mkdirSync(DATA_DIR, { recursive: true });

const dbPath = path.join(DATA_DIR, "meta.db");
const AUTH_CHALLENGE_TTL_MS = 5 * 60 * 1000;

let _db: Database.Database | null = null;

type AgentRow = {
  id: string;
  owner_user_id: string | null;
  name: string;
  emoji: string;
  description: string;
  model: string;
  system_prompt: string;
  capabilities: string;
  created_at: number;
  updated_at: number;
};

type ChatMessageRow = {
  id: string;
  agent_id: string;
  role: "user" | "assistant";
  content: string;
  metadata: string | null;
  created_at: number;
};

type TaskRunRow = {
  id: string;
  user_id: string;
  agent_id: string;
  title: string;
  input: string;
  status: TaskRunStatus;
  provider: "claude" | "codex";
  browser_source: "user" | "env" | "none";
  started_at: number;
  completed_at: number | null;
};

type TaskEventRow = {
  id: string;
  task_run_id: string;
  kind: TaskEventKind;
  title: string;
  status: TaskRunStatus | null;
  details: string | null;
  tool_call_id: string | null;
  artifact_id: string | null;
  started_at: number | null;
  completed_at: number | null;
  created_at: number;
};

type TaskArtifactRow = {
  id: string;
  task_run_id: string;
  kind: TaskArtifactKind;
  label: string;
  mime_type: string;
  byte_size: number;
  storage_path: string;
  created_at: number;
};

type UserRow = {
  id: string;
  email: string;
  name: string;
  created_at: number;
  updated_at: number;
};

type SessionRow = {
  id: string;
  user_id: string;
  created_at: number;
  expires_at: number;
};

type BrowserSettingsRow = {
  user_id: string;
  chrome_mcp_url: string | null;
  created_at: number;
  updated_at: number;
};

type DecisionMemoryRow = {
  user_id: string;
  recent_signals: string;
  created_at: number;
  updated_at: number;
};

type CredentialRequestRow = {
  id: string;
  user_id: string;
  task_run_id: string;
  agent_id: string;
  origin: string;
  current_url: string | null;
  account_hint: string | null;
  reason: string;
  requested_action: CredentialRequestedAction;
  status: CredentialRequestStatus;
  created_at: number;
  expires_at: number;
  resolved_at: number | null;
};

type AuthChallengeRow = {
  id: string;
  kind: AuthChallengeKind;
  user_id: string | null;
  challenge: string;
  payload: string;
  created_at: number;
  expires_at: number;
};

type WebAuthnCredentialRow = {
  id: string;
  user_id: string;
  public_key: Buffer;
  counter: number;
  transports: string;
  device_type: "singleDevice" | "multiDevice";
  backed_up: number;
  created_at: number;
  last_used_at: number | null;
};

function normalizeEmail(email: string): string {
  return email.trim().toLowerCase();
}

function ensureAgentsOwnerColumn(db: Database.Database) {
  const columns = db.prepare("PRAGMA table_info(agents)").all() as Array<{ name: string }>;
  if (!columns.some((column) => column.name === "owner_user_id")) {
    db.exec("ALTER TABLE agents ADD COLUMN owner_user_id TEXT");
  }
  db.exec("CREATE INDEX IF NOT EXISTS idx_agents_owner ON agents(owner_user_id, updated_at DESC)");
}

function ensureChatMessagesMetadataColumn(db: Database.Database) {
  const columns = db.prepare("PRAGMA table_info(chat_messages)").all() as Array<{ name: string }>;
  if (!columns.some((column) => column.name === "metadata")) {
    db.exec("ALTER TABLE chat_messages ADD COLUMN metadata TEXT");
  }
}

function cleanupExpiredRecords(db: Database.Database) {
  const now = Date.now();
  db.prepare("DELETE FROM auth_challenges WHERE expires_at <= ?").run(now);
  db.prepare("DELETE FROM sessions WHERE expires_at <= ?").run(now);
  db.prepare(
    "UPDATE credential_requests SET status = 'expired', resolved_at = ? WHERE status = 'pending' AND expires_at <= ?",
  ).run(now, now);
}

export function getDb(): Database.Database {
  if (_db) return _db;

  const db = new Database(dbPath);
  db.pragma("journal_mode = WAL");
  db.pragma("foreign_keys = ON");
  db.exec(`
    CREATE TABLE IF NOT EXISTS users (
      id TEXT PRIMARY KEY,
      email TEXT NOT NULL UNIQUE,
      name TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);

    CREATE TABLE IF NOT EXISTS sessions (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      expires_at INTEGER NOT NULL,
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id, expires_at);

    CREATE TABLE IF NOT EXISTS user_browser_settings (
      user_id TEXT PRIMARY KEY,
      chrome_mcp_url TEXT,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS user_decision_memory (
      user_id TEXT PRIMARY KEY,
      recent_signals TEXT NOT NULL DEFAULT '[]',
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS credential_requests (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL,
      task_run_id TEXT NOT NULL,
      agent_id TEXT NOT NULL,
      origin TEXT NOT NULL,
      current_url TEXT,
      account_hint TEXT,
      reason TEXT NOT NULL,
      requested_action TEXT NOT NULL,
      status TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      expires_at INTEGER NOT NULL,
      resolved_at INTEGER,
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
      FOREIGN KEY (task_run_id) REFERENCES task_runs(id) ON DELETE CASCADE,
      FOREIGN KEY (agent_id) REFERENCES agents(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_credential_requests_user ON credential_requests(user_id, created_at DESC);
    CREATE INDEX IF NOT EXISTS idx_credential_requests_task ON credential_requests(task_run_id, status, created_at DESC);

    CREATE TABLE IF NOT EXISTS auth_challenges (
      id TEXT PRIMARY KEY,
      kind TEXT NOT NULL,
      user_id TEXT,
      challenge TEXT NOT NULL,
      payload TEXT NOT NULL DEFAULT '{}',
      created_at INTEGER NOT NULL,
      expires_at INTEGER NOT NULL,
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_auth_challenges_kind ON auth_challenges(kind, expires_at);

    CREATE TABLE IF NOT EXISTS webauthn_credentials (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL,
      public_key BLOB NOT NULL,
      counter INTEGER NOT NULL,
      transports TEXT NOT NULL DEFAULT '[]',
      device_type TEXT NOT NULL,
      backed_up INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL,
      last_used_at INTEGER,
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_webauthn_credentials_user ON webauthn_credentials(user_id);

    CREATE TABLE IF NOT EXISTS agents (
      id TEXT PRIMARY KEY,
      owner_user_id TEXT,
      name TEXT NOT NULL,
      emoji TEXT NOT NULL,
      description TEXT NOT NULL DEFAULT '',
      model TEXT NOT NULL,
      system_prompt TEXT NOT NULL DEFAULT '',
      capabilities TEXT NOT NULL DEFAULT '[]',
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS chat_messages (
      id TEXT PRIMARY KEY,
      agent_id TEXT NOT NULL,
      role TEXT NOT NULL,
      content TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      FOREIGN KEY (agent_id) REFERENCES agents(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_chat_agent ON chat_messages(agent_id, created_at);

    CREATE TABLE IF NOT EXISTS task_runs (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL,
      agent_id TEXT NOT NULL,
      title TEXT NOT NULL,
      input TEXT NOT NULL,
      status TEXT NOT NULL,
      provider TEXT NOT NULL,
      browser_source TEXT NOT NULL,
      started_at INTEGER NOT NULL,
      completed_at INTEGER,
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
      FOREIGN KEY (agent_id) REFERENCES agents(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_task_runs_agent ON task_runs(agent_id, user_id, started_at DESC);

    CREATE TABLE IF NOT EXISTS task_events (
      id TEXT PRIMARY KEY,
      task_run_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      title TEXT NOT NULL,
      status TEXT,
      details TEXT,
      tool_call_id TEXT,
      artifact_id TEXT,
      started_at INTEGER,
      completed_at INTEGER,
      created_at INTEGER NOT NULL,
      FOREIGN KEY (task_run_id) REFERENCES task_runs(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_task_events_run ON task_events(task_run_id, created_at ASC);

    CREATE TABLE IF NOT EXISTS task_artifacts (
      id TEXT PRIMARY KEY,
      task_run_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      label TEXT NOT NULL,
      mime_type TEXT NOT NULL,
      byte_size INTEGER NOT NULL,
      storage_path TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      FOREIGN KEY (task_run_id) REFERENCES task_runs(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_task_artifacts_run ON task_artifacts(task_run_id, created_at ASC);

    CREATE TABLE IF NOT EXISTS service_registry (
      user_id TEXT NOT NULL,
      origin TEXT NOT NULL,
      kind TEXT NOT NULL DEFAULT 'unknown',
      logged_in INTEGER NOT NULL DEFAULT 0,
      has_mcp INTEGER NOT NULL DEFAULT 0,
      mcp_slug TEXT,
      auto_provisioned INTEGER NOT NULL DEFAULT 0,
      first_seen INTEGER NOT NULL,
      last_seen INTEGER NOT NULL,
      visit_count INTEGER NOT NULL DEFAULT 1,
      PRIMARY KEY (user_id, origin),
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_service_registry_user ON service_registry(user_id, last_seen DESC);

    CREATE TABLE IF NOT EXISTS site_knowledge (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL,
      origin TEXT NOT NULL,
      kind TEXT NOT NULL,
      content_md TEXT NOT NULL DEFAULT '',
      source TEXT NOT NULL DEFAULT 'recording',
      confidence REAL NOT NULL DEFAULT 0.5,
      superseded_by TEXT,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_site_knowledge_user_origin ON site_knowledge(user_id, origin, updated_at DESC);

    CREATE TABLE IF NOT EXISTS knowledge_pages (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL,
      type TEXT NOT NULL,
      title TEXT NOT NULL,
      content_md TEXT NOT NULL DEFAULT '',
      confidence REAL NOT NULL DEFAULT 0.5,
      superseded_by TEXT,
      sources TEXT NOT NULL DEFAULT '[]',
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_knowledge_pages_user ON knowledge_pages(user_id, type, updated_at DESC);

    CREATE TABLE IF NOT EXISTS knowledge_edges (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL,
      from_page TEXT NOT NULL,
      to_page TEXT NOT NULL,
      relation TEXT NOT NULL,
      weight REAL NOT NULL DEFAULT 1.0,
      created_at INTEGER NOT NULL,
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
      FOREIGN KEY (from_page) REFERENCES knowledge_pages(id) ON DELETE CASCADE,
      FOREIGN KEY (to_page) REFERENCES knowledge_pages(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_knowledge_edges_from ON knowledge_edges(user_id, from_page);
    CREATE INDEX IF NOT EXISTS idx_knowledge_edges_to ON knowledge_edges(user_id, to_page);

    CREATE TABLE IF NOT EXISTS user_policies (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL,
      scope TEXT NOT NULL,
      action TEXT NOT NULL,
      decision TEXT NOT NULL,
      rationale TEXT,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_user_policies_unique ON user_policies(user_id, scope, action);

    CREATE TABLE IF NOT EXISTS agent_actions (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL,
      agent_id TEXT NOT NULL,
      task_run_id TEXT,
      tool TEXT NOT NULL,
      origin TEXT,
      args_hash TEXT NOT NULL,
      outcome TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
      FOREIGN KEY (agent_id) REFERENCES agents(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_agent_actions_user ON agent_actions(user_id, created_at DESC);

    CREATE TABLE IF NOT EXISTS encrypted_credentials (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL,
      origin TEXT NOT NULL,
      username TEXT,
      ciphertext BLOB NOT NULL,
      iv BLOB NOT NULL,
      kind TEXT NOT NULL DEFAULT 'password',
      created_at INTEGER NOT NULL,
      last_used_at INTEGER,
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_encrypted_credentials_user ON encrypted_credentials(user_id, origin);

    CREATE TABLE IF NOT EXISTS user_mcp_connections (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL,
      slug TEXT NOT NULL,
      origin TEXT,
      connection_url TEXT,
      status TEXT NOT NULL DEFAULT 'pending',
      last_error TEXT,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_user_mcp_connections_slug ON user_mcp_connections(user_id, slug);
  `);

  ensureAgentsOwnerColumn(db);
  ensureChatMessagesMetadataColumn(db);
  cleanupExpiredRecords(db);
  _db = db;
  return db;
}

function rowToAgent(row: AgentRow): Agent {
  return {
    id: row.id,
    name: row.name,
    emoji: row.emoji,
    description: row.description,
    model: row.model as Agent["model"],
    systemPrompt: row.system_prompt,
    capabilities: JSON.parse(row.capabilities),
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function parseJsonObject(raw: string | null): Record<string, unknown> {
  if (!raw) return {};

  try {
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
  } catch {
    return {};
  }
}

function parseMessageMetadata(row: ChatMessageRow): Pick<ChatMessage, "toolTrace"> & { taskRunId?: string } {
  if (!row.metadata) return {};

  const parsed = parseJsonObject(row.metadata) as { toolTrace?: ToolTraceEntry[]; taskRunId?: string };
  return {
    ...(Array.isArray(parsed.toolTrace) && parsed.toolTrace.length > 0
      ? { toolTrace: parsed.toolTrace }
      : {}),
    ...(typeof parsed.taskRunId === "string" ? { taskRunId: parsed.taskRunId } : {}),
  };
}

function buildMessageMetadataJson(metadata?: { toolTrace?: ToolTraceEntry[]; taskRunId?: string }) {
  const metadataPayload = {
    ...(metadata?.toolTrace && metadata.toolTrace.length > 0
      ? { toolTrace: sanitizeToolTraceForStorage(metadata.toolTrace) }
      : {}),
    ...(metadata?.taskRunId ? { taskRunId: metadata.taskRunId } : {}),
  };

  return Object.keys(metadataPayload).length > 0 ? JSON.stringify(metadataPayload) : null;
}

const MAX_STORED_TOOL_TRACE_ENTRIES = 200;
const MAX_STORED_TOOL_VALUE_DEPTH = 5;
const MAX_STORED_TOOL_STRING_LENGTH = 2_000;
const MAX_STORED_TOOL_ARRAY_ITEMS = 20;
const MAX_STORED_TOOL_OBJECT_KEYS = 50;

function sanitizeToolTraceForStorage(trace: ToolTraceEntry[]): ToolTraceEntry[] {
  return trace.slice(0, MAX_STORED_TOOL_TRACE_ENTRIES).map((entry) => ({
    id: sanitizeStoredString(entry.id),
    name: sanitizeStoredString(entry.name),
    ...(entry.input !== undefined ? { input: sanitizeToolValueForStorage(entry.input) } : {}),
    ...(entry.result !== undefined ? { result: sanitizeToolValueForStorage(entry.result) } : {}),
    ...(entry.artifacts && entry.artifacts.length > 0
      ? { artifacts: entry.artifacts.map(sanitizeTaskArtifactForStorage) }
      : {}),
    ...(entry.isError !== undefined ? { isError: entry.isError } : {}),
    startedAt: entry.startedAt,
    ...(entry.completedAt !== undefined ? { completedAt: entry.completedAt } : {}),
  }));
}

function sanitizeTaskArtifactForStorage(artifact: TaskArtifact): TaskArtifact {
  return {
    id: artifact.id,
    taskRunId: artifact.taskRunId,
    kind: artifact.kind,
    label: sanitizeStoredString(artifact.label),
    mimeType: artifact.mimeType,
    byteSize: artifact.byteSize,
    url: artifact.url,
    createdAt: artifact.createdAt,
  };
}

function sanitizeToolValueForStorage(
  value: unknown,
  depth = 0,
  seen = new WeakSet<object>(),
): unknown {
  if (typeof value === "string") return sanitizeStoredString(value);
  if (typeof value !== "object" || value === null) return value;

  if (seen.has(value)) return "[circular]";
  if (depth >= MAX_STORED_TOOL_VALUE_DEPTH) return "[truncated: max depth]";
  seen.add(value);

  if (Array.isArray(value)) {
    const items = value
      .slice(0, MAX_STORED_TOOL_ARRAY_ITEMS)
      .map((item) => sanitizeToolValueForStorage(item, depth + 1, seen));
    if (value.length > MAX_STORED_TOOL_ARRAY_ITEMS) {
      items.push(`[truncated: ${value.length - MAX_STORED_TOOL_ARRAY_ITEMS} more item(s)]`);
    }
    return items;
  }

  if (!isRecord(value)) return "[unsupported object]";
  if (isImageBlock(value)) return summarizeImageBlock(value);

  const entries = Object.entries(value);
  const sanitized: Record<string, unknown> = {};
  for (const [key, child] of entries.slice(0, MAX_STORED_TOOL_OBJECT_KEYS)) {
    sanitized[key] = shouldRedactStorageKey(key)
      ? "[redacted]"
      : sanitizeToolValueForStorage(child, depth + 1, seen);
  }
  if (entries.length > MAX_STORED_TOOL_OBJECT_KEYS) {
    sanitized.__truncatedKeys = entries.length - MAX_STORED_TOOL_OBJECT_KEYS;
  }
  return sanitized;
}

function sanitizeStoredString(value: string) {
  const cleaned = redactSecretPatterns(value.replace(/\u0000/g, ""));
  if (cleaned.length <= MAX_STORED_TOOL_STRING_LENGTH) return cleaned;
  return `${cleaned.slice(0, MAX_STORED_TOOL_STRING_LENGTH)}...[truncated ${cleaned.length - MAX_STORED_TOOL_STRING_LENGTH} chars]`;
}

function shouldRedactStorageKey(key: string) {
  return /password|passwd|token|secret|api[_-]?key|access[_-]?key|client[_-]?secret|private[_-]?key|cookie|authorization|card|cvv/i.test(key);
}

function redactSecretPatterns(value: string) {
  return value
    .replace(/\bgithub_pat_[A-Za-z0-9_]{20,}\b/g, "[redacted:github_pat]")
    .replace(/\bgh[pousr]_[A-Za-z0-9_]{20,}\b/g, "[redacted:github_token]")
    .replace(/\bglpat-[A-Za-z0-9_-]{20,}\b/g, "[redacted:gitlab_token]")
    .replace(/\bxox[baprs]-[A-Za-z0-9-]{20,}\b/g, "[redacted:slack_token]")
    .replace(/\bsk-[A-Za-z0-9_-]{20,}\b/g, "[redacted:api_key]");
}

function isImageBlock(value: Record<string, unknown>) {
  return value.type === "image";
}

function summarizeImageBlock(value: Record<string, unknown>) {
  const source = isRecord(value.source) ? value.source : null;
  const directData = typeof value.data === "string" ? value.data : null;
  const sourceData =
    source?.type === "base64" && typeof source.data === "string" ? source.data : null;
  const mimeType =
    (typeof value.mimeType === "string" ? value.mimeType : undefined) ??
    (typeof source?.media_type === "string" ? source.media_type : undefined) ??
    "image/*";
  const byteSize = estimateBase64ByteSize(directData ?? sourceData);

  return {
    type: "image",
    mimeType,
    ...(byteSize !== null ? { byteSize } : {}),
    omitted: "base64 image data omitted from chat metadata; see task artifacts",
  };
}

function estimateBase64ByteSize(value: string | null) {
  if (!value) return null;
  const padding = value.endsWith("==") ? 2 : value.endsWith("=") ? 1 : 0;
  return Math.max(0, Math.floor((value.length * 3) / 4) - padding);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function rowToUser(row: UserRow): User {
  return {
    id: row.id,
    email: row.email,
    name: row.name,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function rowToSession(row: SessionRow): Session {
  return {
    id: row.id,
    userId: row.user_id,
    createdAt: row.created_at,
    expiresAt: row.expires_at,
  };
}

function rowToBrowserSettings(row: BrowserSettingsRow): BrowserSettings {
  return {
    chromeMcpUrl: row.chrome_mcp_url,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function rowToCredentialRequest(row: CredentialRequestRow): CredentialRequest {
  return {
    id: row.id,
    userId: row.user_id,
    taskRunId: row.task_run_id,
    agentId: row.agent_id,
    origin: row.origin,
    currentUrl: row.current_url,
    accountHint: row.account_hint,
    reason: row.reason,
    requestedAction: row.requested_action,
    status: row.status,
    createdAt: row.created_at,
    expiresAt: row.expires_at,
    resolvedAt: row.resolved_at,
  };
}

function rowToCredential(row: WebAuthnCredentialRow): WebAuthnCredentialRecord {
  return {
    id: row.id,
    userId: row.user_id,
    publicKey: new Uint8Array(row.public_key),
    counter: row.counter,
    transports: JSON.parse(row.transports),
    deviceType: row.device_type,
    backedUp: Boolean(row.backed_up),
    createdAt: row.created_at,
    lastUsedAt: row.last_used_at,
  };
}

function rowToChallenge(row: AuthChallengeRow): AuthChallenge {
  return {
    id: row.id,
    kind: row.kind,
    userId: row.user_id,
    challenge: row.challenge,
    payload: JSON.parse(row.payload),
    createdAt: row.created_at,
    expiresAt: row.expires_at,
  };
}

function rowToTaskEvent(row: TaskEventRow): TaskEvent {
  const startedAt = row.started_at ?? undefined;
  const completedAt = row.completed_at ?? undefined;

  return {
    id: row.id,
    taskRunId: row.task_run_id,
    kind: row.kind,
    title: row.title,
    ...(row.status ? { status: row.status } : {}),
    ...(row.details ? { details: parseJsonObject(row.details) } : {}),
    ...(row.tool_call_id ? { toolCallId: row.tool_call_id } : {}),
    ...(row.artifact_id ? { artifactId: row.artifact_id } : {}),
    ...(startedAt ? { startedAt } : {}),
    ...(completedAt ? { completedAt } : {}),
    ...(startedAt && completedAt ? { durationMs: completedAt - startedAt } : {}),
    createdAt: row.created_at,
  };
}

function rowToTaskArtifact(row: TaskArtifactRow): TaskArtifact {
  return {
    id: row.id,
    taskRunId: row.task_run_id,
    kind: row.kind,
    label: row.label,
    mimeType: row.mime_type,
    byteSize: row.byte_size,
    url: `/api/task-runs/${row.task_run_id}/artifacts/${row.id}`,
    createdAt: row.created_at,
  };
}

function rowToTaskRunSnapshot(
  row: TaskRunRow,
  events: TaskEvent[],
  artifacts: TaskArtifact[],
): TaskRunSnapshot {
  return {
    id: row.id,
    agentId: row.agent_id,
    status: row.status,
    title: row.title,
    input: row.input,
    provider: row.provider,
    browserSource: row.browser_source,
    startedAt: row.started_at,
    ...(row.completed_at ? { completedAt: row.completed_at, durationMs: row.completed_at - row.started_at } : {}),
    events,
    artifacts,
  };
}

export function countUsers(): number {
  const db = getDb();
  const row = db.prepare("SELECT COUNT(*) AS count FROM users").get() as { count: number };
  return row.count;
}

export function getUserById(id: string): User | null {
  const db = getDb();
  const row = db.prepare("SELECT * FROM users WHERE id = ?").get(id) as UserRow | undefined;
  return row ? rowToUser(row) : null;
}

export function getUserByEmail(email: string): User | null {
  const db = getDb();
  const row = db
    .prepare("SELECT * FROM users WHERE email = ?")
    .get(normalizeEmail(email)) as UserRow | undefined;
  return row ? rowToUser(row) : null;
}

export function createUser({
  id = randomUUID(),
  email,
  name,
}: {
  id?: string;
  email: string;
  name: string;
}): User {
  const db = getDb();
  const now = Date.now();
  const normalizedEmail = normalizeEmail(email);
  const hadUsers = countUsers() > 0;

  db.prepare(
    `INSERT INTO users (id, email, name, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?)`,
  ).run(id, normalizedEmail, name, now, now);

  if (!hadUsers) {
    db.prepare("UPDATE agents SET owner_user_id = ? WHERE owner_user_id IS NULL").run(id);
  }

  return {
    id,
    email: normalizedEmail,
    name,
    createdAt: now,
    updatedAt: now,
  };
}

export function createSession(userId: string, ttlMs: number): Session {
  const db = getDb();
  const now = Date.now();
  const id = randomBytes(32).toString("base64url");
  const expiresAt = now + ttlMs;

  db.prepare(
    `INSERT INTO sessions (id, user_id, created_at, expires_at)
     VALUES (?, ?, ?, ?)`,
  ).run(id, userId, now, expiresAt);

  return rowToSession({ id, user_id: userId, created_at: now, expires_at: expiresAt });
}

export function getBrowserSettings(userId: string): BrowserSettings {
  const db = getDb();
  const row = db
    .prepare("SELECT * FROM user_browser_settings WHERE user_id = ?")
    .get(userId) as BrowserSettingsRow | undefined;

  if (!row) {
    return {
      chromeMcpUrl: null,
      createdAt: null,
      updatedAt: null,
    };
  }

  return rowToBrowserSettings(row);
}

export function upsertBrowserSettings({
  userId,
  chromeMcpUrl,
}: {
  userId: string;
  chromeMcpUrl: string | null;
}): BrowserSettings {
  const db = getDb();
  const now = Date.now();

  db.prepare(
    `INSERT INTO user_browser_settings (user_id, chrome_mcp_url, created_at, updated_at)
     VALUES (?, ?, ?, ?)
     ON CONFLICT(user_id) DO UPDATE SET
       chrome_mcp_url = excluded.chrome_mcp_url,
       updated_at = excluded.updated_at`,
  ).run(userId, chromeMcpUrl, now, now);

  return getBrowserSettings(userId);
}

export function getDecisionMemory(userId: string): DecisionMemory {
  const db = getDb();
  const row = db
    .prepare("SELECT * FROM user_decision_memory WHERE user_id = ?")
    .get(userId) as DecisionMemoryRow | undefined;

  if (!row) return { recentSignals: [] };

  return buildDecisionMemory(parseDecisionSignals(row.recent_signals), row.updated_at);
}

export function recordDecisionMemorySignal({
  userId,
  message,
}: {
  userId: string;
  message: string;
}): DecisionMemory {
  const signal = normalizeDecisionSignalText(message);
  if (!signal) return getDecisionMemory(userId);

  const db = getDb();
  const now = Date.now();
  const current = getDecisionMemory(userId).recentSignals;
  const next = [...current, { text: signal, recordedAt: now }].slice(-20);

  db.prepare(
    `INSERT INTO user_decision_memory (user_id, recent_signals, created_at, updated_at)
     VALUES (?, ?, ?, ?)
     ON CONFLICT(user_id) DO UPDATE SET
       recent_signals = excluded.recent_signals,
       updated_at = excluded.updated_at`,
  ).run(userId, JSON.stringify(next), now, now);

  return buildDecisionMemory(next, now);
}

export function createCredentialRequest({
  userId,
  taskRunId,
  agentId,
  origin,
  currentUrl = null,
  accountHint = null,
  reason,
  requestedAction,
  ttlMs = 5 * 60 * 1000,
}: {
  userId: string;
  taskRunId: string;
  agentId: string;
  origin: string;
  currentUrl?: string | null;
  accountHint?: string | null;
  reason: string;
  requestedAction: CredentialRequestedAction;
  ttlMs?: number;
}): CredentialRequest {
  const db = getDb();
  const id = randomUUID();
  const now = Date.now();
  const expiresAt = now + ttlMs;

  db.prepare(
    `INSERT INTO credential_requests (
      id, user_id, task_run_id, agent_id, origin, current_url, account_hint,
      reason, requested_action, status, created_at, expires_at, resolved_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  ).run(
    id,
    userId,
    taskRunId,
    agentId,
    origin,
    currentUrl,
    accountHint,
    reason,
    requestedAction,
    "pending",
    now,
    expiresAt,
    null,
  );

  return rowToCredentialRequest({
    id,
    user_id: userId,
    task_run_id: taskRunId,
    agent_id: agentId,
    origin,
    current_url: currentUrl,
    account_hint: accountHint,
    reason,
    requested_action: requestedAction,
    status: "pending",
    created_at: now,
    expires_at: expiresAt,
    resolved_at: null,
  });
}

export function getCredentialRequest(id: string, userId: string): CredentialRequest | null {
  const db = getDb();
  const row = db
    .prepare("SELECT * FROM credential_requests WHERE id = ? AND user_id = ?")
    .get(id, userId) as CredentialRequestRow | undefined;

  if (!row) return null;

  if (row.status === "pending" && row.expires_at <= Date.now()) {
    expireCredentialRequest(id, userId);
    return getCredentialRequest(id, userId);
  }

  return rowToCredentialRequest(row);
}

export function listCredentialRequests({
  userId,
  taskRunId,
  status,
  limit = 50,
}: {
  userId: string;
  taskRunId?: string;
  status?: CredentialRequestStatus;
  limit?: number;
}): CredentialRequest[] {
  const db = getDb();
  cleanupExpiredRecords(db);

  const safeLimit = Math.max(1, Math.min(100, Math.round(limit)));
  const conditions = ["user_id = ?"];
  const params: Array<string | number> = [userId];

  if (taskRunId) {
    conditions.push("task_run_id = ?");
    params.push(taskRunId);
  }

  if (status) {
    conditions.push("status = ?");
    params.push(status);
  }

  params.push(safeLimit);
  const rows = db
    .prepare(
      `SELECT * FROM credential_requests
       WHERE ${conditions.join(" AND ")}
       ORDER BY created_at DESC
       LIMIT ?`,
    )
    .all(...params) as CredentialRequestRow[];

  return rows.map(rowToCredentialRequest);
}

export function resolveCredentialRequest({
  id,
  userId,
  status,
}: {
  id: string;
  userId: string;
  status: "approved" | "denied" | "used";
}): CredentialRequest | null {
  const current = getCredentialRequest(id, userId);
  if (!current) return null;
  if (current.status !== "pending" && !(current.status === "approved" && status === "used")) {
    return current;
  }

  const db = getDb();
  const resolvedAt = Date.now();
  db.prepare(
    `UPDATE credential_requests
     SET status = ?, resolved_at = ?
     WHERE id = ? AND user_id = ?`,
  ).run(status, resolvedAt, id, userId);

  return getCredentialRequest(id, userId);
}

export function expireCredentialRequest(id: string, userId: string): CredentialRequest | null {
  const db = getDb();
  const resolvedAt = Date.now();
  db.prepare(
    `UPDATE credential_requests
     SET status = 'expired', resolved_at = ?
     WHERE id = ? AND user_id = ? AND status = 'pending'`,
  ).run(resolvedAt, id, userId);

  return getCredentialRequest(id, userId);
}

function parseDecisionSignals(raw: string): DecisionMemorySignal[] {
  try {
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];

    return parsed
      .map((item): DecisionMemorySignal | null => {
        if (!item || typeof item !== "object") return null;
        const text = (item as { text?: unknown }).text;
        const recordedAt = (item as { recordedAt?: unknown }).recordedAt;
        if (typeof text !== "string" || !text.trim()) return null;
        if (typeof recordedAt !== "number" || !Number.isFinite(recordedAt)) return null;
        return { text: text.trim().slice(0, 500), recordedAt };
      })
      .filter((signal): signal is DecisionMemorySignal => Boolean(signal));
  } catch {
    return [];
  }
}

function buildDecisionMemory(
  recentSignals: DecisionMemorySignal[],
  updatedAt?: number,
): DecisionMemory {
  return {
    recentSignals,
    ...(updatedAt ? { updatedAt } : {}),
  };
}

function normalizeDecisionSignalText(message: string) {
  const normalized = message.replace(/\s+/g, " ").trim();
  if (!normalized) return null;
  if (normalized.length > 500) return normalized.slice(0, 500);
  return normalized;
}

export function deleteSession(id: string): void {
  const db = getDb();
  db.prepare("DELETE FROM sessions WHERE id = ?").run(id);
}

export function getUserBySessionToken(sessionToken: string): User | null {
  const db = getDb();
  const now = Date.now();
  const row = db
    .prepare(
      `SELECT users.*
       FROM sessions
       INNER JOIN users ON users.id = sessions.user_id
       WHERE sessions.id = ? AND sessions.expires_at > ?`,
    )
    .get(sessionToken, now) as UserRow | undefined;

  if (!row) {
    db.prepare("DELETE FROM sessions WHERE id = ? OR expires_at <= ?").run(sessionToken, now);
    return null;
  }

  return rowToUser(row);
}

export function createAuthChallenge({
  kind,
  challenge,
  userId = null,
  payload = {},
  ttlMs = AUTH_CHALLENGE_TTL_MS,
}: {
  kind: AuthChallengeKind;
  challenge: string;
  userId?: string | null;
  payload?: Record<string, unknown>;
  ttlMs?: number;
}): AuthChallenge {
  const db = getDb();
  const now = Date.now();
  const id = randomUUID();
  const expiresAt = now + ttlMs;

  db.prepare(
    `INSERT INTO auth_challenges (id, kind, user_id, challenge, payload, created_at, expires_at)
     VALUES (?, ?, ?, ?, ?, ?, ?)`,
  ).run(id, kind, userId, challenge, JSON.stringify(payload), now, expiresAt);

  return rowToChallenge({
    id,
    kind,
    user_id: userId,
    challenge,
    payload: JSON.stringify(payload),
    created_at: now,
    expires_at: expiresAt,
  });
}

export function consumeAuthChallenge(id: string, kind: AuthChallengeKind): AuthChallenge | null {
  const db = getDb();
  const row = db
    .prepare("SELECT * FROM auth_challenges WHERE id = ? AND kind = ?")
    .get(id, kind) as AuthChallengeRow | undefined;

  if (!row) return null;

  db.prepare("DELETE FROM auth_challenges WHERE id = ?").run(id);

  if (row.expires_at <= Date.now()) {
    return null;
  }

  return rowToChallenge(row);
}

export function listWebAuthnCredentialsForUser(userId: string): WebAuthnCredentialRecord[] {
  const db = getDb();
  const rows = db
    .prepare("SELECT * FROM webauthn_credentials WHERE user_id = ? ORDER BY created_at ASC")
    .all(userId) as WebAuthnCredentialRow[];

  return rows.map(rowToCredential);
}

export function getWebAuthnCredential(id: string): WebAuthnCredentialRecord | null {
  const db = getDb();
  const row = db
    .prepare("SELECT * FROM webauthn_credentials WHERE id = ?")
    .get(id) as WebAuthnCredentialRow | undefined;

  return row ? rowToCredential(row) : null;
}

export function saveWebAuthnCredential({
  id,
  userId,
  publicKey,
  counter,
  transports,
  deviceType,
  backedUp,
}: {
  id: string;
  userId: string;
  publicKey: Uint8Array;
  counter: number;
  transports: string[];
  deviceType: "singleDevice" | "multiDevice";
  backedUp: boolean;
}): WebAuthnCredentialRecord {
  const db = getDb();
  const now = Date.now();

  db.prepare(
    `INSERT INTO webauthn_credentials (
      id, user_id, public_key, counter, transports, device_type, backed_up, created_at, last_used_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
      user_id = excluded.user_id,
      public_key = excluded.public_key,
      counter = excluded.counter,
      transports = excluded.transports,
      device_type = excluded.device_type,
      backed_up = excluded.backed_up,
      last_used_at = excluded.last_used_at`,
  ).run(
    id,
    userId,
    Buffer.from(publicKey),
    counter,
    JSON.stringify(transports),
    deviceType,
    Number(backedUp),
    now,
    now,
  );

  const saved = getWebAuthnCredential(id);
  if (!saved) throw new Error("Failed to persist WebAuthn credential");
  return saved;
}

export function updateWebAuthnCredentialUsage({
  id,
  counter,
  deviceType,
  backedUp,
}: {
  id: string;
  counter: number;
  deviceType: "singleDevice" | "multiDevice";
  backedUp: boolean;
}): void {
  const db = getDb();
  db.prepare(
    `UPDATE webauthn_credentials
     SET counter = ?, device_type = ?, backed_up = ?, last_used_at = ?
     WHERE id = ?`,
  ).run(counter, deviceType, Number(backedUp), Date.now(), id);
}

export function listAgents(userId: string): Agent[] {
  const db = getDb();
  const rows = db
    .prepare("SELECT * FROM agents WHERE owner_user_id = ? ORDER BY updated_at DESC")
    .all(userId) as AgentRow[];
  return rows.map(rowToAgent);
}

export function getAgent(id: string, userId: string): Agent | null {
  const db = getDb();
  const row = db
    .prepare("SELECT * FROM agents WHERE id = ? AND owner_user_id = ?")
    .get(id, userId) as AgentRow | undefined;
  return row ? rowToAgent(row) : null;
}

export function createAgent(draft: AgentDraft, userId: string): Agent {
  const db = getDb();
  const now = Date.now();
  const id = randomUUID();

  db.prepare(
    `INSERT INTO agents (
      id, owner_user_id, name, emoji, description, model, system_prompt, capabilities, created_at, updated_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  ).run(
    id,
    userId,
    draft.name,
    draft.emoji,
    draft.description,
    draft.model,
    draft.systemPrompt,
    JSON.stringify(draft.capabilities),
    now,
    now,
  );

  return { id, ...draft, createdAt: now, updatedAt: now };
}

export function updateAgent(id: string, patch: Partial<AgentDraft>, userId: string): Agent | null {
  const db = getDb();
  const current = getAgent(id, userId);
  if (!current) return null;

  const next = { ...current, ...patch, updatedAt: Date.now() };
  db.prepare(
    `UPDATE agents
     SET name = ?, emoji = ?, description = ?, model = ?, system_prompt = ?, capabilities = ?, updated_at = ?
     WHERE id = ? AND owner_user_id = ?`,
  ).run(
    next.name,
    next.emoji,
    next.description,
    next.model,
    next.systemPrompt,
    JSON.stringify(next.capabilities),
    next.updatedAt,
    id,
    userId,
  );

  return next;
}

export function deleteAgent(id: string, userId: string): boolean {
  const db = getDb();
  const info = db.prepare("DELETE FROM agents WHERE id = ? AND owner_user_id = ?").run(id, userId);
  return info.changes > 0;
}

function getTaskRunRow(id: string, userId: string): TaskRunRow | null {
  const db = getDb();
  const row = db
    .prepare("SELECT * FROM task_runs WHERE id = ? AND user_id = ?")
    .get(id, userId) as TaskRunRow | undefined;
  return row ?? null;
}

export function createTaskRun({
  agentId,
  userId,
  title,
  input,
  provider,
  browserSource,
}: {
  agentId: string;
  userId: string;
  title: string;
  input: string;
  provider: "claude" | "codex";
  browserSource: "user" | "env" | "none";
}): TaskRunSnapshot {
  if (!getAgent(agentId, userId)) {
    throw new Error("agent_not_found");
  }

  const db = getDb();
  const id = randomUUID();
  const startedAt = Date.now();

  db.prepare(
    `INSERT INTO task_runs (
      id, user_id, agent_id, title, input, status, provider, browser_source, started_at, completed_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  ).run(id, userId, agentId, title, input, "created", provider, browserSource, startedAt, null);

  return rowToTaskRunSnapshot(
    {
      id,
      user_id: userId,
      agent_id: agentId,
      title,
      input,
      status: "created",
      provider,
      browser_source: browserSource,
      started_at: startedAt,
      completed_at: null,
    },
    [],
    [],
  );
}

export function updateTaskRunStatus({
  id,
  userId,
  status,
  completedAt = null,
}: {
  id: string;
  userId: string;
  status: TaskRunStatus;
  completedAt?: number | null;
}): TaskRunSnapshot | null {
  const current = getTaskRunRow(id, userId);
  if (!current) return null;

  const db = getDb();
  db.prepare("UPDATE task_runs SET status = ?, completed_at = ? WHERE id = ? AND user_id = ?").run(
    status,
    completedAt,
    id,
    userId,
  );

  return getTaskRunSnapshot(id, userId);
}

export function appendTaskEvent({
  taskRunId,
  userId,
  kind,
  title,
  status,
  details,
  toolCallId,
  artifactId,
  startedAt,
  completedAt,
}: {
  taskRunId: string;
  userId: string;
  kind: TaskEventKind;
  title: string;
  status?: TaskRunStatus;
  details?: Record<string, unknown>;
  toolCallId?: string;
  artifactId?: string;
  startedAt?: number;
  completedAt?: number;
}): TaskEvent | null {
  if (!getTaskRunRow(taskRunId, userId)) return null;

  const db = getDb();
  const id = randomUUID();
  const createdAt = Date.now();
  const detailsJson = details && Object.keys(details).length > 0 ? JSON.stringify(details) : null;

  db.prepare(
    `INSERT INTO task_events (
      id, task_run_id, kind, title, status, details, tool_call_id, artifact_id, started_at, completed_at, created_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  ).run(
    id,
    taskRunId,
    kind,
    title,
    status ?? null,
    detailsJson,
    toolCallId ?? null,
    artifactId ?? null,
    startedAt ?? null,
    completedAt ?? null,
    createdAt,
  );

  return rowToTaskEvent({
    id,
    task_run_id: taskRunId,
    kind,
    title,
    status: status ?? null,
    details: detailsJson,
    tool_call_id: toolCallId ?? null,
    artifact_id: artifactId ?? null,
    started_at: startedAt ?? null,
    completed_at: completedAt ?? null,
    created_at: createdAt,
  });
}

export function createTaskArtifact({
  taskRunId,
  userId,
  kind,
  label,
  mimeType,
  byteSize,
  storagePath,
}: {
  taskRunId: string;
  userId: string;
  kind: TaskArtifactKind;
  label: string;
  mimeType: string;
  byteSize: number;
  storagePath: string;
}): TaskArtifact | null {
  if (!getTaskRunRow(taskRunId, userId)) return null;

  const db = getDb();
  const id = randomUUID();
  const createdAt = Date.now();

  db.prepare(
    `INSERT INTO task_artifacts (
      id, task_run_id, kind, label, mime_type, byte_size, storage_path, created_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
  ).run(id, taskRunId, kind, label, mimeType, byteSize, storagePath, createdAt);

  return rowToTaskArtifact({
    id,
    task_run_id: taskRunId,
    kind,
    label,
    mime_type: mimeType,
    byte_size: byteSize,
    storage_path: storagePath,
    created_at: createdAt,
  });
}

export function getTaskArtifact(
  taskRunId: string,
  artifactId: string,
  userId: string,
): (TaskArtifact & { storagePath: string }) | null {
  const db = getDb();
  const row = db
    .prepare(
      `SELECT task_artifacts.*
       FROM task_artifacts
       INNER JOIN task_runs ON task_runs.id = task_artifacts.task_run_id
       WHERE task_artifacts.id = ? AND task_artifacts.task_run_id = ? AND task_runs.user_id = ?`,
    )
    .get(artifactId, taskRunId, userId) as TaskArtifactRow | undefined;

  return row ? { ...rowToTaskArtifact(row), storagePath: row.storage_path } : null;
}

export function getTaskRunSnapshot(id: string, userId: string): TaskRunSnapshot | null {
  const row = getTaskRunRow(id, userId);
  if (!row) return null;

  const db = getDb();
  const events = (
    db
      .prepare("SELECT * FROM task_events WHERE task_run_id = ? ORDER BY created_at ASC")
      .all(id) as TaskEventRow[]
  ).map(rowToTaskEvent);
  const artifacts = (
    db
      .prepare("SELECT * FROM task_artifacts WHERE task_run_id = ? ORDER BY created_at ASC")
      .all(id) as TaskArtifactRow[]
  ).map(rowToTaskArtifact);

  return rowToTaskRunSnapshot(row, events, artifacts);
}

export function listMessages(agentId: string, userId: string): ChatMessage[] {
  const db = getDb();
  const rows = db
    .prepare(
      `SELECT chat_messages.*
       FROM chat_messages
       INNER JOIN agents ON agents.id = chat_messages.agent_id
       WHERE chat_messages.agent_id = ? AND agents.owner_user_id = ?
       ORDER BY chat_messages.created_at ASC, chat_messages.rowid ASC`,
    )
    .all(agentId, userId) as ChatMessageRow[];

  return rows.map((row) => {
    const metadata = parseMessageMetadata(row);
    const taskRun = metadata.taskRunId ? getTaskRunSnapshot(metadata.taskRunId, userId) : null;

    return {
      id: row.id,
      agentId: row.agent_id,
      role: row.role,
      content: row.content,
      ...(metadata.toolTrace ? { toolTrace: metadata.toolTrace } : {}),
      ...(taskRun ? { taskRun } : {}),
      createdAt: row.created_at,
    };
  });
}

export function appendMessage(
  agentId: string,
  userId: string,
  role: "user" | "assistant",
  content: string,
  metadata?: { toolTrace?: ToolTraceEntry[]; taskRunId?: string },
): ChatMessage {
  if (!getAgent(agentId, userId)) {
    throw new Error("agent_not_found");
  }

  const db = getDb();
  const id = randomUUID();
  const createdAt = Date.now();
  const metadataJson = buildMessageMetadataJson(metadata);

  db.prepare(
    `INSERT INTO chat_messages (id, agent_id, role, content, metadata, created_at)
     VALUES (?, ?, ?, ?, ?, ?)`,
  ).run(id, agentId, role, content, metadataJson, createdAt);

  const taskRun = metadata?.taskRunId ? getTaskRunSnapshot(metadata.taskRunId, userId) : null;
  return {
    id,
    agentId,
    role,
    content,
    ...(metadata?.toolTrace && metadata.toolTrace.length > 0 ? { toolTrace: metadata.toolTrace } : {}),
    ...(taskRun ? { taskRun } : {}),
    createdAt,
  };
}

export function updateMessage(
  agentId: string,
  userId: string,
  messageId: string,
  role: "user" | "assistant",
  content: string,
  metadata?: { toolTrace?: ToolTraceEntry[]; taskRunId?: string },
): boolean {
  const db = getDb();
  const metadataJson = buildMessageMetadataJson(metadata);
  const info = db.prepare(
    `UPDATE chat_messages
     SET content = ?, metadata = ?
     WHERE id = ?
       AND agent_id = ?
       AND role = ?
       AND EXISTS (
         SELECT 1 FROM agents
         WHERE agents.id = chat_messages.agent_id
           AND agents.owner_user_id = ?
       )`,
  ).run(content, metadataJson, messageId, agentId, role, userId);

  return info.changes > 0;
}

export function clearMessages(agentId: string, userId: string): void {
  if (!getAgent(agentId, userId)) {
    return;
  }

  const db = getDb();
  db.prepare("DELETE FROM chat_messages WHERE agent_id = ?").run(agentId);
  db.prepare("DELETE FROM task_runs WHERE agent_id = ? AND user_id = ?").run(agentId, userId);
}

export function truncateMessagesFrom(
  agentId: string,
  userId: string,
  messageId: string,
): boolean {
  if (!getAgent(agentId, userId)) return false;

  const db = getDb();
  const anchor = db
    .prepare(
      "SELECT created_at, rowid FROM chat_messages WHERE id = ? AND agent_id = ?",
    )
    .get(messageId, agentId) as { created_at: number; rowid: number } | undefined;

  if (!anchor) return false;

  const info = db
    .prepare(
      `DELETE FROM chat_messages
       WHERE agent_id = ?
         AND (created_at > ? OR (created_at = ? AND rowid >= ?))`,
    )
    .run(agentId, anchor.created_at, anchor.created_at, anchor.rowid);

  return info.changes > 0;
}
