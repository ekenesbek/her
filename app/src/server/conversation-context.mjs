const DEFAULT_POLICY = {
  maxContextTokens: 4_500,
  maxRecentMessages: 14,
  maxRecentTokens: 2_700,
  maxRecentMessageTokens: 650,
  maxCompactedTokens: 1_250,
  maxCompactedUserMessages: 24,
  maxCompactedAssistantMessages: 12,
  maxCompactedFacts: 10,
  maxCompactedUserMessageTokens: 140,
  maxCompactedAssistantMessageTokens: 110,
  maxCompactedFactTokens: 100,
  maxRetrievedMessages: 6,
  maxRetrievedTokens: 700,
  maxRetrievedMessageTokens: 140,
  minRetrievalScore: 2.2,
};

const ASSISTANT_PLACEHOLDERS = new Set(["Задача выполняется...", "Task is running..."]);

const FACT_PATTERNS = [
  {
    label: "preference",
    pattern: /(?:предпоч|предпочита|люблю|не люблю|нравится|не нравится|prefer|preference|like|dislike|любимый|favorite)/i,
  },
  {
    label: "constraint",
    pattern: /(?:важно|всегда|никогда|не надо|используй|не используй|по умолчанию|must|should|never|always|default|constraint|do not|don't)/i,
  },
  {
    label: "decision",
    pattern: /(?:решили|выбрали|подтвердил|подтверждаю|согласовал|итог|decision|confirmed|selected|agreed|approved)/i,
  },
  {
    label: "blocker",
    pattern: /(?:заблок|не получилось|ошибка|blocker|blocked|failed|error|cannot|can't|missing|нужен доступ|нет доступа)/i,
  },
  {
    label: "memory",
    pattern: /(?:запомни|запомнил|remember|keep in mind|note that)/i,
  },
];

const STOP_WORDS = new Set([
  "the",
  "and",
  "for",
  "with",
  "that",
  "this",
  "from",
  "you",
  "your",
  "are",
  "was",
  "were",
  "have",
  "has",
  "had",
  "как",
  "что",
  "это",
  "для",
  "или",
  "если",
  "там",
  "тут",
  "мне",
  "тебе",
  "надо",
  "нужно",
  "давай",
  "сделай",
  "сейчас",
  "можно",
  "будет",
  "чтобы",
  "когда",
  "где",
]);

export function buildConversationContext(messages, policy = {}) {
  return buildConversationContextWindow(messages, policy).text;
}

export function buildConversationContextWindow(messages, policy = {}) {
  const resolvedPolicy = { ...DEFAULT_POLICY, ...policy };
  const normalized = normalizeMessages(messages);
  const latestUserMessage = normalizeWhitespace(
    policy.latestUserMessage ?? findLatestUserMessage(normalized) ?? "",
  );
  const recent = normalized.slice(-resolvedPolicy.maxRecentMessages);
  const older = normalized.slice(0, Math.max(0, normalized.length - recent.length));

  const compactedText = buildCompactedContext(older, resolvedPolicy);
  const retrieved = buildRetrievedContext(older, latestUserMessage, resolvedPolicy);
  const preRecentTokens =
    estimateTokenCount(compactedText) +
    estimateTokenCount(retrieved.text) +
    (compactedText && retrieved.text ? 2 : 0);
  const remainingRecentTokens = Math.max(
    0,
    Math.min(resolvedPolicy.maxRecentTokens, resolvedPolicy.maxContextTokens - preRecentTokens),
  );
  const recentText = buildRecentContext(recent, remainingRecentTokens, resolvedPolicy);
  const text = trimToTokenBudget(
    [compactedText, retrieved.text, recentText].filter(Boolean).join("\n\n"),
    resolvedPolicy.maxContextTokens,
  );

  return {
    text,
    strategy: buildStrategy({ compactedText, retrievedText: retrieved.text }),
    estimatedTokens: estimateTokenCount(text),
    tokenBudget: resolvedPolicy.maxContextTokens,
    contextChars: text.length,
    compactedChars: compactedText.length,
    retrievedChars: retrieved.text.length,
    recentChars: recentText.length,
    compactedTokens: estimateTokenCount(compactedText),
    retrievedTokens: estimateTokenCount(retrieved.text),
    recentTokens: estimateTokenCount(recentText),
    totalMessageCount: normalized.length,
    compactedMessageCount: older.length,
    retrievedMessageCount: retrieved.messageCount,
    recentMessageCount: recent.length,
  };
}

export function estimateTokenCount(value) {
  if (!value) return 0;
  const lexicalTokens = tokenizeForBudget(value).length;
  const charEstimate = Math.ceil(value.length / 4);
  const nonAsciiEstimate = /[^\u0000-\u007f]/.test(value) ? Math.ceil(value.length / 3) : 0;
  return Math.max(lexicalTokens, charEstimate, nonAsciiEstimate);
}

export function redactSensitiveText(value) {
  if (typeof value !== "string" || !value) return "";
  return value
    .replace(/\bgithub_pat_[A-Za-z0-9_]{20,}\b/g, "[redacted:github_pat]")
    .replace(/\bgh[pousr]_[A-Za-z0-9_]{20,}\b/g, "[redacted:github_token]")
    .replace(/\bglpat-[A-Za-z0-9_-]{20,}\b/g, "[redacted:gitlab_token]")
    .replace(/\bxox[baprs]-[A-Za-z0-9-]{20,}\b/g, "[redacted:slack_token]")
    .replace(/\bsk-[A-Za-z0-9_-]{20,}\b/g, "[redacted:api_key]")
    .replace(/\bBearer\s+[A-Za-z0-9._~+/=-]{20,}\b/gi, "Bearer [redacted]")
    .replace(/\beyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b/g, "[redacted:jwt]")
    .replace(/\b(cookie|set-cookie|authorization)\s*[:=]\s*(?!Bearer \[redacted\])[^\s;,]+/gi, "$1: [redacted]")
    .replace(/\b(password|passwd|api[_-]?key|secret|client[_-]?secret|access[_-]?token|refresh[_-]?token)\s*[:=]\s*['"]?[^'"\s,;]+/gi, "$1: [redacted]");
}

function buildStrategy({ compactedText, retrievedText }) {
  if (compactedText && retrievedText) return "compacted_summary_plus_retrieval_plus_recent";
  if (compactedText) return "compacted_summary_plus_recent";
  if (retrievedText) return "retrieval_plus_recent";
  return "recent_exact";
}

function normalizeMessages(messages) {
  return messages
    .map((message, index) => ({
      index,
      role: message.role === "assistant" ? "assistant" : "user",
      content: normalizeWhitespace(redactSensitiveText(message.content)),
    }))
    .filter((message) => message.content)
    .filter((message) => message.role !== "assistant" || !ASSISTANT_PLACEHOLDERS.has(message.content));
}

function findLatestUserMessage(messages) {
  return [...messages].reverse().find((message) => message.role === "user")?.content;
}

function buildCompactedContext(messages, policy) {
  if (messages.length === 0 || policy.maxCompactedTokens <= 0) return "";

  const userMessages = takeLastByRole(messages, "user", policy.maxCompactedUserMessages)
    .map((message) => trimToTokenBudget(message.content, policy.maxCompactedUserMessageTokens));
  const assistantMessages = takeLastByRole(messages, "assistant", policy.maxCompactedAssistantMessages)
    .map((message) => trimToTokenBudget(message.content, policy.maxCompactedAssistantMessageTokens));
  const facts = extractFactSignals(messages, policy);

  const sections = [
    `Compacted earlier conversation (${messages.length} older message${messages.length === 1 ? "" : "s"}):`,
    "Use this as lossy memory only. Recent messages below are the source of truth.",
    formatBulletSection("Selected prior user messages and constraints, oldest to newest:", userMessages),
    formatBulletSection("Selected prior assistant outcomes, oldest to newest:", assistantMessages),
    formatBulletSection("Stable facts, preferences, decisions, and blockers detected:", facts),
  ].filter(Boolean);

  return trimSectionsToTokenBudget(sections, policy.maxCompactedTokens);
}

function buildRetrievedContext(messages, latestUserMessage, policy) {
  if (messages.length === 0 || !latestUserMessage || policy.maxRetrievedTokens <= 0) {
    return { text: "", messageCount: 0 };
  }

  const queryTerms = extractSearchTerms(latestUserMessage);
  if (queryTerms.length === 0) return { text: "", messageCount: 0 };

  const scored = messages
    .map((message, index) => ({
      message,
      score: scoreMessageForRetrieval(message, index, messages.length, queryTerms),
    }))
    .filter((entry) => entry.score >= policy.minRetrievalScore)
    .sort((a, b) => b.score - a.score)
    .slice(0, policy.maxRetrievedMessages)
    .sort((a, b) => a.message.index - b.message.index);

  if (scored.length === 0) return { text: "", messageCount: 0 };

  const items = scored.map(({ message, score }) => {
    const content = trimToTokenBudget(message.content, policy.maxRetrievedMessageTokens);
    return `${formatRole(message.role)} [score ${score.toFixed(1)}]: ${content}`;
  });
  const text = trimSectionsToTokenBudget(
    [
      "Retrieved older messages relevant to the latest user message:",
      "Use these only to resolve references; recent messages and the latest user message override them.",
      ...items.map((item) => `- ${item}`),
    ],
    policy.maxRetrievedTokens,
  );

  return { text, messageCount: scored.length };
}

function buildRecentContext(messages, budgetTokens, policy) {
  if (messages.length === 0 || budgetTokens <= 0) return "";

  const formatted = [];
  let remainingTokens = budgetTokens;
  for (const message of [...messages].reverse()) {
    const content = trimToTokenBudget(message.content, policy.maxRecentMessageTokens);
    const entry = `${formatRole(message.role)}: ${content}`;
    if (estimateTokenCount(entry) > remainingTokens && formatted.length > 0) break;
    const clippedEntry = trimToTokenBudget(entry, remainingTokens);
    formatted.push(clippedEntry);
    remainingTokens -= estimateTokenCount(clippedEntry) + 2;
    if (remainingTokens <= 0) break;
  }

  if (formatted.length === 0) return "";
  return [
    "Recent conversation (verbatim except long turns may be clipped, oldest to newest):",
    ...formatted.reverse(),
  ].join("\n\n");
}

function scoreMessageForRetrieval(message, relativeIndex, totalMessages, queryTerms) {
  const contentTerms = new Set(extractSearchTerms(message.content));
  if (contentTerms.size === 0) return 0;

  let overlap = 0;
  for (const term of queryTerms) {
    if (contentTerms.has(term)) overlap += term.length >= 7 ? 1.4 : 1;
  }

  if (overlap === 0) return 0;

  const recencyBoost = totalMessages > 1 ? relativeIndex / (totalMessages - 1) : 0;
  const roleBoost = message.role === "user" ? 0.35 : 0;
  const factBoost = classifyFact(message.content) ? 0.8 : 0;
  return overlap + recencyBoost + roleBoost + factBoost;
}

function extractSearchTerms(value) {
  return dedupePreserveOrder(
    tokenizeForBudget(value)
      .map((token) => token.toLowerCase())
      .filter((token) => token.length >= 3)
      .filter((token) => !STOP_WORDS.has(token))
      .filter((token) => !/^\d+$/.test(token)),
  );
}

function tokenizeForBudget(value) {
  return value.match(/[\p{L}\p{N}_-]+|[^\s\p{L}\p{N}]/gu) ?? [];
}

function takeLastByRole(messages, role, maxItems) {
  if (maxItems <= 0) return [];
  return messages.filter((message) => message.role === role).slice(-maxItems);
}

function extractFactSignals(messages, policy) {
  const facts = [];
  for (const message of messages) {
    const label = classifyFact(message.content);
    if (!label) continue;
    facts.push(`[${label}] ${formatRole(message.role)}: ${trimToTokenBudget(message.content, policy.maxCompactedFactTokens)}`);
  }
  return dedupePreserveOrder(facts).slice(-policy.maxCompactedFacts);
}

function classifyFact(content) {
  return FACT_PATTERNS.find((entry) => entry.pattern.test(content))?.label ?? null;
}

function formatBulletSection(title, items) {
  if (items.length === 0) return "";
  return [title, ...items.map((item) => `- ${item}`)].join("\n");
}

function trimSectionsToTokenBudget(sections, budgetTokens) {
  let remainingTokens = budgetTokens;
  const kept = [];

  for (const section of sections) {
    if (remainingTokens <= 0) break;
    const sectionTokens = estimateTokenCount(section) + (kept.length > 0 ? 2 : 0);
    if (sectionTokens <= remainingTokens) {
      kept.push(section);
      remainingTokens -= sectionTokens;
      continue;
    }

    const clipped = trimToTokenBudget(section, remainingTokens - (kept.length > 0 ? 2 : 0));
    if (clipped) kept.push(clipped);
    break;
  }

  return kept.join("\n\n");
}

function trimToTokenBudget(value, maxTokens) {
  if (maxTokens <= 0 || !value) return "";
  if (estimateTokenCount(value) <= maxTokens) return value;

  const suffix = "...";
  let low = 0;
  let high = value.length;
  let best = "";
  while (low <= high) {
    const mid = Math.floor((low + high) / 2);
    const candidate = `${value.slice(0, mid).trimEnd()}${suffix}`;
    if (estimateTokenCount(candidate) <= maxTokens) {
      best = candidate;
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }

  return best || suffix.slice(0, Math.max(0, maxTokens));
}

function dedupePreserveOrder(values) {
  const seen = new Set();
  const result = [];
  for (const value of values) {
    const key = value.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    result.push(value);
  }
  return result;
}

function formatRole(role) {
  return role === "assistant" ? "Assistant" : "User";
}

function normalizeWhitespace(value) {
  return typeof value === "string" ? value.replace(/\s+/g, " ").trim() : "";
}
