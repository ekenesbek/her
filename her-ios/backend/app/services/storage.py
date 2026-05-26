from __future__ import annotations

import json
import re
import sqlite3
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Iterable
from uuid import uuid4

from app.schemas import (
    MeetingChatMessageResponse,
    MeetingChatRunResponse,
    MeetingChatThreadResponse,
    MeetingJobResponse,
    MeetingOutlineItem,
    MeetingResponse,
    MemoryCandidateResponse,
    TranscriptSegment,
    UserResponse,
    VoiceProfileResponse,
    VoiceProfileSampleResponse,
)
from app.services.meeting_memory import build_meeting_memory_candidates
from app.services.transcript_format import format_speaker_transcript


SUMMARY_ITEM_KINDS = ("decision", "action", "follow_up")
MEETING_JOB_ACTIVE_STATUSES = ("queued", "processing")
MEETING_CHAT_RUN_STATUSES = ("running", "completed", "failed")
SPEAKER_PROFILE_NAME_RE = re.compile(r"^Speaker\s+(\d+)$", re.IGNORECASE)


@dataclass(frozen=True)
class AppleSubscriptionRecord:
    transaction_id: str
    original_transaction_id: str | None
    product_id: str
    environment: str | None
    purchase_date: datetime | None
    expires_date: datetime | None
    revocation_date: datetime | None
    created_at: datetime
    updated_at: datetime


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
        return self.get(meeting_id, user_id=user_id)

    def update_meeting_transcript(
        self,
        meeting_id: str,
        user_id: str,
        transcript: str,
        segments: list[TranscriptSegment],
    ) -> MeetingResponse | None:
        meeting = self.get(meeting_id, user_id=user_id)
        if meeting is None:
            return None
        updated = meeting.model_copy(update={"transcript": transcript, "segments": segments})
        self.save(updated, user_id=user_id)
        return self.get(meeting_id, user_id=user_id)

    def update_meeting_title(
        self,
        meeting_id: str,
        user_id: str,
        title: str,
    ) -> MeetingResponse | None:
        meeting = self.get(meeting_id, user_id=user_id)
        if meeting is None:
            return None
        updated = meeting.model_copy(update={"title": title})
        self.save(updated, user_id=user_id)
        return self.get(meeting_id, user_id=user_id)

    def delete_meeting(
        self,
        meeting_id: str,
        user_id: str,
    ) -> tuple[bool, Path | None]:
        with self._connect() as connection:
            row = connection.execute(
                """
                SELECT audio_path FROM meetings
                WHERE id = ? AND user_id = ?
                """,
                (meeting_id, user_id),
            ).fetchone()
            if row is None:
                return False, None
            audio_path = Path(row["audio_path"]) if row["audio_path"] else None
            cursor = connection.execute(
                "DELETE FROM meetings WHERE id = ? AND user_id = ?",
                (meeting_id, user_id),
            )
            return cursor.rowcount > 0, audio_path

    def list_chat_messages(
        self,
        meeting_id: str,
        user_id: str,
        limit: int = 200,
    ) -> list[MeetingChatMessageResponse]:
        with self._connect() as connection:
            if not self._meeting_exists_for_user(connection, meeting_id, user_id):
                return []
            thread = self._get_or_create_chat_thread(connection, meeting_id)
            self._attach_legacy_chat_messages_to_thread(connection, meeting_id, thread.id)
            rows = connection.execute(
                """
                SELECT * FROM meeting_chat_messages
                WHERE meeting_id = ? AND thread_id = ?
                ORDER BY created_at ASC, id ASC
                LIMIT ?
                """,
                (meeting_id, thread.id, limit),
            ).fetchall()
            return [self._chat_message_from_row(row) for row in rows]

    def get_or_create_chat_thread(
        self,
        meeting_id: str,
        user_id: str,
    ) -> MeetingChatThreadResponse | None:
        with self._connect() as connection:
            if not self._meeting_exists_for_user(connection, meeting_id, user_id):
                return None
            thread = self._get_or_create_chat_thread(connection, meeting_id)
            self._attach_legacy_chat_messages_to_thread(connection, meeting_id, thread.id)
            return thread

    def append_chat_message(
        self,
        meeting_id: str,
        user_id: str,
        role: str,
        content: str,
        run_id: str | None = None,
    ) -> MeetingChatMessageResponse:
        if role not in {"user", "assistant"}:
            raise ValueError("Invalid chat message role.")
        message_id = str(uuid4())
        now = datetime.now(UTC).isoformat()
        with self._connect() as connection:
            if not self._meeting_exists_for_user(connection, meeting_id, user_id):
                raise ValueError("Meeting not found.")
            thread = self._get_or_create_chat_thread(connection, meeting_id)
            self._attach_legacy_chat_messages_to_thread(connection, meeting_id, thread.id)
            connection.execute(
                """
                INSERT INTO meeting_chat_messages (
                    id, meeting_id, thread_id, run_id, role, content, created_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (message_id, meeting_id, thread.id, run_id, role, content, now),
            )
            connection.execute(
                "UPDATE meeting_chat_threads SET updated_at = ? WHERE id = ?",
                (now, thread.id),
            )
            row = connection.execute(
                "SELECT * FROM meeting_chat_messages WHERE id = ?",
                (message_id,),
            ).fetchone()
            return self._chat_message_from_row(row)

    def create_chat_run(
        self,
        meeting_id: str,
        user_id: str,
        model: str,
        source: str,
        prompt_message_count: int,
        prompt_character_count: int,
    ) -> MeetingChatRunResponse:
        run_id = str(uuid4())
        now = datetime.now(UTC).isoformat()
        with self._connect() as connection:
            if not self._meeting_exists_for_user(connection, meeting_id, user_id):
                raise ValueError("Meeting not found.")
            thread = self._get_or_create_chat_thread(connection, meeting_id)
            self._attach_legacy_chat_messages_to_thread(connection, meeting_id, thread.id)
            connection.execute(
                """
                INSERT INTO meeting_chat_runs (
                    id, meeting_id, thread_id, status, model, source,
                    prompt_message_count, prompt_character_count, created_at
                )
                VALUES (?, ?, ?, 'running', ?, ?, ?, ?, ?)
                """,
                (
                    run_id,
                    meeting_id,
                    thread.id,
                    model,
                    source,
                    prompt_message_count,
                    prompt_character_count,
                    now,
                ),
            )
            row = connection.execute(
                "SELECT * FROM meeting_chat_runs WHERE id = ?",
                (run_id,),
            ).fetchone()
            return self._chat_run_from_row(row)

    def complete_chat_run(
        self,
        run_id: str,
        response_message_id: str | None = None,
    ) -> None:
        self._finish_chat_run(
            run_id,
            status="completed",
            response_message_id=response_message_id,
            error=None,
        )

    def fail_chat_run(self, run_id: str, error: str) -> None:
        self._finish_chat_run(
            run_id,
            status="failed",
            response_message_id=None,
            error=error,
        )

    def _finish_chat_run(
        self,
        run_id: str,
        status: str,
        response_message_id: str | None,
        error: str | None,
    ) -> None:
        if status not in MEETING_CHAT_RUN_STATUSES:
            raise ValueError("Invalid chat run status.")
        completed_at = datetime.now(UTC).isoformat()
        with self._connect() as connection:
            connection.execute(
                """
                UPDATE meeting_chat_runs
                SET status = ?, response_message_id = ?, error = ?, completed_at = ?
                WHERE id = ?
                """,
                (status, response_message_id, error, completed_at, run_id),
            )

    def create_meeting_job(
        self,
        user_id: str,
        audio_path: Path,
        source: str | None = None,
        device_name: str | None = None,
        location_name: str | None = None,
        summary_mode: str = "reasoning",
        generate_summary: bool = True,
    ) -> MeetingJobResponse:
        job_id = str(uuid4())
        now = datetime.now(UTC).isoformat()
        with self._connect() as connection:
            connection.execute(
                """
                INSERT INTO meeting_jobs (
                    id, user_id, audio_path, source, device_name, location_name,
                    summary_mode, generate_summary, status, meeting_id, error, created_at, updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    job_id,
                    user_id,
                    str(audio_path),
                    source,
                    device_name,
                    location_name,
                    summary_mode,
                    1 if generate_summary else 0,
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
                SELECT id, user_id, audio_path, source, device_name, location_name,
                       summary_mode, generate_summary, status, meeting_id
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
                SET status = ?, meeting_id = COALESCE(?, meeting_id), error = ?, updated_at = ?
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

    def get_first_user(self) -> UserResponse | None:
        with self._connect() as connection:
            row = connection.execute(
                "SELECT * FROM users ORDER BY created_at ASC LIMIT 1"
            ).fetchone()
            return self._user_from_row(row) if row else None

    def get_user_subscription_plan(self, user_id: str) -> str:
        with self._connect() as connection:
            active_apple = self._active_apple_subscription_with_connection(
                connection,
                user_id,
                datetime.now(UTC),
            )
            if active_apple is not None:
                return "plus"
            row = connection.execute(
                "SELECT plan FROM user_subscriptions WHERE user_id = ?",
                (user_id,),
            ).fetchone()
            plan = row["plan"] if row else "free"
            return "plus" if plan == "paid" else plan

    def get_user_subscription_source(self, user_id: str) -> str:
        with self._connect() as connection:
            active_apple = self._active_apple_subscription_with_connection(
                connection,
                user_id,
                datetime.now(UTC),
            )
            if active_apple is not None:
                return "apple"
            row = connection.execute(
                "SELECT plan FROM user_subscriptions WHERE user_id = ?",
                (user_id,),
            ).fetchone()
            if row is not None and row["plan"] == "paid":
                return "manual"
            return "free"

    def set_user_subscription_plan(self, user_id: str, plan: str) -> str:
        if plan not in {"free", "plus", "paid"}:
            raise ValueError("Invalid subscription plan.")
        stored_plan = "paid" if plan in {"plus", "paid"} else "free"
        now = datetime.now(UTC).isoformat()
        with self._connect() as connection:
            connection.execute(
                """
                INSERT INTO user_subscriptions (user_id, plan, created_at, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(user_id) DO UPDATE SET
                    plan = excluded.plan,
                    updated_at = excluded.updated_at
                """,
                (user_id, stored_plan, now, now),
            )
        return "plus" if stored_plan == "paid" else "free"

    def save_apple_subscription_transaction(
        self,
        *,
        user_id: str,
        transaction_id: str,
        original_transaction_id: str | None,
        product_id: str,
        environment: str | None,
        purchase_date: datetime | None,
        expires_date: datetime | None,
        revocation_date: datetime | None,
        signed_transaction: str,
    ) -> None:
        now = datetime.now(UTC).isoformat()
        with self._connect() as connection:
            connection.execute(
                """
                INSERT INTO apple_subscription_transactions (
                    user_id,
                    transaction_id,
                    original_transaction_id,
                    product_id,
                    environment,
                    purchase_date,
                    expires_date,
                    revocation_date,
                    signed_transaction,
                    created_at,
                    updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(transaction_id) DO UPDATE SET
                    user_id = excluded.user_id,
                    original_transaction_id = excluded.original_transaction_id,
                    product_id = excluded.product_id,
                    environment = excluded.environment,
                    purchase_date = excluded.purchase_date,
                    expires_date = excluded.expires_date,
                    revocation_date = excluded.revocation_date,
                    signed_transaction = excluded.signed_transaction,
                    updated_at = excluded.updated_at
                """,
                (
                    user_id,
                    transaction_id,
                    original_transaction_id,
                    product_id,
                    environment,
                    purchase_date.isoformat() if purchase_date else None,
                    expires_date.isoformat() if expires_date else None,
                    revocation_date.isoformat() if revocation_date else None,
                    signed_transaction,
                    now,
                    now,
                ),
            )

    def active_apple_subscription(
        self,
        user_id: str,
        now: datetime | None = None,
    ) -> AppleSubscriptionRecord | None:
        with self._connect() as connection:
            return self._active_apple_subscription_with_connection(
                connection,
                user_id,
                now or datetime.now(UTC),
            )

    def recording_usage_seconds(
        self,
        user_id: str,
        period_start: datetime,
        period_end: datetime,
    ) -> float:
        with self._connect() as connection:
            row = connection.execute(
                """
                SELECT COALESCE(SUM(
                    CASE
                        WHEN duration_seconds IS NOT NULL AND duration_seconds > 0
                        THEN duration_seconds
                        ELSE 0
                    END
                ), 0) AS used_seconds
                FROM meetings
                WHERE user_id = ?
                  AND created_at >= ?
                  AND created_at < ?
                """,
                (user_id, period_start.isoformat(), period_end.isoformat()),
            ).fetchone()
            return float(row["used_seconds"] or 0)

    def _active_apple_subscription_with_connection(
        self,
        connection: sqlite3.Connection,
        user_id: str,
        now: datetime,
    ) -> AppleSubscriptionRecord | None:
        row = connection.execute(
            """
            SELECT *
            FROM apple_subscription_transactions
            WHERE user_id = ?
              AND revocation_date IS NULL
              AND expires_date IS NOT NULL
              AND expires_date > ?
            ORDER BY expires_date DESC, updated_at DESC
            LIMIT 1
            """,
            (user_id, now.isoformat()),
        ).fetchone()
        return self._apple_subscription_from_row(row) if row else None

    def _user_from_row(self, row: sqlite3.Row) -> UserResponse:
        return UserResponse(
            id=row["id"],
            provider=row["provider"],
            email=row["email"],
            name=row["name"],
            createdAt=row["created_at"],
        )

    def _apple_subscription_from_row(self, row: sqlite3.Row) -> AppleSubscriptionRecord:
        return AppleSubscriptionRecord(
            transaction_id=row["transaction_id"],
            original_transaction_id=row["original_transaction_id"],
            product_id=row["product_id"],
            environment=row["environment"],
            purchase_date=self._parse_optional_datetime(row["purchase_date"]),
            expires_date=self._parse_optional_datetime(row["expires_date"]),
            revocation_date=self._parse_optional_datetime(row["revocation_date"]),
            created_at=self._parse_datetime(row["created_at"]),
            updated_at=self._parse_datetime(row["updated_at"]),
        )

    @staticmethod
    def _parse_datetime(value: str) -> datetime:
        parsed = datetime.fromisoformat(value)
        return parsed if parsed.tzinfo else parsed.replace(tzinfo=UTC)

    @classmethod
    def _parse_optional_datetime(cls, value: str | None) -> datetime | None:
        return cls._parse_datetime(value) if value else None

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
            self._ensure_user_subscriptions_table(connection)
            self._ensure_apple_subscription_transactions_table(connection)
            self._ensure_meetings_user_id_column(connection)
            self._ensure_meeting_content_columns(connection)
            self._ensure_meeting_summary_status_column(connection)
            self._ensure_meeting_summary_mode_column(connection)
            self._ensure_meeting_audio_columns(connection)
            self._ensure_meeting_memory_candidates_table(connection)
            self._ensure_voice_profiles_table(connection)
            self._ensure_voice_profile_samples_table(connection)
            self._ensure_user_speaker_counters_table(connection)
            self._ensure_meeting_jobs_table(connection)
            self._ensure_meeting_chat_threads_table(connection)
            self._ensure_meeting_chat_runs_table(connection)
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

    def _ensure_user_subscriptions_table(self, connection: sqlite3.Connection) -> None:
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS user_subscriptions (
                user_id TEXT PRIMARY KEY,
                plan TEXT NOT NULL DEFAULT 'free' CHECK (plan IN ('free', 'paid')),
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
            )
            """
        )

    def _ensure_apple_subscription_transactions_table(self, connection: sqlite3.Connection) -> None:
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS apple_subscription_transactions (
                transaction_id TEXT PRIMARY KEY,
                user_id TEXT NOT NULL,
                original_transaction_id TEXT,
                product_id TEXT NOT NULL,
                environment TEXT,
                purchase_date TEXT,
                expires_date TEXT,
                revocation_date TEXT,
                signed_transaction TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
            )
            """
        )
        connection.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_apple_subscription_transactions_user_active
            ON apple_subscription_transactions (user_id, product_id, expires_date, revocation_date)
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

    def _ensure_meeting_memory_candidates_table(self, connection: sqlite3.Connection) -> None:
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS meeting_memory_candidates (
                id TEXT PRIMARY KEY,
                meeting_id TEXT NOT NULL,
                user_id TEXT,
                kind TEXT NOT NULL,
                text TEXT NOT NULL,
                confidence REAL NOT NULL DEFAULT 0.5,
                sensitivity TEXT NOT NULL DEFAULT 'normal',
                status TEXT NOT NULL DEFAULT 'candidate'
                    CHECK (status IN ('candidate', 'promoted', 'rejected')),
                source TEXT NOT NULL DEFAULT 'meeting_summary',
                created_at TEXT NOT NULL,
                FOREIGN KEY (meeting_id) REFERENCES meetings(id) ON DELETE CASCADE,
                FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
            )
            """
        )
        connection.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_meeting_memory_candidates_meeting
            ON meeting_memory_candidates (meeting_id, status, kind)
            """
        )
        connection.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_meeting_memory_candidates_user
            ON meeting_memory_candidates (user_id, created_at DESC)
            """
        )

    def _ensure_voice_profiles_table(self, connection: sqlite3.Connection) -> None:
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS voice_profiles (
                id TEXT PRIMARY KEY,
                user_id TEXT NOT NULL,
                name TEXT NOT NULL,
                duration_seconds REAL,
                sample_count INTEGER NOT NULL DEFAULT 1,
                embedding BLOB NOT NULL,
                created_at TEXT NOT NULL,
                FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
            )
            """
        )
        columns = self._table_columns(connection, "voice_profiles")
        if "sample_count" not in columns:
            connection.execute(
                "ALTER TABLE voice_profiles ADD COLUMN sample_count INTEGER NOT NULL DEFAULT 1"
            )
        connection.execute(
            "CREATE INDEX IF NOT EXISTS idx_voice_profiles_user_id ON voice_profiles (user_id)"
        )

    def _ensure_voice_profile_samples_table(self, connection: sqlite3.Connection) -> None:
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS voice_profile_samples (
                id TEXT PRIMARY KEY,
                profile_id TEXT NOT NULL,
                user_id TEXT NOT NULL,
                meeting_id TEXT,
                speaker_label TEXT,
                duration_seconds REAL,
                embedding BLOB NOT NULL,
                created_at TEXT NOT NULL,
                FOREIGN KEY (profile_id) REFERENCES voice_profiles(id) ON DELETE CASCADE,
                FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
                FOREIGN KEY (meeting_id) REFERENCES meetings(id) ON DELETE SET NULL
            )
            """
        )
        connection.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_voice_profile_samples_profile_created
            ON voice_profile_samples (profile_id, created_at DESC)
            """
        )

    def _ensure_user_speaker_counters_table(self, connection: sqlite3.Connection) -> None:
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS user_speaker_counters (
                user_id TEXT PRIMARY KEY,
                next_index INTEGER NOT NULL DEFAULT 1,
                updated_at TEXT NOT NULL,
                FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
            )
            """
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
                generate_summary INTEGER NOT NULL DEFAULT 1,
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
        if "generate_summary" not in columns:
            connection.execute(
                "ALTER TABLE meeting_jobs ADD COLUMN generate_summary INTEGER NOT NULL DEFAULT 1"
            )

    def _ensure_meeting_chat_threads_table(self, connection: sqlite3.Connection) -> None:
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS meeting_chat_threads (
                id TEXT PRIMARY KEY,
                meeting_id TEXT NOT NULL,
                title TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                FOREIGN KEY (meeting_id) REFERENCES meetings(id) ON DELETE CASCADE
            )
            """
        )
        connection.execute(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS idx_meeting_chat_threads_meeting
            ON meeting_chat_threads (meeting_id)
            """
        )

    def _ensure_meeting_chat_runs_table(self, connection: sqlite3.Connection) -> None:
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS meeting_chat_runs (
                id TEXT PRIMARY KEY,
                meeting_id TEXT NOT NULL,
                thread_id TEXT NOT NULL,
                status TEXT NOT NULL CHECK (status IN ('running', 'completed', 'failed')),
                model TEXT NOT NULL,
                source TEXT NOT NULL,
                prompt_message_count INTEGER NOT NULL DEFAULT 0,
                prompt_character_count INTEGER NOT NULL DEFAULT 0,
                response_message_id TEXT,
                error TEXT,
                created_at TEXT NOT NULL,
                completed_at TEXT,
                FOREIGN KEY (meeting_id) REFERENCES meetings(id) ON DELETE CASCADE,
                FOREIGN KEY (thread_id) REFERENCES meeting_chat_threads(id) ON DELETE CASCADE
            )
            """
        )
        connection.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_meeting_chat_runs_thread_created
            ON meeting_chat_runs (thread_id, created_at ASC)
            """
        )

    def _ensure_meeting_chat_messages_table(self, connection: sqlite3.Connection) -> None:
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS meeting_chat_messages (
                id TEXT PRIMARY KEY,
                meeting_id TEXT NOT NULL,
                thread_id TEXT,
                run_id TEXT,
                role TEXT NOT NULL CHECK (role IN ('user', 'assistant')),
                content TEXT NOT NULL,
                created_at TEXT NOT NULL,
                FOREIGN KEY (meeting_id) REFERENCES meetings(id) ON DELETE CASCADE,
                FOREIGN KEY (thread_id) REFERENCES meeting_chat_threads(id) ON DELETE CASCADE,
                FOREIGN KEY (run_id) REFERENCES meeting_chat_runs(id) ON DELETE SET NULL
            )
            """
        )
        columns = self._table_columns(connection, "meeting_chat_messages")
        if "thread_id" not in columns:
            connection.execute("ALTER TABLE meeting_chat_messages ADD COLUMN thread_id TEXT")
        if "run_id" not in columns:
            connection.execute("ALTER TABLE meeting_chat_messages ADD COLUMN run_id TEXT")
        connection.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_meeting_chat_messages_meeting_created
            ON meeting_chat_messages (meeting_id, created_at ASC)
            """
        )
        connection.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_meeting_chat_messages_thread_created
            ON meeting_chat_messages (thread_id, created_at ASC)
            """
        )
        connection.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_meeting_chat_messages_run
            ON meeting_chat_messages (run_id)
            """
        )

    def save_voice_profile(
        self,
        user_id: str,
        name: str,
        duration_seconds: float | None,
        embedding: bytes,
        meeting_id: str | None = None,
        speaker_label: str | None = None,
    ) -> VoiceProfileResponse:
        from datetime import UTC as _UTC

        profile_id = str(uuid4())
        sample_id = str(uuid4())
        created_at = datetime.now(_UTC).isoformat()
        with self._connect() as connection:
            connection.execute(
                """
                INSERT INTO voice_profiles (
                    id, user_id, name, duration_seconds, sample_count, embedding, created_at
                )
                VALUES (?, ?, ?, ?, 1, ?, ?)
                """,
                (profile_id, user_id, name, duration_seconds, embedding, created_at),
            )
            connection.execute(
                """
                INSERT INTO voice_profile_samples (
                    id, profile_id, user_id, meeting_id, speaker_label,
                    duration_seconds, embedding, created_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    sample_id,
                    profile_id,
                    user_id,
                    meeting_id,
                    speaker_label,
                    duration_seconds,
                    embedding,
                    created_at,
                ),
            )
            self._advance_speaker_counter_past_name(connection, user_id, name)
        return VoiceProfileResponse(
            id=profile_id,
            name=name,
            durationSeconds=duration_seconds,
            sampleCount=1,
            createdAt=created_at,
        )

    def list_voice_profiles(self, user_id: str) -> list[VoiceProfileResponse]:
        with self._connect() as connection:
            rows = connection.execute(
                """
                SELECT id, name, duration_seconds, sample_count, created_at FROM voice_profiles
                WHERE user_id = ? ORDER BY created_at DESC
                """,
                (user_id,),
            ).fetchall()
            return [
                VoiceProfileResponse(
                    id=row["id"],
                    name=row["name"],
                    durationSeconds=row["duration_seconds"],
                    sampleCount=row["sample_count"],
                    createdAt=row["created_at"],
                )
                for row in rows
            ]

    def next_speaker_profile_name(self, user_id: str) -> str:
        with self._connect() as connection:
            row = connection.execute(
                "SELECT next_index FROM user_speaker_counters WHERE user_id = ?",
                (user_id,),
            ).fetchone()
            max_existing = self._max_existing_speaker_profile_index(connection, user_id)
            next_index = max(int(row["next_index"]) if row else 1, max_existing + 1)
            now = datetime.now(UTC).isoformat()
            connection.execute(
                """
                INSERT INTO user_speaker_counters (user_id, next_index, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(user_id) DO UPDATE SET
                    next_index = excluded.next_index,
                    updated_at = excluded.updated_at
                """,
                (user_id, next_index + 1, now),
            )
            return f"Speaker {next_index}"

    def _max_existing_speaker_profile_index(
        self,
        connection: sqlite3.Connection,
        user_id: str,
    ) -> int:
        rows = connection.execute(
            "SELECT name FROM voice_profiles WHERE user_id = ?",
            (user_id,),
        ).fetchall()
        max_index = 0
        for row in rows:
            match = SPEAKER_PROFILE_NAME_RE.match((row["name"] or "").strip())
            if match:
                max_index = max(max_index, int(match.group(1)))
        return max_index

    def _advance_speaker_counter_past_name(
        self,
        connection: sqlite3.Connection,
        user_id: str,
        name: str | None,
    ) -> None:
        match = SPEAKER_PROFILE_NAME_RE.match((name or "").strip())
        if not match:
            return
        min_next_index = int(match.group(1)) + 1
        row = connection.execute(
            "SELECT next_index FROM user_speaker_counters WHERE user_id = ?",
            (user_id,),
        ).fetchone()
        next_index = max(int(row["next_index"]) if row else 1, min_next_index)
        now = datetime.now(UTC).isoformat()
        connection.execute(
            """
            INSERT INTO user_speaker_counters (user_id, next_index, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(user_id) DO UPDATE SET
                next_index = MAX(user_speaker_counters.next_index, excluded.next_index),
                updated_at = excluded.updated_at
            """,
            (user_id, next_index, now),
        )

    def list_voice_profile_embeddings(
        self, user_id: str
    ) -> list[tuple[VoiceProfileResponse, bytes]]:
        with self._connect() as connection:
            rows = connection.execute(
                """
                SELECT id, name, duration_seconds, sample_count, created_at, embedding
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
                        sampleCount=row["sample_count"],
                        createdAt=row["created_at"],
                    ),
                    row["embedding"],
                )
                for row in rows
            ]

    def get_voice_profile_embedding(
        self,
        user_id: str,
        profile_id: str,
    ) -> tuple[VoiceProfileResponse, bytes] | None:
        with self._connect() as connection:
            row = connection.execute(
                """
                SELECT id, name, duration_seconds, sample_count, created_at, embedding
                FROM voice_profiles WHERE id = ? AND user_id = ?
                """,
                (profile_id, user_id),
            ).fetchone()
            if row is None:
                return None
            return (
                VoiceProfileResponse(
                    id=row["id"],
                    name=row["name"],
                    durationSeconds=row["duration_seconds"],
                    sampleCount=row["sample_count"],
                    createdAt=row["created_at"],
                ),
                row["embedding"],
            )

    def find_voice_profile_by_name(
        self,
        user_id: str,
        name: str,
    ) -> tuple[VoiceProfileResponse, bytes] | None:
        normalized = name.strip().casefold()
        if not normalized:
            return None
        for profile, embedding in self.list_voice_profile_embeddings(user_id):
            if profile.name.strip().casefold() == normalized:
                return profile, embedding
        return None

    def rename_voice_profile(
        self,
        user_id: str,
        profile_id: str,
        name: str,
    ) -> VoiceProfileResponse | None:
        clean_name = name.strip()
        if not clean_name:
            raise ValueError("Voice profile name is required.")
        with self._connect() as connection:
            row = connection.execute(
                """
                SELECT id, name, duration_seconds, sample_count, created_at
                FROM voice_profiles WHERE id = ? AND user_id = ?
                """,
                (profile_id, user_id),
            ).fetchone()
            if row is None:
                return None

            duplicate = connection.execute(
                """
                SELECT id FROM voice_profiles
                WHERE user_id = ? AND lower(name) = lower(?) AND id != ?
                LIMIT 1
                """,
                (user_id, clean_name, profile_id),
            ).fetchone()
            if duplicate is not None:
                raise ValueError("A voice profile with that name already exists.")

            old_name = row["name"]
            self._advance_speaker_counter_past_name(connection, user_id, old_name)
            connection.execute(
                "UPDATE voice_profiles SET name = ? WHERE id = ? AND user_id = ?",
                (clean_name, profile_id, user_id),
            )
            self._advance_speaker_counter_past_name(connection, user_id, clean_name)
            self._rename_speaker_in_user_meetings(connection, user_id, old_name, clean_name)
            return VoiceProfileResponse(
                id=row["id"],
                name=clean_name,
                durationSeconds=row["duration_seconds"],
                sampleCount=row["sample_count"],
                createdAt=row["created_at"],
            )

    def list_voice_profile_samples(
        self,
        user_id: str,
        profile_id: str,
    ) -> list[VoiceProfileSampleResponse]:
        with self._connect() as connection:
            if not self._voice_profile_exists_for_user(connection, user_id, profile_id):
                return []
            rows = connection.execute(
                """
                SELECT samples.id, samples.profile_id, samples.meeting_id,
                       samples.speaker_label, samples.duration_seconds,
                       samples.created_at, meetings.audio_path
                FROM voice_profile_samples samples
                LEFT JOIN meetings ON meetings.id = samples.meeting_id
                WHERE samples.user_id = ? AND samples.profile_id = ?
                ORDER BY samples.created_at DESC
                """,
                (user_id, profile_id),
            ).fetchall()
            return [
                VoiceProfileSampleResponse(
                    id=row["id"],
                    profileId=row["profile_id"],
                    meetingId=row["meeting_id"],
                    speakerLabel=row["speaker_label"],
                    durationSeconds=row["duration_seconds"],
                    hasAudio=bool(row["audio_path"]),
                    createdAt=row["created_at"],
                )
                for row in rows
            ]

    def get_voice_profile_sample_payload(
        self,
        user_id: str,
        profile_id: str,
        sample_id: str,
    ) -> dict | None:
        with self._connect() as connection:
            row = connection.execute(
                """
                SELECT samples.id, samples.profile_id, samples.meeting_id,
                       samples.speaker_label, samples.duration_seconds,
                       samples.created_at, profiles.name AS profile_name,
                       meetings.audio_path, meetings.audio_content_type
                FROM voice_profile_samples samples
                JOIN voice_profiles profiles
                  ON profiles.id = samples.profile_id
                 AND profiles.user_id = samples.user_id
                LEFT JOIN meetings ON meetings.id = samples.meeting_id
                WHERE samples.user_id = ?
                  AND samples.profile_id = ?
                  AND samples.id = ?
                """,
                (user_id, profile_id, sample_id),
            ).fetchone()
            return dict(row) if row else None

    def add_voice_profile_sample(
        self,
        user_id: str,
        profile_id: str,
        duration_seconds: float | None,
        embedding: bytes,
        updated_embedding: bytes,
        meeting_id: str | None = None,
        speaker_label: str | None = None,
    ) -> VoiceProfileResponse | None:
        sample_id = str(uuid4())
        created_at = datetime.now(UTC).isoformat()
        with self._connect() as connection:
            row = connection.execute(
                """
                SELECT id, name, duration_seconds, sample_count, created_at
                FROM voice_profiles WHERE id = ? AND user_id = ?
                """,
                (profile_id, user_id),
            ).fetchone()
            if row is None:
                return None

            current_duration = row["duration_seconds"]
            total_duration = (
                (current_duration or 0.0) + duration_seconds
                if duration_seconds is not None
                else current_duration
            )
            sample_count = int(row["sample_count"] or 1) + 1
            connection.execute(
                """
                INSERT INTO voice_profile_samples (
                    id, profile_id, user_id, meeting_id, speaker_label,
                    duration_seconds, embedding, created_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    sample_id,
                    profile_id,
                    user_id,
                    meeting_id,
                    speaker_label,
                    duration_seconds,
                    embedding,
                    created_at,
                ),
            )
            connection.execute(
                """
                UPDATE voice_profiles
                SET duration_seconds = ?, sample_count = ?, embedding = ?
                WHERE id = ? AND user_id = ?
                """,
                (total_duration, sample_count, updated_embedding, profile_id, user_id),
            )

            return VoiceProfileResponse(
                id=row["id"],
                name=row["name"],
                durationSeconds=total_duration,
                sampleCount=sample_count,
                createdAt=row["created_at"],
            )

    def delete_voice_profile(self, user_id: str, profile_id: str) -> bool:
        with self._connect() as connection:
            row = connection.execute(
                "SELECT name FROM voice_profiles WHERE id = ? AND user_id = ?",
                (profile_id, user_id),
            ).fetchone()
            if row is not None:
                self._advance_speaker_counter_past_name(connection, user_id, row["name"])
            cursor = connection.execute(
                "DELETE FROM voice_profiles WHERE id = ? AND user_id = ?",
                (profile_id, user_id),
            )
            return cursor.rowcount > 0

    def _voice_profile_exists_for_user(
        self,
        connection: sqlite3.Connection,
        user_id: str,
        profile_id: str,
    ) -> bool:
        row = connection.execute(
            "SELECT 1 FROM voice_profiles WHERE id = ? AND user_id = ?",
            (profile_id, user_id),
        ).fetchone()
        return row is not None

    def _rename_speaker_in_user_meetings(
        self,
        connection: sqlite3.Connection,
        user_id: str,
        old_name: str,
        new_name: str,
    ) -> None:
        if old_name.strip().casefold() == new_name.strip().casefold():
            return
        rows = connection.execute(
            """
            SELECT id, segments_json FROM meetings
            WHERE user_id = ? AND segments_json IS NOT NULL
            """,
            (user_id,),
        ).fetchall()
        for row in rows:
            segments = self._decode_segments(row["segments_json"])
            changed = False
            updated_segments = []
            for segment in segments:
                if (segment.speaker or "").strip().casefold() == old_name.strip().casefold():
                    updated_segments.append(segment.model_copy(update={"speaker": new_name}))
                    changed = True
                else:
                    updated_segments.append(segment)
            if not changed:
                continue
            connection.execute(
                """
                UPDATE meetings
                SET transcript = ?, segments_json = ?
                WHERE id = ? AND user_id = ?
                """,
                (
                    format_speaker_transcript(updated_segments),
                    json.dumps(
                        [segment.model_dump(mode="json") for segment in updated_segments],
                        ensure_ascii=False,
                    ),
                    row["id"],
                    user_id,
                ),
            )

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
        self._ensure_meeting_memory_candidates_table(connection)
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
        self._replace_meeting_memory_candidates(connection, meeting, user_id)

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
            memoryCandidates=self._memory_candidates_for(connection, row["id"]),
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

    def _replace_meeting_memory_candidates(
        self,
        connection: sqlite3.Connection,
        meeting: MeetingResponse,
        user_id: str | None,
    ) -> None:
        candidates = [
            candidate
            for candidate in build_meeting_memory_candidates(meeting)
            if candidate.text
        ]
        if not candidates:
            connection.execute(
                """
                DELETE FROM meeting_memory_candidates
                WHERE meeting_id = ? AND source IN ('meeting_summary', 'call_summary')
                """,
                (meeting.id,),
            )
            return

        now = datetime.now(UTC).isoformat()
        connection.executemany(
            """
            INSERT INTO meeting_memory_candidates (
                id, meeting_id, user_id, kind, text, confidence,
                sensitivity, status, source, created_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, 'candidate', ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                user_id = excluded.user_id,
                kind = excluded.kind,
                text = excluded.text,
                confidence = excluded.confidence,
                sensitivity = excluded.sensitivity,
                source = excluded.source
            """,
            (
                (
                    candidate.stable_key,
                    meeting.id,
                    user_id,
                    candidate.kind,
                    candidate.text,
                    candidate.confidence,
                    candidate.sensitivity,
                    candidate.source,
                    now,
                )
                for candidate in candidates
            ),
        )
        placeholders = ", ".join("?" for _ in candidates)
        connection.execute(
            f"""
            DELETE FROM meeting_memory_candidates
            WHERE meeting_id = ?
              AND source IN ('meeting_summary', 'call_summary')
              AND id NOT IN ({placeholders})
            """,
            (meeting.id, *(candidate.stable_key for candidate in candidates)),
        )

    def _memory_candidates_for(
        self,
        connection: sqlite3.Connection,
        meeting_id: str,
    ) -> list[MemoryCandidateResponse]:
        rows = connection.execute(
            """
            SELECT *
            FROM meeting_memory_candidates
            WHERE meeting_id = ?
            ORDER BY created_at ASC, kind ASC, id ASC
            """,
            (meeting_id,),
        ).fetchall()
        return [
            MemoryCandidateResponse(
                id=row["id"],
                meetingId=row["meeting_id"],
                kind=row["kind"],
                text=row["text"],
                confidence=float(row["confidence"] or 0.5),
                sensitivity=row["sensitivity"],
                status=row["status"],
                source=row["source"],
                createdAt=row["created_at"],
            )
            for row in rows
        ]

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

    def _get_or_create_chat_thread(
        self,
        connection: sqlite3.Connection,
        meeting_id: str,
    ) -> MeetingChatThreadResponse:
        row = connection.execute(
            """
            SELECT * FROM meeting_chat_threads
            WHERE meeting_id = ?
            ORDER BY created_at ASC
            LIMIT 1
            """,
            (meeting_id,),
        ).fetchone()
        if row is not None:
            return self._chat_thread_from_row(row)

        thread_id = str(uuid4())
        now = datetime.now(UTC).isoformat()
        connection.execute(
            """
            INSERT INTO meeting_chat_threads (id, meeting_id, title, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?)
            """,
            (thread_id, meeting_id, "Recording chat", now, now),
        )
        row = connection.execute(
            "SELECT * FROM meeting_chat_threads WHERE id = ?",
            (thread_id,),
        ).fetchone()
        return self._chat_thread_from_row(row)

    def _attach_legacy_chat_messages_to_thread(
        self,
        connection: sqlite3.Connection,
        meeting_id: str,
        thread_id: str,
    ) -> None:
        connection.execute(
            """
            UPDATE meeting_chat_messages
            SET thread_id = ?
            WHERE meeting_id = ? AND thread_id IS NULL
            """,
            (thread_id, meeting_id),
        )

    def _chat_thread_from_row(self, row: sqlite3.Row) -> MeetingChatThreadResponse:
        return MeetingChatThreadResponse(
            id=row["id"],
            meetingId=row["meeting_id"],
            title=row["title"],
            createdAt=row["created_at"],
            updatedAt=row["updated_at"],
        )

    def _chat_run_from_row(self, row: sqlite3.Row) -> MeetingChatRunResponse:
        return MeetingChatRunResponse(
            id=row["id"],
            threadId=row["thread_id"],
            status=row["status"],
            model=row["model"],
            source=row["source"],
            promptMessageCount=row["prompt_message_count"],
            promptCharacterCount=row["prompt_character_count"],
            responseMessageId=row["response_message_id"],
            error=row["error"],
            createdAt=row["created_at"],
            completedAt=row["completed_at"],
        )

    def _chat_message_from_row(self, row: sqlite3.Row) -> MeetingChatMessageResponse:
        return MeetingChatMessageResponse(
            id=row["id"],
            role=row["role"],
            content=row["content"],
            createdAt=row["created_at"],
            threadId=row["thread_id"],
            runId=row["run_id"],
        )
