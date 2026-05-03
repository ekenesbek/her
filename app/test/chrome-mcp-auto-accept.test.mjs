import test from "node:test";
import assert from "node:assert/strict";

import { chromeExtensionIdFromKey } from "../scripts/browser-runtime.mjs";
import { shouldAttemptChromeMcpAutoAccept } from "../scripts/chrome-mcp-auto-accept.mjs";

test("derives Chrome extension ids from manifest keys", () => {
  assert.equal(
    chromeExtensionIdFromKey("AQID"),
    "adjafimgpcmamlejcmfddlakenbeophh",
  );
});

test("auto-accept attempts only once unless forced", () => {
  assert.equal(shouldAttemptChromeMcpAutoAccept({ marker: null }), true);
  assert.equal(
    shouldAttemptChromeMcpAutoAccept({ marker: { attemptedAt: "2026-04-30T00:00:00.000Z" } }),
    false,
  );
  assert.equal(
    shouldAttemptChromeMcpAutoAccept({
      force: true,
      marker: { attemptedAt: "2026-04-30T00:00:00.000Z" },
    }),
    true,
  );
});
