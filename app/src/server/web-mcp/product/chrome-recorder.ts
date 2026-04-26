import {
  recordWebPageSnapshot,
  upsertWebSiteWorkspace,
} from "./storage";
import type { WebActionKind, WebGoalState, WebPageAction, WebPageLink } from "../core/types";

type TabMemory = {
  url: string;
  title?: string;
  windowId?: number;
  active?: boolean;
};

export type WebMcpRecordingState = {
  tabs: Map<number, TabMemory>;
  activeTabId: number | null;
  milestoneGoal: string;
};

export type WebMcpRecordingOutcome = {
  title: string;
  details: Record<string, unknown>;
};

const MAX_LAYOUT_CHARS = 24_000;
const MAX_SUMMARY_CHARS = 700;
const MAX_LINKS = 120;
const MAX_ACTIONS = 120;

export function createWebMcpRecordingState(milestoneGoal = ""): WebMcpRecordingState {
  return {
    tabs: new Map(),
    activeTabId: null,
    milestoneGoal,
  };
}

export function recordWebMcpToolResult({
  userId,
  state,
  toolName,
  input,
  result,
}: {
  userId: string;
  state: WebMcpRecordingState;
  toolName: string;
  input: unknown;
  result: unknown;
}): WebMcpRecordingOutcome | null {
  const normalizedToolName = normalizeToolName(toolName);
  const payloads = extractJsonPayloads(result);
  if (payloads.length === 0) return null;

  let lastOutcome: WebMcpRecordingOutcome | null = null;
  for (const payload of payloads) {
    updateTabMemory(state, payload, input);

    const snapshotInput = buildSnapshotInput(normalizedToolName, payload, input, state);
    if (!snapshotInput) continue;

    const workspace = upsertWebSiteWorkspace(userId, {
      url: snapshotInput.url,
      label: new URL(snapshotInput.url).hostname,
      goal: state.milestoneGoal || "Auto-recorded browser memory for public site traversal.",
    }).site;

    const snapshot = recordWebPageSnapshot(userId, workspace.siteKey, snapshotInput);
    lastOutcome = {
      title: `Web MCP recorded: ${snapshot.host}${snapshot.pathname}`,
      details: {
        siteKey: workspace.siteKey,
        url: snapshot.url,
        title: snapshot.title,
        linkCount: snapshot.linkCount,
        source: normalizedToolName,
        snapshotFile: snapshot.snapshotFile,
      },
    };
  }

  return lastOutcome;
}

function buildSnapshotInput(
  toolName: string,
  payload: Record<string, unknown>,
  input: unknown,
  state: WebMcpRecordingState,
) {
  if (!isSuccessfulPayload(payload)) return null;

  const url = resolvePayloadUrl(payload, input, state);
  if (!url || !shouldRecordUrl(url)) return null;

  const normalizedUrl = new URL(url);
  const title = cleanString(payload.title) ?? findTabByUrl(state, normalizedUrl.toString())?.title ?? normalizedUrl.hostname;
  const textContent = cleanString(payload.textContent);
  const pageContent = cleanString(payload.pageContent);
  const htmlContent = cleanString(payload.htmlContent);
  const message = cleanString(payload.message);

  const isContentTool = toolName === "chrome_get_web_content";
  const isReadPageTool = toolName === "chrome_read_page";
  const isNavigationTool = toolName === "chrome_navigate" || toolName === "chrome_switch_tab";

  if (!isContentTool && !isReadPageTool && !isNavigationTool) return null;

  const layout = truncate(
    [
      title ? `# ${title}` : null,
      `URL: ${normalizedUrl.toString()}`,
      textContent ? `\n## Text\n${textContent}` : null,
      pageContent ? `\n## Visible accessibility tree\n${pageContent}` : null,
      htmlContent ? `\n## HTML\n${htmlContent}` : null,
      !textContent && !pageContent && message ? `\n## Navigation\n${message}` : null,
    ]
      .filter(Boolean)
      .join("\n"),
    MAX_LAYOUT_CHARS,
  );

  const summary = buildSummary({ textContent, pageContent, message, toolName, payload });
  const links = extractLinks({ payload, layout, baseUrl: normalizedUrl });
  const actions = extractActions({ payload, layout, links, baseUrl: normalizedUrl });
  const statusCode = typeof payload.statusCode === "number" ? payload.statusCode : null;
  const goalState: WebGoalState = textContent || pageContent ? "visited" : "queued";
  const plan = [
    `Captured automatically from ${toolName}.`,
    actions.length > 0
      ? `Next-step candidates: ${actions.slice(0, 8).map((action) => `${action.kind}:${action.label}`).join("; ")}`
      : null,
  ]
    .filter(Boolean)
    .join(" ");

  return {
    url: normalizedUrl.toString(),
    title,
    statusCode,
    summary,
    layout,
    links,
    actions,
    sourceUrl: null,
    plan,
    flowPlan: actions.length > 0
      ? `Semantic actions available on this page: ${actions.slice(0, 20).map((action) => action.label).join("; ")}`
      : "",
    milestoneGoal: state.milestoneGoal,
    goalState,
  };
}

function buildSummary({
  textContent,
  pageContent,
  message,
  toolName,
  payload,
}: {
  textContent?: string;
  pageContent?: string;
  message?: string;
  toolName: string;
  payload: Record<string, unknown>;
}) {
  if (textContent) return truncate(collapseWhitespace(textContent), MAX_SUMMARY_CHARS);
  if (pageContent) {
    const count = typeof payload.count === "number" ? payload.count : undefined;
    const filter = cleanString(payload.filter);
    return [
      "Visible accessibility snapshot",
      count !== undefined ? `${count} elements` : null,
      filter ? `filter=${filter}` : null,
    ]
      .filter(Boolean)
      .join("; ");
  }
  if (message) return truncate(message, MAX_SUMMARY_CHARS);
  return `Captured automatically from ${toolName}.`;
}

function updateTabMemory(state: WebMcpRecordingState, payload: Record<string, unknown>, input: unknown) {
  const inputTabId = getNumber(input, "tabId");
  const directUrl = cleanString(payload.url);
  const directTitle = cleanString(payload.title);
  const directTabId = getNumber(payload, "tabId") ?? inputTabId;
  const directWindowId = getNumber(payload, "windowId");

  if (directTabId !== undefined && directUrl) {
    state.tabs.set(directTabId, {
      url: directUrl,
      title: directTitle ?? state.tabs.get(directTabId)?.title,
      windowId: directWindowId ?? state.tabs.get(directTabId)?.windowId,
      active: state.tabs.get(directTabId)?.active,
    });
    state.activeTabId = directTabId;
  }

  const windows = Array.isArray(payload.windows) ? payload.windows : [];
  for (const windowValue of windows) {
    if (!isRecord(windowValue)) continue;
    const windowId = getNumber(windowValue, "windowId");
    const tabs = Array.isArray(windowValue.tabs) ? windowValue.tabs : [];
    for (const tabValue of tabs) updateTabFromPayload(state, tabValue, windowId);
  }

  const tabs = Array.isArray(payload.tabs) ? payload.tabs : [];
  for (const tabValue of tabs) updateTabFromPayload(state, tabValue, directWindowId);
}

function updateTabFromPayload(state: WebMcpRecordingState, value: unknown, windowId?: number) {
  if (!isRecord(value)) return;
  const tabId = getNumber(value, "tabId") ?? getNumber(value, "id");
  const url = cleanString(value.url);
  if (tabId === undefined || !url) return;

  const active = typeof value.active === "boolean" ? value.active : undefined;
  state.tabs.set(tabId, {
    url,
    title: cleanString(value.title),
    windowId,
    active,
  });
  if (active) state.activeTabId = tabId;
}

function resolvePayloadUrl(payload: Record<string, unknown>, input: unknown, state: WebMcpRecordingState) {
  const payloadUrl = cleanString(payload.url);
  if (payloadUrl) return payloadUrl;

  const tabs = Array.isArray(payload.tabs) ? payload.tabs : [];
  for (const tabValue of tabs) {
    if (!isRecord(tabValue)) continue;
    const tabUrl = cleanString(tabValue.url);
    if (tabUrl) return tabUrl;
  }

  const inputTabId = getNumber(input, "tabId");
  if (inputTabId !== undefined) return state.tabs.get(inputTabId)?.url;

  if (state.activeTabId !== null) return state.tabs.get(state.activeTabId)?.url;
  return undefined;
}

function findTabByUrl(state: WebMcpRecordingState, url: string) {
  return [...state.tabs.values()].find((tab) => tab.url === url);
}

function extractJsonPayloads(result: unknown): Record<string, unknown>[] {
  const payloads: Record<string, unknown>[] = [];
  if (isRecord(result)) payloads.push(result);

  for (const text of collectTextBlocks(result)) {
    try {
      const parsed = JSON.parse(text) as unknown;
      if (isRecord(parsed)) payloads.push(parsed);
    } catch {
      // Non-JSON text blocks are common in tool output.
    }
  }

  return payloads;
}

function collectTextBlocks(value: unknown): string[] {
  if (Array.isArray(value)) return value.flatMap(collectTextBlocks);
  if (!isRecord(value)) return [];
  if (value.type === "text" && typeof value.text === "string") return [value.text];

  const blocks: string[] = [];
  if (Array.isArray(value.content)) blocks.push(...value.content.flatMap(collectTextBlocks));
  if (Array.isArray(value.result)) blocks.push(...value.result.flatMap(collectTextBlocks));
  return blocks;
}

function extractLinks({
  payload,
  layout,
  baseUrl,
}: {
  payload: Record<string, unknown>;
  layout: string;
  baseUrl: URL;
}): WebPageLink[] {
  const links = new Map<string, WebPageLink>();
  const rawLinks = Array.isArray(payload.links) ? payload.links : [];

  for (const rawLink of rawLinks) {
    if (!isRecord(rawLink)) continue;
    addLink(links, baseUrl, cleanString(rawLink.url), cleanString(rawLink.text) ?? "", cleanString(rawLink.rel) ?? null);
  }

  for (const line of layout.split(/\r?\n/)) {
    const readPageMatch = line.match(/link(?:\s+"([^"]*)")?.*?href="([^"]+)"/);
    if (readPageMatch) addLink(links, baseUrl, readPageMatch[2], readPageMatch[1] ?? "", null);
  }

  const anchorPattern = /<a\b[^>]*\bhref=["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>/gi;
  for (const match of layout.matchAll(anchorPattern)) {
    addLink(links, baseUrl, match[1], stripTags(match[2]), null);
    if (links.size >= MAX_LINKS) break;
  }

  return [...links.values()].slice(0, MAX_LINKS);
}

function addLink(
  links: Map<string, WebPageLink>,
  baseUrl: URL,
  rawUrl: string | undefined,
  text: string,
  rel: string | null,
) {
  if (!rawUrl || links.size >= MAX_LINKS) return;

  try {
    const url = new URL(rawUrl, baseUrl);
    if (url.protocol !== "http:" && url.protocol !== "https:") return;
    url.hash = "";
    const normalized = url.toString();
    if (!links.has(normalized)) {
      links.set(normalized, {
        url: normalized,
        text: truncate(collapseWhitespace(text), 180),
        rel,
      });
    }
  } catch {
    // Ignore malformed links from page content.
  }
}

function extractActions({
  payload,
  layout,
  links,
  baseUrl,
}: {
  payload: Record<string, unknown>;
  layout: string;
  links: WebPageLink[];
  baseUrl: URL;
}): Array<Partial<WebPageAction>> {
  const actions = new Map<string, Partial<WebPageAction>>();

  for (const link of links) {
    addAction(actions, {
      kind: "link",
      label: link.text || link.url,
      text: link.text,
      href: link.url,
      targetUrl: link.url,
      source: "link",
      confidence: 0.8,
    });
  }

  const rawElements = [
    ...(Array.isArray(payload.elements) ? payload.elements : []),
    ...(Array.isArray(payload.items) ? payload.items : []),
    ...(Array.isArray(payload.actions) ? payload.actions : []),
  ];
  for (const element of rawElements) {
    if (!isRecord(element)) continue;
    const kind = normalizeActionKind(cleanString(element.kind) ?? cleanString(element.role) ?? cleanString(element.type));
    const href = cleanString(element.href) ?? cleanString(element.url);
    addAction(actions, {
      kind,
      role: cleanString(element.role) ?? null,
      label:
        cleanString(element.label) ??
        cleanString(element.name) ??
        cleanString(element.text) ??
        href ??
        undefined,
      text: cleanString(element.text) ?? cleanString(element.name) ?? "",
      href,
      targetUrl: href ? normalizeHref(href, baseUrl) : null,
      ref: cleanString(element.ref) ?? cleanString(element.id) ?? null,
      source: "payload",
      confidence: 0.85,
    });
  }

  for (const line of layout.split(/\r?\n/)) {
    const parsed = parseInteractiveLine(line, baseUrl);
    if (parsed) addAction(actions, parsed);
    if (actions.size >= MAX_ACTIONS) break;
  }

  return [...actions.values()].slice(0, MAX_ACTIONS);
}

function addAction(actions: Map<string, Partial<WebPageAction>>, action: Partial<WebPageAction>) {
  const label = cleanString(action.label);
  if (!label) return;
  const key = [
    action.kind ?? "unknown",
    label.toLowerCase(),
    action.targetUrl ?? action.href ?? "",
    action.ref ?? "",
  ].join("|");
  if (!actions.has(key)) {
    actions.set(key, {
      ...action,
      label: truncate(collapseWhitespace(label), 180),
    });
  }
}

function parseInteractiveLine(line: string, baseUrl: URL): Partial<WebPageAction> | null {
  const roleMatch = line.match(/\b(link|button|textbox|input|combobox|select|checkbox|radio|tab|menuitem|option|form)\b/i);
  if (!roleMatch) return null;

  const role = roleMatch[1].toLowerCase();
  const label =
    line.match(/"([^"]{1,240})"/)?.[1] ??
    line.match(/\b(?:name|label|aria-label)=["']([^"']{1,240})["']/i)?.[1] ??
    line.replace(/\s+/g, " ").trim().slice(0, 180);
  const href = line.match(/\bhref=["']([^"']+)["']/i)?.[1];
  const ref = line.match(/\b(?:ref|data-ref|id)=["']?([A-Za-z0-9:_-]{1,160})["']?/i)?.[1];

  return {
    kind: normalizeActionKind(role),
    role,
    label,
    text: label,
    href,
    targetUrl: href ? normalizeHref(href, baseUrl) : null,
    ref,
    source: "layout",
    confidence: href || ref ? 0.72 : 0.58,
  };
}

function normalizeActionKind(value: string | undefined): WebActionKind {
  switch (value?.toLowerCase()) {
    case "link":
      return "link";
    case "button":
      return "button";
    case "textbox":
    case "input":
      return "input";
    case "combobox":
    case "select":
    case "option":
      return "select";
    case "checkbox":
      return "checkbox";
    case "radio":
      return "radio";
    case "tab":
      return "tab";
    case "menuitem":
      return "menuitem";
    case "form":
      return "form";
    default:
      return "unknown";
  }
}

function normalizeHref(href: string, baseUrl: URL) {
  try {
    const url = new URL(href, baseUrl);
    if (url.protocol !== "http:" && url.protocol !== "https:") return null;
    url.hash = "";
    return url.toString();
  } catch {
    return null;
  }
}

function shouldRecordUrl(rawUrl: string) {
  let url: URL;
  try {
    url = new URL(rawUrl);
  } catch {
    return false;
  }

  if (url.protocol !== "http:" && url.protocol !== "https:") return false;
  if (url.hostname === "localhost" || url.hostname === "127.0.0.1") return false;

  const host = url.hostname.toLowerCase();
  const pathAndQuery = `${url.pathname} ${url.search}`.toLowerCase();

  if (
    host === "mail.google.com" ||
    host.startsWith("accounts.") ||
    host.startsWith("login.") ||
    host.includes("passport.") ||
    host.includes("auth.")
  ) {
    return false;
  }

  return !/(^|[/?&=_-])(login|signin|sign-in|auth|oauth|password|checkout|payment|billing|account|profile|inbox|compose)([/?&=_-]|$)/i.test(
    pathAndQuery,
  );
}

function isSuccessfulPayload(payload: Record<string, unknown>) {
  return payload.success === true || payload.success === undefined;
}

function normalizeToolName(name: string) {
  return name.replace(/^mcp__chrome__/, "").replace(/^mcp__[^_]+__/, "");
}

function getNumber(value: unknown, key: string) {
  if (!isRecord(value)) return undefined;
  const child = value[key];
  return typeof child === "number" && Number.isFinite(child) ? child : undefined;
}

function cleanString(value: unknown) {
  if (typeof value !== "string") return undefined;
  const cleaned = value.replace(/[\u0000-\u001f\u007f]/g, " ").trim();
  return cleaned || undefined;
}

function collapseWhitespace(value: string) {
  return value.replace(/\s+/g, " ").trim();
}

function stripTags(value: string) {
  return collapseWhitespace(value.replace(/<[^>]+>/g, " "));
}

function truncate(value: string, maxLength: number) {
  return value.length > maxLength ? `${value.slice(0, maxLength - 3)}...` : value;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}
