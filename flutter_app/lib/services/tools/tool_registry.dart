import 'dart:async';

import '../../services/llm_service.dart';
import '../../models/chat_models.dart';
import '../llm_content_sanitizer.dart';
import '../mcp_service.dart';
import '../preferences_service.dart';
import '../memory_service.dart';
import 'untrusted_data_policy.dart';
import 'bash_tool.dart';
import 'env_var_tool.dart';
import 'memory_tools.dart';
import 'phone_intent_tool.dart';
import 'phone_tools.dart';
import 'read_file_tool.dart';
import 'tool_result_formatter.dart';
import 'tool_policy.dart';
import 'write_file_tool.dart';
import 'xds_agent_tool.dart';
import 'web_fetch_tool.dart';
import 'web_search_tool.dart';
import 'image_gen_tool.dart';
import 'load_skill_tool.dart';
import 'present_structured_result_tool.dart';

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
    RunTaintSet? runTaintSet,
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
  ///
  /// [runTaintSet] is the **calling run's** taint set. It is passed per call so
  /// concurrent runs never share or clear each other's provenance.
  Future<ToolResultPayload> executeResultWithOperation(
    Map<String, dynamic> input, {
    String? sessionId,
    required String operationId,
    RunTaintSet? runTaintSet,
  }) {
    return executeResult(
      input,
      sessionId: sessionId,
      runTaintSet: runTaintSet,
    );
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
    RunTaintSet? runTaintSet,
  }) {
    cancellationSignal.throwIfCancellationRequested();
    return executeResultWithOperation(
      input,
      sessionId: sessionId,
      operationId: operationId,
      runTaintSet: runTaintSet,
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
  final Set<String> _hiddenTools = {};
  final Map<String, bool Function()> _visibleWhen = {};
  final Set<String> _mcpToolNames = {};

  /// The MCP tools each run registered, keyed by run scope then tool name. A
  /// run's refresh or end must not remove another live run's tools from the
  /// shared registry, and two runs on the same server must not fight over one
  /// registry entry.
  final Map<String, Map<String, Tool>> _mcpToolsByRun = {};
  final McpService? _mcpService;

  ToolRegistry({McpService? mcpService}) : _mcpService = mcpService;

  factory ToolRegistry.withDefaults({PreferencesService? prefs}) {
    final registry = ToolRegistry(
      mcpService: prefs == null ? null : McpService(prefs: prefs),
    );
    registry.register(BashTool(), risk: ToolRisk.dangerous);
    registry.register(LoadSkillTool(), risk: ToolRisk.moderate);
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
    registry.register(PresentStructuredResultTool(), risk: ToolRisk.safe);
    if (prefs != null) {
      // The split phone API is the model-facing surface; `phone_intent` stays
      // registered but hidden as a one-version compatibility alias.
      registry.register(PhoneReadTool(), risk: ToolRisk.moderate);
      registry.register(PhoneActTool(), risk: ToolRisk.moderate);
      registry.register(
        PhoneSendTool(prefs),
        risk: ToolRisk.dangerous,
        // §7.5: omitted from tool definitions unless an outbound setting is on.
        // A single enabled action still returns disabled_by_user for the other.
        visibleWhen: () => prefs.allowPhoneCall || prefs.allowSms,
      );
      registry.register(
        PhoneIntentTool(prefs),
        risk: ToolRisk.dangerous,
        hidden: true,
      );
    }
    registry.register(WebSearchTool(), risk: ToolRisk.safe);
    if (prefs != null) {
      registry.register(ImageGenTool(prefs), risk: ToolRisk.safe);
      registry.register(XdsAgentTool(prefs), risk: ToolRisk.dangerous);
    }
    return registry;
  }

  void register(
    Tool tool, {
    ToolRisk risk = ToolRisk.dangerous,
    bool hidden = false,
    bool Function()? visibleWhen,
  }) {
    _tools[tool.name] = tool;
    _risks[tool.name] = risk;
    if (hidden) {
      _hiddenTools.add(tool.name);
    } else {
      _hiddenTools.remove(tool.name);
    }
    if (visibleWhen != null) {
      _visibleWhen[tool.name] = visibleWhen;
    } else {
      _visibleWhen.remove(tool.name);
    }
  }

  void unregister(String name) {
    _tools.remove(name);
    _risks.remove(name);
    _hiddenTools.remove(name);
    _visibleWhen.remove(name);
  }

  /// Whether [name] may be advertised to the model right now.
  bool _isVisible(String name) {
    if (_hiddenTools.contains(name)) return false;
    final predicate = _visibleWhen[name];
    if (predicate == null) return true;
    try {
      return predicate();
    } catch (_) {
      return false;
    }
  }

  List<ToolDefinition> getToolDefinitions({
    String? sessionId,
    bool includeXds = false,
  }) {
    return _tools.values
        .where(
          (tool) =>
              _isVisible(tool.name) &&
              (includeXds || tool.name != 'xds_agent') &&
              _isToolAvailableForSession(tool, sessionId),
        )
        .map((t) => t.toDefinition())
        .toList();
  }

  /// Whether [name] is registered but intentionally absent from the
  /// model-facing tool list (a compatibility alias).
  bool isHidden(String name) => _hiddenTools.contains(name);

  Future<void> refreshMcpTools({String? runId}) async {
    final service = _mcpService;
    if (service == null) return;
    final scope = runId ?? '';
    final previous = _mcpToolsByRun.remove(scope) ?? const <String, Tool>{};
    final tools = await service.loadTools(runId: runId);
    _mcpToolsByRun[scope] = {for (final tool in tools) tool.name: tool};
    // Re-resolve every name this run or the previous one touched, so a shared
    // name follows whichever live run most recently provided it.
    _resolveMcpNames({...previous.keys, ..._mcpToolsByRun[scope]!.keys});
  }

  /// Point each [name] at the newest live run that provides it, or drop it.
  void _resolveMcpNames(Iterable<String> names) {
    for (final name in names) {
      Tool? winner;
      for (final tools in _mcpToolsByRun.values) {
        final candidate = tools[name];
        if (candidate != null) winner = candidate;
      }
      if (winner == null) {
        unregister(name);
        _mcpToolNames.remove(name);
      } else {
        register(winner, risk: ToolRisk.moderate);
        _mcpToolNames.add(name);
      }
    }
  }

  /// I5: opens the MCP run scope for one agent run. MCP children started after
  /// this belong to the run and die with it.
  String beginMcpRun({String? sessionId}) =>
      _mcpService?.beginRun(sessionId: sessionId) ?? '';

  /// I5: kills the MCP children owned by [runId] and drops only that run's MCP
  /// tools. Another live run's children and tools are untouched.
  Future<void> endMcpRun(String runId) async {
    if (runId.isEmpty) return;
    final dropped = _mcpToolsByRun.remove(runId) ?? const <String, Tool>{};
    _resolveMcpNames(dropped.keys);
    await _mcpService?.endRun(runId);
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
    RunTaintSet? runTaintSet,
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
        runTaintSet: runTaintSet,
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
          runTaintSet: runTaintSet,
        );
      }
      return tool.executeResultWithOperation(
        input,
        sessionId: sessionId,
        operationId: operationId,
        runTaintSet: runTaintSet,
      );
    }
    return tool.executeResult(
      input,
      sessionId: sessionId,
      runTaintSet: runTaintSet,
    );
  }

  static String sanitizeToolOutput(String output) {
    return const LlmContentSanitizer().sanitizeText(output).text;
  }

  bool hasTool(String name) => _tools.containsKey(name);

  ToolRisk riskFor(String name) => _risks[name] ?? ToolRisk.dangerous;

  List<String> get availableTools => availableToolsForSession();

  List<String> availableToolsForSession({String? sessionId}) => _tools.values
      .where((tool) =>
          _isVisible(tool.name) &&
          _isToolAvailableForSession(tool, sessionId))
      .map((tool) => tool.name)
      .toList();

  bool _isToolAvailableForSession(Tool tool, String? sessionId) {
    if (tool.name.startsWith('memory_')) {
      return MemoryService.isEnabledForSessionSync(sessionId);
    }
    return true;
  }
}
