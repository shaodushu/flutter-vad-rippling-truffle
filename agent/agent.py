"""
LiveKit Voice Agent — SenseVoice STT (API) + DeepSeek LLM + IndexTTS (v1.5)
"""

import argparse
import asyncio
import json
import logging
import os
import re
import time
from pathlib import Path

import httpx
import jwt
from dotenv import load_dotenv
from livekit import rtc
from livekit.agents import StopResponse
from livekit.agents.llm.chat_context import ChatMessage
from livekit.agents.voice import Agent, AgentSession, room_io
from livekit.plugins import openai, silero
from livekit.agents.voice.turn import TurnHandlingOptions
from openai import AsyncClient as OpenAIAsyncClient

from funasr_stt import FunASRSTT
# from sensevoice_stt import SenseVoiceAPI_STT
from index_tts import IndexTTSPlugin

logger = logging.getLogger("voice-agent")

# ---- Load .env ----
dotenv_path = Path(__file__).resolve().parent.parent / ".env"
load_dotenv(dotenv_path)

# ---- Config from env ----
LLM_API_KEY = os.environ.get("DEEPSEEK_API_KEY", "")
LLM_BASE_URL = os.environ.get("DEEPSEEK_BASE_URL", "http://ai-platform.xwfintech.com/v1")
LLM_MODEL = os.environ.get("DEEPSEEK_MODEL", "qwen")
SYSTEM_PROMPT = os.environ.get("SYSTEM_PROMPT", "你是一个友好的中文语音助手。")

ASR_BASE_URL = os.environ.get("ASR_BASE_URL", "http://ai-asr.xwfintech.com:10095")
ASR_API_KEY = os.environ.get("ASR_API_KEY", "")
ASR_MODEL = os.environ.get("ASR_MODEL", "qwen3-asr")

TTS_BASE_URL = os.environ.get("TTS_BASE_URL", "http://ai-platform.xwfintech.com")
TTS_API_KEY = os.environ.get("TTS_API_KEY", "")
TTS_MODEL = os.environ.get("TTS_MODEL", "IndexTTS-1.5")
TTS_VOICE = os.environ.get("TTS_VOICE", "wenroudoudou")

# ---- 意图识别常量 ----
CONSECUTIVE_UNDIRECTED_LIMIT = 3
HUMAN_MARKERS = ["他", "她", "他们", "她们", "你们"]
AI_QUESTION_MARKERS = ["吗", "呢", "什么", "怎么", "为什么", "如何", "能不能", "可不可以"]
AI_COMMAND_MARKERS = ["帮我", "请问", "你帮我", "你能", "你可以", "告诉我", "讲个", "讲一", "给我", "我要", "我想", "说说", "介绍一下", "写个", "继续", "再来", "接着说"]
YOU_EXCLUDE_PATTERNS = ["你妈", "你爸", "你老板", "你同事", "你朋友", "你去不去", "你走不走", "他妈", "她妈", "他爸", "她爸", "他娘", "他妈的", "他奶奶"]


def _is_backchannel(text: str) -> bool:
    """判断是否是敷衍回应/语气词。"""
    t = text.strip().rstrip("。，.!！?？，、；：…—～·")
    if not t:
        return True
    backchannel_chars = set("嗯哦噢啊哈嘿诶好行对是okyesnoyeah知道明白懂了")
    alpha_chars = [c for c in t.lower() if c.isalpha()]
    return len(alpha_chars) > 0 and all(c in backchannel_chars for c in alpha_chars)



class VoiceAgent(Agent):
    """LiveKit voice assistant with smart interruption control."""

    def __init__(self, llm_instance, room: rtc.Room):
        super().__init__(
            llm=llm_instance,
            instructions=SYSTEM_PROMPT + (
                "\n\n规则：\n"
                "1. 如果用户输入看起来是语音误识别、背景噪音、或不是对你说话的内容，"
                "请回答 [SKIP]\n"
                "2. 如果输入简短模糊（如单个词、语气词），可以追问澄清，但不要长篇大论\n"
            ),
        )
        self._room = room
        self._session_ready = asyncio.Event()
        self._undirected_count = 0

    async def _send(self, type_: str, **extra):
        try:
            payload = json.dumps({"type": type_, **extra}).encode()
            logger.info("_send: %s", type_)
            await self._room.local_participant.publish_data(payload)
        except Exception as e:
            logger.warning("_send %s failed: %s", type_, e)

    async def _on_conversation_item_added(self, event):
        """当对话有新增内容时触发"""
        try:
            item = event.item
            item_type = getattr(item, "type", "?")
            item_role = getattr(item, "role", "?")
            item_text = getattr(item, "text_content", None) or ""
            logger.info("item_added: type=%s role=%s text=%s", item_type, item_role, item_text[:50])
            # 文字已通过 agent_response_chunk 逐句推送，这里不再发 agent_response
            # 以免异步到达造成重复消息
        except Exception as e:
            logger.warning("item event error: %s", e)

    async def _classify_intent(self, text: str) -> str:
        """用本地 Ollama Qwen 模型判断是否在对 AI 说话。"""
        t = text.strip()
        if not t:
            return "NOISE"
        try:
            async with httpx.AsyncClient(timeout=10.0) as client:
                resp = await client.post(
                    "http://localhost:11434/v1/chat/completions",
                    json={
                        "model": "qwen2.5:1.5b",
                        "messages": [
                            {"role": "system", "content": "你是一个分类器。只输出AI或HUMAN。"},
                            {"role": "user", "content": f"用户说：{t}"},
                        ],
                        "temperature": 0.1,
                        "max_tokens": 10,
                    },
                )
                data = resp.json()
                result = data["choices"][0]["message"]["content"].strip().upper()
            if result == "AI":
                logger.info("INTENT=AI: %s", t[:30])
                return "AI"
            logger.info("INTENT=HUMAN (%s): %s", result, t[:30])
            return "HUMAN"
        except Exception as e:
            logger.warning("INTENT classification failed: %s", e)
            return "AI"  # 出错时默认放行

    async def on_user_turn_completed(self, turn_ctx, new_message):
        """用户说完 → 模型意图判断 → 是AI则打断TTS并回复，否则忽略。"""
        text = new_message.text_content if new_message else ""
        if not text:
            return
        # 快速预检：语气词直接跳过
        if _is_backchannel(text):
            logger.info("SKIP backchannel: %s", text[:20])
            raise StopResponse()
        # LLM 意图分类
        intent = await self._classify_intent(text)
        if intent != "AI":
            logger.info("INTENT=HUMAN → 不打断, TTS继续播放")
            raise StopResponse()
        # 是 AI 对话 → 手动打断当前 TTS，再正常回复
        if self.session:
            await self.session.interrupt()
        self._undirected_count = 0
        await self._send("agent_speaking")
        await self._send("user_transcript", text=text)
        if hasattr(self, '_tts'):
            self._tts._spoke = False

    async def on_enter(self):
        """Agent 进入房间"""
        await self._send("agent_speaking")
        await self._setup_listener()

    async def _setup_listener(self):
        if self._session_ready.is_set():
            return
        try:
            if self.session:
                def sync_handler(event):
                    asyncio.create_task(self._on_conversation_item_added(event))
                self.session.on("conversation_item_added", sync_handler)
                self._session_ready.set()
                logger.info("listener registered on session")
        except Exception as e:
            logger.warning("listener setup: %s", e)

    async def on_exit(self):
        """Agent 离开房间"""
        await self._send("agent_finished")


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default=os.environ.get("LIVEKIT_URL", "ws://localhost:7880"))
    parser.add_argument("--api-key", default=os.environ.get("LIVEKIT_API_KEY", "devkey"))
    parser.add_argument("--api-secret", default=os.environ.get("LIVEKIT_API_SECRET", "secret"))
    parser.add_argument("--room", default="voice-demo")
    parser.add_argument("--identity", default="voice-agent")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s | %(name)-20s | %(levelname)-6s | %(message)s",
    )

    # Generate agent JWT
    token = jwt.encode({
        "iss": args.api_key, "sub": args.identity,
        "exp": int(time.time()) + 3600,
        "video": {"roomJoin": True, "room": args.room,
                  "canPublish": True, "canSubscribe": True, "canPublishData": True},
    }, args.api_secret, algorithm="HS256")

    # Connect room
    room = rtc.Room()
    await room.connect(args.url, token)
    logger.info("connected to room %s as %s", args.room, args.identity)

    # Components
    llm = openai.LLM(model=LLM_MODEL, base_url=LLM_BASE_URL, api_key=LLM_API_KEY)
    stt = FunASRSTT(ws_url=ASR_BASE_URL.replace("http://", "wss://"))
    # stt = SenseVoiceAPI_STT(base_url=ASR_BASE_URL, api_key=ASR_API_KEY, model=ASR_MODEL)
    tts = IndexTTSPlugin(base_url=TTS_BASE_URL, api_key=TTS_API_KEY,
                         model=TTS_MODEL, voice=TTS_VOICE, room=room)
    vad = silero.VAD.load(
        activation_threshold=0.5,
        deactivation_threshold=0.35,
        min_speech_duration=0.2,
        min_silence_duration=0.8,
        prefix_padding_duration=0.3,
    )

    turn_handling = {
        "turn_detection": "vad",
        "endpointing": {"min_delay": 0.5, "max_delay": 1.5},
        "interruption": {
            "enabled": False,  # 手动控制打断，不由 VAD 自动触发
        },
    }

    # Session
    session = AgentSession(
        stt=stt, tts=tts, vad=vad, turn_handling=turn_handling,
    )

    agent = VoiceAgent(llm_instance=llm, room=room)
    agent._tts = tts

    await session.start(agent=agent, room=room,
                        room_options=room_io.RoomOptions(
                            audio_input=room_io.AudioInputOptions(),
                        ))
    logger.info("voice agent ready")

    try:
        while True:
            await asyncio.sleep(1)
    except KeyboardInterrupt:
        pass
    finally:
        await session.aclose()
        await room.disconnect()


if __name__ == "__main__":
    asyncio.run(main())
