import { NextRequest } from "next/server";
import { z } from "zod";
import { getUserFromRequest, unauthorizedJson } from "@/server/auth";
import { getDb } from "@/server/db";
import { upsertKnowledgePage } from "@/server/service-registry";

export async function GET(req: NextRequest) {
  const user = getUserFromRequest(req);
  if (!user) return unauthorizedJson();

  const url = new URL(req.url);
  const type = url.searchParams.get("type");
  const db = getDb();
  const rows = type
    ? db
        .prepare(
          "SELECT id, type, title, content_md, confidence, sources, updated_at FROM knowledge_pages WHERE user_id = ? AND type = ? AND superseded_by IS NULL ORDER BY updated_at DESC LIMIT 500",
        )
        .all(user.id, type)
    : db
        .prepare(
          "SELECT id, type, title, content_md, confidence, sources, updated_at FROM knowledge_pages WHERE user_id = ? AND superseded_by IS NULL ORDER BY updated_at DESC LIMIT 500",
        )
        .all(user.id);

  return Response.json({ pages: rows });
}

const postSchema = z.object({
  type: z.string().trim().min(1).max(40),
  title: z.string().trim().min(1).max(200),
  contentMd: z.string().max(20_000).default(""),
  confidence: z.number().min(0).max(1).optional(),
  sources: z.array(z.string().trim().max(500)).max(50).optional(),
});

export async function POST(req: NextRequest) {
  const user = getUserFromRequest(req);
  if (!user) return unauthorizedJson();

  const body = await req.json().catch(() => null);
  const parsed = postSchema.safeParse(body);
  if (!parsed.success) {
    return Response.json({ error: "invalid", issues: parsed.error.issues }, { status: 400 });
  }

  const id = upsertKnowledgePage({
    userId: user.id,
    type: parsed.data.type,
    title: parsed.data.title,
    contentMd: parsed.data.contentMd,
    confidence: parsed.data.confidence,
    sources: parsed.data.sources,
  });

  return Response.json({ id });
}
