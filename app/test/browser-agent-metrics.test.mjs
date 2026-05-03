import test from "node:test";
import assert from "node:assert/strict";

import {
  isBrowserToolName,
  isRecoveryEvent,
  isRememberedEdgeUseEvent,
  isWebMcpQueryEvent,
  isWebMcpRecordEvent,
  summarizeBrowserTaskMetrics,
} from "../src/server/browser-agent-metrics.mjs";

test("classifies Chrome MCP and browser tool names", () => {
  assert.equal(isBrowserToolName("mcp__chrome__chrome_read_page"), true);
  assert.equal(isBrowserToolName("chrome_click_element"), true);
  assert.equal(isBrowserToolName("get_windows_and_tabs"), true);
  assert.equal(isBrowserToolName("browser_snapshot"), true);
  assert.equal(isBrowserToolName("Shell"), false);
  assert.equal(isBrowserToolName("web_search"), false);
});

test("classifies Web MCP recording/query and remembered edge events", () => {
  assert.equal(isWebMcpRecordEvent({ title: "Web MCP recorded: github.com/settings" }), true);
  assert.equal(isWebMcpRecordEvent({ title: "Memory updated" }), false);

  assert.equal(isWebMcpQueryEvent({ details: { webMcpQuery: true } }), true);
  assert.equal(isWebMcpQueryEvent({ details: { webMcpLookup: true } }), true);
  assert.equal(isWebMcpQueryEvent({ details: { webMcpQuery: false } }), false);

  assert.equal(isRememberedEdgeUseEvent({ details: { rememberedEdgeUsed: true } }), true);
  assert.equal(isRememberedEdgeUseEvent({ details: { rememberedFlowUsed: true } }), true);
  assert.equal(isRememberedEdgeUseEvent({ details: { rememberedEdgeUsed: false } }), false);
});

test("classifies browser recovery events from explicit flags and retry titles", () => {
  assert.equal(isRecoveryEvent({ details: { recoveryStep: true } }), true);
  assert.equal(isRecoveryEvent({ title: "Повтор: агент ответил по старой вкладке" }), true);
  assert.equal(isRecoveryEvent({ title: "Retry: stale page action" }), true);
  assert.equal(isRecoveryEvent({ title: "Готово: chrome_read_page" }), false);
});

test("summarizes phase-0 browser memory metrics from task trace", () => {
  const metrics = summarizeBrowserTaskMetrics({
    taskRun: {
      startedAt: 1_000,
      completedAt: 7_500,
    },
    toolTrace: [
      {
        id: "1",
        name: "mcp__chrome__chrome_read_page",
        startedAt: 1_100,
        completedAt: 1_400,
      },
      {
        id: "2",
        name: "chrome_click_element",
        startedAt: 1_500,
        completedAt: 1_700,
        isError: true,
      },
      {
        id: "3",
        name: "Shell",
        startedAt: 2_000,
        completedAt: 2_500,
      },
    ],
    events: [
      {
        title: "Web MCP lookup",
        details: { webMcpQuery: true },
      },
      {
        title: "Web MCP recorded: github.com/settings",
        details: { siteKey: "github-com" },
      },
      {
        title: "Used remembered checkout edge",
        details: { rememberedEdgeUsed: true },
      },
      {
        title: "Повтор: агент попросил пользователя открыть браузерную вкладку",
      },
    ],
  });

  assert.deepEqual(metrics, {
    browserToolCalls: 2,
    browserToolErrors: 1,
    recoverySteps: 2,
    webMcpRecordings: 1,
    webMcpQueries: 1,
    rememberedEdgeUses: 1,
    durationMs: 6_500,
  });
});

test("returns null duration when task timing is incomplete or invalid", () => {
  assert.equal(summarizeBrowserTaskMetrics({ taskRun: { startedAt: 10 } }).durationMs, null);
  assert.equal(summarizeBrowserTaskMetrics({ taskRun: { startedAt: 20, completedAt: 10 } }).durationMs, null);
});

