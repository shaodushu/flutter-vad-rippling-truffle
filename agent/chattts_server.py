"""
轻量 ChatTTS OpenAI-compatible TTS API server.
"""

import io
import json
import logging
import os
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler

# Ensure ChatTTS source is in path before importing
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "ChatTTS"))
import ChatTTS
import torch
import torchaudio

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("chattts-server")

# Load model once at startup
logger.info("Loading ChatTTS model...")
chat = ChatTTS.Chat()
chat.load(source="huggingface")
logger.info("ChatTTS model loaded.")

SAMPLE_RATE = 24000


class TTSHandler(BaseHTTPRequestHandler):
    def _send_json(self, code, data):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def do_POST(self):
        if self.path in ("/v1/audio/speech", "/audio/speech"):
            self._handle_tts()
        elif self.path == "/health":
            self._send_json(200, {"status": "ok"})
        else:
            self._send_json(404, {"error": "not found"})

    def _handle_tts(self):
        try:
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length)
            params = json.loads(body)
            text = params.get("input", "")
            voice = params.get("voice", "default")
            response_format = params.get("response_format", "wav")

            if not text:
                self._send_json(400, {"error": "input is required"})
                return

            logger.info("TTS: %d chars, voice=%s", len(text), voice)

            # Synthesize
            # Synthesize - infer returns list of tensors
            wavs = chat.infer(text, skip_refine_text=True)
            wav = wavs[0]  # first result (numpy array)
            if wav.ndim == 3:
                wav = wav.squeeze(0)
            if wav.ndim == 2 and wav.shape[0] == 1:
                wav = wav.squeeze(0)

            # Convert float [-1,1] to int16 PCM with proper WAV header
            pcm = (wav * 32767).astype("<i2").tobytes()
            data_size = len(pcm)
            import struct
            wav_header = struct.pack(
                "<4sI4s4sIHHIIHH",
                b"RIFF", 36 + data_size, b"WAVE",
                b"fmt ", 16, 1, 1, SAMPLE_RATE,
                SAMPLE_RATE * 2, 2, 16,
            ) + struct.pack("<4sI", b"data", data_size)

            if response_format == "wav":
                self.send_response(200)
                self.send_header("Content-Type", "audio/wav")
                self.send_header("Content-Length", str(len(wav_header) + data_size))
                self.end_headers()
                self.wfile.write(wav_header + pcm)
            else:
                buf = io.BytesIO()
                wav_tensor = torch.from_numpy(wav) if not isinstance(wav, torch.Tensor) else wav
                if wav_tensor.dim() == 1:
                    wav_tensor = wav_tensor.unsqueeze(0)
                fmt = "mp3" if response_format == "mp3" else "ogg"
                torchaudio.save(buf, wav_tensor, SAMPLE_RATE, format=fmt)
                audio_bytes = buf.getvalue()
                ct = "audio/mpeg" if response_format == "mp3" else "audio/ogg"
                self.send_response(200)
                self.send_header("Content-Type", ct)
                self.send_header("Content-Length", str(len(audio_bytes)))
                self.end_headers()
                self.wfile.write(audio_bytes)
            return

            audio_bytes = buf.getvalue()
            logger.info("TTS done: %d bytes", len(audio_bytes))

            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(audio_bytes)))
            self.end_headers()
            self.wfile.write(audio_bytes)

        except Exception as e:
            logger.error("TTS error: %s", e)
            import traceback
            traceback.print_exc()
            self._send_json(500, {"error": str(e)})

    def do_GET(self):
        if self.path == "/health":
            self._send_json(200, {"status": "ok"})
        else:
            self._send_json(404, {"error": "not found"})

    def log_message(self, format, *args):
        logger.info("%s - %s", self.client_address[0], format % args)


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8020
    server = HTTPServer(("0.0.0.0", port), TTSHandler)
    logger.info("ChatTTS server listening on port %d", port)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()
