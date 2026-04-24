#!/usr/bin/env node
import {
  CHROME_MCP_URL,
  ensureEnvLocal,
  findChromeMcpExtensionPath,
  pingChromeMcp,
  printStatusRows,
  readBridgeDoctor,
  summarizeBridgeDoctor,
} from "./browser-runtime.mjs";

const fix = process.argv.includes("--fix");

console.log("Browser runtime doctor");
console.log(`Chrome MCP URL: ${CHROME_MCP_URL}`);

const env = ensureEnvLocal(CHROME_MCP_URL);
console.log(`Env file: ${env.path}${env.changed ? " (updated)" : ""}`);

const extensionPath = findChromeMcpExtensionPath();
console.log(`Extension path: ${extensionPath ?? "not found"}`);

const doctor = readBridgeDoctor({ fix });
printStatusRows(summarizeBridgeDoctor(doctor));

const ping = await pingChromeMcp(CHROME_MCP_URL);
console.log(`${ping.ok ? "OK" : "FAIL"}  endpoint ${ping.url} -> ${ping.status ?? ping.body}`);

if (!doctor.ok || !ping.ok) {
  console.log("");
  console.log("Next step:");
  if (doctor.missing) {
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
