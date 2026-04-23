import Database from "better-sqlite3";
import { randomBytes, randomUUID } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import type {
  Agent,
  AgentDraft,
  AuthChallenge,
  AuthChallengeKind,
  ChatMessage,
  Session,
  User,
  WebAuthnCredentialRecord,
} from "./types";

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

function cleanupExpiredRecords(db: Database.Database) {
  const now = Date.now();
  db.prepare("DELETE FROM auth_challenges WHERE expires_at <= ?").run(now);
  db.prepare("DELETE FROM sessions WHERE expires_at <= ?").run(now);
}

function getDb(): Database.Database {
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
  `);

  ensureAgentsOwnerColumn(db);
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

export function listMessages(agentId: string, userId: string): ChatMessage[] {
  const db = getDb();
  const rows = db
    .prepare(
      `SELECT chat_messages.*
       FROM chat_messages
       INNER JOIN agents ON agents.id = chat_messages.agent_id
       WHERE chat_messages.agent_id = ? AND agents.owner_user_id = ?
       ORDER BY chat_messages.created_at ASC`,
    )
    .all(agentId, userId) as ChatMessageRow[];

  return rows.map((row) => ({
    id: row.id,
    agentId: row.agent_id,
    role: row.role,
    content: row.content,
    createdAt: row.created_at,
  }));
}

export function appendMessage(
  agentId: string,
  userId: string,
  role: "user" | "assistant",
  content: string,
): ChatMessage {
  if (!getAgent(agentId, userId)) {
    throw new Error("agent_not_found");
  }

  const db = getDb();
  const id = randomUUID();
  const createdAt = Date.now();

  db.prepare(
    `INSERT INTO chat_messages (id, agent_id, role, content, created_at)
     VALUES (?, ?, ?, ?, ?)`,
  ).run(id, agentId, role, content, createdAt);

  return { id, agentId, role, content, createdAt };
}

export function clearMessages(agentId: string, userId: string): void {
  if (!getAgent(agentId, userId)) {
    return;
  }

  const db = getDb();
  db.prepare("DELETE FROM chat_messages WHERE agent_id = ?").run(agentId);
}
