import { NextRequest } from "next/server";
import { getUserFromRequest, unauthorizedJson } from "@/server/auth";
import { getCredentialRequest, resolveCredentialRequest } from "@/server/db";
import { credentialRequestDecisionSchema } from "@/shared/validation";

export const runtime = "nodejs";

type Ctx = { params: Promise<{ requestId: string }> };

export async function GET(req: NextRequest, ctx: Ctx) {
  const user = getUserFromRequest(req);
  if (!user) return unauthorizedJson();

  const { requestId } = await ctx.params;
  const request = getCredentialRequest(requestId, user.id);
  if (!request) return Response.json({ error: "not_found" }, { status: 404 });

  return Response.json({ request });
}

export async function PATCH(req: NextRequest, ctx: Ctx) {
  const user = getUserFromRequest(req);
  if (!user) return unauthorizedJson();

  const body = await req.json();
  const parsed = credentialRequestDecisionSchema.safeParse(body);
  if (!parsed.success) {
    return Response.json({ error: "invalid", issues: parsed.error.issues }, { status: 400 });
  }

  const { requestId } = await ctx.params;
  const status = parsed.data.decision === "approve" ? "approved" : "denied";
  const request = resolveCredentialRequest({ id: requestId, userId: user.id, status });
  if (!request) return Response.json({ error: "not_found" }, { status: 404 });

  return Response.json({ request });
}
