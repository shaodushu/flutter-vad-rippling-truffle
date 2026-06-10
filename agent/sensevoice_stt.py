"""STT plugin using SenseVoiceSmall via OpenAI-compatible API."""

import json
import logging
import time
from typing import AsyncIterable

import httpx
from livekit.agents import stt, utils
from livekit.agents.types import NOT_GIVEN, NotGivenOr, APIConnectOptions
from livekit.rtc import AudioFrame

logger = logging.getLogger("sensevoice-api")


class SenseVoiceAPI_STT(stt.STT):
    """SenseVoice Small ASR via HTTP API (OpenAI-compatible /v1/audio/transcriptions)."""

    def __init__(self, *, base_url: str, api_key: str, model: str = "SenseVoiceSmall"):
        super().__init__(
            capabilities=stt.STTCapabilities(streaming=False, interim_results=False),
        )
        self._base_url = base_url.rstrip("/")
        self._api_key = api_key
        self._model = model

    async def _recognize_impl(
        self,
        buffer: utils.AudioBuffer,
        *,
        language: NotGivenOr[str] = NOT_GIVEN,
        conn_options: APIConnectOptions | None = None,
    ) -> stt.SpeechEvent:
        t0 = time.time()
        pcm_bytes = _audio_buffer_to_pcm16(buffer)
        wav_bytes = _pcm_to_wav(pcm_bytes)

        logger.info("STT sending %d WAV bytes to %s", len(wav_bytes), self._model)

        async with httpx.AsyncClient(timeout=60.0) as client:
            headers = {}
            if self._api_key:
                headers["Authorization"] = f"Bearer {self._api_key}"
            resp = await client.post(
                f"{self._base_url}/v1/audio/transcriptions",
                headers=headers,
                files={"file": ("audio.wav", wav_bytes, "audio/wav")},
                data={
                    "model": self._model,
                    "language": "Chinese",
                    "response_format": "json",
                },
            )
            if resp.status_code != 200:
                logger.error("STT API error: %s %s", resp.status_code, resp.text)
                return stt.SpeechEvent(
                    type=stt.SpeechEventType.FINAL_TRANSCRIPT,
                    alternatives=[stt.SpeechData(text="", language="zh")],
                )

            result = resp.json()
            text = result.get("text", "")

            # 过滤杂音：纯标点、单字符、或仅空白 → 当作无语音
            stripped = text.strip().strip("。，.!？,.;:…、")
            if not stripped or len(stripped) <= 1:
                logger.info("STT filtered noise: %r", text)
                text = ""

            elapsed = time.time() - t0
            logger.info("STT result (%.1fs): %s", elapsed, text[:80])

        return stt.SpeechEvent(
            type=stt.SpeechEventType.FINAL_TRANSCRIPT,
            alternatives=[stt.SpeechData(text=text, language="zh")],
        )

    async def aclose(self) -> None:
        pass


def _audio_buffer_to_pcm16(buffer: utils.AudioBuffer) -> bytes:
    """Convert AudioBuffer (list of AudioFrame or single AudioFrame) to raw PCM16 bytes."""
    frames = buffer if isinstance(buffer, list) else [buffer]
    raw = bytearray()
    for f in frames:
        if isinstance(f, AudioFrame):
            raw.extend(f.data)
    return bytes(raw)


def _pcm_to_wav(pcm_bytes: bytes) -> bytes:
    """Add WAV header to raw PCM16 (mono, 16kHz)."""
    sample_rate = 16000
    bits = 16
    channels = 1
    data_size = len(pcm_bytes)
    import struct
    header = struct.pack(
        "<4sI4s4sIHHIIHH",
        b"RIFF",
        36 + data_size,
        b"WAVE",
        b"fmt ",
        16,
        1,          # PCM
        channels,
        sample_rate,
        sample_rate * channels * bits // 8,
        channels * bits // 8,
        bits,
    )
    header += struct.pack("<4sI", b"data", data_size)
    return header + pcm_bytes
