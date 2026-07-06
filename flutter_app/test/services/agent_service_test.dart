import 'package:clawchat/services/agent_service.dart';
import 'package:clawchat/services/llm_service.dart';
import 'package:clawchat/services/runtime_debug_events.dart';
import 'package:clawchat/services/tools/tool_policy.dart';
import 'package:clawchat/services/tools/tool_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AgentService tool safety', () {
    test('forwards reasoning deltas separately from visible text', () async {
      final service = AgentService(
        llm: _ReasoningStreamLlmService(_config),
        tools: ToolRegistry(),
        systemPrompt: 'system',
      );

      final agentEvents = <AgentEvent>[];
      await for (final event in service.runAgentLoop([])) {
        agentEvents.add(event);
      }

      expect(agentEvents.whereType<AgentReasoningDelta>().map((e) => e.text), [
        'hidden step ',
        'hidden state',
      ]);
      expect(agentEvents.whereType<AgentTextDelta>().map((e) => e.text), [
        'visible',
      ]);
      expect(
          agentEvents.whereType<AgentComplete>().single.finalText, 'visible');
    });

    test('denies configured tools before approval and execution', () async {
      var approvalCount = 0;
      final tool = _RecordingTool(name: 'bash');
      final tools = ToolRegistry()..register(tool, risk: ToolRisk.dangerous);
      final events = RuntimeDebugEventService();
      final service = AgentService(
        llm: _ToolCallLlmService(
          _config,
          toolName: 'bash',
          arguments: const {'command': 'echo secret-token'},
        ),
        tools: tools,
        systemPrompt: 'system',
        toolPolicy: ToolPolicy(
          deniedToolNames: const {'bash'},
          onApprovalRequired: (_) {
            approvalCount++;
            return true;
          },
        ),
        runtimeDebugEvents: events,
        sessionId: 'session',
      );

      final agentEvents = <AgentEvent>[];
      await for (final event in service.runAgentLoop([])) {
        agentEvents.add(event);
      }

      expect(tool.executedInputs, isEmpty);
      expect(approvalCount, 0);
      final done = agentEvents.whereType<AgentToolDone>().single;
      expect(done.isError, isTrue);
      expect(done.output, contains('blocked'));
      final debugEvent = events
          .recent(sessionId: 'session')
          .where((event) => event.type == 'tool.execution.denied')
          .single;
      expect(debugEvent.data, {
        'ruleType': 'tool',
        'ruleId': 'tool:bash',
      });
      expect(debugEvent.data.toString(), isNot(contains('echo secret-token')));
    });

    test('denies bash command patterns without logging raw command', () async {
      var approvalCount = 0;
      final tool = _RecordingTool(name: 'bash');
      final tools = ToolRegistry()..register(tool, risk: ToolRisk.dangerous);
      final events = RuntimeDebugEventService();
      final service = AgentService(
        llm: _ToolCallLlmService(
          _config,
          toolName: 'bash',
          arguments: const {'command': 'rm -rf /tmp/secret-project'},
        ),
        tools: tools,
        systemPrompt: 'system',
        toolPolicy: ToolPolicy(
          bashCommandDenyPatterns: const [r'rm\s+-rf'],
          onApprovalRequired: (_) {
            approvalCount++;
            return true;
          },
        ),
        runtimeDebugEvents: events,
        sessionId: 'session',
      );

      await for (final _ in service.runAgentLoop([])) {}

      expect(tool.executedInputs, isEmpty);
      expect(approvalCount, 0);
      final debugEvent = events
          .recent(sessionId: 'session')
          .where((event) => event.type == 'tool.execution.denied')
          .single;
      expect(debugEvent.data['ruleType'], 'bash_pattern');
      expect(debugEvent.data['ruleId'], 'bash_pattern_1');
      expect(debugEvent.data.toString(), isNot(contains('secret-project')));
      expect(debugEvent.data.toString(), isNot(contains('rm -rf')));
    });

    test('MCP tools require approval before execution', () async {
      var approvalCount = 0;
      final tool = _RecordingTool(name: 'mcp_12345678_echo_abcd1234');
      final tools = ToolRegistry()..register(tool, risk: ToolRisk.moderate);
      final service = AgentService(
        llm: _ToolCallLlmService(
          _config,
          toolName: tool.name,
          arguments: const {'text': 'hello'},
        ),
        tools: tools,
        systemPrompt: 'system',
        toolPolicy: ToolPolicy(
          onApprovalRequired: (_) {
            approvalCount++;
            return true;
          },
        ),
      );

      await for (final _ in service.runAgentLoop([])) {}

      expect(approvalCount, 1);
      expect(tool.executedInputs, [
        {'text': 'hello'},
      ]);
    });

    test('denies configured MCP tools before execution', () async {
      var approvalCount = 0;
      final tool = _RecordingTool(name: 'mcp_12345678_echo_abcd1234');
      final tools = ToolRegistry()..register(tool, risk: ToolRisk.moderate);
      final service = AgentService(
        llm: _ToolCallLlmService(
          _config,
          toolName: tool.name,
          arguments: const {'text': 'hello'},
        ),
        tools: tools,
        systemPrompt: 'system',
        toolPolicy: ToolPolicy(
          deniedToolNames: {tool.name},
          onApprovalRequired: (_) {
            approvalCount++;
            return true;
          },
        ),
      );

      final agentEvents = <AgentEvent>[];
      await for (final event in service.runAgentLoop([])) {
        agentEvents.add(event);
      }

      expect(approvalCount, 0);
      expect(tool.executedInputs, isEmpty);
      final done = agentEvents.whereType<AgentToolDone>().single;
      expect(done.isError, isTrue);
      expect(done.output, contains('blocked'));
    });

    test('does not execute tools from incomplete streamed tool calls',
        () async {
      var approvalCount = 0;
      final tool = _RecordingTool(name: 'bash');
      final tools = ToolRegistry()..register(tool, risk: ToolRisk.dangerous);
      final service = AgentService(
        llm: _IncompleteToolStreamLlmService(_config),
        tools: tools,
        systemPrompt: 'system',
        toolPolicy: ToolPolicy(
          onApprovalRequired: (_) {
            approvalCount++;
            return true;
          },
        ),
      );

      final agentEvents = <AgentEvent>[];
      await for (final event in service.runAgentLoop([])) {
        agentEvents.add(event);
      }

      expect(approvalCount, 0);
      expect(tool.executedInputs, isEmpty);
      expect(agentEvents.whereType<AgentToolStart>(), isEmpty);
      expect(agentEvents.whereType<AgentToolDone>(), isEmpty);
      final error = agentEvents.whereType<AgentError>().single;
      expect(error.message, contains('incomplete tool call JSON'));
    });
  });
}

const _config = LlmConfig(
  format: ApiFormat.anthropic,
  apiKey: 'sk-test',
  model: 'claude-test',
  baseUrl: 'https://api.anthropic.com',
);

class _ToolCallLlmService extends LlmService {
  final String toolName;
  final Map<String, dynamic> arguments;
  var calls = 0;

  _ToolCallLlmService(
    super.config, {
    required this.toolName,
    required this.arguments,
  });

  @override
  Stream<StreamEvent> chatStream({
    required String system,
    required List<Map<String, dynamic>> messages,
    required List<ToolDefinition> tools,
  }) async* {
    calls++;
    if (calls == 1) {
      yield StreamDone(LlmResponse(
        stopReason: 'tool_use',
        content: [
          ContentBlock(
            type: 'tool_use',
            toolUseId: 'call_1',
            toolName: toolName,
            toolInput: arguments,
          ),
        ],
      ));
      return;
    }
    yield StreamDone(const LlmResponse(
      stopReason: 'end_turn',
      content: [ContentBlock(type: 'text', text: 'done')],
    ));
  }
}

class _IncompleteToolStreamLlmService extends LlmService {
  _IncompleteToolStreamLlmService(super.config);

  @override
  Stream<StreamEvent> chatStream({
    required String system,
    required List<Map<String, dynamic>> messages,
    required List<ToolDefinition> tools,
  }) async* {
    yield ToolUseStart('call_1', 'bash');
    yield ToolInputDelta('{"command":');
    yield StreamError(
      'OpenAI stream interrupted: incomplete tool call JSON',
    );
  }
}

class _ReasoningStreamLlmService extends LlmService {
  _ReasoningStreamLlmService(super.config);

  @override
  Stream<StreamEvent> chatStream({
    required String system,
    required List<Map<String, dynamic>> messages,
    required List<ToolDefinition> tools,
  }) async* {
    yield ReasoningDelta('hidden step ');
    yield TextDelta('visible');
    yield ReasoningDelta('hidden state');
    yield StreamDone(const LlmResponse(
      stopReason: 'end_turn',
      content: [
        ContentBlock(
          type: 'text',
          text: 'visible',
          reasoningContent: 'hidden step hidden state',
        ),
      ],
    ));
  }
}

class _RecordingTool extends Tool {
  @override
  final String name;

  final executedInputs = <Map<String, dynamic>>[];

  _RecordingTool({required this.name});

  @override
  String get description => 'Recording tool';

  @override
  Map<String, dynamic> get inputSchema => const {
        'type': 'object',
        'properties': {
          'command': {'type': 'string'},
        },
      };

  @override
  Future<String> execute(Map<String, dynamic> input) async {
    executedInputs.add(Map<String, dynamic>.from(input));
    return 'executed';
  }
}
