from __future__ import annotations

import json
import sqlite3
from datetime import UTC, datetime
from pathlib import Path
from typing import Iterable
from uuid import uuid4

from app.schemas import (
    MeetingChatMessageResponse,
    MeetingJobResponse,
    MeetingOutlineItem,
    MeetingResponse,
    TranscriptSegment,
    UserResponse,
    VoiceProfileResponse,
)


SUMMARY_ITEM_KINDS = ("decision", "action", "follow_up")
MEETING_JOB_ACTIVE_STATUSES = ("queued", "processing")


class MeetingStore:
    def __init__(self, data_dir: Path):
        self.db_path = data_dir / "meetings.sqlite3"
        self._init_db()

    def save(self, meeting: MeetingResponse, user_id: str | None = None) -> None:
        with self._connect() as connection:
            self._save_with_connection(connection, meeting, user_id)

    def list(self, user_id: str | None = None, limit: int = 50) -> list[MeetingResponse]:
        with self._connect() as connection:
            if user_id is None:
                rows = connection.execute(
                    "SELECT * FROM meetings ORDER BY created_at DESC LIMIT ?",
                    (limit,),
                ).fetchall()
            else:
                rows = connection.execute(
                    "SELECT * FROM meetings WHERE user_id = ? ORDER BY created_at DESC LIMIT ?",
                    (user_id, limit),
                ).fetchall()
            return [self._meeting_from_row(connection, row) for row in rows]

    def get(self, meeting_id: str, user_id: str | None = None) -> MeetingResponse | None:
        with self._connect() as connection:
            if user_id is None:
                row = connection.execute(
                    "SELECT * FROM meetings WHERE id = ?",
                    (meeting_id,),
                ).fetchone()
            else:
                row = connection.execute(
                    "SELECT * FROM meetings WHERE id = ? AND user_id = ?",
                    (meeting_id, user_id),
                ).fetchone()
            if row is None:
                return None
            return self._meeting_from_row(connection, row)

    def attach_meeting_audio(
        self,
        meeting_id: str,
        user_id: str,
        audio_path: Path,
        content_type: str | None = None,
    ) -> None:
        with self._connect() as connection:
            connection.execute(
                """
                UPDATE meetings
                SET audio_path = ?, audio_content_type = ?
                WHERE id = ? AND user_id = ?
                """,
                (str(audio_path), content_type, meeting_id, user_id),
            )

    def get_meeting_audio(
        self,
        meeting_id: str,
        user_id: str,
    ) -> tuple[Path, str | None] | None:
        with self._connect() as connection:
            row = connection.execute(
                """
                SELECT audio_path, audio_content_type FROM meetings
                WHERE id = ? AND user_id = ?
                """,
                (meeting_id, user_id),
            ).fetchone()
        if row is None or not row["audio_path"]:
            return None
        return Path(row["audio_path"]), row["audio_content_type"]

    def next_meeting_title(self, user_id: str, base_title: str) -> str:
        base = base_title.strip() or "Recording"
        with self._connect() as connection:
            rows = connection.execute(
                """
                SELECT title FROM meetings
                WHERE user_id = ? AND (title = ? OR title LIKE ?)
                """,
                (user_id, base, f"{base} %"),
            ).fetchall()
        existing = {row["title"] for row in rows}
        if base not in existing:
            return base
        index = 1
        while f"{base} {index}" in existing:
            index += 1
        return f"{base} {index}"

    def update_meeting_summary(
        self,
        meeting_id: str,
        user_id: str,
        summary,
    ) -> MeetingResponse | None:
        meeting = self.get(meeting_id, user_id=user_id)
        if meeting is None:
            return None
        updated = MeetingResponse(
            id=meeting.id,
            transcript=meeting.transcript,
            segments=meeting.segments,
            language=meeting.language,
            durationSeconds=meeting.durationSeconds,
            source=meeting.source,
            deviceName=meeting.deviceName,
            locationName=meeting.locationName,
            hasAudio=meeting.hasAudio,
            createdAt=meeting.createdAt,
            title=summary.title,
            overview=summary.overview,
            keyTopics=summary.keyTopics,
            decisions=summary.decisions,
            actionItems=summary.actionItems,
            followUps=summary.followUps,
            outline=summary.outline,
            generatedAt=summary.generatedAt,
            summaryStatus=summary.summaryStatus,
            summaryMode=summary.summaryMode,
        )
        self.save(updated, user_id=user_id)
        return updated

    def list_chat_messages(
        self,
        meeting_id: str,
        user_id: str,
        limit: int = 200,
    ) -> list[MeetingChatMessageResponse]:
        with self._connect() as connection:
            if not self._meeting_exists_for_user(connection, meeting_id, user_id):
                return []
            rows = connection.execute(
                """
                SELECT * FROM meeting_chat_messages
                WHERE meeting_id = ?
                ORDER BY created_at ASC, id ASC
                LIMIT ?
                """,
                (meeting_id, limit),
            ).fetchall()
            return [self._chat_message_from_row(row) for row in rows]

    def append_chat_message(
        self,
        meeting_id: str,
        user_id: str,
        role: str,
        content: str,
    ) -> MeetingChatMessageResponse:
        if role not in {"user", "assistant"}:
            raise ValueError("Invalid chat message role.")
        message_id = str(uuid4())
        now = datetime.now(UTC).isoformat()
        with self._connect() as connection:
            if not self._meeting_exists_for_user(connection, meeting_id, user_id):
                raise ValueError("Meeting not found.")
            connection.execute(
                """
                INSERT INTO meeting_chat_messages (id, meeting_id, role, content, created_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                (message_id, meeting_id, role, content, now),
            )
            row = connection.execute(
                "SELECT * FROM meeting_chat_messages WHERE id = ?",
                (message_id,),
            ).fetchone()
            return self._chat_message_from_row(row)

    def create_meeting_job(
        self,
        user_id: str,
        audio_path: Path,
        source: str | None = None,
        device_name: str | None = None,
        location_name: str | None = None,
        summary_mode: str = "reasoning",
    ) -> MeetingJobResponse:
        job_id = str(uuid4())
        now = datetime.now(UTC).isoformat()
        with self._connect() as connection:
            connection.execute(
                """
                INSERT INTO meeting_jobs (
                    id, user_id, audio_path, source, device_name, location_name,
                    summary_mode, status, meeting_id, error, created_at, updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    job_id,
                    user_id,
                    str(audio_path),
                    source,
                    device_name,
                    location_name,
                    summary_mode,
                    "queued",
                    None,
                    None,
                    now,
                    now,
                ),
            )
            row = connection.execute(
                "SELECT * FROM meeting_jobs WHERE id = ?", (job_id,)
            ).fetchone()
            return self._meeting_job_from_row(connection, row)

    def get_meeting_job(
        self,
        job_id: str,
        user_id: str | None = None,
    ) -> MeetingJobResponse | None:
        with self._connect() as connection:
            if user_id is None:
                row = connection.execute(
                    "SELECT * FROM meeting_jobs WHERE id = ?",
                    (job_id,),
                ).fetchone()
            else:
                row = connection.execute(
                    "SELECT * FROM meeting_jobs WHERE id = ? AND user_id = ?",
                    (job_id, user_id),
                ).fetchone()
            return self._meeting_job_from_row(connection, row) if row else None

    def get_meeting_job_payload(self, job_id: str) -> dict[str, str] | None:
        with self._connect() as connection:
            row = connection.execute(
                """
                SELECT id, user_id, audio_path, source, device_name, location_name, summary_mode, status
                FROM meeting_jobs
                WHERE id = ?
                """,
                (job_id,),
            ).fetchone()
            return dict(row) if row else None

    def list_active_meeting_job_ids(self, limit: int = 100) -> list[str]:
        placeholders = ", ".join("?" for _ in MEETING_JOB_ACTIVE_STATUSES)
        with self._connect() as connection:
            rows = connection.execute(
                f"""
                SELECT id FROM meeting_jobs
                WHERE status IN ({placeholders})
                ORDER BY created_at ASC
                LIMIT ?
                """,
                (*MEETING_JOB_ACTIVE_STATUSES, limit),
            ).fetchall()
            return [row["id"] for row in rows]

    def update_meeting_job(
        self,
        job_id: str,
        status: str,
        meeting_id: str | None = None,
        error: str | None = None,
    ) -> None:
        now = datetime.now(UTC).isoformat()
        with self._connect() as connection:
            connection.execute(
                """
                UPDATE meeting_jobs
                SET status = ?, meeting_id = ?, error = ?, updated_at = ?
                WHERE id = ?
                """,
                (status, meeting_id, error, now, job_id),
            )

    def find_or_create_user(
        self,
        provider: str,
        provider_user_id: str,
        email: str | None,
        name: str | None,
    ) -> UserResponse:
        user, _ = self.find_or_create_user_with_status(
            provider=provider,
            provider_user_id=provider_user_id,
            email=email,
            name=name,
        )
        return user

    def find_or_create_user_with_status(
        self,
        provider: str,
        provider_user_id: str,
        email: str | None,
        name: str | None,
    ) -> tuple[UserResponse, bool]:
        with self._connect() as connection:
            row = connection.execute(
                "SELECT * FROM users WHERE provider = ? AND provider_user_id = ?",
                (provider, provider_user_id),
            ).fetchone()

            if row is not None:
                if (email and not row["email"]) or (name and not row["name"]):
                    connection.execute(
                        "UPDATE users SET email = COALESCE(email, ?), name = COALESCE(name, ?) WHERE id = ?",
                        (email, name, row["id"]),
                    )
                    row = connection.execute(
                        "SELECT * FROM users WHERE id = ?", (row["id"],)
                    ).fetchone()
                return self._user_from_row(row), False

            user_id = str(uuid4())
            now = datetime.now(UTC).isoformat()
            connection.execute(
                """
                INSERT INTO users (id, provider, provider_user_id, email, name, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (user_id, provider, provider_user_id, email, name, now),
            )
            row = connection.execute(
                "SELECT * FROM users WHERE id = ?", (user_id,)
            ).fetchone()
            return self._user_from_row(row), True

    def get_user(self, user_id: str) -> UserResponse | None:
        with self._connect() as connection:
            row = connection.execute(
                "SELECT * FROM users WHERE id = ?", (user_id,)
            ).fetchone()
            return self._user_from_row(row) if row else None

    def _user_from_row(self, row: sqlite3.Row) -> UserResponse:
        return UserResponse(
            id=row["id"],
            provider=row["provider"],
            email=row["email"],
            name=row["name"],
            createdAt=row["created_at"],
        )

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.db_path)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        return connection

    def _init_db(self) -> None:
        with self._connect() as connection:
            existing_columns = self._table_columns(connection, "meetings")
            if existing_columns and "payload" in existing_columns:
                self._migrate_json_blob_store(connection)
            else:
                self._create_tables(connection)

            self._ensure_users_table(connection)
            self._ensure_meetings_user_id_column(connection)
            self._ensure_meeting_content_columns(connection)
            self._ensure_meeting_summary_status_column(connection)
            self._ensure_meeting_summary_mode_column(connection)
            self._ensure_meeting_audio_columns(connection)
            self._ensure_voice_profiles_table(connection)
            self._ensure_meeting_jobs_table(connection)
            self._ensure_meeting_chat_messages_table(connection)

    def _ensure_users_table(self, connection: sqlite3.Connection) -> None:
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS users (
                id TEXT PRIMARY KEY,
                provider TEXT NOT NULL,
                provider_user_id TEXT NOT NULL,
                email TEXT,
                name TEXT,
                created_at TEXT NOT NULL,
                UNIQUE(provider, provider_user_id)
            )
            """
        )

    def _ensure_meetings_user_id_column(self, connection: sqlite3.Connection) -> None:
        columns = self._table_columns(connection, "meetings")
        if "user_id" not in columns:
            connection.execute("ALTER TABLE meetings ADD COLUMN user_id TEXT")
            connection.execute(
                "CREATE INDEX IF NOT EXISTS idx_meetings_user_id ON meetings (user_id)"
            )

    def _ensure_meeting_content_columns(self, connection: sqlite3.Connection) -> None:
        columns = self._table_columns(connection, "meetings")
        if "outline_json" not in columns:
            connection.execute(
                "ALTER TABLE meetings ADD COLUMN outline_json TEXT NOT NULL DEFAULT '[]'"
            )
        if "segments_json" not in columns:
            connection.execute(
                "ALTER TABLE meetings ADD COLUMN segments_json TEXT NOT NULL DEFAULT '[]'"
            )

    def _ensure_meeting_summary_status_column(self, connection: sqlite3.Connection) -> None:
        columns = self._table_columns(connection, "meetings")
        if "summary_status" not in columns:
            connection.execute(
                "ALTER TABLE meetings ADD COLUMN summary_status TEXT NOT NULL DEFAULT 'generated'"
            )

    def _ensure_meeting_summary_mode_column(self, connection: sqlite3.Connection) -> None:
        columns = self._table_columns(connection, "meetings")
        if "summary_mode" not in columns:
            connection.execute(
                "ALTER TABLE meetings ADD COLUMN summary_mode TEXT NOT NULL DEFAULT 'reasoning'"
            )

    def _ensure_meeting_audio_columns(self, connection: sqlite3.Connection) -> None:
        columns = self._table_columns(connection, "meetings")
        if "audio_path" not in columns:
            connection.execute("ALTER TABLE meetings ADD COLUMN audio_path TEXT")
        if "audio_content_type" not in columns:
            connection.execute("ALTER TABLE meetings ADD COLUMN audio_content_type TEXT")

    def _ensure_voice_profiles_table(self, connection: sqlite3.Connection) -> None:
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS voice_profiles (
                id TEXT PRIMARY KEY,
                user_id TEXT NOT NULL,
                name TEXT NOT NULL,
                duration_seconds REAL,
                embedding BLOB NOT NULL,
                created_at TEXT NOT NULL,
                FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
            )
            """
        )
        connection.execute(
            "CREATE INDEX IF NOT EXISTS idx_voice_profiles_user_id ON voice_profiles (user_id)"
        )

    def _ensure_meeting_jobs_table(self, connection: sqlite3.Connection) -> None:
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS meeting_jobs (
                id TEXT PRIMARY KEY,
                user_id TEXT NOT NULL,
                audio_path TEXT NOT NULL,
                source TEXT,
                device_name TEXT,
                location_name TEXT,
                summary_mode TEXT NOT NULL DEFAULT 'reasoning',
                status TEXT NOT NULL CHECK (status IN ('queued', 'processing', 'completed', 'failed')),
                meeting_id TEXT,
                error TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
                FOREIGN KEY (meeting_id) REFERENCES meetings(id) ON DELETE SET NULL
            )
            """
        )
        connection.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_meeting_jobs_user_status
            ON meeting_jobs (user_id, status, created_at DESC)
            """
        )
        columns = self._table_columns(connection, "meeting_jobs")
        for column in ("source", "device_name", "location_name"):
            if column not in columns:
                connection.execute(f"ALTER TABLE meeting_jobs ADD COLUMN {column} TEXT")
        if "summary_mode" not in columns:
            connection.execute(
                "ALTER TABLE meeting_jobs ADD COLUMN summary_mode TEXT NOT NULL DEFAULT 'reasoning'"
            )

    def _ensure_meeting_chat_messages_table(self, connection: sqlite3.Connection) -> None:
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS meeting_chat_messages (
                id TEXT PRIMARY KEY,
                meeting_id TEXT NOT NULL,
                role TEXT NOT NULL CHECK (role IN ('user', 'assistant')),
                content TEXT NOT NULL,
                created_at TEXT NOT NULL,
                FOREIGN KEY (meeting_id) REFERENCES meetings(id) ON DELETE CASCADE
            )
            """
        )
        connection.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_meeting_chat_messages_meeting_created
            ON meeting_chat_messages (meeting_id, created_at ASC)
            """
        )

    def save_voice_profile(
        self,
        user_id: str,
        name: str,
        duration_seconds: float | None,
        embedding: bytes,
    ) -> VoiceProfileResponse:
        from datetime import UTC as _UTC

        profile_id = str(uuid4())
        created_at = datetime.now(_UTC).isoformat()
        with self._connect() as connection:
            connection.execute(
                """
                INSERT INTO voice_profiles (id, user_id, name, duration_seconds, embedding, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (profile_id, user_id, name, duration_seconds, embedding, created_at),
            )
        return VoiceProfileResponse(
            id=profile_id,
            name=name,
            durationSeconds=duration_seconds,
            createdAt=created_at,
        )

    def list_voice_profiles(self, user_id: str) -> list[VoiceProfileResponse]:
        with self._connect() as connection:
            rows = connection.execute(
                """
                SELECT id, name, duration_seconds, created_at FROM voice_profiles
                WHERE user_id = ? ORDER BY created_at DESC
                """,
                (user_id,),
            ).fetchall()
            return [
                VoiceProfileResponse(
                    id=row["id"],
                    name=row["name"],
                    durationSeconds=row["duration_seconds"],
                    createdAt=row["created_at"],
                )
                for row in rows
            ]

    def list_voice_profile_embeddings(
        self, user_id: str
    ) -> list[tuple[VoiceProfileResponse, bytes]]:
        with self._connect() as connection:
            rows = connection.execute(
                """
                SELECT id, name, duration_seconds, created_at, embedding
                FROM voice_profiles WHERE user_id = ?
                """,
                (user_id,),
            ).fetchall()
            return [
                (
                    VoiceProfileResponse(
                        id=row["id"],
                        name=row["name"],
                        durationSeconds=row["duration_seconds"],
                        createdAt=row["created_at"],
                    ),
                    row["embedding"],
                )
                for row in rows
            ]

    def delete_voice_profile(self, user_id: str, profile_id: str) -> bool:
        with self._connect() as connection:
            cursor = connection.execute(
                "DELETE FROM voice_profiles WHERE id = ? AND user_id = ?",
                (profile_id, user_id),
            )
            return cursor.rowcount > 0

    def _create_tables(self, connection: sqlite3.Connection) -> None:
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS meetings (
                id TEXT PRIMARY KEY,
                user_id TEXT,
                created_at TEXT NOT NULL,
                generated_at TEXT NOT NULL,
                title TEXT NOT NULL,
                overview TEXT NOT NULL,
                transcript TEXT NOT NULL,
                language TEXT,
                duration_seconds REAL,
                source TEXT,
                device_name TEXT,
                location_name TEXT,
                summary_status TEXT NOT NULL DEFAULT 'generated',
                summary_mode TEXT NOT NULL DEFAULT 'reasoning',
                outline_json TEXT NOT NULL DEFAULT '[]',
                segments_json TEXT NOT NULL DEFAULT '[]',
                audio_path TEXT,
                audio_content_type TEXT
            )
            """
        )
        connection.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_meetings_created_at
            ON meetings (created_at DESC)
            """
        )
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS summary_items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                meeting_id TEXT NOT NULL,
                kind TEXT NOT NULL CHECK (kind IN ('decision', 'action', 'follow_up')),
                position INTEGER NOT NULL,
                text TEXT NOT NULL,
                FOREIGN KEY (meeting_id) REFERENCES meetings(id) ON DELETE CASCADE
            )
            """
        )
        connection.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_summary_items_meeting_kind
            ON summary_items (meeting_id, kind, position)
            """
        )
        self._ensure_meeting_chat_messages_table(connection)

    def _migrate_json_blob_store(self, connection: sqlite3.Connection) -> None:
        rows = connection.execute("SELECT payload FROM meetings").fetchall()
        connection.execute("ALTER TABLE meetings RENAME TO meetings_legacy_json")
        self._create_tables(connection)

        for row in rows:
            meeting = MeetingResponse.model_validate(json.loads(row["payload"]))
            self._save_with_connection(connection, meeting)

        connection.execute("DROP TABLE meetings_legacy_json")

    def _table_columns(self, connection: sqlite3.Connection, table_name: str) -> set[str]:
        rows = connection.execute(f"PRAGMA table_info({table_name})").fetchall()
        return {row["name"] for row in rows}

    def _insert_summary_items(
        self,
        connection: sqlite3.Connection,
        meeting_id: str,
        kind: str,
        items: Iterable[str],
    ) -> None:
        connection.executemany(
            """
            INSERT INTO summary_items (meeting_id, kind, position, text)
            VALUES (?, ?, ?, ?)
            """,
            ((meeting_id, kind, index, text) for index, text in enumerate(items)),
        )

    def _save_with_connection(
        self,
        connection: sqlite3.Connection,
        meeting: MeetingResponse,
        user_id: str | None = None,
    ) -> None:
        connection.execute(
            """
            INSERT INTO meetings (
                id,
                user_id,
                created_at,
                generated_at,
                title,
                overview,
                transcript,
                language,
                duration_seconds,
                source,
                device_name,
                location_name,
                summary_status,
                summary_mode,
                outline_json,
                segments_json
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                user_id = excluded.user_id,
                created_at = excluded.created_at,
                generated_at = excluded.generated_at,
                title = excluded.title,
                overview = excluded.overview,
                transcript = excluded.transcript,
                language = excluded.language,
                duration_seconds = excluded.duration_seconds,
                source = excluded.source,
                device_name = excluded.device_name,
                location_name = excluded.location_name,
                summary_status = excluded.summary_status,
                summary_mode = excluded.summary_mode,
                outline_json = excluded.outline_json,
                segments_json = excluded.segments_json
            """,
            (
                meeting.id,
                user_id,
                meeting.createdAt.isoformat(),
                meeting.generatedAt.isoformat(),
                meeting.title,
                meeting.overview,
                meeting.transcript,
                meeting.language,
                meeting.durationSeconds,
                meeting.source,
                meeting.deviceName,
                meeting.locationName,
                meeting.summaryStatus,
                meeting.summaryMode,
                json.dumps(
                    [item.model_dump(mode="json") for item in meeting.outline],
                    ensure_ascii=False,
                ),
                json.dumps(
                    [segment.model_dump(mode="json") for segment in meeting.segments],
                    ensure_ascii=False,
                ),
            ),
        )
        connection.execute("DELETE FROM summary_items WHERE meeting_id = ?", (meeting.id,))
        self._insert_summary_items(
            connection,
            meeting.id,
            "decision",
            meeting.decisions,
        )
        self._insert_summary_items(
            connection,
            meeting.id,
            "action",
            meeting.actionItems,
        )
        self._insert_summary_items(
            connection,
            meeting.id,
            "follow_up",
            meeting.followUps,
        )

    def _meeting_from_row(
        self,
        connection: sqlite3.Connection,
        row: sqlite3.Row,
    ) -> MeetingResponse:
        items = self._summary_items_for(connection, row["id"])
        return MeetingResponse(
            id=row["id"],
            createdAt=row["created_at"],
            generatedAt=row["generated_at"],
            title=row["title"],
            overview=row["overview"],
            summaryStatus=row["summary_status"],
            summaryMode=row["summary_mode"],
            decisions=items["decision"],
            actionItems=items["action"],
            followUps=items["follow_up"],
            outline=self._decode_outline(row["outline_json"]),
            transcript=row["transcript"],
            segments=self._decode_segments(row["segments_json"]),
            language=row["language"],
            durationSeconds=row["duration_seconds"],
            source=row["source"],
            deviceName=row["device_name"],
            locationName=row["location_name"],
            hasAudio=bool(row["audio_path"]),
        )

    def _decode_outline(self, raw_value: str | None) -> list[MeetingOutlineItem]:
        return self._decode_json_items(raw_value, MeetingOutlineItem)

    def _decode_segments(self, raw_value: str | None) -> list[TranscriptSegment]:
        return self._decode_json_items(raw_value, TranscriptSegment)

    def _decode_json_items(self, raw_value: str | None, model: type) -> list:
        if not raw_value:
            return []
        try:
            payload = json.loads(raw_value)
        except json.JSONDecodeError:
            return []
        if not isinstance(payload, list):
            return []
        items = []
        for item in payload:
            try:
                items.append(model.model_validate(item))
            except Exception:  # noqa: BLE001
                continue
        return items

    def _meeting_job_from_row(
        self,
        connection: sqlite3.Connection,
        row: sqlite3.Row,
    ) -> MeetingJobResponse:
        meeting = None
        if row["meeting_id"]:
            meeting_row = connection.execute(
                "SELECT * FROM meetings WHERE id = ?",
                (row["meeting_id"],),
            ).fetchone()
            if meeting_row is not None:
                meeting = self._meeting_from_row(connection, meeting_row)

        return MeetingJobResponse(
            id=row["id"],
            status=row["status"],
            meetingId=row["meeting_id"],
            error=row["error"],
            createdAt=row["created_at"],
            updatedAt=row["updated_at"],
            meeting=meeting,
        )

    def _summary_items_for(
        self,
        connection: sqlite3.Connection,
        meeting_id: str,
    ) -> dict[str, list[str]]:
        rows = connection.execute(
            """
            SELECT kind, text FROM summary_items
            WHERE meeting_id = ?
            ORDER BY kind, position
            """,
            (meeting_id,),
        ).fetchall()
        items = {kind: [] for kind in SUMMARY_ITEM_KINDS}
        for row in rows:
            items[row["kind"]].append(row["text"])
        return items

    def _meeting_exists_for_user(
        self,
        connection: sqlite3.Connection,
        meeting_id: str,
        user_id: str,
    ) -> bool:
        row = connection.execute(
            "SELECT 1 FROM meetings WHERE id = ? AND user_id = ?",
            (meeting_id, user_id),
        ).fetchone()
        return row is not None

    def _chat_message_from_row(self, row: sqlite3.Row) -> MeetingChatMessageResponse:
        return MeetingChatMessageResponse(
            id=row["id"],
            role=row["role"],
            content=row["content"],
            createdAt=row["created_at"],
        )
