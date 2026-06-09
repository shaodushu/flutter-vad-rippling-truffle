"""STT plugin — placeholder until FunASR is ready."""

import logging
from livekit.agents import stt, utils
from livekit.agents.types import NOT_GIVEN, NotGivenOr, APIConnectOptions

logger = logging.getLogger("stt")


class PlaceholderSTT(stt.STT):
    """Returns empty results. Replace with FunASR-based STT when server is ready."""

    def __init__(self):
        super().__init__(
            capabilities=stt.STTCapabilities(streaming=False, interim_results=False)
        )

    async def _recognize_impl(
        self,
        buffer: utils.AudioBuffer,
        *,
        language: NotGivenOr[str] = NOT_GIVEN,
        conn_options: APIConnectOptions | None = None,
    ) -> stt.SpeechEvent:
        return stt.SpeechEvent(
            is_final=True,
            alternatives=[stt.SpeechData(text="", language="zh")],
        )
