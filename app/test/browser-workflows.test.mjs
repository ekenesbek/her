import test from "node:test";
import assert from "node:assert/strict";

import {
  buildBrowserWorkflowRuntimeContext,
  detectBrowserWorkflow,
} from "../src/server/browser-workflows.mjs";

test("detects taxi and ride-hailing order requests", () => {
  assert.deepEqual(detectBrowserWorkflow("Закажи такси домой мне"), {
    kind: "ride_hailing",
    destinationAlias: "home",
  });
  assert.equal(detectBrowserWorkflow("book a taxi to the office")?.kind, "ride_hailing");
});

test("does not detect unrelated browser tasks as ride-hailing", () => {
  assert.equal(detectBrowserWorkflow("отправь письмо в gmail"), null);
  assert.equal(detectBrowserWorkflow("что это нам даст?"), null);
});

test("builds ride-hailing runtime context that uses exact location and stops before final order", () => {
  const context = buildBrowserWorkflowRuntimeContext({
    latestUserMessage: "Закажи такси домой мне",
    exactBrowserLocationPresent: true,
  });

  assert.match(context, /Workflow hint: ride-hailing/);
  assert.match(context, /exact browser location is already available/);
  assert.match(context, /Resolve it from confirmed user memory/);
  assert.match(context, /Do not assume a single fixed provider/);
  assert.match(context, /never click the final order/);
});

test("asks only for pickup when exact location is missing", () => {
  const context = buildBrowserWorkflowRuntimeContext({
    latestUserMessage: "Закажи такси",
    exactBrowserLocationPresent: false,
  });

  assert.match(context, /ask one concise pickup question/);
});
