import { spawn, spawnSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
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
