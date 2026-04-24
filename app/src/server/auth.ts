import { cookies, headers } from "next/headers";
import { redirect } from "next/navigation";
import { NextRequest, NextResponse } from "next/server";
import { createSession, deleteSession, getUserBySessionToken } from "./db";
import type { User } from "@/shared/types";

const SESSION_COOKIE_NAME = "meta_session";
const SESSION_TTL_MS = 30 * 24 * 60 * 60 * 1000;

function isSecureCookie() {
  return process.env.NODE_ENV === "production";
}

function resolveOrigin(headerStore: Headers): string {
  const configuredOrigin = process.env.PASSKEY_ORIGIN?.trim();
  if (configuredOrigin) return configuredOrigin;

  const host = headerStore.get("x-forwarded-host") ?? headerStore.get("host");
  if (!host) throw new Error("Missing host header");

  const protocol =
    headerStore.get("x-forwarded-proto") ?? (process.env.NODE_ENV === "development" ? "http" : "https");

  return `${protocol}://${host}`;
}

export function getPasskeyConfigFromHeaders(headerStore: Headers) {
  const origin = resolveOrigin(headerStore);
  return {
    origin,
    rpID: process.env.PASSKEY_RP_ID?.trim() || new URL(origin).hostname,
    rpName: process.env.PASSKEY_RP_NAME?.trim() || "meta",
  };
}

export async function getPasskeyConfig() {
  const headerStore = await headers();
  return getPasskeyConfigFromHeaders(headerStore);
}

export function getPasskeyConfigFromRequest(req: NextRequest) {
  return getPasskeyConfigFromHeaders(req.headers);
}

export async function getCurrentUser(): Promise<User | null> {
  const cookieStore = await cookies();
  const sessionToken = cookieStore.get(SESSION_COOKIE_NAME)?.value;
  if (!sessionToken) return null;
  return getUserBySessionToken(sessionToken);
}

export async function requireUser(): Promise<User> {
  const user = await getCurrentUser();
  if (!user) redirect("/login");
  return user;
}

export function getUserFromRequest(req: NextRequest): User | null {
  const sessionToken = req.cookies.get(SESSION_COOKIE_NAME)?.value;
  if (!sessionToken) return null;
  return getUserBySessionToken(sessionToken);
}

export function unauthorizedJson() {
  return Response.json({ error: "unauthorized" }, { status: 401 });
}

function applySessionCookie(response: NextResponse, sessionToken: string, expiresAt: number) {
  response.cookies.set({
    name: SESSION_COOKIE_NAME,
    value: sessionToken,
    httpOnly: true,
    sameSite: "lax",
    secure: isSecureCookie(),
    path: "/",
    expires: new Date(expiresAt),
  });
}

export function createSessionJsonResponse(userId: string, body: unknown) {
  const session = createSession(userId, SESSION_TTL_MS);
  const response = NextResponse.json(body);
  applySessionCookie(response, session.id, session.expiresAt);
  return response;
}

export function logoutJson(req: NextRequest) {
  const sessionToken = req.cookies.get(SESSION_COOKIE_NAME)?.value;
  if (sessionToken) {
    deleteSession(sessionToken);
  }

  const response = NextResponse.json({ ok: true });
  response.cookies.set({
    name: SESSION_COOKIE_NAME,
    value: "",
    httpOnly: true,
    sameSite: "lax",
    secure: isSecureCookie(),
    path: "/",
    expires: new Date(0),
  });
  return response;
}
