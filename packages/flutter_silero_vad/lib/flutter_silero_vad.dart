import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;

import 'flutter_silero_vad_platform_interface.dart';
import 'flutter_silero_vad_method_channel.dart';
// Web implementation only available on web (dart:js_interop)
import 'flutter_silero_vad_web.dart' if (dart.library.io) '_flutter_silero_vad_nonweb.dart';

class FlutterSileroVad {
  FlutterSileroVad() {
    _ensurePlatform();
  }

  static void _ensurePlatform() {
    if (kIsWeb) {
      FlutterSileroVadPlatform.instance = WebFlutterSileroVad();
    } else {
      FlutterSileroVadPlatform.instance = MethodChannelFlutterSileroVad();
    }
  }

  Future<String?> initialize({
    required String modelPath,
    required int sampleRate,
    required int frameSize,
    required double threshold,
    required int minSilenceDurationMs,
    required int speechPadMs,
  }) {
    return FlutterSileroVadPlatform.instance.initialize(
      modelPath: modelPath,
      sampleRate: sampleRate,
      frameSize: frameSize,
      threshold: threshold,
      minSilenceDurationMs: minSilenceDurationMs,
      speechPadMs: speechPadMs,
    );
  }

  Future<void> resetState() {
    return FlutterSileroVadPlatform.instance.resetState();
  }

  Future<bool?> predict(Float32List data) {
    return FlutterSileroVadPlatform.instance.predict(data);
  }
}
