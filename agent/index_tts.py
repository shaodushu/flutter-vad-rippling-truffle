"""TTS plugin using IndexTTS-1.5 via OpenAI-compatible API (v1.5 ChunkedStream)."""

import json
import logging
import re
import httpx
from livekit import rtc
from livekit.agents import tts, utils
from livekit.agents.types import APIConnectOptions, DEFAULT_API_CONNECT_OPTIONS

logger = logging.getLogger("index-tts")

SAMPLE_RATE = 24000
NUM_CHANNELS = 1

# TTS 文本清洗：移除 LLM 可能输出的特殊符号
_TTS_CLEAN_RE = re.compile(r"[*#_~`\[\](){}<>|@&$%^=+\\/;:!?]+")


def _clean_tts_text(text: str) -> str:
    """移除 TTS 不该朗读的符号，保留中文、英文、数字和基本标点。"""
    text = _TTS_CLEAN_RE.sub("", text)   # 移除特殊符号
    text = re.sub(r"\s+", " ", text).strip()  # 合并空白
    return text


class IndexTTSPlugin(tts.TTS):
    """Text-to-speech via IndexTTS-1.5 API."""

    def __init__(
        self,
        *,
        base_url: str,
        api_key: str,
        room: rtc.Room | None = None,
        model: str = "IndexTTS-1.5",
        voice: str = "default",
    ):
        super().__init__(
            capabilities=tts.TTSCapabilities(streaming=False),
            sample_rate=SAMPLE_RATE,
            num_channels=NUM_CHANNELS,
        )
        self._base_url = base_url.rstrip("/") + "/v1"
        self._api_key = api_key
        self._model = model
        self._voice = voice
        self._room = room
        self.last_tts_text = ""
        # 已发送文本指纹去重（最近 20 条）
        self._sent_hashes: set[int] = set()
        # TTS 音频缓存 { text_hash: wav_bytes }，避免重复合成相同文本
        self._audio_cache: dict[int, bytes] = {}

    def synthesize(
        self,
        text: str,
        *,
        conn_options: APIConnectOptions = DEFAULT_API_CONNECT_OPTIONS,
    ) -> tts.ChunkedStream:
        return _IndexTTSChunkedStream(tts=self, input_text=text, conn_options=conn_options)

    async def aclose(self) -> None:
        pass


class _IndexTTSChunkedStream(tts.ChunkedStream):
    def __init__(self, *, tts: IndexTTSPlugin, input_text: str, conn_options: APIConnectOptions):
        super().__init__(tts=tts, input_text=input_text, conn_options=conn_options)
        self._tts: IndexTTSPlugin = tts

    async def _send_chunk(self, text: str):
        """Push TTS chunk text to UI. Returns True if skipped."""
        if not self._tts._room:
            logger.warning("_send_chunk: no room")
            return False
        # 过滤 [SKIP] — 不推送到 UI 也不合成语音
        if text.strip().upper().startswith("[SKIP]") or text.strip().upper() == "SKIP":
            logger.info("_send_chunk: skipped [SKIP]")
            return True
        # 去重：同一段文本不要重复发送到 UI（TTS 合成仍需进行）
        text_hash = hash(text)
        if text_hash in self._tts._sent_hashes:
            logger.info("_send_chunk: dedup skipped: %s", text[:40])
        else:
            self._tts._sent_hashes.add(text_hash)
            if len(self._tts._sent_hashes) > 20:
                self._tts._sent_hashes.clear()
            try:
                # Send agent_speaking BEFORE first chunk so Flutter state transitions first
                if not hasattr(self._tts, '_spoke') or not self._tts._spoke:
                    payload = json.dumps({"type": "agent_speaking"}).encode()
                    await self._tts._room.local_participant.publish_data(payload)
                    self._tts._spoke = True
                payload = json.dumps({"type": "agent_response_chunk", "text": text}).encode()
                await self._tts._room.local_participant.publish_data(payload)
                logger.info("_send_chunk: %s", text[:40])
            except Exception as e:
                logger.warning("_send_chunk failed: %s", e)
        return False

    async def _run(self, output_emitter: tts.AudioEmitter) -> None:
        # 清洗文本后再合成
        clean_text = _clean_tts_text(self._input_text)
        if not clean_text:
            logger.info("TTS skipped (empty after cleanup)")
            return
        # 记录当前 TTS 文本（供意图判断用）
        self._tts.last_tts_text = clean_text
        logger.info("TTS %d chars → %s/%s (cleaned: %d chars)",
                     len(self._input_text), self._tts._model, self._tts._voice, len(clean_text))

        # Send the text for this chunk to the Flutter UI BEFORE synthesizing
        if await self._send_chunk(clean_text):
            return  # SKIP 消息不合成语音

        text_hash = hash(clean_text)

        # 检查音频缓存——相同文本直接复用，避免重复合成
        if text_hash in self._tts._audio_cache:
            wav_bytes = self._tts._audio_cache[text_hash]
            logger.info("TTS cache hit: %d bytes for '%s'", len(wav_bytes), clean_text[:40])
        else:
            try:
                async with httpx.AsyncClient(timeout=httpx.Timeout(120.0, connect=30.0, read=120.0, write=30.0, pool=10.0)) as client:
                    resp = await client.post(
                        f"{self._tts._base_url}/audio/speech",
                        headers={
                            "Authorization": f"Bearer {self._tts._api_key}",
                            "Content-Type": "application/json",
                        },
                        json={
                            "model": self._tts._model,
                            "input": clean_text,
                            "voice": self._tts._voice,
                            "response_format": "wav",
                        },
                    )
                    if resp.status_code != 200:
                        logger.error("TTS HTTP %s: %s", resp.status_code, resp.text[:200])
                        raise RuntimeError(f"TTS error: HTTP {resp.status_code}")

                    wav_bytes = resp.content
                    logger.info("TTS got %d bytes", len(wav_bytes))
                    # 缓存结果
                    self._tts._audio_cache[text_hash] = wav_bytes
                    if len(self._tts._audio_cache) > 10:
                        self._tts._audio_cache.pop(next(iter(self._tts._audio_cache)))
            except Exception as e:
                logger.error("TTS failed: %s", e)
                raise

        try:
            output_emitter.initialize(
                request_id="index-tts",
                sample_rate=SAMPLE_RATE,
                num_channels=NUM_CHANNELS,
                mime_type="audio/wav",
            )
            output_emitter.push(wav_bytes)
            output_emitter.flush()
            logger.info("TTS done")
        except Exception as e:
            logger.error("TTS output failed: %s", e)
            raise
