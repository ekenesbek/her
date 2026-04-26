export type WebGoalState = "seed" | "queued" | "visited" | "blocked" | "done";

export type WebNoteKind = "general" | "goal" | "plan" | "finding" | "run" | "memory";
export type WebSiteCategory =
  | "unknown"
  | "taxi"
  | "maps"
  | "delivery"
  | "mail"
  | "calendar"
  | "contacts"
  | "chat"
  | "docs"
  | "project"
  | "code"
  | "finance"
  | "social"
  | "media"
  | "search"
  | "shopping"
  | "travel"
  | "weather"
  | "local_services";
export type WebActionKind =
  | "link"
  | "button"
  | "input"
  | "select"
  | "checkbox"
  | "radio"
  | "tab"
  | "menuitem"
  | "form"
  | "navigation"
  | "unknown";
export type WebEdgeStatus = "discovered" | "observed" | "blocked";

export type WebPageLink = {
  url: string;
  text: string;
  rel: string | null;
};

export type WebPageAction = {
  id: string;
  kind: WebActionKind;
  label: string;
  role: string | null;
  text: string;
  href: string | null;
  targetUrl: string | null;
  ref: string | null;
  semanticKey: string;
  source: string;
  confidence: number;
  discoveredAt: number;
  lastObservedAt: number;
  observationCount: number;
};

export type WebPageSummary = {
  url: string;
  canonicalUrl: string;
  pageKey: string;
  pageKind: string;
  title: string;
  host: string;
  siteFamilyHost: string;
  pathname: string;
  statusCode: number | null;
  summary: string;
  plan: string;
  milestoneGoal: string;
  flowPlan: string;
  sourceUrl: string | null;
  goalState: WebGoalState;
  firstVisitedAt: number;
  visitedAt: number;
  observationCount: number;
  artifactDir: string;
  snapshotFile: string;
  layoutFile: string | null;
  linkCount: number;
  actionCount: number;
};

export type WebPageSnapshot = WebPageSummary & {
  links: WebPageLink[];
  actions: WebPageAction[];
  layout: string;
};

export type WebEdge = {
  fromUrl: string;
  toUrl: string;
  text: string;
  rel: string | null;
  discoveredAt: number;
  sourcePageKey?: string;
  targetPageKey?: string;
  actionId?: string | null;
  actionKind?: WebActionKind;
  actionLabel?: string;
  confidence?: number;
  status?: WebEdgeStatus;
  firstObservedAt?: number;
  lastObservedAt?: number;
  observationCount?: number;
};

export type WebNoteSummary = {
  id: string;
  title: string;
  kind: WebNoteKind;
  url: string | null;
  createdAt: number;
  filePath: string;
};

export type WebNote = WebNoteSummary & {
  content: string;
};

export type WebSiteWorkspace = {
  siteKey: string;
  label: string;
  seedUrl: string;
  primaryHost: string;
  goal: string;
  category: WebSiteCategory;
  tags: string[];
  createdAt: number;
  updatedAt: number;
  lastVisitAt: number | null;
  pageCount: number;
  edgeCount: number;
  noteCount: number;
  siteDir: string;
  pagesDir: string;
  notesDir: string;
  memoryFile: string;
  graphFile: string;
};

export type WebSiteDetail = {
  site: WebSiteWorkspace;
  siteMemory: string;
  pages: WebPageSummary[];
  edges: WebEdge[];
  notes: WebNote[];
};
