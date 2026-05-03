import test from "node:test";
import assert from "node:assert/strict";

import {
  getBrowserRunGuardViolation,
  isBrowserToolName,
  isShellToolName,
} from "../src/server/browser-run-guard.mjs";

test("classifies shell-like tools as forbidden for browser runs", () => {
  assert.equal(isShellToolName("Shell"), true);
  assert.equal(isShellToolName("command_execution"), true);
  assert.equal(isShellToolName("functions.exec_command"), true);
  assert.equal(isShellToolName("mcp__chrome__chrome_read_page"), false);
});

test("classifies Chrome MCP tools as browser tools", () => {
  assert.equal(isBrowserToolName("mcp__chrome__chrome_read_page"), true);
  assert.equal(isBrowserToolName("chrome_navigate"), true);
  assert.equal(isBrowserToolName("get_windows_and_tabs"), true);
  assert.equal(isBrowserToolName("Shell"), false);
});

test("does not guard non-browser runs", () => {
  assert.equal(getBrowserRunGuardViolation({ browserRequired: false, toolName: "Shell" }), null);
});

test("stops browser runs on shell tools", () => {
  assert.equal(
    getBrowserRunGuardViolation({ browserRequired: true, toolName: "Shell" })?.reason,
    "shell_tool_for_browser_task",
  );
});

test("stops browser runs that spend budget before using browser tools", () => {
  assert.equal(
    getBrowserRunGuardViolation({
      browserRequired: true,
      totalTokens: 75_000,
      browserToolCalls: 0,
    })?.reason,
    "browser_task_no_browser_tool_budget_exceeded",
  );
});

test("allows browser runs under budget after browser tool use", () => {
  assert.equal(
    getBrowserRunGuardViolation({
      browserRequired: true,
      totalTokens: 80_000,
      browserToolCalls: 2,
    }),
    null,
  );
});

test("stops browser runs that exceed total budget even after browser tool use", () => {
  assert.equal(
    getBrowserRunGuardViolation({
      browserRequired: true,
      totalTokens: 120_000,
      browserToolCalls: 2,
    })?.reason,
    "browser_task_total_budget_exceeded",
  );
});
