import {
  clipWebMemoryForPrompt,
  extractTimestampedMemoryEntries,
  listWebSites,
  readOrInitCommonWebMemory,
  readOrInitWebSiteMemory,
  summarizeWebSitePagePatterns,
} from "./storage";

export function buildWebMcpRuntimeContext(userId: string, autoRecording: boolean) {
  const sites = listWebSites(userId).slice(0, 10);
  const commonMemory = clipWebMemoryForPrompt(
    extractTimestampedMemoryEntries(readOrInitCommonWebMemory(userId)) || "(none yet)",
  );
  const lines = [
    "Web MCP memory is available for browser/web tasks.",
    `User-scoped root: .data/web-mcp/users/${userId}/`,
    `Common Web MCP memory file: .data/web-mcp/users/${userId}/common.md`,
    `Site workspaces root: .data/web-mcp/users/${userId}/sites/`,
    autoRecording
      ? "The app runtime automatically records supported public-page Chrome MCP observations into Web MCP memory. To feed that recorder, after landing on a public page call chrome_get_web_content with textContent=true or chrome_read_page; do not manually create Web MCP files unless the user asks."
      : "When mapping a website without Chrome MCP, persist site memory by writing snapshots/layout/notes under the Web MCP root.",
    "Before revisiting a site, use the known Web MCP site index below to avoid rediscovering the same navigation and facts.",
    "Known page patterns are canonical instructions, not a log of every URL. Treat URLs that differ only by volatile route/map/search state as the same page pattern and update the existing snapshot.",
    "Use common Web MCP memory for durable cross-site facts such as home/work address, city, transport preferences, preferred services, and recurring constraints.",
    "Use site Web MCP memory only for facts tied to a specific website/account/workflow.",
    "If a durable fact needed for the task is missing, ask the user once. When the user supplies it, persist it so future agents do not ask again.",
    "Do not infer home/work addresses from current GPS, browser tabs, or route history. Persist those only when the user explicitly states or confirms them.",
    "To update common Web MCP memory, include a hidden tagged block in the final answer: <remember-web-common>short durable fact</remember-web-common>. The app strips the tag and mirrors the fact into identity user.md.",
    "To update per-site memory, include: <remember-web-site url=\"https://example.com\" title=\"short label\">short site-specific fact</remember-web-site>. Use the site's origin or current page URL.",
    "Do not store passwords, tokens, cookies, MFA codes, payment card data, or one-time page state in Web MCP memory.",
    "=== common.md durable entries ===",
    commonMemory,
    "=== end common.md durable entries ===",
  ];

  if (sites.length === 0) {
    lines.push("Known Web MCP sites: none yet.");
  } else {
    lines.push("Known Web MCP sites:");
    for (const site of sites) {
      lines.push(
        [
          `- ${site.primaryHost}`,
          `label=${site.label}`,
          `pages=${site.pageCount}`,
          `edges=${site.edgeCount}`,
          `notes=${site.noteCount}`,
          `lastVisit=${site.lastVisitAt ? new Date(site.lastVisitAt).toISOString() : "never"}`,
          `seed=${site.seedUrl}`,
          `memoryFile=${site.memoryFile}`,
        ].join("; "),
      );
      const siteMemory = site.siteKey
        ? extractTimestampedMemoryEntries(readOrInitWebSiteMemory(userId, site.siteKey) ?? "", 8)
        : "";
      if (siteMemory) {
        lines.push(clipWebMemoryForPrompt(indentBlock(siteMemory), 2_000));
      }
      const pagePatterns = summarizeWebSitePagePatterns(userId, site.siteKey, 5);
      if (pagePatterns.length > 0) {
        lines.push("  Known page patterns:");
        for (const pattern of pagePatterns) {
          lines.push(`  - ${pattern}`);
        }
      }
    }
  }

  return lines.join("\n");
}

function indentBlock(value: string) {
  return value
    .split(/\r?\n/)
    .map((line) => `  ${line}`)
    .join("\n");
}
