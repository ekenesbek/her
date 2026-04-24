import type { UserRuntimeLocation } from "@/shared/types";

export const EXACT_LOCATION_STORAGE_KEY = "meta.exact-location.v1";
export const EXACT_LOCATION_CHANGED_EVENT = "meta:exact-location-changed";

type StoredExactLocation = UserRuntimeLocation & {
  source: "browser";
  capturedAt: string;
};

export function readStoredExactLocation(): UserRuntimeLocation | undefined {
  if (typeof window === "undefined") return undefined;

  try {
    const raw = window.localStorage.getItem(EXACT_LOCATION_STORAGE_KEY);
    if (!raw) return undefined;

    const parsed = JSON.parse(raw) as Partial<StoredExactLocation>;
    if (
      parsed.source !== "browser" ||
      typeof parsed.latitude !== "number" ||
      typeof parsed.longitude !== "number" ||
      !Number.isFinite(parsed.latitude) ||
      !Number.isFinite(parsed.longitude)
    ) {
      return undefined;
    }

    return {
      source: "browser",
      latitude: parsed.latitude,
      longitude: parsed.longitude,
      ...(typeof parsed.accuracyMeters === "number" && Number.isFinite(parsed.accuracyMeters)
        ? { accuracyMeters: parsed.accuracyMeters }
        : {}),
      ...(typeof parsed.capturedAt === "string" ? { capturedAt: parsed.capturedAt } : {}),
    };
  } catch {
    return undefined;
  }
}

export function writeStoredExactLocation(location: {
  latitude: number;
  longitude: number;
  accuracyMeters?: number;
}) {
  if (typeof window === "undefined") return;

  const stored: StoredExactLocation = {
    source: "browser",
    latitude: location.latitude,
    longitude: location.longitude,
    ...(typeof location.accuracyMeters === "number" ? { accuracyMeters: location.accuracyMeters } : {}),
    capturedAt: new Date().toISOString(),
  };

  window.localStorage.setItem(EXACT_LOCATION_STORAGE_KEY, JSON.stringify(stored));
  window.dispatchEvent(new Event(EXACT_LOCATION_CHANGED_EVENT));
}

export function clearStoredExactLocation() {
  if (typeof window === "undefined") return;

  window.localStorage.removeItem(EXACT_LOCATION_STORAGE_KEY);
  window.dispatchEvent(new Event(EXACT_LOCATION_CHANGED_EVENT));
}
