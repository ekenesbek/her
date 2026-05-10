from functools import lru_cache
from pathlib import Path

from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8")

    host: str = "0.0.0.0"
    port: int = 8787
    data_dir: Path = Path("./data")

    whisper_model: str = "turbo"
    whisper_device: str = "auto"
    whisper_compute_type: str = "default"
    whisper_language: str | None = None
    whisper_cpu_threads: int = 0
    whisper_num_workers: int = 1
    whisperx_batch_size: int = 4
    transcription_chunking_enabled: bool = True
    transcription_chunk_seconds: int = 30
    transcription_chunk_overlap_seconds: int = 3
    transcription_chunk_min_duration_seconds: int = 30
    transcription_chunk_workers: int = 2

    openai_api_key: str | None = None
    openai_base_url: str | None = None
    openai_summary_model: str = "gpt-oss"
    alem_oss_api_key: str | None = None
    alem_oss_base_url: str = "https://llm.alem.ai/v1"
    meeting_job_workers: int = 1

    auth_jwt_secret: str = "dev-secret-change-me-in-production"
    apple_client_id: str = "com.ekenesbek.her"
    google_client_ids: str = ""

    huggingface_token: str | None = None
    diarization_enabled: bool = True
    diarization_min_speakers: int = 0
    diarization_max_speakers: int = 0
    voice_profile_match_threshold: float = 0.62

    @field_validator("whisper_language", mode="before")
    @classmethod
    def normalize_empty_whisper_language(cls, value: object) -> object:
        if isinstance(value, str):
            normalized = value.strip()
            return normalized or None
        return value

    @property
    def google_client_id_list(self) -> list[str]:
        return [c.strip() for c in self.google_client_ids.split(",") if c.strip()]

    @property
    def llm_api_key(self) -> str | None:
        return self.openai_api_key or self.alem_oss_api_key

    @property
    def llm_base_url(self) -> str | None:
        if self.openai_base_url:
            return self.openai_base_url
        if self.alem_oss_api_key:
            return self.alem_oss_base_url
        return None

    @property
    def llm_configured(self) -> bool:
        return bool(self.llm_api_key)


@lru_cache
def get_settings() -> Settings:
    settings = Settings()
    settings.data_dir.mkdir(parents=True, exist_ok=True)
    return settings
