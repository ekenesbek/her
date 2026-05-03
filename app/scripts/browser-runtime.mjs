import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs, { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));

export const APP_ROOT = path.resolve(scriptDir, "..");
export const REPO_ROOT = path.resolve(APP_ROOT, "..");
export const DEFAULT_CHROME_MCP_URL = "http://127.0.0.1:12306/mcp";
export const CHROME_MCP_URL = process.env.CHROME_MCP_URL || DEFAULT_CHROME_MCP_URL;
export const COMMON_EXTENSION_PATHS = [
  process.env.CHROME_MCP_EXTENSION_PATH,
  path.join(os.homedir(), "ChromeMCP", "extension"),
].filter(Boolean);

export const META_HOME = process.env.META_HOME || path.join(os.homedir(), ".meta");
export const MANAGED_CHROME_PROFILE = path.join(META_HOME, "chrome-profile");
export const MANAGED_CHROME_PID_FILE = path.join(META_HOME, "chrome.pid");
export const CHROME_MCP_AUTO_ACCEPT_FILE = path.join(META_HOME, "chrome-mcp-auto-accept.json");
export const MANAGED_CHROME_BIN = process.env.MANAGED_CHROME_BIN || findManagedChromeBinary();
export const MANAGED_CHROME_DEBUG_PORT = Number(process.env.MANAGED_CHROME_DEBUG_PORT || 9222);
export const DEFAULT_CHROME_MCP_EXTENSION_ID = "hbdgbgagpkpjffpklnamcljpakneikee";
export const CHROME_MCP_EXTENSION_ID =
  process.env.CHROME_MCP_EXTENSION_ID || findChromeMcpExtensionId() || DEFAULT_CHROME_MCP_EXTENSION_ID;

export const MANAGED_CHROME_LOADS_UNPACKED_EXTENSIONS = !/Google Chrome\.app\/Contents\/MacOS\/Google Chrome$/.test(
  MANAGED_CHROME_BIN,
);

function findManagedChromeBinary() {
  const candidates = [
    path.join(
      APP_ROOT,
      ".data",
      "browsers",
      "chrome",
      "mac_arm-*",
      "chrome-mac-arm64",
      "Google Chrome for Testing.app",
      "Contents",
      "MacOS",
      "Google Chrome for Testing",
    ),
    "/Applications/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary",
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  ];

  for (const candidate of candidates) {
    const resolved = resolveGlobCandidate(candidate);
    if (resolved) return resolved;
  }

  return "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
}

function resolveGlobCandidate(candidate) {
  if (!candidate.includes("*")) return existsSync(candidate) ? candidate : null;

  const parts = candidate.split(path.sep);
  const wildcardIndex = parts.findIndex((part) => part.includes("*"));
  if (wildcardIndex < 0) return existsSync(candidate) ? candidate : null;

  const base = parts.slice(0, wildcardIndex).join(path.sep) || path.sep;
  const rest = parts.slice(wildcardIndex + 1);
  if (!existsSync(base)) return null;

  const pattern = new RegExp(`^${parts[wildcardIndex].replace(/\*/g, ".*")}$`);
  const entries = fsReaddirSafe(base)
    .filter((entry) => pattern.test(entry))
    .sort()
    .reverse();

  for (const entry of entries) {
    const resolved = path.join(base, entry, ...rest);
    if (existsSync(resolved)) return resolved;
  }

  return null;
}

function fsReaddirSafe(dir) {
  try {
    return fs.readdirSync(dir);
  } catch {
    return [];
  }
}

export function ensureMetaHome() {
  if (!existsSync(META_HOME)) mkdirSync(META_HOME, { recursive: true });
  if (!existsSync(MANAGED_CHROME_PROFILE)) mkdirSync(MANAGED_CHROME_PROFILE, { recursive: true });
}

export function commandExists(command) {
  const result = spawnSync("sh", ["-lc", `command -v ${command}`], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  });
  return result.status === 0 && Boolean(result.stdout.trim());
}

export function run(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: options.cwd ?? APP_ROOT,
      env: options.env ?? process.env,
      stdio: options.stdio ?? "inherit",
    });

    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) {
        resolve();
      } else {
        reject(new Error(`${command} ${args.join(" ")} exited with ${code}`));
      }
    });
  });
}

export function capture(command, args, options = {}) {
  return spawnSync(command, args, {
    cwd: options.cwd ?? APP_ROOT,
    env: options.env ?? process.env,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
}

export function ensureEnvLocal(url = CHROME_MCP_URL) {
  const envPath = path.join(APP_ROOT, ".env.local");
  const line = `CHROME_MCP_URL=${url}`;

  if (!existsSync(envPath)) {
    writeFileSync(envPath, `${line}\n`);
    return { changed: true, path: envPath };
  }

  const current = readFileSync(envPath, "utf8");
  if (/^CHROME_MCP_URL=/m.test(current)) {
    return { changed: false, path: envPath };
  }

  const prefix = current.endsWith("\n") ? "" : "\n";
  writeFileSync(envPath, `${current}${prefix}${line}\n`);
  return { changed: true, path: envPath };
}

export function findChromeMcpExtensionPath() {
  return COMMON_EXTENSION_PATHS.find((extensionPath) =>
    existsSync(path.join(extensionPath, "manifest.json")),
  ) ?? null;
}

export function chromeExtensionIdFromKey(key) {
  if (!key || typeof key !== "string") return null;
  try {
    const der = Buffer.from(key, "base64");
    if (!der.length) return null;
    const hash = createHash("sha256").update(der).digest("hex").slice(0, 32);
    return hash
      .split("")
      .map((char) => String.fromCharCode("a".charCodeAt(0) + Number.parseInt(char, 16)))
      .join("");
  } catch {
    return null;
  }
}

export function findChromeMcpExtensionId() {
  const extensionPath = findChromeMcpExtensionPath();
  if (!extensionPath) return null;

  try {
    const manifest = JSON.parse(readFileSync(path.join(extensionPath, "manifest.json"), "utf8"));
    return chromeExtensionIdFromKey(manifest.key);
  } catch {
    return null;
  }
}

export async function pingChromeMcp(url = CHROME_MCP_URL) {
  const pingUrl = new URL(url);
  pingUrl.pathname = "/ping";
  pingUrl.search = "";
  pingUrl.hash = "";

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 1500);

  try {
    const response = await fetch(pingUrl, { signal: controller.signal });
    const body = await response.text();
    return {
      ok: response.ok,
      status: response.status,
      url: pingUrl.toString(),
      body,
    };
  } catch (error) {
    return {
      ok: false,
      status: null,
      url: pingUrl.toString(),
      body: error instanceof Error ? error.message : String(error),
    };
  } finally {
    clearTimeout(timeout);
  }
}

export function readBridgeDoctor({ fix = false } = {}) {
  if (!commandExists("mcp-chrome-bridge")) {
    return {
      ok: false,
      missing: true,
      stdout: "",
      stderr: "mcp-chrome-bridge is not installed",
      report: null,
    };
  }

  const args = ["doctor", "--json", "--browser", "chrome"];
  if (fix) args.push("--fix");

  const result = capture("mcp-chrome-bridge", args);
  let report = null;
  try {
    report = JSON.parse(result.stdout);
  } catch {
    // Keep raw stdout/stderr for diagnostics below.
  }

  return {
    ok: result.status === 0 && Boolean(report?.ok),
    missing: false,
    stdout: result.stdout,
    stderr: result.stderr,
    report,
  };
}

export function summarizeBridgeDoctor(doctor) {
  if (doctor.missing) {
    return [
      ["mcp-chrome-bridge", "missing", "Install with browser:setup"],
    ];
  }

  if (!doctor.report?.checks) {
    return [
      ["mcp-chrome-bridge", doctor.ok ? "ok" : "error", doctor.stderr.trim() || "Invalid doctor output"],
    ];
  }

  return doctor.report.checks.map((check) => [
    check.title,
    check.status,
    check.message,
  ]);
}

export function printStatusRows(rows) {
  const width = Math.max(...rows.map(([name]) => name.length), 6);
  for (const [name, status, message] of rows) {
    const label = status === "ok" ? "OK" : status === "warn" ? "WARN" : "FAIL";
    console.log(`${label.padEnd(4)} ${name.padEnd(width)} ${message}`);
  }
}
