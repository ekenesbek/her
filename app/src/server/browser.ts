import type { BrowserConnection, BrowserSettings } from "@/shared/types";

export const CHROME_MCP_URL_ENV = "CHROME_MCP_URL";
export const CHROME_MCP_SSE_URL_ENV = "CHROME_MCP_SSE_URL";
export const CHROME_MCP_AUTO_DISABLE_ENV = "CHROME_MCP_AUTO_DISABLE";
export const DEFAULT_CHROME_MCP_URL = "http://127.0.0.1:12306/mcp";

export function normalizeChromeMcpUrl(value: string | null | undefined) {
  const trimmed = value?.trim() ?? "";
  return trimmed || null;
}

export function resolveBrowserConnection(settings: BrowserSettings | null | undefined): BrowserConnection {
  const userUrl = normalizeChromeMcpUrl(settings?.chromeMcpUrl);
  if (userUrl) {
    return { chromeMcpUrl: userUrl, source: "user" };
  }

  const envUrl = normalizeChromeMcpUrl(
    process.env[CHROME_MCP_URL_ENV] ?? process.env[CHROME_MCP_SSE_URL_ENV],
  );
  if (envUrl) {
    return { chromeMcpUrl: envUrl, source: "env" };
  }

  if (process.env[CHROME_MCP_AUTO_DISABLE_ENV] !== "1") {
    return { chromeMcpUrl: DEFAULT_CHROME_MCP_URL, source: "auto" };
  }

  return { chromeMcpUrl: null, source: "none" };
}
