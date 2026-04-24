import type { Capability } from "@/shared/types";

export function capabilitiesToTools(caps: Capability[]): string[] {
  const tools: string[] = [];
  if (caps.includes("web_search")) tools.push("WebSearch");
  if (caps.includes("web_fetch")) tools.push("WebFetch");
  if (caps.includes("file_read")) tools.push("Read", "Glob", "Grep");
  if (caps.includes("file_write")) tools.push("Write", "Edit");
  if (caps.includes("shell")) tools.push("Bash");
  return tools;
}
