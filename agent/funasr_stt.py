"""STT plugin using FunASR WebSocket service."""

import audioop
import json
import logging
import ssl
from livekit.agents import stt, utils
from livekit.agents.stt import SpeechEventType
from livekit.agents.types import NOT_GIVEN, NotGivenOr, APIConnectOptions

logger = logging.getLogger("funasr-stt")

TARGET_SAMPLE_RATE = 16000


def _resample_to_16khz(data: bytes, sample_rate: int) -> bytes:
    """Resample PCM16 mono audio to 16kHz if needed."""
    if sample_rate == TARGET_SAMPLE_RATE:
        return data
    # audioop.ratecv requires 2-byte sample size and 1 channel
    result, _ = audioop.ratecv(data, 2, 1, sample_rate, TARGET_SAMPLE_RATE, None)
    return result


class FunASRSTT(stt.STT):
    """Speech-to-text using FunASR WebSocket API."""

    def __init__(self, ws_url: str = "ws://localhost:10095"):
        super().__init__(
            capabilities=stt.STTCapabilities(streaming=False, interim_results=False)
        )
        self._ws_url = ws_url

    async def _recognize_impl(
        self,
        buffer: utils.AudioBuffer,
        *,
        language: NotGivenOr[str] = NOT_GIVEN,
        conn_options: APIConnectOptions | None = None,
    ) -> stt.SpeechEvent:
        import websockets

        logger.info("connecting to FunASR at %s", self._ws_url)
        text = ""

        try:
            ssl_ctx = ssl.create_default_context()
            ssl_ctx.check_hostname = False
            ssl_ctx.verify_mode = ssl.CERT_NONE
            async with websockets.connect(self._ws_url, ping_interval=None, ssl=ssl_ctx) as ws:
                # 1. Send config
                config = {
                    "mode": "2pass",
                    "chunk_size": [5, 10, 5],
                    "chunk_interval": 10,
                    "wav_name": "microphone",
                    "is_speaking": True,
                }
                await ws.send(json.dumps(config))

                # 2. Send audio frames as raw PCM int16 (resampled to 16kHz)
                frames = buffer if isinstance(buffer, list) else [buffer]
                for frame in frames:
                    pcm = _resample_to_16khz(bytes(frame.data), frame.sample_rate)
                    await ws.send(pcm)

                # 3. Signal end of speech
                await ws.send(json.dumps({"is_speaking": False}))

                # 4. Read results
                async for msg in ws:
                    data = json.loads(msg)
                    logger.debug("FunASR msg: %s", data)
                    chunk_text = data.get("text", "")
                    if chunk_text and chunk_text not in ("sil", "waiting_for_more_voice"):
                        text = chunk_text
                    # offline mode response indicates final
                    mode = data.get("mode", "")
                    if "offline" in mode or not data.get("is_speaking", True):
                        break
        except Exception as e:
            logger.error("FunASR error: %s", e)

        logger.info("ASR result: %s", text[:80] if text else "(empty)")
        return stt.SpeechEvent(
            type=SpeechEventType.FINAL_TRANSCRIPT,
            alternatives=[stt.SpeechData(text=text, language="zh")],
        )
