import { NextRequest } from "next/server";
import { getUserFromRequest, unauthorizedJson } from "@/lib/auth";
import { recordWebPageSnapshot } from "@/lib/web-mcp/storage";
import { webPageSnapshotSchema } from "@/lib/validation";

export const runtime = "nodejs";

export async function POST(req: NextRequest, ctx: { params: Promise<{ siteKey: string }> }) {
  const user = getUserFromRequest(req);
  if (!user) return unauthorizedJson();

  const body = await req.json();
  const parsed = webPageSnapshotSchema.safeParse(body);
  if (!parsed.success) {
    return Response.json({ error: "invalid", issues: parsed.error.issues }, { status: 400 });
  }

  try {
    const { siteKey } = await ctx.params;
    const snapshot = recordWebPageSnapshot(user.id, siteKey, {
      ...parsed.data,
      links: parsed.data.links?.map((link) => ({
        ...link,
        rel: link.rel ?? null,
      })),
    });
    return Response.json(snapshot, { status: 201 });
  } catch (error) {
    if (error instanceof Error && error.message === "site_not_found") {
      return Response.json({ error: "site_not_found" }, { status: 404 });
    }
    throw error;
  }
}
