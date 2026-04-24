import { generateRegistrationOptions } from "@simplewebauthn/server";
import { NextRequest } from "next/server";
import { randomUUID } from "node:crypto";
import { getPasskeyConfigFromRequest, getUserFromRequest } from "@/server/auth";
import { createAuthChallenge, getUserByEmail, listWebAuthnCredentialsForUser } from "@/server/db";
import { toAuthenticatorTransports } from "@/server/passkeys";
import { passkeyRegistrationStartSchema } from "@/shared/validation";

export const runtime = "nodejs";

export async function POST(req: NextRequest) {
  const body = await req.json();
  const parsed = passkeyRegistrationStartSchema.safeParse(body);
  if (!parsed.success) {
    return Response.json({ error: "invalid", issues: parsed.error.issues }, { status: 400 });
  }

  const sessionUser = getUserFromRequest(req);
  const existingUser = getUserByEmail(parsed.data.email);

  if (existingUser && sessionUser?.id !== existingUser.id) {
    return Response.json({ error: "account_exists" }, { status: 409 });
  }

  const { origin, rpID, rpName } = getPasskeyConfigFromRequest(req);
  const userId = existingUser?.id ?? randomUUID();
  const userName = parsed.data.name?.trim() || parsed.data.email;
  const existingCredentials = existingUser ? listWebAuthnCredentialsForUser(existingUser.id) : [];

  const options = await generateRegistrationOptions({
    rpName,
    rpID,
    userID: new TextEncoder().encode(userId),
    userName: parsed.data.email,
    userDisplayName: userName,
    excludeCredentials: existingCredentials.map((credential) => ({
      id: credential.id,
      transports: toAuthenticatorTransports(credential.transports),
    })),
    authenticatorSelection: {
      residentKey: "required",
      userVerification: "required",
    },
    attestationType: "none",
    preferredAuthenticatorType: "localDevice",
  });

  const challenge = createAuthChallenge({
    kind: "registration",
    challenge: options.challenge,
    userId: existingUser?.id ?? null,
    payload: {
      pendingUserId: userId,
      email: parsed.data.email,
      name: userName,
      origin,
    },
  });

  return Response.json({ challengeId: challenge.id, options });
}
