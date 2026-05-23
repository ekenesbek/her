from __future__ import annotations

import logging
from dataclasses import dataclass
from pathlib import Path
from tempfile import TemporaryDirectory

from telegram import Message, Update
from telegram.constants import ChatAction
from telegram.ext import Application, CommandHandler, ContextTypes, MessageHandler, filters

from telegram_transcriber_bot.config import Settings, load_settings
from telegram_transcriber_bot.messages import format_transcript_reply, split_reply
from telegram_transcriber_bot.transcription_client import TranscriptionClient, TranscriptionError


logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class AudioAttachment:
    file_id: str
    file_name: str
    mime_type: str | None
    file_size: int | None
    kind: str


def build_application(settings: Settings) -> Application:
    application = Application.builder().token(settings.telegram_bot_token).build()
    application.bot_data["settings"] = settings
    application.bot_data["transcription_client"] = TranscriptionClient(settings)

    application.add_handler(CommandHandler("start", start))
    application.add_handler(CommandHandler("whoami", whoami))
    application.add_handler(
        MessageHandler(
            filters.VOICE | filters.AUDIO | filters.Document.ALL | filters.VIDEO_NOTE,
            transcribe_audio,
        )
    )
    application.add_handler(MessageHandler(filters.ALL, unsupported_message))
    return application


async def start(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not await guard_allowed(update, context):
        return
    message = update.effective_message
    if message:
        await message.reply_text("Send or forward a voice/audio message and I will transcribe it.")


async def whoami(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    message = update.effective_message
    user = update.effective_user
    if message and user:
        await message.reply_text(f"Telegram user id: {user.id}")


async def transcribe_audio(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not await guard_allowed(update, context):
        return

    message = update.effective_message
    if message is None:
        return

    settings: Settings = context.application.bot_data["settings"]
    client: TranscriptionClient = context.application.bot_data["transcription_client"]
    attachment = audio_attachment_from_message(message)
    if attachment is None:
        await message.reply_text("Send a voice message, audio file, or audio document.")
        return

    if attachment.file_size and attachment.file_size > settings.max_audio_bytes:
        await message.reply_text(
            "Audio is too large for this bot. "
            f"Limit: {settings.max_audio_bytes // (1024 * 1024)} MB."
        )
        return

    await context.bot.send_chat_action(chat_id=message.chat_id, action=ChatAction.TYPING)
    status = await message.reply_text("Transcribing audio...")

    try:
        with TemporaryDirectory(prefix="telegram-audio-") as temp_dir:
            local_path = Path(temp_dir) / sanitize_filename(attachment.file_name)
            telegram_file = await context.bot.get_file(attachment.file_id)
            await telegram_file.download_to_drive(custom_path=local_path)
            result = await client.transcribe(local_path)
    except TranscriptionError as exc:
        logger.exception("Transcription failed")
        await status.edit_text(str(exc))
        return
    except Exception:
        logger.exception("Unexpected Telegram transcription failure")
        await status.edit_text("Transcription failed. Check the bot logs for details.")
        return

    reply = format_transcript_reply(
        result.transcript,
        language=result.language,
        duration_seconds=result.duration_seconds,
    )
    chunks = split_reply(reply, limit=settings.max_reply_chars)
    await status.edit_text(chunks[0])
    for chunk in chunks[1:]:
        await message.reply_text(chunk)


async def unsupported_message(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not await guard_allowed(update, context):
        return
    message = update.effective_message
    if message:
        await message.reply_text("Send or forward a voice/audio message.")


async def guard_allowed(update: Update, context: ContextTypes.DEFAULT_TYPE) -> bool:
    settings: Settings = context.application.bot_data["settings"]
    allowed_ids = settings.allowed_telegram_user_ids
    user = update.effective_user
    if allowed_ids is None or user is None or user.id in allowed_ids:
        return True

    message = update.effective_message
    if message:
        await message.reply_text("This bot is restricted.")
    return False


def audio_attachment_from_message(message: Message) -> AudioAttachment | None:
    if message.voice:
        return AudioAttachment(
            file_id=message.voice.file_id,
            file_name=f"{message.voice.file_unique_id}.oga",
            mime_type=message.voice.mime_type,
            file_size=message.voice.file_size,
            kind="voice",
        )

    if message.audio:
        return AudioAttachment(
            file_id=message.audio.file_id,
            file_name=message.audio.file_name or f"{message.audio.file_unique_id}.mp3",
            mime_type=message.audio.mime_type,
            file_size=message.audio.file_size,
            kind="audio",
        )

    if message.video_note:
        return AudioAttachment(
            file_id=message.video_note.file_id,
            file_name=f"{message.video_note.file_unique_id}.mp4",
            mime_type="video/mp4",
            file_size=message.video_note.file_size,
            kind="video_note",
        )

    if message.document and is_audio_document(message.document.mime_type, message.document.file_name):
        return AudioAttachment(
            file_id=message.document.file_id,
            file_name=message.document.file_name or f"{message.document.file_unique_id}.bin",
            mime_type=message.document.mime_type,
            file_size=message.document.file_size,
            kind="document",
        )

    return None


def is_audio_document(mime_type: str | None, file_name: str | None) -> bool:
    if mime_type and (mime_type.startswith("audio/") or mime_type == "video/mp4"):
        return True
    if not file_name:
        return False
    return Path(file_name.lower()).suffix in {
        ".aac",
        ".aiff",
        ".flac",
        ".m4a",
        ".mp3",
        ".mp4",
        ".oga",
        ".ogg",
        ".opus",
        ".wav",
        ".webm",
    }


def sanitize_filename(name: str) -> str:
    cleaned = "".join(char if char.isalnum() or char in "._-" else "_" for char in name)
    cleaned = cleaned.strip("._")
    return cleaned or "audio.bin"


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("httpcore").setLevel(logging.WARNING)
    settings = load_settings()
    application = build_application(settings)
    logger.info("Starting Telegram transcriber bot")
    application.run_polling(allowed_updates=Update.ALL_TYPES)
