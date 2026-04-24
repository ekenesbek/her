import { NextRequest } from "next/server";
import { z } from "zod";
import { getUserFromRequest, unauthorizedJson } from "@/server/auth";
import {
  ensureDefaultPolicies,
  listPolicies,
  setPolicy,
  type PolicyDecision,
} from "@/server/policies";

export async function GET(req: NextRequest) {
  const user = getUserFromRequest(req);
  if (!user) return unauthorizedJson();

  ensureDefaultPolicies(user.id);
  return Response.json({ policies: listPolicies(user.id) });
}

const patchSchema = z.object({
  scope: z.string().trim().min(1).max(100),
  action: z.string().trim().min(1).max(60),
  decision: z.enum(["allow", "prompt", "deny"]),
  rationale: z.string().trim().max(500).optional(),
});

export async function PATCH(req: NextRequest) {
  const user = getUserFromRequest(req);
  if (!user) return unauthorizedJson();

  const body = await req.json().catch(() => null);
  const parsed = patchSchema.safeParse(body);
  if (!parsed.success) {
    return Response.json({ error: "invalid", issues: parsed.error.issues }, { status: 400 });
  }

  setPolicy({
    userId: user.id,
    scope: parsed.data.scope,
    action: parsed.data.action,
    decision: parsed.data.decision as PolicyDecision,
    ...(parsed.data.rationale !== undefined ? { rationale: parsed.data.rationale } : {}),
  });

  return Response.json({ policies: listPolicies(user.id) });
}
