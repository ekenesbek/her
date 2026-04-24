import { NextRequest } from "next/server";
import { logoutJson } from "@/server/auth";

export async function POST(req: NextRequest) {
  return logoutJson(req);
}
