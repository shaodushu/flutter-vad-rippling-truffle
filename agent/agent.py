"""
LiveKit Voice Agent — edge-tts TTS + DeepSeek LLM
Connects to LiveKit room for voice conversations.

Usage:
  export LLM_API_KEY=sk-xxx
  export LLM_BASE_URL=https://api.deepseek.com
  python agent.py --url ws://localhost:7880 --api-key devkey --api-secret secret
"""

import argparse
import asyncio
import json
import logging
import os
import time

import jwt
from livekit import rtc
from livekit.agents.voice import Agent, AgentSession
from livekit.plugins import openai, silero
from livekit.agents.voice.turn import TurnHandlingOptions
from chattts_tts import EdgeTTSPlugin
from funasr_stt import PlaceholderSTT

logger = logging.getLogger("voice-agent")


class VoiceAgent(Agent):
    """Custom agent that sends state updates via data channel."""

    def __init__(self, room: rtc.Room, **kwargs):
        super().__init__(**kwargs)
        self._room = room

    async def _send(self, type_: str):
        try:
            await self._room.local_participant.publish_data(
                json.dumps({"type": type_}).encode()
            )
        except Exception:
            pass

    async def on_enter(self) -> None:
        await self._send("agent_speaking")
        return await super().on_enter()

    async def on_exit(self) -> None:
        await self._send("agent_finished")
        return await super().on_exit()


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--api-key", required=True)
    parser.add_argument("--api-secret", required=True)
    parser.add_argument("--room", default="voice-demo")
    parser.add_argument("--identity", default="voice-agent")
    parser.add_argument("--llm-api-key", default=os.environ.get("LLM_API_KEY", ""))
    parser.add_argument("--llm-base-url", default=os.environ.get("LLM_BASE_URL", "https://api.deepseek.com"))
    parser.add_argument("--llm-model", default=os.environ.get("LLM_MODEL", "deepseek-chat"))
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO)

    # Generate agent JWT token
    token = jwt.encode({
        "iss": args.api_key,
        "sub": args.identity,
        "exp": int(time.time()) + 3600,
        "video": {"roomJoin": True, "room": args.room, "canPublish": True, "canSubscribe": True, "canPublishData": True},
    }, args.api_secret, algorithm="HS256")

    # Connect to room
    room = rtc.Room()
    await room.connect(args.url, token)
    logger.info("connected to room %s as %s", args.room, args.identity)

    # Create DeepSeek LLM
    llm_instance = openai.LLM(
        model=args.llm_model,
        base_url=args.llm_base_url,
        api_key=args.llm_api_key,
    )

    # Turn handling config (replaces allow_interruptions)
    turn = TurnHandlingOptions(
        allow_interruptions=True,
        min_endpointing_delay=0.5,
    )

    # Create the agent
    agent = VoiceAgent(
        room=room,
        instructions="你是一个友好的中文语音助手。请用中文简洁自然地回答用户的问题。",
        stt=PlaceholderSTT(),
        llm=llm_instance,
        tts=EdgeTTSPlugin(),
        vad=silero.VAD.load(),
        turn_handling=turn,
    )

    # Start session
    session = AgentSession(
        vad=silero.VAD.load(),
        stt=PlaceholderSTT(),
        llm=llm_instance,
        tts=EdgeTTSPlugin(),
        turn_handling=turn,
    )
    session_task = asyncio.create_task(session.start(agent, room=room))
    logger.info("voice agent ready")

    try:
        while True:
            await asyncio.sleep(1)
    except KeyboardInterrupt:
        pass
    finally:
        session_task.cancel()
        await session.aclose()
        await room.disconnect()


if __name__ == "__main__":
    asyncio.run(main())
