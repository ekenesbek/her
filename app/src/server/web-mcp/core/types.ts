export type WebGoalState = "seed" | "queued" | "visited" | "blocked" | "done";

export type WebNoteKind = "general" | "goal" | "plan" | "finding" | "run" | "memory";

export type WebPageLink = {
  url: string;
  text: string;
  rel: string | null;
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
  sourceUrl: string | null;
  goalState: WebGoalState;
  firstVisitedAt: number;
  visitedAt: number;
  observationCount: number;
  artifactDir: string;
  snapshotFile: string;
  layoutFile: string | null;
  linkCount: number;
};

export type WebPageSnapshot = WebPageSummary & {
  links: WebPageLink[];
  layout: string;
};

export type WebEdge = {
  fromUrl: string;
  toUrl: string;
  text: string;
  rel: string | null;
  discoveredAt: number;
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
