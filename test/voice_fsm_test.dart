import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_voice_demo/voice/voice_fsm.dart';
import 'package:flutter_voice_demo/voice/voice_state.dart';

void main() {
  group('VoiceFSM', () {
    late VoiceFSM fsm;

    setUp(() {
      fsm = VoiceFSM();
    });

    test('starts in idle', () {
      expect(fsm.current, VoiceState.idle);
    });

    test('idle → initializing', () {
      expect(fsm.transition(VoiceState.initializing), true);
      expect(fsm.current, VoiceState.initializing);
    });

    test('initializing → listening', () {
      fsm.transition(VoiceState.initializing);
      expect(fsm.transition(VoiceState.listening), true);
      expect(fsm.current, VoiceState.listening);
    });

    test('listening → thinking (speech end)', () {
      fsm.transition(VoiceState.initializing);
      fsm.transition(VoiceState.listening);
      expect(fsm.transition(VoiceState.thinking), true);
      expect(fsm.current, VoiceState.thinking);
    });

    test('thinking → speaking (TTS start)', () {
      fsm.transition(VoiceState.initializing);
      fsm.transition(VoiceState.listening);
      fsm.transition(VoiceState.thinking);
      expect(fsm.transition(VoiceState.speaking), true);
      expect(fsm.current, VoiceState.speaking);
    });

    test('speaking → interrupted (user interrupt)', () {
      fsm.transition(VoiceState.initializing);
      fsm.transition(VoiceState.listening);
      fsm.transition(VoiceState.thinking);
      fsm.transition(VoiceState.speaking);
      expect(fsm.transition(VoiceState.interrupted), true);
      expect(fsm.current, VoiceState.interrupted);
    });

    test('interrupted → listening (resume)', () {
      fsm.transition(VoiceState.initializing);
      fsm.transition(VoiceState.listening);
      fsm.transition(VoiceState.thinking);
      fsm.transition(VoiceState.speaking);
      fsm.transition(VoiceState.interrupted);
      expect(fsm.transition(VoiceState.listening), true);
      expect(fsm.current, VoiceState.listening);
    });

    test('full cycle: idle → listening → thinking → speaking → listening', () {
      fsm.transition(VoiceState.initializing);
      fsm.transition(VoiceState.listening);
      fsm.transition(VoiceState.thinking);
      fsm.transition(VoiceState.speaking);
      fsm.transition(VoiceState.listening);
      expect(fsm.current, VoiceState.listening);
    });

    test('rejects invalid transitions', () {
      // Cannot go from idle directly to speaking
      expect(fsm.transition(VoiceState.speaking), false);
      expect(fsm.current, VoiceState.idle);

      // Cannot go from thinking to thinking
      fsm.transition(VoiceState.initializing);
      fsm.transition(VoiceState.listening);
      fsm.transition(VoiceState.thinking);
      // thinking → thinking
      expect(fsm.transition(VoiceState.thinking), false);
    });

    test('force bypasses transition validation', () {
      fsm.force(VoiceState.speaking); // Normally invalid from idle
      expect(fsm.current, VoiceState.speaking);
    });

    test('any state can transition to error', () {
      fsm.transition(VoiceState.initializing);
      expect(fsm.transition(VoiceState.error), true);
      expect(fsm.current, VoiceState.error);
    });

    test('error can only transition to idle', () {
      fsm.transition(VoiceState.initializing);
      fsm.transition(VoiceState.error);
      expect(fsm.transition(VoiceState.idle), true);
    });

    test('any state can transition to idle (stop/reset)', () {
      fsm.transition(VoiceState.initializing);
      fsm.transition(VoiceState.listening);
      fsm.transition(VoiceState.thinking);
      expect(fsm.transition(VoiceState.idle), true);
    });

    test('reset goes to idle', () {
      fsm.transition(VoiceState.initializing);
      fsm.transition(VoiceState.listening);
      fsm.reset();
      expect(fsm.current, VoiceState.idle);
    });

    test('listening → listeningLong', () {
      fsm.transition(VoiceState.initializing);
      fsm.transition(VoiceState.listening);
      expect(fsm.transition(VoiceState.listeningLong), true);
      expect(fsm.current, VoiceState.listeningLong);
    });

    test('listeningLong → thinking', () {
      fsm.transition(VoiceState.initializing);
      fsm.transition(VoiceState.listening);
      fsm.transition(VoiceState.listeningLong);
      expect(fsm.transition(VoiceState.thinking), true);
      expect(fsm.current, VoiceState.thinking);
    });
  });
}
