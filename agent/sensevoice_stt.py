"""STT plugin using Qwen3-ASR via HTTP API (OpenAI-compatible /v1/audio/transcriptions)."""

import json
import logging
import struct
import time
from typing import AsyncIterable

import httpx
from livekit.agents import stt, utils
from livekit.agents.types import NOT_GIVEN, NotGivenOr, APIConnectOptions
from livekit.rtc import AudioFrame

logger = logging.getLogger("sensevoice-api")


class SenseVoiceAPI_STT(stt.STT):
    """Qwen3-ASR via HTTP API (OpenAI-compatible /v1/audio/transcriptions)."""

    def __init__(self, *, base_url: str, api_key: str, model: str = "qwen3-asr"):
        super().__init__(
            capabilities=stt.STTCapabilities(streaming=False, interim_results=False),
        )
        self._base_url = base_url.rstrip("/")
        self._api_key = api_key
        self._model = model
        self.context_prompt: str = ""

    async def _recognize_impl(
        self,
        buffer: utils.AudioBuffer,
        *,
        language: NotGivenOr[str] = NOT_GIVEN,
        conn_options: APIConnectOptions | None = None,
    ) -> stt.SpeechEvent:
        t0 = time.time()
        pcm_bytes, sample_rate = _audio_buffer_to_pcm16(buffer)
        wav_bytes = _pcm_to_wav(pcm_bytes, sample_rate)

        logger.info("STT sending %d WAV bytes (%d Hz) to %s", len(wav_bytes), sample_rate, self._model)

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
                    "language": "zh",
                    "response_format": "json",
                    "enable_itn": "true",
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


def _audio_buffer_to_pcm16(buffer: utils.AudioBuffer) -> tuple[bytes, int]:
    """Convert AudioBuffer (list of AudioFrame or single AudioFrame) to raw PCM16 bytes.

    Returns (pcm_bytes, sample_rate) using the sample rate from the first frame.
    """
    frames = buffer if isinstance(buffer, list) else [buffer]
    sample_rate = 16000  # fallback
    raw = bytearray()
    for f in frames:
        if isinstance(f, AudioFrame):
            if f.sample_rate > 0:
                sample_rate = f.sample_rate
            raw.extend(f.data)
    return bytes(raw), sample_rate


def _pcm_to_wav(pcm_bytes: bytes, sample_rate: int = 16000) -> bytes:
    """Add WAV header to raw PCM16 (mono)."""
    bits = 16
    channels = 1
    data_size = len(pcm_bytes)
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


def _resample_pcm16(data: bytes, src_rate: int, dst_rate: int) -> bytes:
    """线性重采样 PCM16 到目标采样率。"""
    if src_rate == dst_rate:
        return data
    samples_in = len(data) // 2
    samples_out = int(samples_in * dst_rate / src_rate)
    import array
    arr_in = array.array('h')
    arr_in.frombytes(data)
    arr_out = array.array('h', [0]) * samples_out
    for i in range(samples_out):
        src_idx = i * src_rate / dst_rate
        lo = int(src_idx)
        hi = min(lo + 1, samples_in - 1)
        frac = src_idx - lo
        arr_out[i] = int(arr_in[lo] * (1 - frac) + arr_in[hi] * frac)
    return arr_out.tobytes()
