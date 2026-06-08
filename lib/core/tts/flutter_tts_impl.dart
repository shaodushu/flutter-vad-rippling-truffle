import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'tts_service.dart';

class FlutterTtsImpl implements TtsService {
  final FlutterTts _tts = FlutterTts();
  bool _isSpeaking = false;
  void Function()? _onComplete;

  FlutterTtsImpl() {
    _tts.setCompletionHandler(() {
      debugPrint('[TTS] playback complete');
      _isSpeaking = false;
      _onComplete?.call();
    });
    _tts.setStartHandler(() {
      debugPrint('[TTS] playback started');
    });
    _tts.setErrorHandler((msg) {
      debugPrint('[TTS] error: $msg');
      _isSpeaking = false;
    });
  }

  @override
  bool get isSpeaking => _isSpeaking;

  @override
  Future<void> speak(String text) async {
    debugPrint('[TTS] speak (${text.length} chars)');
    _isSpeaking = true;
    await _tts.speak(text);
  }

  @override
  Future<void> stop() async {
    debugPrint('[TTS] stop');
    _isSpeaking = false;
    await _tts.stop();
  }

  @override
  void setSpeed(double speed) {
    _tts.setSpeechRate(speed);
  }

  @override
  void setVolume(double volume) {
    _tts.setVolume(volume);
  }

  @override
  void setOnComplete(void Function() callback) {
    _onComplete = callback;
  }

  @override
  void dispose() {
    debugPrint('[TTS] dispose');
    _tts.stop();
  }
}
