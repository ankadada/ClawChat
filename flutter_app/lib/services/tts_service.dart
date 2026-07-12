import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../l10n/app_strings.dart';
import 'app_http.dart';
import 'api_validator.dart';
import 'preferences_service.dart';

class TtsService extends ChangeNotifier {
  static final TtsService _instance = TtsService._();
  factory TtsService({AppHttpClient? httpClient}) {
    if (httpClient != null) _instance._injectedClient = httpClient;
    return _instance;
  }
  TtsService._();

  static const _channel = MethodChannel('com.anka.clawbot/native');
  final FlutterTts _tts = FlutterTts();
  bool _initialized = false;
  Future<void>? _initialization;
  bool _systemAvailable = false;
  int _systemFailCount = 0;
  String? _selectedSystemLanguage;
  bool _systemQueueActive = false;
  int _playbackToken = 0;
  int _requestGeneration = 0;
  Future<void> _mediaControlTail = Future<void>.value();
  int _systemPlaybackToken = 0;
  bool _systemStopRequested = false;
  bool _systemPaused = false;
  String? _systemCurrentChunk;
  Completer<bool>? _systemChunkCompleter;
  bool isSpeaking = false;
  bool isLoading = false;
  String? _currentMessageId;
  String? _currentRouteLabel;
  String? _lastSpokenText;
  AppHttpClient? _injectedClient;
  Completer<void>? _activeApiAbort;
  final Map<String, _TtsApiAudioOperation> _apiAudioOperations = {};
  _TtsApiAudioOperation? _activeApiAudio;
  int _apiAudioSequence = 0;
  String? lastError;
  static const int _maxSystemFailures = 3;
  static const int _defaultSystemChunkLimit = 220;
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

  AppHttpClient get _httpClient =>
      _injectedClient ?? AppHttpClientRegistry.instance.client;

  bool isLoadingMessage(String messageId) =>
      isLoading && _currentMessageId == messageId;

  String? routeLabelForMessage(String messageId) =>
      _currentMessageId == messageId ? _currentRouteLabel : null;

  bool isPausedMessage(String messageId) =>
      _systemPaused && _currentMessageId == messageId;

  bool isSystemMessage(String messageId) =>
      _currentMessageId == messageId &&
      _currentRouteLabel == AppStrings.ttsSystemEngine;

  bool get isAvailable {
    final ttsModel = PreferencesService().ttsModel;
    return _systemAvailable || (ttsModel != null && ttsModel.isNotEmpty);
  }

  Future<void> init() {
    if (_initialized) return Future<void>.value();
    return _initialization ??= _initialize();
  }

  Future<void> _initialize() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onAudioComplete') {
        await _handleNativeAudioEvent(call.arguments);
        if (_systemQueueActive) return;
      }
    });

    try {
      await _prepareSystemEngine(forceLanguageProbe: true);

      _tts.setStartHandler(() {
        isSpeaking = true;
        notifyListeners();
      });
      _tts.setCompletionHandler(() {
        if (_systemQueueActive) {
          _completeSystemChunk(true);
          return;
        }
        _systemFailCount = 0;
        isSpeaking = false;
        _currentMessageId = null;
        _currentRouteLabel = null;
        notifyListeners();
      });
      _tts.setPauseHandler(() {
        if (_systemQueueActive) {
          _systemPaused = true;
          isSpeaking = false;
          notifyListeners();
        }
      });
      _tts.setContinueHandler(() {
        if (_systemQueueActive) {
          _systemPaused = false;
          isSpeaking = true;
          notifyListeners();
        }
      });
      _tts.setCancelHandler(() {
        if (_systemQueueActive) {
          _systemStopRequested = true;
          _completeSystemChunk(false);
          return;
        }
        isSpeaking = false;
        _currentMessageId = null;
        _currentRouteLabel = null;
        notifyListeners();
      });
      _tts.setErrorHandler(_handleSystemTtsError);
    } catch (_) {
      debugPrint('TTS initialization failed');
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
        if (_isTtsSuccess(available)) {
          final result = await _tts.setLanguage(lang);
          if (_isTtsSuccess(result)) return lang;
        }
      } catch (_) {
        debugPrint('TTS language availability check failed');
      }
    }

    for (final lang in availableLanguages.where(_isChineseLanguage)) {
      try {
        final result = await _tts.setLanguage(lang);
        if (_isTtsSuccess(result)) return lang;
      } catch (_) {
        debugPrint('TTS fallback language selection failed');
      }
    }

    return null;
  }

  Future<String?> _prepareSystemEngine(
      {bool forceLanguageProbe = false}) async {
    final engines = _stringList(await _tts.getEngines);
    debugPrint('TTS engine count=${engines.length}');
    if (engines.isEmpty) {
      debugPrint('TTS: no system engines');
      _systemAvailable = false;
      return null;
    }

    final languages = _stringList(await _tts.getLanguages);
    debugPrint('TTS language count=${languages.length}');
    var selectedLanguage = forceLanguageProbe ? null : _selectedSystemLanguage;
    if (selectedLanguage == null) {
      selectedLanguage = await _selectSystemLanguage(languages);
    } else {
      final result = await _tts.setLanguage(selectedLanguage);
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
    debugPrint('TTS system language selected');
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

  Future<bool> speak(String text, String messageId) {
    final generation = ++_requestGeneration;
    return _speakForGeneration(text, messageId, generation);
  }

  Future<bool> _speakForGeneration(
    String text,
    String messageId,
    int generation,
  ) async {
    await init();
    if (!_isRequestCurrent(generation)) return false;

    if (_currentMessageId == messageId &&
        (_systemQueueActive || _systemPaused)) {
      if (_systemPaused) {
        return _resumeSystemPlayback(generation);
      }
      if (isSpeaking) {
        return _pauseSystemPlayback(generation);
      }
    }

    if ((isSpeaking || isLoading) && _currentMessageId == messageId) {
      await _stopForGeneration(generation);
      return _isRequestCurrent(generation);
    }

    await _stopForGeneration(generation);
    if (!_isRequestCurrent(generation)) return false;
    final playbackToken = generation;
    _playbackToken = playbackToken;
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

    final systemReady = _systemAvailable ||
        await _prepareSystemEngine(forceLanguageProbe: true) != null;
    if (!_isRequestCurrent(generation)) return false;
    if (systemReady) {
      return _speakViaSystem(speakableText, messageId, playbackToken);
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

    final ok =
        await _speakViaApi(speakableText, ttsModel, prefs, playbackToken);
    if (!_isRequestCurrent(generation)) return false;
    if (!ok) {
      if (_isPlaybackCurrent(playbackToken)) {
        isSpeaking = false;
        _currentMessageId = null;
        _currentRouteLabel = null;
        notifyListeners();
      }
    }
    return ok;
  }

  Future<bool> _speakViaSystem(
    String text,
    String messageId,
    int playbackToken,
  ) async {
    try {
      final language = await _prepareSystemEngine(forceLanguageProbe: false);
      if (!_isRequestCurrent(playbackToken)) return false;
      if (language == null) return false;

      final limit = await _systemChunkLimit();
      if (!_isRequestCurrent(playbackToken)) return false;
      final chunks = _splitTextForSystemSpeech(text, maxLength: limit);
      if (chunks.isEmpty) return false;

      _systemQueueActive = true;
      _systemStopRequested = false;
      _systemPaused = false;
      final token = ++_systemPlaybackToken;
      isSpeaking = true;
      _currentMessageId = messageId;
      _currentRouteLabel = AppStrings.ttsSystemEngine;
      notifyListeners();

      var anyChunkSucceeded = false;
      for (var i = 0; i < chunks.length; i += 1) {
        if (_systemStopRequested ||
            token != _systemPlaybackToken ||
            !_isPlaybackCurrent(playbackToken)) {
          break;
        }
        final chunkSucceeded = await _speakSystemChunk(
          chunks[i],
          index: i,
          total: chunks.length,
          token: token,
          playbackToken: playbackToken,
        );
        if (!_isRequestCurrent(playbackToken)) return false;
        if (chunkSucceeded) {
          anyChunkSucceeded = true;
        } else {
          debugPrint('TTS system chunk ${i + 1} rejected, skipping');
        }
      }

      if (Platform.isAndroid) {
        await _runMediaControl<void>(
          playbackToken,
          () async {
            await _tts.setQueueMode(0);
          },
        );
      }
      if (!_isRequestCurrent(playbackToken)) return false;
      if (token == _systemPlaybackToken) {
        _systemQueueActive = false;
        _systemPaused = false;
        _systemCurrentChunk = null;
        _systemChunkCompleter = null;
        _systemFailCount = 0;
        isSpeaking = false;
        if (_isPlaybackCurrent(playbackToken)) {
          _currentMessageId = null;
          _currentRouteLabel = null;
        }
        notifyListeners();
      }
      if (!anyChunkSucceeded && !_systemStopRequested) {
        lastError = '系统语音引擎无法朗读这段文本';
      }
      return true;
    } catch (_) {
      debugPrint('TTS system playback setup failed');
      if (!_isRequestCurrent(playbackToken)) return false;
      _systemQueueActive = false;
      _systemPaused = false;
      _systemCurrentChunk = null;
      _systemChunkCompleter = null;
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

  bool _isPlaybackCurrent(int token) => token == _playbackToken;

  bool _isRequestCurrent(int generation) =>
      generation == _requestGeneration ||
      (_systemQueueActive && generation == _playbackToken);

  Future<bool> _pauseSystemPlayback(int generation) async {
    if (!_systemQueueActive || _systemPaused) return false;
    _systemPaused = true;
    isSpeaking = false;
    notifyListeners();
    try {
      await _runMediaControl<void>(generation, () async {
        await _tts.pause();
      });
      if (!_isRequestCurrent(generation)) return false;
      return true;
    } catch (_) {
      debugPrint('TTS system pause failed');
      if (!_isRequestCurrent(generation)) return false;
      _systemPaused = false;
      isSpeaking = true;
      notifyListeners();
      return false;
    }
  }

  Future<bool> _resumeSystemPlayback(int generation) async {
    if (!_systemQueueActive || !_systemPaused) return false;
    final chunk = _systemCurrentChunk;
    if (chunk == null || chunk.isEmpty) return false;
    _systemPaused = false;
    isSpeaking = true;
    notifyListeners();
    try {
      final result = await _runMediaControl<dynamic>(generation, () async {
        if (Platform.isAndroid) {
          await _tts.setQueueMode(0);
        }
        return _tts.speak(chunk);
      });
      if (!_isRequestCurrent(generation)) return false;
      if (!_isTtsSuccess(result)) {
        _completeSystemChunk(false);
      }
      return _isTtsSuccess(result);
    } catch (_) {
      debugPrint('TTS system resume failed');
      if (!_isRequestCurrent(generation)) return false;
      _completeSystemChunk(false);
      return false;
    }
  }

  Future<bool> _speakSystemChunk(
    String chunk, {
    required int index,
    required int total,
    required int token,
    required int playbackToken,
  }) async {
    final completer = Completer<bool>();
    _systemChunkCompleter = completer;
    _systemCurrentChunk = chunk;
    try {
      final result = await _runMediaControl<dynamic>(playbackToken, () async {
        if (Platform.isAndroid) {
          await _tts.setQueueMode(0);
        }
        return _tts.speak(chunk);
      });
      if (!_isRequestCurrent(playbackToken) ||
          !_isPlaybackCurrent(playbackToken)) {
        return false;
      }
      if (!_isTtsSuccess(result)) {
        _completeSystemChunk(false);
      }
      return await _waitForSystemChunk(
        completer,
        timeout: _systemChunkTimeout(chunk),
        index: index,
        total: total,
        token: token,
        playbackToken: playbackToken,
      );
    } catch (_) {
      debugPrint('TTS system chunk ${index + 1}/$total failed');
      if (!_isRequestCurrent(playbackToken)) return false;
      _completeSystemChunk(false);
      return false;
    } finally {
      if (_systemChunkCompleter == completer) {
        _systemChunkCompleter = null;
      }
      if (_systemCurrentChunk == chunk && !_systemPaused) {
        _systemCurrentChunk = null;
      }
    }
  }

  Future<bool> _waitForSystemChunk(
    Completer<bool> completer, {
    required Duration timeout,
    required int index,
    required int total,
    required int token,
    required int playbackToken,
  }) async {
    var activeWait = Duration.zero;
    while (!completer.isCompleted) {
      final started = DateTime.now();
      await Future.any([
        completer.future,
        Future<void>.delayed(const Duration(milliseconds: 250)),
      ]);
      if (completer.isCompleted) break;
      if (!_isRequestCurrent(playbackToken) ||
          !_isPlaybackCurrent(playbackToken)) {
        return false;
      }
      if (_systemStopRequested || token != _systemPlaybackToken) return false;
      if (!_systemPaused) {
        activeWait += DateTime.now().difference(started);
      }
      if (activeWait >= timeout) {
        debugPrint('TTS system chunk ${index + 1}/$total timed out');
        return false;
      }
    }
    return completer.future;
  }

  Duration _systemChunkTimeout(String chunk) {
    final seconds = (chunk.length / 5).ceil().clamp(8, 75).toInt();
    return Duration(seconds: seconds);
  }

  void _completeSystemChunk(bool success) {
    final completer = _systemChunkCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(success);
    }
  }

  Future<int> _systemChunkLimit() async {
    if (!Platform.isAndroid) return _defaultSystemChunkLimit;
    try {
      final maxLength = await _tts.getMaxSpeechInputLength;
      if (maxLength == null || maxLength <= 0) return _defaultSystemChunkLimit;
      final safeLength = maxLength - 100;
      return safeLength.clamp(120, _defaultSystemChunkLimit).toInt();
    } catch (_) {
      return _defaultSystemChunkLimit;
    }
  }

  void _handleSystemTtsError(dynamic _) {
    debugPrint('TTS system engine error');
    if (_systemQueueActive) {
      _completeSystemChunk(false);
      notifyListeners();
      return;
    }
    if (_currentRouteLabel == AppStrings.ttsSystemEngine) {
      isSpeaking = false;
      _currentMessageId = null;
      _currentRouteLabel = null;
      lastError = '系统语音引擎朗读失败';
      notifyListeners();
      return;
    }

    _systemQueueActive = false;
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
      isSpeaking = true;
      _currentRouteLabel = AppStrings.ttsApiEngine(ttsModel);
      notifyListeners();
      final playbackToken = _playbackToken;
      _speakViaApi(text, ttsModel, prefs, playbackToken).then((ok) {
        if (!ok &&
            _isPlaybackCurrent(playbackToken) &&
            _isRequestCurrent(playbackToken)) {
          isSpeaking = false;
          _currentMessageId = null;
          _currentRouteLabel = null;
          lastError = '系统语音合成失败，API 也失败';
          notifyListeners();
        }
      });
    } else {
      isSpeaking = false;
      _currentMessageId = null;
      _currentRouteLabel = null;
      lastError = ttsModel == null || ttsModel.isEmpty
          ? '系统语音合成失败（可能缺少中文语音包），请在设置 → 语音能力 中填写 TTS 模型名称启用 API 兜底'
          : '语音合成出错';
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
    value = value.replaceAll(
      RegExp('[^0-9A-Za-z\u3400-\u4DBF\u4E00-\u9FFF，。！？；：、,.!?;:\\s-]'),
      ' ',
    );
    value = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return value;
  }

  @visibleForTesting
  List<String> splitTextForSystemSpeech(
    String text, {
    int maxLength = _defaultSystemChunkLimit,
  }) =>
      _splitTextForSystemSpeech(text, maxLength: maxLength);

  @visibleForTesting
  Future<bool> speakViaApiForTesting(
    String text,
    String model,
    PreferencesService prefs, {
    Directory? cacheDirectory,
  }) async {
    final generation = ++_requestGeneration;
    await _stopForGeneration(generation);
    if (!_isRequestCurrent(generation)) return false;
    _playbackToken = generation;
    isSpeaking = true;
    final result = await _speakViaApi(
      text,
      model,
      prefs,
      generation,
      cacheDirectory: cacheDirectory,
    );
    if (!result && _isRequestCurrent(generation)) isSpeaking = false;
    return result;
  }

  @visibleForTesting
  String? get activeApiAudioOperationIdForTesting => _activeApiAudio?.id;

  @visibleForTesting
  String? get activeApiAudioPathForTesting => _activeApiAudio?.file.path;

  @visibleForTesting
  Future<void> handleNativeAudioEventForTesting({
    required String operationId,
    required String event,
  }) {
    return _handleNativeAudioEvent({
      'operationId': operationId,
      'event': event,
    });
  }

  @visibleForTesting
  Future<void> resetApiAudioForTesting() async {
    final abort = _activeApiAbort;
    if (abort != null && !abort.isCompleted) abort.complete();
    _activeApiAbort = null;
    _requestGeneration += 1;
    _playbackToken = _requestGeneration;
    await _cleanupAllApiAudioOperations();
    _injectedClient = null;
    lastError = null;
    isLoading = false;
    isSpeaking = false;
  }

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
    String text,
    String model,
    PreferencesService prefs,
    int playbackToken, {
    Directory? cacheDirectory,
  }) async {
    if (!_isRequestCurrent(playbackToken) ||
        !_isPlaybackCurrent(playbackToken)) {
      return false;
    }
    final apiKey = prefs.apiKey;
    if (apiKey == null || apiKey.isEmpty) {
      if (_isRequestCurrent(playbackToken)) lastError = '未配置 API Key';
      return false;
    }

    final baseUrl = prefs.baseUrl ?? 'https://api.openai.com';
    final url = '$baseUrl/v1/audio/speech';

    isLoading = true;
    notifyListeners();

    final abort = Completer<void>();
    _activeApiAbort = abort;
    _TtsApiAudioOperation? audioOperation;
    var handedToNative = false;
    final timeout = Timer(const Duration(seconds: 90), () {
      if (!abort.isCompleted) abort.complete();
    });
    try {
      final uri =
          ApiValidator.validateBearerUrl(url, context: 'TTS API endpoint');

      final request = http.AbortableRequest(
        'POST',
        uri,
        abortTrigger: abort.future,
      )
        ..headers['Authorization'] = 'Bearer $apiKey'
        ..headers['Content-Type'] = 'application/json; charset=utf-8'
        ..headers['Accept'] = 'audio/mpeg'
        ..body = jsonEncode({
          'model': model,
          'input': text,
          'voice': 'alloy',
          'response_format': 'mp3',
        });
      // Long text + ElevenLabs can take 30-60s; allow up to 90s
      final response = await _httpClient.send(request);
      if (!_isRequestCurrent(playbackToken) ||
          !_isPlaybackCurrent(playbackToken)) {
        return false;
      }
      debugPrint('TTS API request status=${response.statusCode}');

      // Read response body as bytes
      final bytesBuilder = BytesBuilder(copy: false);
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 90),
      )) {
        bytesBuilder.add(chunk);
      }
      final body = bytesBuilder.toBytes();
      if (!_isRequestCurrent(playbackToken) ||
          !_isPlaybackCurrent(playbackToken)) {
        return false;
      }

      if (response.statusCode != 200) {
        lastError = '语音合成失败 (${response.statusCode})';
        return false;
      }
      if (body.isEmpty) {
        lastError = '语音合成失败: 服务器返回空响应';
        return false;
      }

      final dir = cacheDirectory ?? await getTemporaryDirectory();
      if (!_isRequestCurrent(playbackToken) ||
          !_isPlaybackCurrent(playbackToken)) {
        return false;
      }
      final operationId = 'api-$playbackToken-${++_apiAudioSequence}';
      final file = File('${dir.path}/tts_$operationId.mp3');
      audioOperation = _TtsApiAudioOperation(
        operationId,
        file,
        playbackToken,
      );
      await file.writeAsBytes(body);

      if (!_isRequestCurrent(playbackToken) ||
          !_isPlaybackCurrent(playbackToken)) {
        return false;
      }
      final obsoleteOperationIds =
          _apiAudioOperations.keys.toList(growable: false);
      for (final obsoleteOperationId in obsoleteOperationIds) {
        await _cleanupApiAudioOperation(obsoleteOperationId);
      }
      if (!_isRequestCurrent(playbackToken) ||
          !_isPlaybackCurrent(playbackToken)) {
        return false;
      }
      _apiAudioOperations[operationId] = audioOperation;
      _activeApiAudio = audioOperation;
      final started = await _runMediaControl<bool?>(
        playbackToken,
        () => _channel.invokeMethod<bool>('playAudio', {
          'path': file.path,
          'operationId': operationId,
        }),
      );
      if (started != true) {
        if (!_isRequestCurrent(playbackToken)) return false;
        throw StateError('Native audio playback was not started');
      }
      handedToNative = true;
      if (!_isRequestCurrent(playbackToken) ||
          !_isPlaybackCurrent(playbackToken)) {
        await _cleanupApiAudioOperation(operationId);
        return false;
      }
      isLoading = false;
      notifyListeners();
      return true;
    } catch (_) {
      debugPrint('TTS API request failed');
      if (_isRequestCurrent(playbackToken) &&
          _isPlaybackCurrent(playbackToken)) {
        lastError = '语音合成失败';
      }
      return false;
    } finally {
      timeout.cancel();
      if (!handedToNative && audioOperation != null) {
        await _cleanupApiAudioOperation(audioOperation.id);
        await _deleteApiAudioFile(audioOperation.file);
      }
      if (_isRequestCurrent(playbackToken) &&
          _isPlaybackCurrent(playbackToken)) {
        isLoading = false;
        notifyListeners();
      }
      if (identical(_activeApiAbort, abort)) _activeApiAbort = null;
    }
  }

  Future<void> _handleNativeAudioEvent(dynamic arguments) async {
    if (arguments is! Map) return;
    final operationId = arguments['operationId']?.toString();
    if (operationId == null || operationId.isEmpty) return;
    final event = arguments['event']?.toString();
    final operation = _apiAudioOperations[operationId];
    final wasActive = identical(_activeApiAudio, operation);
    await _cleanupApiAudioOperation(operationId);
    if (!wasActive ||
        operation == null ||
        !_isPlaybackCurrent(operation.generation) ||
        !_isRequestCurrent(operation.generation)) {
      return;
    }

    if (event == 'error') lastError = '语音播放失败';
    isSpeaking = false;
    _currentMessageId = null;
    _currentRouteLabel = null;
    notifyListeners();
  }

  Future<void> _cleanupApiAudioOperation(String operationId) async {
    final operation = _apiAudioOperations.remove(operationId);
    if (operation == null) return;
    if (identical(_activeApiAudio, operation)) _activeApiAudio = null;
    await _deleteApiAudioFile(operation.file);
  }

  Future<void> _cleanupAllApiAudioOperations() async {
    final operations = _apiAudioOperations.values.toList(growable: false);
    _apiAudioOperations.clear();
    _activeApiAudio = null;
    for (final operation in operations) {
      await _deleteApiAudioFile(operation.file);
    }
  }

  static Future<void> _deleteApiAudioFile(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Cache cleanup must not mask playback state transitions.
    }
  }

  Future<T?> _runMediaControl<T>(
    int generation,
    Future<T> Function() action,
  ) {
    final completer = Completer<T?>();
    final previous = _mediaControlTail;
    final scheduled = () async {
      try {
        await previous;
      } catch (_) {
        // A failed operation must not poison subsequent media controls.
      }
      if (!_isRequestCurrent(generation)) {
        completer.complete(null);
        return;
      }
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    }();
    _mediaControlTail = scheduled.catchError((_) {});
    return completer.future;
  }

  Future<void> stop() {
    final generation = ++_requestGeneration;
    return _stopForGeneration(generation);
  }

  Future<void> _stopForGeneration(int generation) async {
    if (!_isRequestCurrent(generation)) return;
    _playbackToken = generation;
    _systemPlaybackToken += 1;
    _systemStopRequested = true;
    _systemPaused = false;
    _completeSystemChunk(false);
    _systemQueueActive = false;
    _systemCurrentChunk = null;
    final abort = _activeApiAbort;
    if (abort != null && !abort.isCompleted) abort.complete();
    if (identical(_activeApiAbort, abort)) _activeApiAbort = null;
    final activeOperationId = _activeApiAudio?.id;
    final operationIds = _apiAudioOperations.keys.toList(growable: false);
    try {
      await _runMediaControl<void>(generation, () async {
        try {
          await _tts.stop();
          if (Platform.isAndroid) {
            await _tts.setQueueMode(0);
          }
        } catch (_) {
          // Continue to the operation-scoped native stop.
        }
        if (activeOperationId != null) {
          try {
            await _channel.invokeMethod('stopAudio', {
              'operationId': activeOperationId,
            });
          } catch (_) {
            // Dart still owns and removes the matching cache file below.
          }
        }
      });
    } finally {
      for (final operationId in operationIds) {
        await _cleanupApiAudioOperation(operationId);
      }
    }
    if (!_isRequestCurrent(generation)) return;
    isSpeaking = false;
    _currentMessageId = null;
    _currentRouteLabel = null;
    notifyListeners();
  }

  bool isPlayingMessage(String messageId) =>
      isSpeaking && _currentMessageId == messageId;
}

final class _TtsApiAudioOperation {
  const _TtsApiAudioOperation(this.id, this.file, this.generation);

  final String id;
  final File file;
  final int generation;
}
