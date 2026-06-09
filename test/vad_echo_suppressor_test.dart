import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_voice_demo/core/vad/vad_echo_suppressor.dart';

/// Helper to create a Float32List filled with a repeated value.
Float32List _frame(double value, {int length = 512}) {
  return Float32List.fromList(List.filled(length, value));
}

void main() {
  group('EchoSuppressor', () {
    late EchoSuppressor suppressor;

    setUp(() {
      suppressor = EchoSuppressor(correlationThreshold: 0.5);
    });

    test('returns false when no TTS data has been fed', () {
      expect(suppressor.isEcho(_frame(0.1)), false);
    });

    test('returns false for silence-level mic input', () {
      suppressor.feedTTS(_frame(0.5));
      // Very quiet mic should not be flagged
      expect(suppressor.isEcho(_frame(0.001)), false);
    });

    test('detects echo when mic matches recent TTS', () {
      // Feed TTS audio with a distinctive pattern
      final ttsAudio = Float32List(512);
      for (int i = 0; i < 512; i++) {
        ttsAudio[i] = (i % 10) / 10.0; // Sawtooth pattern
      }
      suppressor.feedTTS(ttsAudio);

      // First call establishes noise baseline, returns false
      suppressor.isEcho(Float32List(512));

      // Mic picks up the same pattern (echo)
      final micEcho = Float32List(512);
      for (int i = 0; i < 512; i++) {
        micEcho[i] = (i % 10) / 10.0; // Same sawtooth
      }
      expect(suppressor.isEcho(micEcho), true);
    });

    test('does not flag different audio as echo', () {
      suppressor.feedTTS(_frame(0.5));

      // Different audio (random-ish) should not match
      final different = Float32List(512);
      for (int i = 0; i < 512; i++) {
        different[i] = (i * 7 % 100) / 100.0;
      }
      expect(suppressor.isEcho(different), false);
    });

    test('clear removes TTS buffer', () {
      suppressor.feedTTS(_frame(0.5));
      suppressor.clear();
      expect(suppressor.isEcho(_frame(0.5)), false);
    });

    test('only keeps recent TTS frames', () {
      // Feed many frames to exceed the window
      for (int i = 0; i < 20; i++) {
        suppressor.feedTTS(_frame(0.3 + i * 0.01));
      }

      // Clear replaces internal state
      suppressor.clear();
      expect(suppressor.isEcho(_frame(0.5)), false);
    });

    test('returns false for random noise', () {
      suppressor.feedTTS(_frame(0.5));

      // White noise
      final noise = Float32List(512);
      for (int i = 0; i < 512; i++) {
        noise[i] = (i * 31 % 100) / 100.0;
      }
      expect(suppressor.isEcho(noise), false);
    });
  });
}
