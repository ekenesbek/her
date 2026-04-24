import { NextRequest } from "next/server";
import fs from "node:fs/promises";
import { getUserFromRequest, unauthorizedJson } from "@/server/auth";
import { getTaskArtifact } from "@/server/db";
import { resolveTaskArtifactPath } from "@/server/task-artifacts";

export const runtime = "nodejs";

type Ctx = { params: Promise<{ runId: string; artifactId: string }> };

export async function GET(req: NextRequest, ctx: Ctx) {
  const user = getUserFromRequest(req);
  if (!user) return unauthorizedJson();

  const { runId, artifactId } = await ctx.params;
  const artifact = getTaskArtifact(runId, artifactId, user.id);
  if (!artifact) return Response.json({ error: "artifact_not_found" }, { status: 404 });

  try {
    const file = await fs.readFile(resolveTaskArtifactPath(artifact.storagePath));
    return new Response(new Uint8Array(file), {
      headers: {
        "Content-Type": artifact.mimeType,
        "Cache-Control": "private, max-age=3600",
      },
    });
  } catch {
    return Response.json({ error: "artifact_file_not_found" }, { status: 404 });
  }
}
