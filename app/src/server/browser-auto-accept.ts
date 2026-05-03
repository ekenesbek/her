import { spawn } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import type { BrowserConnection } from "@/shared/types";

const AUTO_ACCEPT_FILE = path.join(process.env.META_HOME || path.join(os.homedir(), ".meta"), "chrome-mcp-auto-accept.json");
const AUTO_ACCEPT_SCRIPT = path.join(process.cwd(), "scripts", "chrome-mcp-auto-accept.mjs");
const AUTO_ACCEPT_TIMEOUT_MS = 10_000;
const PING_TIMEOUT_MS = 1000;

let processChecked = false;
let pendingAttempt: Promise<BrowserAutoAcceptResult> | null = null;
let lastAutoAcceptResult: BrowserAutoAcceptResult | null = null;

export type BrowserAutoAcceptResult = {
  ran: boolean;
  ok: boolean;
  reason: string;
  markerPath: string;
  raw?: unknown;
  error?: string;
};

type ChromeMcpAutoAcceptScriptResult = {
  reason?: string;
  mcp?: {
    ok?: boolean;
    body?: string;
  };
  accept?: {
    connected?: {
      lastError?: string;
    };
  };
};

export async function maybeRunBrowserAutoAcceptOnce(
  browserConnection: BrowserConnection,
): Promise<BrowserAutoAcceptResult> {
  if (!browserConnection.chromeMcpUrl) {
    return skipped("browser_not_configured");
  }

  if (!isLocalChromeMcpUrl(browserConnection.chromeMcpUrl)) {
    return skipped("non_local_browser_mcp");
  }

  const liveMcp = await pingChromeMcp(browserConnection.chromeMcpUrl);
  if (liveMcp.ok) {
    lastAutoAcceptResult = {
      ran: false,
      ok: true,
      reason: "already_connected",
      markerPath: AUTO_ACCEPT_FILE,
    };
    return lastAutoAcceptResult;
  }

  if (processChecked) {
    return lastAutoAcceptResult ?? skipped("already_checked_in_process");
  }

  const marker = readAutoAcceptMarker();
  if (marker?.attemptedAt) {
    processChecked = true;
    lastAutoAcceptResult = {
      ran: false,
      ok: false,
      reason: "already_attempted",
      markerPath: AUTO_ACCEPT_FILE,
      raw: marker,
    };
    return lastAutoAcceptResult;
  }

  pendingAttempt ??= runAutoAcceptScript()
    .then((result) => {
      lastAutoAcceptResult = result;
      return result;
    })
    .finally(() => {
      processChecked = true;
      pendingAttempt = null;
    });

  return pendingAttempt;
}

function isLocalChromeMcpUrl(value: string) {
  try {
    const url = new URL(value);
    return ["127.0.0.1", "localhost", "::1"].includes(url.hostname);
  } catch {
    return false;
  }
}

function readAutoAcceptMarker() {
  if (!existsSync(AUTO_ACCEPT_FILE)) return null;
  try {
    return JSON.parse(readFileSync(AUTO_ACCEPT_FILE, "utf8")) as {
      attemptedAt?: string;
      status?: string;
    };
  } catch {
    return { attemptedAt: null, status: "invalid_marker" };
  }
}

async function pingChromeMcp(mcpUrl: string) {
  let url: URL;
  try {
    url = new URL(mcpUrl);
  } catch {
    return { ok: false };
  }

  url.pathname = "/ping";
  url.search = "";
  url.hash = "";

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), PING_TIMEOUT_MS);

  try {
    const response = await fetch(url, { signal: controller.signal });
    return { ok: response.ok };
  } catch {
    return { ok: false };
  } finally {
    clearTimeout(timeout);
  }
}

function runAutoAcceptScript(): Promise<BrowserAutoAcceptResult> {
  return new Promise((resolve) => {
    if (!existsSync(AUTO_ACCEPT_SCRIPT)) {
      resolve({
        ran: false,
        ok: false,
        reason: "auto_accept_script_missing",
        markerPath: AUTO_ACCEPT_FILE,
      });
      return;
    }

    const child = spawn(process.execPath, [AUTO_ACCEPT_SCRIPT], {
      cwd: process.cwd(),
      env: process.env,
      stdio: ["ignore", "pipe", "pipe"],
    });

    let stdout = "";
    let stderr = "";
    const timeout = setTimeout(() => {
      child.kill("SIGTERM");
      resolve({
        ran: true,
        ok: false,
        reason: "timeout",
        markerPath: AUTO_ACCEPT_FILE,
        error: `Timed out after ${AUTO_ACCEPT_TIMEOUT_MS}ms`,
      });
    }, AUTO_ACCEPT_TIMEOUT_MS);

    child.stdout.on("data", (chunk) => {
      stdout += String(chunk);
    });
    child.stderr.on("data", (chunk) => {
      stderr += String(chunk);
    });

    child.on("error", (error) => {
      clearTimeout(timeout);
      resolve({
        ran: true,
        ok: false,
        reason: "spawn_error",
        markerPath: AUTO_ACCEPT_FILE,
        error: error.message,
      });
    });

    child.on("close", (code) => {
      clearTimeout(timeout);
      const parsed = parseJson(stdout);
      resolve({
        ran: true,
        ok: code === 0 && Boolean(parsed?.mcp?.ok),
        reason: parsed?.reason ?? (code === 0 ? "completed" : "failed"),
        markerPath: AUTO_ACCEPT_FILE,
        raw: parsed ?? undefined,
        error: code === 0 ? undefined : stderr.trim() || parsed?.accept?.connected?.lastError || parsed?.mcp?.body,
      });
    });
  });
}

function parseJson(value: string): ChromeMcpAutoAcceptScriptResult | null {
  try {
    return JSON.parse(value) as ChromeMcpAutoAcceptScriptResult;
  } catch {
    return null;
  }
}

function skipped(reason: string): BrowserAutoAcceptResult {
  return {
    ran: false,
    ok: false,
    reason,
    markerPath: AUTO_ACCEPT_FILE,
  };
}
