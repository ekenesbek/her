import { NextRequest } from "next/server";
import { getUserFromRequest, unauthorizedJson } from "@/server/auth";
import { normalizeChromeMcpUrl, resolveBrowserConnection } from "@/server/browser";
import { getBrowserSettings, upsertBrowserSettings } from "@/server/db";
import { browserSettingsPatchSchema } from "@/shared/validation";

export async function GET(req: NextRequest) {
  const user = getUserFromRequest(req);
  if (!user) return unauthorizedJson();

  const settings = getBrowserSettings(user.id);
  return Response.json({
    settings,
    connection: resolveBrowserConnection(settings),
  });
}

export async function PATCH(req: NextRequest) {
  const user = getUserFromRequest(req);
  if (!user) return unauthorizedJson();

  const body = await req.json();
  const parsed = browserSettingsPatchSchema.safeParse(body);
  if (!parsed.success) {
    return Response.json({ error: "invalid", issues: parsed.error.issues }, { status: 400 });
  }

  const settings = upsertBrowserSettings({
    userId: user.id,
    chromeMcpUrl: normalizeChromeMcpUrl(parsed.data.chromeMcpUrl),
  });

  return Response.json({
    settings,
    connection: resolveBrowserConnection(settings),
  });
}
