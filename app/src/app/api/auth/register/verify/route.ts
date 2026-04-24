import type { RegistrationResponseJSON } from "@simplewebauthn/server";
import { verifyRegistrationResponse } from "@simplewebauthn/server";
import { NextRequest } from "next/server";
import { createSessionJsonResponse, getPasskeyConfigFromRequest } from "@/server/auth";
import {
  consumeAuthChallenge,
  createUser,
  getUserByEmail,
  getUserById,
  saveWebAuthnCredential,
} from "@/server/db";
import { passkeyFinishSchema } from "@/shared/validation";

export const runtime = "nodejs";

export async function POST(req: NextRequest) {
  const body = await req.json();
  const parsed = passkeyFinishSchema.safeParse(body);
  if (!parsed.success) {
    return Response.json({ error: "invalid", issues: parsed.error.issues }, { status: 400 });
  }

  const challenge = consumeAuthChallenge(parsed.data.challengeId, "registration");
  if (!challenge) {
    return Response.json({ error: "challenge_expired" }, { status: 400 });
  }

  const response = parsed.data.response as unknown as RegistrationResponseJSON;
  const payload = challenge.payload;
  const email = typeof payload.email === "string" ? payload.email : null;
  const name = typeof payload.name === "string" ? payload.name : null;
  const pendingUserId = typeof payload.pendingUserId === "string" ? payload.pendingUserId : null;

  if (!email || !name || !pendingUserId) {
    return Response.json({ error: "challenge_invalid" }, { status: 400 });
  }

  const { origin, rpID } = getPasskeyConfigFromRequest(req);
  const verification = await verifyRegistrationResponse({
    response,
    expectedChallenge: challenge.challenge,
    expectedOrigin: origin,
    expectedRPID: rpID,
    requireUserVerification: true,
  });

  if (!verification.verified || !verification.registrationInfo) {
    return Response.json({ error: "verification_failed" }, { status: 400 });
  }

  let user = challenge.userId ? getUserById(challenge.userId) : null;
  if (!user) {
    const existingUser = getUserByEmail(email);
    if (existingUser) {
      return Response.json({ error: "account_exists" }, { status: 409 });
    }
    user = createUser({ id: pendingUserId, email, name });
  }

  const transports = response.response.transports;
  saveWebAuthnCredential({
    id: verification.registrationInfo.credential.id,
    userId: user.id,
    publicKey: verification.registrationInfo.credential.publicKey,
    counter: verification.registrationInfo.credential.counter,
    transports: Array.isArray(transports) ? transports : [],
    deviceType: verification.registrationInfo.credentialDeviceType,
    backedUp: verification.registrationInfo.credentialBackedUp,
  });

  return createSessionJsonResponse(user.id, { ok: true, user });
}
