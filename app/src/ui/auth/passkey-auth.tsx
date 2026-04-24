"use client";

import {
  browserSupportsWebAuthn,
  browserSupportsWebAuthnAutofill,
  startAuthentication,
  startRegistration,
} from "@simplewebauthn/browser";
import type {
  AuthenticationResponseJSON,
  PublicKeyCredentialCreationOptionsJSON,
  PublicKeyCredentialRequestOptionsJSON,
  RegistrationResponseJSON,
} from "@simplewebauthn/server";
import { useCallback, useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { useLang, t } from "@/client/i18n";
import LangToggle from "@/ui/shell/lang-toggle";

type RegistrationStartPayload = {
  challengeId: string;
  options: PublicKeyCredentialCreationOptionsJSON;
};

type AuthenticationStartPayload = {
  challengeId: string;
  options: PublicKeyCredentialRequestOptionsJSON;
};

type BusyState = "idle" | "registering" | "signing-in";
type Mode = "signin" | "create";

function isAbortError(error: unknown) {
  if (!(error instanceof Error)) return false;
  const message = error.message.toLowerCase();
  return error.name === "AbortError" || message.includes("abort") || message.includes("cancel");
}

const ERROR_COPY: Record<string, { en: string; ru: string }> = {
  account_exists: {
    en: "An account with this email already exists. Sign in with your existing passkey.",
    ru: "Аккаунт с этим email уже существует. Войдите существующим passkey.",
  },
  account_not_found: {
    en: "No account exists for this email yet.",
    ru: "Аккаунт с этим email ещё не создан.",
  },
  no_passkeys: {
    en: "No passkeys registered for this account yet.",
    ru: "Для этого аккаунта пока нет зарегистрированных passkeys.",
  },
  verification_failed: {
    en: "Passkey verification failed. Try again.",
    ru: "Passkey не удалось подтвердить. Попробуйте ещё раз.",
  },
  challenge_expired: {
    en: "Challenge expired. Start the sign-in again.",
    ru: "Challenge устарел. Запустите вход ещё раз.",
  },
  credential_not_found: {
    en: "This passkey isn’t registered in the app.",
    ru: "Эта passkey не зарегистрирована в приложении.",
  },
  credential_mismatch: {
    en: "This passkey belongs to a different account.",
    ru: "Выбранная passkey привязана к другому аккаунту.",
  },
};

function describeError(error: unknown, lang: "en" | "ru") {
  if (!(error instanceof Error))
    return lang === "en" ? "Unknown error" : "Неизвестная ошибка";
  const entry = ERROR_COPY[error.message];
  return entry ? entry[lang] : error.message;
}

async function postJSON<T>(url: string, body: unknown): Promise<T> {
  const response = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });

  const data = (await response.json().catch(() => null)) as Record<string, unknown> | null;
  if (!response.ok) {
    const error = typeof data?.error === "string" ? data.error : `HTTP ${response.status}`;
    throw new Error(error);
  }

  return data as T;
}

function detectDeviceLabel(): string {
  if (typeof navigator === "undefined") return "this device";
  const ua = navigator.userAgent;
  if (/iPhone/i.test(ua)) return "iPhone";
  if (/iPad/i.test(ua)) return "iPad";
  if (/Macintosh|Mac OS/i.test(ua)) return "MacBook";
  if (/Windows/i.test(ua)) return "Windows PC";
  if (/Android/i.test(ua)) return "Android device";
  if (/Linux/i.test(ua)) return "Linux device";
  return "this device";
}

function detectAuthenticatorLabel(): string {
  if (typeof navigator === "undefined") return "Passkey · WebAuthn";
  const ua = navigator.userAgent;
  if (/iPhone|iPad/i.test(ua)) return "Face ID · Secure Enclave";
  if (/Macintosh|Mac OS/i.test(ua)) return "Touch ID · Secure Enclave";
  if (/Android/i.test(ua)) return "Biometrics · Google Password Manager";
  if (/Windows/i.test(ua)) return "Windows Hello";
  return "Passkey · WebAuthn";
}

export default function PasskeyAuth() {
  const router = useRouter();
  const [lang] = useLang();
  const [mode, setMode] = useState<Mode>("signin");
  const [email, setEmail] = useState("");
  const [name, setName] = useState("");
  const [busy, setBusy] = useState<BusyState>("idle");
  const [error, setError] = useState<string | null>(null);
  const [supportsPasskeys, setSupportsPasskeys] = useState<boolean | null>(null);
  const [autofillReady, setAutofillReady] = useState(false);
  const [status, setStatus] = useState<string | null>(null);

  const deviceLabel = useMemo(detectDeviceLabel, []);
  const authenticatorLabel = useMemo(detectAuthenticatorLabel, []);

  async function finishAuthentication(
    body: { email?: string },
    useBrowserAutofill = false,
  ) {
    const start = await postJSON<AuthenticationStartPayload>("/api/auth/authenticate/options", body);
    const response = await startAuthentication({
      optionsJSON: start.options,
      useBrowserAutofill,
    });

    await postJSON("/api/auth/authenticate/verify", {
      challengeId: start.challengeId,
      response,
    } satisfies {
      challengeId: string;
      response: AuthenticationResponseJSON;
    });
  }

  const goHome = useCallback(async () => {
    router.replace("/");
    router.refresh();
  }, [router]);

  useEffect(() => {
    let active = true;
    const supported = browserSupportsWebAuthn();

    void Promise.resolve().then(async () => {
      if (!active) return;
      setSupportsPasskeys(supported);
      if (!supported) return;

      try {
        const supportedAutofill = await browserSupportsWebAuthnAutofill();
        if (!active || !supportedAutofill) return;
        setAutofillReady(true);
      } catch {
        /* ignore */
      }
    });

    return () => {
      active = false;
    };
  }, []);

  useEffect(() => {
    if (!supportsPasskeys) return;

    let active = true;

    void (async () => {
      try {
        const supportedAutofill = await browserSupportsWebAuthnAutofill();
        if (!active || !supportedAutofill) return;

        await finishAuthentication({}, true);
        if (!active) return;
        await goHome();
      } catch (authError) {
        if (!active || isAbortError(authError)) return;
        console.error(authError);
      }
    })();

    return () => {
      active = false;
    };
  }, [goHome, supportsPasskeys]);

  async function handleRegister() {
    if (!email.trim()) {
      setError(
        lang === "en"
          ? "Enter an email to create an account."
          : "Укажите email для создания аккаунта.",
      );
      return;
    }

    if (!supportsPasskeys) {
      setError(t(lang, "login.notSupported"));
      return;
    }

    setBusy("registering");
    setError(null);
    setStatus(
      lang === "en"
        ? "Open the system prompt and save the passkey."
        : "Откройте системный диалог и сохраните passkey.",
    );

    try {
      const start = await postJSON<RegistrationStartPayload>("/api/auth/register/options", {
        email,
        name,
      });

      const response = await startRegistration({
        optionsJSON: start.options,
      });

      await postJSON("/api/auth/register/verify", {
        challengeId: start.challengeId,
        response,
      } satisfies {
        challengeId: string;
        response: RegistrationResponseJSON;
      });

      await goHome();
    } catch (registrationError) {
      if (!isAbortError(registrationError)) {
        setError(describeError(registrationError, lang));
      }
    } finally {
      setBusy("idle");
      setStatus(null);
    }
  }

  async function handleSignIn() {
    if (!supportsPasskeys) {
      setError(t(lang, "login.notSupported"));
      return;
    }

    setBusy("signing-in");
    setError(null);
    setStatus(
      email.trim()
        ? lang === "en"
          ? `Looking for passkey for ${email.trim().toLowerCase()}…`
          : `Ищем passkey для ${email.trim().toLowerCase()}…`
        : lang === "en"
          ? "Open the system prompt and pick a passkey."
          : "Откройте системный диалог и выберите passkey.",
    );

    try {
      await finishAuthentication(email.trim() ? { email } : {});
      await goHome();
    } catch (authError) {
      if (!isAbortError(authError)) {
        setError(describeError(authError, lang));
      }
    } finally {
      setBusy("idle");
      setStatus(null);
    }
  }

  const signin = mode === "signin";
  const disabled = busy !== "idle" || supportsPasskeys === false;
  const onPrimary = signin ? handleSignIn : handleRegister;
  const primaryBusy =
    (signin && busy === "signing-in") || (!signin && busy === "registering");

  return (
    <div className="flex-1 px-6 py-12 flex items-start justify-center">
      <div className="relative w-full max-w-[460px] flex flex-col min-h-[680px] px-8 py-10 overflow-hidden">
        <div
          aria-hidden
          className="absolute -top-16 -right-16 w-60 h-60 rounded-full pointer-events-none"
          style={{
            background:
              "radial-gradient(circle, rgba(0,0,0,0.05), transparent 65%)",
          }}
        />

        <div className="relative z-10 flex items-center gap-2.5">
          <span className="w-[22px] h-[22px] rounded-full bg-[var(--fg)] grid place-items-center text-[var(--bg)] font-serif italic text-[11px]">
            m
          </span>
          <span className="font-serif italic text-[17px] font-medium">meta</span>
          <span className="ml-auto flex items-center gap-2">
            <span className="label-mono text-[10px]">
              {signin ? t(lang, "login.signIn") : t(lang, "login.createAccount")}
            </span>
            <LangToggle />
          </span>
        </div>

        <div className="relative z-10 mt-14">
          <h1
            className="font-serif text-[38px] leading-none font-light"
            style={{ letterSpacing: "-1px" }}
          >
            {signin ? (
              <>
                {t(lang, "login.welcome")}
                <br />
                <em className="italic text-[var(--accent)] font-normal">
                  {t(lang, "login.welcomeEm")}
                </em>
                .
              </>
            ) : (
              <>
                {t(lang, "login.letsMake")}
                <br />
                {t(lang, "login.youA")}{" "}
                <em className="italic text-[var(--accent)] font-normal">
                  {t(lang, "login.letsMakeEm")}
                </em>
                .
              </>
            )}
          </h1>
          <p className="mt-3.5 text-[13px] text-[var(--fg-muted)] leading-[1.55] max-w-[300px]">
            {signin ? t(lang, "login.subSignin") : t(lang, "login.subCreate")}
          </p>
        </div>

        <div className="relative z-10 mt-7 space-y-3">
          <div>
            <label className="label-mono block mb-1.5">{t(lang, "login.email")}</label>
            <input
              className="input !bg-[var(--bg)]"
              type="email"
              value={email}
              onChange={(event) => setEmail(event.target.value)}
              placeholder="you@example.com"
              autoCapitalize="none"
              autoCorrect="off"
              autoComplete="username webauthn"
              disabled={busy !== "idle"}
            />
          </div>
          {!signin && (
            <div>
              <label className="label-mono block mb-1.5">{t(lang, "login.name")}</label>
              <input
                className="input !bg-[var(--bg)]"
                value={name}
                onChange={(event) => setName(event.target.value)}
                placeholder={t(lang, "login.namePlaceholder")}
                autoComplete="name"
                disabled={busy !== "idle"}
              />
            </div>
          )}
        </div>

        <div
          className="relative z-10 mt-5 p-[18px] rounded-2xl"
          style={{
            background: "var(--bg-soft)",
            border: "1px solid var(--border-strong)",
          }}
        >
          <div className="flex items-center gap-3">
            <div
              className="w-11 h-11 rounded-full grid place-items-center"
              style={{
                background: "var(--bg)",
                border: "1px solid var(--border-strong)",
              }}
            >
              <KeyIcon />
            </div>
            <div className="flex-1">
              <div className="text-[13px] font-medium">{deviceLabel}</div>
              <div className="label-mono mt-0.5">{authenticatorLabel}</div>
            </div>
            <div
              className="label-mono"
              style={{
                color: "var(--success)",
                padding: "2px 6px",
                border: "1px solid var(--success)",
                borderRadius: 3,
                letterSpacing: "0.1em",
                fontSize: 9,
              }}
            >
              {supportsPasskeys === false
                ? t(lang, "login.unavailable")
                : supportsPasskeys === null
                  ? t(lang, "login.checking")
                  : t(lang, "login.ready")}
            </div>
          </div>
          <button
            type="button"
            onClick={onPrimary}
            disabled={disabled}
            className="w-full mt-3.5 h-[46px] rounded-[10px] text-[13px] font-medium flex items-center justify-center gap-2.5 transition-opacity disabled:opacity-60"
            style={{ background: "var(--fg)", color: "var(--bg)" }}
          >
            {primaryBusy
              ? signin
                ? t(lang, "login.signingIn")
                : t(lang, "login.creating")
              : signin
                ? t(lang, "login.signinCta")
                : t(lang, "login.createCta")}
          </button>
        </div>

        {(error || status) && (
          <div className="relative z-10 mt-3 text-[12px] leading-relaxed">
            {error ? (
              <div
                className="px-3 py-2 rounded-lg"
                style={{
                  background: "rgba(193,18,31,0.06)",
                  border: "1px solid var(--danger)",
                  color: "var(--danger)",
                }}
              >
                {error}
              </div>
            ) : (
              <div className="text-[var(--fg-muted)] italic">{status}</div>
            )}
          </div>
        )}

        {supportsPasskeys === false && !error && (
          <div
            className="relative z-10 mt-3 px-3 py-2 rounded-lg text-[12px] text-[var(--fg-muted)]"
            style={{
              background: "var(--bg-softer)",
              border: "1px solid var(--border-strong)",
            }}
          >
            {t(lang, "login.notSupported")}
          </div>
        )}

        <div className="relative z-10 mt-3.5 flex flex-col gap-1.5">
          <div className="label-mono" style={{ fontSize: 9 }}>
            {t(lang, "login.or")}
          </div>
          <div className="grid grid-cols-2 gap-2">
            <AltAuth
              icon={<GlobeIcon />}
              label={t(lang, "login.securityKey")}
              onClick={signin ? handleSignIn : undefined}
              disabled={disabled}
            />
            <AltAuth
              icon={<ChromeIcon />}
              label={t(lang, "login.anotherDevice")}
              onClick={signin ? handleSignIn : undefined}
              disabled={disabled}
            />
          </div>
          {autofillReady && (
            <div className="label-mono mt-1" style={{ fontSize: 9 }}>
              {t(lang, "login.autofillTip")}
            </div>
          )}
        </div>

        <div
          className="relative z-10 mt-auto pt-5 flex flex-col gap-1.5"
          style={{ borderTop: "1px solid var(--border)" }}
        >
          <div className="text-[12px] text-[var(--fg-muted)]">
            {signin ? `${t(lang, "login.newHere")} ` : `${t(lang, "login.alreadyHave")} `}
            <button
              type="button"
              onClick={() => {
                setMode(signin ? "create" : "signin");
                setError(null);
                setStatus(null);
              }}
              className="font-medium text-[var(--accent)]"
              style={{ borderBottom: "1px solid var(--accent)" }}
            >
              {signin ? t(lang, "login.createAMeta") : t(lang, "login.signIn")}
            </button>
          </div>
          <div
            className="label-mono"
            style={{ fontSize: 9, letterSpacing: "0.05em" }}
          >
            {t(lang, "login.strapline")}
          </div>
        </div>
      </div>
    </div>
  );
}

function AltAuth({
  icon,
  label,
  onClick,
  disabled,
}: {
  icon: React.ReactNode;
  label: string;
  onClick?: () => void;
  disabled?: boolean;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled || !onClick}
      className="flex items-center gap-2 px-3 py-2.5 rounded-lg text-[11px] text-[var(--fg-muted)] transition-colors hover:bg-[var(--bg-soft)] disabled:opacity-60 disabled:hover:bg-transparent"
      style={{ border: "1px solid var(--border-strong)" }}
    >
      {icon}
      {label}
    </button>
  );
}

function KeyIcon() {
  return (
    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="var(--accent)" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round">
      <circle cx="7.5" cy="15.5" r="4.5" />
      <path d="M10.5 12.5L21 2" />
      <path d="M15.5 7.5l3 3" />
      <path d="M18 5l3 3" />
    </svg>
  );
}

function GlobeIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round">
      <circle cx="12" cy="12" r="9" />
      <path d="M3 12h18" />
      <path d="M12 3a14 14 0 010 18" />
      <path d="M12 3a14 14 0 000 18" />
    </svg>
  );
}

function ChromeIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round">
      <circle cx="12" cy="12" r="9" />
      <circle cx="12" cy="12" r="3.2" />
      <path d="M21.2 8H12" />
      <path d="M3.6 7.5l4.8 7" />
      <path d="M15.6 13.8L10.4 22" />
    </svg>
  );
}
