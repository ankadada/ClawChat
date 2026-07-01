import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import '../models/model_capabilities.dart';
import 'api_validator.dart';
import 'llm_content_sanitizer.dart';
import 'model_capability_registry.dart';
import 'provider_message_transform.dart';
export '../models/model_capabilities.dart' show ApiFormat;

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

sealed class StreamEvent {}

class TextDelta extends StreamEvent {
  final String text;
  TextDelta(this.text);
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

class StreamDone extends StreamEvent {
  final LlmResponse response;
  StreamDone(this.response);
}

class StreamError extends StreamEvent {
  final String message;
  final Object? cause;
  StreamError(this.message, {this.cause});
}

class LlmService {
  final LlmConfig config;
  final http.Client _client;
  final bool Function()? _isInBackground;
  final CapabilityRegistry _capabilityRegistry;

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
  })  : _capabilityRegistry = capabilityRegistry,
        _isInBackground = isInBackground,
        _client = _createPinnedClient();

  /// Creates an HTTP client that rejects bad TLS certificates (self-signed,
  /// expired, wrong-host) to mitigate MITM attacks on API traffic.
  static http.Client _createPinnedClient() {
    final httpClient = HttpClient()
      ..idleTimeout = const Duration(seconds: 120)
      ..badCertificateCallback = (X509Certificate cert, String host, int port) {
        return false;
      };
    return IOClient(httpClient);
  }

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
  }) async {
    if (apiFormat == 'anthropic') {
      final effectiveBaseUrl = (baseUrl != null && baseUrl.isNotEmpty)
          ? baseUrl
          : 'https://api.anthropic.com';
      final url = _joinEndpointUrl(effectiveBaseUrl, '/v1/models');
      final client = _createPinnedClient();
      try {
        final uri =
            ApiValidator.validateBearerUrl(url, context: 'Models API endpoint');
        final response = await client.get(
          uri,
          headers: {
            'x-api-key': apiKey,
            'anthropic-version': '2023-06-01',
          },
        ).timeout(const Duration(seconds: 10));
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
      } finally {
        client.close();
      }
    }

    final effectiveBaseUrl = (baseUrl != null && baseUrl.isNotEmpty)
        ? baseUrl
        : 'https://api.openai.com';
    final url = _joinEndpointUrl(effectiveBaseUrl, '/v1/models');
    final client = _createPinnedClient();
    try {
      final uri =
          ApiValidator.validateBearerUrl(url, context: 'Models API endpoint');
      final response = await client.get(
        uri,
        headers: {'Authorization': 'Bearer $apiKey'},
      ).timeout(const Duration(seconds: 10));

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
    } finally {
      client.close();
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

  /// Closes the underlying HTTP client. Must be called when the service
  /// is no longer needed to avoid connection pool leaks.
  void dispose() => _client.close();

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
  static const Duration _streamChunkTimeout = Duration(seconds: 60);
  static const Duration _streamReconnectBaseDelay = Duration(seconds: 2);
  static const int _maxRetries = 3;
  static const int _maxStreamReconnects = 2;
  static const Map<String, String> _keepAliveHeaders = {
    'Connection': 'keep-alive',
    'Keep-Alive': 'timeout=120',
  };

  /// Runs [fn] with exponential backoff retry on 429 and 5xx errors.
  Future<T> _retryWithBackoff<T>(Future<T> Function() fn) async {
    for (int attempt = 0; attempt <= _maxRetries; attempt++) {
      try {
        return await fn().timeout(_requestTimeout);
      } on TimeoutException {
        if (attempt == _maxRetries) rethrow;
      } catch (e) {
        final isRetryable = e is http.ClientException ||
            (e is Exception && _isRetryableHttpError(e.toString()));
        if (!isRetryable || attempt == _maxRetries) rethrow;
      }
      await Future.delayed(Duration(seconds: (1 << attempt) * 2));
    }
    throw StateError('unreachable');
  }

  static bool _isRetryableHttpError(String msg) {
    // Match 429 (rate limit) and 5xx status codes in error messages
    final pattern = RegExp(r'\((429|5\d{2})\)');
    return pattern.hasMatch(msg);
  }

  bool _isRetryableStreamError(Object error) {
    return error is http.ClientException ||
        error is TimeoutException ||
        error is SocketException ||
        error is HttpException ||
        error is IOException ||
        (error is Exception && _isRetryableHttpError(error.toString()));
  }

  Future<void> _delayBeforeStreamReconnect(int completedAttempts) async {
    final multiplier = 1 << completedAttempts;
    await Future.delayed(_streamReconnectBaseDelay * multiplier);
  }

  Stream<String> _linesWithForegroundTimeout(
    Stream<List<int>> byteStream, {
    bool Function()? isInBackground,
  }) {
    late final StreamController<String> controller;
    StreamSubscription<String>? subscription;
    Timer? timeoutTimer;
    var pendingLine = '';
    var lastChunkTime = DateTime.now();
    var closed = false;

    void cancelTimeout() {
      timeoutTimer?.cancel();
      timeoutTimer = null;
    }

    void failWithTimeout() {
      closed = true;
      unawaited(subscription?.cancel());
      controller.addError(
        TimeoutException(
          'No stream data received within $_streamChunkTimeout',
          _streamChunkTimeout,
        ),
      );
      unawaited(controller.close());
    }

    void scheduleTimeout([Duration delay = _streamChunkTimeout]) {
      cancelTimeout();
      if (closed) return;
      timeoutTimer = Timer(delay, () {
        if (closed) return;
        if (isInBackground?.call() == true) {
          lastChunkTime = DateTime.now();
          scheduleTimeout();
          return;
        }

        final idleDuration = DateTime.now().difference(lastChunkTime);
        if (idleDuration < _streamChunkTimeout) {
          scheduleTimeout(_streamChunkTimeout - idleDuration);
          return;
        }

        failWithTimeout();
      });
    }

    controller = StreamController<String>(
      onListen: () {
        scheduleTimeout();
        subscription = byteStream.transform(utf8.decoder).listen(
          (chunk) {
            lastChunkTime = DateTime.now();
            scheduleTimeout();
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
            if (closed) return;
            closed = true;
            cancelTimeout();
            controller.addError(error, stackTrace);
            unawaited(controller.close());
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
            cancelTimeout();
            unawaited(controller.close());
          },
        );
      },
      onPause: () {
        cancelTimeout();
        subscription?.pause();
      },
      onResume: () {
        lastChunkTime = DateTime.now();
        scheduleTimeout();
        subscription?.resume();
      },
      onCancel: () async {
        closed = true;
        cancelTimeout();
        await subscription?.cancel();
      },
    );

    return controller.stream;
  }

  Stream<String> _resilientSseDataStream({
    required Future<http.StreamedResponse> Function() openStream,
    required bool Function(String data) isDoneData,
    void Function(int attempt, Object error)? onRetry,
    bool Function()? isInBackground,
  }) async* {
    for (int attempt = 0; attempt <= _maxStreamReconnects; attempt++) {
      final sseDataLines = <String>[];
      try {
        final response = await openStream();
        await for (final line in _linesWithForegroundTimeout(
          response.stream,
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
            yield data;
            if (isDoneData(data)) return;
          }
        }

        if (sseDataLines.isNotEmpty) {
          final data = sseDataLines.join('\n').trim();
          sseDataLines.clear();
          yield data;
          if (isDoneData(data)) return;
        }
        return;
      } catch (e) {
        if (attempt >= _maxStreamReconnects || !_isRetryableStreamError(e)) {
          rethrow;
        }
        onRetry?.call(attempt + 1, e);
        await _delayBeforeStreamReconnect(attempt);
      }
    }
  }

  Future<LlmResponse> chat({
    required String system,
    required List<Map<String, dynamic>> messages,
    required List<ToolDefinition> tools,
  }) async {
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
    return _retryWithBackoff(() async {
      final body = _buildAnthropicBody(system, messages, tools, stream: false);
      final response = await _client.post(
        Uri.parse(url),
        headers: _anthropicHeaders(),
        body: jsonEncode(body),
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
    final body = _buildAnthropicBody(system, messages, tools, stream: true);

    Future<http.StreamedResponse> openStream() {
      return _retryWithBackoff(() async {
        final request = http.Request('POST', Uri.parse(url));
        request.headers.addAll(_anthropicHeaders());
        request.body = jsonEncode(body);
        final response = await _client.send(request);
        if (response.statusCode != 200) {
          final errorBody = await response.stream.bytesToString();
          throw _anthropicApiException(response.statusCode, errorBody);
        }
        return response;
      });
    }

    final List<ContentBlock> collectedBlocks = [];
    String currentText = '';
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
    int textSkipRemaining = 0;
    int toolInputSkipRemaining = 0;
    int toolStartSkipRemaining = 0;
    int completedToolBlockSkipRemaining = 0;
    int emittedTextLength = 0;
    int emittedToolInputLength = 0;
    int emittedToolStarts = 0;
    int completedToolBlocks = 0;
    bool suppressCurrentToolBlock = false;

    void finishCurrentAnthropicBlock() {
      if (isThinkingBlock) {
        isThinkingBlock = false;
        return;
      }
      if (currentToolName.isNotEmpty && currentToolId.isNotEmpty) {
        final shouldSuppressToolBlock = suppressCurrentToolBlock;
        suppressCurrentToolBlock = false;
        Map<String, dynamic> input = {};
        try {
          final inputStr = currentToolInput.toString();
          if (inputStr.isNotEmpty) input = jsonDecode(inputStr);
        } catch (_) {
          // Malformed tool input JSON - proceed with empty input
        }
        if (!shouldSuppressToolBlock) {
          final rawToolInputJson = currentToolInput.toString();
          collectedBlocks.add(ContentBlock(
            type: 'tool_use',
            toolUseId: currentToolId,
            toolName: currentToolName,
            toolInput: input,
            rawToolInputJson:
                rawToolInputJson.isEmpty ? null : rawToolInputJson,
          ));
          completedToolBlocks++;
        }
        currentToolId = '';
        currentToolName = '';
        currentToolInput = StringBuffer();
      } else if (currentText.isNotEmpty) {
        collectedBlocks.add(ContentBlock(type: 'text', text: currentText));
        currentText = '';
      }
    }

    Iterable<StreamEvent> parseAnthropicSseData(String data) sync* {
      if (data == '[DONE]') {
        receivedMessageStop = true;
        return;
      }

      try {
        final event = jsonDecode(data) as Map<String, dynamic>;
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
            if (block['type'] == 'thinking') {
              isThinkingBlock = true;
            } else if (block['type'] == 'tool_use') {
              isThinkingBlock = false;
              final duplicateToolStart = toolStartSkipRemaining > 0;
              final duplicateCompletedToolBlock =
                  completedToolBlockSkipRemaining > 0;
              if (!duplicateToolStart ||
                  duplicateCompletedToolBlock ||
                  currentToolId.isEmpty) {
                currentToolId = block['id'] as String;
                currentToolName = block['name'] as String;
              }
              if (!duplicateToolStart || duplicateCompletedToolBlock) {
                currentToolInput = StringBuffer();
              }
              suppressCurrentToolBlock = duplicateCompletedToolBlock;
              if (duplicateCompletedToolBlock) {
                completedToolBlockSkipRemaining--;
              }
              if (duplicateToolStart) {
                toolStartSkipRemaining--;
              } else {
                emittedToolStarts++;
                yield ToolUseStart(currentToolId, currentToolName);
              }
            } else {
              isThinkingBlock = false;
            }
            break;

          case 'content_block_delta':
            if (isThinkingBlock) break;
            final delta = event['delta'] as Map<String, dynamic>;
            if (delta['type'] == 'text_delta') {
              final text = delta['text'] as String;
              var textToEmit = text;
              if (textSkipRemaining > 0) {
                if (textSkipRemaining >= text.length) {
                  textSkipRemaining -= text.length;
                  textToEmit = '';
                } else {
                  textToEmit = text.substring(textSkipRemaining);
                  textSkipRemaining = 0;
                }
              }
              if (textToEmit.isNotEmpty) {
                currentText += textToEmit;
                emittedTextLength += textToEmit.length;
                yield TextDelta(textToEmit);
              }
            } else if (delta['type'] == 'input_json_delta') {
              final json = delta['partial_json'] as String;
              var jsonToEmit = json;
              if (toolInputSkipRemaining > 0) {
                if (toolInputSkipRemaining >= json.length) {
                  toolInputSkipRemaining -= json.length;
                  jsonToEmit = '';
                } else {
                  jsonToEmit = json.substring(toolInputSkipRemaining);
                  toolInputSkipRemaining = 0;
                }
              }
              if (jsonToEmit.isNotEmpty) {
                currentToolInput.write(jsonToEmit);
                emittedToolInputLength += jsonToEmit.length;
                yield ToolInputDelta(jsonToEmit);
              }
            }
            break;

          case 'content_block_stop':
            finishCurrentAnthropicBlock();
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
        // Malformed SSE event JSON - skip and continue to next event
      }
    }

    try {
      await for (final data in _resilientSseDataStream(
        openStream: openStream,
        isDoneData: (data) => data == '[DONE]',
        isInBackground: _isInBackground,
        onRetry: (_, __) {
          textSkipRemaining = emittedTextLength;
          toolInputSkipRemaining = emittedToolInputLength;
          toolStartSkipRemaining = emittedToolStarts;
          completedToolBlockSkipRemaining = completedToolBlocks;
        },
      )) {
        for (final event in parseAnthropicSseData(data)) {
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

    finishCurrentAnthropicBlock();

    if (!receivedMessageStop && collectedBlocks.isEmpty) {
      yield StreamError('Anthropic stream ended without message_stop event');
      return;
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
    return _retryWithBackoff(() async {
      final body = _buildOpenAIBody(system, messages, tools, stream: false);
      final response = await _client.post(
        Uri.parse(url),
        headers: _openaiHeaders(),
        body: jsonEncode(body),
      );
      if (response.statusCode == 400 &&
          (_tryTokenKeyFallback(response.body) ||
              _tryReasoningContentFallback(response.body))) {
        final retryBody =
            _buildOpenAIBody(system, messages, tools, stream: false);
        final retryResponse = await _client.post(
          Uri.parse(url),
          headers: _openaiHeaders(),
          body: jsonEncode(retryBody),
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
      return _retryWithBackoff(() async {
        final request = http.Request('POST', Uri.parse(url));
        request.headers.addAll(_openaiHeaders());
        request.body = jsonEncode(body);
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
            final retryReq = http.Request('POST', Uri.parse(url));
            retryReq.headers.addAll(_openaiHeaders());
            retryReq.body = jsonEncode(body);
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
            final retryReq = http.Request('POST', Uri.parse(url));
            retryReq.headers.addAll(_openaiHeaders());
            retryReq.body = jsonEncode(body);
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
      });
    }

    String currentText = '';
    String currentReasoningContent = '';
    final List<ContentBlock> collectedBlocks = [];
    final Map<int, Map<String, String>> toolCallsAccum = {};
    String stopReason = 'stop';
    bool receivedDone = false;
    int? inputTokens;
    int? outputTokens;
    int? cacheReadInputTokens;
    int textSkipRemaining = 0;
    int reasoningSkipRemaining = 0;
    int emittedTextLength = 0;
    int emittedReasoningLength = 0;
    final Map<int, int> toolArgumentSkipRemaining = {};

    Iterable<StreamEvent> parseOpenAiSseData(String data) sync* {
      if (data == '[DONE]') {
        receivedDone = true;
        return;
      }

      try {
        final event = jsonDecode(data) as Map<String, dynamic>;
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

        if (finishReason != null) stopReason = finishReason;
        if (delta == null) return;

        final content = delta['content'] as String?;
        if (content != null) {
          var contentToEmit = content;
          if (textSkipRemaining > 0) {
            if (textSkipRemaining >= content.length) {
              textSkipRemaining -= content.length;
              contentToEmit = '';
            } else {
              contentToEmit = content.substring(textSkipRemaining);
              textSkipRemaining = 0;
            }
          }
          if (contentToEmit.isNotEmpty) {
            currentText += contentToEmit;
            emittedTextLength += contentToEmit.length;
            yield TextDelta(contentToEmit);
          }
        }
        final reasoningContent = delta['reasoning_content'] as String?;
        if (reasoningContent != null) {
          var reasoningToAppend = reasoningContent;
          if (reasoningSkipRemaining > 0) {
            if (reasoningSkipRemaining >= reasoningContent.length) {
              reasoningSkipRemaining -= reasoningContent.length;
              reasoningToAppend = '';
            } else {
              reasoningToAppend =
                  reasoningContent.substring(reasoningSkipRemaining);
              reasoningSkipRemaining = 0;
            }
          }
          if (reasoningToAppend.isNotEmpty) {
            currentReasoningContent += reasoningToAppend;
            emittedReasoningLength += reasoningToAppend.length;
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
                var argumentsToEmit = arguments;
                final skipRemaining = toolArgumentSkipRemaining[index] ?? 0;
                if (skipRemaining > 0) {
                  if (skipRemaining >= arguments.length) {
                    toolArgumentSkipRemaining[index] =
                        skipRemaining - arguments.length;
                    argumentsToEmit = '';
                  } else {
                    argumentsToEmit = arguments.substring(skipRemaining);
                    toolArgumentSkipRemaining[index] = 0;
                  }
                }
                if (argumentsToEmit.isNotEmpty) {
                  entry['arguments'] = entry['arguments']! + argumentsToEmit;
                  yield ToolInputDelta(argumentsToEmit);
                }
              }
            }
          }
        }
      } catch (_) {
        // Malformed SSE event JSON - skip and continue to next event
      }
    }

    try {
      await for (final data in _resilientSseDataStream(
        openStream: openStream,
        isDoneData: (data) => data == '[DONE]',
        isInBackground: _isInBackground,
        onRetry: (_, __) {
          textSkipRemaining = emittedTextLength;
          reasoningSkipRemaining = emittedReasoningLength;
          toolArgumentSkipRemaining
            ..clear()
            ..addEntries(toolCallsAccum.entries.map(
              (entry) => MapEntry(
                entry.key,
                entry.value['arguments']?.length ?? 0,
              ),
            ));
        },
      )) {
        for (final event in parseOpenAiSseData(data)) {
          yield event;
        }
        if (receivedDone) break;
      }
    } catch (e) {
      yield StreamError('OpenAI stream interrupted after retries: $e');
      return;
    }

    if (currentText.isNotEmpty || currentReasoningContent.isNotEmpty) {
      collectedBlocks.add(ContentBlock(
        type: 'text',
        text: currentText,
        reasoningContent:
            currentReasoningContent.isEmpty ? null : currentReasoningContent,
      ));
    }

    for (final entry in toolCallsAccum.entries) {
      final tc = entry.value;
      if (tc['id']!.isEmpty || tc['name']!.isEmpty) continue;
      Map<String, dynamic> args = {};
      try {
        if (tc['arguments']!.isNotEmpty) args = jsonDecode(tc['arguments']!);
      } catch (_) {
        // Malformed tool arguments JSON — proceed with empty args
      }
      collectedBlocks.add(ContentBlock(
        type: 'tool_use',
        toolUseId: tc['id'],
        toolName: tc['name'],
        toolInput: args,
        rawToolInputJson: tc['arguments']!.isEmpty ? null : tc['arguments']!,
      ));
    }

    if (!receivedDone && collectedBlocks.isEmpty) {
      yield StreamError('OpenAI stream ended without [DONE] marker');
      return;
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
