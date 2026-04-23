import type { AuthenticatorTransportFuture } from "@simplewebauthn/server";
import { generateAuthenticationOptions } from "@simplewebauthn/server";
import { NextRequest } from "next/server";
import { getPasskeyConfigFromRequest } from "@/lib/auth";
import { createAuthChallenge, getUserByEmail, listWebAuthnCredentialsForUser } from "@/lib/db";
import { toAuthenticatorTransports } from "@/lib/passkeys";
import { passkeyAuthenticationStartSchema } from "@/lib/validation";

export const runtime = "nodejs";

export async function POST(req: NextRequest) {
  const body = await req.json();
  const parsed = passkeyAuthenticationStartSchema.safeParse(body);
  if (!parsed.success) {
    return Response.json({ error: "invalid", issues: parsed.error.issues }, { status: 400 });
  }

  const { rpID } = getPasskeyConfigFromRequest(req);

  let userId: string | null = null;
  let allowCredentials:
    | Array<{
        id: string;
        transports?: AuthenticatorTransportFuture[];
      }>
    | undefined;

  if (parsed.data.email) {
    const user = getUserByEmail(parsed.data.email);
    if (!user) {
      return Response.json({ error: "account_not_found" }, { status: 404 });
    }

    const credentials = listWebAuthnCredentialsForUser(user.id);
    if (credentials.length === 0) {
      return Response.json({ error: "no_passkeys" }, { status: 404 });
    }

    userId = user.id;
    allowCredentials = credentials.map((credential) => ({
      id: credential.id,
      transports: toAuthenticatorTransports(credential.transports),
    }));
  }

  const options = await generateAuthenticationOptions({
    rpID,
    allowCredentials,
    userVerification: "required",
  });

  const challenge = createAuthChallenge({
    kind: "authentication",
    challenge: options.challenge,
    userId,
    payload: { email: parsed.data.email ?? null },
  });

  return Response.json({ challengeId: challenge.id, options });
}
