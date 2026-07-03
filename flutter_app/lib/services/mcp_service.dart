import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../models/chat_models.dart';
import '../models/mcp_server_config.dart';
import 'llm_content_sanitizer.dart';
import 'mcp_stdio_client.dart';
import 'preferences_service.dart';
import 'tools/tool_registry.dart';
import 'tools/tool_result_formatter.dart';

class McpService {
  final PreferencesService prefs;
  final McpProcessStarter processStarter;
  final bool stdioSupported;
  final Duration requestTimeout;
  final Duration connectTimeout;
  final Map<String, _McpClientEntry> _clients = {};

  McpService({
    required this.prefs,
    this.processStarter = McpStdioClient.defaultProcessStarter,
    bool? stdioSupported,
    this.requestTimeout = const Duration(seconds: 20),
    this.connectTimeout = const Duration(seconds: 10),
  }) : stdioSupported = stdioSupported ?? McpPlatformSupport.isStdioSupported;

  Future<List<McpTool>> loadTools() async {
    if (!stdioSupported) {
      await dispose();
      return const [];
    }
    final enabled = prefs.mcpServers.where((server) => server.enabled).toList();
    final enabledIds = enabled.map((server) => server.id).toSet();
    final staleIds =
        _clients.keys.where((id) => !enabledIds.contains(id)).toList();
    for (final id in staleIds) {
      await _clients.remove(id)?.client.dispose();
    }

    final tools = <McpTool>[];
    for (final server in enabled) {
      try {
        final client = await _clientFor(server);
        final serverTools = await client.listTools();
        for (final info in serverTools) {
          tools.add(McpTool(
            service: this,
            server: server,
            serverTool: info,
          ));
        }
      } catch (_) {
        // Unavailable MCP servers should not break chat startup. The server can
        // be retried on the next tool refresh after users fix its command/env.
      }
    }
    return tools;
  }

  Future<ToolResultPayload> callTool({
    required McpServerConfig server,
    required McpToolInfo tool,
    required String mappedName,
    required Map<String, dynamic> arguments,
  }) async {
    if (!stdioSupported) {
      return ToolResultFormatter.generic(
        toolName: mappedName,
        output: McpPlatformSupport.unsupportedMessage,
        isError: true,
        limit: 4000,
      );
    }
    try {
      final client = await _clientFor(server);
      final result = await client.callTool(tool.name, arguments);
      final sanitized = _boundedSanitizedOutput(result.output);
      final payload = ToolResultFormatter.generic(
        toolName: mappedName,
        output: sanitized,
        isError: result.isError,
      );
      return payload.copyWith(
        metadata: {
          ...payload.metadata,
          'mcpServerId': server.id,
          'mcpServerName': server.displayName,
          'mcpToolName': tool.name,
          'status': result.isError ? 'error' : 'success',
        },
      );
    } catch (_) {
      return ToolResultFormatter.generic(
        toolName: mappedName,
        output: 'MCP tool failed before producing safe output.',
        isError: true,
        limit: 4000,
      );
    }
  }

  Future<void> dispose() async {
    final clients = _clients.values.map((entry) => entry.client).toList();
    _clients.clear();
    await Future.wait(clients.map((client) => client.dispose()));
  }

  Future<McpStdioClient> _clientFor(McpServerConfig server) async {
    final fingerprint = jsonEncode(server.toJson());
    final existing = _clients[server.id];
    if (existing != null && existing.fingerprint == fingerprint) {
      try {
        await existing.client.connect();
        return existing.client;
      } catch (_) {
        if (_clients[server.id]?.client == existing.client) {
          _clients.remove(server.id);
        }
        await existing.client.dispose();
        rethrow;
      }
    }

    await existing?.client.dispose();
    final client = McpStdioClient(
      config: server,
      processStarter: processStarter,
      requestTimeout: requestTimeout,
      connectTimeout: connectTimeout,
    );
    _clients[server.id] = _McpClientEntry(
      fingerprint: fingerprint,
      client: client,
    );
    try {
      await client.connect();
      return client;
    } catch (_) {
      if (_clients[server.id]?.client == client) {
        _clients.remove(server.id);
      }
      await client.dispose();
      rethrow;
    }
  }

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

  static bool get isStdioSupported =>
      !kIsWeb && defaultTargetPlatform != TargetPlatform.android;

  static const unsupportedMessage =
      'Stdio MCP servers are not available on Android in this build. '
      'Saved MCP configs will not start until a persistent Android/proot '
      'stdio bridge is implemented.';
}

class McpTool extends Tool {
  final McpService service;
  final McpServerConfig server;
  final McpToolInfo serverTool;
  late final String _name = McpToolNames.mappedName(server, serverTool.name);

  McpTool({
    required this.service,
    required this.server,
    required this.serverTool,
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
  Future<ToolResultPayload> executeResult(Map<String, dynamic> input) {
    return service.callTool(
      server: server,
      tool: serverTool,
      mappedName: name,
      arguments: input,
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
  final McpStdioClient client;

  const _McpClientEntry({
    required this.fingerprint,
    required this.client,
  });
}
