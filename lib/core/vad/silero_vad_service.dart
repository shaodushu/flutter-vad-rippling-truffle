import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_silero_vad/flutter_silero_vad.dart';
import 'package:path_provider/path_provider.dart';
import '../../config/app_config.dart';

/// Events emitted by the VAD service
enum VADEventType { speechStarted, speechEnded }

class VADEvent {
  final VADEventType type;
  final DateTime timestamp;
  VADEvent(this.type) : timestamp = DateTime.now();
}

/// Silero VAD service that wraps FlutterSileroVad plugin.
/// Processes 512-sample PCM frames and emits speech start/end events.
class SileroVadService {
  final FlutterSileroVad _vad = FlutterSileroVad();
  bool _initialized = false;
  bool _isSpeaking = false;

  final StreamController<VADEvent> _eventController =
      StreamController<VADEvent>.broadcast();

  Stream<VADEvent> get events => _eventController.stream;
  bool get isInitialized => _initialized;
  bool get isSpeaking => _isSpeaking;

  /// Initialize Silero VAD with bundled ONNX model.
  Future<void> initialize() async {
    if (_initialized) return;

    debugPrint('[VAD] initializing...');

    // Copy ONNX model from assets to local storage
    final modelPath = await _copyModelToLocal();
    if (modelPath == null) {
      debugPrint('[VAD] ERROR: failed to copy model to local storage');
      throw Exception('Failed to copy Silero VAD model');
    }

    debugPrint('[VAD] model ready at $modelPath');

    await _vad.initialize(
      modelPath: modelPath,
      sampleRate: 16000,
      frameSize: 512,
      threshold: AppConfig.vadThreshold,
      minSilenceDurationMs: AppConfig.vadMinSilenceDurationMs,
      speechPadMs: AppConfig.vadSpeechPadMs,
    );

    _initialized = true;
    debugPrint('[VAD] initialized successfully');
  }

  Future<String?> _copyModelToLocal() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final localPath = '${dir.path}/silero_vad.onnx';
      final localFile = File(localPath);
      if (await localFile.exists()) {
        debugPrint('[VAD] model already cached at $localPath');
        return localPath;
      }

      debugPrint('[VAD] copying model from assets to $localPath');
      final data = await rootBundle.load('assets/models/silero_vad.onnx');
      final bytes = data.buffer.asUint8List();
      await localFile.writeAsBytes(bytes);
      debugPrint('[VAD] model copied (${bytes.length} bytes)');
      return localPath;
    } catch (e) {
      debugPrint('[VAD] ERROR copying model: $e');
      return null;
    }
  }

  /// Process a 512-sample Float32 audio frame.
  /// Returns current speaking state.
  Future<bool> processFrame(Float32List frame) async {
    if (!_initialized) return false;

    try {
      final isActive = await _vad.predict(frame);

      if (isActive == true && !_isSpeaking) {
        _isSpeaking = true;
        debugPrint('[VAD] >>> speech START');
        _eventController.add(VADEvent(VADEventType.speechStarted));
      } else if (isActive != true && _isSpeaking) {
        _isSpeaking = false;
        debugPrint('[VAD] <<< speech END');
        _eventController.add(VADEvent(VADEventType.speechEnded));
      }

      return isActive ?? false;
    } catch (e) {
      debugPrint('[VAD] predict error: $e');
      return _isSpeaking;
    }
  }

  /// Reset VAD state for a new conversation turn.
  Future<void> reset() async {
    if (!_initialized) return;
    debugPrint('[VAD] reset state');
    await _vad.resetState();
    _isSpeaking = false;
  }

  void dispose() {
    _eventController.close();
  }
}
