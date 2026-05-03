import test from "node:test";
import assert from "node:assert/strict";

import {
  matchesBrowserGroundedTask,
  normalizeTaskText,
} from "../src/server/browser-task-policy.mjs";

test("normalizes task text for policy matching", () => {
  assert.equal(normalizeTaskText("  Закажи   ТАКСИ  "), "закажи такси");
});

test("treats order and booking requests as external browser actions", () => {
  assert.equal(matchesBrowserGroundedTask("Закажи такси"), true);
  assert.equal(matchesBrowserGroundedTask("закажи пиццу"), true);
  assert.equal(matchesBrowserGroundedTask("book a hotel for tomorrow"), true);
});

test("does not treat unrelated short chat as browser grounded", () => {
  assert.equal(matchesBrowserGroundedTask("m"), false);
  assert.equal(matchesBrowserGroundedTask("что это нам даст?"), false);
  assert.equal(matchesBrowserGroundedTask("напиши план улучшений"), false);
});

test("keeps logged-in communication tasks browser grounded", () => {
  assert.equal(matchesBrowserGroundedTask("Напиши в телеграмме magzhanу салам"), true);
  assert.equal(matchesBrowserGroundedTask("отправь письмо в gmail"), true);
  assert.equal(matchesBrowserGroundedTask("send a message to alex in workspace chat"), true);
});

test("keeps route and ETA questions browser grounded", () => {
  assert.equal(matchesBrowserGroundedTask("Сколько мне ехать до дома?"), true);
  assert.equal(matchesBrowserGroundedTask("Построй маршрут до офиса"), true);
});
