"use client";

import { useEffect, useState } from "react";
import {
  clearStoredExactLocation,
  captureCurrentExactLocation,
  type ExactLocationMode,
  EXACT_LOCATION_CHANGED_EVENT,
  readExactLocationMode,
  readStoredExactLocation,
} from "@/client/location";
import type { UserRuntimeLocation } from "@/shared/types";

type LocationStatus = "idle" | "requesting" | "stored" | "denied" | "unavailable";
type LocationChoice = Exclude<ExactLocationMode, "off">;

const LOCATION_CHOICES: Array<{ mode: LocationChoice; label: string; title: string }> = [
  { mode: "once", label: "1 раз", title: "Передать текущую точку только в следующий запрос." },
  { mode: "while_using", label: "При использовании", title: "Обновлять точку, пока приложение открыто." },
  { mode: "always", label: "Всегда", title: "Всегда прикладывать последнюю разрешённую точку к запросам." },
];

export default function LocationCapture() {
  const [location, setLocation] = useState<UserRuntimeLocation | undefined>();
  const [mode, setMode] = useState<ExactLocationMode>("off");
  const [status, setStatus] = useState<LocationStatus>("idle");

  useEffect(() => {
    const sync = () => {
      const stored = readStoredExactLocation();
      const storedMode = readExactLocationMode();
      setLocation(stored);
      setMode(stored ? storedMode : "off");
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

  async function chooseMode(nextMode: LocationChoice) {
    if (mode === nextMode && location) {
      clearStoredExactLocation();
      setLocation(undefined);
      setMode("off");
      setStatus("idle");
      return;
    }

    if (!("geolocation" in navigator)) {
      setStatus("unavailable");
      return;
    }

    setStatus("requesting");

    try {
      const nextLocation = await captureCurrentExactLocation({
        enableHighAccuracy: true,
        maximumAge: 60_000,
        timeout: 10_000,
      }, nextMode);
      setLocation(nextLocation);
      setMode(nextMode);
      setStatus("stored");
    } catch {
      setLocation(undefined);
      setMode("off");
      setStatus("denied");
    }
  }

  return (
    <div className="flex flex-wrap items-center gap-1.5" title={buttonTitle(status, location, mode)}>
      {LOCATION_CHOICES.map((choice) => {
        const active = Boolean(location && mode === choice.mode);
        return (
          <button
            key={choice.mode}
            type="button"
            className={`chip !py-1.5 !px-2.5 whitespace-nowrap ${active ? "chip-active" : ""}`}
            onClick={() => chooseMode(choice.mode)}
            disabled={status === "requesting"}
            title={choice.title}
          >
            {status === "requesting" && mode === choice.mode ? "..." : choice.label}
          </button>
        );
      })}
    </div>
  );
}

function buttonTitle(status: LocationStatus, location?: UserRuntimeLocation, mode: ExactLocationMode = "off") {
  if (location) {
    const accuracy = location.accuracyMeters !== undefined ? `, точность ${Math.round(location.accuracyMeters)} м` : "";
    return `Локация включена: ${modeLabel(mode)}${accuracy}. Нажми активный режим, чтобы выключить.`;
  }
  if (status === "denied") return "Доступ к геолокации отклонён.";
  if (status === "unavailable") return "Геолокация недоступна в этом браузере.";
  return "Выбери, как передавать текущую локацию агенту.";
}

function modeLabel(mode: ExactLocationMode) {
  if (mode === "once") return "1 раз";
  if (mode === "while_using") return "при использовании";
  if (mode === "always") return "всегда";
  return "выключена";
}
