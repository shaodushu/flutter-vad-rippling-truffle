import 'dart:async';
import 'package:flutter/foundation.dart';
import '../config/app_config.dart';
import '../core/asr/asr_service.dart';
import '../core/asr/platform_asr.dart';
import '../core/audio/audio_capture.dart';
import '../core/llm/llm_client.dart';
import '../core/llm/deepseek_client.dart';
import '../core/tts/tts_service.dart';
import '../core/tts/flutter_tts_impl.dart';
import '../core/vad/silero_vad_service.dart';
import 'voice_state.dart';

/// Orchestrates the voice conversation pipeline:
/// VAD → ASR → LLM → TTS
class VoiceController {
  final AudioCapture _audioCapture = AudioCapture();
  final SileroVadService _vadService = SileroVadService();
  final AsrService _asr = PlatformAsr();
  final TtsService _tts = FlutterTtsImpl();
  late final LLMClient _llm;

  final ValueNotifier<VoiceState> state = ValueNotifier(VoiceState.idle);
  final ValueNotifier<String> transcript = ValueNotifier('');
  final ValueNotifier<String> response = ValueNotifier('');
  final ValueNotifier<String?> errorMessage = ValueNotifier(null);
  final ValueNotifier<double> audioLevel = ValueNotifier(0.0);

  // Conversation history
  final List<ChatMessage> _messages = [];
  StreamSubscription<VADEvent>? _vadSub;
  StreamSubscription<Float32List>? _pcmSub;
  StreamSubscription<double>? _levelSub;
  StreamSubscription<String>? _llmSub;
  bool _isProcessing = false;

  VoiceController() {
    _llm = DeepSeekClient(
      apiKey: AppConfig.llmApiKey,
      baseUrl: AppConfig.llmBaseUrl,
      defaultModel: AppConfig.llmModel,
    );
  }

  /// Start voice conversation session
  Future<void> start() async {
    if (state.value != VoiceState.idle) return;

    debugPrint('[CTRL] start');
    _setState(VoiceState.initializing);

    try {
      // Initialize VAD
      debugPrint('[CTRL] initializing VAD...');
      await _vadService.initialize();

      // Start audio capture
      debugPrint('[CTRL] starting audio capture...');
      await _audioCapture.startCapture();

      // Listen to audio levels for UI
      _levelSub = _audioCapture.audioLevelStream?.listen((level) {
        audioLevel.value = level;
      });

      // Listen to VAD events
      _vadSub = _vadService.events.listen(_onVADEvent);

      // Listen to raw PCM for VAD processing
      _pcmSub = _audioCapture.pcmStream?.listen(_onPcmFrame);

      debugPrint('[CTRL] now listening');
      _setState(VoiceState.listening);
    } catch (e) {
      debugPrint('[CTRL] ERROR init: $e');
      errorMessage.value = 'Init failed: $e';
      _setState(VoiceState.error);
      Future.delayed(const Duration(seconds: 2), _resetToIdle);
    }
  }

  void _onPcmFrame(Float32List frame) {
    if (_isProcessing) return;
    _vadService.processFrame(frame);
  }

  void _onVADEvent(VADEvent event) {
    if (event.type == VADEventType.speechEnded && !_isProcessing) {
      debugPrint('[CTRL] VAD speech ended → starting ASR');
      _onSpeechEnd();
    }
  }

  void _onSpeechEnd() {
    _isProcessing = true;
    _setState(VoiceState.processing);

    // Cancel PCM processing while doing ASR
    _pcmSub?.cancel();
    _pcmSub = null;

    // Stop audio capture for ASR
    _audioCapture.stopCapture().then((_) {
      debugPrint('[CTRL] capture stopped, starting ASR...');
      _startASR();
    });
  }

  Future<void> _startASR() async {
    debugPrint('[CTRL] ASR start');
    try {
      await _asr.start(
        onResult: (text) {
          debugPrint('[CTRL] ASR result: "$text"');
          if (text.trim().isNotEmpty) {
            transcript.value = text;
            _messages.add(ChatMessage(role: 'user', content: text));
            _startLLM(text);
          } else {
            debugPrint('[CTRL] ASR empty, resume listening');
            _resumeListening();
          }
        },
        onError: (error) {
          debugPrint('[CTRL] ASR error: $error');
          errorMessage.value = 'ASR error: $error';
          _resetToIdle();
        },
      );
    } catch (e) {
      debugPrint('[CTRL] ASR failed: $e');
      errorMessage.value = 'ASR failed: $e';
      _resetToIdle();
    }
  }

  Future<void> _startLLM(String text) async {
    debugPrint('[CTRL] LLM start, prompt: "${text.substring(0, text.length.clamp(0, 50))}"');
    try {
      final buffer = StringBuffer();

      _llmSub = _llm
          .streamChat(
            systemPrompt: AppConfig.systemPrompt,
            messages: _messages,
          )
          .listen(
        (chunk) {
          if (!chunk.startsWith('[Error')) {
            buffer.write(chunk);
            response.value = buffer.toString();
          }
        },
        onDone: () {
          final full = buffer.toString();
          debugPrint('[CTRL] LLM done, response (${full.length} chars)');
          _messages
              .add(ChatMessage(role: 'assistant', content: full));
          _startTTS(full);
        },
        onError: (e) {
          debugPrint('[CTRL] LLM stream error: $e');
          errorMessage.value = 'LLM error: $e';
          _resetToIdle();
        },
      );
    } catch (e) {
      debugPrint('[CTRL] LLM failed: $e');
      errorMessage.value = 'LLM failed: $e';
      _resetToIdle();
    }
  }

  Future<void> _startTTS(String text) async {
    if (text.isEmpty) {
      debugPrint('[CTRL] TTS skipped (empty)');
      _resumeListening();
      return;
    }

    debugPrint('[CTRL] TTS start (${text.length} chars)');
    _setState(VoiceState.speaking);

    _tts.setOnComplete(() {
      debugPrint('[CTRL] TTS complete');
      _resumeListening();
    });

    await _tts.speak(text);
  }

  void _resumeListening() {
    debugPrint('[CTRL] resume listening');
    _isProcessing = false;
    _vadService.reset();
    _setState(VoiceState.listening);

    _audioCapture.startCapture().then((_) {
      _pcmSub = _audioCapture.pcmStream?.listen(_onPcmFrame);
      _levelSub?.cancel();
      _levelSub = _audioCapture.audioLevelStream?.listen((level) {
        audioLevel.value = level;
      });
    });
  }

  /// Stop and cancel current conversation
  Future<void> stop() async {
    debugPrint('[CTRL] stop');
    _llmSub?.cancel();
    await _asr.stop();
    await _tts.stop();
    await _audioCapture.stopCapture();
    _vadService.reset();
    _isProcessing = false;
    _resetToIdle();
  }

  void _setState(VoiceState newState) {
    debugPrint('[CTRL] state: ${state.value} → $newState');
    state.value = newState;
  }

  void _resetToIdle() {
    _setState(VoiceState.idle);
  }

  /// Send text directly (skip ASR)
  Future<void> sendText(String text) async {
    if (text.trim().isEmpty || _isProcessing) return;
    debugPrint('[CTRL] sendText: "$text"');
    await stop();
    _isProcessing = true;

    transcript.value = text;
    _messages.add(ChatMessage(role: 'user', content: text));
    _setState(VoiceState.processing);
    _startLLM(text);
  }

  void dispose() {
    debugPrint('[CTRL] dispose');
    _vadSub?.cancel();
    _pcmSub?.cancel();
    _levelSub?.cancel();
    _llmSub?.cancel();
    _asr.dispose();
    _tts.dispose();
    _llm.dispose();
    _vadService.dispose();
    _audioCapture.dispose();
    state.dispose();
    transcript.dispose();
    response.dispose();
    errorMessage.dispose();
    audioLevel.dispose();
  }
}
