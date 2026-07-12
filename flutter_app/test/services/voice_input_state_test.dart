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
      expect(state.phase, VoiceInputPhase.listening);
      expect(state.route, VoiceInputRoute.native);

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
      expect(state.phase, VoiceInputPhase.listening);
      expect(state.route, VoiceInputRoute.plugin);
    });

    test('cancel invalidates stale async completions', () {
      final state = VoiceInputStateMachine();
      final first = state.beginStart();
      state.enterNativeRecognition(first!);

      state.cancel();
      expect(state.phase, VoiceInputPhase.cancelled);
      expect(state.complete(first), isFalse);

      final second = state.beginStart();
      expect(second, isNot(first));
      expect(state.enterWhisperRecording(second!), isTrue);
      expect(state.phase, VoiceInputPhase.listening);
      expect(state.route, VoiceInputRoute.whisper);
    });

    test('stopping and errors are explicit and stale callbacks stay blocked',
        () {
      final state = VoiceInputStateMachine();
      final token = state.beginStart()!;
      state.enterWhisperRecording(token);

      expect(state.enterStopping(token), isTrue);
      expect(state.phase, VoiceInputPhase.stopping);
      expect(state.enterTranscribing(token), isTrue);
      expect(state.fail(token, 'transcription_failed'), isTrue);
      expect(state.phase, VoiceInputPhase.error);
      expect(state.errorCode, 'transcription_failed');

      final retry = state.beginStart();
      expect(retry, isNotNull);
      expect(state.complete(token), isFalse);
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
