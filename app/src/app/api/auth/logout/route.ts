import { NextRequest } from "next/server";
import { logoutJson } from "@/lib/auth";

export async function POST(req: NextRequest) {
  return logoutJson(req);
}
