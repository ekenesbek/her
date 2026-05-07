#!/usr/bin/env node
import {
  CHROME_MCP_URL,
  commandExists,
  ensureEnvLocal,
  ensureHerHome,
  findChromeMcpExtensionPath,
  readBridgeDoctor,
  run,
} from "./browser-runtime.mjs";

const noInstall = process.argv.includes("--no-install");

console.log("Setting up browser runtime");

if (!commandExists("mcp-chrome-bridge")) {
  if (noInstall) {
    console.error("mcp-chrome-bridge is not installed. Rerun without --no-install to install it.");
    process.exit(1);
  }

  console.log("Installing mcp-chrome-bridge globally...");
  await run("npm", ["install", "-g", "mcp-chrome-bridge"]);
}

console.log("Registering Chrome native messaging host...");
await run("mcp-chrome-bridge", ["register", "--browser", "chrome", "--force"]);

console.log("Running bridge doctor with auto-fix...");
const doctor = readBridgeDoctor({ fix: true });
if (!doctor.ok) {
  console.error(doctor.stderr.trim() || doctor.stdout.trim() || "mcp-chrome-bridge doctor failed");
  process.exit(1);
}

const env = ensureEnvLocal(CHROME_MCP_URL);
console.log(`Configured ${env.path}${env.changed ? "" : " (already configured)"}`);

const extensionPath = findChromeMcpExtensionPath();
if (extensionPath) {
  console.log(`Chrome MCP extension folder: ${extensionPath}`);
} else {
  console.log("Chrome MCP extension folder was not found.");
  console.log("Set CHROME_MCP_EXTENSION_PATH or install the Chrome MCP extension before using browser agents.");
  process.exit(1);
}

ensureHerHome();
console.log("Managed Chrome profile directory is ready at ~/.her/chrome-profile.");
console.log("Start it with: pnpm browser:start");
console.log("");
console.log("Browser runtime is configured.");
