from __future__ import annotations

from datetime import UTC, datetime, timedelta

import jwt
from jwt import PyJWKClient

APPLE_ISSUER = "https://appleid.apple.com"
APPLE_JWKS_URL = "https://appleid.apple.com/auth/keys"
GOOGLE_ISSUERS = ("accounts.google.com", "https://accounts.google.com")
GOOGLE_JWKS_URL = "https://www.googleapis.com/oauth2/v3/certs"

SESSION_ALG = "HS256"
SESSION_EXPIRES_IN = timedelta(days=180)

_apple_jwks = PyJWKClient(APPLE_JWKS_URL, cache_keys=True)
_google_jwks = PyJWKClient(GOOGLE_JWKS_URL, cache_keys=True)


class AuthError(Exception):
    pass


def verify_apple_id_token(token: str, audience: str) -> dict:
    try:
        signing_key = _apple_jwks.get_signing_key_from_jwt(token)
        return jwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256"],
            audience=audience,
            issuer=APPLE_ISSUER,
            options={"require": ["sub", "aud", "iss", "exp"]},
        )
    except jwt.PyJWTError as exc:
        raise AuthError(f"Apple identity token invalid: {exc}") from exc


def verify_google_id_token(token: str, audiences: list[str]) -> dict:
    try:
        signing_key = _google_jwks.get_signing_key_from_jwt(token)
        payload = jwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256"],
            audience=audiences,
            options={"require": ["sub", "aud", "iss", "exp"]},
        )
    except jwt.PyJWTError as exc:
        raise AuthError(f"Google identity token invalid: {exc}") from exc

    if payload.get("iss") not in GOOGLE_ISSUERS:
        raise AuthError("Google identity token issuer mismatch.")
    return payload


def create_session_token(user_id: str, secret: str) -> tuple[str, datetime]:
    now = datetime.now(UTC)
    expires_at = now + SESSION_EXPIRES_IN
    payload = {
        "sub": user_id,
        "iat": int(now.timestamp()),
        "exp": int(expires_at.timestamp()),
    }
    token = jwt.encode(payload, secret, algorithm=SESSION_ALG)
    return token, expires_at


def decode_session_token(token: str, secret: str) -> dict:
    try:
        return jwt.decode(token, secret, algorithms=[SESSION_ALG])
    except jwt.PyJWTError as exc:
        raise AuthError(f"Session token invalid: {exc}") from exc
