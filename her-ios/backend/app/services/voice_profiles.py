"""Voice profile embedding extraction + speaker matching."""

from __future__ import annotations

import logging
import shutil
import subprocess
from pathlib import Path
from tempfile import TemporaryDirectory
from threading import Lock
from typing import Any

import numpy as np

from app.settings import Settings

logger = logging.getLogger(__name__)


class VoiceEmbedder:
    """Wraps pyannote embedding + diarization pipelines for enrollment / matching."""

    def __init__(self, settings: Settings):
        self.settings = settings
        self._lock = Lock()
        self._inference: Any = None
        self._inference_attempted = False
        self._diarization: Any = None
        self._diarization_attempted = False

    def extract_full_audio(self, audio_path: Path) -> np.ndarray | None:
        """Extract one embedding for the whole audio file (used for enrollment)."""
        inference = self._get_inference()
        if inference is not None:
            try:
                embedding = inference(str(audio_path))
                embedding = np.asarray(embedding, dtype=np.float32).reshape(-1)
                return embedding
            except Exception as exc:  # noqa: BLE001
                logger.warning("Failed to extract embedding: %s", exc)

        return self._external_embedding(audio_path)

    def extract_per_speaker(
        self, audio_path: Path
    ) -> dict[str, np.ndarray] | None:
        """Run pyannote diarization on the file and return one embedding per speaker."""
        diarization = self._get_diarization()
        inference = self._get_inference()
        if diarization is None or inference is None:
            return None

        try:
            from pyannote.core import Segment

            kwargs: dict[str, int] = {}
            if self.settings.diarization_min_speakers > 0:
                kwargs["min_speakers"] = self.settings.diarization_min_speakers
            if self.settings.diarization_max_speakers > 0:
                kwargs["max_speakers"] = self.settings.diarization_max_speakers
            diarization_result = diarization(str(audio_path), **kwargs)
            timeline_per_speaker: dict[str, list[Segment]] = {}
            for turn, _, speaker in diarization_result.itertracks(yield_label=True):
                timeline_per_speaker.setdefault(speaker, []).append(turn)

            output: dict[str, np.ndarray] = {}
            for speaker, segments in timeline_per_speaker.items():
                vectors = []
                for seg in segments:
                    if seg.duration < 0.5:
                        continue
                    try:
                        emb = inference.crop(str(audio_path), seg)
                        vectors.append(np.asarray(emb, dtype=np.float32).reshape(-1))
                    except Exception:  # noqa: BLE001
                        continue
                if vectors:
                    stacked = np.stack(vectors, axis=0)
                    averaged = stacked.mean(axis=0)
                    output[speaker] = averaged
            return output or None
        except Exception as exc:  # noqa: BLE001
            logger.warning("Failed per-speaker embedding extraction: %s", exc)
            return None

    def extract_for_labeled_segments(
        self,
        audio_path: Path,
        transcript_segments: list[Any],
    ) -> dict[str, np.ndarray] | None:
        """Return one embedding per existing transcript speaker label."""
        inference = self._get_inference()
        if inference is None:
            return self._extract_labeled_segments_external(audio_path, transcript_segments)

        try:
            from pyannote.core import Segment

            timeline_per_speaker: dict[str, list[Segment]] = {}
            for transcript_segment in transcript_segments:
                speaker = getattr(transcript_segment, "speaker", None)
                if not speaker:
                    continue
                start = float(getattr(transcript_segment, "start", 0.0) or 0.0)
                end = float(getattr(transcript_segment, "end", 0.0) or 0.0)
                if end - start < 0.5:
                    continue
                timeline_per_speaker.setdefault(str(speaker), []).append(
                    Segment(max(0.0, start), end)
                )

            output: dict[str, np.ndarray] = {}
            for speaker, segments in timeline_per_speaker.items():
                vectors = []
                for seg in segments:
                    try:
                        emb = inference.crop(str(audio_path), seg)
                        vectors.append(np.asarray(emb, dtype=np.float32).reshape(-1))
                    except Exception:  # noqa: BLE001
                        continue
                if vectors:
                    output[speaker] = np.stack(vectors, axis=0).mean(axis=0)
            return output or None
        except Exception as exc:  # noqa: BLE001
            logger.warning("Failed labeled speaker embedding extraction: %s", exc)
            return self._extract_labeled_segments_external(audio_path, transcript_segments)

    def extract_sample_audio(
        self,
        audio_path: Path,
        output_prefix: Path,
        transcript_segments: list[Any],
    ) -> Path | None:
        segments: list[tuple[float, float]] = []
        for transcript_segment in transcript_segments:
            start = float(getattr(transcript_segment, "start", 0.0) or 0.0)
            end = float(getattr(transcript_segment, "end", 0.0) or 0.0)
            if end - start >= 0.5:
                segments.append((max(0.0, start), end))
        if not segments:
            return None
        return self._speaker_sample_audio(audio_path, output_prefix, segments)

    @staticmethod
    def average_embeddings(
        current: np.ndarray,
        current_weight: int,
        new: np.ndarray,
        new_weight: int = 1,
    ) -> np.ndarray:
        if current.shape != new.shape:
            return new.astype(np.float32)
        safe_current_weight = max(1, int(current_weight))
        safe_new_weight = max(1, int(new_weight))
        return (
            current.astype(np.float32) * safe_current_weight
            + new.astype(np.float32) * safe_new_weight
        ) / float(safe_current_weight + safe_new_weight)

    @staticmethod
    def cosine_similarity(a: np.ndarray, b: np.ndarray) -> float:
        if a.shape != b.shape:
            return 0.0
        denom = float(np.linalg.norm(a) * np.linalg.norm(b))
        if denom == 0:
            return 0.0
        return float(np.dot(a, b) / denom)

    @staticmethod
    def serialize(embedding: np.ndarray) -> bytes:
        return embedding.astype(np.float32).tobytes()

    @staticmethod
    def deserialize(blob: bytes) -> np.ndarray:
        return np.frombuffer(blob, dtype=np.float32)

    def _extract_labeled_segments_external(
        self,
        audio_path: Path,
        transcript_segments: list[Any],
    ) -> dict[str, np.ndarray] | None:
        if not self.settings.external_transcription_url or shutil.which("ffmpeg") is None:
            return None

        grouped = self._group_segments_by_speaker(transcript_segments)
        if not grouped:
            return None

        output: dict[str, np.ndarray] = {}
        with TemporaryDirectory(prefix="her-speaker-samples-") as temp_dir:
            temp_path = Path(temp_dir)
            for speaker, segments in grouped.items():
                sample_path = self._speaker_sample_audio(
                    audio_path,
                    temp_path / self._safe_sample_name(speaker),
                    segments,
                )
                if sample_path is None:
                    continue
                embedding = self._external_embedding(sample_path)
                if embedding is not None:
                    output[speaker] = embedding
        return output or None

    def _external_embedding(self, audio_path: Path) -> np.ndarray | None:
        if not self.settings.external_transcription_url:
            return None

        import httpx

        base_url = self.settings.external_transcription_url.rstrip("/")
        for endpoint in ("v2/embedding", "v1/embedding"):
            try:
                with httpx.Client(timeout=self.settings.external_transcription_timeout_seconds) as client:
                    with audio_path.open("rb") as audio:
                        response = client.post(
                            f"{base_url}/{endpoint}",
                            files={
                                "audio": (
                                    audio_path.name,
                                    audio,
                                    self._content_type(audio_path),
                                )
                            },
                        )
                if response.status_code == 404:
                    continue
                response.raise_for_status()
                payload = response.json()
                embedding = payload.get("embedding")
                if isinstance(embedding, list) and embedding:
                    return np.asarray(embedding, dtype=np.float32).reshape(-1)
            except Exception as exc:  # noqa: BLE001
                logger.warning("External voice embedding failed via %s: %s", endpoint, exc)
        return None

    def _speaker_sample_audio(
        self,
        source_path: Path,
        output_prefix: Path,
        segments: list[tuple[float, float]],
    ) -> Path | None:
        usable_segments = self._selected_sample_segments(segments)
        if not usable_segments:
            return None

        chunk_paths: list[Path] = []
        for index, (start, end) in enumerate(usable_segments):
            chunk_path = output_prefix.with_name(f"{output_prefix.name}-{index:03d}.wav")
            duration = max(0.0, end - start)
            if duration < 0.35:
                continue
            result = subprocess.run(
                [
                    "ffmpeg",
                    "-hide_banner",
                    "-loglevel",
                    "error",
                    "-ss",
                    f"{start:.3f}",
                    "-t",
                    f"{duration:.3f}",
                    "-i",
                    str(source_path),
                    "-vn",
                    "-ac",
                    "1",
                    "-ar",
                    "16000",
                    "-f",
                    "wav",
                    str(chunk_path),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            if result.returncode == 0 and chunk_path.exists():
                chunk_paths.append(chunk_path)

        if not chunk_paths:
            return None
        if len(chunk_paths) == 1:
            return chunk_paths[0]

        concat_file = output_prefix.with_suffix(".txt")
        concat_file.write_text(
            "\n".join(f"file '{path.as_posix()}'" for path in chunk_paths),
            encoding="utf-8",
        )
        output_path = output_prefix.with_suffix(".wav")
        result = subprocess.run(
            [
                "ffmpeg",
                "-hide_banner",
                "-loglevel",
                "error",
                "-f",
                "concat",
                "-safe",
                "0",
                "-i",
                str(concat_file),
                "-c",
                "copy",
                str(output_path),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode == 0 and output_path.exists():
            return output_path
        return chunk_paths[0]

    @staticmethod
    def _group_segments_by_speaker(
        transcript_segments: list[Any],
    ) -> dict[str, list[tuple[float, float]]]:
        grouped: dict[str, list[tuple[float, float]]] = {}
        for transcript_segment in transcript_segments:
            speaker = getattr(transcript_segment, "speaker", None)
            if not speaker:
                continue
            start = float(getattr(transcript_segment, "start", 0.0) or 0.0)
            end = float(getattr(transcript_segment, "end", 0.0) or 0.0)
            if end - start < 0.5:
                continue
            grouped.setdefault(str(speaker), []).append((max(0.0, start), end))
        return grouped

    @staticmethod
    def _selected_sample_segments(
        segments: list[tuple[float, float]],
        max_segments: int = 24,
        max_total_seconds: float = 90.0,
    ) -> list[tuple[float, float]]:
        selected: list[tuple[float, float]] = []
        total = 0.0
        for start, end in sorted(segments, key=lambda item: item[0]):
            duration = max(0.0, end - start)
            if duration < 0.5:
                continue
            selected.append((start, end))
            total += duration
            if len(selected) >= max_segments or total >= max_total_seconds:
                break
        return selected

    @staticmethod
    def _safe_sample_name(speaker: str) -> str:
        safe = "".join(ch if ch.isalnum() else "-" for ch in speaker).strip("-")
        return safe or "speaker"

    @staticmethod
    def _content_type(audio_path: Path) -> str:
        suffix = audio_path.suffix.lower()
        if suffix in {".m4a", ".mp4"}:
            return "audio/mp4"
        if suffix == ".caf":
            return "audio/x-caf"
        if suffix == ".wav":
            return "audio/wav"
        return "application/octet-stream"

    def _get_inference(self):
        with self._lock:
            if self._inference is not None:
                return self._inference
            if self._inference_attempted:
                return None
            self._inference_attempted = True

            token = self.settings.huggingface_token
            if not token:
                logger.warning("HUGGINGFACE_TOKEN not set; voice embeddings disabled.")
                return None

            try:
                from pyannote.audio import Inference, Model

                model = Model.from_pretrained(
                    "pyannote/embedding",
                    use_auth_token=token,
                )
                self._inference = Inference(model, window="whole")
            except Exception as exc:  # noqa: BLE001
                logger.warning("Failed to load pyannote embedding model: %s", exc)
                self._inference = None
            return self._inference

    def _get_diarization(self):
        with self._lock:
            if self._diarization is not None:
                return self._diarization
            if self._diarization_attempted:
                return None
            self._diarization_attempted = True

            token = self.settings.huggingface_token
            if not token:
                return None

            try:
                from pyannote.audio import Pipeline

                self._diarization = Pipeline.from_pretrained(
                    "pyannote/speaker-diarization-3.1",
                    token=token,
                )
            except Exception as exc:  # noqa: BLE001
                logger.warning("Failed to load diarization pipeline for matching: %s", exc)
                self._diarization = None
            return self._diarization
