import 'dart:async';
import 'llm_service.dart';
import 'privacy_filter.dart';
import 'tools/tool_policy.dart';
import 'tools/tool_registry.dart';

sealed class AgentEvent {}

class AgentThinking extends AgentEvent {}

class AgentTextDelta extends AgentEvent {
  final String text;
  AgentTextDelta(this.text);
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
  AgentComplete(this.finalText, {this.inputTokens, this.outputTokens});
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
  final Map<String, String> envVars;
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
    this.envVars = const {},
  })  : _llm = llm,
        _tools = tools,
        _systemPrompt = systemPrompt,
        _toolPolicy = toolPolicy ?? const ToolPolicy();

  void cancel() => _cancelled = true;
  bool get isCancelled => _cancelled;
  List<Map<String, dynamic>> get messages => _lastMessages;

  // NOTE: cancel() sets a flag that is checked between iterations and tool calls,
  // but it cannot interrupt an in-flight HTTP request to the LLM API.
  // The current request will complete before the cancellation takes effect.

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
    final toolDefs = _tools.getToolDefinitions();
    final effectiveMaxIterations = maxIterations.clamp(1, 99).toInt();
    int iteration = 0;

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
          // Keep [messages] raw for UI/session storage; only the LLM payload
          // receives masked tool outputs.
          messages: _filterHistoryMessages(messages),
          tools: toolDefs,
        )) {
          if (_cancelled) return;

          if (event is TextDelta) {
            textBuffer.write(event.text);
            yield AgentTextDelta(event.text);
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
        );
        return;
      }

      final toolBlocks =
          response.content.where((b) => b.type == 'tool_use').toList();
      final toolResults = <Map<String, dynamic>>[];

      for (final block in toolBlocks) {
        final toolUseId = block.toolUseId;
        final toolName = block.toolName;
        if (toolUseId == null || toolName == null) continue;
        yield AgentToolStart(toolUseId, toolName, block.toolInput ?? {});
      }

      if (parallelTools && toolBlocks.length > 1) {
        final futures = toolBlocks.map((block) async {
          if (_cancelled) return null;
          final toolUseId = block.toolUseId;
          final toolName = block.toolName;
          if (toolUseId == null || toolName == null) return null;
          final toolInput = block.toolInput ?? {};
          return _executeToolWithPolicy(toolUseId, toolName, toolInput);
        }).toList();
        final results = await Future.wait(futures);
        for (final r in results) {
          if (r == null) continue;
          yield AgentToolDone(r.id, r.output, isError: r.isError);
          toolResults.add({
            'type': 'tool_result',
            'tool_use_id': r.id,
            'content': r.output,
            if (r.isError) 'is_error': true,
          });
        }
      } else {
        for (final block in toolBlocks) {
          if (_cancelled) return;
          final toolUseId = block.toolUseId;
          final toolName = block.toolName;
          if (toolUseId == null || toolName == null) continue;
          final toolInput = block.toolInput ?? {};

          final result =
              await _executeToolWithPolicy(toolUseId, toolName, toolInput);
          yield AgentToolDone(result.id, result.output,
              isError: result.isError);
          toolResults.add({
            'type': 'tool_result',
            'tool_use_id': result.id,
            'content': result.output,
            if (result.isError) 'is_error': true,
          });
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

  List<Map<String, dynamic>> _filterHistoryMessages(
    List<Map<String, dynamic>> messages,
  ) {
    if (!privacyMode || envVars.isEmpty) return messages;
    return messages.map((msg) {
      final content = msg['content'];
      if (content is! List) return msg;

      var changed = false;
      final filteredContent = content.map((block) {
        if (block is Map && block['type'] == 'tool_result') {
          final value = block['content'];
          if (value is String) {
            final masked = PrivacyFilter.maskEnvVarValues(value, envVars);
            if (masked != value) {
              changed = true;
              return {
                ...Map<String, dynamic>.from(block),
                'content': masked,
              };
            }
          }
        }
        return block;
      }).toList();

      if (!changed) return msg;
      return {
        ...msg,
        'content': filteredContent,
      };
    }).toList();
  }

  Future<_ToolResult> _executeToolWithPolicy(
    String toolUseId,
    String toolName,
    Map<String, dynamic> toolInput,
  ) async {
    if (!_tools.hasTool(toolName)) {
      return _ToolResult(
          toolUseId, 'Tool error: Unknown tool: $toolName', true);
    }

    final request = ToolApprovalRequest(
      toolName: toolName,
      arguments: Map<String, dynamic>.from(toolInput),
      risk: _tools.riskFor(toolName),
    );
    final approved = await _toolPolicy.approve(request);
    if (!approved) {
      return _ToolResult(
        toolUseId,
        'tool execution denied by user: $toolName',
        true,
      );
    }

    try {
      final output = await _tools.executeTool(toolName, toolInput);
      return _ToolResult(toolUseId, output, false);
    } catch (e) {
      return _ToolResult(toolUseId, 'Tool error: $e', true);
    }
  }
}

class _ToolResult {
  final String id;
  final String output;
  final bool isError;
  _ToolResult(this.id, this.output, this.isError);
}
