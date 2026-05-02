# Meta iOS Backend

Local API for the iOS app. It receives meeting audio, transcribes it with local Whisper, summarizes the transcript with OpenAI when `OPENAI_API_KEY` is configured, and persists meetings in SQLite.

## Run

```bash
cd meta-ios/backend
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
uvicorn app.main:app --host 0.0.0.0 --port 8787 --reload
```

For a physical iPhone, keep the phone and Mac on the same network and set the iOS `BackendAPIURL` to the Mac hostname, for example:

```text
http://Yerasyls-MacBook-Pro.local:8787
```

The default summary model is `gpt-5-nano`. Set `OPENAI_API_KEY` and `OPENAI_SUMMARY_MODEL` in `.env` to switch models.

## Endpoints

- `GET /health`
- `POST /v1/transcriptions` with multipart field `audio`
- `POST /v1/summaries` with JSON `{ "transcript": "..." }`
- `POST /v1/meetings/process` with multipart field `audio`
- `GET /v1/meetings`
- `GET /v1/meetings/{id}`

## Database

The backend stores data in `DATA_DIR/meetings.sqlite3` with normalized tables:

- `meetings`: transcript, title, overview, language, duration, source/device/location metadata.
- `summary_items`: decisions, action items, and follow-ups linked to a meeting.

Older JSON-blob databases are migrated automatically on startup.

## Notes

`faster-whisper` runs locally and downloads the configured model on first use. `base` is a practical MVP default. Use `tiny` for faster tests or `small` for better quality.
