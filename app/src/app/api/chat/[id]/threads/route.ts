import { NextRequest } from "next/server";
import { getUserFromRequest, unauthorizedJson } from "@/server/auth";
import { createChatThread, getAgent, listChatThreads } from "@/server/db";

export const runtime = "nodejs";

type Ctx = { params: Promise<{ id: string }> };

export async function GET(_req: NextRequest, ctx: Ctx) {
  const user = getUserFromRequest(_req);
  if (!user) return unauthorizedJson();

  const { id } = await ctx.params;
  if (!getAgent(id, user.id)) {
    return Response.json({ error: "agent_not_found" }, { status: 404 });
  }

  return Response.json(listChatThreads(id, user.id));
}

export async function POST(req: NextRequest, ctx: Ctx) {
  const user = getUserFromRequest(req);
  if (!user) return unauthorizedJson();

  const { id } = await ctx.params;
  if (!getAgent(id, user.id)) {
    return Response.json({ error: "agent_not_found" }, { status: 404 });
  }

  return Response.json(createChatThread(id, user.id), { status: 201 });
}
