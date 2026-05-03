#!/usr/bin/env node
import {
  CHROME_MCP_URL,
  CHROME_MCP_AUTO_ACCEPT_FILE,
  MANAGED_CHROME_BIN,
  MANAGED_CHROME_LOADS_UNPACKED_EXTENSIONS,
  ensureEnvLocal,
  findChromeMcpExtensionPath,
  pingChromeMcp,
  printStatusRows,
  readBridgeDoctor,
  summarizeBridgeDoctor,
} from "./browser-runtime.mjs";
import { readChromeMcpAutoAcceptMarker } from "./chrome-mcp-auto-accept.mjs";

const fix = process.argv.includes("--fix");

console.log("Browser runtime doctor");
console.log(`Chrome MCP URL: ${CHROME_MCP_URL}`);
console.log(`Managed browser: ${MANAGED_CHROME_BIN}`);
console.log(`Loads unpacked extensions: ${MANAGED_CHROME_LOADS_UNPACKED_EXTENSIONS ? "yes" : "no"}`);

const env = ensureEnvLocal(CHROME_MCP_URL);
console.log(`Env file: ${env.path}${env.changed ? " (updated)" : ""}`);

const extensionPath = findChromeMcpExtensionPath();
console.log(`Extension path: ${extensionPath ?? "not found"}`);
const autoAcceptMarker = readChromeMcpAutoAcceptMarker();
console.log(
  `Auto-accept marker: ${autoAcceptMarker?.attemptedAt ? `${CHROME_MCP_AUTO_ACCEPT_FILE} (${autoAcceptMarker.status})` : "not used"}`,
);

const doctor = readBridgeDoctor({ fix });
printStatusRows(summarizeBridgeDoctor(doctor));

const ping = await pingChromeMcp(CHROME_MCP_URL);
console.log(`${ping.ok ? "OK" : "FAIL"}  endpoint ${ping.url} -> ${ping.status ?? ping.body}`);

if (!doctor.ok || !ping.ok || !MANAGED_CHROME_LOADS_UNPACKED_EXTENSIONS) {
  console.log("");
  console.log("Next step:");
  if (!MANAGED_CHROME_LOADS_UNPACKED_EXTENSIONS) {
    console.log("Install Chrome for Testing or Chromium, or set MANAGED_CHROME_BIN to that browser.");
    console.log("Regular Google Chrome ignores --load-extension in current builds, so auto Chrome MCP cannot start there.");
  } else if (doctor.missing) {
    console.log("Run: pnpm browser:setup");
  } else if (!ping.ok) {
    console.log("Open the Chrome MCP extension in Chrome and click Connect, then rerun: pnpm browser:doctor");
  } else {
    console.log("Run: pnpm browser:setup");
  }
  process.exit(1);
}

console.log("");
console.log("Browser runtime is ready.");
