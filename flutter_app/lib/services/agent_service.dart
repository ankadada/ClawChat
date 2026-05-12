import 'dart:async';
import 'llm_service.dart';
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

class AgentComplete extends AgentEvent {
  final String finalText;
  AgentComplete(this.finalText);
}

class AgentError extends AgentEvent {
  final String message;
  AgentError(this.message);
}

class AgentService {
  final LlmService _llm;
  final ToolRegistry _tools;
  final String _systemPrompt;
  final int maxIterations;
  final bool parallelTools;
  bool _cancelled = false;
  List<Map<String, dynamic>> _lastMessages = [];

  AgentService({
    required LlmService llm,
    required ToolRegistry tools,
    required String systemPrompt,
    this.maxIterations = 25,
    this.parallelTools = false,
  })  : _llm = llm,
        _tools = tools,
        _systemPrompt = systemPrompt;

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
    int iteration = 0;

    while (!_cancelled) {
      iteration++;
      if (iteration > maxIterations) {
        yield AgentError('Agent loop exceeded maximum iterations ($maxIterations)');
        return;
      }
      yield AgentThinking();

      LlmResponse? response;
      final textBuffer = StringBuffer();

      try {
        await for (final event in _llm.chatStream(
          system: _systemPrompt,
          messages: messages,
          tools: toolDefs,
        )) {
          if (_cancelled) return;

          if (event is TextDelta) {
            textBuffer.write(event.text);
            yield AgentTextDelta(event.text);
          } else if (event is StreamDone) {
            response = event.response;
          } else if (event is StreamError) {
            yield AgentError(event.message);
            return;
          }
        }
      } catch (e) {
        yield AgentError('LLM request failed: $e');
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
        yield AgentComplete(finalText);
        return;
      }

      final toolBlocks = response.content.where((b) => b.type == 'tool_use').toList();
      final toolResults = <Map<String, dynamic>>[];

      for (final block in toolBlocks) {
        yield AgentToolStart(block.toolUseId!, block.toolName!, block.toolInput ?? {});
      }

      if (parallelTools && toolBlocks.length > 1) {
        final futures = toolBlocks.map((block) async {
          if (_cancelled) return null;
          final toolUseId = block.toolUseId!;
          final toolName = block.toolName!;
          final toolInput = block.toolInput ?? {};
          try {
            final output = await _tools.executeTool(toolName, toolInput);
            return _ToolResult(toolUseId, output, false);
          } catch (e) {
            return _ToolResult(toolUseId, 'Tool error: $e', true);
          }
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
          final toolUseId = block.toolUseId!;
          final toolName = block.toolName!;
          final toolInput = block.toolInput ?? {};

          try {
            final output = await _tools.executeTool(toolName, toolInput);
            yield AgentToolDone(toolUseId, output);
            toolResults.add({
              'type': 'tool_result',
              'tool_use_id': toolUseId,
              'content': output,
            });
          } catch (e) {
            final errorMsg = 'Tool error: $e';
            yield AgentToolDone(toolUseId, errorMsg, isError: true);
            toolResults.add({
              'type': 'tool_result',
              'tool_use_id': toolUseId,
              'content': errorMsg,
              'is_error': true,
            });
          }
        }
      }

      messages.add({
        'role': 'user',
        'content': toolResults,
      });
      onMessagesUpdated?.call(messages);
    }
  }
}

class _ToolResult {
  final String id;
  final String output;
  final bool isError;
  _ToolResult(this.id, this.output, this.isError);
}
