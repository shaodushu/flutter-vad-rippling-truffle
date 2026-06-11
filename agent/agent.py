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

import jwt
from dotenv import load_dotenv
from livekit import rtc
from livekit.agents import StopResponse
from livekit.agents.llm.chat_context import ChatMessage
from livekit.agents.voice import Agent, AgentSession, room_io
from livekit.plugins import openai, silero
from livekit.agents.voice.turn import TurnHandlingOptions
from openai import AsyncClient as OpenAIAsyncClient

from sensevoice_stt import SenseVoiceAPI_STT
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


# ---- Manual turn control (no VAD, no keywords) ----


def _is_backchannel(text: str) -> bool:
    """判断是否是敷衍回应/语气词。"""
    t = text.strip().rstrip("。，.!！?？，、；：…—～·")
    if not t:
        return True
    backchannel_chars = set("嗯哦噢啊哈嘿诶好行对是okyesnoyeah知道明白懂了")
    alpha_chars = [c for c in t.lower() if c.isalpha()]
    return len(alpha_chars) > 0 and all(c in backchannel_chars for c in alpha_chars)

class VoiceAgent(Agent):
    """LiveKit voice assistant with VAD turn detection + LLM intent + fast resume."""

    def __init__(self, llm_instance, room: rtc.Room, stt_instance=None):
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
        self._stt = stt_instance
        self._conversation_history: list[str] = []
        self._session_ready = asyncio.Event()
        self._cached_intent: str | None = None  # Arbiter: 预分类意图缓存
        self._pending_intent_task: asyncio.Task | None = None  # Arbiter: 正在执行的预分类
        self._last_responded_text: str = ""  # 防重复 TTS


    async def _send(self, type_: str, **extra):
        try:
            payload = json.dumps({"type": type_, **extra}).encode()
            logger.info("_send: %s", type_)
            await self._room.local_participant.publish_data(payload)
        except Exception as e:
            logger.warning("_send %s failed: %s", type_, e)

    async def _on_conversation_item_added(self, event):
        """仅用于日志记录"""
        try:
            item = event.item
            item_type = getattr(item, "type", "?")
            item_role = getattr(item, "role", "?")
            item_text = getattr(item, "text_content", None) or ""
            logger.info("item_added: type=%s role=%s", item_type, item_role)
        except Exception:
            pass

    async def _classify_intent(self, text: str) -> str:
        """用 LLM 判断用户是否在对 AI 说话。"""
        try:
            client = OpenAIAsyncClient(api_key=LLM_API_KEY, base_url=LLM_BASE_URL)
            resp = await client.chat.completions.create(
                model=LLM_MODEL,
                messages=[
                    {"role": "system", "content": "你是一个意图分类器。判断下面的话是否是对AI语音助手说的。如果是在和AI对话、问问题、下指令，返回AI。如果是对别人说的、日常闲聊、杂音误识别，返回HUMAN。只返回AI或HUMAN。"},
                    {"role": "user", "content": f"用户说：{text}"},
                ],
                temperature=0.1,
                max_tokens=10,
            )
            result = resp.choices[0].message.content.strip().upper()
            await client.close()
            if result in ("AI",):
                logger.info("INTENT=AI: %s", text[:30])
                return "AI"
            logger.info("INTENT=HUMAN (%s): %s", result, text[:30])
            return "HUMAN"
        except Exception as e:
            logger.warning("INTENT classification failed: %s", e)
            return "AI"

    async def _on_user_input_transcribed(self, event):
        """Arbiter 早期路径：监听到 final transcript 后立即启动意图预分类。"""
        if not event.is_final or not event.transcript:
            return
        text = event.transcript.strip()
        if not text or _is_backchannel(text):
            self._cached_intent = "HUMAN"
            return
        # 取消之前的预分类（如果还在跑）
        if self._pending_intent_task and not self._pending_intent_task.done():
            self._pending_intent_task.cancel()
        self._pending_intent_task = asyncio.create_task(
            self._preclassify_intent(text)
        )

    async def _preclassify_intent(self, text: str):
        """预分类意图并缓存结果。"""
        try:
            greeting_pattern = re.compile(
                r'^(你好|嗨|hi|hello|嘿|hey|在吗|在不在|早上好|下午好|晚上好)[，。!！?？\s]',
                re.IGNORECASE,
            )
            if greeting_pattern.match(text):
                self._cached_intent = "AI"
                logger.info("Arbiter: pre-classified greeting → AI")
            else:
                self._cached_intent = await self._classify_intent(text)
                logger.info("Arbiter: pre-classified intent=%s for '%s'", self._cached_intent, text[:30])
        except asyncio.CancelledError:
            pass
        except Exception as e:
            logger.warning("Arbiter: pre-classify failed: %s", e)
            self._cached_intent = None  # 强制 on_user_turn_completed 重新分类

    async def on_user_turn_completed(self, turn_ctx, new_message):
        text = new_message.text_content if new_message else ""
        if not text or _is_backchannel(text):
            self._cached_intent = None
            raise StopResponse()
        # Arbiter: 优先使用预分类缓存的意图
        greeting_pattern = re.compile(
            r'^(你好|嗨|hi|hello|嘿|hey|在吗|在不在|早上好|下午好|晚上好)[，。!！?？\s]',
            re.IGNORECASE,
        )
        if greeting_pattern.match(text.strip()):
            intent = "AI"
        elif self._cached_intent is not None:
            intent = self._cached_intent
            self._cached_intent = None
            logger.info("Arbiter: cached intent=%s for '%s'", intent, text[:30])
        else:
            intent = await self._classify_intent(text)
            self._cached_intent = intent  # 缓存供下一轮使用
        if intent != "AI":
            # 用户在对旁边人说话 → 等音频缓冲清空后再恢复播放
            if hasattr(self, '_tts'):
                last = getattr(self._tts, 'last_tts_text', '')
                if last and self.session:
                    await asyncio.sleep(0.5)  # 等旧音频缓冲排空
                    self._tts._spoke = True
                    self._tts.last_tts_text = ""
                    logger.info("Arbiter: HUMAN → delayed resume TTS: %s", last[:40])
                    self.session.say(last)
            self._cached_intent = None
            raise StopResponse()
        # AI 意图 → 正常对话流程
        self._cached_intent = None
        self._conversation_history.append(f"用户: {text}")
        if len(self._conversation_history) > 10:
            self._conversation_history = self._conversation_history[-10:]
        if self._stt:
            # 每 3 轮或首次重新生成摘要
            turn_count = len(self._conversation_history)
            should_refresh = turn_count <= 2 or turn_count % 3 == 1
            if should_refresh:
                await self._update_asr_prompt()
            else:
                logger.info("ASR prompt (cached): %s", self._stt.context_prompt[:100])
        # 调 LLM（防重复：同一段用户文本不重复触发）
        if text == self._last_responded_text:
            logger.info("Dedup: skip same user text '%s'", text[:30])
            raise StopResponse()
        self._last_responded_text = text
        await self._send("agent_speaking")
        await self._send("user_transcript", text=text)
        if hasattr(self, '_tts'):
            self._tts._spoke = False

    async def on_enter(self):
        if self._session_ready.is_set():
            # 已经进入过房间，不重复发欢迎语
            return
        await self._send("agent_speaking")
        await self._setup_listener()

    async def _update_asr_prompt(self):
        """用 LLM 把对话历史提炼成 ASR 上下文提示（关键话题 + 实体）。"""
        if not self._stt:
            return
        try:
            history = "\n".join(self._conversation_history[-6:])
            client = OpenAIAsyncClient(api_key=LLM_API_KEY, base_url=LLM_BASE_URL)
            resp = await client.chat.completions.create(
                model=LLM_MODEL,
                messages=[
                    {"role": "system", "content": "你是 ASR 语音识别的上下文提示生成器。根据对话历史，提取关键实体词帮助语音识别。输出规则：只输出关键词，逗号分隔，20个词以内。优先提取：人名、公司名、产品名、专业术语、数字/字母组合（如API、A100）。不要输出完整句子。"},
                    {"role": "user", "content": f"对话历史：\n{history}"},
                ],
                temperature=0.1,
                max_tokens=60,
            )
            summary = resp.choices[0].message.content.strip()
            await client.close()
            if summary:
                self._stt.context_prompt = summary
                logger.info("ASR prompt (LLM summary): %s", summary)
        except Exception as e:
            logger.warning("ASR prompt update failed: %s", e)

    async def _setup_listener(self):
        if self._session_ready.is_set():
            return
        try:
            if self.session:
                def sync_handler(event):
                    asyncio.create_task(self._on_conversation_item_added(event))
                self.session.on("conversation_item_added", sync_handler)

                def sync_transcript_handler(event):
                    asyncio.create_task(self._on_user_input_transcribed(event))
                self.session.on("user_input_transcribed", sync_transcript_handler)

                self._session_ready.set()
                logger.info("listener registered on session")
        except Exception as e:
            logger.warning("listener setup: %s", e)

    async def on_exit(self):
        if self._pending_intent_task and not self._pending_intent_task.done():
            self._pending_intent_task.cancel()
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
    stt = SenseVoiceAPI_STT(base_url=ASR_BASE_URL, api_key=ASR_API_KEY, model=ASR_MODEL)
    tts = IndexTTSPlugin(base_url=TTS_BASE_URL, api_key=TTS_API_KEY,
                         model=TTS_MODEL, voice=TTS_VOICE, room=room)
    vad = silero.VAD.load()

    turn_handling = {
        "turn_detection": "vad",
        "endpointing": {"min_delay": 1.5, "max_delay": 3.0},
        "interruption": {
            "enabled": True,
            "mode": "vad",
            "min_words": 3,
            "min_duration": 0.5,
            "resume_false_interruption": True,
            "false_interruption_timeout": 0.5,
        },
    }

    # Session — VAD passed for STT streaming support, but turns are manual
    session = AgentSession(
        stt=stt, tts=tts, vad=vad, turn_handling=turn_handling,
    )

    agent = VoiceAgent(llm_instance=llm, room=room, stt_instance=stt)
    agent._tts = tts

    await session.start(agent=agent, room=room,
                        room_options=room_io.RoomOptions(
                            audio_input=room_io.AudioInputOptions(),
                            close_on_disconnect=False,  # 参与者断开后不关闭，等待下一个
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
