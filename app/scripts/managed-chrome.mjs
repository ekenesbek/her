#!/usr/bin/env node
import { spawn } from "node:child_process";
import { existsSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import process from "node:process";
import {
  CHROME_MCP_URL,
  MANAGED_CHROME_BIN,
  MANAGED_CHROME_DEBUG_PORT,
  MANAGED_CHROME_PID_FILE,
  MANAGED_CHROME_PROFILE,
  ensureMetaHome,
  findChromeMcpExtensionPath,
  pingChromeMcp,
} from "./browser-runtime.mjs";

function readPid() {
  if (!existsSync(MANAGED_CHROME_PID_FILE)) return null;
  const raw = readFileSync(MANAGED_CHROME_PID_FILE, "utf8").trim();
  const pid = Number(raw);
  return Number.isInteger(pid) && pid > 0 ? pid : null;
}

function isAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

export function managedChromeStatus() {
  const pid = readPid();
  return { pid, running: pid !== null && isAlive(pid) };
}

export async function startManagedChrome() {
  const existing = managedChromeStatus();
  if (existing.running) return { ...existing, started: false };

  if (!existsSync(MANAGED_CHROME_BIN)) {
    throw new Error(
      `Managed Chrome binary not found at ${MANAGED_CHROME_BIN}. Set MANAGED_CHROME_BIN to override.`,
    );
  }

  const extensionPath = findChromeMcpExtensionPath();
  if (!extensionPath) {
    throw new Error(
      "Chrome MCP extension folder not found. Run pnpm browser:setup first or set CHROME_MCP_EXTENSION_PATH.",
    );
  }

  ensureMetaHome();

  const args = [
    `--user-data-dir=${MANAGED_CHROME_PROFILE}`,
    `--load-extension=${extensionPath}`,
    `--remote-debugging-port=${MANAGED_CHROME_DEBUG_PORT}`,
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-features=DefaultBrowserSettingEnabled",
    "--restore-last-session=false",
    "about:blank",
  ];

  const child = spawn(MANAGED_CHROME_BIN, args, {
    detached: true,
    stdio: "ignore",
  });
  child.unref();

  if (!child.pid) throw new Error("Failed to spawn managed Chrome");
  writeFileSync(MANAGED_CHROME_PID_FILE, String(child.pid));

  return { pid: child.pid, running: true, started: true };
}

export function stopManagedChrome() {
  const { pid, running } = managedChromeStatus();
  if (!running) {
    if (existsSync(MANAGED_CHROME_PID_FILE)) unlinkSync(MANAGED_CHROME_PID_FILE);
    return { stopped: false, pid };
  }
  try {
    process.kill(pid, "SIGTERM");
  } catch {
    // ignore
  }
  if (existsSync(MANAGED_CHROME_PID_FILE)) unlinkSync(MANAGED_CHROME_PID_FILE);
  return { stopped: true, pid };
}

export async function waitForMcp({ timeoutMs = 20000, intervalMs = 500 } = {}) {
  const deadline = Date.now() + timeoutMs;
  let last = null;
  while (Date.now() < deadline) {
    last = await pingChromeMcp(CHROME_MCP_URL);
    if (last.ok) return last;
    await new Promise((r) => setTimeout(r, intervalMs));
  }
  return last ?? (await pingChromeMcp(CHROME_MCP_URL));
}

export async function ensureManagedChrome({ wait = true } = {}) {
  const result = await startManagedChrome();
  if (wait) {
    const ping = await waitForMcp();
    return { ...result, mcp: ping };
  }
  return result;
}

// CLI
if (import.meta.url === `file://${process.argv[1]}`) {
  const cmd = process.argv[2] || "status";
  try {
    if (cmd === "start") {
      const r = await ensureManagedChrome({ wait: true });
      console.log(JSON.stringify(r, null, 2));
      process.exit(r.mcp?.ok ? 0 : 2);
    } else if (cmd === "stop") {
      console.log(JSON.stringify(stopManagedChrome(), null, 2));
    } else if (cmd === "status") {
      const s = managedChromeStatus();
      const ping = await pingChromeMcp(CHROME_MCP_URL);
      console.log(JSON.stringify({ ...s, mcp: ping }, null, 2));
    } else {
      console.error(`Unknown command: ${cmd}. Use start|stop|status.`);
      process.exit(1);
    }
  } catch (err) {
    console.error(err instanceof Error ? err.message : String(err));
    process.exit(1);
  }
}
