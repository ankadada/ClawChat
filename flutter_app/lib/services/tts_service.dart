import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'preferences_service.dart';

class TtsService extends ChangeNotifier {
  static final TtsService _instance = TtsService._();
  factory TtsService() => _instance;
  TtsService._();

  static const _channel = MethodChannel('com.anka.clawbot/native');
  final FlutterTts _tts = FlutterTts();
  bool _initialized = false;
  bool _systemAvailable = false;
  bool isSpeaking = false;
  String? _currentMessageId;
  String? lastError;

  bool get isAvailable {
    final ttsModel = PreferencesService().ttsModel;
    return _systemAvailable || (ttsModel != null && ttsModel.isNotEmpty);
  }

  Future<void> init() async {
    if (_initialized) return;
    try {
      final engines = await _tts.getEngines;
      debugPrint('TTS engines: $engines');
      if (engines == null || (engines as List).isEmpty) {
        debugPrint('TTS: no system engines');
        _systemAvailable = false;
        _initialized = true;
        return;
      }

      bool langSet = false;
      for (final lang in ['zh-CN', 'zh', 'zh_CN', 'en-US']) {
        final result = await _tts.setLanguage(lang);
        debugPrint('TTS setLanguage($lang) = $result');
        if (result == 1) { langSet = true; break; }
      }

      _systemAvailable = langSet;
      if (!_systemAvailable) {
        debugPrint('TTS: engines exist but no language supported');
        _initialized = true;
        return;
      }
      await _tts.setSpeechRate(0.5);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);

      _tts.setStartHandler(() {
        isSpeaking = true;
        notifyListeners();
      });
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
        lastError = '语音合成出错: $msg';
        notifyListeners();
      });
    } catch (e) {
      debugPrint('TTS init failed: $e');
      _systemAvailable = false;
    }
    _initialized = true;

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onAudioComplete') {
        isSpeaking = false;
        _currentMessageId = null;
        notifyListeners();
      }
    });
  }

  Future<bool> speak(String text, String messageId) async {
    await init();

    if (isSpeaking && _currentMessageId == messageId) {
      await stop();
      return true;
    }

    await stop();
    _currentMessageId = messageId;
    lastError = null;

    final truncated = text.length > 4000 ? text.substring(0, 4000) : text;

    if (_systemAvailable) {
      isSpeaking = true;
      notifyListeners();
      await _tts.speak(truncated);
      return true;
    }

    // Fallback: API TTS
    final prefs = PreferencesService();
    final ttsModel = prefs.ttsModel;
    if (ttsModel == null || ttsModel.isEmpty) {
      lastError = '当前设备没有语音引擎，请在设置 → 语音识别 中填写 TTS 模型名称（如 tts-1）';
      notifyListeners();
      return false;
    }

    isSpeaking = true;
    notifyListeners();

    final ok = await _speakViaApi(truncated, ttsModel, prefs);
    if (!ok) {
      isSpeaking = false;
      _currentMessageId = null;
      notifyListeners();
    }
    return ok;
  }

  Future<bool> _speakViaApi(String text, String model, PreferencesService prefs) async {
    final apiKey = prefs.apiKey;
    if (apiKey == null || apiKey.isEmpty) {
      lastError = '未配置 API Key';
      return false;
    }

    final baseUrl = prefs.baseUrl ?? 'https://api.openai.com';
    final url = '$baseUrl/v1/audio/speech';

    debugPrint('TTS API: POST $url model=$model');

    try {
      final response = await http.post(
        Uri.parse(url),
        headers: {
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'model': model,
          'input': text,
          'voice': 'alloy',
          'response_format': 'mp3',
        }),
      ).timeout(const Duration(seconds: 30));

      debugPrint('TTS API: ${response.statusCode}, ${response.bodyBytes.length} bytes');

      if (response.statusCode != 200) {
        lastError = '语音合成失败 (${response.statusCode})';
        debugPrint('TTS API error: ${response.body}');
        return false;
      }

      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/tts_output.mp3');
      await file.writeAsBytes(response.bodyBytes);

      await _channel.invokeMethod('playAudio', {'path': file.path});
      return true;
    } catch (e) {
      debugPrint('TTS API exception: $e');
      lastError = '语音合成失败: $e';
      return false;
    }
  }

  Future<void> stop() async {
    if (_systemAvailable) {
      await _tts.stop();
    }
    try {
      await _channel.invokeMethod('stopAudio');
    } catch (_) {}
    isSpeaking = false;
    _currentMessageId = null;
    notifyListeners();
  }

  bool isPlayingMessage(String messageId) =>
      isSpeaking && _currentMessageId == messageId;
}
