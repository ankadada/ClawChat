import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'api_validator.dart';

enum ApiFormat { anthropic, openai }

enum _OpenAICompatibleProvider {
  anthropicCompatible,
  openaiNative,
  generic,
}

class LlmConfig {
  final ApiFormat format;
  final String apiKey;
  final String model;
  final String baseUrl;
  final int maxTokens;
  final int thinkingBudget; // 0 = disabled
  final double? temperature;

  const LlmConfig({
    required this.format,
    required this.apiKey,
    required this.model,
    required this.baseUrl,
    this.maxTokens = 8192,
    this.thinkingBudget = 0,
    this.temperature,
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
          temperature == other.temperature;

  @override
  int get hashCode => Object.hash(
      format, apiKey, model, baseUrl, maxTokens, thinkingBudget, temperature);

  factory LlmConfig.anthropic({
    required String apiKey,
    String model = 'claude-sonnet-4-20250514',
    String baseUrl = 'https://api.anthropic.com',
    int maxTokens = 8192,
    int thinkingBudget = 0,
  }) {
    return LlmConfig(
      format: ApiFormat.anthropic,
      apiKey: apiKey,
      model: model,
      baseUrl: baseUrl,
      maxTokens: maxTokens,
      thinkingBudget: thinkingBudget,
    );
  }

  factory LlmConfig.openai({
    required String apiKey,
    required String model,
    String baseUrl = 'https://api.openai.com',
    int maxTokens = 8192,
    int thinkingBudget = 0,
  }) {
    return LlmConfig(
      format: ApiFormat.openai,
      apiKey: apiKey,
      model: model,
      baseUrl: baseUrl,
      maxTokens: maxTokens,
      thinkingBudget: thinkingBudget,
    );
  }
}

class LlmResponse {
  final String stopReason;
  final List<ContentBlock> content;
  final int? inputTokens;
  final int? outputTokens;
  const LlmResponse({
    required this.stopReason,
    required this.content,
    this.inputTokens,
    this.outputTokens,
  });
}

class ContentBlock {
  final String type;
  final String? text;
  final String? toolUseId;
  final String? toolName;
  final Map<String, dynamic>? toolInput;

  const ContentBlock({
    required this.type,
    this.text,
    this.toolUseId,
    this.toolName,
    this.toolInput,
  });

  Map<String, dynamic> toJson() {
    if (type == 'text') {
      return {'type': 'text', 'text': text};
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
  StreamError(this.message);
}

class LlmService {
  final LlmConfig config;
  final http.Client _client;

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
  static const _anthropicPresetModelIds = [
    'claude-sonnet-4-20250514',
    'claude-opus-4-20250514',
    'claude-haiku-4-20250514',
  ];

  LlmService(this.config) : _client = _createPinnedClient();

  /// Creates an HTTP client that rejects bad TLS certificates (self-signed,
  /// expired, wrong-host) to mitigate MITM attacks on API traffic.
  static http.Client _createPinnedClient() {
    final httpClient = HttpClient()
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
        final models = (data['data'] as List)
            .map((m) => (m as Map)['id'] as String)
            .where((id) =>
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
    return isPresetModel(model)
        ? model.substring(0, model.length - presetModelSuffix.length)
        : model;
  }

  static List<String> _anthropicPresetModels() {
    return _anthropicPresetModelIds
        .map((id) => '$id$presetModelSuffix')
        .toList();
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
    return sanitized;
  }

  static const Duration _requestTimeout = Duration(seconds: 120);
  static const int _maxRetries = 3;

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
        throw Exception(
            'Anthropic API error (${response.statusCode}): ${_sanitizeErrorBody(response.body)}');
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

    http.StreamedResponse streamedResponse;
    try {
      streamedResponse = await _retryWithBackoff(() async {
        final request = http.Request('POST', Uri.parse(url));
        request.headers.addAll(_anthropicHeaders());
        request.body = jsonEncode(body);
        final response = await _client.send(request);
        if (response.statusCode != 200) {
          final errorBody = await response.stream.bytesToString();
          throw Exception(
              'Anthropic API error (${response.statusCode}): ${_sanitizeErrorBody(errorBody)}');
        }
        return response;
      });
    } catch (e) {
      yield StreamError('Anthropic request failed after retries: $e');
      return;
    }

    final List<ContentBlock> collectedBlocks = [];
    String currentText = '';
    String currentToolId = '';
    String currentToolName = '';
    StringBuffer currentToolInput = StringBuffer();
    String stopReason = 'end_turn';
    final List<String> _sseDataLines = [];
    bool receivedMessageStop = false;
    bool _isThinkingBlock = false;
    int? _inputTokens;
    int? _outputTokens;
    bool streamFailed = false;

    void finishCurrentAnthropicBlock() {
      if (_isThinkingBlock) {
        _isThinkingBlock = false;
        return;
      }
      if (currentToolName.isNotEmpty && currentToolId.isNotEmpty) {
        Map<String, dynamic> input = {};
        try {
          final inputStr = currentToolInput.toString();
          if (inputStr.isNotEmpty) input = jsonDecode(inputStr);
        } catch (_) {
          // Malformed tool input JSON - proceed with empty input
        }
        collectedBlocks.add(ContentBlock(
          type: 'tool_use',
          toolUseId: currentToolId,
          toolName: currentToolName,
          toolInput: input,
        ));
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
                _inputTokens = usage['input_tokens'] as int?;
              }
            }
            break;

          case 'content_block_start':
            final block = event['content_block'] as Map<String, dynamic>;
            if (block['type'] == 'thinking') {
              _isThinkingBlock = true;
            } else if (block['type'] == 'tool_use') {
              _isThinkingBlock = false;
              currentToolId = block['id'] as String;
              currentToolName = block['name'] as String;
              currentToolInput = StringBuffer();
              yield ToolUseStart(currentToolId, currentToolName);
            } else {
              _isThinkingBlock = false;
            }
            break;

          case 'content_block_delta':
            if (_isThinkingBlock) break;
            final delta = event['delta'] as Map<String, dynamic>;
            if (delta['type'] == 'text_delta') {
              final text = delta['text'] as String;
              currentText += text;
              yield TextDelta(text);
            } else if (delta['type'] == 'input_json_delta') {
              final json = delta['partial_json'] as String;
              currentToolInput.write(json);
              yield ToolInputDelta(json);
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
              _outputTokens = usage['output_tokens'] as int?;
            }
            break;

          case 'message_stop':
            receivedMessageStop = true;
            break;

          case 'error':
            final error = event['error'] as Map<String, dynamic>;
            streamFailed = true;
            yield StreamError(error['message'] as String? ?? 'Unknown error');
            return;
        }
      } catch (_) {
        // Malformed SSE event JSON - skip and continue to next event
      }
    }

    await for (final chunk in streamedResponse.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      if (chunk.startsWith('data:')) {
        // SSE spec: strip at most one leading space after "data:"
        final payload = chunk.length > 5 && chunk[5] == ' '
            ? chunk.substring(6)
            : chunk.substring(5);
        _sseDataLines.add(payload);
        continue;
      }
      // event:, id:, retry: are part of the SSE spec — ignore them silently
      if (chunk.startsWith('event:') ||
          chunk.startsWith('id:') ||
          chunk.startsWith('retry:')) {
        continue;
      }
      // Flush buffer on empty line (normal SSE delimiter) OR when stream ends
      // (handled after the loop). Some proxies omit the final blank line.
      if (chunk.trim().isEmpty && _sseDataLines.isNotEmpty) {
        final data = _sseDataLines.join('\n').trim();
        _sseDataLines.clear();
        for (final event in parseAnthropicSseData(data)) {
          yield event;
        }
        if (streamFailed) return;
      }
    }

    if (_sseDataLines.isNotEmpty) {
      final data = _sseDataLines.join('\n').trim();
      _sseDataLines.clear();
      for (final event in parseAnthropicSseData(data)) {
        yield event;
      }
      if (streamFailed) return;
    }

    finishCurrentAnthropicBlock();

    if (!receivedMessageStop && collectedBlocks.isEmpty) {
      yield StreamError('Anthropic stream ended without message_stop event');
      return;
    }

    yield StreamDone(LlmResponse(
      stopReason: stopReason,
      content: collectedBlocks,
      inputTokens: _inputTokens,
      outputTokens: _outputTokens,
    ));
  }

  Map<String, dynamic> _buildAnthropicBody(
    String system,
    List<Map<String, dynamic>> messages,
    List<ToolDefinition> tools, {
    required bool stream,
  }) {
    final body = <String, dynamic>{
      'model': modelIdFromDisplay(config.model),
      'max_tokens': config.maxTokens,
      'system': system,
      'messages': messages,
      'stream': stream,
    };
    if (config.temperature != null && !_isReasoningModel(config.model)) {
      body['temperature'] = config.temperature;
    }
    if (tools.isNotEmpty) {
      body['tools'] = tools.map((t) => t.toAnthropicJson()).toList();
    }
    if (config.thinkingBudget > 0) {
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
        .map<ContentBlock>((block) {
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
      return ContentBlock(type: 'text', text: '');
    }).toList();
    return LlmResponse(stopReason: stopReason, content: content);
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
    final body = _buildOpenAIBody(system, messages, tools, stream: true);

    http.StreamedResponse streamedResponse;
    try {
      streamedResponse = await _retryWithBackoff(() async {
        final request = http.Request('POST', Uri.parse(url));
        request.headers.addAll(_openaiHeaders());
        request.body = jsonEncode(body);
        final response = await _client.send(request);
        if (response.statusCode != 200) {
          final errorBody = await response.stream.bytesToString();
          throw Exception(
              'OpenAI API error (${response.statusCode}): ${_sanitizeErrorBody(errorBody)}');
        }
        return response;
      });
    } catch (e) {
      yield StreamError('OpenAI request failed after retries: $e');
      return;
    }

    String currentText = '';
    final List<ContentBlock> collectedBlocks = [];
    final Map<int, Map<String, String>> toolCallsAccum = {};
    String stopReason = 'stop';
    final List<String> _sseDataLines = [];
    bool receivedDone = false;
    int? _inputTokens;
    int? _outputTokens;

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
          _inputTokens = usage['prompt_tokens'] as int?;
          _outputTokens = usage['completion_tokens'] as int?;
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
          currentText += content;
          yield TextDelta(content);
        }

        final toolCalls = delta['tool_calls'] as List?;
        if (toolCalls != null) {
          for (final tc in toolCalls) {
            final index = tc['index'] as int;
            final entry = toolCallsAccum.putIfAbsent(
              index,
              () => {'id': '', 'name': '', 'arguments': '', 'started': ''},
            );
            if (tc['id'] != null) entry['id'] = tc['id'];
            if (tc['function'] != null) {
              final func = tc['function'] as Map<String, dynamic>;
              if (func['name'] != null) {
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
                entry['arguments'] = entry['arguments']! + func['arguments'];
                yield ToolInputDelta(func['arguments']);
              }
            }
          }
        }
      } catch (_) {
        // Malformed SSE event JSON - skip and continue to next event
      }
    }

    await for (final chunk in streamedResponse.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      if (chunk.startsWith('data:')) {
        final payload = chunk.length > 5 && chunk[5] == ' '
            ? chunk.substring(6)
            : chunk.substring(5);
        _sseDataLines.add(payload);
        continue;
      }
      if (chunk.startsWith('event:') ||
          chunk.startsWith('id:') ||
          chunk.startsWith('retry:')) {
        continue;
      }
      if (chunk.trim().isEmpty && _sseDataLines.isNotEmpty) {
        final data = _sseDataLines.join('\n').trim();
        _sseDataLines.clear();
        for (final event in parseOpenAiSseData(data)) {
          yield event;
        }
        if (receivedDone) break;
      }
    }

    if (_sseDataLines.isNotEmpty) {
      final data = _sseDataLines.join('\n').trim();
      _sseDataLines.clear();
      for (final event in parseOpenAiSseData(data)) {
        yield event;
      }
    }

    if (currentText.isNotEmpty) {
      collectedBlocks.add(ContentBlock(type: 'text', text: currentText));
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

    yield StreamDone(LlmResponse(
      stopReason: mappedStopReason,
      content: collectedBlocks,
      inputTokens: _inputTokens,
      outputTokens: _outputTokens,
    ));
  }

  Map<String, dynamic> _buildOpenAIBody(
    String system,
    List<Map<String, dynamic>> messages,
    List<ToolDefinition> tools, {
    required bool stream,
  }) {
    final openaiMessages = <Map<String, dynamic>>[
      {'role': 'system', 'content': system},
    ];
    for (final msg in messages) {
      openaiMessages.addAll(_convertMessageToOpenAI(msg));
    }
    final provider = _detectOpenAICompatibleProvider();
    final thinkingEnabled = config.thinkingBudget > 0 &&
        provider == _OpenAICompatibleProvider.anthropicCompatible;
    final tokenLimitKey = _openAITokenLimitKey(provider);
    final body = <String, dynamic>{
      'model': modelIdFromDisplay(config.model),
      if (thinkingEnabled)
        'max_completion_tokens': config.thinkingBudget + config.maxTokens
      else
        tokenLimitKey: config.maxTokens,
      'messages': openaiMessages,
      'stream': stream,
      if (stream) 'stream_options': {'include_usage': true},
    };
    if (config.temperature != null && !_isReasoningModel(config.model)) {
      body['temperature'] = config.temperature;
    }
    if (tools.isNotEmpty) {
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

  static bool _isReasoningModel(String model) {
    final m = model.toLowerCase();
    return m.startsWith('o1') ||
        m.startsWith('o3') ||
        m.startsWith('o4') ||
        m.contains('gpt-5') ||
        m.contains('reasoning');
  }

  String _openAITokenLimitKey(_OpenAICompatibleProvider provider) {
    return switch (provider) {
      // Restore the pre-regression OpenAI parameter for native OpenAI models,
      // including reasoning/new-generation models that reject max_tokens.
      _OpenAICompatibleProvider.openaiNative => 'max_completion_tokens',
      _ => 'max_tokens',
    };
  }

  _OpenAICompatibleProvider _detectOpenAICompatibleProvider() {
    final baseUrl = config.baseUrl.toLowerCase();
    if (baseUrl.contains('anthropic') || baseUrl.contains('claude')) {
      return _OpenAICompatibleProvider.anthropicCompatible;
    }
    if (baseUrl.contains('openai.com')) {
      return _OpenAICompatibleProvider.openaiNative;
    }
    return _OpenAICompatibleProvider.generic;
  }

  List<Map<String, dynamic>> _convertMessageToOpenAI(Map<String, dynamic> msg) {
    final role = msg['role'] as String;
    final content = msg['content'];

    if (content is String) {
      return [
        {'role': role, 'content': content}
      ];
    }

    if (content is List) {
      final firstItem = content.isNotEmpty ? content[0] : null;
      if (firstItem is Map && firstItem['type'] == 'tool_result') {
        return content
            .where((item) => item is Map && item['type'] == 'tool_result')
            .map<Map<String, dynamic>>((item) {
          return {
            'role': 'tool',
            'tool_call_id': item['tool_use_id'],
            'content': item['content'] is String
                ? item['content']
                : jsonEncode(item['content']),
          };
        }).toList();
      }

      final textParts = <String>[];
      final contentParts = <Map<String, dynamic>>[];
      final toolCalls = <Map<String, dynamic>>[];
      var hasImage = false;
      for (final block in content) {
        if (block is Map) {
          if (block['type'] == 'text') {
            final text = block['text'] as String? ?? '';
            textParts.add(text);
            contentParts.add({'type': 'text', 'text': text});
          } else if (block['type'] == 'image') {
            final imageContent = _convertImageBlockToOpenAI(block);
            if (imageContent != null) {
              hasImage = true;
              contentParts.add(imageContent);
            }
          } else if (block['type'] == 'tool_use') {
            toolCalls.add({
              'id': block['id'],
              'type': 'function',
              'function': {
                'name': block['name'],
                'arguments': jsonEncode(block['input']),
              },
            });
          }
        }
      }
      if (hasImage && toolCalls.isEmpty) {
        return [
          {
            'role': role,
            'content': contentParts,
          }
        ];
      }
      final result = <String, dynamic>{
        'role': role,
        'content': textParts.join('\n'),
      };
      if (toolCalls.isNotEmpty) result['tool_calls'] = toolCalls;
      return [result];
    }

    return [
      {'role': role, 'content': content.toString()}
    ];
  }

  Map<String, dynamic>? _convertImageBlockToOpenAI(
      Map<dynamic, dynamic> block) {
    final imageUrl = block['image_url'];
    if (imageUrl is Map && imageUrl['url'] is String) {
      return {
        'type': 'image_url',
        'image_url': {'url': imageUrl['url'] as String},
      };
    }

    final source = block['source'];
    final sourceMap = source is Map ? source : const <String, dynamic>{};
    final mediaType = (sourceMap['media_type'] ??
        block['media_type'] ??
        'image/png') as String;
    final data = (sourceMap['data'] ?? block['data']) as String?;
    if (data == null || data.isEmpty) return null;

    return {
      'type': 'image_url',
      'image_url': {
        'url': 'data:$mediaType;base64,$data',
      },
    };
  }

  Map<String, String> _openaiHeaders() => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${config.apiKey}',
        'Accept-Encoding': 'identity',
      };

  LlmResponse _parseOpenAIResponse(Map<String, dynamic> json) {
    final choice = (json['choices'] as List)[0] as Map<String, dynamic>;
    final message = choice['message'] as Map<String, dynamic>;
    final finishReason = choice['finish_reason'] as String? ?? 'stop';

    final blocks = <ContentBlock>[];
    final content = message['content'] as String?;
    if (content != null && content.isNotEmpty) {
      blocks.add(ContentBlock(type: 'text', text: content));
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
        ));
      }
    }

    final mappedStopReason = switch (finishReason) {
      'tool_calls' => 'tool_use',
      'stop' => 'end_turn',
      'length' => 'max_tokens',
      _ => finishReason,
    };

    return LlmResponse(stopReason: mappedStopReason, content: blocks);
  }
}
