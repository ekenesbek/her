from __future__ import annotations

import mimetypes
from pathlib import Path
from typing import Any

from app.schemas import TranscriptResponse, TranscriptSegment
from app.services.transcript_format import (
    format_speaker_transcript,
    join_words,
    normalize_speaker_label,
)
from app.settings import Settings


class DeepgramTranscriber:
    """Deepgram pre-recorded STT adapter with diarized segment output."""

    def __init__(self, settings: Settings):
        if not settings.deepgram_api_key:
            raise RuntimeError("DEEPGRAM_API_KEY is required when TRANSCRIPTION_PROVIDER=deepgram.")
        self.settings = settings
        self._base_url = settings.deepgram_base_url.rstrip("/")

    def transcribe(self, audio_path: Path) -> TranscriptResponse:
        import httpx

        headers = {
            "Authorization": f"Token {self.settings.deepgram_api_key}",
            "Content-Type": mimetypes.guess_type(audio_path.name)[0] or "application/octet-stream",
        }
        params: dict[str, str] = {
            "model": self.settings.deepgram_model,
            "smart_format": "true",
            "punctuate": "true",
            "diarize": "true",
            "utterances": "true",
        }
        if self.settings.deepgram_language:
            params["language"] = self.settings.deepgram_language

        with httpx.Client(timeout=self.settings.deepgram_timeout_seconds) as client:
            with audio_path.open("rb") as audio:
                response = client.post(
                    f"{self._base_url}/v1/listen",
                    params=params,
                    content=self._read_chunks(audio),
                    headers=headers,
                )
        response.raise_for_status()
        return self.parse_response(response.json())

    def parse_response(self, payload: dict[str, Any]) -> TranscriptResponse:
        results = payload.get("results") if isinstance(payload, dict) else {}
        results = results if isinstance(results, dict) else {}

        segments = self._segments_from_utterances(results.get("utterances"))
        if not segments:
            segments = self._segments_from_channels(results.get("channels"))

        transcript = format_speaker_transcript(segments) if segments else ""
        if not transcript:
            transcript = self._fallback_transcript(results)

        return TranscriptResponse(
            transcript=transcript,
            language=self._language(results, payload),
            durationSeconds=self._duration(payload, segments),
            segments=segments,
        )

    def _segments_from_utterances(self, utterances: object) -> list[TranscriptSegment]:
        if not isinstance(utterances, list):
            return []

        segments: list[TranscriptSegment] = []
        for utterance in utterances:
            if not isinstance(utterance, dict):
                continue
            text = str(utterance.get("transcript") or "").strip()
            if not text:
                continue
            start = self._float_or_default(utterance.get("start"), 0.0)
            end = self._float_or_default(utterance.get("end"), start)
            segments.append(
                TranscriptSegment(
                    start=start,
                    end=max(start, end),
                    text=text,
                    speaker=normalize_speaker_label(utterance.get("speaker")),
                )
            )
        return segments

    def _segments_from_channels(self, channels: object) -> list[TranscriptSegment]:
        if not isinstance(channels, list):
            return []

        words: list[dict[str, Any]] = []
        for channel in channels:
            if not isinstance(channel, dict):
                continue
            alternatives = channel.get("alternatives")
            if not isinstance(alternatives, list) or not alternatives:
                continue
            alternative = alternatives[0]
            if not isinstance(alternative, dict):
                continue
            alt_words = alternative.get("words")
            if isinstance(alt_words, list):
                words.extend(word for word in alt_words if isinstance(word, dict))

        groups: list[dict[str, Any]] = []
        for word in words:
            word_text = str(word.get("punctuated_word") or word.get("word") or "").strip()
            if not word_text:
                continue
            speaker = normalize_speaker_label(word.get("speaker"))
            start = self._float_or_default(word.get("start"), 0.0)
            end = self._float_or_default(word.get("end"), start)
            if groups and groups[-1]["speaker"] == speaker:
                groups[-1]["words"].append(word_text)
                groups[-1]["end"] = max(float(groups[-1]["end"]), end)
            else:
                groups.append(
                    {
                        "speaker": speaker,
                        "start": start,
                        "end": max(start, end),
                        "words": [word_text],
                    }
                )

        return [
            TranscriptSegment(
                start=float(group["start"]),
                end=float(group["end"]),
                text=join_words(group["words"]),
                speaker=group["speaker"],
            )
            for group in groups
            if group["words"]
        ]

    def _fallback_transcript(self, results: dict[str, Any]) -> str:
        channels = results.get("channels")
        if not isinstance(channels, list) or not channels:
            return ""
        alternatives = channels[0].get("alternatives") if isinstance(channels[0], dict) else None
        if not isinstance(alternatives, list) or not alternatives:
            return ""
        alternative = alternatives[0]
        if not isinstance(alternative, dict):
            return ""
        return str(alternative.get("transcript") or "").strip()

    def _language(self, results: dict[str, Any], payload: dict[str, Any]) -> str | None:
        channels = results.get("channels")
        if isinstance(channels, list) and channels:
            channel = channels[0]
            if isinstance(channel, dict):
                language = channel.get("detected_language")
                if language:
                    return str(language)
                alternatives = channel.get("alternatives")
                if isinstance(alternatives, list) and alternatives:
                    alternative = alternatives[0]
                    if isinstance(alternative, dict):
                        languages = alternative.get("languages")
                        if isinstance(languages, list) and languages:
                            return "multi" if len(languages) > 1 else str(languages[0])
                        if alternative.get("language"):
                            return str(alternative["language"])

        metadata = payload.get("metadata")
        if isinstance(metadata, dict) and metadata.get("language"):
            return str(metadata["language"])
        return self.settings.deepgram_language

    def _duration(
        self,
        payload: dict[str, Any],
        segments: list[TranscriptSegment],
    ) -> float | None:
        metadata = payload.get("metadata")
        if isinstance(metadata, dict):
            duration = self._float_or_none(metadata.get("duration"))
            if duration is not None:
                return duration
        if segments:
            return max(segment.end for segment in segments)
        return None

    def _float_or_default(self, value: object, default: float) -> float:
        parsed = self._float_or_none(value)
        return parsed if parsed is not None else default

    def _float_or_none(self, value: object) -> float | None:
        try:
            return float(value)
        except (TypeError, ValueError):
            return None

    def _read_chunks(self, audio):
        while chunk := audio.read(1024 * 1024):
            yield chunk
