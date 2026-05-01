import json
import sqlite3
from pathlib import Path

from app.schemas import MeetingResponse


class MeetingStore:
    def __init__(self, data_dir: Path):
        self.db_path = data_dir / "meetings.sqlite3"
        self._init_db()

    def save(self, meeting: MeetingResponse) -> None:
        with sqlite3.connect(self.db_path) as connection:
            connection.execute(
                """
                INSERT OR REPLACE INTO meetings (id, created_at, payload)
                VALUES (?, ?, ?)
                """,
                (
                    meeting.id,
                    meeting.createdAt.isoformat(),
                    meeting.model_dump_json(),
                ),
            )

    def list(self, limit: int = 50) -> list[MeetingResponse]:
        with sqlite3.connect(self.db_path) as connection:
            rows = connection.execute(
                """
                SELECT payload FROM meetings
                ORDER BY created_at DESC
                LIMIT ?
                """,
                (limit,),
            ).fetchall()
        return [MeetingResponse.model_validate(json.loads(row[0])) for row in rows]

    def get(self, meeting_id: str) -> MeetingResponse | None:
        with sqlite3.connect(self.db_path) as connection:
            row = connection.execute(
                "SELECT payload FROM meetings WHERE id = ?",
                (meeting_id,),
            ).fetchone()
        if row is None:
            return None
        return MeetingResponse.model_validate(json.loads(row[0]))

    def _init_db(self) -> None:
        with sqlite3.connect(self.db_path) as connection:
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS meetings (
                    id TEXT PRIMARY KEY,
                    created_at TEXT NOT NULL,
                    payload TEXT NOT NULL
                )
                """
            )

