enum VoiceInputPhase {
  idle,
  listening,
  stopping,
  transcribing,
  cancelled,
  error,
}

enum VoiceInputRoute { native, plugin, whisper }

class VoiceInputStateMachine {
  VoiceInputPhase phase = VoiceInputPhase.idle;
  VoiceInputRoute? route;
  String? errorCode;
  int _token = 0;

  int? beginStart() {
    if (isBusy) return null;
    _token += 1;
    errorCode = null;
    route = null;
    phase = VoiceInputPhase.listening;
    return _token;
  }

  int get activeToken => _token;

  bool isCurrent(int token) => token == _token;

  bool get isListening => phase == VoiceInputPhase.listening;

  bool get isWhisperRecording =>
      phase == VoiceInputPhase.listening && route == VoiceInputRoute.whisper;

  bool get isBusy => !isTerminal;
  bool get isTerminal =>
      phase == VoiceInputPhase.idle ||
      phase == VoiceInputPhase.cancelled ||
      phase == VoiceInputPhase.error;

  bool enterStopping(int token) => _enter(token, VoiceInputPhase.stopping);

  bool enterNativeRecognition(int token) =>
      _enterListening(token, VoiceInputRoute.native);

  bool enterPluginRecognition(int token) =>
      _enterListening(token, VoiceInputRoute.plugin);

  bool enterWhisperRecording(int token) =>
      _enterListening(token, VoiceInputRoute.whisper);

  bool enterTranscribing(int token) =>
      _enter(token, VoiceInputPhase.transcribing);

  bool complete(int token) {
    if (!isCurrent(token)) return false;
    phase = VoiceInputPhase.idle;
    route = null;
    errorCode = null;
    route = null;
    return true;
  }

  void cancel() {
    _token += 1;
    errorCode = null;
    phase = VoiceInputPhase.cancelled;
  }

  bool fail(int token, String code) {
    if (!isCurrent(token)) return false;
    errorCode = code;
    route = null;
    phase = VoiceInputPhase.error;
    return true;
  }

  bool _enter(int token, VoiceInputPhase nextPhase) {
    if (!isCurrent(token)) return false;
    phase = nextPhase;
    return true;
  }

  bool _enterListening(int token, VoiceInputRoute nextRoute) {
    if (!isCurrent(token)) return false;
    route = nextRoute;
    phase = VoiceInputPhase.listening;
    return true;
  }
}
