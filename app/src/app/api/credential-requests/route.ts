import { NextRequest } from "next/server";
import { getUserFromRequest, unauthorizedJson } from "@/server/auth";
import { listCredentialRequests } from "@/server/db";
import type { CredentialRequestStatus } from "@/shared/types";

export const runtime = "nodejs";

const STATUSES = new Set<CredentialRequestStatus>([
  "pending",
  "approved",
  "denied",
  "expired",
  "used",
]);

export async function GET(req: NextRequest) {
  const user = getUserFromRequest(req);
  if (!user) return unauthorizedJson();

  const { searchParams } = new URL(req.url);
  const taskRunId = searchParams.get("taskRunId") ?? undefined;
  const statusParam = searchParams.get("status");
  const status = STATUSES.has(statusParam as CredentialRequestStatus)
    ? (statusParam as CredentialRequestStatus)
    : undefined;

  return Response.json({
    requests: listCredentialRequests({ userId: user.id, taskRunId, status }),
  });
}
