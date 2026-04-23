import type { AuthenticationResponseJSON } from "@simplewebauthn/server";
import { verifyAuthenticationResponse } from "@simplewebauthn/server";
import { NextRequest } from "next/server";
import { createSessionJsonResponse, getPasskeyConfigFromRequest } from "@/lib/auth";
import {
  consumeAuthChallenge,
  getUserById,
  getWebAuthnCredential,
  updateWebAuthnCredentialUsage,
} from "@/lib/db";
import { toAuthenticatorTransports } from "@/lib/passkeys";
import { passkeyFinishSchema } from "@/lib/validation";

export const runtime = "nodejs";

export async function POST(req: NextRequest) {
  const body = await req.json();
  const parsed = passkeyFinishSchema.safeParse(body);
  if (!parsed.success) {
    return Response.json({ error: "invalid", issues: parsed.error.issues }, { status: 400 });
  }

  const challenge = consumeAuthChallenge(parsed.data.challengeId, "authentication");
  if (!challenge) {
    return Response.json({ error: "challenge_expired" }, { status: 400 });
  }

  const response = parsed.data.response as unknown as AuthenticationResponseJSON;
  const credential = getWebAuthnCredential(response.id);
  if (!credential) {
    return Response.json({ error: "credential_not_found" }, { status: 404 });
  }

  if (challenge.userId && challenge.userId !== credential.userId) {
    return Response.json({ error: "credential_mismatch" }, { status: 403 });
  }

  const { origin, rpID } = getPasskeyConfigFromRequest(req);
  const verification = await verifyAuthenticationResponse({
    response,
    expectedChallenge: challenge.challenge,
    expectedOrigin: origin,
    expectedRPID: rpID,
    credential: {
      id: credential.id,
      publicKey: Uint8Array.from(credential.publicKey),
      counter: credential.counter,
      transports: toAuthenticatorTransports(credential.transports),
    },
    requireUserVerification: true,
  });

  if (!verification.verified) {
    return Response.json({ error: "verification_failed" }, { status: 400 });
  }

  updateWebAuthnCredentialUsage({
    id: credential.id,
    counter: verification.authenticationInfo.newCounter,
    deviceType: verification.authenticationInfo.credentialDeviceType,
    backedUp: verification.authenticationInfo.credentialBackedUp,
  });

  const user = getUserById(credential.userId);
  if (!user) {
    return Response.json({ error: "user_not_found" }, { status: 404 });
  }

  return createSessionJsonResponse(user.id, { ok: true, user });
}
