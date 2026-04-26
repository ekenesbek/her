import { z } from "zod";
import { AGENT_MODELS } from "./types";

const capabilitySchema = z.enum([
  "web_search",
  "web_fetch",
  "chrome_browser",
  "credential_broker",
  "file_read",
  "file_write",
  "shell",
]);

const modelSchema = z.enum(AGENT_MODELS);

const emailSchema = z.string().trim().email().max(320).transform((value) => value.toLowerCase());

export const agentDraftSchema = z.object({
  name: z.string().min(1).max(100),
  emoji: z.string().max(1_000_000),
  description: z.string().max(500),
  model: modelSchema,
  systemPrompt: z.string().max(10000),
  capabilities: z.array(capabilitySchema),
});

export const agentPatchSchema = agentDraftSchema.partial();

export const browserSettingsPatchSchema = z.object({
  chromeMcpUrl: z.union([z.string().trim().url(), z.literal(""), z.null()]).optional(),
});

export const passkeyRegistrationStartSchema = z.object({
  email: emailSchema,
  name: z.string().trim().max(80).optional(),
});

export const passkeyAuthenticationStartSchema = z.object({
  email: emailSchema.optional(),
});

export const passkeyFinishSchema = z.object({
  challengeId: z.string().min(1),
  response: z.record(z.string(), z.unknown()),
});

const webNoteKindSchema = z.enum(["general", "goal", "plan", "finding", "run", "memory"]);
const webGoalStateSchema = z.enum(["seed", "queued", "visited", "blocked", "done"]);
const webSiteCategorySchema = z.enum([
  "unknown",
  "taxi",
  "maps",
  "delivery",
  "mail",
  "calendar",
  "contacts",
  "chat",
  "docs",
  "project",
  "code",
  "finance",
  "social",
  "media",
  "search",
  "shopping",
  "travel",
  "weather",
  "local_services",
]);
const webActionKindSchema = z.enum([
  "link",
  "button",
  "input",
  "select",
  "checkbox",
  "radio",
  "tab",
  "menuitem",
  "form",
  "navigation",
  "unknown",
]);

export const webSiteCreateSchema = z.object({
  url: z.string().trim().url(),
  label: z.string().trim().max(120).optional(),
  goal: z.string().trim().max(2000).optional(),
  category: webSiteCategorySchema.optional(),
  tags: z.array(z.string().trim().min(1).max(40)).max(20).optional(),
});

export const webPageLinkSchema = z.object({
  url: z.string().trim().url(),
  text: z.string().max(1000).default(""),
  rel: z.string().trim().max(120).nullable().optional(),
});

export const webPageActionSchema = z.object({
  id: z.string().trim().max(120).optional(),
  kind: webActionKindSchema.optional(),
  label: z.string().trim().max(1000).optional(),
  role: z.string().trim().max(120).nullable().optional(),
  text: z.string().trim().max(1000).optional(),
  href: z.string().trim().max(2000).nullable().optional(),
  targetUrl: z.string().trim().url().nullable().optional(),
  ref: z.string().trim().max(160).nullable().optional(),
  semanticKey: z.string().trim().max(500).optional(),
  source: z.string().trim().max(120).optional(),
  confidence: z.number().min(0).max(1).optional(),
});

export const webPageSnapshotSchema = z.object({
  url: z.string().trim().url(),
  title: z.string().max(500).optional(),
  statusCode: z.number().int().min(100).max(599).nullable().optional(),
  summary: z.string().max(10000).optional(),
  layout: z.string().max(40000).optional(),
  links: z.array(webPageLinkSchema).max(1000).optional(),
  actions: z.array(webPageActionSchema).max(1000).optional(),
  sourceUrl: z.string().trim().url().nullable().optional(),
  plan: z.string().max(10000).optional(),
  milestoneGoal: z.string().max(5000).optional(),
  flowPlan: z.string().max(10000).optional(),
  goalState: webGoalStateSchema.optional(),
});

export const webNoteSchema = z.object({
  title: z.string().trim().min(1).max(200),
  content: z.string().trim().min(1).max(50000),
  kind: webNoteKindSchema.optional(),
  url: z.string().trim().url().nullable().optional(),
});

export const credentialRequestDecisionSchema = z.object({
  decision: z.enum(["approve", "deny"]),
});
