import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'flutter_silero_vad_platform_interface.dart';

/// JS interop for the SileroVADAdapter class defined in web/silero_vad_adapter.js
@JS('SileroVADAdapter')
@staticInterop
class SileroVADAdapterJS {
  external factory SileroVADAdapterJS();
}

extension SileroVADAdapterJSExt on SileroVADAdapterJS {
  external JSPromise<JSString> initialize(Uint8List modelData);
  external JSPromise<JSNumber> predict(Float32List audioData);
  external void resetState();
}

/// Web implementation of FlutterSileroVadPlatform.
///
/// Uses onnxruntime-web (loaded via CDN in web/index.html) and a thin
/// JS adapter (web/silero_vad_adapter.js) to run Silero VAD inference
/// directly in the browser via WebAssembly.
class WebFlutterSileroVad extends FlutterSileroVadPlatform {
  SileroVADAdapterJS? _adapter;
  bool _initialized = false;

  @override
  Future<String?> initialize({
    required String modelPath,
    required int sampleRate,
    required int frameSize,
    required double threshold,
    required int minSilenceDurationMs,
    required int speechPadMs,
  }) async {
    try {
      _adapter = SileroVADAdapterJS();

      // Load ONNX model from assets via rootBundle
      final byteData = await rootBundle.load(modelPath);
      final bytes = byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );

      // Initialize JS adapter (loads model into ONNX Runtime Web)
      final result = await _adapter!.initialize(bytes).toDart;
      final resultStr = result.toDart;
      if (resultStr != 'ok') {
        return resultStr; // error message
      }

      _initialized = true;
      return 'ok';
    } catch (e) {
      return 'error: $e';
    }
  }

  @override
  Future<bool?> predict(Float32List data) async {
    if (!_initialized || _adapter == null) return false;

    try {
      final prob = await _adapter!.predict(data).toDart;
      final probability = prob.toDartDouble;
      return probability > 0.5;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<double?> predictRaw(Float32List data) async {
    if (!_initialized || _adapter == null) return 0.0;

    try {
      final prob = await _adapter!.predict(data).toDart;
      return prob.toDartDouble;
    } catch (e) {
      return 0.0;
    }
  }

  @override
  Future<void> resetState() async {
    _adapter?.resetState();
    _initialized = false;
  }
}
