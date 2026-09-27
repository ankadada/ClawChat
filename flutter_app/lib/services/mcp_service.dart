import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../models/chat_models.dart';
import '../models/mcp_server_config.dart';
import 'llm_content_sanitizer.dart';
import 'mcp_proot_bridge.dart';
import 'mcp_stdio_client.dart';
import 'preferences_service.dart';
import 'tools/tool_registry.dart';
import 'tools/tool_result_formatter.dart';
import 'tools/untrusted_data_policy.dart';

/// One MCP server that could not be started or listed, with a reason the user
/// can see. A failed start is a visible error, never a silently empty tool
/// list.
@immutable
class McpServerFailure {
  final String serverId;
  final String displayName;
  final String reasonCode;
  final String message;

  const McpServerFailure({
    required this.serverId,
    required this.displayName,
    required this.reasonCode,
    required this.message,
  });
}

void _logMcpEvent(String message) {
  if (kDebugMode) {
    debugPrint('[mcp] $message');
  }
}

class McpService {
  final PreferencesService prefs;
  final bool stdioSupported;
  final Duration requestTimeout;
  final Duration connectTimeout;
  /// MCP clients keyed by `(runId, serverId)`, matching the native
  /// `McpStdioRegistry`. A single slot keyed by server id would let a second
  /// concurrent run dispose the first run's live child.
  final Map<String, _McpClientEntry> _clients = {};

  /// I5: run-scoped proot bridge. Non-null when this platform needs the
  /// Android proot stdio bridge (Android). Desktop keeps `dart:io` processes.
  final McpProotBridge? _bridge;

  /// How a server process is started outside the proot bridge: the injected
  /// starter (tests) or the platform default host process.
  late final McpProcessStarter processStarter;

  /// True when the caller injected its own starter, so the proot bridge must
  /// stay out of the way.
  final bool _usesInjectedStarter;

  /// The run that currently owns MCP children, set by [beginRun].
  String? _activeRunId;


  /// Failures from the most recent [loadTools]. Settings shows these instead of
  /// pretending the server does not exist.
  List<McpServerFailure> _lastLoadFailures = const [];
  List<McpServerFailure> get lastLoadFailures =>
      List.unmodifiable(_lastLoadFailures);

  McpService({
    required this.prefs,
    McpProcessStarter? processStarter,
    bool? stdioSupported,
    this.requestTimeout = const Duration(seconds: 20),
    this.connectTimeout = const Duration(seconds: 10),
  })  : stdioSupported = stdioSupported ?? McpPlatformSupport.isStdioSupported,
        // An injected process starter means the caller owns process management
        // (tests, or a future non-proot runtime); the platform bridge is only
        // used when the service itself must start the guest child.
        _usesInjectedStarter = processStarter != null,
        _bridge = (stdioSupported == false ||
                processStarter != null ||
                !McpPlatformSupport.requiresProotBridge)
            ? null
            : McpProotBridge(
                host: NativeMcpProotProcessHost(),
                readinessProbe: const NativeMcpProotReadinessProbe().call,
              ) {
    this.processStarter =
        processStarter ?? McpPlatformSupport.defaultProcessStarter();
  }

  /// The starter for one client. On Android the proot child is started for the
  /// exact run that owns the client, so two runs never share a start slot.
  McpProcessStarter _starterFor(String runId) {
    final bridge = _bridge;
    if (bridge == null || _usesInjectedStarter) return processStarter;
    return (config) => bridge.start(config, runId: runId);
  }

  /// Opens a run scope. MCP children started after this belong to [runId] and
  /// are killed by [endRun].
  String beginRun({String? sessionId}) {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final suffix = (sessionId ?? 'session').trim();
    final runId = 'mcp-run:$suffix:$stamp';
    _activeRunId = runId;
    return runId;
  }

  String get activeRunId => _activeRunId ?? '';

  /// Kills every child owned by [runId] and drops its clients. Called when the
  /// run ends, is cancelled, or the foreground lease drops.
  Future<void> endRun(String runId) async {
    // Only this run's clients, keyed by (runId, serverId): another run's live
    // child must survive.
    final stale = _clients.keys
        .where((key) => _clientEntry(key)?.runId == runId)
        .toList();
    for (final key in stale) {
      final client = _clients.remove(key)?.client;
      await client?.dispose();
    }
    await _bridge?.endRun(runId);
    if (_activeRunId == runId) _activeRunId = null;
  }

  Future<List<McpTool>> loadTools({String? runId}) async {
    if (!stdioSupported) {
      await dispose();
      _lastLoadFailures = [
        const McpServerFailure(
          serverId: '',
          displayName: 'MCP',
          reasonCode: 'stdio_unsupported',
          message: McpPlatformSupport.unsupportedMessage,
        ),
      ];
      return const [];
    }
    final enabled = prefs.mcpServers.where((server) => server.enabled).toList();
    final enabledIds = enabled.map((server) => server.id).toSet();

    final failures = <McpServerFailure>[];
    final tools = <McpTool>[];
    // A null run id must never resolve to a live run's scope: it could not
    // start, dispose, or reconnect that run's client. Callers without a run
    // scope (app init, settings, the pre-loop refresh) get no tools; the agent
    // loop refreshes inside its own scope (see AgentService.runAgentLoop).
    final effectiveRunId = runId;
    if (effectiveRunId == null || effectiveRunId.isEmpty) {
      _lastLoadFailures = const [];
      return const [];
    }
    // A server that is no longer enabled (or was removed) must not keep a child
    // alive for this run. Other runs keep their own entries.
    final staleKeys = _clients.keys
        .where((key) =>
            _clientEntry(key)?.runId == effectiveRunId &&
            !enabledIds.contains(_serverIdFromKey(key)))
        .toList();
    for (final key in staleKeys) {
      await _clients.remove(key)?.client.dispose();
    }
    for (final server in enabled) {
      try {
        final client = await _clientFor(server, runId: effectiveRunId);
          final serverTools = await client.listTools();
          for (final info in serverTools) {
            tools.add(McpTool(
              service: this,
              server: server,
              serverTool: info,
              runId: effectiveRunId,
            ));
          }
        } on McpBridgeException catch (error) {
          failures.add(McpServerFailure(
            serverId: server.id,
            displayName: server.displayName,
            reasonCode: error.reasonCode,
            message: error.message,
          ));
          _logMcpEvent(
              'MCP server ${server.id} not started: ${error.reasonCode}');
        } on TimeoutException catch (error) {
          failures.add(McpServerFailure(
            serverId: server.id,
            displayName: server.displayName,
            reasonCode: 'mcp_timeout',
            message: 'MCP 服务器响应超时：${error.message ?? ''}'.trim(),
          ));
          _logMcpEvent('MCP server ${server.id} timed out');
        } catch (error) {
          failures.add(McpServerFailure(
            serverId: server.id,
            displayName: server.displayName,
            reasonCode: 'mcp_start_failed',
            message: 'MCP 服务器启动失败：$error',
          ));
        _logMcpEvent('MCP server ${server.id} failed: $error');
      }
    }
    _lastLoadFailures = List.unmodifiable(failures);
    return tools;
  }

  Future<ToolResultPayload> callTool({
    required McpServerConfig server,
    required McpToolInfo tool,
    required String mappedName,
    required Map<String, dynamic> arguments,
    String? sessionId,
    String? runId,
  }) async {
    if (!stdioSupported) {
      return ToolResultFormatter.generic(
        toolName: mappedName,
        output: McpPlatformSupport.unsupportedMessage,
        isError: true,
        limit: 4000,
      );
    }
    // The run that enumerated this tool owns its child. There is deliberately
    // no `_activeRunId` fallback: a call must never reach, or start a child in,
    // a run it does not belong to.
    final effectiveRunId = runId;
    if (effectiveRunId == null || effectiveRunId.isEmpty) {
      return ToolResultFormatter.generic(
        toolName: mappedName,
        output: 'MCP 工具只能在 agent 运行范围内调用。',
        isError: true,
        limit: 4000,
      );
    }
    try {
      final client = await _clientFor(server, runId: effectiveRunId);
      final result = await client.callTool(tool.name, arguments);
      final sanitized = _boundedSanitizedOutput(result.output);
      final payload = ToolResultFormatter.generic(
        toolName: mappedName,
        output: sanitized,
        isError: result.isError,
      );
      // I5: every MCP result enters the existing untrusted-data deny engine.
      return payload.copyWith(
        metadata: {
          ...payload.metadata,
          'mcpServerId': server.id,
          'mcpServerName': server.displayName,
          'mcpToolName': tool.name,
          'status': result.isError ? 'error' : 'success',
          'trust': 'untrusted',
          'untrustedSource': UntrustedSource.mcp.name,
        },
      );
    } on McpBridgeException catch (error) {
      return ToolResultFormatter.generic(
        toolName: mappedName,
        output: error.message,
        isError: true,
        limit: 4000,
      );
    } catch (error) {
      return ToolResultFormatter.generic(
        toolName: mappedName,
        output: 'MCP 工具调用失败：$error',
        isError: true,
        limit: 4000,
      );
    }
  }

  Future<void> dispose() async {
    final clients = _clients.values.map((entry) => entry.client).toList();
    _clients.clear();
    await Future.wait(clients.map((client) => client.dispose()));
    await _bridge?.endAll();
    _activeRunId = null;
  }

  Future<McpStdioClient> _clientFor(
    McpServerConfig server, {
    String? runId,
  }) async {
    final effectiveRunId = runId;
    if (effectiveRunId == null || effectiveRunId.isEmpty) {
      throw StateError('MCP clients require a run scope');
    }
    final fingerprint = jsonEncode(server.toJson());
    final key = _clientKey(effectiveRunId, server.id);
    final existing = _clients[key];
    if (existing != null &&
        existing.fingerprint == fingerprint &&
        existing.runId == effectiveRunId) {
      try {
        await existing.client.connect();
        return existing.client;
      } catch (_) {
        if (_clients[key]?.client == existing.client) {
          _clients.remove(key);
        }
        await existing.client.dispose();
        rethrow;
      }
    }

    await existing?.client.dispose();
    final client = McpStdioClient(
      config: server,
      processStarter: _starterFor(effectiveRunId),
      requestTimeout: requestTimeout,
      connectTimeout: connectTimeout,
    );
    _clients[key] = _McpClientEntry(
      fingerprint: fingerprint,
      runId: effectiveRunId,
      client: client,
    );
    try {
      await client.connect();
      return client;
    } catch (_) {
      if (_clients[key]?.client == client) {
        _clients.remove(key);
      }
      await client.dispose();
      rethrow;
    }
  }

  /// Cache key matching the native registry's `(runId, serverId)` pair.
  static String _clientKey(String runId, String serverId) =>
      '$runId\u0000$serverId';

  static String _serverIdFromKey(String key) {
    final separator = key.indexOf('\u0000');
    return separator < 0 ? key : key.substring(separator + 1);
  }

  _McpClientEntry? _clientEntry(String key) => _clients[key];

  String _boundedSanitizedOutput(String output) {
    final sanitized = const LlmContentSanitizer().sanitizeText(output).text;
    const limit = 50000;
    if (sanitized.length <= limit) return sanitized;
    return '${sanitized.substring(0, limit)}\n\n'
        '[MCP output truncated, original length: ${sanitized.length} chars]';
  }
}

class McpPlatformSupport {
  const McpPlatformSupport._();

  /// Whether stdio MCP is a supported feature on this platform. Android is
  /// supported because the I5 proot bridge exists; whether the bridge can
  /// actually start a child depends on Alpine readiness, which is reported by
  /// [readiness] and by a visible failure at start time.
  static bool get isStdioSupported => !kIsWeb;

  /// Android needs the proot stdio bridge instead of a host `dart:io` process.
  static bool get requiresProotBridge =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static McpProcessStarter defaultProcessStarter() =>
      McpStdioClient.defaultProcessStarter;

  /// Probes the Alpine runtime. Used by settings to explain why servers are not
  /// running instead of showing an empty list.
  static Future<McpProotReadiness> readiness() {
    if (!requiresProotBridge) {
      return Future.value(const McpProotReadiness.ready());
    }
    return const NativeMcpProotReadinessProbe().call();
  }

  static const unsupportedMessage =
      'Stdio MCP servers are not available on this platform in this build.';
}

class McpTool extends Tool {
  final McpService service;
  final McpServerConfig server;
  final McpToolInfo serverTool;

  /// The run that enumerated this tool. Its MCP child belongs to that run, so
  /// a call from this tool reaches the right child even while another run is
  /// active.
  final String runId;
  late final String _name = McpToolNames.mappedName(server, serverTool.name);

  McpTool({
    required this.service,
    required this.server,
    required this.serverTool,
    this.runId = '',
  });

  @override
  String get name => _name;

  @override
  String get description {
    final desc = serverTool.description.trim();
    final suffix = desc.isEmpty ? serverTool.name : desc;
    return 'MCP ${server.displayName}: $suffix';
  }

  @override
  Map<String, dynamic> get inputSchema => serverTool.inputSchema;

  @override
  Future<String> execute(Map<String, dynamic> input) async {
    final payload = await executeResult(input);
    return payload.forUser;
  }

  @override
  Future<ToolResultPayload> executeResult(
    Map<String, dynamic> input, {
    String? sessionId,
    RunTaintSet? runTaintSet,
  }) {
    return service.callTool(
      server: server,
      tool: serverTool,
      mappedName: name,
      arguments: input,
      sessionId: sessionId,
      runId: runId,
    );
  }
}

class McpToolNames {
  const McpToolNames._();

  static String mappedName(McpServerConfig server, String toolName) {
    final serverHash = _hash(server.id, 8);
    final toolPart = _sanitize(toolName, fallback: 'tool', max: 40);
    final toolHash = _hash(toolName, 8);
    return 'mcp_${serverHash}_${toolPart}_$toolHash';
  }

  static String _sanitize(
    String value, {
    required String fallback,
    required int max,
  }) {
    final sanitized = value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    final safe = sanitized.isEmpty ? fallback : sanitized;
    return safe.length <= max ? safe : safe.substring(0, max);
  }

  static String _hash(String value, int chars) {
    return sha1.convert(utf8.encode(value)).toString().substring(0, chars);
  }
}

class _McpClientEntry {
  final String fingerprint;
  final String runId;
  final McpStdioClient client;

  const _McpClientEntry({
    required this.fingerprint,
    required this.runId,
    required this.client,
  });
}
