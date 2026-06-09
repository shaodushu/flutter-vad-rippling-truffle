"""TTS plugin using edge-tts (no model download needed)."""

import asyncio
import logging
import subprocess
from livekit.agents import tts, utils

logger = logging.getLogger("edge-tts")


class EdgeTTSPlugin(tts.TTS):
    """Text-to-speech using Microsoft Edge TTS (free, instant)."""

    def __init__(self, voice: str = "zh-CN-XiaoxiaoNeural"):
        super().__init__(
            capabilities=tts.TTSCapabilities(streaming=False),
            sample_rate=24000,
            num_channels=1,
        )
        self._voice = voice

    async def synthesize(
        self, *, text: str, language: str | None = None
    ) -> utils.AudioBuffer:
        import edge_tts

        communicate = edge_tts.Communicate(text, self._voice)
        mp3_data = b""
        async for chunk in communicate.stream():
            if chunk["type"] == "audio":
                mp3_data += chunk["data"]

        # Convert MP3 to PCM16 via ffmpeg
        proc = await asyncio.create_subprocess_exec(
            "ffmpeg", "-i", "pipe:0", "-f", "s16le", "-ar", "24000",
            "-ac", "1", "-loglevel", "error", "pipe:1",
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        pcm_data, stderr = await proc.communicate(mp3_data)

        if proc.returncode != 0:
            raise RuntimeError(f"ffmpeg error: {stderr.decode()}")

        return utils.AudioBuffer(
            data=pcm_data,
            sample_rate=24000,
            num_channels=1,
        )
