# Telegram Transcriber Bot

Local Telegram bot for forwarding voice/audio messages and getting a transcript back.

The bot does not run Whisper itself. It downloads the Telegram audio into a temporary directory, posts it to a configured Her-compatible transcription endpoint, replies with the `transcript` field, then deletes the temporary file.

## Run

```bash
cd telegram-transcriber-bot
python3 -m venv .venv
source .venv/bin/activate
pip install -e .
cp env.example .env
python -m telegram_transcriber_bot
```

Fill `.env` before starting:

```bash
TELEGRAM_BOT_TOKEN=<token from BotFather>
TRANSCRIPTION_URL=http://127.0.0.1:8000/v1/transcribe
```

If you point at the authenticated iOS backend instead, use:

```bash
TRANSCRIPTION_URL=http://127.0.0.1:8787/v1/transcriptions
TRANSCRIPTION_BEARER_TOKEN=<Her session token>
```

## Usage

1. Start the bot process locally.
2. Open the bot in Telegram and press Start.
3. Forward or send a voice message, audio file, or audio document to the bot.
4. The bot replies with the transcription.

Use `/whoami` to get your numeric Telegram user id. Set `ALLOWED_TELEGRAM_USER_IDS` in `.env` to restrict who can use the bot:

```bash
ALLOWED_TELEGRAM_USER_IDS=123456789
```

## Notes

- Keep the Telegram token in `.env`; do not hard-code it.
- Telegram Bot API downloads are limited by Telegram's file-size rules, so long audio may fail before transcription.
- The default endpoint matches `her-ios/stt-service` on port `8000`. The iOS backend endpoint on port `8787` requires a bearer token.
