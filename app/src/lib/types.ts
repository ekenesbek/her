export const AGENT_MODELS = [
  "claude-haiku-4-5-20251001",
  "claude-sonnet-4-6",
  "claude-opus-4-7",
  "gpt-5.3-codex",
] as const;

export type AgentModel = (typeof AGENT_MODELS)[number];
export type AgentProvider = "claude" | "codex";

export type Capability =
  | "web_search"
  | "web_fetch"
  | "chrome_browser"
  | "file_read"
  | "file_write"
  | "shell";

export type Agent = {
  id: string;
  name: string;
  emoji: string;
  description: string;
  model: AgentModel;
  systemPrompt: string;
  capabilities: Capability[];
  createdAt: number;
  updatedAt: number;
};

export type AgentDraft = Omit<Agent, "id" | "createdAt" | "updatedAt">;

export type ChatMessage = {
  id: string;
  agentId: string;
  role: "user" | "assistant";
  content: string;
  createdAt: number;
};

export type User = {
  id: string;
  email: string;
  name: string;
  createdAt: number;
  updatedAt: number;
};

export type Session = {
  id: string;
  userId: string;
  createdAt: number;
  expiresAt: number;
};

export type AuthChallengeKind = "registration" | "authentication";

export type AuthChallenge = {
  id: string;
  kind: AuthChallengeKind;
  userId: string | null;
  challenge: string;
  payload: Record<string, unknown>;
  createdAt: number;
  expiresAt: number;
};

export type WebAuthnCredentialRecord = {
  id: string;
  userId: string;
  publicKey: Uint8Array;
  counter: number;
  transports: string[];
  deviceType: "singleDevice" | "multiDevice";
  backedUp: boolean;
  createdAt: number;
  lastUsedAt: number | null;
};

export const MODEL_LABELS: Record<AgentModel, { label: string; hint: string; provider: AgentProvider }> = {
  "claude-haiku-4-5-20251001": { label: "Haiku 4.5", hint: "Claude: быстрый, дешёвый", provider: "claude" },
  "claude-sonnet-4-6": { label: "Sonnet 4.6", hint: "Claude: баланс скорости и качества", provider: "claude" },
  "claude-opus-4-7": { label: "Opus 4.7", hint: "Claude: максимум для сложных задач", provider: "claude" },
  "gpt-5.3-codex": { label: "Codex 5.3", hint: "Codex: код, файлы и терминал", provider: "codex" },
};

export function getModelProvider(model: AgentModel): AgentProvider {
  return MODEL_LABELS[model].provider;
}

export const CAPABILITY_LABELS: Record<Capability, { label: string; hint: string; icon: string }> = {
  web_search: { label: "Веб-поиск", hint: "Искать в интернете", icon: "🔍" },
  web_fetch: { label: "Открывать URL", hint: "Читать веб-страницы", icon: "🌐" },
  chrome_browser: { label: "Chrome с сессиями", hint: "Твой браузер, твои логины", icon: "🧭" },
  file_read: { label: "Чтение файлов", hint: "Читать локальные файлы", icon: "📄" },
  file_write: { label: "Запись файлов", hint: "Сохранять результаты на диск", icon: "💾" },
  shell: { label: "Shell", hint: "Запускать команды в терминале", icon: "⚡" },
};
