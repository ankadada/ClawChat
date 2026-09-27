import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../constants.dart';
import '../models/mcp_server_config.dart';
import 'llm_content_sanitizer.dart';
import 'mcp_stdio_line_transformer.dart';

abstract class McpStdioProcess {
  Stream<String> get stdoutLines;
  Stream<String> get stderrLines;
  Future<int> get exitCode;

  /// Writes one JSON-RPC frame. Completes only after the frame reached the
  /// child, and completes with an error when the write failed.
  Future<void> writeLine(String line);

  Future<void> closeStdin();
  bool kill();
}

/// Shared MCP stdio bounds. The native reader/writer mirrors these values;
/// keep both sides in sync when changing one.
class McpStdioLimits {
  const McpStdioLimits._();

  /// One stdout/stderr line may not exceed this many UTF-8 bytes.
  ///
  /// Matching the Android reader (ProcessManager.MCP_MAX_LINE_BYTES): an
  /// over-limit line fails the stream instead of being buffered whole.
  static const int maxLineBytes = 1024 * 1024;

  /// One stdin frame may not exceed this many UTF-8 bytes.
  ///
  /// The frame is the payload plus its newline terminator, which is the same
  /// unit the native writer measures (ProcessManager.MCP_MAX_STDIN_LINE_BYTES).
  static const int maxStdinLineBytes = 1024 * 1024;
}

/// A stdin frame could not be delivered to the MCP child.
class McpStdinWriteException implements Exception {
  final String message;

  const McpStdinWriteException(this.message);

  @override
  String toString() => 'MCP stdin write failed: $message';
}

typedef McpProcessStarter = Future<McpStdioProcess> Function(
  McpServerConfig config,
);

class DartMcpStdioProcess implements McpStdioProcess {
  final Process _process;

  DartMcpStdioProcess(this._process);

  /// Bounded before it is split: a child that never terminates a line must not
  /// be able to grow this process's memory. Android runs the same cap natively
  /// on the same pipes (see ProcessManager.readMcpStream).
  @override
  Stream<String> get stdoutLines => _process.stdout.transform(
        const BoundedUtf8LineTransformer(
          maxLineBytes: McpStdioLimits.maxLineBytes,
          streamName: 'stdout',
        ),
      );

  @override
  Stream<String> get stderrLines => _process.stderr.transform(
        const BoundedUtf8LineTransformer(
          maxLineBytes: McpStdioLimits.maxLineBytes,
          streamName: 'stderr',
        ),
      );

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  Future<void> writeLine(String line) async {
    try {
      _process.stdin.write('$line\n');
      await _process.stdin.flush();
    } catch (error) {
      throw McpStdinWriteException('$error');
    }
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

  /// Serializes stdin frames for this client, exactly like the native writer
  /// serializes them per child. Two call sites must never interleave a frame.
  Future<void> _writeChain = Future<void>.value();
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
        // A stale child's stream must not tear the live connection down.
        if (!identical(_process, process)) return;
        _handleStreamFailure('stdout', error);
      },
      cancelOnError: false,
    );
    _stderrSub = process.stderrLines.listen(
      _handleStderrLine,
      onError: (Object error) {
        if (!identical(_process, process)) return;
        _handleStreamFailure('stderr', error);
      },
      cancelOnError: false,
    );
    unawaited(process.exitCode.then((code) {
      if (_disposed) return;
      // A stale child (a failed attempt already replaced by a new one) must not
      // reset the live connection's state.
      if (!identical(_process, process)) return;
      // A run-scoped MCP child dies with its run. Pending requests settle now,
      // and the next call starts a fresh child instead of writing into a
      // process that is gone.
      _completeAllPendingError('process exited with code $code');
      _dropChild();
    }));

    await _request('initialize', {
      'protocolVersion': '2025-03-26',
      'capabilities': const {},
      'clientInfo': {
        'name': AppConstants.appName,
        'version': AppConstants.version,
      },
    });
    await _sendNotification('notifications/initialized', const {});
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
    // The frame is written before this future is awaited. A child that dies in
    // that window (or a write failure that settles every pending request) would
    // otherwise complete the future with an error that no listener has seen
    // yet, which the zone reports as an unhandled async error.
    unawaited(completer.future.then((_) {}, onError: (Object _) {}));
    _pending[id] = completer;
    try {
      await _writeJson({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      });
    } catch (error) {
      // A frame that never reached the child can never be answered, so this
      // request must fail now instead of waiting for the request timeout.
      _pending.remove(id);
      final failure = error is McpStdinWriteException
          ? error
          : McpStdinWriteException('$error');
      _failPendingAfterWriteFailure(failure);
      throw failure;
    }
    try {
      return await completer.future.timeout(requestTimeout);
    } on TimeoutException {
      _pending.remove(id);
      throw TimeoutException('MCP request timed out: $method', requestTimeout);
    }
  }

  Future<void> _sendNotification(
    String method,
    Map<String, dynamic> params,
  ) async {
    if (_disposed) return;
    try {
      await _writeJson({
        'jsonrpc': '2.0',
        'method': method,
        'params': params,
      });
    } catch (error) {
      _failPendingAfterWriteFailure(
        error is McpStdinWriteException
            ? error
            : McpStdinWriteException('$error'),
      );
      rethrow;
    }
  }

  Future<void> _writeJson(Map<String, dynamic> message) {
    final process = _process;
    if (process == null) throw StateError('MCP process not started');
    final encoded = jsonEncode(message);
    // The cap covers the frame as it goes on the wire: payload plus newline.
    if (utf8.encode(encoded).length + 1 > McpStdioLimits.maxStdinLineBytes) {
      throw const McpStdinWriteException(
        'frame exceeds ${McpStdioLimits.maxStdinLineBytes} UTF-8 bytes',
      );
    }
    // One frame at a time: concurrent requests must not interleave bytes on the
    // child's stdin. A failed frame is reported to its caller and the chain
    // stays usable, so one failure cannot corrupt a later frame.
    final next = _writeChain.then((_) => process.writeLine(encoded));
    _writeChain = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  /// A bounded stdio stream failed: an over-limit line, a decode error, or a
  /// broken pipe. The child cannot be trusted to answer again, so every pending
  /// request settles now and the child is stopped instead of leaving callers on
  /// the request timeout.
  void _handleStreamFailure(String stream, Object error) {
    final sanitized = const LlmContentSanitizer().sanitizeText('$error').text;
    _completeAllPendingError('$stream stream failed: $sanitized');
    _dropChild();
  }

  /// Settles every pending request when a stdin frame cannot be delivered and
  /// tears the broken child down, so the next call starts a fresh one.
  void _failPendingAfterWriteFailure(Object error) {
    final sanitized = const LlmContentSanitizer().sanitizeText('$error').text;
    _completeAllPendingError(sanitized);
    _dropChild();
  }

  /// Forgets the live child, stops listening to it, and kills it. The next call
  /// reconnects through [connect].
  void _dropChild() {
    _initialized = false;
    _connectFuture = null;
    final process = _process;
    _process = null;
    final stdoutSub = _stdoutSub;
    final stderrSub = _stderrSub;
    _stdoutSub = null;
    _stderrSub = null;
    unawaited(stdoutSub?.cancel() ?? Future<void>.value());
    unawaited(stderrSub?.cancel() ?? Future<void>.value());
    _writeChain = Future<void>.value();
    process?.kill();
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
