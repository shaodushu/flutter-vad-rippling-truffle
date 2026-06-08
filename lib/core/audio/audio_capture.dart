import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

class AudioCapture {
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<List<int>>? _pcmSub;
  StreamSubscription? _amplitudeSub;
  StreamController<double>? _levelController;
  StreamController<Float32List>? _pcmController;
  bool _isActive = false;
  List<int> _pcmBuffer = [];

  static const int sampleRate = 16000;
  static const int vadFrameSize = 512; // 512 samples per VAD inference

  Stream<double>? get audioLevelStream => _levelController?.stream;
  Stream<Float32List>? get pcmStream => _pcmController?.stream;
  bool get isActive => _isActive;

  Future<void> startCapture() async {
    if (_isActive) return;

    debugPrint('[AUDIO] startCapture...');
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      debugPrint('[AUDIO] ERROR: microphone permission denied');
      throw Exception('Microphone permission denied');
    }

    _levelController = StreamController<double>.broadcast();
    _pcmController = StreamController<Float32List>.broadcast();
    _pcmBuffer = [];

    final stream = await _recorder.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      numChannels: 1,
      sampleRate: 16000,
    ));

    _isActive = true;
    debugPrint('[AUDIO] capture started');

    _pcmSub = stream.listen(
      (chunk) {
        _pcmController?.add(_int16ToFloat32(chunk));
        _accumulatePcm(chunk);
      },
      onError: (error) {
        debugPrint('[AUDIO] stream error: $error');
        _isActive = false;
      },
      onDone: () {
        debugPrint('[AUDIO] stream done');
        _isActive = false;
      },
    );

    _amplitudeSub = Stream.periodic(
      const Duration(milliseconds: 50),
      (_) => null,
    ).listen((_) async {
      try {
        final amplitude = await _recorder.getAmplitude();
        final level = min(1.0, amplitude.current / 160.0);
        _levelController?.add(level);
      } catch (_) {}
    });
  }

  /// Convert raw PCM16 bytes to normalized Float32 (-1.0 ~ 1.0)
  Float32List _int16ToFloat32(List<int> data) {
    final result = Float32List(data.length ~/ 2);
    for (int i = 0; i < result.length; i++) {
      final sample = (data[i * 2] | (data[i * 2 + 1] << 8)).toSigned(16);
      result[i] = sample / 32768.0;
    }
    return result;
  }

  /// Accumulate PCM data and emit 512-sample frames for VAD
  void _accumulatePcm(List<int> chunk) {
    _pcmBuffer.addAll(chunk);

    final frameBytes = vadFrameSize * 2; // 512 samples * 2 bytes (int16)
    while (_pcmBuffer.length >= frameBytes) {
      final frameBytesList = _pcmBuffer.sublist(0, frameBytes);
      _pcmBuffer = _pcmBuffer.sublist(frameBytes);
      final float32Frame = _int16ToFloat32(frameBytesList);
      _pcmController?.add(float32Frame);
    }
  }

  Future<void> stopCapture() async {
    debugPrint('[AUDIO] stopCapture');
    _isActive = false;
    debugPrint('[AUDIO] buffer remaining: ${_pcmBuffer.length} bytes');
    await _amplitudeSub?.cancel();
    _amplitudeSub = null;
    await _pcmSub?.cancel();
    _pcmSub = null;
    _pcmBuffer = [];
    await _levelController?.close();
    _levelController = null;
    await _pcmController?.close();
    _pcmController = null;

    try {
      await _recorder.stop();
      debugPrint('[AUDIO] capture stopped');
    } catch (e) {
      debugPrint('[AUDIO] stop error: $e');
    }
  }

  void dispose() {
    stopCapture();
    _recorder.dispose();
  }
}
