import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'asr_service.dart';

class PlatformAsr implements AsrService {
  final SpeechToText _stt = SpeechToText();
  String? _currentText;
  bool _isListening = false;

  @override
  String? get currentText => _currentText;

  @override
  bool get isListening => _isListening;

  @override
  Future<void> start({
    required void Function(String text) onResult,
    void Function()? onListening,
    void Function()? onDone,
    void Function(String error)? onError,
  }) async {
    if (_isListening) return;

    debugPrint('[ASR] initializing...');
    final available = await _stt.initialize();
    if (!available) {
      debugPrint('[ASR] ERROR: speech recognition not available');
      onError?.call('Speech recognition not available');
      return;
    }

    _isListening = true;
    _currentText = null;
    debugPrint('[ASR] listening...');

    await _stt.listen(
      onResult: (result) {
        _currentText = result.recognizedWords;
        debugPrint('[ASR] partial: "${result.recognizedWords}" (final: ${result.finalResult})');
        if (result.finalResult) {
          onResult(result.recognizedWords);
        }
      },
      onSoundLevelChange: (_) {},
      listenOptions: SpeechListenOptions(
        listenFor: const Duration(seconds: 30),
        localeId: 'zh_CN',
      ),
    );

    onListening?.call();
  }

  @override
  Future<String> stop() async {
    debugPrint('[ASR] stop');
    _isListening = false;
    await _stt.stop();
    return _currentText ?? '';
  }

  @override
  void dispose() {
    debugPrint('[ASR] dispose');
    _stt.stop();
  }
}
