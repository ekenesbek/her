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
  | "credential_broker"
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
  toolTrace?: ToolTraceEntry[];
  taskRun?: TaskRunSnapshot;
  createdAt: number;
};

export type ToolTraceEntry = {
  id: string;
  name: string;
  input?: unknown;
  result?: unknown;
  artifacts?: TaskArtifact[];
  isError?: boolean;
  startedAt: number;
  completedAt?: number;
};

export type TaskRunStatus =
  | "created"
  | "planning"
  | "running"
  | "waiting_for_user"
  | "done"
  | "failed"
  | "cancelled";

export type TaskEventKind =
  | "status"
  | "tool_call"
  | "tool_result"
  | "screenshot"
  | "error"
  | "message";

export type TaskArtifactKind = "screenshot" | "image" | "trace";

export type TaskArtifact = {
  id: string;
  taskRunId: string;
  kind: TaskArtifactKind;
  label: string;
  mimeType: string;
  byteSize: number;
  url: string;
  createdAt: number;
};

export type TaskEvent = {
  id: string;
  taskRunId: string;
  kind: TaskEventKind;
  title: string;
  status?: TaskRunStatus;
  details?: Record<string, unknown>;
  toolCallId?: string;
  artifactId?: string;
  startedAt?: number;
  completedAt?: number;
  durationMs?: number;
  createdAt: number;
};

export type TaskRunSnapshot = {
  id: string;
  agentId: string;
  status: TaskRunStatus;
  title: string;
  input: string;
  provider: AgentProvider;
  browserSource: BrowserConnection["source"];
  startedAt: number;
  completedAt?: number;
  durationMs?: number;
  events: TaskEvent[];
  artifacts: TaskArtifact[];
};

export type CredentialRequestStatus = "pending" | "approved" | "denied" | "expired" | "used";

export type CredentialRequestedAction =
  | "fill_password"
  | "use_passkey"
  | "reuse_session"
  | "scheduled_read";

export type CredentialRequest = {
  id: string;
  userId: string;
  taskRunId: string;
  agentId: string;
  origin: string;
  currentUrl: string | null;
  accountHint: string | null;
  reason: string;
  requestedAction: CredentialRequestedAction;
  status: CredentialRequestStatus;
  createdAt: number;
  expiresAt: number;
  resolvedAt: number | null;
};

export type BrowserSettings = {
  chromeMcpUrl: string | null;
  createdAt: number | null;
  updatedAt: number | null;
};

export type BrowserConnection = {
  chromeMcpUrl: string | null;
  source: "user" | "env" | "none";
};

export type DecisionMemorySignal = {
  text: string;
  recordedAt: number;
};

export type DecisionMemory = {
  recentSignals: DecisionMemorySignal[];
  updatedAt?: number;
};

export type UserRuntimeLocation = {
  source: "browser" | "edge";
  city?: string;
  region?: string;
  country?: string;
  latitude?: number;
  longitude?: number;
  accuracyMeters?: number;
  capturedAt?: string;
};

export type UserRuntimeMetadata = {
  locale?: string;
  languages?: string[];
  timeZone?: string;
  localTime?: string;
  utcOffsetMinutes?: number;
  calendar?: string;
  hourCycle?: string;
  platform?: string;
  location?: UserRuntimeLocation;
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

export const CAPABILITY_LABELS: Record<Capability, { label: string; hint: string }> = {
  web_search: { label: "Веб-поиск", hint: "Искать в интернете" },
  web_fetch: { label: "Открывать URL", hint: "Читать веб-страницы" },
  chrome_browser: { label: "Chrome с сессиями", hint: "Твой браузер, твои логины" },
  credential_broker: { label: "Парольный брокер", hint: "Запрашивать approve на saved credentials" },
  file_read: { label: "Чтение файлов", hint: "Читать локальные файлы" },
  file_write: { label: "Запись файлов", hint: "Сохранять результаты на диск" },
  shell: { label: "Shell", hint: "Запускать команды в терминале" },
};
