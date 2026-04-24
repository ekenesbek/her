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
import { useCallback, useEffect, useState } from "react";
import { useRouter } from "next/navigation";

type RegistrationStartPayload = {
  challengeId: string;
  options: PublicKeyCredentialCreationOptionsJSON;
};

type AuthenticationStartPayload = {
  challengeId: string;
  options: PublicKeyCredentialRequestOptionsJSON;
};

type BusyState = "idle" | "registering" | "signing-in";

function isAbortError(error: unknown) {
  if (!(error instanceof Error)) return false;
  const message = error.message.toLowerCase();
  return error.name === "AbortError" || message.includes("abort") || message.includes("cancel");
}

function describeError(error: unknown) {
  if (!(error instanceof Error)) return "Неизвестная ошибка";

  switch (error.message) {
    case "account_exists":
      return "Аккаунт с этим email уже существует. Войдите существующим passkey.";
    case "account_not_found":
      return "Аккаунт с этим email ещё не создан.";
    case "no_passkeys":
      return "Для этого аккаунта пока нет зарегистрированных passkeys.";
    case "verification_failed":
      return "Passkey не удалось подтвердить. Попробуйте ещё раз.";
    case "challenge_expired":
      return "Challenge устарел. Запустите вход ещё раз.";
    case "credential_not_found":
      return "Эта passkey не зарегистрирована в приложении.";
    case "credential_mismatch":
      return "Выбранная passkey привязана к другому аккаунту.";
    default:
      return error.message;
  }
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

export default function PasskeyAuth() {
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [name, setName] = useState("");
  const [busy, setBusy] = useState<BusyState>("idle");
  const [error, setError] = useState<string | null>(null);
  const [supportsPasskeys, setSupportsPasskeys] = useState<boolean | null>(null);
  const [autofillReady, setAutofillReady] = useState(false);
  const [status, setStatus] = useState(
    "Вход по passkey. Работает через Apple Passwords/iCloud Keychain и Google Password Manager.",
  );

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
      if (!supported) {
        setStatus("Этот браузер не поддерживает passkeys.");
        return;
      }

      try {
        const supportedAutofill = await browserSupportsWebAuthnAutofill();
        if (!active || !supportedAutofill) return;
        setAutofillReady(true);
        setStatus("Можно войти по кнопке ниже или через системную подсказку passkeys в поле email.");
      } catch {
        // Ignore autofill detection failures and keep the basic passkey flow available.
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
      setError("Укажите email для создания аккаунта.");
      return;
    }

    if (!supportsPasskeys) {
      setError("Passkeys в этом браузере не поддерживаются.");
      return;
    }

    setBusy("registering");
    setError(null);
    setStatus("Откройте системный диалог и сохраните passkey.");

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
        setError(describeError(registrationError));
      }
    } finally {
      setBusy("idle");
    }
  }

  async function handleSignIn() {
    if (!supportsPasskeys) {
      setError("Passkeys в этом браузере не поддерживаются.");
      return;
    }

    setBusy("signing-in");
    setError(null);
    setStatus(
      email.trim()
        ? `Ищем passkey для ${email.trim().toLowerCase()}...`
        : "Откройте системный диалог и выберите passkey.",
    );

    try {
      await finishAuthentication(email.trim() ? { email } : {});
      await goHome();
    } catch (authError) {
      if (!isAbortError(authError)) {
        setError(describeError(authError));
      }
    } finally {
      setBusy("idle");
    }
  }

  return (
    <div className="flex-1 px-6 py-12">
      <div className="max-w-5xl mx-auto grid grid-cols-1 lg:grid-cols-[1.1fr_0.9fr] gap-6 items-stretch">
        <section className="card p-8 md:p-10 flex flex-col justify-between">
          <div className="space-y-6">
            <div className="inline-flex items-center gap-2 rounded-full border border-[var(--border)] bg-[var(--bg-softer)] px-3 py-1 text-xs text-[var(--fg-muted)]">
              <span>passkeys</span>
              <span className="text-[var(--fg-dim)]">Apple + Google</span>
            </div>

            <div className="space-y-3">
              <h1 className="text-4xl md:text-5xl font-semibold tracking-tight">
                Вход без пароля.
              </h1>
              <p className="text-lg text-[var(--fg-muted)] max-w-xl leading-relaxed">
                Создайте одну passkey и входите через Apple Passwords, iCloud Keychain или Google Password Manager.
              </p>
            </div>

            <div className="grid grid-cols-1 md:grid-cols-3 gap-3">
              <InfoCard title="Face ID / Touch ID" text="Биометрия или PIN вместо пароля." />
              <InfoCard title="Кросс-девайс" text="Одна passkey синхронизируется между вашими устройствами." />
              <InfoCard title="Без общего секрета" text="Сервер не хранит пароль, только публичный ключ." />
            </div>
          </div>

          <div className="mt-8 rounded-2xl border border-[var(--border)] bg-[var(--bg-softer)] p-4 text-sm text-[var(--fg-muted)]">
            <div className="font-medium text-[var(--fg)] mb-1">Локальная разработка</div>
            <div>
              Для passkeys в dev лучше открывать приложение через <span className="text-[var(--fg)]">http://localhost:3000</span>.
              На <span className="text-[var(--fg)]">127.0.0.1</span> часть менеджеров может вести себя хуже.
            </div>
          </div>
        </section>

        <section className="card p-8 md:p-10 space-y-5">
          <div className="space-y-2">
            <h2 className="text-2xl font-semibold tracking-tight">Войти или создать аккаунт</h2>
            <p className="text-sm text-[var(--fg-muted)]">{status}</p>
          </div>

          <div className="space-y-4">
            <div>
              <label className="text-xs text-[var(--fg-muted)] block mb-1">Email</label>
              <input
                className="input"
                type="email"
                value={email}
                onChange={(event) => setEmail(event.target.value)}
                placeholder="you@example.com"
                autoCapitalize="none"
                autoCorrect="off"
                autoComplete="username webauthn"
              />
            </div>

            <div>
              <label className="text-xs text-[var(--fg-muted)] block mb-1">Имя для нового аккаунта</label>
              <input
                className="input"
                value={name}
                onChange={(event) => setName(event.target.value)}
                placeholder="Как вас называть"
                autoComplete="name"
              />
            </div>
          </div>

          {error && (
            <div className="rounded-xl border border-[var(--danger)] bg-[rgba(239,68,68,0.08)] px-4 py-3 text-sm text-[var(--danger)]">
              {error}
            </div>
          )}

          {supportsPasskeys === false && (
            <div className="rounded-xl border border-[var(--border-strong)] bg-[var(--bg-softer)] px-4 py-3 text-sm text-[var(--fg-muted)]">
              В этом браузере WebAuthn/passkeys недоступны. Нужен современный Safari, Chrome, Edge или Firefox.
            </div>
          )}

          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3 pt-2">
            <button
              className="btn btn-primary !py-3"
              type="button"
              onClick={handleSignIn}
              disabled={busy !== "idle" || supportsPasskeys === false}
            >
              {busy === "signing-in" ? "Входим..." : "Войти с passkey"}
            </button>
            <button
              className="btn btn-secondary !py-3"
              type="button"
              onClick={handleRegister}
              disabled={busy !== "idle" || supportsPasskeys === false}
            >
              {busy === "registering" ? "Создаём..." : "Создать passkey"}
            </button>
          </div>

          <div className="rounded-2xl border border-[var(--border)] bg-[var(--bg-softer)] px-4 py-4 text-sm text-[var(--fg-muted)] space-y-2">
            <div>
              <span className="text-[var(--fg)] font-medium">Автоподсказка:</span>{" "}
              {autofillReady
                ? "браузер поддерживает passkey autofill. Кликните в поле email, чтобы увидеть системную подсказку."
                : "если браузер поддерживает conditional UI, passkeys появятся в системной подсказке автоматически."}
            </div>
            <div>
              Если аккаунт уже существует, используйте вход. Если заходите впервые, сначала создайте passkey.
            </div>
          </div>
        </section>
      </div>
    </div>
  );
}

function InfoCard({ title, text }: { title: string; text: string }) {
  return (
    <div className="rounded-2xl border border-[var(--border)] bg-[var(--bg-softer)] p-4">
      <div className="text-sm font-medium">{title}</div>
      <div className="text-sm text-[var(--fg-muted)] mt-1 leading-relaxed">{text}</div>
    </div>
  );
}
