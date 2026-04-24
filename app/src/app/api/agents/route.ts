import { NextRequest } from "next/server";
import { getUserFromRequest, unauthorizedJson } from "@/server/auth";
import { createAgent, listAgents } from "@/server/db";
import { agentDraftSchema } from "@/shared/validation";

export async function GET(req: NextRequest) {
  const user = getUserFromRequest(req);
  if (!user) return unauthorizedJson();

  return Response.json(listAgents(user.id));
}

export async function POST(req: NextRequest) {
  const user = getUserFromRequest(req);
  if (!user) return unauthorizedJson();

  const body = await req.json();
  const parsed = agentDraftSchema.safeParse(body);
  if (!parsed.success) {
    return Response.json({ error: "invalid", issues: parsed.error.issues }, { status: 400 });
  }
  const agent = createAgent(parsed.data, user.id);
  return Response.json(agent, { status: 201 });
}
