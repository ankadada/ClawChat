import 'dart:async';
import '../models/chat_models.dart';
import 'llm_content_sanitizer.dart';
import 'llm_service.dart';
import 'privacy_filter.dart';
import 'runtime_debug_events.dart';
import 'tools/tool_argument_preflight.dart';
import 'tools/tool_policy.dart';
import 'tools/tool_registry.dart';

sealed class AgentEvent {}

class AgentThinking extends AgentEvent {}

class AgentTextDelta extends AgentEvent {
  final String text;
  AgentTextDelta(this.text);
}

class AgentReasoningDelta extends AgentEvent {
  final String text;
  AgentReasoningDelta(this.text);
}

class AgentToolStart extends AgentEvent {
  final String toolUseId;
  final String toolName;
  final Map<String, dynamic> input;
  AgentToolStart(this.toolUseId, this.toolName, this.input);
}

class AgentToolDone extends AgentEvent {
  final String toolUseId;
  final String output;
  final bool isError;
  AgentToolDone(this.toolUseId, this.output, {this.isError = false});
}

class AgentIterationDone extends AgentEvent {
  final List<Map<String, dynamic>> messages;
  AgentIterationDone(this.messages);
}

class AgentComplete extends AgentEvent {
  final String finalText;
  final int? inputTokens;
  final int? outputTokens;
  final LlmUsage? usage;
  final bool hadToolCalls;
  AgentComplete(
    this.finalText, {
    this.inputTokens,
    this.outputTokens,
    this.usage,
    this.hadToolCalls = false,
  });
}

class AgentError extends AgentEvent {
  final String message;
  final Object? cause;
  AgentError(this.message, {this.cause});
}

class AgentService {
  final LlmService _llm;
  final ToolRegistry _tools;
  final String _systemPrompt;
  final ToolPolicy _toolPolicy;
  final int maxIterations;
  final bool parallelTools;
  final bool privacyMode;
  final bool supportsTools;
  final Map<String, String> envVars;
  final RuntimeDebugEventService? runtimeDebugEvents;
  final String? sessionId;
  final ToolArgumentPreflight _toolArgumentPreflight;
  bool _cancelled = false;
  List<Map<String, dynamic>> _lastMessages = [];

  AgentService({
    required LlmService llm,
    required ToolRegistry tools,
    required String systemPrompt,
    ToolPolicy? toolPolicy,
    this.maxIterations = 25,
    this.parallelTools = false,
    this.privacyMode = true,
    this.supportsTools = true,
    this.envVars = const {},
    this.runtimeDebugEvents,
    this.sessionId,
    ToolArgumentPreflight? toolArgumentPreflight,
  })  : _llm = llm,
        _tools = tools,
        _systemPrompt = systemPrompt,
        _toolPolicy = toolPolicy ?? const ToolPolicy(),
        _toolArgumentPreflight =
            toolArgumentPreflight ?? const ToolArgumentPreflight();

  void cancel() {
    _cancelled = true;
    _llm.dispose();
  }

  bool get isCancelled => _cancelled;
  List<Map<String, dynamic>> get messages => _lastMessages;

  /// Runs the agentic tool-use loop, streaming [AgentEvent]s as it progresses.
  ///
  /// [messages] is mutated in place during the agent loop -- the caller's list
  /// will contain all intermediate messages (assistant responses, tool results)
  /// when the stream completes. A reference is also kept in [_lastMessages] so
  /// that callers can inspect the final conversation via the [messages] getter.
  Stream<AgentEvent> runAgentLoop(
    List<Map<String, dynamic>> messages, {
    void Function(List<Map<String, dynamic>> messages)? onMessagesUpdated,
  }) async* {
    _cancelled = false;
    _lastMessages = messages;
    final toolDefs = supportsTools
        ? _tools.getToolDefinitions(sessionId: sessionId)
        : <ToolDefinition>[];
    final effectiveMaxIterations = maxIterations.clamp(1, 99).toInt();
    int iteration = 0;
    var hadToolCalls = false;

    while (!_cancelled) {
      iteration++;
      if (iteration > effectiveMaxIterations) {
        yield AgentError(
          'Agent loop exceeded maximum iterations ($effectiveMaxIterations)',
        );
        return;
      }
      yield AgentThinking();

      LlmResponse? response;
      final textBuffer = StringBuffer();

      try {
        await for (final event in _llm.chatStream(
          system: _systemPrompt,
          // Keep [messages] raw for UI/session storage; the LLM receives only
          // the safe tool-result projection.
          messages: _messagesForLlm(messages),
          tools: toolDefs,
        )) {
          if (_cancelled) return;

          if (event is TextDelta) {
            textBuffer.write(event.text);
            yield AgentTextDelta(event.text);
          } else if (event is ReasoningDelta) {
            yield AgentReasoningDelta(event.text);
          } else if (event is StreamDone) {
            response = event.response;
          } else if (event is StreamError) {
            yield AgentError(event.message, cause: event.cause);
            return;
          }
        }
      } catch (e) {
        yield AgentError('LLM request failed: $e', cause: e);
        return;
      }

      if (response == null) {
        yield AgentError('No LLM response received');
        return;
      }

      messages.add({
        'role': 'assistant',
        'content': response.content.map((b) => b.toJson()).toList(),
      });
      onMessagesUpdated?.call(messages);

      if (response.stopReason != 'tool_use') {
        final finalText = response.content
            .where((b) => b.type == 'text')
            .map((b) => b.text ?? '')
            .join();
        yield AgentComplete(
          finalText,
          inputTokens: response.inputTokens,
          outputTokens: response.outputTokens,
          usage: response.usage,
          hadToolCalls: hadToolCalls,
        );
        return;
      }

      final toolBlocks =
          response.content.where((b) => b.type == 'tool_use').toList();
      if (toolBlocks.isNotEmpty) hadToolCalls = true;
      final toolResults = <Map<String, dynamic>>[];

      final toolInputs = <ContentBlock, Map<String, dynamic>>{};
      for (final block in toolBlocks) {
        final toolUseId = block.toolUseId;
        final toolName = block.toolName;
        if (toolUseId == null || toolName == null) continue;
        final toolInput = _preflightToolInput(
          toolName,
          block.rawToolInputJson ?? block.toolInput ?? {},
        );
        toolInputs[block] = toolInput;
        yield AgentToolStart(toolUseId, toolName, toolInput);
      }

      if (parallelTools && toolBlocks.length > 1) {
        final futures = toolBlocks.map((block) async {
          if (_cancelled) return null;
          final toolUseId = block.toolUseId;
          final toolName = block.toolName;
          if (toolUseId == null || toolName == null) return null;
          final toolInput = toolInputs[block] ?? block.toolInput ?? {};
          return _executeToolWithPolicy(toolUseId, toolName, toolInput);
        }).toList();
        final results = await Future.wait(futures);
        for (final r in results) {
          if (r == null) continue;
          yield AgentToolDone(r.id, r.output, isError: r.isError);
          toolResults.add(r.toJson());
        }
      } else {
        for (final block in toolBlocks) {
          if (_cancelled) return;
          final toolUseId = block.toolUseId;
          final toolName = block.toolName;
          if (toolUseId == null || toolName == null) continue;
          final toolInput = toolInputs[block] ?? block.toolInput ?? {};

          final result =
              await _executeToolWithPolicy(toolUseId, toolName, toolInput);
          yield AgentToolDone(result.id, result.output,
              isError: result.isError);
          toolResults.add(result.toJson());
        }
      }

      messages.add({
        'role': 'user',
        'content': toolResults,
      });
      onMessagesUpdated?.call(messages);
      yield AgentIterationDone(messages);
    }
  }

  List<Map<String, dynamic>> _messagesForLlm(
    List<Map<String, dynamic>> messages,
  ) {
    return messages.map((msg) {
      final content = msg['content'];
      if (content is! List) return msg;

      var changed = false;
      final filteredContent = content
          .map((block) {
            if (block is Map && block['type'] == 'tool_result') {
              final id = block['tool_use_id']?.toString();
              if (id == null || id.isEmpty) {
                changed = true;
                return null;
              }
              changed = true;
              final projected = <String, dynamic>{
                'type': 'tool_result',
                'tool_use_id': id,
                'content': _safeToolResultContent(block),
                if (block['is_error'] == true) 'is_error': true,
              };
              return projected;
            }
            return block;
          })
          .where((block) => block != null)
          .toList();

      if (!changed) return msg;
      return {
        ...msg,
        'content': filteredContent,
      };
    }).toList();
  }

  String _safeToolResultContent(Map<dynamic, dynamic> block) {
    final raw = ToolResultPayload.stringifyContent(
      block['for_llm'] ?? block['content'] ?? block['output'],
    );
    final sanitized = const LlmContentSanitizer().sanitizeText(raw).text;
    if (!privacyMode || envVars.isEmpty) return sanitized;
    return PrivacyFilter.maskEnvVarValues(sanitized, envVars);
  }

  Future<_ToolResult> _executeToolWithPolicy(
    String toolUseId,
    String toolName,
    Map<String, dynamic> toolInput,
  ) async {
    if (!_tools.hasTool(toolName)) {
      const output = 'Tool error: Unknown tool';
      return _ToolResult(
        toolUseId,
        ToolResultPayload(
          forUser: '$output: $toolName',
          forLlm: '$output: $toolName',
          summary: '$output: $toolName',
          metadata: const {'toolName': 'unknown', 'status': 'error'},
        ),
        true,
      );
    }

    final request = ToolApprovalRequest(
      toolName: toolName,
      arguments: Map<String, dynamic>.from(toolInput),
      risk: _tools.riskFor(toolName),
    );
    final denyDecision = _toolPolicy.denyFor(request);
    if (denyDecision != null) {
      _recordRuntimeEvent('tool.execution.denied', {
        'ruleType': denyDecision.ruleType,
        'ruleId': denyDecision.ruleId,
      });
      return _ToolResult(
        toolUseId,
        ToolResultPayload(
          forUser: denyDecision.message,
          forLlm: denyDecision.message,
          summary: denyDecision.message,
          metadata: {
            'status': 'error',
            'denyRuleType': denyDecision.ruleType,
            'denyRuleId': denyDecision.ruleId,
          },
        ),
        true,
      );
    }
    final approved = await _toolPolicy.approve(request);
    if (!approved) {
      return _ToolResult(
        toolUseId,
        ToolResultPayload(
          forUser: 'tool execution denied by user: $toolName',
          forLlm: 'tool execution denied by user: $toolName',
          summary: 'tool execution denied by user: $toolName',
          metadata: {'toolName': toolName, 'status': 'error'},
        ),
        true,
      );
    }

    try {
      final payload = await _tools.executeToolResult(
        toolName,
        toolInput,
        sessionId: sessionId,
      );
      return _ToolResult(toolUseId, payload, false);
    } catch (e) {
      return _ToolResult(
        toolUseId,
        ToolResultPayload(
          forUser: 'Tool error: $e',
          forLlm: 'Tool error: $e',
          summary: 'Tool error: $e',
          metadata: {'toolName': toolName, 'status': 'error'},
        ),
        true,
      );
    }
  }

  Map<String, dynamic> _preflightToolInput(
    String toolName,
    Object? rawToolInput,
  ) {
    final schema = _tools.inputSchemaFor(toolName, sessionId: sessionId);
    if (schema == null) {
      return rawToolInput is Map
          ? Map<String, dynamic>.from(rawToolInput)
          : const {};
    }
    final result = _toolArgumentPreflight.repair(rawToolInput, schema);
    if (result.repaired) {
      _recordRuntimeEvent('tool.preflight.repaired', {
        'repairCount': result.repairCounts.values
            .fold<int>(0, (sum, count) => sum + count),
        'repairTypes': result.repairCounts,
      });
    }
    return result.arguments;
  }

  void _recordRuntimeEvent(String type, Map<String, Object?> data) {
    final service = runtimeDebugEvents;
    final id = sessionId;
    if (service == null || id == null) return;
    try {
      service.record(RuntimeDebugEvent(
        type: type,
        sessionId: id,
        data: data,
      ));
    } catch (_) {
      // Debug events must never affect tool execution.
    }
  }
}

class _ToolResult {
  final String id;
  final ToolResultPayload payload;
  final bool isError;
  _ToolResult(this.id, this.payload, this.isError);

  String get output => payload.forUser;

  Map<String, dynamic> toJson() => {
        'type': 'tool_result',
        'tool_use_id': id,
        'content': payload.llmOutput,
        'output': payload.forUser,
        if (payload.forLlm != null) 'for_llm': payload.forLlm,
        if (payload.summary != null) 'summary': payload.summary,
        if (payload.metadata.isNotEmpty) 'metadata': payload.metadata,
        if (isError) 'is_error': true,
      };
}
