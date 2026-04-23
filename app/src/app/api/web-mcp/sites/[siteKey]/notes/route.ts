import { NextRequest } from "next/server";
import { getUserFromRequest, unauthorizedJson } from "@/lib/auth";
import { appendWebSiteNote } from "@/lib/web-mcp/storage";
import { webNoteSchema } from "@/lib/validation";

export const runtime = "nodejs";

export async function POST(req: NextRequest, ctx: { params: Promise<{ siteKey: string }> }) {
  const user = getUserFromRequest(req);
  if (!user) return unauthorizedJson();

  const body = await req.json();
  const parsed = webNoteSchema.safeParse(body);
  if (!parsed.success) {
    return Response.json({ error: "invalid", issues: parsed.error.issues }, { status: 400 });
  }

  try {
    const { siteKey } = await ctx.params;
    const note = appendWebSiteNote(user.id, siteKey, parsed.data);
    return Response.json(note, { status: 201 });
  } catch (error) {
    if (error instanceof Error && error.message === "site_not_found") {
      return Response.json({ error: "site_not_found" }, { status: 404 });
    }
    throw error;
  }
}
