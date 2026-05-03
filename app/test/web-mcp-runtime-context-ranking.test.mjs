import test from "node:test";
import assert from "node:assert/strict";

import {
  rankWebSitesForGoal,
  scoreWebSiteForGoal,
  tokenizeGoal,
} from "../src/server/web-mcp/product/runtime-context-ranking.mjs";

const now = Date.now();

function site(overrides) {
  return {
    siteKey: overrides.siteKey,
    label: overrides.label,
    seedUrl: overrides.seedUrl ?? `https://${overrides.primaryHost}`,
    primaryHost: overrides.primaryHost,
    goal: overrides.goal ?? "",
    category: overrides.category ?? "unknown",
    tags: overrides.tags ?? [],
    updatedAt: overrides.updatedAt ?? now,
    lastVisitAt: overrides.lastVisitAt ?? now,
  };
}

test("tokenizeGoal keeps English and Russian goal terms", () => {
  assert.deepEqual(tokenizeGoal("Открой GitHub settings и найди tokens"), [
    "открой",
    "github",
    "settings",
    "найди",
    "tokens",
  ]);
});

test("ranks sites by metadata overlap before recency", () => {
  const github = site({
    siteKey: "github",
    primaryHost: "github.com",
    label: "GitHub",
    category: "code",
    tags: ["token", "repo"],
    updatedAt: now - 10_000_000,
    lastVisitAt: now - 10_000_000,
  });
  const recentMail = site({
    siteKey: "mail",
    primaryHost: "google.com",
    label: "Gmail",
    category: "mail",
  });

  const ranked = rankWebSitesForGoal([recentMail, github], "Open GitHub settings personal access token", 1);

  assert.equal(ranked[0].siteKey, "github");
  assert.equal(scoreWebSiteForGoal(github, "github token") > scoreWebSiteForGoal(recentMail, "github token"), true);
});

test("ranks user-observed tags for Russian browser goals", () => {
  const taxi = site({
    siteKey: "taxi",
    primaryHost: "yandex.ru",
    label: "Yandex Go",
    category: "local-service",
    tags: ["маршрут", "такси", "тариф"],
  });
  const docs = site({
    siteKey: "docs",
    primaryHost: "notion.so",
    label: "Notion",
    category: "docs",
  });

  const ranked = rankWebSitesForGoal([docs, taxi], "Построй маршрут такси и покажи тариф", 1);

  assert.equal(ranked[0].siteKey, "taxi");
});

test("falls back to recency when goal has no site signal", () => {
  const oldSite = site({
    siteKey: "old",
    primaryHost: "old.example.com",
    updatedAt: now - 30 * 86_400_000,
    lastVisitAt: now - 30 * 86_400_000,
  });
  const recentSite = site({
    siteKey: "recent",
    primaryHost: "recent.example.com",
    updatedAt: now,
    lastVisitAt: now,
  });

  const ranked = rankWebSitesForGoal([oldSite, recentSite], "", 1);

  assert.equal(ranked[0].siteKey, "recent");
});
