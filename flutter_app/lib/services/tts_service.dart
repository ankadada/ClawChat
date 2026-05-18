import 'dart:io';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';
import 'api_validator.dart';
import 'preferences_service.dart';

class TtsService extends ChangeNotifier {
  static final TtsService _instance = TtsService._();
  factory TtsService() => _instance;
  TtsService._();

  static const _channel = MethodChannel('com.anka.clawbot/native');
  final FlutterTts _tts = FlutterTts();
  bool _initialized = false;
  bool _systemAvailable = false;
  bool _systemFailedOnce = false;
  bool isSpeaking = false;
  bool isLoading = false;
  String? _currentMessageId;
  String? _lastSpokenText;
  String? lastError;

  bool isLoadingMessage(String messageId) =>
      isLoading && _currentMessageId == messageId;

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
        _systemFailedOnce = true;
        // Try API fallback if model configured and we have text + messageId
        final prefs = PreferencesService();
        final ttsModel = prefs.ttsModel;
        final text = _lastSpokenText;
        final msgId = _currentMessageId;
        if (ttsModel != null && ttsModel.isNotEmpty && text != null && msgId != null) {
          debugPrint('TTS: system failed, falling back to API');
          _speakViaApi(text, ttsModel, prefs).then((ok) {
            if (!ok) {
              isSpeaking = false;
              _currentMessageId = null;
              lastError = '系统语音合成失败，API 也失败';
              notifyListeners();
            }
          });
        } else {
          isSpeaking = false;
          _currentMessageId = null;
          lastError = ttsModel == null || ttsModel.isEmpty
              ? '系统语音合成失败（可能缺少中文语音包），请在设置 → 语音能力 中填写 TTS 模型名称启用 API 兜底'
              : '语音合成出错: $msg';
          notifyListeners();
        }
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
    _lastSpokenText = truncated;

    // Skip system TTS if it failed before (e.g., missing voice data).
    // Go straight to API if configured.
    if (_systemAvailable && !_systemFailedOnce) {
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

    isLoading = true;
    notifyListeners();

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 15);
    client.idleTimeout = const Duration(seconds: 30);
    try {
      final uri = ApiValidator.validateBearerUrl(url, context: 'TTS API endpoint');
      debugPrint('TTS API: POST $url model=$model');

      final request = await client.postUrl(uri);
      request.headers.set('Authorization', 'Bearer $apiKey');
      request.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
      request.headers.set('Accept', 'audio/mpeg');
      request.headers.set('User-Agent', 'ClawChat/1.0');
      final bodyJson = jsonEncode({
        'model': model,
        'input': text,
        'voice': 'alloy',
        'response_format': 'mp3',
      });
      request.add(utf8.encode(bodyJson));
      // Long text + ElevenLabs can take 30-60s; allow up to 90s
      final response = await request.close().timeout(const Duration(seconds: 90));
      debugPrint('TTS API: status=${response.statusCode} contentLength=${response.contentLength} contentType=${response.headers.contentType}');

      // Read response body as bytes
      final bytesBuilder = BytesBuilder();
      await for (final chunk in response) {
        bytesBuilder.add(chunk);
      }
      final body = bytesBuilder.toBytes();
      debugPrint('TTS API: received ${body.length} bytes');

      if (response.statusCode != 200) {
        final errText = utf8.decode(body, allowMalformed: true);
        lastError = '语音合成失败 (${response.statusCode}): ${errText.length > 200 ? errText.substring(0, 200) : errText}';
        return false;
      }
      if (body.isEmpty) {
        lastError = '语音合成失败: 服务器返回空响应';
        return false;
      }

      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/tts_${DateTime.now().millisecondsSinceEpoch}.mp3');
      await file.writeAsBytes(body);

      await _channel.invokeMethod('playAudio', {'path': file.path});
      isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('TTS API exception: $e');
      lastError = '语音合成失败: $e';
      return false;
    } finally {
      isLoading = false;
      notifyListeners();
      client.close(force: true);
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
