"""TTS adapter shims.

Default: Cartesia Sonic-2 (wired in voice_agent.main).

To self-host Sesame CSM-1B, add `csm.py` here that wraps a local FastAPI server
running the model from https://github.com/SesameAILabs/csm, and swap the `tts=`
line in `voice_agent.main` to use it. ARCHITECTURE.md has the deployment notes.
"""
