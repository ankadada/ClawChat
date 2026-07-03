import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../constants.dart';
import '../models/mcp_server_config.dart';
import 'llm_content_sanitizer.dart';

abstract class McpStdioProcess {
  Stream<String> get stdoutLines;
  Stream<String> get stderrLines;
  Future<int> get exitCode;
  void writeLine(String line);
  Future<void> closeStdin();
  bool kill();
}

typedef McpProcessStarter = Future<McpStdioProcess> Function(
  McpServerConfig config,
);

class DartMcpStdioProcess implements McpStdioProcess {
  final Process _process;

  DartMcpStdioProcess(this._process);

  @override
  Stream<String> get stdoutLines =>
      _process.stdout.transform(utf8.decoder).transform(const LineSplitter());

  @override
  Stream<String> get stderrLines =>
      _process.stderr.transform(utf8.decoder).transform(const LineSplitter());

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  void writeLine(String line) {
    _process.stdin.writeln(line);
  }

  @override
  Future<void> closeStdin() => _process.stdin.close();

  @override
  bool kill() => _process.kill();
}

class McpJsonRpcException implements Exception {
  final String message;
  final int? code;

  const McpJsonRpcException(this.message, {this.code});

  @override
  String toString() =>
      code == null ? 'MCP error: $message' : 'MCP error $code: $message';
}

class McpToolInfo {
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  const McpToolInfo({
    required this.name,
    required this.description,
    required this.inputSchema,
  });
}

class McpToolCallResult {
  final String output;
  final bool isError;
  final Map<String, dynamic> raw;

  const McpToolCallResult({
    required this.output,
    required this.isError,
    required this.raw,
  });
}

class McpStdioClient {
  final McpServerConfig config;
  final McpProcessStarter processStarter;
  final Duration requestTimeout;
  final Duration connectTimeout;

  McpStdioProcess? _process;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  final _pending = <Object, Completer<Object?>>{};
  final _stderrTail = StringBuffer();
  Future<void>? _connectFuture;
  var _nextId = 1;
  var _connectAttempt = 0;
  var _disposed = false;
  var _initialized = false;

  McpStdioClient({
    required this.config,
    required this.processStarter,
    this.requestTimeout = const Duration(seconds: 20),
    this.connectTimeout = const Duration(seconds: 10),
  });

  static Future<McpStdioProcess> defaultProcessStarter(
    McpServerConfig config,
  ) async {
    if (kIsWeb || defaultTargetPlatform == TargetPlatform.android) {
      throw UnsupportedError(
        'Stdio MCP servers are not available on Android in this build.',
      );
    }
    final process = await Process.start(
      config.command,
      config.args,
      environment: config.env.isEmpty ? null : config.env,
      includeParentEnvironment: true,
      runInShell: false,
    );
    return DartMcpStdioProcess(process);
  }

  String get sanitizedStderrTail => _stderrTail.toString();

  Future<void> connect() {
    if (_initialized) return Future.value();
    final existing = _connectFuture;
    if (existing != null) return existing;
    final attempt = ++_connectAttempt;
    final future = _connectWithCleanup(attempt);
    _connectFuture = future;
    return future;
  }

  Future<void> _connectWithCleanup(int attempt) async {
    try {
      await _connect(attempt).timeout(connectTimeout);
    } catch (_) {
      if (!_disposed) {
        _connectFuture = null;
        _initialized = false;
        await _cleanupFailedProcess();
      }
      rethrow;
    }
  }

  Future<void> _connect(int attempt) async {
    if (_disposed) throw StateError('MCP client disposed');
    final process = await processStarter(config);
    if (_disposed || attempt != _connectAttempt || _connectFuture == null) {
      try {
        await process.closeStdin().timeout(const Duration(milliseconds: 250));
      } catch (_) {}
      process.kill();
      throw StateError('MCP connection cancelled');
    }
    _process = process;
    _stdoutSub = process.stdoutLines.listen(
      _handleStdoutLine,
      onError: (Object error) {
        _completeAllPendingError('stdout error: $error');
      },
      cancelOnError: false,
    );
    _stderrSub = process.stderrLines.listen(
      _handleStderrLine,
      cancelOnError: false,
    );
    unawaited(process.exitCode.then((code) {
      if (_disposed) return;
      _completeAllPendingError('process exited with code $code');
    }));

    await _request('initialize', {
      'protocolVersion': '2025-03-26',
      'capabilities': const {},
      'clientInfo': {
        'name': AppConstants.appName,
        'version': AppConstants.version,
      },
    });
    _sendNotification('notifications/initialized', const {});
    _initialized = true;
  }

  Future<List<McpToolInfo>> listTools() async {
    await connect();
    final result = await _request('tools/list', const {});
    if (result is! Map) return const [];
    final tools = result['tools'];
    if (tools is! List) return const [];
    return tools
        .whereType<Map>()
        .map((tool) {
          final schema = tool['inputSchema'];
          return McpToolInfo(
            name: tool['name']?.toString() ?? '',
            description: tool['description']?.toString() ?? '',
            inputSchema: schema is Map
                ? Map<String, dynamic>.from(schema)
                : const {'type': 'object', 'properties': {}},
          );
        })
        .where((tool) => tool.name.trim().isNotEmpty)
        .toList(growable: false);
  }

  Future<McpToolCallResult> callTool(
    String toolName,
    Map<String, dynamic> arguments,
  ) async {
    await connect();
    final result = await _request('tools/call', {
      'name': toolName,
      'arguments': arguments,
    });
    final raw =
        result is Map ? Map<String, dynamic>.from(result) : <String, dynamic>{};
    return McpToolCallResult(
      output: _toolOutputText(result),
      isError: raw['isError'] == true,
      raw: raw,
    );
  }

  Future<void> dispose() async {
    _disposed = true;
    _connectFuture = null;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('MCP client disposed'));
      }
    }
    _pending.clear();
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    try {
      await _process?.closeStdin().timeout(const Duration(milliseconds: 250));
    } catch (_) {}
    _process?.kill();
  }

  Future<void> _cleanupFailedProcess() async {
    _completeAllPendingError('MCP connection failed');
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;
    final process = _process;
    _process = null;
    if (process == null) return;
    try {
      await process.closeStdin().timeout(const Duration(milliseconds: 250));
    } catch (_) {}
    process.kill();
  }

  Future<Object?> _request(
    String method,
    Map<String, dynamic> params,
  ) async {
    if (_disposed) throw StateError('MCP client disposed');
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _writeJson({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    });
    try {
      return await completer.future.timeout(requestTimeout);
    } on TimeoutException {
      _pending.remove(id);
      throw TimeoutException('MCP request timed out: $method', requestTimeout);
    }
  }

  void _sendNotification(String method, Map<String, dynamic> params) {
    if (_disposed) return;
    _writeJson({
      'jsonrpc': '2.0',
      'method': method,
      'params': params,
    });
  }

  void _writeJson(Map<String, dynamic> message) {
    final process = _process;
    if (process == null) throw StateError('MCP process not started');
    process.writeLine(jsonEncode(message));
  }

  void _handleStdoutLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;
    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (_) {
      _handleStderrLine('non-json stdout from MCP server');
      return;
    }
    if (decoded is List) {
      for (final item in decoded) {
        if (item is Map) _handleJsonRpcMessage(item);
      }
    } else if (decoded is Map) {
      _handleJsonRpcMessage(decoded);
    }
  }

  void _handleJsonRpcMessage(Map<dynamic, dynamic> message) {
    if (!message.containsKey('id')) return;
    final id = message['id'];
    if (id == null) return;
    final completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) return;

    final error = message['error'];
    if (error is Map) {
      final sanitized = const LlmContentSanitizer()
          .sanitizeText(error['message']?.toString() ?? 'request failed')
          .text;
      final code = error['code'] is num ? (error['code'] as num).toInt() : null;
      completer.completeError(McpJsonRpcException(sanitized, code: code));
      return;
    }
    completer.complete(message['result']);
  }

  void _handleStderrLine(String line) {
    final sanitized = const LlmContentSanitizer().sanitizeText(line).text;
    if (sanitized.trim().isEmpty) return;
    _stderrTail.writeln(sanitized);
    const max = 4000;
    if (_stderrTail.length > max) {
      final text = _stderrTail.toString();
      _stderrTail
        ..clear()
        ..write(text.substring(text.length - max));
    }
  }

  void _completeAllPendingError(String message) {
    final sanitized = const LlmContentSanitizer().sanitizeText(message).text;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError(sanitized));
      }
    }
    _pending.clear();
  }

  String _toolOutputText(Object? result) {
    if (result is! Map) return result?.toString() ?? '';
    final content = result['content'];
    if (content is List) {
      final parts = <String>[];
      for (final item in content) {
        if (item is Map && item['type'] == 'text') {
          parts.add(item['text']?.toString() ?? '');
        }
      }
      if (parts.isNotEmpty) return parts.join('\n');
    }
    return const JsonEncoder.withIndent('  ').convert(result);
  }
}
