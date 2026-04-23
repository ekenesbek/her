import { NextRequest } from "next/server";
import { getUserFromRequest, unauthorizedJson } from "@/lib/auth";
import { deleteAgent, getAgent, updateAgent } from "@/lib/db";
import { agentPatchSchema } from "@/lib/validation";

type Ctx = { params: Promise<{ id: string }> };

export async function GET(req: NextRequest, ctx: Ctx) {
  const user = getUserFromRequest(req);
  if (!user) return unauthorizedJson();

  const { id } = await ctx.params;
  const a = getAgent(id, user.id);
  if (!a) return Response.json({ error: "not_found" }, { status: 404 });
  return Response.json(a);
}

export async function PATCH(req: NextRequest, ctx: Ctx) {
  const user = getUserFromRequest(req);
  if (!user) return unauthorizedJson();

  const { id } = await ctx.params;
  const body = await req.json();
  const parsed = agentPatchSchema.safeParse(body);
  if (!parsed.success) {
    return Response.json({ error: "invalid", issues: parsed.error.issues }, { status: 400 });
  }
  const updated = updateAgent(id, parsed.data, user.id);
  if (!updated) return Response.json({ error: "not_found" }, { status: 404 });
  return Response.json(updated);
}

export async function DELETE(req: NextRequest, ctx: Ctx) {
  const user = getUserFromRequest(req);
  if (!user) return unauthorizedJson();

  const { id } = await ctx.params;
  const ok = deleteAgent(id, user.id);
  if (!ok) return Response.json({ error: "not_found" }, { status: 404 });
  return new Response(null, { status: 204 });
}
