#!/usr/bin/env node
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import process from "node:process";
import {
  CHROME_MCP_AUTO_ACCEPT_FILE,
  CHROME_MCP_EXTENSION_ID,
  CHROME_MCP_URL,
  MANAGED_CHROME_DEBUG_PORT,
  ensureHerHome,
  pingChromeMcp,
} from "./browser-runtime.mjs";

const DEFAULT_NATIVE_PORT = 12306;

export function readChromeMcpAutoAcceptMarker() {
  if (!existsSync(CHROME_MCP_AUTO_ACCEPT_FILE)) return null;
  try {
    return JSON.parse(readFileSync(CHROME_MCP_AUTO_ACCEPT_FILE, "utf8"));
  } catch {
    return { attemptedAt: null, status: "invalid_marker" };
  }
}

export function shouldAttemptChromeMcpAutoAccept({ force = false, marker = null } = {}) {
  return force || !marker?.attemptedAt;
}

export function writeChromeMcpAutoAcceptMarker(marker) {
  ensureHerHome();
  writeFileSync(CHROME_MCP_AUTO_ACCEPT_FILE, `${JSON.stringify(marker, null, 2)}\n`);
}

export async function ensureChromeMcpAutoAcceptOnce({
  force = false,
  reason = "runtime",
  extensionId = CHROME_MCP_EXTENSION_ID,
  port = defaultPortFromMcpUrl(CHROME_MCP_URL),
  waitTimeoutMs = 6000,
} = {}) {
  ensureHerHome();

  const initialMcp = await pingChromeMcp(CHROME_MCP_URL);
  if (initialMcp.ok) {
    return {
      attempted: false,
      skipped: true,
      reason: "already_connected",
      markerPath: CHROME_MCP_AUTO_ACCEPT_FILE,
      mcp: initialMcp,
    };
  }

  const existingMarker = readChromeMcpAutoAcceptMarker();
  if (!shouldAttemptChromeMcpAutoAccept({ force, marker: existingMarker })) {
    return {
      attempted: false,
      skipped: true,
      reason: "already_attempted",
      markerPath: CHROME_MCP_AUTO_ACCEPT_FILE,
      marker: existingMarker,
      mcp: initialMcp,
    };
  }

  const startedAt = new Date().toISOString();
  const baseMarker = {
    attemptedAt: startedAt,
    reason,
    extensionId,
    port,
    debugPort: MANAGED_CHROME_DEBUG_PORT,
    status: "running",
    initialMcp: summarizePing(initialMcp),
  };
  writeChromeMcpAutoAcceptMarker(baseMarker);

  let accept;
  try {
    accept = await tryChromeMcpAutoAccept({ extensionId, port });
  } catch (error) {
    accept = {
      ok: false,
      error: error instanceof Error ? error.message : String(error),
    };
  }

  const mcp = await waitForChromeMcp({ timeoutMs: waitTimeoutMs });
  const marker = {
    ...baseMarker,
    completedAt: new Date().toISOString(),
    status: mcp.ok ? "connected" : "failed",
    accept,
    mcp: summarizePing(mcp),
  };
  writeChromeMcpAutoAcceptMarker(marker);

  return {
    attempted: true,
    skipped: false,
    markerPath: CHROME_MCP_AUTO_ACCEPT_FILE,
    marker,
    accept,
    mcp,
  };
}

async function tryChromeMcpAutoAccept({ extensionId, port }) {
  if (!extensionId) {
    return { ok: false, reason: "extension_id_missing" };
  }

  if (typeof WebSocket === "undefined") {
    const opened = await openExtensionPopupViaHttp(extensionId);
    return {
      ok: Boolean(opened.ok),
      reason: opened.ok ? "popup_opened_without_cdp_websocket" : "cdp_websocket_unavailable",
      opened,
    };
  }

  const browserWsUrl = await getBrowserWebSocketUrl();
  const client = await createCdpClient(browserWsUrl);
  try {
    let target = await findExtensionTarget(client, extensionId);
    let opened = null;

    if (!target) {
      opened = await openExtensionPopupViaCdp(client, extensionId);
      await delay(750);
      target = await findExtensionTarget(client, extensionId);
    }

    if (!target) {
      return {
        ok: false,
        reason: "extension_target_not_found",
        opened,
      };
    }

    const connected = await sendConnectNative(client, target, port);
    return {
      ok: Boolean(connected?.response?.success || connected?.response?.connected),
      target: {
        id: target.targetId,
        type: target.type,
        url: target.url,
      },
      opened,
      connected,
    };
  } finally {
    client.close();
  }
}

async function getBrowserWebSocketUrl() {
  const version = await fetchJson(`http://127.0.0.1:${MANAGED_CHROME_DEBUG_PORT}/json/version`, {
    timeoutMs: 2000,
  });
  if (!version?.webSocketDebuggerUrl) {
    throw new Error("Chrome DevTools endpoint did not expose webSocketDebuggerUrl");
  }
  return version.webSocketDebuggerUrl;
}

async function findExtensionTarget(client, extensionId) {
  const targets = await client.call("Target.getTargets");
  const prefix = `chrome-extension://${extensionId}/`;
  return targets.targetInfos.find((target) =>
    target.url?.startsWith(prefix) &&
    ["service_worker", "background_page", "page"].includes(target.type),
  ) ?? null;
}

async function openExtensionPopupViaCdp(client, extensionId) {
  try {
    const result = await client.call("Target.createTarget", {
      url: `chrome-extension://${extensionId}/popup.html`,
    });
    return { ok: true, targetId: result.targetId };
  } catch (error) {
    const httpFallback = await openExtensionPopupViaHttp(extensionId);
    return {
      ok: httpFallback.ok,
      error: error instanceof Error ? error.message : String(error),
      fallback: httpFallback,
    };
  }
}

async function openExtensionPopupViaHttp(extensionId) {
  const popupUrl = `chrome-extension://${extensionId}/popup.html`;
  const openUrl = `http://127.0.0.1:${MANAGED_CHROME_DEBUG_PORT}/json/new?${encodeURIComponent(popupUrl)}`;
  try {
    const target = await fetchJson(openUrl, { method: "PUT", timeoutMs: 2000 });
    return { ok: true, target };
  } catch (error) {
    return {
      ok: false,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}

async function sendConnectNative(client, target, port) {
  const { sessionId } = await client.call("Target.attachToTarget", {
    targetId: target.targetId,
    flatten: true,
  });

  try {
    const expression = `new Promise((resolve) => {
      try {
        chrome.runtime.sendMessage({ type: "connectNative", port: ${JSON.stringify(port)} }, (response) => {
          resolve({
            response: response ?? null,
            lastError: chrome.runtime.lastError ? chrome.runtime.lastError.message : null
          });
        });
      } catch (error) {
        resolve({ response: null, lastError: error && error.message ? error.message : String(error) });
      }
    })`;

    const result = await client.call(
      "Runtime.evaluate",
      {
        expression,
        awaitPromise: true,
        returnByValue: true,
      },
      sessionId,
    );

    if (result.exceptionDetails) {
      return {
        response: null,
        error: result.exceptionDetails.text || "Runtime.evaluate failed",
      };
    }

    return result.result?.value ?? null;
  } finally {
    try {
      await client.call("Target.detachFromTarget", { sessionId });
    } catch {
      // Target might close after opening the extension popup.
    }
  }
}

async function createCdpClient(webSocketUrl) {
  const ws = new WebSocket(webSocketUrl);
  const pending = new Map();
  let nextId = 1;

  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("Timed out connecting to Chrome DevTools")), 2000);
    ws.addEventListener("open", () => {
      clearTimeout(timer);
      resolve();
    }, { once: true });
    ws.addEventListener("error", (event) => {
      clearTimeout(timer);
      reject(new Error(event?.message || "Chrome DevTools WebSocket error"));
    }, { once: true });
  });

  ws.addEventListener("message", (event) => {
    void decodeWebSocketData(event.data).then((text) => {
      const message = JSON.parse(text);
      if (!message.id || !pending.has(message.id)) return;

      const request = pending.get(message.id);
      pending.delete(message.id);
      clearTimeout(request.timer);

      if (message.error) {
        request.reject(new Error(message.error.message || JSON.stringify(message.error)));
      } else {
        request.resolve(message.result);
      }
    }).catch(() => {
      // Ignore unrelated DevTools events that cannot be parsed.
    });
  });

  return {
    call(method, params = {}, sessionId = null) {
      const id = nextId++;
      const payload = { id, method, params };
      if (sessionId) payload.sessionId = sessionId;

      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          pending.delete(id);
          reject(new Error(`Timed out waiting for DevTools method ${method}`));
        }, 5000);

        pending.set(id, { resolve, reject, timer });

        try {
          ws.send(JSON.stringify(payload));
        } catch (error) {
          clearTimeout(timer);
          pending.delete(id);
          reject(error);
        }
      });
    },
    close() {
      for (const [id, request] of pending.entries()) {
        clearTimeout(request.timer);
        request.reject(new Error("Chrome DevTools connection closed"));
        pending.delete(id);
      }
      try {
        ws.close();
      } catch {
        // ignore
      }
    },
  };
}

async function fetchJson(url, { method = "GET", timeoutMs = 2000 } = {}) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, { method, signal: controller.signal });
    const body = await response.text();
    if (!response.ok) {
      throw new Error(`${response.status} ${body.slice(0, 200)}`);
    }
    return body ? JSON.parse(body) : null;
  } finally {
    clearTimeout(timeout);
  }
}

async function waitForChromeMcp({ timeoutMs = 6000, intervalMs = 400 } = {}) {
  const deadline = Date.now() + timeoutMs;
  let last = null;

  while (Date.now() < deadline) {
    last = await pingChromeMcp(CHROME_MCP_URL);
    if (last.ok) return last;
    await delay(intervalMs);
  }

  return last ?? (await pingChromeMcp(CHROME_MCP_URL));
}

async function decodeWebSocketData(data) {
  if (typeof data === "string") return data;
  if (data instanceof ArrayBuffer) return Buffer.from(data).toString("utf8");
  if (ArrayBuffer.isView(data)) {
    return Buffer.from(data.buffer, data.byteOffset, data.byteLength).toString("utf8");
  }
  if (data?.arrayBuffer) {
    return Buffer.from(await data.arrayBuffer()).toString("utf8");
  }
  return String(data);
}

function summarizePing(ping) {
  return {
    ok: ping.ok,
    status: ping.status,
    url: ping.url,
    body: typeof ping.body === "string" ? ping.body.slice(0, 300) : ping.body,
  };
}

function defaultPortFromMcpUrl(url) {
  try {
    return Number(new URL(url).port) || DEFAULT_NATIVE_PORT;
  } catch {
    return DEFAULT_NATIVE_PORT;
  }
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const force = process.argv.includes("--force");
  const result = await ensureChromeMcpAutoAcceptOnce({ force, reason: force ? "cli_force" : "cli" });
  console.log(JSON.stringify(result, null, 2));
  process.exit(result.mcp?.ok ? 0 : 2);
}
