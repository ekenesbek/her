#!/usr/bin/env node
import { existsSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import {
  APP_ROOT,
  CHROME_MCP_URL,
  commandExists,
  ensureEnvLocal,
  readBridgeDoctor,
  run,
} from "./browser-runtime.mjs";
import { ensureManagedChrome, managedChromeStatus } from "./managed-chrome.mjs";

console.log("Launching Her app");

if (!commandExists("pnpm")) {
  console.error("pnpm is required. Install it first, then rerun launch.");
  process.exit(1);
}

if (!existsSync(path.join(APP_ROOT, "node_modules"))) {
  console.log("Installing app dependencies...");
  await run("pnpm", ["install"], { cwd: APP_ROOT });
}

ensureEnvLocal(CHROME_MCP_URL);

if (!commandExists("mcp-chrome-bridge")) {
  console.log("Browser bridge is missing. Running browser setup...");
  await run("node", ["scripts/browser-setup.mjs"], { cwd: APP_ROOT });
}

const doctor = readBridgeDoctor({ fix: true });
if (!doctor.ok) {
  console.log("Browser bridge doctor reports issues. Run: pnpm browser:doctor");
}

const preStatus = managedChromeStatus();
if (!preStatus.running) {
  console.log("Starting managed Chrome profile...");
}
try {
  const result = await ensureManagedChrome({ wait: true });
  if (result.mcp?.ok) {
    console.log(
      result.started
        ? `Managed Chrome started (pid ${result.pid}); MCP endpoint ready.`
        : "Managed Chrome already running; MCP endpoint ready.",
    );
  } else {
    console.log(
      `Managed Chrome is running (pid ${result.pid}) but MCP endpoint did not respond: ${result.mcp?.status ?? result.mcp?.body}`,
    );
    console.log("Check the Chrome MCP extension; run: pnpm browser:doctor");
  }
} catch (err) {
  console.log(`Could not start managed Chrome: ${err instanceof Error ? err.message : err}`);
  console.log("Run: pnpm browser:setup");
}

console.log("");
console.log("App: http://localhost:3000");
console.log(`Chrome MCP: ${CHROME_MCP_URL}`);
console.log("");

await run("pnpm", ["dev"], {
  cwd: APP_ROOT,
  env: {
    ...process.env,
    CHROME_MCP_URL,
  },
});
