"""LiveKit Agents entrypoint.

Run locally against the LiveKit Cloud dev playground:

    python -m voice_agent.main dev

Production worker:

    python -m voice_agent.main start
"""

from __future__ import annotations

import logging

from livekit.agents import (
    Agent,
    AgentSession,
    AutoSubscribe,
    JobContext,
    WorkerOptions,
    cli,
)
from livekit.plugins import anthropic, cartesia, deepgram, silero

from .config import Config
from .prompts import build_session_prompt
from .tools import VoiceAgentTools

logger = logging.getLogger("voice_agent")


async def entrypoint(ctx: JobContext) -> None:
    """Invoked by the LiveKit worker once per call."""
    cfg = Config.from_env()
    logging.basicConfig(level=cfg.log_level)

    await ctx.connect(auto_subscribe=AutoSubscribe.AUDIO_ONLY)
    logger.info("connected to room=%s", ctx.room.name)

    tools = VoiceAgentTools(
        backend_url=cfg.her_backend_url,
        backend_token=cfg.her_backend_token,
        on_end=ctx.shutdown,
    )

    agent = Agent(
        instructions=build_session_prompt(),
        tools=tools.as_tool_list(),
    )

    session = AgentSession(
        vad=silero.VAD.load(),
        stt=deepgram.STT(api_key=cfg.deepgram_api_key, model="nova-3", language="multi"),
        llm=anthropic.LLM(api_key=cfg.anthropic_api_key, model=cfg.anthropic_model),
        tts=cartesia.TTS(
            api_key=cfg.cartesia_api_key,
            voice=cfg.cartesia_voice_id,
            model="sonic-2",
        ),
        # Turn detector: combines silence floor with a semantic classifier so the
        # agent doesn't cut in during natural hesitations.
        min_endpointing_delay=cfg.turn_silence_ms / 1000.0,
    )

    await session.start(room=ctx.room, agent=agent)

    # Greet the user so they hear something within the first second of the call.
    await session.generate_reply(
        instructions="Greet the user briefly in their last-used language. Ask how you can help."
    )


def main() -> None:
    cli.run_app(WorkerOptions(entrypoint_fnc=entrypoint))


if __name__ == "__main__":
    main()
