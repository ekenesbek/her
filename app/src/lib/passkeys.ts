import type { AuthenticatorTransportFuture } from "@simplewebauthn/server";

const AUTHENTICATOR_TRANSPORTS = new Set<AuthenticatorTransportFuture>([
  "ble",
  "cable",
  "hybrid",
  "internal",
  "nfc",
  "smart-card",
  "usb",
]);

export function toAuthenticatorTransports(
  transports: string[] | undefined | null,
): AuthenticatorTransportFuture[] | undefined {
  if (!transports?.length) return undefined;

  const normalized = transports.filter(
    (transport): transport is AuthenticatorTransportFuture =>
      AUTHENTICATOR_TRANSPORTS.has(transport as AuthenticatorTransportFuture),
  );

  return normalized.length > 0 ? normalized : undefined;
}
