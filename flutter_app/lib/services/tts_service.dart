import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

class TtsService extends ChangeNotifier {
  static final TtsService _instance = TtsService._();
  factory TtsService() => _instance;
  TtsService._();

  final FlutterTts _tts = FlutterTts();
  bool _initialized = false;
  bool isSpeaking = false;
  String? _currentMessageId;

  Future<void> init() async {
    if (_initialized) return;
    await _tts.setLanguage('zh-CN');
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
    _tts.setCompletionHandler(() {
      isSpeaking = false;
      _currentMessageId = null;
      notifyListeners();
    });
    _tts.setCancelHandler(() {
      isSpeaking = false;
      _currentMessageId = null;
      notifyListeners();
    });
    _initialized = true;
  }

  Future<void> speak(String text, String messageId) async {
    await init();
    if (isSpeaking && _currentMessageId == messageId) {
      await stop();
      return;
    }
    await stop();
    _currentMessageId = messageId;
    isSpeaking = true;
    notifyListeners();
    await _tts.speak(text);
  }

  Future<void> stop() async {
    await _tts.stop();
    isSpeaking = false;
    _currentMessageId = null;
    notifyListeners();
  }

  bool isPlayingMessage(String messageId) =>
      isSpeaking && _currentMessageId == messageId;
}
