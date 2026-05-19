enum VoiceInputPhase {
  idle,
  starting,
  nativeRecognition,
  pluginRecognition,
  whisperRecording,
  transcribing,
}

class VoiceInputStateMachine {
  VoiceInputPhase phase = VoiceInputPhase.idle;
  int _token = 0;

  int? beginStart() {
    if (phase != VoiceInputPhase.idle) return null;
    _token += 1;
    phase = VoiceInputPhase.starting;
    return _token;
  }

  int get activeToken => _token;

  bool isCurrent(int token) => token == _token;

  bool get isListening =>
      phase == VoiceInputPhase.starting ||
      phase == VoiceInputPhase.nativeRecognition ||
      phase == VoiceInputPhase.pluginRecognition;

  bool get isWhisperRecording => phase == VoiceInputPhase.whisperRecording;

  bool get isBusy => phase != VoiceInputPhase.idle;

  bool enterNativeRecognition(int token) =>
      _enter(token, VoiceInputPhase.nativeRecognition);

  bool enterPluginRecognition(int token) =>
      _enter(token, VoiceInputPhase.pluginRecognition);

  bool enterWhisperRecording(int token) =>
      _enter(token, VoiceInputPhase.whisperRecording);

  bool enterTranscribing(int token) =>
      _enter(token, VoiceInputPhase.transcribing);

  bool complete(int token) {
    if (!isCurrent(token)) return false;
    phase = VoiceInputPhase.idle;
    return true;
  }

  void cancel() {
    _token += 1;
    phase = VoiceInputPhase.idle;
  }

  bool _enter(int token, VoiceInputPhase nextPhase) {
    if (!isCurrent(token)) return false;
    phase = nextPhase;
    return true;
  }
}
