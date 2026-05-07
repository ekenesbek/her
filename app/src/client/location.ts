import type { UserRuntimeLocation } from "@/shared/types";

export const EXACT_LOCATION_STORAGE_KEY = "her.exact-location.v1";
export const EXACT_LOCATION_MODE_STORAGE_KEY = "her.exact-location-mode.v1";
export const EXACT_LOCATION_CHANGED_EVENT = "her:exact-location-changed";
export const EXACT_LOCATION_AUTO_REQUESTED_KEY = "her.exact-location-auto-requested.v1";
const SEND_REFRESH_TIMEOUT_MS = 4_000;
const INITIAL_LOCATION_REQUEST_TIMEOUT_MS = 10_000;

export type ExactLocationMode = "off" | "once" | "while_using" | "always";

type StoredExactLocation = UserRuntimeLocation & {
  source: "browser";
  capturedAt: string;
};

function notifyLocationChanged() {
  window.dispatchEvent(new Event(EXACT_LOCATION_CHANGED_EVENT));
}

export function readExactLocationMode(): ExactLocationMode {
  if (typeof window === "undefined") return "off";

  try {
    const sessionValue = window.sessionStorage.getItem(EXACT_LOCATION_MODE_STORAGE_KEY);
    if (sessionValue === "while_using") return sessionValue;

    const value = window.localStorage.getItem(EXACT_LOCATION_MODE_STORAGE_KEY);
    if (value === "once" || value === "always") return value;

    if (window.localStorage.getItem(EXACT_LOCATION_STORAGE_KEY)) {
      window.localStorage.setItem(EXACT_LOCATION_MODE_STORAGE_KEY, "always");
      return "always";
    }
  } catch {
    return "off";
  }

  return "off";
}

export function writeExactLocationMode(mode: ExactLocationMode) {
  if (typeof window === "undefined") return;

  window.localStorage.removeItem(EXACT_LOCATION_MODE_STORAGE_KEY);
  window.sessionStorage.removeItem(EXACT_LOCATION_MODE_STORAGE_KEY);

  if (mode === "off") {
    window.localStorage.removeItem(EXACT_LOCATION_STORAGE_KEY);
    window.sessionStorage.removeItem(EXACT_LOCATION_STORAGE_KEY);
  } else if (mode === "while_using") {
    window.sessionStorage.setItem(EXACT_LOCATION_MODE_STORAGE_KEY, mode);
  } else {
    window.localStorage.setItem(EXACT_LOCATION_MODE_STORAGE_KEY, mode);
  }
  notifyLocationChanged();
}

export function readStoredExactLocation(): UserRuntimeLocation | undefined {
  if (typeof window === "undefined") return undefined;

  const mode = readExactLocationMode();
  if (mode === "off") return undefined;

  try {
    const storage = mode === "while_using" ? window.sessionStorage : window.localStorage;
    const raw = storage.getItem(EXACT_LOCATION_STORAGE_KEY);
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
}, mode: Exclude<ExactLocationMode, "off"> = "once"): UserRuntimeLocation | undefined {
  if (typeof window === "undefined") return undefined;

  const stored: StoredExactLocation = {
    source: "browser",
    latitude: location.latitude,
    longitude: location.longitude,
    ...(typeof location.accuracyMeters === "number" ? { accuracyMeters: location.accuracyMeters } : {}),
    capturedAt: new Date().toISOString(),
  };

  window.localStorage.removeItem(EXACT_LOCATION_STORAGE_KEY);
  window.localStorage.removeItem(EXACT_LOCATION_MODE_STORAGE_KEY);
  window.sessionStorage.removeItem(EXACT_LOCATION_STORAGE_KEY);
  window.sessionStorage.removeItem(EXACT_LOCATION_MODE_STORAGE_KEY);

  const storage = mode === "while_using" ? window.sessionStorage : window.localStorage;
  storage.setItem(EXACT_LOCATION_STORAGE_KEY, JSON.stringify(stored));
  storage.setItem(EXACT_LOCATION_MODE_STORAGE_KEY, mode);
  notifyLocationChanged();
  return stored;
}

export function clearStoredExactLocation() {
  if (typeof window === "undefined") return;

  window.localStorage.removeItem(EXACT_LOCATION_STORAGE_KEY);
  window.localStorage.removeItem(EXACT_LOCATION_MODE_STORAGE_KEY);
  window.sessionStorage.removeItem(EXACT_LOCATION_STORAGE_KEY);
  window.sessionStorage.removeItem(EXACT_LOCATION_MODE_STORAGE_KEY);
  notifyLocationChanged();
}

export async function captureCurrentExactLocation(
  options: PositionOptions = {},
  mode: Exclude<ExactLocationMode, "off"> = "once",
): Promise<UserRuntimeLocation> {
  if (typeof window === "undefined" || !("geolocation" in navigator)) {
    throw new Error("geolocation_unavailable");
  }

  const position = await getCurrentPosition(options);
  const stored = writeStoredExactLocation({
    latitude: position.coords.latitude,
    longitude: position.coords.longitude,
    accuracyMeters: position.coords.accuracy,
  }, mode);

  if (!stored) throw new Error("geolocation_not_stored");
  return stored;
}

export function readRuntimeExactLocation(): UserRuntimeLocation | undefined {
  const mode = readExactLocationMode();
  if (mode === "off") return undefined;

  const stored = readStoredExactLocation();
  if (!stored) return undefined;

  if (mode === "once") {
    clearStoredExactLocation();
  }

  return stored;
}

export async function refreshSharedExactLocation(): Promise<UserRuntimeLocation | undefined> {
  const mode = readExactLocationMode();
  if (mode === "off") return undefined;

  const stored = readStoredExactLocation();
  if (typeof window === "undefined" || !("geolocation" in navigator)) return stored;

  if (!stored) {
    const permission = await getGeolocationPermissionState();
    if (permission !== "granted") return undefined;
  }

  try {
    return await captureCurrentExactLocation({
      enableHighAccuracy: true,
      maximumAge: 15_000,
      timeout: SEND_REFRESH_TIMEOUT_MS,
    }, mode);
  } catch {
    return stored;
  }
}

export async function requestAlwaysExactLocationOnce(): Promise<UserRuntimeLocation | undefined> {
  if (typeof window === "undefined" || !("geolocation" in navigator)) return undefined;
  if (readExactLocationMode() !== "off") return refreshSharedExactLocation();

  try {
    if (window.localStorage.getItem(EXACT_LOCATION_AUTO_REQUESTED_KEY) === "1") {
      return undefined;
    }
    window.localStorage.setItem(EXACT_LOCATION_AUTO_REQUESTED_KEY, "1");
  } catch {
    return undefined;
  }

  const permission = await getGeolocationPermissionState();
  if (permission === "denied") return undefined;

  try {
    return await captureCurrentExactLocation({
      enableHighAccuracy: true,
      maximumAge: 60_000,
      timeout: INITIAL_LOCATION_REQUEST_TIMEOUT_MS,
    }, "always");
  } catch {
    return undefined;
  }
}

function getCurrentPosition(options: PositionOptions) {
  return new Promise<GeolocationPosition>((resolve, reject) => {
    navigator.geolocation.getCurrentPosition(resolve, reject, options);
  });
}

async function getGeolocationPermissionState(): Promise<PermissionState | null> {
  if (!navigator.permissions?.query) return null;

  try {
    const status = await navigator.permissions.query({ name: "geolocation" as PermissionName });
    return status.state;
  } catch {
    return null;
  }
}
