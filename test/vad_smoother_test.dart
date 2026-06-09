import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_voice_demo/core/vad/vad_smoother.dart';

void main() {
  group('VADSmoother', () {
    /// VADSmoother with sample-count-based timing (no wall-clock dependency).
    /// frameSize=512, sampleRate=16000 → each frame = 32ms.
    /// minSpeechDuration=50ms → need 2 frames (1024 samples > 800)
    /// minSilenceDuration=50ms → need 2 frames
    late VADSmoother smoother;

    setUp(() {
      smoother = VADSmoother(
        onThreshold: 0.5,
        offThreshold: 0.35,
        smoothWindow: 3,
        minSpeechDuration: const Duration(milliseconds: 50),
        minSilenceDuration: const Duration(milliseconds: 50),
        maxSpeechDuration: const Duration(seconds: 30),
        frameSize: 512,
        sampleRate: 16000,
      );
    });

    test('starts with no speech', () {
      final event = smoother.process(0.1);
      expect(event, isA<Continuation>());
      expect((event as Continuation).isSpeech, false);
    });

    test('detects speech start after sustained high probability', () {
      // Each frame = 32ms; need >50ms (~2 frames) to confirm speech.
      bool speechStarted = false;
      for (int i = 0; i < 5; i++) {
        final event = smoother.process(0.8);
        if (event is SpeechStart) speechStarted = true;
      }
      expect(speechStarted, true);
    });

    test('filters out brief noise bursts (single spike)', () {
      // Single high-probability frame is too short to confirm speech
      smoother.process(0.7); // starts tracking

      // Follow immediately with silence — speech candidate is reset as noise
      for (int i = 0; i < 5; i++) {
        final event = smoother.process(0.1);
        expect(event, isA<Continuation>());
        expect((event as Continuation).isSpeech, false);
      }
    });

    test('speech end after sustained silence', () {
      // Start speaking: need 3 frames to confirm (3 × 32ms = 96ms > 50ms)
      for (int i = 0; i < 5; i++) {
        smoother.process(0.8);
      }

      // Now send silence; need 2 frames to trigger SpeechEnd
      bool speechEnded = false;
      for (int i = 0; i < 5; i++) {
        final event = smoother.process(0.1);
        if (event is SpeechEnd) speechEnded = true;
      }
      expect(speechEnded, true);
    });

    test('respects hysteresis — noise near threshold does not toggle', () {
      // Probability between 0.35 and 0.5 should not change state
      for (int i = 0; i < 20; i++) {
        final event = smoother.process(0.42);
        expect(event, isA<Continuation>());
        expect((event as Continuation).isSpeech, false);
      }
    });

    test('reset clears all state', () {
      // Start speaking
      for (int i = 0; i < 5; i++) {
        smoother.process(0.9);
      }
      smoother.reset();

      // After reset, should be back to idle
      final event = smoother.process(0.1);
      expect(event, isA<Continuation>());
      expect((event as Continuation).isSpeech, false);
    });

    test('applies moving average smoothing', () {
      // Send spike then low — smoothed value is the average
      // smoothWindow = 3
      smoother.process(0.9); // buffer: [0.9]
      smoother.process(0.1); // buffer: [0.9, 0.1]
      final event = smoother.process(0.1); // buffer: [0.9, 0.1, 0.1] avg=0.37

      // 0.37 < onThreshold (0.5) and > offThreshold (0.35)
      // → no state change, continuation
      expect(event, isA<Continuation>());
      expect((event as Continuation).isSpeech, false);
      expect((event as Continuation).smoothedProb, closeTo(0.367, 0.01));
    });
  });
}
