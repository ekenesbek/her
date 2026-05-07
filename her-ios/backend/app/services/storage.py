from __future__ import annotations

import json
import sqlite3
from datetime import UTC, datetime
from pathlib import Path
from typing import Iterable
from uuid import uuid4

from app.schemas import MeetingResponse, UserResponse, VoiceProfileResponse


SUMMARY_ITEM_KINDS = ("decision", "action", "follow_up")


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
            self._ensure_voice_profiles_table(connection)

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
                created_at TEXT NOT NULL,
                generated_at TEXT NOT NULL,
                title TEXT NOT NULL,
                overview TEXT NOT NULL,
                transcript TEXT NOT NULL,
                language TEXT,
                duration_seconds REAL,
                source TEXT,
                device_name TEXT,
                location_name TEXT
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
            INSERT OR REPLACE INTO meetings (
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
                location_name
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            decisions=items["decision"],
            actionItems=items["action"],
            followUps=items["follow_up"],
            transcript=row["transcript"],
            language=row["language"],
            durationSeconds=row["duration_seconds"],
            source=row["source"],
            deviceName=row["device_name"],
            locationName=row["location_name"],
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
