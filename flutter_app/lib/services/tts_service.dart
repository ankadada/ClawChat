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
        debugPrint('TTS: no engines found');
        _available = false;
        _initialized = true;
        return;
      }

      // Try languages in order: zh-CN, zh, en-US
      final languages = await _tts.getLanguages;
      debugPrint('TTS languages: $languages');

      bool langSet = false;
      for (final lang in ['zh-CN', 'zh', 'zh_CN', 'en-US']) {
        final result = await _tts.setLanguage(lang);
        debugPrint('TTS setLanguage($lang) = $result');
        if (result == 1) {
          langSet = true;
          break;
        }
      }

      // Even if setLanguage didn't return 1, some engines still work
      _available = true;

      await _tts.setSpeechRate(0.5);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);

      _tts.setStartHandler(() {
        debugPrint('TTS: started speaking');
        isSpeaking = true;
        notifyListeners();
      });
      _tts.setCompletionHandler(() {
        debugPrint('TTS: completed');
        isSpeaking = false;
        _currentMessageId = null;
        notifyListeners();
      });
      _tts.setCancelHandler(() {
        debugPrint('TTS: cancelled');
        isSpeaking = false;
        _currentMessageId = null;
        notifyListeners();
      });
      _tts.setErrorHandler((msg) {
        debugPrint('TTS error: $msg');
        isSpeaking = false;
        _currentMessageId = null;
        lastError = '语音合成出错: $msg';
        notifyListeners();
      });

      if (!langSet) {
        debugPrint('TTS: no preferred language supported, will try anyway');
      }
    } catch (e) {
      debugPrint('TTS init failed: $e');
      _available = false;
    }
    _initialized = true;
  }

  Future<bool> speak(String text, String messageId) async {
    await init();
    debugPrint('TTS speak: available=$_available, text=${text.length} chars');

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

    // Truncate very long text to avoid TTS engine issues
    final truncated = text.length > 4000 ? text.substring(0, 4000) : text;

    final result = await _tts.speak(truncated);
    debugPrint('TTS speak result: $result');

    if (result != 1) {
      debugPrint('TTS speak returned $result, may have failed');
      // Don't immediately mark as failed - some engines return 0 but still speak
      // The error/completion handler will update the state
    }
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
