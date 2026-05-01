from functools import lru_cache
from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8")

    host: str = "0.0.0.0"
    port: int = 8787
    data_dir: Path = Path("./data")

    whisper_model: str = "base"
    whisper_device: str = "auto"
    whisper_compute_type: str = "default"
    whisper_language: str | None = None

    openai_api_key: str | None = None
    openai_summary_model: str = "gpt-5-nano"


@lru_cache
def get_settings() -> Settings:
    settings = Settings()
    settings.data_dir.mkdir(parents=True, exist_ok=True)
    return settings
