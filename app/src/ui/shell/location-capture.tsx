"use client";

import { useEffect, useState } from "react";
import {
  clearStoredExactLocation,
  EXACT_LOCATION_CHANGED_EVENT,
  readStoredExactLocation,
  writeStoredExactLocation,
} from "@/client/location";
import type { UserRuntimeLocation } from "@/shared/types";

type LocationStatus = "idle" | "requesting" | "stored" | "denied" | "unavailable";

export default function LocationCapture() {
  const [location, setLocation] = useState<UserRuntimeLocation | undefined>();
  const [status, setStatus] = useState<LocationStatus>("idle");

  useEffect(() => {
    const sync = () => {
      const stored = readStoredExactLocation();
      setLocation(stored);
      setStatus(stored ? "stored" : "idle");
    };

    sync();
    window.addEventListener(EXACT_LOCATION_CHANGED_EVENT, sync);
    window.addEventListener("storage", sync);

    return () => {
      window.removeEventListener(EXACT_LOCATION_CHANGED_EVENT, sync);
      window.removeEventListener("storage", sync);
    };
  }, []);

  async function capture() {
    if (location) {
      clearStoredExactLocation();
      setLocation(undefined);
      setStatus("idle");
      return;
    }

    if (!("geolocation" in navigator)) {
      setStatus("unavailable");
      return;
    }

    setStatus("requesting");

    try {
      const position = await getCurrentPosition();
      writeStoredExactLocation({
        latitude: position.coords.latitude,
        longitude: position.coords.longitude,
        accuracyMeters: position.coords.accuracy,
      });
      setLocation(readStoredExactLocation());
      setStatus("stored");
    } catch {
      setLocation(undefined);
      setStatus("denied");
    }
  }

  return (
    <button
      className={`btn !py-1.5 !px-3 text-xs whitespace-nowrap ${
        location ? "btn-secondary border-[var(--accent)]" : "btn-ghost"
      }`}
      onClick={capture}
      disabled={status === "requesting"}
      title={buttonTitle(status, location)}
    >
      {buttonLabel(status, location)}
    </button>
  );
}

function getCurrentPosition() {
  return new Promise<GeolocationPosition>((resolve, reject) => {
    navigator.geolocation.getCurrentPosition(resolve, reject, {
      enableHighAccuracy: true,
      maximumAge: 60_000,
      timeout: 10_000,
    });
  });
}

function buttonLabel(status: LocationStatus, location?: UserRuntimeLocation) {
  if (status === "requesting") return "Подача...";
  if (location) return "Подача вкл";
  if (status === "denied") return "Подача отказ";
  if (status === "unavailable") return "Подача недоступна";
  return "Подача";
}

function buttonTitle(status: LocationStatus, location?: UserRuntimeLocation) {
  if (location) {
    const accuracy = location.accuracyMeters !== undefined ? `, точность ${Math.round(location.accuracyMeters)} м` : "";
    return `Точка подачи сохранена${accuracy}. Нажми, чтобы очистить.`;
  }
  if (status === "denied") return "Доступ к геолокации отклонён.";
  if (status === "unavailable") return "Геолокация недоступна в этом браузере.";
  return "Одноразово сохранить текущую точку подачи для задач агента.";
}

