from __future__ import annotations

import json
import shutil
import subprocess
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Iterator

from app.settings import Settings


@dataclass(frozen=True)
class AudioChunk:
    index: int
    start: float
    duration: float
    path: Path

    @property
    def end(self) -> float:
        return self.start + self.duration


def audio_duration_seconds(audio_path: Path) -> float | None:
    if shutil.which("ffprobe") is None:
        return None

    result = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "json",
            str(audio_path),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return None

    try:
        raw_duration = json.loads(result.stdout)["format"]["duration"]
        duration = float(raw_duration)
    except (KeyError, TypeError, ValueError, json.JSONDecodeError):
        return None

    return duration if duration > 0 else None


def should_chunk_audio(audio_path: Path, settings: Settings) -> tuple[bool, float | None]:
    duration = audio_duration_seconds(audio_path)
    return (
        settings.transcription_chunking_enabled
        and shutil.which("ffmpeg") is not None
        and duration is not None
        and duration >= settings.transcription_chunk_min_duration_seconds,
        duration,
    )


@contextmanager
def split_audio_chunks(
    audio_path: Path,
    settings: Settings,
    duration_seconds: float,
) -> Iterator[list[AudioChunk]]:
    if shutil.which("ffmpeg") is None:
        yield []
        return

    chunk_seconds = max(1.0, float(settings.transcription_chunk_seconds))
    overlap_seconds = max(
        0.0,
        min(float(settings.transcription_chunk_overlap_seconds), chunk_seconds / 3),
    )
    step_seconds = max(1.0, chunk_seconds - overlap_seconds)

    with TemporaryDirectory(prefix="her-audio-chunks-") as temp_dir:
        chunk_dir = Path(temp_dir)
        chunks: list[AudioChunk] = []
        start = 0.0
        index = 0
        while start < duration_seconds:
            remaining = duration_seconds - start
            chunk_duration = min(chunk_seconds, remaining)
            if chunk_duration <= 0:
                break

            chunk_path = chunk_dir / f"chunk-{index:04d}.wav"
            subprocess.run(
                [
                    "ffmpeg",
                    "-hide_banner",
                    "-loglevel",
                    "error",
                    "-ss",
                    f"{start:.3f}",
                    "-t",
                    f"{chunk_duration:.3f}",
                    "-i",
                    str(audio_path),
                    "-vn",
                    "-ac",
                    "1",
                    "-ar",
                    "16000",
                    "-f",
                    "wav",
                    str(chunk_path),
                ],
                check=True,
            )
            chunks.append(
                AudioChunk(
                    index=index,
                    start=start,
                    duration=chunk_duration,
                    path=chunk_path,
                )
            )
            if start + chunk_duration >= duration_seconds:
                break
            start += step_seconds
            index += 1

        yield chunks
