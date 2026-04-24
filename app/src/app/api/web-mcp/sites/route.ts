import { NextRequest } from "next/server";
import { getUserFromRequest, unauthorizedJson } from "@/server/auth";
import { upsertWebSiteWorkspace, listWebSites } from "@/server/web-mcp/storage";
import { webSiteCreateSchema } from "@/shared/validation";

export const runtime = "nodejs";

export async function GET(req: NextRequest) {
  const user = getUserFromRequest(req);
  if (!user) return unauthorizedJson();

  return Response.json(listWebSites(user.id));
}

export async function POST(req: NextRequest) {
  const user = getUserFromRequest(req);
  if (!user) return unauthorizedJson();

  const body = await req.json();
  const parsed = webSiteCreateSchema.safeParse(body);
  if (!parsed.success) {
    return Response.json({ error: "invalid", issues: parsed.error.issues }, { status: 400 });
  }

  const result = upsertWebSiteWorkspace(user.id, parsed.data);
  return Response.json(result.site, { status: result.created ? 201 : 200 });
}
