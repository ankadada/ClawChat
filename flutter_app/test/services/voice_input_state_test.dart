import 'package:clawchat/services/voice_input_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('VoiceInputStateMachine', () {
    test('returns to idle after a native recognition completes', () {
      final state = VoiceInputStateMachine();

      final token = state.beginStart();
      expect(token, isNotNull);
      expect(state.isListening, isTrue);

      expect(state.enterNativeRecognition(token!), isTrue);
      expect(state.phase, VoiceInputPhase.nativeRecognition);

      expect(state.complete(token), isTrue);
      expect(state.phase, VoiceInputPhase.idle);
      expect(state.isListening, isFalse);

      expect(state.beginStart(), isNotNull);
    });

    test('blocks a second start while any voice phase is active', () {
      final state = VoiceInputStateMachine();
      final token = state.beginStart();
      state.enterPluginRecognition(token!);

      expect(state.beginStart(), isNull);
      expect(state.phase, VoiceInputPhase.pluginRecognition);
    });

    test('cancel invalidates stale async completions', () {
      final state = VoiceInputStateMachine();
      final first = state.beginStart();
      state.enterNativeRecognition(first!);

      state.cancel();
      expect(state.phase, VoiceInputPhase.idle);
      expect(state.complete(first), isFalse);

      final second = state.beginStart();
      expect(second, isNot(first));
      expect(state.enterWhisperRecording(second!), isTrue);
      expect(state.phase, VoiceInputPhase.whisperRecording);
    });

    test('transcribing keeps the mic busy until completion', () {
      final state = VoiceInputStateMachine();
      final token = state.beginStart();
      state.enterWhisperRecording(token!);
      state.enterTranscribing(token);

      expect(state.isBusy, isTrue);
      expect(state.isWhisperRecording, isFalse);
      expect(state.beginStart(), isNull);

      state.complete(token);
      expect(state.isBusy, isFalse);
    });
  });
}
