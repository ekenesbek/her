from __future__ import annotations

import json
import sqlite3
from pathlib import Path
from typing import Iterable

from app.schemas import MeetingResponse


SUMMARY_ITEM_KINDS = ("decision", "action", "follow_up")


class MeetingStore:
    def __init__(self, data_dir: Path):
        self.db_path = data_dir / "meetings.sqlite3"
        self._init_db()

    def save(self, meeting: MeetingResponse) -> None:
        with self._connect() as connection:
            self._save_with_connection(connection, meeting)

    def list(self, limit: int = 50) -> list[MeetingResponse]:
        with self._connect() as connection:
            rows = connection.execute(
                """
                SELECT * FROM meetings
                ORDER BY created_at DESC
                LIMIT ?
                """,
                (limit,),
            ).fetchall()
            return [self._meeting_from_row(connection, row) for row in rows]

    def get(self, meeting_id: str) -> MeetingResponse | None:
        with self._connect() as connection:
            row = connection.execute(
                "SELECT * FROM meetings WHERE id = ?",
                (meeting_id,),
            ).fetchone()
            if row is None:
                return None
            return self._meeting_from_row(connection, row)

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
    ) -> None:
        connection.execute(
            """
            INSERT OR REPLACE INTO meetings (
                id,
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
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                meeting.id,
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
