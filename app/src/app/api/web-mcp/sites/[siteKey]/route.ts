import { NextRequest } from "next/server";
import { getUserFromRequest, unauthorizedJson } from "@/server/auth";
import { getWebSiteDetail } from "@/server/web-mcp/storage";

export const runtime = "nodejs";

export async function GET(req: NextRequest, ctx: { params: Promise<{ siteKey: string }> }) {
  const user = getUserFromRequest(req);
  if (!user) return unauthorizedJson();

  const { siteKey } = await ctx.params;
  const detail = getWebSiteDetail(user.id, siteKey);
  if (!detail) {
    return Response.json({ error: "site_not_found" }, { status: 404 });
  }

  return Response.json(detail);
}
