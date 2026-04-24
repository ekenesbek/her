import { randomUUID } from "node:crypto";
import { getDb } from "./db";

export type PolicyDecision = "allow" | "prompt" | "deny";

export type PolicyKey = {
  scope: string;
  action: string;
};

export type Policy = PolicyKey & {
  id: string;
  userId: string;
  decision: PolicyDecision;
  rationale: string | null;
  updatedAt: number;
};

export const DEFAULT_POLICIES: Array<{
  scope: string;
  action: string;
  decision: PolicyDecision;
  rationale: string;
}> = [
  { scope: "*", action: "observe_visit", decision: "allow", rationale: "Passive service discovery" },
  { scope: "*", action: "read_public_content", decision: "allow", rationale: "Reading pages user already opens" },
  { scope: "*", action: "autoprovision_mcp", decision: "allow", rationale: "Agent may install MCPs for services user already uses" },
  { scope: "*", action: "fill_login", decision: "allow", rationale: "Agent fills saved credentials silently" },
  { scope: "*", action: "create_login", decision: "allow", rationale: "Agent creates accounts with generated passwords" },
  { scope: "kind:finance", action: "fill_login", decision: "prompt", rationale: "Finance: confirm before any login fill" },
  { scope: "kind:finance", action: "transact", decision: "deny", rationale: "Never auto-initiate money movement" },
  { scope: "*", action: "send_message", decision: "prompt", rationale: "Outbound messages (mail/chat) always confirm" },
  { scope: "*", action: "delete_data", decision: "prompt", rationale: "Destructive ops confirm" },
];

export function ensureDefaultPolicies(userId: string) {
  const db = getDb();
  const now = Date.now();
  const insert = db.prepare(
    `INSERT OR IGNORE INTO user_policies
       (id, user_id, scope, action, decision, rationale, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
  );
  const txn = db.transaction(() => {
    for (const p of DEFAULT_POLICIES) {
      insert.run(randomUUID(), userId, p.scope, p.action, p.decision, p.rationale, now, now);
    }
  });
  txn();
}

export function listPolicies(userId: string): Policy[] {
  const rows = getDb()
    .prepare(
      "SELECT id, user_id, scope, action, decision, rationale, updated_at FROM user_policies WHERE user_id = ? ORDER BY scope, action",
    )
    .all(userId) as Array<{
    id: string;
    user_id: string;
    scope: string;
    action: string;
    decision: PolicyDecision;
    rationale: string | null;
    updated_at: number;
  }>;
  return rows.map((r) => ({
    id: r.id,
    userId: r.user_id,
    scope: r.scope,
    action: r.action,
    decision: r.decision,
    rationale: r.rationale,
    updatedAt: r.updated_at,
  }));
}

export function setPolicy(params: {
  userId: string;
  scope: string;
  action: string;
  decision: PolicyDecision;
  rationale?: string;
}) {
  const db = getDb();
  const now = Date.now();
  const id = randomUUID();
  db.prepare(
    `INSERT INTO user_policies (id, user_id, scope, action, decision, rationale, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(user_id, scope, action)
       DO UPDATE SET decision = excluded.decision, rationale = excluded.rationale, updated_at = excluded.updated_at`,
  ).run(id, params.userId, params.scope, params.action, params.decision, params.rationale ?? null, now, now);
}

export function resolveDecision(params: {
  userId: string;
  action: string;
  serviceKind?: string;
  origin?: string;
}): PolicyDecision {
  const db = getDb();
  const scopes = [
    params.origin ? `origin:${params.origin}` : null,
    params.serviceKind ? `kind:${params.serviceKind}` : null,
    "*",
  ].filter((x): x is string => Boolean(x));

  for (const scope of scopes) {
    const row = db
      .prepare(
        "SELECT decision FROM user_policies WHERE user_id = ? AND scope = ? AND action = ?",
      )
      .get(params.userId, scope, params.action) as { decision: PolicyDecision } | undefined;
    if (row) return row.decision;
  }
  return "prompt";
}
