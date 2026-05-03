const BROWSER_TOOL_NAMES = new Set([
  "get_windows_and_tabs",
  "search_tabs_content",
  "chrome_read_page",
  "chrome_navigate",
  "chrome_click_element",
  "chrome_fill_or_select",
  "chrome_computer",
  "chrome_request_element_selection",
]);

const RECOVERY_TITLE_RE = /повтор|retry|recovery|fallback|stale|old tab|стара(я|ой) вкладк|попросил пользователя открыть/i;

export function isBrowserToolName(name) {
  if (typeof name !== "string") return false;
  return (
    BROWSER_TOOL_NAMES.has(name) ||
    name.startsWith("mcp__chrome__") ||
    name.startsWith("chrome_") ||
    name.startsWith("browser_")
  );
}

export function isWebMcpRecordEvent(event) {
  return typeof event?.title === "string" && event.title.startsWith("Web MCP recorded:");
}

export function isWebMcpQueryEvent(event) {
  const details = asRecord(event?.details);
  return details?.webMcpQuery === true || details?.webMcpLookup === true;
}

export function isRememberedEdgeUseEvent(event) {
  const details = asRecord(event?.details);
  return details?.rememberedEdgeUsed === true || details?.rememberedFlowUsed === true;
}

export function isRecoveryEvent(event) {
  if (asRecord(event?.details)?.recoveryStep === true) return true;
  return typeof event?.title === "string" && RECOVERY_TITLE_RE.test(event.title);
}

export function summarizeBrowserTaskMetrics({ taskRun = {}, toolTrace = [], events = [] } = {}) {
  const browserToolTrace = toolTrace.filter((entry) => isBrowserToolName(entry?.name));
  const browserToolErrors = browserToolTrace.filter((entry) => entry?.isError === true);
  const recoveryEvents = events.filter(isRecoveryEvent);
  const webMcpRecordEvents = events.filter(isWebMcpRecordEvent);
  const webMcpQueryEvents = events.filter(isWebMcpQueryEvent);
  const rememberedEdgeUseEvents = events.filter(isRememberedEdgeUseEvent);

  return {
    browserToolCalls: browserToolTrace.length,
    browserToolErrors: browserToolErrors.length,
    recoverySteps: browserToolErrors.length + recoveryEvents.length,
    webMcpRecordings: webMcpRecordEvents.length,
    webMcpQueries: webMcpQueryEvents.length,
    rememberedEdgeUses: rememberedEdgeUseEvents.length,
    durationMs: durationFromTaskRun(taskRun),
  };
}

function durationFromTaskRun(taskRun) {
  if (
    typeof taskRun?.startedAt !== "number" ||
    typeof taskRun?.completedAt !== "number" ||
    taskRun.completedAt < taskRun.startedAt
  ) {
    return null;
  }
  return taskRun.completedAt - taskRun.startedAt;
}

function asRecord(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : null;
}

