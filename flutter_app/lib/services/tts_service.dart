import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';
import '../l10n/app_strings.dart';
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
  int _systemFailCount = 0;
  String? _selectedSystemLanguage;
  bool _systemQueueActive = false;
  int _systemQueuedChunkCount = 0;
  int _systemCompletedChunkCount = 0;
  bool _systemFallbackInProgress = false;
  bool isSpeaking = false;
  bool isLoading = false;
  String? _currentMessageId;
  String? _currentRouteLabel;
  String? _lastSpokenText;
  String? lastError;
  static const int _maxSystemFailures = 3;
  static const int _defaultSystemChunkLimit = 1800;
  static const List<String> _preferredSystemLanguages = [
    'zh-CN',
    'zh_CN',
    'zh',
    'cmn-hans-cn',
    'zh-Hans-CN',
    'en-US',
    'en_US',
    'en',
  ];

  bool isLoadingMessage(String messageId) =>
      isLoading && _currentMessageId == messageId;

  String? routeLabelForMessage(String messageId) =>
      _currentMessageId == messageId ? _currentRouteLabel : null;

  bool get isAvailable {
    final ttsModel = PreferencesService().ttsModel;
    return _systemAvailable || (ttsModel != null && ttsModel.isNotEmpty);
  }

  Future<void> init() async {
    if (_initialized) return;

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onAudioComplete') {
        _systemFallbackInProgress = false;
        isSpeaking = false;
        _currentMessageId = null;
        _currentRouteLabel = null;
        notifyListeners();
      }
    });

    try {
      await _prepareSystemEngine(forceLanguageProbe: true);

      _tts.setStartHandler(() {
        isSpeaking = true;
        notifyListeners();
      });
      _tts.setCompletionHandler(() {
        if (_systemFallbackInProgress) return;
        if (_systemQueueActive) {
          _systemCompletedChunkCount += 1;
          if (_systemCompletedChunkCount < _systemQueuedChunkCount) return;
          _systemQueueActive = false;
          _systemQueuedChunkCount = 0;
          _systemCompletedChunkCount = 0;
        }
        _systemFailCount = 0;
        isSpeaking = false;
        _currentMessageId = null;
        _currentRouteLabel = null;
        notifyListeners();
      });
      _tts.setCancelHandler(() {
        if (_systemFallbackInProgress) return;
        _systemQueueActive = false;
        _systemQueuedChunkCount = 0;
        _systemCompletedChunkCount = 0;
        isSpeaking = false;
        _currentMessageId = null;
        _currentRouteLabel = null;
        notifyListeners();
      });
      _tts.setErrorHandler(_handleSystemTtsError);
    } catch (e) {
      debugPrint('TTS init failed: $e');
      _systemAvailable = false;
    }
    _initialized = true;
  }

  List<String> _stringList(dynamic value) {
    if (value is Iterable) {
      return value.map((item) => item.toString()).toList();
    }
    return const [];
  }

  bool _isTtsSuccess(dynamic result) => result == true || result == 1;

  bool _isChineseLanguage(String language) {
    final normalized = language.toLowerCase().replaceAll('_', '-');
    return normalized.startsWith('zh') ||
        normalized.startsWith('cmn') ||
        normalized.contains('hans') ||
        normalized.contains('chinese');
  }

  Future<String?> _selectSystemLanguage(List<String> availableLanguages) async {
    for (final lang in _preferredSystemLanguages) {
      try {
        final available = await _tts.isLanguageAvailable(lang);
        debugPrint('TTS isLanguageAvailable($lang) = $available');
        if (_isTtsSuccess(available)) {
          final result = await _tts.setLanguage(lang);
          debugPrint('TTS setLanguage($lang) = $result');
          if (_isTtsSuccess(result)) return lang;
        }
      } catch (e) {
        debugPrint('TTS language check $lang failed: $e');
      }
    }

    for (final lang in availableLanguages.where(_isChineseLanguage)) {
      try {
        final result = await _tts.setLanguage(lang);
        debugPrint('TTS setLanguage($lang) = $result');
        if (_isTtsSuccess(result)) return lang;
      } catch (e) {
        debugPrint('TTS fallback language $lang failed: $e');
      }
    }

    return null;
  }

  Future<String?> _prepareSystemEngine(
      {bool forceLanguageProbe = false}) async {
    final engines = _stringList(await _tts.getEngines);
    debugPrint('TTS engines: $engines');
    if (engines.isEmpty) {
      debugPrint('TTS: no system engines');
      _systemAvailable = false;
      return null;
    }

    final languages = _stringList(await _tts.getLanguages);
    debugPrint('TTS available languages: $languages');
    var selectedLanguage = forceLanguageProbe ? null : _selectedSystemLanguage;
    if (selectedLanguage == null) {
      selectedLanguage = await _selectSystemLanguage(languages);
    } else {
      final result = await _tts.setLanguage(selectedLanguage);
      debugPrint('TTS setLanguage($selectedLanguage) = $result');
      if (!_isTtsSuccess(result)) {
        selectedLanguage = await _selectSystemLanguage(languages);
      }
    }

    if (selectedLanguage == null) {
      debugPrint('TTS: engines exist but no language supported');
      _selectedSystemLanguage = null;
      _systemAvailable = false;
      return null;
    }

    _selectedSystemLanguage = selectedLanguage;
    _systemAvailable = true;
    _systemFailCount = 0;
    debugPrint('TTS: selected system language $selectedLanguage');
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
    await _tts.awaitSpeakCompletion(false);
    if (Platform.isAndroid) {
      await _tts.setQueueMode(0);
    }
    return selectedLanguage;
  }

  String _summarizeList(List<String> values) {
    if (values.isEmpty) return '无';
    final sample = values.take(12).join(', ');
    if (values.length <= 12) return sample;
    return '$sample ... 共 ${values.length} 项';
  }

  Future<String> diagnoseSystemVoice() async {
    final lines = <String>[];
    try {
      await init();
      final engines = _stringList(await _tts.getEngines);
      final languages = _stringList(await _tts.getLanguages);
      lines.add('TTS 引擎: ${_summarizeList(engines)}');
      lines.add('TTS 语言: ${_summarizeList(languages)}');

      if (engines.isEmpty) {
        lines.add('TTS 测试: 未发现系统语音引擎。请在系统设置中启用 HiVoice 或安装文本转语音引擎。');
        return lines.join('\n');
      }

      final language = await _prepareSystemEngine(forceLanguageProbe: true);
      if (language == null) {
        lines.add('TTS 测试: 未找到可用的中文语音包。请在系统文本转语音设置中下载中文语音数据。');
        return lines.join('\n');
      }

      _systemAvailable = true;
      await _tts.stop();
      _currentMessageId = null;
      _currentRouteLabel = null;
      _lastSpokenText = null;
      await _prepareSystemEngine(forceLanguageProbe: false);
      final result = await _tts.speak('系统语音测试，ClawChat 正在使用手机内置语音引擎。');
      lines.add('TTS 测试: 已调用系统引擎，语言 $language，结果 $result。');
    } catch (e) {
      lines.add('TTS 测试失败: $e');
      lines.add('建议检查系统文本转语音设置，确认 HiVoice 已启用且中文语音包已安装。');
    }
    return lines.join('\n');
  }

  Future<bool> speak(String text, String messageId) async {
    await init();

    if (isSpeaking && _currentMessageId == messageId) {
      await stop();
      return true;
    }

    await stop();
    _currentMessageId = messageId;
    _currentRouteLabel = null;
    lastError = null;

    final speakableText = _normalizeTextForSpeech(text);
    if (speakableText.isEmpty) {
      lastError = '没有可朗读的文本';
      notifyListeners();
      return false;
    }
    _lastSpokenText = speakableText;

    if (_systemAvailable ||
        await _prepareSystemEngine(forceLanguageProbe: true) != null) {
      final systemStarted = await _speakViaSystem(speakableText, messageId);
      if (systemStarted) return true;
    }

    // Fallback: API TTS
    final prefs = PreferencesService();
    final ttsModel = prefs.ttsModel;
    if (ttsModel == null || ttsModel.isEmpty) {
      lastError = '当前设备没有语音引擎，请在设置 → 语音识别 中填写 TTS 模型名称（如 tts-1）';
      _currentRouteLabel = null;
      notifyListeners();
      return false;
    }

    isSpeaking = true;
    _currentRouteLabel = AppStrings.ttsApiEngine(ttsModel);
    notifyListeners();

    final ok = await _speakViaApi(speakableText, ttsModel, prefs);
    if (!ok) {
      isSpeaking = false;
      _currentMessageId = null;
      _currentRouteLabel = null;
      notifyListeners();
    }
    return ok;
  }

  Future<bool> _speakViaSystem(String text, String messageId) async {
    try {
      final language = await _prepareSystemEngine(forceLanguageProbe: false);
      if (language == null) return false;

      final limit = await _systemChunkLimit();
      final chunks = _splitTextForSystemSpeech(text, maxLength: limit);
      if (chunks.isEmpty) return false;

      _systemQueueActive = true;
      _systemQueuedChunkCount = chunks.length;
      _systemCompletedChunkCount = 0;
      _systemFallbackInProgress = false;
      isSpeaking = true;
      _currentMessageId = messageId;
      _currentRouteLabel = AppStrings.ttsSystemEngine;
      notifyListeners();

      for (var i = 0; i < chunks.length; i += 1) {
        if (Platform.isAndroid) {
          await _tts.setQueueMode(i == 0 ? 0 : 1);
        }
        final result = await _tts.speak(chunks[i]);
        debugPrint('TTS system chunk ${i + 1}/${chunks.length}: $result');
        if (!_isTtsSuccess(result)) {
          throw StateError('System TTS rejected chunk ${i + 1}');
        }
      }
      if (Platform.isAndroid) {
        await _tts.setQueueMode(0);
      }
      return true;
    } catch (e) {
      debugPrint('TTS system speak failed before playback: $e');
      _systemQueueActive = false;
      _systemQueuedChunkCount = 0;
      _systemCompletedChunkCount = 0;
      _systemFailCount += 1;
      if (_systemFailCount >= _maxSystemFailures) {
        _systemAvailable = false;
      }
      isSpeaking = false;
      _currentRouteLabel = null;
      notifyListeners();
      return false;
    }
  }

  Future<int> _systemChunkLimit() async {
    if (!Platform.isAndroid) return _defaultSystemChunkLimit;
    try {
      final maxLength = await _tts.getMaxSpeechInputLength;
      if (maxLength == null || maxLength <= 0) return _defaultSystemChunkLimit;
      final safeLength = maxLength - 100;
      return safeLength.clamp(400, _defaultSystemChunkLimit).toInt();
    } catch (_) {
      return _defaultSystemChunkLimit;
    }
  }

  void _handleSystemTtsError(dynamic msg) {
    debugPrint('TTS error: $msg');
    _systemQueueActive = false;
    _systemQueuedChunkCount = 0;
    _systemCompletedChunkCount = 0;
    _systemFailCount += 1;
    if (_systemFailCount >= _maxSystemFailures) {
      debugPrint('TTS: system failed $_systemFailCount times, disabling');
      _systemAvailable = false;
    }

    final prefs = PreferencesService();
    final ttsModel = prefs.ttsModel;
    final text = _lastSpokenText;
    final msgId = _currentMessageId;
    if (ttsModel != null &&
        ttsModel.isNotEmpty &&
        text != null &&
        msgId != null) {
      debugPrint('TTS: system failed, falling back to API');
      _systemFallbackInProgress = true;
      isSpeaking = true;
      _currentRouteLabel = AppStrings.ttsApiEngine(ttsModel);
      notifyListeners();
      _speakViaApi(text, ttsModel, prefs).then((ok) {
        _systemFallbackInProgress = false;
        if (!ok) {
          isSpeaking = false;
          _currentMessageId = null;
          _currentRouteLabel = null;
          lastError = '系统语音合成失败，API 也失败';
          notifyListeners();
        }
      });
    } else {
      _systemFallbackInProgress = false;
      isSpeaking = false;
      _currentMessageId = null;
      _currentRouteLabel = null;
      lastError = ttsModel == null || ttsModel.isEmpty
          ? '系统语音合成失败（可能缺少中文语音包），请在设置 → 语音能力 中填写 TTS 模型名称启用 API 兜底'
          : '语音合成出错: $msg';
      notifyListeners();
    }
  }

  @visibleForTesting
  String normalizeTextForSpeech(String text) => _normalizeTextForSpeech(text);

  String _normalizeTextForSpeech(String text) {
    var value = text;
    value = value.replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), ' ');
    value = value.replaceAll(RegExp(r'```[\s\S]*?```'), ' 代码块 ');
    value = value.replaceAllMapped(
      RegExp(r'!\[([^\]]*)\]\([^)]+\)'),
      (match) =>
          match.group(1)?.isEmpty ?? true ? ' 图片 ' : ' 图片 ${match.group(1)} ',
    );
    value = value.replaceAllMapped(
      RegExp(r'\[([^\]]+)\]\([^)]+\)'),
      (match) => match.group(1) ?? '',
    );
    value = value.replaceAllMapped(
      RegExp(r'`([^`]*)`'),
      (match) => match.group(1) ?? '',
    );
    value = value.replaceAll(RegExp(r'https?://\S+'), ' 链接 ');
    value = value.replaceAll(RegExp(r'<[^>]+>'), ' ');
    value = value.replaceAll(RegExp(r'^\s{0,3}#{1,6}\s*', multiLine: true), '');
    value = value.replaceAll(RegExp(r'^\s*>+\s?', multiLine: true), '');
    value = value.replaceAll(RegExp(r'^\s*[-*+]\s+', multiLine: true), '');
    value = value.replaceAll(RegExp(r'^\s*\d+[\.)]\s+', multiLine: true), '');
    value =
        value.replaceAll(RegExp(r'^\s*[-:| ]{3,}\s*$', multiLine: true), ' ');
    value = value.replaceAll('|', '，');
    value = value.replaceAll(RegExp(r'[*_~#\[\]()]'), ' ');
    value = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return value;
  }

  @visibleForTesting
  List<String> splitTextForSystemSpeech(
    String text, {
    int maxLength = _defaultSystemChunkLimit,
  }) =>
      _splitTextForSystemSpeech(text, maxLength: maxLength);

  List<String> _splitTextForSystemSpeech(
    String text, {
    required int maxLength,
  }) {
    final limit = maxLength.clamp(120, _defaultSystemChunkLimit).toInt();
    final chunks = <String>[];
    var remaining = text.trim();
    while (remaining.length > limit) {
      var splitAt = -1;
      for (final delimiter in const [
        '。',
        '！',
        '？',
        '. ',
        '! ',
        '? ',
        '；',
        '; ',
        '，',
        ', '
      ]) {
        final index = remaining.lastIndexOf(delimiter, limit);
        if (index > limit ~/ 3) {
          splitAt = index + delimiter.length;
          break;
        }
      }
      if (splitAt <= 0) splitAt = limit;
      final chunk = remaining.substring(0, splitAt).trim();
      if (chunk.isNotEmpty) chunks.add(chunk);
      remaining = remaining.substring(splitAt).trim();
    }
    if (remaining.isNotEmpty) chunks.add(remaining);
    return chunks;
  }

  Future<bool> _speakViaApi(
      String text, String model, PreferencesService prefs) async {
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
      final uri =
          ApiValidator.validateBearerUrl(url, context: 'TTS API endpoint');
      debugPrint('TTS API: POST $url model=$model');

      final request = await client.postUrl(uri);
      request.headers.set('Authorization', 'Bearer $apiKey');
      request.headers.contentType =
          ContentType('application', 'json', charset: 'utf-8');
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
      final response =
          await request.close().timeout(const Duration(seconds: 90));
      debugPrint(
          'TTS API: status=${response.statusCode} contentLength=${response.contentLength} contentType=${response.headers.contentType}');

      // Read response body as bytes
      final bytesBuilder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        bytesBuilder.add(chunk);
      }
      final body = bytesBuilder.toBytes();
      debugPrint('TTS API: received ${body.length} bytes');

      if (response.statusCode != 200) {
        final errText = utf8.decode(body, allowMalformed: true);
        lastError =
            '语音合成失败 (${response.statusCode}): ${errText.length > 200 ? errText.substring(0, 200) : errText}';
        return false;
      }
      if (body.isEmpty) {
        lastError = '语音合成失败: 服务器返回空响应';
        return false;
      }

      final dir = await getTemporaryDirectory();
      final file =
          File('${dir.path}/tts_${DateTime.now().millisecondsSinceEpoch}.mp3');
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
    _systemQueueActive = false;
    _systemQueuedChunkCount = 0;
    _systemCompletedChunkCount = 0;
    _systemFallbackInProgress = false;
    try {
      await _tts.stop();
      if (Platform.isAndroid) {
        await _tts.setQueueMode(0);
      }
    } catch (_) {}
    try {
      await _channel.invokeMethod('stopAudio');
    } catch (_) {}
    isSpeaking = false;
    _currentMessageId = null;
    _currentRouteLabel = null;
    notifyListeners();
  }

  bool isPlayingMessage(String messageId) =>
      isSpeaking && _currentMessageId == messageId;
}
