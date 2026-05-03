export const DEFAULT_BROWSER_RUN_MAX_TOKENS_WITHOUT_BROWSER_TOOL = 75_000;
export const DEFAULT_BROWSER_RUN_MAX_TOTAL_TOKENS = 120_000;

const SHELL_TOOL_NAMES = new Set([
  "Shell",
  "shell",
  "exec_command",
  "command_execution",
  "local_shell",
  "functions.exec_command",
]);

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

export function isShellToolName(name) {
  if (typeof name !== "string") return false;
  return SHELL_TOOL_NAMES.has(name) || /\bshell\b/i.test(name) || /\bcommand_execution\b/i.test(name);
}

export function isBrowserToolName(name) {
  if (typeof name !== "string") return false;
  return (
    BROWSER_TOOL_NAMES.has(name) ||
    name.startsWith("mcp__chrome__") ||
    name.startsWith("chrome_") ||
    name.startsWith("browser_")
  );
}

/**
 * @param {{
 *   browserRequired?: boolean;
 *   toolName?: string;
 *   totalTokens?: number;
 *   browserToolCalls?: number;
 *   maxTokensWithoutBrowserTool?: number;
 *   maxTotalTokens?: number;
 * }} [options]
 */
export function getBrowserRunGuardViolation({
  browserRequired,
  toolName,
  totalTokens,
  browserToolCalls = 0,
  maxTokensWithoutBrowserTool = DEFAULT_BROWSER_RUN_MAX_TOKENS_WITHOUT_BROWSER_TOOL,
  maxTotalTokens = DEFAULT_BROWSER_RUN_MAX_TOTAL_TOKENS,
} = {}) {
  if (!browserRequired) return null;

  if (isShellToolName(toolName)) {
    return {
      reason: "shell_tool_for_browser_task",
      message:
        "Browser-задача попыталась использовать Shell вместо Chrome MCP. Остановлено, чтобы не тратить токены в неверном runtime.",
      toolName,
      browserToolCalls,
    };
  }

  if (isFiniteTokenCount(totalTokens) && browserToolCalls <= 0 && totalTokens >= maxTokensWithoutBrowserTool) {
    return {
      reason: "browser_task_no_browser_tool_budget_exceeded",
      message:
        "Browser-задача потратила токен-бюджет, не начав работу через Chrome MCP. Остановлено, чтобы не продолжать неверный маршрут исполнения.",
      totalTokens,
      browserToolCalls,
      maxTokens: maxTokensWithoutBrowserTool,
    };
  }

  if (isFiniteTokenCount(totalTokens) && totalTokens >= maxTotalTokens) {
    return {
      reason: "browser_task_total_budget_exceeded",
      message:
        "Browser-задача превысила общий токен-бюджет. Остановлено, чтобы агент не уходил в дорогой цикл.",
      totalTokens,
      browserToolCalls,
      maxTokens: maxTotalTokens,
    };
  }

  return null;
}

function isFiniteTokenCount(value) {
  return typeof value === "number" && Number.isFinite(value) && value > 0;
}
