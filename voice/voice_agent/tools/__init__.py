"""Tool surface for the voice agent. Bridges to the Her backend and OS."""

from __future__ import annotations

import logging
from typing import Awaitable, Callable, Optional

import httpx
from livekit.agents import llm

logger = logging.getLogger("voice_agent.tools")


class VoiceAgentTools:
    """Container so tools can share an HTTP client and shutdown hook."""

    def __init__(
        self,
        backend_url: Optional[str],
        backend_token: Optional[str],
        on_end: Callable[[], Awaitable[None] | None],
    ) -> None:
        self._backend_url = backend_url
        self._on_end = on_end
        self._http = (
            httpx.AsyncClient(
                base_url=backend_url,
                headers={"Authorization": f"Bearer {backend_token}"} if backend_token else {},
                timeout=10.0,
            )
            if backend_url
            else None
        )

    def as_tool_list(self) -> list[llm.FunctionTool]:
        return [
            llm.FunctionTool(self.search_meetings),
            llm.FunctionTool(self.recall_memory),
            llm.FunctionTool(self.end_conversation),
        ]

    async def search_meetings(self, query: str) -> str:
        """Search the user's recorded meetings for content matching the query.

        Args:
            query: Natural-language search query (e.g. "what did we agree about Q3 hiring").

        Returns:
            A short summary of the top matches, formatted for speech.
        """
        if not self._http:
            return "Meetings backend is not configured."
        try:
            r = await self._http.get("/v1/meetings/search", params={"q": query, "limit": 3})
            r.raise_for_status()
            items = r.json().get("items", [])
        except httpx.HTTPError as exc:
            logger.warning("search_meetings failed: %s", exc)
            return "I couldn't reach the meetings service right now."

        if not items:
            return "I didn't find any matching meetings."
        lines = [f"{m.get('title', 'untitled')}: {m.get('summary', '')[:200]}" for m in items]
        return " | ".join(lines)

    async def recall_memory(self, query: str) -> str:
        """Recall a fact the user previously asked the agent to remember.

        Args:
            query: What to look up (e.g. "where did I park", "wife's birthday").
        """
        if not self._http:
            return "Memory backend is not configured."
        try:
            r = await self._http.get("/v1/memory/recall", params={"q": query})
            r.raise_for_status()
            answer = r.json().get("answer")
        except httpx.HTTPError as exc:
            logger.warning("recall_memory failed: %s", exc)
            return "I couldn't reach memory right now."
        return answer or "I don't have anything saved about that."

    async def end_conversation(self) -> str:
        """End the voice session. Use when the user says bye, finish, or similar."""
        logger.info("end_conversation called")
        result = self._on_end()
        if hasattr(result, "__await__"):
            await result  # type: ignore[func-returns-value]
        return "Goodbye."
