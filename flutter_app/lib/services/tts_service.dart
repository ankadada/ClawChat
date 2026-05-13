import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

class TtsService extends ChangeNotifier {
  static final TtsService _instance = TtsService._();
  factory TtsService() => _instance;
  TtsService._();

  final FlutterTts _tts = FlutterTts();
  bool _initialized = false;
  bool _available = false;
  bool isSpeaking = false;
  String? _currentMessageId;
  String? lastError;

  bool get isAvailable => _available;

  Future<void> init() async {
    if (_initialized) return;
    try {
      final engines = await _tts.getEngines;
      debugPrint('TTS engines: $engines');
      if (engines == null || (engines as List).isEmpty) {
        _available = false;
        _initialized = true;
        return;
      }

      final result = await _tts.setLanguage('zh-CN');
      if (result == 0) {
        // zh-CN not supported, try zh
        final fallback = await _tts.setLanguage('zh');
        _available = fallback == 1;
      } else {
        _available = true;
      }

      if (_available) {
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
        _tts.setErrorHandler((msg) {
          debugPrint('TTS error: $msg');
          isSpeaking = false;
          _currentMessageId = null;
          lastError = msg;
          notifyListeners();
        });
      }
    } catch (e) {
      debugPrint('TTS init failed: $e');
      _available = false;
    }
    _initialized = true;
  }

  Future<bool> speak(String text, String messageId) async {
    await init();
    if (!_available) {
      lastError = '当前设备没有可用的语音合成引擎，请在系统设置 → 无障碍 → 文字转语音中安装语音引擎';
      notifyListeners();
      return false;
    }
    if (isSpeaking && _currentMessageId == messageId) {
      await stop();
      return true;
    }
    await stop();
    _currentMessageId = messageId;
    isSpeaking = true;
    lastError = null;
    notifyListeners();
    await _tts.speak(text);
    return true;
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
