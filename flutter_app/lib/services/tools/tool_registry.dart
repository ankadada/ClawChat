import 'dart:async';

import '../../services/llm_service.dart';
import '../../models/chat_models.dart';
import '../llm_content_sanitizer.dart';
import '../mcp_service.dart';
import '../preferences_service.dart';
import '../memory_service.dart';
import 'bash_tool.dart';
import 'env_var_tool.dart';
import 'memory_tools.dart';
import 'phone_intent_tool.dart';
import 'read_file_tool.dart';
import 'tool_result_formatter.dart';
import 'tool_policy.dart';
import 'write_file_tool.dart';
import 'web_fetch_tool.dart';
import 'web_search_tool.dart';
import 'image_gen_tool.dart';
import 'load_skill_tool.dart';

class ToolCancellationSignal {
  final Completer<void> _cancelled = Completer<void>();

  bool get isCancellationRequested => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  void throwIfCancellationRequested({
    bool sideEffectsPrevented = true,
  }) {
    if (!isCancellationRequested) return;
    throw ToolExecutionCancelledException(
      sideEffectsPrevented: sideEffectsPrevented,
    );
  }
}

class ToolExecutionCancelledException implements Exception {
  final bool sideEffectsPrevented;

  const ToolExecutionCancelledException({
    required this.sideEffectsPrevented,
  });

  @override
  String toString() => 'Tool execution cancelled';
}

abstract class Tool {
  String get name;
  String get description;
  Map<String, dynamic> get inputSchema;

  Future<String> execute(Map<String, dynamic> input);

  Future<String> executeWithContext(
    Map<String, dynamic> input, {
    String? sessionId,
  }) {
    return execute(input);
  }

  Future<ToolResultPayload> executeResult(
    Map<String, dynamic> input, {
    String? sessionId,
  }) async {
    final output = await executeWithContext(input, sessionId: sessionId);
    return ToolResultFormatter.format(
      toolName: name,
      input: input,
      output: output,
    );
  }

  /// Execution hook carrying a stable per-attempt operation ID.
  ///
  /// Tools that support upstream idempotency can override this method and
  /// forward [operationId]. Existing tools remain backward compatible and
  /// execute through [executeResult] without receiving extra user data.
  Future<ToolResultPayload> executeResultWithOperation(
    Map<String, dynamic> input, {
    String? sessionId,
    required String operationId,
  }) {
    return executeResult(input, sessionId: sessionId);
  }

  /// Optional cancellation-aware operation hook.
  ///
  /// The default implementation only checks cancellation before dispatch.
  /// Tools that can abort an in-flight request should override this method,
  /// listen to [cancellationSignal.whenCancelled], and throw
  /// [ToolExecutionCancelledException] only when abort is confirmed.
  Future<ToolResultPayload> executeResultWithOperationAndCancellation(
    Map<String, dynamic> input, {
    String? sessionId,
    required String operationId,
    required ToolCancellationSignal cancellationSignal,
  }) {
    cancellationSignal.throwIfCancellationRequested();
    return executeResultWithOperation(
      input,
      sessionId: sessionId,
      operationId: operationId,
    );
  }

  ToolDefinition toDefinition() => ToolDefinition(
        name: name,
        description: description,
        inputSchema: inputSchema,
      );
}

class ToolRegistry {
  final Map<String, Tool> _tools = {};
  final Map<String, ToolRisk> _risks = {};
  final Set<String> _mcpToolNames = {};
  final McpService? _mcpService;

  ToolRegistry({McpService? mcpService}) : _mcpService = mcpService;

  factory ToolRegistry.withDefaults({PreferencesService? prefs}) {
    final registry = ToolRegistry(
      mcpService: prefs == null ? null : McpService(prefs: prefs),
    );
    registry.register(BashTool(), risk: ToolRisk.dangerous);
    registry.register(LoadSkillTool(), risk: ToolRisk.safe);
    registry.register(ReadFileTool(), risk: ToolRisk.moderate);
    registry.register(WriteFileTool(), risk: ToolRisk.dangerous);
    registry.register(WebFetchTool(), risk: ToolRisk.moderate);
    registry.register(
      EnvVarTool(prefs ?? PreferencesService()),
      risk: ToolRisk.moderate,
    );
    registry.register(MemoryGetTool(), risk: ToolRisk.safe);
    registry.register(MemoryWriteTool(), risk: ToolRisk.moderate);
    registry.register(MemoryDeleteTool(), risk: ToolRisk.moderate);
    if (prefs != null) {
      registry.register(PhoneIntentTool(prefs), risk: ToolRisk.dangerous);
    }
    registry.register(WebSearchTool(), risk: ToolRisk.safe);
    if (prefs != null) {
      registry.register(ImageGenTool(prefs), risk: ToolRisk.safe);
    }
    return registry;
  }

  void register(Tool tool, {ToolRisk risk = ToolRisk.dangerous}) {
    _tools[tool.name] = tool;
    _risks[tool.name] = risk;
  }

  void unregister(String name) {
    _tools.remove(name);
    _risks.remove(name);
  }

  List<ToolDefinition> getToolDefinitions({String? sessionId}) {
    return _tools.values
        .where((tool) => _isToolAvailableForSession(tool, sessionId))
        .map((t) => t.toDefinition())
        .toList();
  }

  Future<void> refreshMcpTools() async {
    final service = _mcpService;
    if (service == null) return;
    for (final name in _mcpToolNames) {
      unregister(name);
    }
    _mcpToolNames.clear();

    final tools = await service.loadTools();
    for (final tool in tools) {
      register(tool, risk: ToolRisk.moderate);
      _mcpToolNames.add(tool.name);
    }
  }

  Future<void> dispose() async {
    await _mcpService?.dispose();
  }

  Map<String, dynamic>? inputSchemaFor(String name, {String? sessionId}) {
    final tool = _tools[name];
    if (tool == null || !_isToolAvailableForSession(tool, sessionId)) {
      return null;
    }
    return tool.inputSchema;
  }

  Future<String> executeTool(
    String name,
    Map<String, dynamic> input, {
    String? sessionId,
  }) async {
    final payload = await executeToolResult(
      name,
      input,
      sessionId: sessionId,
    );
    return payload.forUser;
  }

  Future<ToolResultPayload> executeToolResult(
    String name,
    Map<String, dynamic> input, {
    String? sessionId,
    String? operationId,
    ToolCancellationSignal? cancellationSignal,
    Set<String>? allowedNetworkDomains,
    Set<String>? allowedFilesystemReadScopes,
    Set<String>? allowedFilesystemWriteScopes,
  }) async {
    final tool = _tools[name];
    if (tool == null) throw Exception('Unknown tool: $name');
    if (tool is ReadFileTool && allowedFilesystemReadScopes != null) {
      cancellationSignal?.throwIfCancellationRequested();
      final output = await tool.executeWithAllowedScopes(
        input,
        allowedFilesystemReadScopes,
      );
      return ToolResultFormatter.format(
        toolName: tool.name,
        input: input,
        output: output,
        isError: output.startsWith('Error'),
      );
    }
    if (tool is WriteFileTool && allowedFilesystemWriteScopes != null) {
      cancellationSignal?.throwIfCancellationRequested();
      final output = await tool.executeWithAllowedScopes(
        input,
        allowedFilesystemWriteScopes,
      );
      return ToolResultFormatter.format(
        toolName: tool.name,
        input: input,
        output: output,
        isError: output.startsWith('Error'),
      );
    }
    if (tool is WebFetchTool && allowedNetworkDomains != null) {
      cancellationSignal?.throwIfCancellationRequested();
      final output = await tool.executeWithAllowedDomains(
        input,
        allowedDomains: allowedNetworkDomains,
        cancellationSignal: cancellationSignal,
      );
      return ToolResultFormatter.format(
        toolName: tool.name,
        input: input,
        output: output,
        isError: output.startsWith('Error'),
      );
    }
    if (tool is WebSearchTool && allowedNetworkDomains != null) {
      cancellationSignal?.throwIfCancellationRequested();
      final output = await tool.executeForSkill(
        input,
        cancellationSignal: cancellationSignal,
      );
      return ToolResultFormatter.format(
        toolName: tool.name,
        input: input,
        output: output,
        isError: output.startsWith('Search failed:'),
      );
    }
    if (operationId != null) {
      if (cancellationSignal != null) {
        return tool.executeResultWithOperationAndCancellation(
          input,
          sessionId: sessionId,
          operationId: operationId,
          cancellationSignal: cancellationSignal,
        );
      }
      return tool.executeResultWithOperation(
        input,
        sessionId: sessionId,
        operationId: operationId,
      );
    }
    return tool.executeResult(input, sessionId: sessionId);
  }

  static String sanitizeToolOutput(String output) {
    return const LlmContentSanitizer().sanitizeText(output).text;
  }

  bool hasTool(String name) => _tools.containsKey(name);

  ToolRisk riskFor(String name) => _risks[name] ?? ToolRisk.dangerous;

  List<String> get availableTools => availableToolsForSession();

  List<String> availableToolsForSession({String? sessionId}) => _tools.values
      .where((tool) => _isToolAvailableForSession(tool, sessionId))
      .map((tool) => tool.name)
      .toList();

  bool _isToolAvailableForSession(Tool tool, String? sessionId) {
    if (tool.name.startsWith('memory_')) {
      return MemoryService.isEnabledForSessionSync(sessionId);
    }
    return true;
  }
}
