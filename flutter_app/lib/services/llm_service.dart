import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import '../models/model_capabilities.dart';
import 'app_http.dart';
import 'api_validator.dart';
import 'llm_content_sanitizer.dart';
import 'model_capability_registry.dart';
import 'provider_message_transform.dart';
export '../models/model_capabilities.dart' show ApiFormat;

/// Test seam for driving request timeout time and lifecycle transitions.
///
/// Production uses [_SystemLlmTimeoutScheduler], whose clock is monotonic and
/// whose global binding observer publishes precise lifecycle transitions.
/// Tests can publish transitions at an exact fake-clock instant so foreground
/// budget accounting has no wall-clock sleeps or polling races.
@visibleForTesting
abstract interface class LlmTimeoutScheduler {
  DateTime now();

  Timer schedule(Duration duration, void Function() callback);

  Future<void> delay(Duration duration);

  void Function()? registerLifecycleListener(
    void Function(LlmLifecycleTransition transition) listener,
  );
}

@immutable
@visibleForTesting
final class LlmLifecycleTransition {
  const LlmLifecycleTransition({
    required this.isInBackground,
    required this.timestamp,
  });

  final bool isInBackground;
  final DateTime timestamp;
}

final class _LlmDeadline {
  const _LlmDeadline({
    required this.startedAt,
    required this.expiresAt,
    required this.maxDuration,
  });

  final DateTime startedAt;
  final DateTime expiresAt;
  final Duration maxDuration;

  Duration remaining(DateTime now) => expiresAt.difference(now);
}

/// Process-wide precise app lifecycle events in the timeout clock domain.
final class _LlmLifecycleBroadcaster with WidgetsBindingObserver {
  _LlmLifecycleBroadcaster()
      : _origin = DateTime.now(),
        _clock = Stopwatch()..start();

  static final instance = _LlmLifecycleBroadcaster();

  final DateTime _origin;
  final Stopwatch _clock;
  final Set<void Function(LlmLifecycleTransition)> _listeners = {};
  bool _observing = false;
  bool? _isInBackground;

  DateTime now() => _origin.add(_clock.elapsed);

  void Function()? addListener(
    void Function(LlmLifecycleTransition transition) listener,
  ) {
    if (!_observing) {
      late final WidgetsBinding binding;
      try {
        binding = WidgetsBinding.instance;
      } on FlutterError {
        // Pure Dart/VM tests may exercise LLM services without a Flutter
        // binding. They use the bounded sampled-lifecycle fallback instead.
        return null;
      }
      binding.addObserver(this);
      _observing = true;
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final isInBackground = state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached;
    if (_isInBackground == isInBackground) return;
    _isInBackground = isInBackground;
    final transition = LlmLifecycleTransition(
      isInBackground: isInBackground,
      timestamp: now(),
    );
    for (final listener in _listeners.toList(growable: false)) {
      listener(transition);
    }
  }
}

final class _SystemLlmTimeoutScheduler implements LlmTimeoutScheduler {
  _SystemLlmTimeoutScheduler();

  final _lifecycle = _LlmLifecycleBroadcaster.instance;

  @override
  DateTime now() => _lifecycle.now();

  @override
  Timer schedule(Duration duration, void Function() callback) {
    return Timer(duration, callback);
  }

  @override
  Future<void> delay(Duration duration) => Future<void>.delayed(duration);

  @override
  void Function()? registerLifecycleListener(
    void Function(LlmLifecycleTransition transition) listener,
  ) {
    return _lifecycle.addListener(listener);
  }
}

class EncryptedContentError implements Exception {
  final String message;
  final String? code;
  final int? statusCode;

  const EncryptedContentError(
    this.message, {
    this.code,
    this.statusCode,
  });

  @override
  String toString() => message;
}

class LlmConfig {
  final ApiFormat format;
  final String apiKey;
  final String model;
  final String baseUrl;
  final int maxTokens;
  final int thinkingBudget; // 0 = disabled
  final double? temperature;
  final CapabilityOverride? capabilityOverride;

  const LlmConfig({
    required this.format,
    required this.apiKey,
    required this.model,
    required this.baseUrl,
    this.maxTokens = 8192,
    this.thinkingBudget = 0,
    this.temperature,
    this.capabilityOverride,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LlmConfig &&
          format == other.format &&
          apiKey == other.apiKey &&
          model == other.model &&
          baseUrl == other.baseUrl &&
          maxTokens == other.maxTokens &&
          thinkingBudget == other.thinkingBudget &&
          temperature == other.temperature &&
          capabilityOverride == other.capabilityOverride;

  @override
  int get hashCode => Object.hash(
        format,
        apiKey,
        model,
        baseUrl,
        maxTokens,
        thinkingBudget,
        temperature,
        capabilityOverride,
      );

  factory LlmConfig.anthropic({
    required String apiKey,
    String model = 'claude-sonnet-4-20250514',
    String baseUrl = 'https://api.anthropic.com',
    int maxTokens = 8192,
    int thinkingBudget = 0,
    CapabilityOverride? capabilityOverride,
  }) {
    return LlmConfig(
      format: ApiFormat.anthropic,
      apiKey: apiKey,
      model: model,
      baseUrl: baseUrl,
      maxTokens: maxTokens,
      thinkingBudget: thinkingBudget,
      capabilityOverride: capabilityOverride,
    );
  }

  factory LlmConfig.openai({
    required String apiKey,
    required String model,
    String baseUrl = 'https://api.openai.com',
    int maxTokens = 8192,
    int thinkingBudget = 0,
    CapabilityOverride? capabilityOverride,
  }) {
    return LlmConfig(
      format: ApiFormat.openai,
      apiKey: apiKey,
      model: model,
      baseUrl: baseUrl,
      maxTokens: maxTokens,
      thinkingBudget: thinkingBudget,
      capabilityOverride: capabilityOverride,
    );
  }
}

class LlmUsage {
  final int? inputTokens;
  final int? outputTokens;
  final int? cacheReadInputTokens;
  final int? cacheCreationInputTokens;
  final bool inputTokensIncludeCache;

  const LlmUsage({
    this.inputTokens,
    this.outputTokens,
    this.cacheReadInputTokens,
    this.cacheCreationInputTokens,
    this.inputTokensIncludeCache = false,
  });

  bool get hasValues =>
      inputTokens != null ||
      outputTokens != null ||
      cacheReadInputTokens != null ||
      cacheCreationInputTokens != null;

  int? get totalInputTokens {
    final input = inputTokens;
    if (input == null) return null;
    if (inputTokensIncludeCache) return input;
    return input +
        (cacheReadInputTokens ?? 0) +
        (cacheCreationInputTokens ?? 0);
  }

  static LlmUsage? fromAnthropic(Map<String, dynamic>? usage) {
    if (usage == null) return null;
    final parsed = LlmUsage(
      inputTokens: _intValue(usage['input_tokens']),
      outputTokens: _intValue(usage['output_tokens']),
      cacheReadInputTokens: _intValue(usage['cache_read_input_tokens']),
      cacheCreationInputTokens: _intValue(usage['cache_creation_input_tokens']),
    );
    return parsed.hasValues ? parsed : null;
  }

  static LlmUsage? fromOpenAI(Map<String, dynamic>? usage) {
    if (usage == null) return null;
    final details = usage['prompt_tokens_details'];
    final detailsMap =
        details is Map ? Map<String, dynamic>.from(details) : null;
    final parsed = LlmUsage(
      inputTokens: _intValue(usage['prompt_tokens']),
      outputTokens: _intValue(usage['completion_tokens']),
      cacheReadInputTokens: _intValue(detailsMap?['cached_tokens']),
      inputTokensIncludeCache: true,
    );
    return parsed.hasValues ? parsed : null;
  }

  static int? _intValue(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    if (value is String) return int.tryParse(value);
    return null;
  }
}

class LlmResponse {
  final String stopReason;
  final List<ContentBlock> content;
  final LlmUsage? usage;

  int? get inputTokens => usage?.inputTokens;
  int? get outputTokens => usage?.outputTokens;

  const LlmResponse({
    required this.stopReason,
    required this.content,
    this.usage,
  });

  factory LlmResponse.withTokenCounts({
    required String stopReason,
    required List<ContentBlock> content,
    int? inputTokens,
    int? outputTokens,
  }) {
    final usage = LlmUsage(
      inputTokens: inputTokens,
      outputTokens: outputTokens,
    );
    return LlmResponse(
      stopReason: stopReason,
      content: content,
      usage: usage.hasValues ? usage : null,
    );
  }
}

class ContentBlock {
  final String type;
  final String? text;
  final String? reasoningContent;
  final String? toolUseId;
  final String? toolName;
  final Map<String, dynamic>? toolInput;
  final String? rawToolInputJson;

  const ContentBlock({
    required this.type,
    this.text,
    this.reasoningContent,
    this.toolUseId,
    this.toolName,
    this.toolInput,
    this.rawToolInputJson,
  });

  Map<String, dynamic> toJson() {
    if (type == 'text') {
      return {
        'type': 'text',
        'text': text,
        if (reasoningContent?.isNotEmpty == true)
          'reasoning_content': reasoningContent,
      };
    } else {
      return {
        'type': 'tool_use',
        'id': toolUseId,
        'name': toolName,
        'input': toolInput,
      };
    }
  }
}

class ToolDefinition {
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  const ToolDefinition({
    required this.name,
    required this.description,
    required this.inputSchema,
  });

  Map<String, dynamic> toAnthropicJson() => {
        'name': name,
        'description': description,
        'input_schema': inputSchema,
      };

  Map<String, dynamic> toOpenAIJson() => {
        'type': 'function',
        'function': {
          'name': name,
          'description': description,
          'parameters': inputSchema,
        },
      };
}

sealed class StreamEvent {
  const StreamEvent();
}

class TextDelta extends StreamEvent {
  final String text;
  TextDelta(this.text);
}

class ReasoningDelta extends StreamEvent {
  final String text;
  ReasoningDelta(this.text);
}

class ToolUseStart extends StreamEvent {
  final String id;
  final String name;
  ToolUseStart(this.id, this.name);
}

class ToolInputDelta extends StreamEvent {
  final String json;
  ToolInputDelta(this.json);
}

class StreamReset extends StreamEvent {
  const StreamReset();
}

class StreamDone extends StreamEvent {
  final LlmResponse response;
  StreamDone(this.response);
}

class StreamError extends StreamEvent {
  final String message;
  final Object? cause;
  StreamError(this.message, {this.cause});
}

sealed class _ResilientSseEvent {
  const _ResilientSseEvent();
}

class _ResilientSseData extends _ResilientSseEvent {
  final String data;
  const _ResilientSseData(this.data);
}

class _ResilientSseRetry extends _ResilientSseEvent {
  const _ResilientSseRetry();
}

class LlmService {
  final LlmConfig config;
  final AppHttpClient _client;
  final Completer<void> _abortTrigger = Completer<void>();
  final bool Function()? _isInBackground;
  final Duration _requestTimeoutDuration;
  final Duration _requestMaxWallClockDuration;
  final LlmTimeoutScheduler _timeoutScheduler;
  final CapabilityRegistry _capabilityRegistry;
  bool _disposed = false;

  static const _allowedApiHosts = {
    'api.anthropic.com',
    'api.openai.com',
    'generativelanguage.googleapis.com',
    'openrouter.ai',
    'api.deepseek.com',
    'integrate.api.nvidia.com',
    'api.x.ai',
  };

  static const presetModelSuffix = ' (preset)';
  static const streamUsageUnsupportedHostsPrefsKey =
      CapabilityRegistry.streamUsageUnsupportedHostsPrefsKey;
  static const _anthropicPresetModelIds = [
    'claude-sonnet-4-20250514',
    'claude-opus-4-20250514',
    'claude-haiku-4-20250514',
  ];

  LlmService(
    this.config, {
    bool Function()? isInBackground,
    CapabilityRegistry capabilityRegistry = CapabilityRegistry.instance,
    Duration? requestTimeout,
    Duration? requestMaxWallClock,
    AppHttpClient? httpClient,
    @visibleForTesting LlmTimeoutScheduler? timeoutScheduler,
  })  : _capabilityRegistry = capabilityRegistry,
        _isInBackground = isInBackground,
        _requestTimeoutDuration = requestTimeout ?? _requestTimeout,
        _requestMaxWallClockDuration =
            requestMaxWallClock ?? _requestMaxWallClockTimeout,
        _timeoutScheduler = timeoutScheduler ?? _SystemLlmTimeoutScheduler(),
        _client = httpClient ?? AppHttpClientRegistry.instance.client;

  /// Validates that [url] uses HTTPS and targets a known AI provider host.
  void _validateApiHost(String url) {
    final uri =
        ApiValidator.validateBearerUrl(url, context: 'LLM API endpoint');
    // Allow known providers and any user-configured custom baseUrl
    final configHost = Uri.tryParse(config.baseUrl)?.host ?? '';
    if (!_allowedApiHosts.contains(uri.host) && uri.host != configHost) {
      throw Exception(
          'Unknown API host: ${uri.host}. Only known AI provider endpoints are allowed.');
    }
  }

  /// Fetches available model IDs from the API provider.
  /// For Anthropic, calls GET /v1/models and falls back to preset labels.
  /// For OpenAI-compatible APIs, calls GET /v1/models and throws on errors.
  static Future<List<String>> fetchModels({
    required String apiFormat,
    required String apiKey,
    String? baseUrl,
    AppHttpClient? httpClient,
  }) async {
    final client = httpClient ?? AppHttpClientRegistry.instance.client;
    if (apiFormat == 'anthropic') {
      final effectiveBaseUrl = (baseUrl != null && baseUrl.isNotEmpty)
          ? baseUrl
          : 'https://api.anthropic.com';
      final url = _joinEndpointUrl(effectiveBaseUrl, '/v1/models');
      try {
        final uri =
            ApiValidator.validateBearerUrl(url, context: 'Models API endpoint');
        final response = await _sendResponseWithTimeout(
          client,
          method: 'GET',
          uri: uri,
          headers: {
            'x-api-key': apiKey,
            'anthropic-version': '2023-06-01',
          },
          timeout: const Duration(seconds: 10),
        );
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          final models = (data['data'] as List? ?? const [])
              .map((m) => m is Map ? m['id']?.toString() : null)
              .whereType<String>()
              .where((id) => id.isNotEmpty)
              .toList()
            ..sort();
          if (models.isNotEmpty) return models;
        }
        return _anthropicPresetModels();
      } catch (_) {
        return _anthropicPresetModels();
      }
    }

    final effectiveBaseUrl = (baseUrl != null && baseUrl.isNotEmpty)
        ? baseUrl
        : 'https://api.openai.com';
    final url = _joinEndpointUrl(effectiveBaseUrl, '/v1/models');
    try {
      final uri =
          ApiValidator.validateBearerUrl(url, context: 'Models API endpoint');
      final response = await _sendResponseWithTimeout(
        client,
        method: 'GET',
        uri: uri,
        headers: {'Authorization': 'Bearer $apiKey'},
        timeout: const Duration(seconds: 10),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final models = (data['data'] as List? ?? const [])
            .map((m) => m is Map ? m['id']?.toString() : null)
            .whereType<String>()
            .where((id) =>
                id.isNotEmpty &&
                !id.contains('embed') &&
                !id.contains('tts') &&
                !id.contains('dall-e') &&
                !id.contains('whisper') &&
                !id.contains('moderation'))
            .toList()
          ..sort();
        return models;
      }
      throw Exception(
        'Models API error (${response.statusCode}): ${_sanitizeErrorBody(response.body)}',
      );
    } catch (e) {
      throw Exception('Failed to fetch models: $e');
    }
  }

  static bool isPresetModel(String model) => model.endsWith(presetModelSuffix);

  static String modelIdFromDisplay(String model) {
    return CapabilityRegistry.modelIdFromDisplay(model);
  }

  static List<String> _anthropicPresetModels() {
    return _anthropicPresetModelIds
        .map((id) => '$id$presetModelSuffix')
        .toList();
  }

  static void clearStreamUsageUnsupportedHostsForTesting() {
    CapabilityRegistry.instance.clearStreamUsageUnsupportedHostsForTesting();
  }

  static String _joinBaseUrl(String baseUrl, String path) {
    return '${baseUrl.replaceFirst(RegExp(r'/+$'), '')}$path';
  }

  static String _joinEndpointUrl(String baseUrl, String endpointPath) {
    final trimmedBase = baseUrl.trim();
    final endpoint =
        endpointPath.startsWith('/') ? endpointPath : '/$endpointPath';
    final uri = Uri.tryParse(trimmedBase.replaceFirst(RegExp(r'/+$'), ''));
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return _joinBaseUrl(trimmedBase, endpoint);
    }

    final basePath = uri.path.replaceFirst(RegExp(r'/+$'), '');
    const knownEndpoints = [
      '/v1/messages',
      '/v1/chat/completions',
      '/v1/models',
    ];

    for (final knownEndpoint in knownEndpoints) {
      if (basePath == knownEndpoint || basePath.endsWith(knownEndpoint)) {
        final prefix =
            basePath.substring(0, basePath.length - knownEndpoint.length);
        return uri
            .replace(path: '$prefix$endpoint', query: null, fragment: null)
            .toString();
      }
    }

    if (basePath == '/v1' || basePath.endsWith('/v1')) {
      final endpointTail = endpoint.startsWith('/v1/')
          ? endpoint.substring('/v1'.length)
          : endpoint;
      return uri
          .replace(path: '$basePath$endpointTail', query: null, fragment: null)
          .toString();
    }

    return _joinBaseUrl(trimmedBase, endpoint);
  }

  static Future<http.Response> _sendResponse(
    AppHttpClient client,
    http.BaseRequest request,
  ) async {
    return http.Response.fromStream(await client.send(request));
  }

  static Future<http.Response> _sendResponseWithTimeout(
    AppHttpClient client, {
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    required Duration timeout,
  }) async {
    final abort = Completer<void>();
    final timer = Timer(timeout, () {
      if (!abort.isCompleted) abort.complete();
    });
    final request = http.AbortableRequest(
      method,
      uri,
      abortTrigger: abort.future,
    )..headers.addAll(headers);
    try {
      return await _sendResponse(client, request);
    } on http.RequestAbortedException {
      throw TimeoutException('Request timed out', timeout);
    } finally {
      timer.cancel();
    }
  }

  http.AbortableRequest _abortableRequest(
    String method,
    Uri uri, {
    required Map<String, String> headers,
    required Future<void> attemptAbortTrigger,
    required _LlmDeadline deadline,
    String? body,
  }) {
    _ensureDeadlineRemaining(deadline);
    final request = http.AbortableRequest(
      method,
      uri,
      abortTrigger: Future.any<void>([
        _abortTrigger.future,
        attemptAbortTrigger,
      ]),
    );
    request.headers.addAll(headers);
    if (body != null) request.body = body;
    return request;
  }

  Future<http.Response> _postJson(
    Uri uri, {
    required Map<String, String> headers,
    required String body,
    required Future<void> attemptAbortTrigger,
    required _LlmDeadline deadline,
  }) {
    return _sendResponse(
      _client,
      _abortableRequest(
        'POST',
        uri,
        headers: headers,
        body: body,
        attemptAbortTrigger: attemptAbortTrigger,
        deadline: deadline,
      ),
    );
  }

  /// Retires this service without closing the app-owned shared transport.
  /// Active stream subscriptions remain independently cancellable by callers.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (!_abortTrigger.isCompleted) {
      _abortTrigger.complete();
    }
  }

  ResolvedModelProfile get resolvedModelProfile => _capabilityRegistry.resolve(
        apiFormat: config.format,
        baseUrl: config.baseUrl,
        model: config.model,
        override: config.capabilityOverride,
      );

  bool get supportsImagesForTransform =>
      resolvedModelProfile.capabilities.supportsImages;

  bool get supportsReasoningContentForTransform =>
      resolvedModelProfile.capabilities.supportsReasoningContent;

  /// Sanitize error response bodies to prevent leaking sensitive data
  /// (e.g. API keys) in exception messages.
  static String _sanitizeErrorBody(String body) {
    String sanitized =
        body.length > 500 ? '${body.substring(0, 500)}...' : body;
    // Remove potential API key patterns (sk-..., key-..., api-..., etc.)
    sanitized = sanitized.replaceAll(
      RegExp(r'(sk-|key-|api-)[a-zA-Z0-9_-]{10,}'),
      '[REDACTED]',
    );
    return const LlmContentSanitizer().sanitizeText(sanitized).text;
  }

  static Exception _anthropicApiException(int statusCode, String body) {
    final sanitizedBody = _sanitizeErrorBody(body);
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is Map) {
          final code = error['code']?.toString();
          final message = error['message']?.toString() ?? sanitizedBody;
          if (code == 'invalid_encrypted_content') {
            return EncryptedContentError(
              'Anthropic API error ($statusCode): ${_sanitizeErrorBody(message)}',
              code: code,
              statusCode: statusCode,
            );
          }
        }
      }
    } catch (_) {
      // Fall through to the generic sanitized error.
    }
    if (sanitizedBody.contains('invalid_encrypted_content')) {
      return EncryptedContentError(
        'Anthropic API error ($statusCode): $sanitizedBody',
        code: 'invalid_encrypted_content',
        statusCode: statusCode,
      );
    }
    return Exception('Anthropic API error ($statusCode): $sanitizedBody');
  }

  static const Duration _requestTimeout = Duration(seconds: 120);
  static const Duration _requestMaxWallClockTimeout = Duration(minutes: 30);
  static const Duration _streamChunkTimeout = Duration(seconds: 60);
  static const Duration _streamReconnectBaseDelay = Duration(seconds: 2);
  static const Duration _foregroundTimeoutPollInterval = Duration(seconds: 1);
  static const Duration _sampledLifecyclePollInterval =
      Duration(milliseconds: 100);
  static const String _requestMaxWallClockTimeoutMessage =
      'Request exceeded maximum wall-clock timeout';
  static const int _maxRetries = 3;
  static const int _maxStreamReconnects = 2;
  static const Map<String, String> _keepAliveHeaders = {
    'Connection': 'keep-alive',
    'Keep-Alive': 'timeout=120',
  };

  /// Runs [fn] with exponential backoff retry on 429 and 5xx errors.
  Future<T> _retryWithBackoff<T>(
    Future<T> Function(
      Future<void> attemptAbortTrigger,
      _LlmDeadline deadline,
    ) fn, {
    _LlmDeadline? deadline,
  }) async {
    final logicalDeadline = deadline ?? _newDeadline();
    for (int attempt = 0; attempt <= _maxRetries; attempt++) {
      final attemptAbort = Completer<void>();
      late final Future<T> attemptWork;
      _ensureDeadlineRemaining(logicalDeadline);
      try {
        attemptWork =
            Future<T>.sync(() => fn(attemptAbort.future, logicalDeadline));
        return await _withForegroundTimeout(
          attemptWork,
          deadline: logicalDeadline,
          abortOnTimeout: () {
            if (!attemptAbort.isCompleted) attemptAbort.complete();
          },
        );
      } on TimeoutException catch (e) {
        if (_isRequestMaxWallClockTimeout(e)) rethrow;
        if (attempt == _maxRetries) rethrow;
      } catch (e) {
        if (e is http.RequestAbortedException) rethrow;
        final isRetryable = e is http.ClientException ||
            (e is Exception && _isRetryableHttpError(e.toString()));
        if (!isRetryable || attempt == _maxRetries) rethrow;
      }
      await _retireAttemptBeforeRetry(attemptAbort, attemptWork);
      final delay = Duration(seconds: (1 << attempt) * 2);
      final wallRemaining = _remainingRequestWallClock(logicalDeadline);
      if (wallRemaining <= Duration.zero) {
        throw _requestMaxWallClockTimeoutException(
          logicalDeadline.maxDuration,
        );
      }
      if (_disposed) throw http.RequestAbortedException();
      await _timeoutScheduler.delay(
        delay <= wallRemaining ? delay : wallRemaining,
      );
      if (_disposed) throw http.RequestAbortedException();
    }
    throw StateError('unreachable');
  }

  Future<void> _retireAttemptBeforeRetry<T>(
    Completer<void> attemptAbort,
    Future<T> attemptWork,
  ) async {
    if (!attemptAbort.isCompleted) attemptAbort.complete();
    await attemptAbort.future;
    try {
      await attemptWork;
    } catch (_) {
      // The retry classifier already handled this attempt's terminal error.
    }
  }

  @visibleForTesting
  Future<T> retryWithBackoffForTesting<T>(
    Future<T> Function(Future<void> attemptAbortTrigger) operation,
  ) {
    return _retryWithBackoff(
      (attemptAbortTrigger, _) => operation(attemptAbortTrigger),
    );
  }

  static bool _isRequestMaxWallClockTimeout(TimeoutException error) {
    return error.message?.contains(_requestMaxWallClockTimeoutMessage) ?? false;
  }

  static TimeoutException _requestMaxWallClockTimeoutException(
    Duration duration,
  ) {
    return TimeoutException(
      '$_requestMaxWallClockTimeoutMessage: $duration',
      duration,
    );
  }

  _LlmDeadline _newDeadline() {
    final startedAt = _timeoutScheduler.now();
    return _LlmDeadline(
      startedAt: startedAt,
      expiresAt: startedAt.add(_requestMaxWallClockDuration),
      maxDuration: _requestMaxWallClockDuration,
    );
  }

  Duration _remainingRequestWallClock(_LlmDeadline deadline) {
    return deadline.remaining(_timeoutScheduler.now());
  }

  void _ensureDeadlineRemaining(_LlmDeadline deadline) {
    if (_remainingRequestWallClock(deadline) <= Duration.zero) {
      throw _requestMaxWallClockTimeoutException(deadline.maxDuration);
    }
  }

  Future<T> _withForegroundTimeout<T>(
    Future<T> future, {
    required _LlmDeadline deadline,
    required void Function() abortOnTimeout,
  }) {
    final isInBackground = _isInBackground ?? () => false;

    final completer = Completer<T>();
    Timer? timer;
    void Function()? unregisterLifecycleListener;
    var settled = false;
    TimeoutException? pendingTimeout;
    var lastCheck = _timeoutScheduler.now();
    var foregroundElapsed = Duration.zero;
    var wasInBackground = isInBackground();

    void cancelTimer() {
      timer?.cancel();
      timer = null;
    }

    void cancelLifecycleListener() {
      unregisterLifecycleListener?.call();
      unregisterLifecycleListener = null;
    }

    void completeValue(T value) {
      if (settled) return;
      settled = true;
      cancelTimer();
      cancelLifecycleListener();
      final timeout = pendingTimeout;
      if (timeout != null) {
        completer.completeError(timeout, StackTrace.current);
      } else {
        completer.complete(value);
      }
    }

    void completeError(Object error, StackTrace stackTrace) {
      if (settled) return;
      settled = true;
      cancelTimer();
      cancelLifecycleListener();
      final timeout = pendingTimeout;
      if (timeout != null) {
        completer.completeError(timeout, StackTrace.current);
      } else {
        completer.completeError(error, stackTrace);
      }
    }

    Duration minDuration(Duration a, Duration b) => a <= b ? a : b;
    final timeoutMicros = _requestTimeoutDuration.inMicroseconds;
    var pollInterval = minDuration(
      _foregroundTimeoutPollInterval,
      Duration(
        microseconds: timeoutMicros <= 4 ? 1 : (timeoutMicros + 3) ~/ 4,
      ),
    );

    void beginTimeout(String message, Duration duration) {
      if (settled || pendingTimeout != null) return;
      pendingTimeout = TimeoutException(message, duration);
      cancelTimer();
      cancelLifecycleListener();
      abortOnTimeout();
    }

    Duration remainingWallClock(DateTime now) {
      return deadline.remaining(now);
    }

    Duration nextDelay(Duration preferred, DateTime now) {
      final wallRemaining = remainingWallClock(now);
      if (wallRemaining <= Duration.zero) return Duration.zero;
      return minDuration(preferred, wallRemaining);
    }

    late void Function({
      DateTime? transitionTimestamp,
      bool? transitionBackgroundState,
    }) checkTimeout;

    void scheduleTimeout([Duration? delay]) {
      cancelTimer();
      if (settled || pendingTimeout != null) return;
      timer = _timeoutScheduler.schedule(delay ?? _requestTimeoutDuration, () {
        checkTimeout();
      });
    }

    void scheduleNextCheck(DateTime now) {
      final foregroundRemaining = _requestTimeoutDuration - foregroundElapsed;
      final preferred = wasInBackground
          ? pollInterval
          : minDuration(foregroundRemaining, pollInterval);
      scheduleTimeout(nextDelay(preferred, now));
    }

    checkTimeout = ({
      DateTime? transitionTimestamp,
      bool? transitionBackgroundState,
    }) {
      if (settled || pendingTimeout != null) return;
      final sampledNow = _timeoutScheduler.now();
      final now =
          transitionTimestamp == null || transitionTimestamp.isAfter(sampledNow)
              ? sampledNow
              : transitionTimestamp;
      final wallRemaining = remainingWallClock(now);
      if (wallRemaining <= Duration.zero) {
        beginTimeout(
          '$_requestMaxWallClockTimeoutMessage: '
          '${deadline.maxDuration}',
          deadline.maxDuration,
        );
        return;
      }
      final currentlyInBackground =
          transitionBackgroundState ?? isInBackground();
      final elapsedSinceLastCheck =
          now.isBefore(lastCheck) ? Duration.zero : now.difference(lastCheck);

      // Charge elapsed time according to the previously observed state. With
      // precise lifecycle events the timestamp is exact. With sampled fallback
      // a foreground -> background interval is conservatively charged in full,
      // bounding error without allowing repeated toggles to refresh budget.
      if (!wasInBackground) {
        foregroundElapsed += elapsedSinceLastCheck;
      }

      lastCheck = now;
      wasInBackground = currentlyInBackground;
      final remaining = _requestTimeoutDuration - foregroundElapsed;
      if (remaining <= Duration.zero) {
        beginTimeout(
          'No response received within $_requestTimeoutDuration',
          _requestTimeoutDuration,
        );
        return;
      }
      scheduleNextCheck(now);
    };

    if (_isInBackground != null) {
      unregisterLifecycleListener =
          _timeoutScheduler.registerLifecycleListener((transition) {
        checkTimeout(
          transitionTimestamp: transition.timestamp,
          transitionBackgroundState: transition.isInBackground,
        );
      });
      if (unregisterLifecycleListener == null) {
        pollInterval = minDuration(
          pollInterval,
          _sampledLifecyclePollInterval,
        );
      }
    }
    scheduleNextCheck(_timeoutScheduler.now());
    future.then(completeValue, onError: completeError);
    return completer.future;
  }

  @visibleForTesting
  Future<T> withForegroundTimeoutForTesting<T>(
    Future<T> Function(Future<void> abortTrigger) operation,
  ) {
    final abort = Completer<void>();
    final deadline = _newDeadline();
    return _withForegroundTimeout(
      Future<T>.sync(() => operation(abort.future)),
      deadline: deadline,
      abortOnTimeout: () {
        if (!abort.isCompleted) abort.complete();
      },
    );
  }

  static bool _isRetryableHttpError(String msg) {
    // Match 429 (rate limit) and 5xx status codes in error messages
    final pattern = RegExp(r'\((429|5\d{2})\)');
    return pattern.hasMatch(msg);
  }

  bool _isRetryableStreamError(Object error) {
    if (error is http.RequestAbortedException) return false;
    if (error is TimeoutException && _isRequestMaxWallClockTimeout(error)) {
      return false;
    }
    return error is http.ClientException ||
        error is TimeoutException ||
        error is SocketException ||
        error is HttpException ||
        error is IOException ||
        (error is Exception && _isRetryableHttpError(error.toString()));
  }

  Future<void> _delayBeforeStreamReconnect(
    int completedAttempts,
    _LlmDeadline deadline,
  ) async {
    final multiplier = 1 << completedAttempts;
    final delay = _streamReconnectBaseDelay * multiplier;
    final wallRemaining = _remainingRequestWallClock(deadline);
    if (wallRemaining <= Duration.zero) {
      throw _requestMaxWallClockTimeoutException(deadline.maxDuration);
    }
    await _timeoutScheduler.delay(
      delay <= wallRemaining ? delay : wallRemaining,
    );
    if (_remainingRequestWallClock(deadline) <= Duration.zero) {
      throw _requestMaxWallClockTimeoutException(deadline.maxDuration);
    }
  }

  Stream<String> _linesWithForegroundTimeout(
    Stream<List<int>> byteStream, {
    required _LlmDeadline deadline,
    bool Function()? isInBackground,
  }) {
    late final StreamController<String> controller;
    StreamSubscription<String>? subscription;
    Timer? timeoutTimer;
    void Function()? unregisterLifecycleListener;
    var pendingLine = '';
    var lastCheck = _timeoutScheduler.now();
    var idleForegroundElapsed = Duration.zero;
    var wasInBackground = isInBackground?.call() ?? false;
    var closed = false;
    var controllerCancelled = false;
    var consumerPaused = false;

    void cancelTimeout() {
      timeoutTimer?.cancel();
      timeoutTimer = null;
    }

    void cancelLifecycleListener() {
      unregisterLifecycleListener?.call();
      unregisterLifecycleListener = null;
    }

    void cleanupTimeoutState() {
      cancelTimeout();
      cancelLifecycleListener();
    }

    void failWithError(Object error, StackTrace stackTrace) {
      if (closed) return;
      closed = true;
      cleanupTimeoutState();
      unawaited(() async {
        try {
          await subscription?.cancel();
        } finally {
          if (!controllerCancelled) {
            controller.addError(error, stackTrace);
            await controller.close();
          }
        }
      }());
    }

    Duration minDuration(Duration a, Duration b) => a <= b ? a : b;

    Duration wallRemaining(DateTime now) {
      return deadline.remaining(now);
    }

    late void Function({
      DateTime? transitionTimestamp,
      bool? transitionBackgroundState,
    }) checkTimeout;

    void scheduleTimeout(Duration delay) {
      cancelTimeout();
      if (closed) return;
      timeoutTimer = _timeoutScheduler.schedule(delay, () {
        checkTimeout();
      });
    }

    void scheduleNextCheck(DateTime now) {
      final remainingWall = wallRemaining(now);
      if (remainingWall <= Duration.zero) {
        scheduleTimeout(Duration.zero);
        return;
      }
      if (consumerPaused) {
        scheduleTimeout(remainingWall);
        return;
      }
      final lifecyclePollInterval =
          isInBackground != null && unregisterLifecycleListener == null
              ? _sampledLifecyclePollInterval
              : _foregroundTimeoutPollInterval;
      final preferred = wasInBackground
          ? lifecyclePollInterval
          : minDuration(
              _streamChunkTimeout - idleForegroundElapsed,
              lifecyclePollInterval,
            );
      scheduleTimeout(minDuration(preferred, remainingWall));
    }

    checkTimeout = ({
      DateTime? transitionTimestamp,
      bool? transitionBackgroundState,
    }) {
      if (closed) return;
      final sampledNow = _timeoutScheduler.now();
      if (wallRemaining(sampledNow) <= Duration.zero) {
        failWithError(
          _requestMaxWallClockTimeoutException(
            deadline.maxDuration,
          ),
          StackTrace.current,
        );
        return;
      }
      final now =
          transitionTimestamp == null || transitionTimestamp.isAfter(sampledNow)
              ? sampledNow
              : transitionTimestamp;
      final currentlyInBackground =
          transitionBackgroundState ?? isInBackground?.call() ?? false;
      final elapsedSinceLastCheck =
          now.isBefore(lastCheck) ? Duration.zero : now.difference(lastCheck);
      if (!consumerPaused && !wasInBackground) {
        idleForegroundElapsed += elapsedSinceLastCheck;
      }
      lastCheck = now;
      wasInBackground = currentlyInBackground;
      if (!consumerPaused && idleForegroundElapsed >= _streamChunkTimeout) {
        failWithError(
          TimeoutException(
            'No stream data received within $_streamChunkTimeout',
            _streamChunkTimeout,
          ),
          StackTrace.current,
        );
        return;
      }
      scheduleNextCheck(sampledNow);
    };

    void resetIdleBudget() {
      idleForegroundElapsed = Duration.zero;
      lastCheck = _timeoutScheduler.now();
      wasInBackground = isInBackground?.call() ?? false;
      scheduleNextCheck(lastCheck);
    }

    controller = StreamController<String>(
      onListen: () {
        if (isInBackground != null) {
          unregisterLifecycleListener =
              _timeoutScheduler.registerLifecycleListener((transition) {
            checkTimeout(
              transitionTimestamp: transition.timestamp,
              transitionBackgroundState: transition.isInBackground,
            );
          });
        }
        scheduleNextCheck(_timeoutScheduler.now());
        subscription = byteStream.transform(utf8.decoder).listen(
          (chunk) {
            if (closed) return;
            resetIdleBudget();
            pendingLine += chunk;
            while (true) {
              final newlineIndex = pendingLine.indexOf('\n');
              if (newlineIndex < 0) break;
              var line = pendingLine.substring(0, newlineIndex);
              if (line.endsWith('\r')) {
                line = line.substring(0, line.length - 1);
              }
              controller.add(line);
              pendingLine = pendingLine.substring(newlineIndex + 1);
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            failWithError(error, stackTrace);
          },
          onDone: () {
            if (closed) return;
            if (pendingLine.isNotEmpty) {
              controller.add(
                pendingLine.endsWith('\r')
                    ? pendingLine.substring(0, pendingLine.length - 1)
                    : pendingLine,
              );
              pendingLine = '';
            }
            closed = true;
            cleanupTimeoutState();
            unawaited(controller.close());
          },
        );
      },
      onPause: () {
        if (closed) return;
        consumerPaused = true;
        lastCheck = _timeoutScheduler.now();
        scheduleNextCheck(lastCheck);
        subscription?.pause();
      },
      onResume: () {
        if (closed) return;
        consumerPaused = false;
        resetIdleBudget();
        subscription?.resume();
      },
      onCancel: () async {
        controllerCancelled = true;
        closed = true;
        cleanupTimeoutState();
        await subscription?.cancel();
      },
    );

    return controller.stream;
  }

  @visibleForTesting
  Stream<String> linesWithForegroundTimeoutForTesting(
    Stream<List<int>> byteStream,
  ) {
    return _linesWithForegroundTimeout(
      byteStream,
      deadline: _newDeadline(),
      isInBackground: _isInBackground,
    );
  }

  Stream<_ResilientSseEvent> _resilientSseDataStream({
    required Future<http.StreamedResponse> Function() openStream,
    required bool Function(String data) isDoneData,
    required _LlmDeadline deadline,
    bool Function()? isInBackground,
  }) async* {
    for (int attempt = 0; attempt <= _maxStreamReconnects; attempt++) {
      final sseDataLines = <String>[];
      try {
        _ensureDeadlineRemaining(deadline);
        final response = await openStream();
        await for (final line in _linesWithForegroundTimeout(
          response.stream,
          deadline: deadline,
          isInBackground: isInBackground,
        )) {
          if (line.startsWith('data:')) {
            final payload = line.length > 5 && line[5] == ' '
                ? line.substring(6)
                : line.substring(5);
            sseDataLines.add(payload);
            continue;
          }
          if (line.startsWith('event:') ||
              line.startsWith('id:') ||
              line.startsWith('retry:')) {
            continue;
          }
          if (line.trim().isEmpty && sseDataLines.isNotEmpty) {
            final data = sseDataLines.join('\n').trim();
            sseDataLines.clear();
            yield _ResilientSseData(data);
            if (isDoneData(data)) return;
          }
        }

        if (sseDataLines.isNotEmpty) {
          final data = sseDataLines.join('\n').trim();
          sseDataLines.clear();
          yield _ResilientSseData(data);
          if (isDoneData(data)) return;
        }
        return;
      } catch (e) {
        if (attempt >= _maxStreamReconnects || !_isRetryableStreamError(e)) {
          rethrow;
        }
        yield const _ResilientSseRetry();
        await _delayBeforeStreamReconnect(attempt, deadline);
      }
    }
  }

  @visibleForTesting
  Stream<String> resilientSseDataForTesting(
    Future<http.StreamedResponse> Function(
      Future<void> attemptAbortTrigger,
    ) openStream,
  ) async* {
    final deadline = _newDeadline();
    await for (final event in _resilientSseDataStream(
      openStream: () => _retryWithBackoff(
        (attemptAbortTrigger, _) => openStream(attemptAbortTrigger),
        deadline: deadline,
      ),
      isDoneData: (_) => false,
      deadline: deadline,
      isInBackground: _isInBackground,
    )) {
      if (event is _ResilientSseData) {
        yield event.data;
      } else if (event is _ResilientSseRetry) {
        yield '__retry__';
      }
    }
  }

  Future<LlmResponse> chat({
    required String system,
    required List<Map<String, dynamic>> messages,
    required List<ToolDefinition> tools,
  }) async {
    _ensureNotDisposed();
    switch (config.format) {
      case ApiFormat.anthropic:
        return _anthropicChat(system, messages, tools);
      case ApiFormat.openai:
        return _openaiChat(system, messages, tools);
    }
  }

  Stream<StreamEvent> chatStream({
    required String system,
    required List<Map<String, dynamic>> messages,
    required List<ToolDefinition> tools,
  }) {
    _ensureNotDisposed();
    switch (config.format) {
      case ApiFormat.anthropic:
        return _anthropicStream(system, messages, tools);
      case ApiFormat.openai:
        return _openaiStream(system, messages, tools);
    }
  }

  // ── Anthropic ──────────────────────────────────────────────────

  Future<LlmResponse> _anthropicChat(
    String system,
    List<Map<String, dynamic>> messages,
    List<ToolDefinition> tools,
  ) async {
    final url = _joinEndpointUrl(config.baseUrl, '/v1/messages');
    _validateApiHost(url);
    return _retryWithBackoff((attemptAbortTrigger, deadline) async {
      final body = _buildAnthropicBody(system, messages, tools, stream: false);
      final response = await _postJson(
        Uri.parse(url),
        headers: _anthropicHeaders(),
        body: jsonEncode(body),
        attemptAbortTrigger: attemptAbortTrigger,
        deadline: deadline,
      );
      if (response.statusCode != 200) {
        throw _anthropicApiException(response.statusCode, response.body);
      }
      return _parseAnthropicResponse(jsonDecode(response.body));
    });
  }

  Stream<StreamEvent> _anthropicStream(
    String system,
    List<Map<String, dynamic>> messages,
    List<ToolDefinition> tools,
  ) async* {
    final url = _joinEndpointUrl(config.baseUrl, '/v1/messages');
    _validateApiHost(url);
    final deadline = _newDeadline();
    final body = _buildAnthropicBody(system, messages, tools, stream: true);

    Future<http.StreamedResponse> openStream() {
      return _retryWithBackoff((attemptAbortTrigger, attemptDeadline) async {
        final request = _abortableRequest(
          'POST',
          Uri.parse(url),
          headers: _anthropicHeaders(),
          body: jsonEncode(body),
          attemptAbortTrigger: attemptAbortTrigger,
          deadline: attemptDeadline,
        );
        final response = await _client.send(request);
        if (response.statusCode != 200) {
          final errorBody = await response.stream.bytesToString();
          throw _anthropicApiException(response.statusCode, errorBody);
        }
        return response;
      }, deadline: deadline);
    }

    final List<ContentBlock> collectedBlocks = [];
    String currentText = '';
    StringBuffer currentReasoningContent = StringBuffer();
    String currentToolId = '';
    String currentToolName = '';
    StringBuffer currentToolInput = StringBuffer();
    String stopReason = 'end_turn';
    bool receivedMessageStop = false;
    bool isThinkingBlock = false;
    int? inputTokens;
    int? outputTokens;
    int? cacheReadInputTokens;
    int? cacheCreationInputTokens;
    bool streamFailed = false;
    bool activeContentBlock = false;

    void resetAnthropicStreamState() {
      collectedBlocks.clear();
      currentText = '';
      currentReasoningContent = StringBuffer();
      currentToolId = '';
      currentToolName = '';
      currentToolInput = StringBuffer();
      stopReason = 'end_turn';
      receivedMessageStop = false;
      isThinkingBlock = false;
      inputTokens = null;
      outputTokens = null;
      cacheReadInputTokens = null;
      cacheCreationInputTokens = null;
      streamFailed = false;
      activeContentBlock = false;
    }

    String? finishCurrentAnthropicBlock() {
      if (isThinkingBlock) {
        isThinkingBlock = false;
        return null;
      }
      if (currentToolName.isNotEmpty && currentToolId.isNotEmpty) {
        Map<String, dynamic> input = {};
        try {
          final inputStr = currentToolInput.toString();
          if (inputStr.isNotEmpty) input = jsonDecode(inputStr);
        } catch (_) {
          return 'Anthropic stream interrupted: incomplete tool call JSON';
        }
        final rawToolInputJson = currentToolInput.toString();
        collectedBlocks.add(ContentBlock(
          type: 'tool_use',
          toolUseId: currentToolId,
          toolName: currentToolName,
          toolInput: input,
          rawToolInputJson: rawToolInputJson.isEmpty ? null : rawToolInputJson,
        ));
        currentToolId = '';
        currentToolName = '';
        currentToolInput = StringBuffer();
      } else if (currentText.isNotEmpty) {
        final reasoningText = currentReasoningContent.toString();
        collectedBlocks.add(ContentBlock(
          type: 'text',
          text: currentText,
          reasoningContent: reasoningText.isEmpty ? null : reasoningText,
        ));
        currentReasoningContent = StringBuffer();
        currentText = '';
      }
      return null;
    }

    Iterable<StreamEvent> parseAnthropicSseData(String data) sync* {
      final frame = data.trim();
      if (frame.isEmpty || frame == '[DONE]') {
        return;
      }

      late final Map<String, dynamic> event;
      try {
        final decoded = jsonDecode(frame);
        if (decoded is! Map) {
          throw const FormatException('Expected JSON object');
        }
        event = Map<String, dynamic>.from(decoded);
      } catch (_) {
        streamFailed = true;
        yield StreamError(
          'Anthropic stream interrupted: malformed SSE JSON frame',
        );
        return;
      }

      try {
        final type = event['type'] as String?;

        switch (type) {
          case 'message_start':
            final message = event['message'] as Map<String, dynamic>?;
            if (message != null) {
              final usage = message['usage'] as Map<String, dynamic>?;
              if (usage != null) {
                final parsedUsage = LlmUsage.fromAnthropic(usage);
                inputTokens = parsedUsage?.inputTokens ?? inputTokens;
                cacheReadInputTokens =
                    parsedUsage?.cacheReadInputTokens ?? cacheReadInputTokens;
                cacheCreationInputTokens =
                    parsedUsage?.cacheCreationInputTokens ??
                        cacheCreationInputTokens;
              }
            }
            break;

          case 'content_block_start':
            final block = event['content_block'] as Map<String, dynamic>;
            if (activeContentBlock) {
              streamFailed = true;
              yield StreamError(
                'Anthropic stream interrupted: content block was incomplete',
              );
              return;
            }
            activeContentBlock = true;
            if (block['type'] == 'thinking') {
              isThinkingBlock = true;
            } else if (block['type'] == 'tool_use') {
              isThinkingBlock = false;
              final blockId = block['id'] as String?;
              final blockName = block['name'] as String?;
              if (blockId == null ||
                  blockId.isEmpty ||
                  blockName == null ||
                  blockName.isEmpty) {
                streamFailed = true;
                yield StreamError(
                  'Anthropic stream interrupted: incomplete tool call metadata',
                );
                return;
              }
              currentToolId = blockId;
              currentToolName = blockName;
              currentToolInput = StringBuffer();
              yield ToolUseStart(currentToolId, currentToolName);
            } else {
              isThinkingBlock = false;
            }
            break;

          case 'content_block_delta':
            final delta = event['delta'] as Map<String, dynamic>;
            if (isThinkingBlock) {
              if (delta['type'] == 'thinking_delta') {
                final thinking = delta['thinking'] as String? ?? '';
                if (thinking.isNotEmpty) {
                  currentReasoningContent.write(thinking);
                  yield ReasoningDelta(thinking);
                }
              }
              break;
            }
            if (delta['type'] == 'text_delta') {
              final text = delta['text'] as String;
              if (text.isNotEmpty) {
                currentText += text;
                yield TextDelta(text);
              }
            } else if (delta['type'] == 'input_json_delta') {
              final json = delta['partial_json'] as String;
              if (json.isNotEmpty) {
                currentToolInput.write(json);
                yield ToolInputDelta(json);
              }
            }
            break;

          case 'content_block_stop':
            if (!activeContentBlock) {
              streamFailed = true;
              yield StreamError(
                'Anthropic stream interrupted: content block stop was unexpected',
              );
              return;
            }
            activeContentBlock = false;
            final blockError = finishCurrentAnthropicBlock();
            if (blockError != null) {
              streamFailed = true;
              yield StreamError(blockError);
              return;
            }
            break;

          case 'message_delta':
            final delta = event['delta'] as Map<String, dynamic>;
            stopReason = delta['stop_reason'] as String? ?? 'end_turn';
            final usage = event['usage'] as Map<String, dynamic>?;
            if (usage != null) {
              final parsedUsage = LlmUsage.fromAnthropic(usage);
              outputTokens = parsedUsage?.outputTokens ?? outputTokens;
              cacheReadInputTokens =
                  parsedUsage?.cacheReadInputTokens ?? cacheReadInputTokens;
              cacheCreationInputTokens =
                  parsedUsage?.cacheCreationInputTokens ??
                      cacheCreationInputTokens;
            }
            break;

          case 'message_stop':
            if (activeContentBlock) {
              streamFailed = true;
              yield StreamError(
                'Anthropic stream interrupted: content block was incomplete',
              );
              return;
            }
            receivedMessageStop = true;
            break;

          case 'error':
            final error = event['error'] as Map<String, dynamic>;
            streamFailed = true;
            final code = error['code']?.toString();
            final message = _sanitizeErrorBody(
              error['message'] as String? ?? 'Unknown error',
            );
            if (code == 'invalid_encrypted_content') {
              final cause = EncryptedContentError(
                'Anthropic API error: invalid_encrypted_content: $message',
                code: code,
              );
              yield StreamError(cause.message, cause: cause);
            } else {
              yield StreamError(message);
            }
            return;
        }
      } catch (_) {
        streamFailed = true;
        yield StreamError(
          'Anthropic stream interrupted: malformed SSE JSON frame',
        );
      }
    }

    try {
      await for (final data in _resilientSseDataStream(
        openStream: openStream,
        isDoneData: (data) => data == '[DONE]',
        deadline: deadline,
        isInBackground: _isInBackground,
      )) {
        if (data is _ResilientSseRetry) {
          resetAnthropicStreamState();
          yield const StreamReset();
          continue;
        }
        if (data is! _ResilientSseData) {
          continue;
        }
        for (final event in parseAnthropicSseData(data.data)) {
          yield event;
        }
        if (streamFailed) return;
      }
    } catch (e) {
      if (e is EncryptedContentError) {
        yield StreamError(e.message, cause: e);
      } else {
        yield StreamError('Anthropic stream interrupted after retries: $e');
      }
      return;
    }

    if (activeContentBlock) {
      yield StreamError(
        'Anthropic stream interrupted: content block was incomplete',
      );
      return;
    }

    if (!receivedMessageStop) {
      yield StreamError(
        'Anthropic stream interrupted: ended without message_stop event',
      );
      return;
    }

    final trailingReasoning = currentReasoningContent.toString();
    if (trailingReasoning.isNotEmpty) {
      collectedBlocks.add(ContentBlock(
        type: 'text',
        text: '',
        reasoningContent: trailingReasoning,
      ));
    }

    final usage = LlmUsage(
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      cacheReadInputTokens: cacheReadInputTokens,
      cacheCreationInputTokens: cacheCreationInputTokens,
    );
    yield StreamDone(LlmResponse(
      stopReason: stopReason,
      content: collectedBlocks,
      usage: usage.hasValues ? usage : null,
    ));
  }

  Map<String, dynamic> _buildAnthropicBody(
    String system,
    List<Map<String, dynamic>> messages,
    List<ToolDefinition> tools, {
    required bool stream,
  }) {
    const transform = ProviderMessageTransform();
    final capabilities = resolvedModelProfile.capabilities;
    final safeSystem = _sanitizeForLlmPayload(system);
    final transformedMessages = transform.toProviderPayload(
      messages,
      ProviderTransformOptions(
        apiFormat: 'anthropic',
        modelId: modelIdFromDisplay(config.model),
        baseUrl: Uri.tryParse(config.baseUrl),
        capabilities: capabilities.copyWith(supportsReasoningContent: false),
      ),
    );
    final body = <String, dynamic>{
      'model': modelIdFromDisplay(config.model),
      'max_tokens': config.maxTokens,
      'system': safeSystem,
      'messages': transformedMessages,
      'stream': stream,
    };
    final thinkingEnabled = config.thinkingBudget > 0;
    if (config.temperature != null &&
        capabilities.acceptsTemperature &&
        !thinkingEnabled) {
      body['temperature'] = config.temperature;
    }
    if (capabilities.supportsTools && tools.isNotEmpty) {
      body['tools'] = tools.map((t) => t.toAnthropicJson()).toList();
    }
    if (thinkingEnabled) {
      body['thinking'] = {
        'type': 'enabled',
        'budget_tokens': config.thinkingBudget,
      };
      // Increase max_tokens to accommodate thinking + response
      body['max_tokens'] = config.thinkingBudget + config.maxTokens;
    }
    return body;
  }

  Map<String, String> _anthropicHeaders() {
    final headers = {
      'Content-Type': 'application/json',
      'x-api-key': config.apiKey,
      'anthropic-version': '2023-06-01',
      'Accept-Encoding': 'identity',
      ..._keepAliveHeaders,
    };
    if (config.thinkingBudget > 0) {
      headers['anthropic-version'] = '2025-04-15';
      headers['anthropic-beta'] = 'interleaved-thinking-2025-05-14';
    }
    return headers;
  }

  LlmResponse _parseAnthropicResponse(Map<String, dynamic> json) {
    final stopReason = json['stop_reason'] as String? ?? 'end_turn';
    final content = (json['content'] as List)
        .where((block) => block['type'] != 'thinking')
        .map<ContentBlock?>((block) {
          if (block['type'] == 'text') {
            return ContentBlock(type: 'text', text: block['text']);
          } else if (block['type'] == 'tool_use') {
            return ContentBlock(
              type: 'tool_use',
              toolUseId: block['id'],
              toolName: block['name'],
              toolInput: Map<String, dynamic>.from(block['input']),
            );
          }
          return null;
        })
        .whereType<ContentBlock>()
        .toList();
    final usage = LlmUsage.fromAnthropic(
      json['usage'] is Map ? Map<String, dynamic>.from(json['usage']) : null,
    );
    return LlmResponse(
      stopReason: stopReason,
      content: content,
      usage: usage,
    );
  }

  // ── OpenAI ─────────────────────────────────────────────────────

  Future<LlmResponse> _openaiChat(
    String system,
    List<Map<String, dynamic>> messages,
    List<ToolDefinition> tools,
  ) async {
    final url = _joinEndpointUrl(config.baseUrl, '/v1/chat/completions');
    _validateApiHost(url);
    return _retryWithBackoff((attemptAbortTrigger, deadline) async {
      final body = _buildOpenAIBody(system, messages, tools, stream: false);
      final response = await _postJson(
        Uri.parse(url),
        headers: _openaiHeaders(),
        body: jsonEncode(body),
        attemptAbortTrigger: attemptAbortTrigger,
        deadline: deadline,
      );
      if (response.statusCode == 400 &&
          (_tryTokenKeyFallback(response.body) ||
              _tryReasoningContentFallback(response.body))) {
        final retryBody =
            _buildOpenAIBody(system, messages, tools, stream: false);
        final retryResponse = await _postJson(
          Uri.parse(url),
          headers: _openaiHeaders(),
          body: jsonEncode(retryBody),
          attemptAbortTrigger: attemptAbortTrigger,
          deadline: deadline,
        );
        if (retryResponse.statusCode != 200) {
          throw Exception(
              'OpenAI API error (${retryResponse.statusCode}): ${_sanitizeErrorBody(retryResponse.body)}');
        }
        return _parseOpenAIResponse(jsonDecode(retryResponse.body));
      }
      if (response.statusCode != 200) {
        throw Exception(
            'OpenAI API error (${response.statusCode}): ${_sanitizeErrorBody(response.body)}');
      }
      return _parseOpenAIResponse(jsonDecode(response.body));
    });
  }

  Stream<StreamEvent> _openaiStream(
    String system,
    List<Map<String, dynamic>> messages,
    List<ToolDefinition> tools,
  ) async* {
    final url = _joinEndpointUrl(config.baseUrl, '/v1/chat/completions');
    _validateApiHost(url);
    final deadline = _newDeadline();
    var includeUsage = await _capabilityRegistry
        .supportsOpenAIStreamUsage(resolvedModelProfile);
    var body = _buildOpenAIBody(
      system,
      messages,
      tools,
      stream: true,
      includeStreamUsage: includeUsage,
    );

    Future<http.StreamedResponse> openStream() {
      return _retryWithBackoff((attemptAbortTrigger, attemptDeadline) async {
        final request = _abortableRequest(
          'POST',
          Uri.parse(url),
          headers: _openaiHeaders(),
          body: jsonEncode(body),
          attemptAbortTrigger: attemptAbortTrigger,
          deadline: attemptDeadline,
        );
        final response = await _client.send(request);
        if (response.statusCode == 400) {
          final errorBody = await response.stream.bytesToString();
          if (includeUsage && _isStreamUsageUnsupportedError(errorBody)) {
            await _capabilityRegistry
                .markOpenAIStreamUsageUnsupported(config.baseUrl);
            includeUsage = false;
            body = _buildOpenAIBody(
              system,
              messages,
              tools,
              stream: true,
              includeStreamUsage: false,
            );
            final retryReq = _abortableRequest(
              'POST',
              Uri.parse(url),
              headers: _openaiHeaders(),
              body: jsonEncode(body),
              attemptAbortTrigger: attemptAbortTrigger,
              deadline: attemptDeadline,
            );
            final retryResp = await _client.send(retryReq);
            if (retryResp.statusCode != 200) {
              final retryErr = await retryResp.stream.bytesToString();
              throw Exception(
                  'OpenAI API error (${retryResp.statusCode}): ${_sanitizeErrorBody(retryErr)}');
            }
            return retryResp;
          }
          if (_tryTokenKeyFallback(errorBody) ||
              _tryReasoningContentFallback(errorBody)) {
            body = _buildOpenAIBody(
              system,
              messages,
              tools,
              stream: true,
              includeStreamUsage: includeUsage,
            );
            final retryReq = _abortableRequest(
              'POST',
              Uri.parse(url),
              headers: _openaiHeaders(),
              body: jsonEncode(body),
              attemptAbortTrigger: attemptAbortTrigger,
              deadline: attemptDeadline,
            );
            final retryResp = await _client.send(retryReq);
            if (retryResp.statusCode != 200) {
              final retryErr = await retryResp.stream.bytesToString();
              throw Exception(
                  'OpenAI API error (${retryResp.statusCode}): ${_sanitizeErrorBody(retryErr)}');
            }
            return retryResp;
          }
          throw Exception(
              'OpenAI API error (400): ${_sanitizeErrorBody(errorBody)}');
        }
        if (response.statusCode != 200) {
          final errorBody = await response.stream.bytesToString();
          throw Exception(
              'OpenAI API error (${response.statusCode}): ${_sanitizeErrorBody(errorBody)}');
        }
        return response;
      }, deadline: deadline);
    }

    String currentText = '';
    StringBuffer currentReasoningContent = StringBuffer();
    final List<ContentBlock> collectedBlocks = [];
    final Map<int, Map<String, String>> toolCallsAccum = {};
    String stopReason = 'stop';
    bool receivedDone = false;
    int? inputTokens;
    int? outputTokens;
    int? cacheReadInputTokens;
    bool receivedFinishReason = false;
    bool streamFailed = false;

    void resetOpenAiStreamState() {
      currentText = '';
      currentReasoningContent = StringBuffer();
      collectedBlocks.clear();
      toolCallsAccum.clear();
      stopReason = 'stop';
      receivedDone = false;
      inputTokens = null;
      outputTokens = null;
      cacheReadInputTokens = null;
      receivedFinishReason = false;
      streamFailed = false;
    }

    Iterable<StreamEvent> parseOpenAiSseData(String data) sync* {
      final frame = data.trim();
      if (frame.isEmpty) {
        return;
      }
      if (frame == '[DONE]') {
        receivedDone = true;
        return;
      }

      late final Map<String, dynamic> event;
      try {
        final decoded = jsonDecode(frame);
        if (decoded is! Map) {
          throw const FormatException('Expected JSON object');
        }
        event = Map<String, dynamic>.from(decoded);
      } catch (_) {
        streamFailed = true;
        yield StreamError(
          'OpenAI stream interrupted: malformed SSE JSON frame',
        );
        return;
      }

      try {
        // Parse usage from streaming chunk (OpenAI sends it in final chunk)
        final usage = event['usage'] as Map<String, dynamic>?;
        if (usage != null) {
          final parsedUsage = LlmUsage.fromOpenAI(usage);
          inputTokens = parsedUsage?.inputTokens ?? inputTokens;
          outputTokens = parsedUsage?.outputTokens ?? outputTokens;
          cacheReadInputTokens =
              parsedUsage?.cacheReadInputTokens ?? cacheReadInputTokens;
        }

        final choices = event['choices'] as List?;
        if (choices == null || choices.isEmpty) return;
        final choice = choices[0] as Map<String, dynamic>;
        final delta = choice['delta'] as Map<String, dynamic>?;
        final finishReason = choice['finish_reason'] as String?;

        if (finishReason != null) {
          stopReason = finishReason;
          receivedFinishReason = true;
        }
        if (delta == null) return;

        final content = delta['content'] as String?;
        if (content != null) {
          if (content.isNotEmpty) {
            currentText += content;
            yield TextDelta(content);
          }
        }
        final reasoningContent = delta['reasoning_content'] as String?;
        if (reasoningContent != null) {
          if (reasoningContent.isNotEmpty) {
            currentReasoningContent.write(reasoningContent);
            yield ReasoningDelta(reasoningContent);
          }
        }

        final toolCalls = delta['tool_calls'] as List?;
        if (toolCalls != null) {
          for (final tc in toolCalls) {
            final index = tc['index'] as int;
            final entry = toolCallsAccum.putIfAbsent(
              index,
              () => {'id': '', 'name': '', 'arguments': '', 'started': ''},
            );
            if (tc['id'] != null && entry['id']!.isEmpty) {
              entry['id'] = tc['id'];
            }
            if (tc['function'] != null) {
              final func = tc['function'] as Map<String, dynamic>;
              if (func['name'] != null && entry['name']!.isEmpty) {
                entry['name'] = func['name'];
              }
              // Only emit ToolUseStart once both id and name are known
              if (entry['started']!.isEmpty &&
                  entry['id']!.isNotEmpty &&
                  entry['name']!.isNotEmpty) {
                entry['started'] = '1';
                yield ToolUseStart(entry['id']!, entry['name']!);
              }
              if (func['arguments'] != null) {
                final arguments = func['arguments'] as String;
                if (arguments.isNotEmpty) {
                  entry['arguments'] = entry['arguments']! + arguments;
                  yield ToolInputDelta(arguments);
                }
              }
            }
          }
        }
      } catch (_) {
        streamFailed = true;
        yield StreamError(
          'OpenAI stream interrupted: malformed SSE JSON frame',
        );
      }
    }

    try {
      await for (final data in _resilientSseDataStream(
        openStream: openStream,
        isDoneData: (data) => data == '[DONE]',
        deadline: deadline,
        isInBackground: _isInBackground,
      )) {
        if (data is _ResilientSseRetry) {
          resetOpenAiStreamState();
          yield const StreamReset();
          continue;
        }
        if (data is! _ResilientSseData) {
          continue;
        }
        for (final event in parseOpenAiSseData(data.data)) {
          yield event;
        }
        if (streamFailed) return;
        if (receivedDone) break;
      }
    } catch (e) {
      yield StreamError('OpenAI stream interrupted after retries: $e');
      return;
    }

    if (!receivedFinishReason) {
      yield StreamError(
        'OpenAI stream interrupted: ended without finish_reason',
      );
      return;
    }

    final reasoningText = currentReasoningContent.toString();
    if (currentText.isNotEmpty || reasoningText.isNotEmpty) {
      collectedBlocks.add(ContentBlock(
        type: 'text',
        text: currentText,
        reasoningContent: reasoningText.isEmpty ? null : reasoningText,
      ));
    }

    if (toolCallsAccum.isNotEmpty && stopReason != 'tool_calls') {
      yield StreamError(
        'OpenAI stream interrupted: tool call ended without tool_calls finish_reason',
      );
      return;
    }

    for (final entry in toolCallsAccum.entries) {
      final tc = entry.value;
      if (tc['id']!.isEmpty || tc['name']!.isEmpty) {
        yield StreamError(
          'OpenAI stream interrupted: incomplete tool call metadata',
        );
        return;
      }
      Map<String, dynamic> args = {};
      try {
        if (tc['arguments']!.isNotEmpty) args = jsonDecode(tc['arguments']!);
      } catch (_) {
        yield StreamError(
          'OpenAI stream interrupted: incomplete tool call JSON',
        );
        return;
      }
      collectedBlocks.add(ContentBlock(
        type: 'tool_use',
        toolUseId: tc['id'],
        toolName: tc['name'],
        toolInput: args,
        rawToolInputJson: tc['arguments']!.isEmpty ? null : tc['arguments']!,
      ));
    }

    final mappedStopReason = switch (stopReason) {
      'tool_calls' => 'tool_use',
      'stop' => 'end_turn',
      'length' => 'max_tokens',
      _ => stopReason,
    };

    final usage = LlmUsage(
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      cacheReadInputTokens: cacheReadInputTokens,
    );
    yield StreamDone(LlmResponse(
      stopReason: mappedStopReason,
      content: collectedBlocks,
      usage: usage.hasValues ? usage : null,
    ));
  }

  Map<String, dynamic> _buildOpenAIBody(
    String system,
    List<Map<String, dynamic>> messages,
    List<ToolDefinition> tools, {
    required bool stream,
    bool includeStreamUsage = true,
  }) {
    const transform = ProviderMessageTransform();
    final capabilities = resolvedModelProfile.capabilities;
    final safeSystem = _sanitizeForLlmPayload(system);
    final openaiMessages = <Map<String, dynamic>>[
      {'role': 'system', 'content': safeSystem},
    ];
    openaiMessages.addAll(transform.toProviderPayload(
      messages,
      ProviderTransformOptions(
        apiFormat: 'openai',
        modelId: modelIdFromDisplay(config.model),
        baseUrl: Uri.tryParse(config.baseUrl),
        capabilities: capabilities,
      ),
    ));
    final thinkingEnabled = config.thinkingBudget > 0 &&
        resolvedModelProfile.provider.kind == ProviderKind.anthropicCompatible;
    final tokenLimitKey = capabilities.tokenLimitParameter.requestKey;
    final body = <String, dynamic>{
      'model': modelIdFromDisplay(config.model),
      if (thinkingEnabled)
        'max_completion_tokens': config.thinkingBudget + config.maxTokens
      else
        tokenLimitKey: config.maxTokens,
      'messages': openaiMessages,
      'stream': stream,
      if (stream && includeStreamUsage)
        'stream_options': {'include_usage': true},
    };
    if (config.temperature != null &&
        capabilities.acceptsTemperature &&
        !thinkingEnabled) {
      body['temperature'] = config.temperature;
    }
    if (capabilities.supportsTools && tools.isNotEmpty) {
      body['tools'] = tools.map((t) => t.toOpenAIJson()).toList();
    }
    if (thinkingEnabled) {
      body['thinking'] = {
        'type': 'enabled',
        'budget_tokens': config.thinkingBudget,
      };
    }
    return body;
  }

  static String _sanitizeForLlmPayload(String text) {
    return const LlmContentSanitizer().sanitizeText(text).text;
  }

  bool _isStreamUsageUnsupportedError(String errorBody) {
    final lower = errorBody.toLowerCase();
    if (!lower.contains('stream_options') && !lower.contains('include_usage')) {
      return false;
    }
    return lower.contains('unknown') ||
        lower.contains('unsupported') ||
        lower.contains('unrecognized') ||
        lower.contains('invalid') ||
        lower.contains('extra') ||
        lower.contains('not permitted') ||
        lower.contains('not supported');
  }

  bool _tryTokenKeyFallback(String errorBody) {
    final lower = errorBody.toLowerCase();
    if (!lower.contains('max_tokens') &&
        !lower.contains('max_completion_tokens')) {
      return false;
    }
    final current = resolvedModelProfile.capabilities.tokenLimitParameter;
    final alternate = current == TokenLimitParameter.maxCompletionTokens
        ? TokenLimitParameter.maxTokens
        : TokenLimitParameter.maxCompletionTokens;
    _capabilityRegistry.markTokenLimitParameterOverride(
      apiFormat: config.format,
      baseUrl: config.baseUrl,
      modelId: modelIdFromDisplay(config.model),
      parameter: alternate,
    );
    return true;
  }

  bool _tryReasoningContentFallback(String errorBody) {
    final lower = errorBody.toLowerCase();
    if (!lower.contains('reasoning_content')) return false;
    if (_isReasoningContentUnsupportedError(lower)) {
      if (!resolvedModelProfile.capabilities.supportsReasoningContent) {
        return false;
      }
      _capabilityRegistry.markDisablesReasoningContent(
        apiFormat: config.format,
        baseUrl: config.baseUrl,
        modelId: modelIdFromDisplay(config.model),
      );
      return true;
    }
    if (!_isReasoningContentRequiredError(lower)) return false;
    _capabilityRegistry.markRequiresReasoningContent(
      apiFormat: config.format,
      baseUrl: config.baseUrl,
      modelId: modelIdFromDisplay(config.model),
    );
    return true;
  }

  bool _isReasoningContentUnsupportedError(String lowerErrorBody) {
    return lowerErrorBody.contains('unsupported') ||
        lowerErrorBody.contains('not supported') ||
        lowerErrorBody.contains('unknown') ||
        lowerErrorBody.contains('unrecognized') ||
        lowerErrorBody.contains('not permitted') ||
        lowerErrorBody.contains('not allowed') ||
        lowerErrorBody.contains('extra') ||
        lowerErrorBody.contains('unexpected');
  }

  bool _isReasoningContentRequiredError(String lowerErrorBody) {
    return lowerErrorBody.contains('required') ||
        lowerErrorBody.contains('missing') ||
        lowerErrorBody.contains('must include') ||
        lowerErrorBody.contains('must provide') ||
        lowerErrorBody.contains('must be supplied') ||
        lowerErrorBody.contains('mandatory');
  }

  static void clearTokenKeyOverrides() {
    CapabilityRegistry.instance.clearTokenLimitOverrides();
  }

  static void clearReasoningContentOverridesForTesting() {
    CapabilityRegistry.instance.clearReasoningContentOverrides();
  }

  Map<String, String> _openaiHeaders() => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${config.apiKey}',
        'Accept-Encoding': 'identity',
        ..._keepAliveHeaders,
      };

  void _ensureNotDisposed() {
    if (_disposed) {
      throw StateError('LlmService has been disposed');
    }
  }

  LlmResponse _parseOpenAIResponse(Map<String, dynamic> json) {
    final choice = (json['choices'] as List)[0] as Map<String, dynamic>;
    final message = choice['message'] as Map<String, dynamic>;
    final finishReason = choice['finish_reason'] as String? ?? 'stop';

    final blocks = <ContentBlock>[];
    final content = message['content'] as String?;
    final reasoningContent = message['reasoning_content'] as String?;
    if ((content != null && content.isNotEmpty) ||
        (reasoningContent != null && reasoningContent.isNotEmpty)) {
      blocks.add(ContentBlock(
        type: 'text',
        text: content ?? '',
        reasoningContent:
            reasoningContent?.isEmpty == true ? null : reasoningContent,
      ));
    }

    final toolCalls = message['tool_calls'] as List?;
    if (toolCalls != null) {
      for (final tc in toolCalls) {
        final func = tc['function'] as Map<String, dynamic>;
        Map<String, dynamic> args = {};
        try {
          args = jsonDecode(func['arguments'] as String);
        } catch (_) {
          // Malformed tool arguments JSON — proceed with empty args
        }
        blocks.add(ContentBlock(
          type: 'tool_use',
          toolUseId: tc['id'] as String,
          toolName: func['name'] as String,
          toolInput: args,
          rawToolInputJson: func['arguments'] as String?,
        ));
      }
    }

    final mappedStopReason = switch (finishReason) {
      'tool_calls' => 'tool_use',
      'stop' => 'end_turn',
      'length' => 'max_tokens',
      _ => finishReason,
    };

    final usage = LlmUsage.fromOpenAI(
      json['usage'] is Map ? Map<String, dynamic>.from(json['usage']) : null,
    );
    return LlmResponse(
      stopReason: mappedStopReason,
      content: blocks,
      usage: usage,
    );
  }
}
