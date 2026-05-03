import test from "node:test";
import assert from "node:assert/strict";

import {
  buildConversationContext,
  buildConversationContextWindow,
  estimateTokenCount,
  redactSensitiveText,
} from "../src/server/conversation-context.mjs";

test("compacts older turns, retrieves relevant older turns, and keeps recent turns available", () => {
  const messages = [
    { role: "user", content: "Запомни: я предпочитаю короткие ответы по делу." },
    { role: "assistant", content: "Запомнил предпочтение по стилю." },
    { role: "user", content: "Old task one about billing dashboard invoices" },
    { role: "assistant", content: "Old answer one about invoices" },
    { role: "user", content: "Old task two about unrelated deployment" },
    { role: "assistant", content: "Old answer two about deployment" },
    { role: "user", content: "Recent question" },
    { role: "assistant", content: "Recent answer" },
  ];

  const window = buildConversationContextWindow(messages, {
    latestUserMessage: "Вернись к invoices из billing dashboard",
    maxRecentMessages: 2,
    maxCompactedTokens: 2_000,
    maxRecentTokens: 2_000,
    maxRetrievedTokens: 800,
  });

  assert.equal(window.strategy, "compacted_summary_plus_retrieval_plus_recent");
  assert.equal(window.compactedMessageCount, 6);
  assert.ok(window.retrievedMessageCount > 0);
  assert.equal(window.recentMessageCount, 2);
  assert.match(window.text, /Compacted earlier conversation/);
  assert.match(window.text, /Retrieved older messages relevant to the latest user message:/);
  assert.match(window.text, /Stable facts, preferences, decisions, and blockers detected:/);
  assert.match(window.text, /\[preference\] User: Запомни: я предпочитаю короткие ответы по делу\./);
  assert.match(window.text, /billing dashboard invoices/);
  assert.match(window.text, /Recent conversation \(verbatim except long turns may be clipped, oldest to newest\):/);
  assert.match(window.text, /User: Recent question/);
  assert.match(window.text, /Assistant: Recent answer/);
});

test("drops transient assistant placeholders from model context", () => {
  const context = buildConversationContext([
    { role: "user", content: "Do the thing" },
    { role: "assistant", content: "Задача выполняется..." },
    { role: "user", content: "What happened?" },
  ]);

  assert.match(context, /Do the thing/);
  assert.match(context, /What happened\?/);
  assert.doesNotMatch(context, /Задача выполняется/);
});

test("respects configured context budget", () => {
  const messages = Array.from({ length: 20 }, (_, index) => ({
    role: index % 2 === 0 ? "user" : "assistant",
    content: `Message ${index} ${"x".repeat(300)}`,
  }));

  const window = buildConversationContextWindow(messages, {
    maxContextTokens: 300,
    maxRecentMessages: 6,
    maxCompactedTokens: 120,
    maxRecentTokens: 180,
    maxRecentMessageTokens: 70,
  });

  assert.ok(window.estimatedTokens <= 300);
  assert.ok(window.compactedMessageCount > 0);
  assert.ok(window.recentMessageCount <= 6);
});

test("redacts secrets before conversation context is built", () => {
  const secret = "github_pat_" + "a".repeat(30);
  const context = buildConversationContext([
    { role: "user", content: `Use token ${secret} and password=hunter2` },
  ]);

  assert.match(context, /\[redacted:github_pat\]/);
  assert.match(context, /password: \[redacted\]/);
  assert.doesNotMatch(context, new RegExp(secret));
  assert.equal(redactSensitiveText(`Authorization: Bearer ${"x".repeat(30)}`), "Authorization: Bearer [redacted]");
});

test("token estimator grows with text size and handles non-ascii text", () => {
  assert.ok(estimateTokenCount("short text") > 0);
  assert.ok(estimateTokenCount("короткий русский текст") > 0);
  assert.ok(estimateTokenCount("x".repeat(800)) > estimateTokenCount("x".repeat(80)));
});
