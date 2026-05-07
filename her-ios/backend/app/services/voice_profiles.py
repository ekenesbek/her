"""Voice profile embedding extraction + speaker matching."""

from __future__ import annotations

import logging
from pathlib import Path
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
        if inference is None:
            return None

        try:
            embedding = inference(str(audio_path))
            embedding = np.asarray(embedding, dtype=np.float32).reshape(-1)
            return embedding
        except Exception as exc:  # noqa: BLE001
            logger.warning("Failed to extract embedding: %s", exc)
            return None

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

            diarization_result = diarization(str(audio_path))
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

    @staticmethod
    def cosine_similarity(a: np.ndarray, b: np.ndarray) -> float:
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
                    use_auth_token=token,
                )
            except Exception as exc:  # noqa: BLE001
                logger.warning("Failed to load diarization pipeline for matching: %s", exc)
                self._diarization = None
            return self._diarization
