#!/usr/bin/env node
import { existsSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import {
  APP_ROOT,
  CHROME_MCP_URL,
  commandExists,
  ensureEnvLocal,
  pingChromeMcp,
  readBridgeDoctor,
  run,
} from "./browser-runtime.mjs";

console.log("Launching Meta app");

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
} else {
  const doctor = readBridgeDoctor({ fix: true });
  const ping = await pingChromeMcp(CHROME_MCP_URL);

  if (!doctor.ok || !ping.ok) {
    console.log("Browser runtime is not fully connected yet.");
    console.log("Run pnpm browser:setup, or open Chrome MCP and click Connect, then rerun pnpm browser:doctor.");
  } else {
    console.log("Browser runtime is ready.");
  }
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
