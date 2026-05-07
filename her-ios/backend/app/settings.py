from functools import lru_cache
from pathlib import Path

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

    openai_api_key: str | None = None
    openai_base_url: str | None = None
    openai_summary_model: str = "gpt-oss"

    auth_jwt_secret: str = "dev-secret-change-me-in-production"
    apple_client_id: str = "com.ekenesbek.her"
    google_client_ids: str = ""

    huggingface_token: str | None = None
    diarization_enabled: bool = True
    voice_profile_match_threshold: float = 0.62

    @property
    def google_client_id_list(self) -> list[str]:
        return [c.strip() for c in self.google_client_ids.split(",") if c.strip()]


@lru_cache
def get_settings() -> Settings:
    settings = Settings()
    settings.data_dir.mkdir(parents=True, exist_ok=True)
    return settings
