import { NextRequest } from "next/server";
import { z } from "zod";
import { getUserFromRequest, unauthorizedJson } from "@/server/auth";
import {
  appendSiteKnowledge,
  listServices,
  observeVisit,
} from "@/server/service-registry";

export async function GET(req: NextRequest) {
  const user = getUserFromRequest(req);
  if (!user) return unauthorizedJson();

  return Response.json({ services: listServices(user.id) });
}

const observeSchema = z.object({
  origin: z.string().trim().url(),
  loggedIn: z.boolean().optional(),
  observation: z.string().trim().max(10_000).optional(),
});

export async function POST(req: NextRequest) {
  const user = getUserFromRequest(req);
  if (!user) return unauthorizedJson();

  const body = await req.json().catch(() => null);
  const parsed = observeSchema.safeParse(body);
  if (!parsed.success) {
    return Response.json({ error: "invalid", issues: parsed.error.issues }, { status: 400 });
  }

  const origin = new URL(parsed.data.origin).origin;
  const service = observeVisit({
    userId: user.id,
    origin,
    loggedIn: parsed.data.loggedIn ?? false,
  });

  if (parsed.data.observation) {
    appendSiteKnowledge({
      userId: user.id,
      origin,
      kind: service.hasMcp ? "mcp_export" : "recording",
      contentMd: parsed.data.observation,
      source: "chrome-mcp",
    });
  }

  return Response.json({ service });
}
