import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../../models/chat_models.dart';
import '../app_http.dart';
import '../legacy_skill_compatibility.dart';
import '../preferences_service.dart';
import '../strict_json_decoder.dart';
import 'tool_registry.dart';
import 'tool_result_formatter.dart';

typedef XdsAgentRequestSender = Future<http.StreamedResponse> Function(
  http.BaseRequest request,
);

/// Fixed first-party adapter for the public xds-skills protocol.
///
/// This tool never executes the package's Python wrapper. The package supplies
/// instructions only; request construction, credential lookup, networking,
/// bounds, and cancellation remain app-owned.
final class XdsAgentTool extends Tool {
  XdsAgentTool(
    this._preferences, {
    AppHttpClient? httpClient,
    @visibleForTesting XdsAgentRequestSender? requestSender,
    Duration timeout = const Duration(seconds: 180),
  })  : _injectedClient = httpClient,
        _requestSender = requestSender,
        _timeout = timeout;

  static final Uri _origin = Uri.parse('https://ai-xds.tapdb.net');
  static const int maxResponseBytes = 512 * 1024;

  final PreferencesService _preferences;
  final AppHttpClient? _injectedClient;
  final XdsAgentRequestSender? _requestSender;
  final Duration _timeout;

  AppHttpClient get _client =>
      _injectedClient ?? AppHttpClientRegistry.instance.client;

  @override
  String get name => LegacySkillCompatibility.xdsToolName;

  @override
  String get description =>
      'Fixed first-party AI-XDS operations: list, get, files, kb, exec. '
      'No arbitrary URL or local shell.';

  @override
  Map<String, dynamic> get inputSchema => {
        'type': 'object',
        'properties': {
          'operation': {
            'type': 'string',
            'enum': ['list', 'get', 'files', 'kb', 'exec'],
          },
          'skill': {'type': 'string'},
          'path': {'type': 'string'},
          // Model responses frequently preserve numeric IDs from the XDS
          // response JSON. Normalize those bounded integers before building
          // the request instead of rejecting an otherwise valid workflow.
          'project_id': {
            'type': ['string', 'integer'],
            'pattern': r'^[0-9]{1,20}$',
            'minimum': 0,
          },
          'app_id': {
            'type': ['string', 'integer'],
            'pattern': r'^[0-9]{1,20}$',
            'minimum': 0,
          },
          'command': {'type': 'string'},
          'user_query': {'type': 'string'},
          'intent': {'type': 'string'},
        },
        'required': ['operation'],
        'oneOf': [
          {
            'properties': {
              'operation': {
                'enum': ['list'],
              },
            },
          },
          {
            'properties': {
              'operation': {
                'enum': ['get', 'files'],
              },
            },
            'required': ['skill'],
          },
          {
            'properties': {
              'operation': {
                'enum': ['kb'],
              },
            },
            'required': ['skill', 'project_id'],
          },
          {
            'properties': {
              'operation': {
                'enum': ['exec'],
              },
            },
            'required': ['skill', 'command'],
          },
        ],
        'additionalProperties': false,
      };

  @override
  Future<String> execute(Map<String, dynamic> input) async {
    final result = await _execute(
      input,
      sessionId: null,
      operationId: const Uuid().v4(),
      cancellationSignal: null,
    );
    return result.output;
  }

  @override
  Future<ToolResultPayload> executeResultWithOperationAndCancellation(
    Map<String, dynamic> input, {
    String? sessionId,
    required String operationId,
    required ToolCancellationSignal cancellationSignal,
  }) async {
    final result = await _execute(
      input,
      sessionId: sessionId,
      operationId: operationId,
      cancellationSignal: cancellationSignal,
    );
    return ToolResultFormatter.format(
      toolName: name,
      input: input,
      output: result.output,
      isError: result.isError,
    );
  }

  Future<_XdsAgentResult> _execute(
    Map<String, dynamic> input, {
    required String? sessionId,
    required String operationId,
    required ToolCancellationSignal? cancellationSignal,
  }) async {
    late final _XdsAgentInvocation invocation;
    try {
      invocation = _XdsAgentInvocation.parse(input);
    } on FormatException {
      return const _XdsAgentResult.error(
        'XDS request rejected: invalid operation arguments.',
      );
    }

    cancellationSignal?.throwIfCancellationRequested();
    try {
      await _preferences.init();
    } catch (_) {
      return const _XdsAgentResult.error(
        'XDS request unavailable: secure preferences are unavailable.',
      );
    }
    final token =
        _preferences.envVars[LegacySkillCompatibility.xdsTokenName]?.trim();
    if (token == null || token.isEmpty) {
      return const _XdsAgentResult.error(
        'XDS request unavailable: XDS_AGENT_TOKEN is not configured.',
      );
    }

    final correlationId = _correlationId(sessionId, operationId);
    final abort = Completer<void>();
    final request = invocation.toRequest(
      origin: _origin,
      token: token,
      correlationId: correlationId,
      abortTrigger: abort.future,
    );
    if (cancellationSignal != null) {
      unawaited(cancellationSignal.whenCancelled.then((_) {
        if (!abort.isCompleted) abort.complete();
      }));
    }
    var dispatched = false;
    final stopwatch = Stopwatch()..start();
    try {
      dispatched = true;
      final response = await (_requestSender ?? _client.send)(request).timeout(
        _timeout,
        onTimeout: () {
          if (!abort.isCompleted) abort.complete();
          throw TimeoutException('xds_request_timeout');
        },
      );
      final remaining = _timeout - stopwatch.elapsed;
      if (remaining <= Duration.zero) {
        if (!abort.isCompleted) abort.complete();
        throw TimeoutException('xds_request_timeout');
      }
      final bytes = await _readBounded(response.stream, abort).timeout(
        remaining,
        onTimeout: () {
          if (!abort.isCompleted) abort.complete();
          throw TimeoutException('xds_response_timeout');
        },
      );
      if (cancellationSignal?.isCancellationRequested == true) {
        throw ToolExecutionCancelledException(
          sideEffectsPrevented: invocation.operation != 'exec',
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return _XdsAgentResult.error(
          'XDS request failed (HTTP ${response.statusCode}).',
        );
      }
      final decoded = const StrictJsonDecoder(
        maxUtf8Bytes: maxResponseBytes,
        maxNestingDepth: 32,
      ).decodeBytes(bytes);
      if (decoded is! Map) {
        return const _XdsAgentResult.error(
          'XDS response rejected: expected a JSON object.',
        );
      }
      var output = jsonEncode(decoded);
      if (token.isNotEmpty) output = output.replaceAll(token, '[REDACTED]');
      return _XdsAgentResult.success(output);
    } on ToolExecutionCancelledException {
      rethrow;
    } on TimeoutException {
      if (!abort.isCompleted) abort.complete();
      return _XdsAgentResult.error(invocation.operation == 'exec' && dispatched
          ? 'XDS execution timed out; outcome is unknown. Do not retry automatically.'
          : 'XDS request timed out before a result was received.');
    } on StrictJsonDecodeException {
      return const _XdsAgentResult.error(
        'XDS response rejected: invalid bounded JSON.',
      );
    } on _XdsResponseTooLarge {
      if (!abort.isCompleted) abort.complete();
      return const _XdsAgentResult.error(
        'XDS response rejected: response exceeds the app limit.',
      );
    } catch (_) {
      if (cancellationSignal?.isCancellationRequested == true) {
        throw ToolExecutionCancelledException(
          sideEffectsPrevented: invocation.operation != 'exec' || !dispatched,
        );
      }
      return const _XdsAgentResult.error('XDS request failed.');
    }
  }

  Future<List<int>> _readBounded(
    Stream<List<int>> stream,
    Completer<void> abort,
  ) async {
    final bytes = <int>[];
    await for (final chunk in stream) {
      if (bytes.length + chunk.length > maxResponseBytes) {
        if (!abort.isCompleted) abort.complete();
        throw const _XdsResponseTooLarge();
      }
      bytes.addAll(chunk);
    }
    return bytes;
  }

  static String _correlationId(String? sessionId, String operationId) {
    final source =
        sessionId?.trim().isNotEmpty == true ? sessionId!.trim() : operationId;
    final digest = sha256.convert(utf8.encode(source)).toString();
    return 'clawchat-${digest.substring(0, 24)}';
  }
}

final class _XdsAgentInvocation {
  const _XdsAgentInvocation({
    required this.operation,
    this.skill,
    this.path,
    this.projectId,
    this.appId,
    this.command,
    this.userQuery,
    this.intent,
  });

  final String operation;
  final String? skill;
  final String? path;
  final String? projectId;
  final String? appId;
  final String? command;
  final String? userQuery;
  final String? intent;

  factory _XdsAgentInvocation.parse(Map<String, dynamic> input) {
    final operation = _requiredString(input, 'operation', 16);
    final allowed = switch (operation) {
      'list' => const {'operation', 'app_id'},
      'get' => const {'operation', 'skill', 'app_id'},
      'files' => const {'operation', 'skill', 'path'},
      'kb' => const {'operation', 'skill', 'project_id', 'path'},
      'exec' => const {
          'operation',
          'skill',
          'command',
          'app_id',
          'user_query',
          'intent',
        },
      _ => throw const FormatException('unsupported operation'),
    };
    if (input.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException('unknown field');
    }

    final skill = operation == 'list'
        ? null
        : _requiredString(input, 'skill', 100, pattern: _skillNamePattern);
    final appId = _optionalIdentifier(input, 'app_id', 20);
    return _XdsAgentInvocation(
      operation: operation,
      skill: skill,
      path: _optionalRelativePath(input, 'path'),
      projectId: operation == 'kb'
          ? _requiredIdentifier(input, 'project_id', 20)
          : null,
      appId: appId,
      command:
          operation == 'exec' ? _requiredString(input, 'command', 4096) : null,
      userQuery: operation == 'exec'
          ? _optionalString(input, 'user_query', 4000) ??
              'User-requested XDS skill operation.'
          : null,
      intent: operation == 'exec'
          ? _optionalString(input, 'intent', 1000) ??
              'Execute the requested XDS skill command.'
          : null,
    );
  }

  http.AbortableRequest toRequest({
    required Uri origin,
    required String token,
    required String correlationId,
    required Future<void> abortTrigger,
  }) {
    final pathSegments = <String>['open-skills'];
    final query = <String, String>{};
    if (appId != null) query['app_id'] = appId!;
    switch (operation) {
      case 'get':
        {
          pathSegments.add(skill!);
          break;
        }
      case 'files':
        {
          pathSegments.addAll([skill!, 'files', ...?_splitPath(path)]);
          break;
        }
      case 'kb':
        {
          pathSegments.addAll([
            skill!,
            'kb',
            projectId!,
            ...?_splitPath(path),
          ]);
          break;
        }
      case 'exec':
        {
          pathSegments.add('execute');
          break;
        }
      case 'list':
        {
          break;
        }
    }
    final uri = origin.replace(
      pathSegments: pathSegments,
      queryParameters: query.isEmpty ? null : query,
    );
    final request = http.AbortableRequest(
      operation == 'exec' ? 'POST' : 'GET',
      uri,
      abortTrigger: abortTrigger,
    )
      ..followRedirects = false
      ..persistentConnection = false
      ..headers['Authorization'] = 'Bearer $token'
      ..headers['Accept'] = 'application/json';
    if (operation == 'files' || operation == 'kb') {
      request.headers['X-XDS-Session-Id'] = correlationId;
    }
    if (operation == 'exec') {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode({
        'session_id': correlationId,
        'skill': skill,
        'command': command,
        if (appId != null) 'app_id': appId,
        'user_query': userQuery,
        'intent': intent,
      });
    }
    return request;
  }

  static List<String>? _splitPath(String? path) => path?.split('/');

  static String _requiredString(
    Map<String, dynamic> input,
    String key,
    int max, {
    RegExp? pattern,
  }) {
    final value = input[key];
    if (value is! String ||
        value.isEmpty ||
        value.length > max ||
        _hasForbiddenControl(value) ||
        pattern != null && !pattern.hasMatch(value)) {
      throw FormatException('invalid $key');
    }
    return value;
  }

  static String? _optionalString(
    Map<String, dynamic> input,
    String key,
    int max, {
    RegExp? pattern,
  }) {
    if (!input.containsKey(key)) return null;
    return _requiredString(input, key, max, pattern: pattern);
  }

  static String _requiredIdentifier(
    Map<String, dynamic> input,
    String key,
    int max,
  ) {
    if (!input.containsKey(key)) throw FormatException('missing $key');
    final value = input[key];
    final normalized = value is int ? value.toString() : value;
    if (normalized is! String ||
        normalized.isEmpty ||
        normalized.length > max ||
        _hasForbiddenControl(normalized) ||
        !_idPattern.hasMatch(normalized)) {
      throw FormatException('invalid $key');
    }
    return normalized;
  }

  static String? _optionalIdentifier(
    Map<String, dynamic> input,
    String key,
    int max,
  ) {
    if (!input.containsKey(key)) return null;
    return _requiredIdentifier(input, key, max);
  }

  static String? _optionalRelativePath(
    Map<String, dynamic> input,
    String key,
  ) {
    final path = _optionalString(input, key, 512);
    if (path == null) return null;
    if (path.startsWith('/') || path.contains(r'\')) {
      throw const FormatException('invalid path');
    }
    final segments = path.split('/');
    if (segments.length > 16 ||
        segments.any((segment) =>
            segment.isEmpty || segment == '.' || segment == '..')) {
      throw const FormatException('invalid path');
    }
    return path;
  }

  static bool _hasForbiddenControl(String value) =>
      RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]').hasMatch(value);

  static final _skillNamePattern = RegExp(r'^[a-z0-9][a-z0-9._-]{0,99}$');
  static final _idPattern = RegExp(r'^[0-9]{1,20}$');
}

final class _XdsAgentResult {
  const _XdsAgentResult._(this.output, this.isError);

  const _XdsAgentResult.success(String output) : this._(output, false);
  const _XdsAgentResult.error(String output) : this._(output, true);

  final String output;
  final bool isError;
}

final class _XdsResponseTooLarge implements Exception {
  const _XdsResponseTooLarge();
}
