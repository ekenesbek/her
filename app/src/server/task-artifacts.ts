import fs from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { appendTaskEvent, createTaskArtifact } from "./db";
import type { TaskArtifact, TaskEvent } from "@/shared/types";

const TASK_ARTIFACT_ROOT = path.join(process.cwd(), ".data", "task-runs");

type PersistedToolArtifacts = {
  artifacts: TaskArtifact[];
  events: TaskEvent[];
};

type ImageBlock = {
  base64: string;
  mimeType: string;
};

export function resolveTaskArtifactPath(storagePath: string) {
  const resolved = path.resolve(TASK_ARTIFACT_ROOT, storagePath);
  const root = path.resolve(TASK_ARTIFACT_ROOT);

  if (resolved !== root && !resolved.startsWith(`${root}${path.sep}`)) {
    throw new Error("Invalid artifact path");
  }

  return resolved;
}

export function persistToolResultArtifacts({
  taskRunId,
  userId,
  toolCallId,
  toolName,
  result,
}: {
  taskRunId: string;
  userId: string;
  toolCallId: string;
  toolName: string;
  result: unknown;
}): PersistedToolArtifacts {
  const imageBlocks = extractImageBlocks(result);
  if (imageBlocks.length === 0) return { artifacts: [], events: [] };

  const dir = resolveTaskArtifactPath(taskRunId);
  fs.mkdirSync(dir, { recursive: true });

  const artifacts: TaskArtifact[] = [];
  const events: TaskEvent[] = [];

  imageBlocks.forEach((image, index) => {
    const bytes = Buffer.from(image.base64, "base64");
    const fileName = `${randomUUID()}${extensionForMimeType(image.mimeType)}`;
    const relativePath = path.join(taskRunId, fileName);
    fs.writeFileSync(resolveTaskArtifactPath(relativePath), bytes);

    const artifact = createTaskArtifact({
      taskRunId,
      userId,
      kind: "screenshot",
      label: imageBlocks.length === 1 ? `Скриншот из ${toolName}` : `Скриншот ${index + 1} из ${toolName}`,
      mimeType: image.mimeType,
      byteSize: bytes.byteLength,
      storagePath: relativePath,
    });

    if (!artifact) return;
    artifacts.push(artifact);

    const event = appendTaskEvent({
      taskRunId,
      userId,
      kind: "screenshot",
      title: `Скриншот сохранён: ${toolName}`,
      details: {
        mimeType: image.mimeType,
        byteSize: bytes.byteLength,
      },
      toolCallId,
      artifactId: artifact.id,
    });

    if (event) events.push(event);
  });

  return { artifacts, events };
}

function extractImageBlocks(value: unknown): ImageBlock[] {
  const blocks = collectBlocks(value);
  const images: ImageBlock[] = [];

  for (const block of blocks) {
    if (!isRecord(block) || block.type !== "image") continue;

    if (typeof block.data === "string") {
      images.push({
        base64: block.data,
        mimeType: typeof block.mimeType === "string" ? block.mimeType : "image/png",
      });
      continue;
    }

    if (isRecord(block.source) && block.source.type === "base64" && typeof block.source.data === "string") {
      images.push({
        base64: block.source.data,
        mimeType: typeof block.source.media_type === "string" ? block.source.media_type : "image/png",
      });
    }
  }

  return images;
}

function collectBlocks(value: unknown): unknown[] {
  if (Array.isArray(value)) return value.flatMap(collectBlocks);
  if (!isRecord(value)) return [];
  if (value.type === "image") return [value];
  if (Array.isArray(value.content)) return value.content.flatMap(collectBlocks);
  if (Array.isArray(value.result)) return value.result.flatMap(collectBlocks);
  return [];
}

function extensionForMimeType(mimeType: string) {
  if (mimeType === "image/jpeg") return ".jpg";
  if (mimeType === "image/webp") return ".webp";
  if (mimeType === "image/gif") return ".gif";
  return ".png";
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}
