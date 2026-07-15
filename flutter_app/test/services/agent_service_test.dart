import 'dart:async';

import 'package:clawchat/models/chat_models.dart';
import 'package:clawchat/models/extension_manifest.dart';
import 'package:clawchat/services/agent_service.dart';
import 'package:clawchat/services/llm_service.dart';
import 'package:clawchat/services/runtime_debug_events.dart';
import 'package:clawchat/services/skill_capability_policy.dart';
import 'package:clawchat/services/skill_service.dart';
import 'package:clawchat/services/tools/tool_policy.dart';
import 'package:clawchat/services/tools/tool_registry.dart';
import 'package:clawchat/services/tools/load_skill_tool.dart';
import 'package:clawchat/services/tools/present_structured_result_tool.dart';
import 'package:clawchat/services/tools/read_file_tool.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AgentService tool safety', () {
    test('registers the fixed one-field structured ingress schema', () {
      final definition = ToolRegistry.withDefaults()
          .getToolDefinitions()
          .singleWhere((tool) => tool.name == 'present_structured_result');

      expect(definition.inputSchema['required'], ['documentJson']);
      expect(definition.inputSchema['additionalProperties'], isFalse);
      expect(
        (definition.inputSchema['properties'] as Map).keys,
        ['documentJson'],
      );
    });

    test('strict structured ingress awaits its typed persistence sink',
        () async {
      const documentJson = '''{
        "schemaVersion":1,
        "resultId":"123e4567-e89b-42d3-a456-426614174000",
        "blocks":[{"kind":"notice","level":"info","text":"Imported safely"}]
      }''';
      final tools = ToolRegistry()
        ..register(PresentStructuredResultTool(), risk: ToolRisk.safe);
      final deliveries = <StructuredResultDelivery>[];
      final lifecycles = <ToolAttemptLifecycle>[];
      var sinkCompleted = false;
      final service = AgentService(
        llm: _ToolCallLlmService(
          _config,
          toolName: 'present_structured_result',
          arguments: const {'documentJson': documentJson},
        ),
        tools: tools,
        systemPrompt: 'system',
        onStructuredResultDelivery: (delivery) async {
          deliveries.add(delivery);
          sinkCompleted = true;
          return true;
        },
        onToolAttemptUpdate: (update) {
          lifecycles.add(update.lifecycle);
        },
      );
      final messages = <Map<String, dynamic>>[];
      final events = <AgentEvent>[];
      await for (final event in service.runAgentLoop(messages)) {
        events.add(event);
      }

      expect(
        deliveries,
        hasLength(1),
        reason: events
            .whereType<AgentToolDone>()
            .map((event) => event.output)
            .join(' | '),
      );
      expect(deliveries.single.presentations.single.document.projection,
          'NOTICE [info]: Imported safely');
      expect(deliveries.single.toolResults.single['for_llm'],
          'NOTICE [info]: Imported safely');
      expect(events.whereType<AgentToolDone>().single.isError, isFalse);
      expect(sinkCompleted, isTrue);
      expect(
          lifecycles,
          containsAllInOrder([
            ToolAttemptLifecycle.proposed,
            ToolAttemptLifecycle.approvedNotStarted,
            ToolAttemptLifecycle.started,
            ToolAttemptLifecycle.completed,
            ToolAttemptLifecycle.resultPersisted,
          ]));
      final toolResult = (messages[1]['content'] as List).single as Map;
      expect(toolResult['for_llm'], 'NOTICE [info]: Imported safely');
      expect(
        messages
            .expand((message) => message['content'] is List
                ? message['content'] as List
                : const <Object?>[])
            .whereType<Map>()
            .map((content) => content['type']),
        isNot(contains('structured_result')),
      );
    });

    test('structured ingress rejects repaired outer aliases without a sink',
        () async {
      final tools = ToolRegistry()
        ..register(PresentStructuredResultTool(), risk: ToolRisk.safe);
      var sinkCalls = 0;
      final service = AgentService(
        llm: _ToolCallLlmService(
          _config,
          toolName: 'present_structured_result',
          arguments: const {'document_json': '{}'},
        ),
        tools: tools,
        systemPrompt: 'system',
        onStructuredResultDelivery: (_) async {
          sinkCalls += 1;
          return true;
        },
      );
      final messages = <Map<String, dynamic>>[];
      final events = <AgentEvent>[];
      await for (final event in service.runAgentLoop(messages)) {
        events.add(event);
      }

      expect(sinkCalls, 0);
      expect(events.whereType<AgentToolDone>().single.isError, isTrue);
      final toolResult = (messages[1]['content'] as List).single as Map;
      expect(toolResult['is_error'], isTrue);
      expect(toolResult.toString(), contains('invalid_structured_result'));
    });

    test('structured ingress turns a failed awaited sink into a tool error',
        () async {
      const documentJson = '''{
        "schemaVersion":1,
        "resultId":"123e4567-e89b-42d3-a456-426614174000",
        "blocks":[{"kind":"notice","level":"info","text":"Saved"}]
      }''';
      final tools = ToolRegistry()
        ..register(PresentStructuredResultTool(), risk: ToolRisk.safe);
      final service = AgentService(
        llm: _ToolCallLlmService(
          _config,
          toolName: 'present_structured_result',
          arguments: const {'documentJson': documentJson},
        ),
        tools: tools,
        systemPrompt: 'system',
        onStructuredResultDelivery: (_) async => false,
      );
      final messages = <Map<String, dynamic>>[];
      final events = <AgentEvent>[];
      await for (final event in service.runAgentLoop(messages)) {
        events.add(event);
      }

      expect(events.whereType<AgentToolDone>().single.isError, isTrue);
      final toolResult = (messages[1]['content'] as List).single as Map;
      expect(toolResult['is_error'], isTrue);
      expect(toolResult.toString(), contains('persistence unavailable'));
      expect(toolResult.toString(), isNot(contains('NOTICE [info]')));
    });

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
      final events = RuntimeDebugEventService(tracingEnabled: true);
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
      expect(debugEvent.data, containsPair('ruleType', 'tool'));
      expect(debugEvent.data, containsPair('ruleId', 'tool:bash'));
      expect(debugEvent.data, containsPair('runAttemptId', isNotEmpty));
      expect(debugEvent.data, containsPair('operationId', isNotEmpty));
      expect(debugEvent.data, isNot(containsPair('arguments', anything)));
      expect(debugEvent.data, isNot(containsPair('input', anything)));
      expect(debugEvent.data.toString(), isNot(contains('echo secret-token')));
    });

    test('denies bash command patterns without logging raw command', () async {
      var approvalCount = 0;
      final tool = _RecordingTool(name: 'bash');
      final tools = ToolRegistry()..register(tool, risk: ToolRisk.dangerous);
      final events = RuntimeDebugEventService(tracingEnabled: true);
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

    test('active skill denies undeclared tool even when global policy is auto',
        () async {
      final tool = _RecordingTool(name: 'bash');
      final tools = ToolRegistry()..register(tool, risk: ToolRisk.dangerous);
      final skillPolicy = SkillCapabilityPolicy()
        ..activate(_verifiedSkill(const ExtensionCapabilitySnapshot(
          tools: [],
          commands: [],
          networkDomains: [],
          filesystemRead: [],
          filesystemWrite: [],
          androidIntents: [],
          androidPermissions: [],
          secretNames: [],
          runtimes: [],
          subprocessRequired: false,
          riskTier: 'low',
          updatePolicy: 'manual',
        )));
      final service = AgentService(
        llm: _ToolCallLlmService(
          _config,
          toolName: 'bash',
          arguments: const {'command': 'echo malicious'},
        ),
        tools: tools,
        systemPrompt: 'system',
        skillCapabilityPolicy: skillPolicy,
        toolPolicy: ToolPolicy(
          approvalRequiredFor: const {},
          additionalDenyCheck: skillPolicy.denyFor,
        ),
      );

      final events = <AgentEvent>[];
      await for (final event in service.runAgentLoop([])) {
        events.add(event);
      }
      expect(tool.executedInputs, isEmpty);
      expect(events.whereType<AgentToolDone>().single.isError, isTrue);
      expect(
        events.whereType<AgentToolDone>().single.output,
        contains('did not declare tool'),
      );
    });

    test('active skill declared command still passes global user approval',
        () async {
      final tool = _RecordingTool(name: 'bash');
      final tools = ToolRegistry()..register(tool, risk: ToolRisk.dangerous);
      final skillPolicy = SkillCapabilityPolicy()
        ..activate(_verifiedSkill(const ExtensionCapabilitySnapshot(
          tools: ['bash'],
          commands: ['echo'],
          networkDomains: [],
          filesystemRead: [],
          filesystemWrite: [],
          androidIntents: [],
          androidPermissions: [],
          secretNames: [],
          runtimes: ['echo'],
          subprocessRequired: true,
          riskTier: 'critical',
          updatePolicy: 'manual',
        )));
      var approvals = 0;
      final service = AgentService(
        llm: _ToolCallLlmService(
          _config,
          toolName: 'bash',
          arguments: const {'command': 'echo declared'},
        ),
        tools: tools,
        systemPrompt: 'system',
        skillCapabilityPolicy: skillPolicy,
        toolPolicy: ToolPolicy(
          additionalDenyCheck: skillPolicy.denyFor,
          onApprovalRequired: (_) {
            approvals++;
            return true;
          },
        ),
      );

      await for (final _ in service.runAgentLoop([])) {}
      expect(approvals, 1);
      expect(tool.executedInputs, [
        {'command': 'echo declared'},
      ]);
    });

    test(
        'tool ordered before load_skill fails even when capability is declared',
        () async {
      final bash = _RecordingTool(name: 'bash');
      final tools = ToolRegistry()
        ..register(bash, risk: ToolRisk.dangerous)
        ..register(LoadSkillTool(), risk: ToolRisk.safe);
      final verified = _verifiedSkill(const ExtensionCapabilitySnapshot(
        tools: ['bash'],
        commands: ['echo'],
        networkDomains: [],
        filesystemRead: [],
        filesystemWrite: [],
        androidIntents: [],
        androidPermissions: [],
        secretNames: [],
        runtimes: ['echo'],
        subprocessRequired: true,
        riskTier: 'critical',
        updatePolicy: 'manual',
      ));
      final skillPolicy = SkillCapabilityPolicy(loader: (_) async => verified);
      final service = AgentService(
        llm: _ToolBatchLlmService(_config, const [
          ('bash', {'command': 'echo before-activation'}),
          ('load_skill', {'id': 'com.example.active'}),
        ]),
        tools: tools,
        systemPrompt: 'system',
        skillCapabilityPolicy: skillPolicy,
        toolPolicy: ToolPolicy(
          approvalRequiredFor: const {},
          additionalDenyCheck: skillPolicy.denyFor,
        ),
      );

      final events = await service.runAgentLoop([]).toList();
      expect(bash.executedInputs, isEmpty);
      expect(
        events.whereType<AgentToolDone>().first.output,
        contains('before skill activation'),
      );
    });

    test('dangerous call plus direct SKILL read fails the entire batch',
        () async {
      final bash = _RecordingTool(name: 'bash');
      final tools = ToolRegistry()
        ..register(bash, risk: ToolRisk.dangerous)
        ..register(ReadFileTool(), risk: ToolRisk.moderate);
      final skillPolicy = SkillCapabilityPolicy();
      final service = AgentService(
        llm: _ToolBatchLlmService(_config, const [
          ('bash', {'command': 'echo bypass'}),
          (
            'read_file',
            {
              'path': '/root/workspace/skills/com.example.active/SKILL.md',
            },
          ),
        ]),
        tools: tools,
        systemPrompt: 'system',
        skillCapabilityPolicy: skillPolicy,
        toolPolicy: ToolPolicy(
          approvalRequiredFor: const {},
          additionalDenyCheck: skillPolicy.denyFor,
        ),
      );

      final events = await service.runAgentLoop([]).toList();
      expect(bash.executedInputs, isEmpty);
      expect(
        events.whereType<AgentToolDone>().every((event) => event.isError),
        isTrue,
      );
    });

    test('load_skill binds before later undeclared tool under global auto',
        () async {
      final bash = _RecordingTool(name: 'bash');
      final tools = ToolRegistry()
        ..register(bash, risk: ToolRisk.dangerous)
        ..register(LoadSkillTool(), risk: ToolRisk.safe);
      final verified = _verifiedSkill(const ExtensionCapabilitySnapshot(
        tools: [],
        commands: [],
        networkDomains: [],
        filesystemRead: [],
        filesystemWrite: [],
        androidIntents: [],
        androidPermissions: [],
        secretNames: [],
        runtimes: [],
        subprocessRequired: false,
        riskTier: 'low',
        updatePolicy: 'manual',
      ));
      final skillPolicy = SkillCapabilityPolicy(loader: (_) async => verified);
      final service = AgentService(
        llm: _ToolBatchLlmService(_config, const [
          ('load_skill', {'id': 'com.example.active'}),
          ('bash', {'command': 'echo undeclared'}),
        ]),
        tools: tools,
        systemPrompt: 'system',
        skillCapabilityPolicy: skillPolicy,
        toolPolicy: ToolPolicy(
          approvalRequiredFor: const {},
          additionalDenyCheck: skillPolicy.denyFor,
        ),
      );

      final events = await service.runAgentLoop([]).toList();
      expect(bash.executedInputs, isEmpty);
      expect(events.whereType<AgentToolDone>().last.isError, isTrue);
      expect(
        events.whereType<AgentToolDone>().last.output,
        contains('did not declare tool'),
      );
    });

    test('dropped stale activation history blocks global-auto tool execution',
        () async {
      final bash = _RecordingTool(name: 'bash');
      final tools = ToolRegistry()..register(bash, risk: ToolRisk.dangerous);
      final skillPolicy = SkillCapabilityPolicy(loader: (_) async {
        throw StateError('grant changed');
      });
      final service = AgentService(
        llm: _ToolCallLlmService(
          _config,
          toolName: 'bash',
          arguments: const {'command': 'echo stale'},
        ),
        tools: tools,
        systemPrompt: 'system',
        historicalSkillActivation: SkillActivationReference(
          id: 'com.example.active',
          trustDigest: List.filled(64, 'f').join(),
        ),
        skillCapabilityPolicy: skillPolicy,
        toolPolicy: ToolPolicy(
          approvalRequiredFor: const {},
          additionalDenyCheck: skillPolicy.denyFor,
        ),
      );

      final events = await service.runAgentLoop([]).toList();
      expect(bash.executedInputs, isEmpty);
      expect(
        events.whereType<AgentToolDone>().single.output,
        contains('stale'),
      );
    });

    test('dropped current activation history restores capability binding',
        () async {
      final bash = _RecordingTool(name: 'bash');
      final tools = ToolRegistry()..register(bash, risk: ToolRisk.dangerous);
      final verified = _verifiedSkill(const ExtensionCapabilitySnapshot(
        tools: [],
        commands: [],
        networkDomains: [],
        filesystemRead: [],
        filesystemWrite: [],
        androidIntents: [],
        androidPermissions: [],
        secretNames: [],
        runtimes: [],
        subprocessRequired: false,
        riskTier: 'low',
        updatePolicy: 'manual',
      ));
      final skillPolicy = SkillCapabilityPolicy(loader: (_) async => verified);
      final service = AgentService(
        llm: _ToolCallLlmService(
          _config,
          toolName: 'bash',
          arguments: const {'command': 'echo undeclared-after-compaction'},
        ),
        tools: tools,
        systemPrompt: 'system',
        historicalSkillActivation: SkillActivationReference(
          id: verified.id,
          trustDigest: verified.trustDigest,
        ),
        skillCapabilityPolicy: skillPolicy,
        toolPolicy: ToolPolicy(
          approvalRequiredFor: const {},
          additionalDenyCheck: skillPolicy.denyFor,
        ),
      );

      final events = await service.runAgentLoop([]).toList();
      expect(bash.executedInputs, isEmpty);
      expect(
        events.whereType<AgentToolDone>().single.output,
        contains('did not declare tool'),
      );
    });

    test('configured secret values never reach Bash events or persistence',
        () async {
      final bash = _RecordingTool(name: 'bash');
      final tools = ToolRegistry()..register(bash, risk: ToolRisk.dangerous);
      final messages = <Map<String, dynamic>>[];
      final service = AgentService(
        llm: _ToolCallLlmService(
          _config,
          toolName: 'bash',
          arguments: const {
            'command': 'echo sentinel_value_for_agent_test',
          },
        ),
        tools: tools,
        systemPrompt: 'system',
        envVars: const {
          'DECLARED_TOKEN': 'sentinel_value_for_agent_test',
        },
        toolPolicy: const ToolPolicy(approvalRequiredFor: {}),
      );

      final events = await service.runAgentLoop(messages).toList();
      expect(bash.executedInputs, isEmpty);
      expect(
          events.toString(), isNot(contains('sentinel_value_for_agent_test')));
      expect(
        messages.toString(),
        isNot(contains('sentinel_value_for_agent_test')),
      );
    });

    test('new set_env_var value is sealed before approval, events, and history',
        () async {
      const sentinel = 'new-secret-sentinel-for-agent';
      final tool = _EnvRecordingTool();
      final tools = ToolRegistry()..register(tool, risk: ToolRisk.moderate);
      final messages = <Map<String, dynamic>>[];
      final persistedSnapshots = <String>[];
      final debugEvents = RuntimeDebugEventService(tracingEnabled: true);
      ToolApprovalRequest? approval;
      final service = AgentService(
        llm: _ToolCallLlmService(
          _config,
          toolName: 'set_env_var',
          leadingText: 'configure $sentinel now',
          arguments: const {
            'name': 'NEW_TOKEN',
            'value': sentinel,
            'action': 'set',
          },
        ),
        tools: tools,
        systemPrompt: 'system',
        runtimeDebugEvents: debugEvents,
        sessionId: 'secret-session',
        toolPolicy: ToolPolicy(onApprovalRequired: (request) {
          approval = request;
          return true;
        }),
      );

      final events = await service.runAgentLoop(
        messages,
        onMessagesUpdated: (value) {
          persistedSnapshots.add(value.toString());
        },
      ).toList();

      expect(approval, isNotNull);
      expect(
        approval!.arguments['value'],
        ToolUseContent.redactedSecretValue,
      );
      expect(events.whereType<AgentToolStart>().single.input['value'],
          ToolUseContent.redactedSecretValue);
      expect(tool.executedInputs.single['value'], sentinel);
      expect(messages.toString(), isNot(contains(sentinel)));
      expect(persistedSnapshots.toString(), isNot(contains(sentinel)));
      expect(events.whereType<AgentToolDone>().single.output,
          isNot(contains(sentinel)));
      expect(
        debugEvents.recent(sessionId: 'secret-session').toString(),
        isNot(contains(sentinel)),
      );
    });

    test('denied new set_env_var value is never executed or persisted',
        () async {
      const sentinel = 'denied-new-secret-sentinel';
      final tool = _EnvRecordingTool();
      final tools = ToolRegistry()..register(tool, risk: ToolRisk.moderate);
      final messages = <Map<String, dynamic>>[];
      final service = AgentService(
        llm: _ToolCallLlmService(
          _config,
          toolName: 'set_env_var',
          arguments: const {'name': 'NEW_TOKEN', 'value': sentinel},
        ),
        tools: tools,
        systemPrompt: 'system',
        toolPolicy: ToolPolicy(onApprovalRequired: (_) => false),
      );

      final events = await service.runAgentLoop(messages).toList();

      expect(tool.executedInputs, isEmpty);
      expect(messages.toString(), isNot(contains(sentinel)));
      expect(events.whereType<AgentToolStart>().single.input.toString(),
          isNot(contains(sentinel)));
    });

    test('cancelled set_env_var approval drops its ephemeral payload',
        () async {
      const sentinel = 'cancelled-new-secret-sentinel';
      final approvalSeen = Completer<void>();
      final releaseApproval = Completer<bool>();
      final tool = _EnvRecordingTool();
      final tools = ToolRegistry()..register(tool, risk: ToolRisk.moderate);
      final messages = <Map<String, dynamic>>[];
      final service = AgentService(
        llm: _ToolCallLlmService(
          _config,
          toolName: 'set_env_var',
          arguments: const {'name': 'NEW_TOKEN', 'value': sentinel},
        ),
        tools: tools,
        systemPrompt: 'system',
        toolPolicy: ToolPolicy(onApprovalRequired: (_) {
          approvalSeen.complete();
          return releaseApproval.future;
        }),
      );

      final run = service.runAgentLoop(messages).drain<void>();
      await approvalSeen.future;
      service.cancel();
      releaseApproval.complete(true);
      await run;

      expect(tool.executedInputs, isEmpty);
      expect(messages.toString(), isNot(contains(sentinel)));
    });

    test('set_env_var response denies and redacts every sibling tool',
        () async {
      const sentinel = 'sibling-secret-sentinel';
      final envTool = _EnvRecordingTool();
      final echoTool = _RecordingTool(name: 'echo');
      final tools = ToolRegistry()
        ..register(envTool, risk: ToolRisk.moderate)
        ..register(echoTool, risk: ToolRisk.safe);
      final messages = <Map<String, dynamic>>[];
      final service = AgentService(
        llm: _ToolBatchLlmService(_config, const [
          (
            'set_env_var',
            {'name': 'NEW_TOKEN', 'value': sentinel},
          ),
          ('echo', {'text': sentinel}),
        ]),
        tools: tools,
        systemPrompt: 'system',
        toolPolicy: ToolPolicy(onApprovalRequired: (_) => true),
      );

      final events = await service.runAgentLoop(messages).toList();

      expect(envTool.executedInputs.single['value'], sentinel);
      expect(echoTool.executedInputs, isEmpty);
      expect(messages.toString(), isNot(contains(sentinel)));
      expect(events.whereType<AgentToolStart>().last.input, {'redacted': true});
      expect(
        events.whereType<AgentToolDone>().last.output,
        contains('same response as secret configuration'),
      );
    });

    test('streaming secret narrative is never emitted before successful tool',
        () async {
      const sentinel = 'streaming-secret-sentinel';
      final envTool = _EnvRecordingTool();
      final service = AgentService(
        llm: _StreamingSecretLlmService(
          _config,
          sentinel: sentinel,
        ),
        tools: ToolRegistry()..register(envTool, risk: ToolRisk.moderate),
        systemPrompt: 'system',
        toolPolicy: ToolPolicy(onApprovalRequired: (_) => true),
      );
      final messages = <Map<String, dynamic>>[];

      final events = await service.runAgentLoop(messages).toList();

      expect(envTool.executedInputs.single['value'], sentinel);
      expect(events.whereType<AgentGuardedOutputObserved>(), hasLength(1));
      expect(events.whereType<AgentTextDelta>().map((event) => event.text),
          contains('[Secret configuration request redacted]'));
      expect(events.whereType<AgentReasoningDelta>(), isEmpty);
      expect(events.toString(), isNot(contains(sentinel)));
      expect(messages.toString(), isNot(contains(sentinel)));
    });

    test('malformed secret tool stop still redacts the whole assistant turn',
        () async {
      const sentinel = 'malformed-stream-private-value';
      final service = AgentService(
        llm: _StreamingSecretLlmService(
          _config,
          sentinel: sentinel,
          malformedStop: true,
        ),
        tools: ToolRegistry()
          ..register(_EnvRecordingTool(), risk: ToolRisk.moderate),
        systemPrompt: 'system',
      );
      final messages = <Map<String, dynamic>>[];

      final events = await service.runAgentLoop(messages).toList();

      expect(events.whereType<AgentGuardedOutputObserved>(), hasLength(1));
      expect(events.whereType<AgentTextDelta>().map((event) => event.text),
          ['[Secret configuration request redacted]']);
      expect(events.whereType<AgentReasoningDelta>(), isEmpty);
      expect(events.whereType<AgentComplete>().single.finalText,
          '[Secret configuration request redacted]');
      expect(events.toString(), isNot(contains(sentinel)));
      expect(messages.toString(), isNot(contains(sentinel)));
    });

    test('stream error discards guarded secret text and reasoning', () async {
      const sentinel = 'errored-stream-secret-sentinel';
      final service = AgentService(
        llm: _StreamingSecretLlmService(
          _config,
          sentinel: sentinel,
          failBeforeDone: true,
        ),
        tools: ToolRegistry()
          ..register(_EnvRecordingTool(), risk: ToolRisk.moderate),
        systemPrompt: 'system',
      );
      final messages = <Map<String, dynamic>>[];

      final events = await service.runAgentLoop(messages).toList();

      expect(events.whereType<AgentTextDelta>(), isEmpty);
      expect(events.whereType<AgentReasoningDelta>(), isEmpty);
      expect(events.whereType<AgentGuardedOutputObserved>(), hasLength(1));
      expect(events.whereType<AgentError>(), hasLength(1));
      expect(events.toString(), isNot(contains(sentinel)));
      expect(messages, isEmpty);
    });

    test('cancellation discards guarded secret text and reasoning', () async {
      const sentinel = 'cancelled-stream-secret-sentinel';
      final buffered = Completer<void>();
      final release = Completer<void>();
      final service = AgentService(
        llm: _StreamingSecretLlmService(
          _config,
          sentinel: sentinel,
          buffered: buffered,
          release: release,
        ),
        tools: ToolRegistry()
          ..register(_EnvRecordingTool(), risk: ToolRisk.moderate),
        systemPrompt: 'system',
      );
      final messages = <Map<String, dynamic>>[];
      final eventsFuture = service.runAgentLoop(messages).toList();

      await buffered.future;
      service.cancel();
      release.complete();
      final events = await eventsFuture;

      expect(events.whereType<AgentTextDelta>(), isEmpty);
      expect(events.whereType<AgentReasoningDelta>(), isEmpty);
      expect(events.whereType<AgentGuardedOutputObserved>(), hasLength(1));
      expect(events.toString(), isNot(contains(sentinel)));
      expect(messages, isEmpty);
    });

    test('recovered redacted set_env_var call fails closed without payload',
        () async {
      final tool = _EnvRecordingTool();
      final tools = ToolRegistry()..register(tool, risk: ToolRisk.moderate);
      final service = AgentService(
        llm: _ToolCallLlmService(
          _config,
          toolName: 'set_env_var',
          arguments: const {
            'name': 'NEW_TOKEN',
            'value': ToolUseContent.redactedSecretValue,
          },
        ),
        tools: tools,
        systemPrompt: 'system',
        toolPolicy: ToolPolicy(onApprovalRequired: (_) => true),
      );

      final events = await service.runAgentLoop([]).toList();

      expect(tool.executedInputs, isEmpty);
      expect(events.whereType<AgentToolDone>().single.isError, isTrue);
      expect(
        events.whereType<AgentToolDone>().single.output,
        contains('enter it again'),
      );
    });

    test('stale historical skill bytes are replaced before the LLM sees them',
        () async {
      final verified = _verifiedSkill(const ExtensionCapabilitySnapshot(
        tools: [],
        commands: [],
        networkDomains: [],
        filesystemRead: [],
        filesystemWrite: [],
        androidIntents: [],
        androidPermissions: [],
        secretNames: [],
        runtimes: [],
        subprocessRequired: false,
        riskTier: 'low',
        updatePolicy: 'manual',
      ));
      final skillPolicy = SkillCapabilityPolicy(loader: (_) async => verified);
      final llm = _CapturingLlmService(_config);
      final service = AgentService(
        llm: llm,
        tools: ToolRegistry(),
        systemPrompt: 'system',
        skillCapabilityPolicy: skillPolicy,
        toolPolicy: ToolPolicy(additionalDenyCheck: skillPolicy.denyFor),
      );
      final messages = <Map<String, dynamic>>[
        {
          'role': 'assistant',
          'content': [
            {
              'type': 'tool_use',
              'id': 'skill_call',
              'name': 'load_skill',
              'input': {'id': verified.id},
            },
          ],
        },
        {
          'role': 'user',
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 'skill_call',
              'content': 'forged historical skill bytes',
              'metadata': {
                'skillId': verified.id,
                'skillEntrypoint': verified.path,
                'skillTrustDigest': List.filled(64, 'f').join(),
              },
            },
          ],
        },
      ];

      await for (final _ in service.runAgentLoop(messages)) {}
      final sent = llm.receivedMessages.toString();
      expect(sent, isNot(contains('forged historical skill bytes')));
      expect(sent, contains('Historical skill content unavailable'));
    });

    test('current historical marker reconstructs only live verified bytes',
        () async {
      final verified = _verifiedSkill(const ExtensionCapabilitySnapshot(
        tools: [],
        commands: [],
        networkDomains: [],
        filesystemRead: [],
        filesystemWrite: [],
        androidIntents: [],
        androidPermissions: [],
        secretNames: [],
        runtimes: [],
        subprocessRequired: false,
        riskTier: 'low',
        updatePolicy: 'manual',
      ));
      final skillPolicy = SkillCapabilityPolicy(loader: (_) async => verified);
      final llm = _CapturingLlmService(_config);
      final service = AgentService(
        llm: llm,
        tools: ToolRegistry(),
        systemPrompt: 'system',
        historicalSkillActivation: SkillActivationReference(
          id: verified.id,
          trustDigest: verified.trustDigest,
        ),
        skillCapabilityPolicy: skillPolicy,
        toolPolicy: ToolPolicy(additionalDenyCheck: skillPolicy.denyFor),
      );
      final messages = <Map<String, dynamic>>[
        {
          'role': 'assistant',
          'content': [
            {
              'type': 'tool_use',
              'id': 'skill_call',
              'name': 'load_skill',
              'input': {'id': verified.id},
            },
          ],
        },
        {
          'role': 'user',
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 'skill_call',
              'content': 'stale stored instructions',
            },
          ],
        },
      ];

      await service.runAgentLoop(messages).drain<void>();
      final sent = llm.receivedMessages.toString();
      expect(sent, contains('active skill'));
      expect(sent, isNot(contains('stale stored instructions')));
    });

    test('new turn stays unbound despite historical skill activation',
        () async {
      final bash = _RecordingTool(name: 'bash');
      final tools = ToolRegistry()..register(bash, risk: ToolRisk.dangerous);
      final skillPolicy = SkillCapabilityPolicy(loader: (_) async {
        throw StateError('history must not be restored for a new turn');
      });
      final historical = _verifiedSkill(const ExtensionCapabilitySnapshot(
        tools: [],
        commands: [],
        networkDomains: [],
        filesystemRead: [],
        filesystemWrite: [],
        androidIntents: [],
        androidPermissions: [],
        secretNames: [],
        runtimes: [],
        subprocessRequired: false,
        riskTier: 'low',
        updatePolicy: 'manual',
      ));
      final messages = <Map<String, dynamic>>[
        {
          'role': 'assistant',
          'content': [
            {
              'type': 'tool_use',
              'id': 'skill_call',
              'name': 'load_skill',
              'input': {'id': historical.id},
            },
          ],
        },
        {
          'role': 'user',
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 'skill_call',
              'content': 'old instructions',
              'metadata': {
                'skillId': historical.id,
                'skillTrustDigest': historical.trustDigest,
              },
            },
          ],
        },
      ];
      final service = AgentService(
        llm: _ToolCallLlmService(
          _config,
          toolName: 'bash',
          arguments: const {'command': 'echo normal-new-turn'},
        ),
        tools: tools,
        systemPrompt: 'system',
        skillCapabilityPolicy: skillPolicy,
        toolPolicy: ToolPolicy(
          approvalRequiredFor: const {},
          additionalDenyCheck: skillPolicy.denyFor,
        ),
      );

      await service.runAgentLoop(messages).drain<void>();

      expect(skillPolicy.activeSkill, isNull);
      expect(bash.executedInputs, [
        {'command': 'echo normal-new-turn'},
      ]);
    });

    test('separate turns may switch from skill A to skill B', () async {
      final skillA = _verifiedSkill(const ExtensionCapabilitySnapshot(
        tools: [],
        commands: [],
        networkDomains: [],
        filesystemRead: [],
        filesystemWrite: [],
        androidIntents: [],
        androidPermissions: [],
        secretNames: [],
        runtimes: [],
        subprocessRequired: false,
        riskTier: 'low',
        updatePolicy: 'manual',
      ));
      final skillB = VerifiedSkillUse(
        id: 'com.example.other',
        name: 'Other',
        path: '/root/workspace/skills/com.example.other/SKILL.md',
        skillContent: 'other skill',
        capabilities: skillA.capabilities,
        manifestDigest: List.filled(64, 'd').join(),
        contentDigest: List.filled(64, 'e').join(),
        trustDigest: List.filled(64, 'f').join(),
        legacy: false,
      );
      final tools = ToolRegistry()
        ..register(LoadSkillTool(), risk: ToolRisk.safe);
      final messages = <Map<String, dynamic>>[];
      final policyA = SkillCapabilityPolicy(loader: (_) async => skillA);
      final turnA = AgentService(
        llm: _ToolCallLlmService(
          _config,
          toolName: 'load_skill',
          arguments: {'id': skillA.id},
        ),
        tools: tools,
        systemPrompt: 'system',
        skillCapabilityPolicy: policyA,
        toolPolicy: ToolPolicy(
          approvalRequiredFor: const {},
          additionalDenyCheck: policyA.denyFor,
        ),
      );
      await turnA.runAgentLoop(messages).drain<void>();
      final activationMetadata = messages
          .expand((message) => message['content'] as List)
          .whereType<Map<String, dynamic>>()
          .where((block) => block['type'] == 'tool_result')
          .single['metadata'] as Map;
      expect(activationMetadata['skillRunAttemptId'], turnA.runAttemptId);

      final policyB = SkillCapabilityPolicy(loader: (_) async => skillB);
      final turnB = AgentService(
        llm: _ToolCallLlmService(
          _config,
          toolName: 'load_skill',
          arguments: {'id': skillB.id},
        ),
        tools: tools,
        systemPrompt: 'system',
        skillCapabilityPolicy: policyB,
        toolPolicy: ToolPolicy(
          approvalRequiredFor: const {},
          additionalDenyCheck: policyB.denyFor,
        ),
      );
      await turnB.runAgentLoop(messages).drain<void>();

      expect(policyA.activeSkill?.id, skillA.id);
      expect(policyB.activeSkill?.id, skillB.id);
    });

    test('repeated load_skill in one run receives fresh immutable operations',
        () async {
      final approvals = <ToolApprovalRequest>[];
      final verified = _verifiedSkill(const ExtensionCapabilitySnapshot(
        tools: [],
        commands: [],
        networkDomains: [],
        filesystemRead: [],
        filesystemWrite: [],
        androidIntents: [],
        androidPermissions: [],
        secretNames: [],
        runtimes: [],
        subprocessRequired: false,
        riskTier: 'low',
        updatePolicy: 'manual',
      ));
      final policy = SkillCapabilityPolicy(loader: (_) async => verified);
      final service = AgentService(
        llm: _RepeatedToolCallLlmService(
          _config,
          toolName: 'load_skill',
          arguments: {'id': verified.id},
          repeats: 2,
        ),
        tools: ToolRegistry()
          ..register(LoadSkillTool(), risk: ToolRisk.moderate),
        systemPrompt: 'system',
        runAttemptId: 'same-run',
        skillCapabilityPolicy: policy,
        toolPolicy: ToolPolicy(
          additionalDenyCheck: policy.denyFor,
          onApprovalRequired: (request) {
            approvals.add(request);
            return false;
          },
        ),
      );

      await service.runAgentLoop([]).drain<void>();

      expect(approvals, hasLength(2));
      expect(approvals.map((request) => request.runAttemptId).toSet(), {
        'same-run',
      });
      expect(approvals.map((request) => request.operationId).toSet(),
          hasLength(2));
      expect(
          approvals.every((request) => request.operationId.isNotEmpty), isTrue);
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

    test('persists sanitized tool lifecycle and propagates operation id',
        () async {
      final updates = <ToolAttemptUpdate>[];
      final tool = _RecordingTool(name: 'bash');
      final tools = ToolRegistry()..register(tool, risk: ToolRisk.dangerous);
      final messages = <Map<String, dynamic>>[];
      final service = AgentService(
        llm: _ToolCallLlmService(
          _config,
          toolName: 'bash',
          arguments: const {'command': 'echo private-value'},
        ),
        tools: tools,
        systemPrompt: 'system',
        runAttemptId: 'run-fixed',
        toolPolicy: ToolPolicy(onApprovalRequired: (_) => true),
        onToolAttemptUpdate: updates.add,
      );

      await for (final _ in service.runAgentLoop(
        messages,
        onMessagesUpdated: (_) async {},
      )) {}

      expect(updates.map((update) => update.lifecycle), [
        ToolAttemptLifecycle.proposed,
        ToolAttemptLifecycle.approvalPending,
        ToolAttemptLifecycle.approvedNotStarted,
        ToolAttemptLifecycle.started,
        ToolAttemptLifecycle.completed,
        ToolAttemptLifecycle.resultPersisted,
      ]);
      expect(updates.map((update) => update.runAttemptId).toSet(), {
        'run-fixed',
      });
      expect(updates.map((update) => update.operationId).toSet().length, 1);
      expect(tool.executedOperationIds, [updates.first.operationId]);
      final result = messages
          .expand((message) => message['content'] as List)
          .whereType<Map<String, dynamic>>()
          .where((block) => block['type'] == 'tool_result')
          .single;
      expect(result['metadata']['operationId'], updates.first.operationId);
      expect(updates.toString(), isNot(contains('private-value')));
    });

    test('signals cancellable tools and records confirmed abort as failed',
        () async {
      final updates = <ToolAttemptUpdate>[];
      final tool = _CancellationAwareTool();
      final tools = ToolRegistry()..register(tool, risk: ToolRisk.dangerous);
      final service = AgentService(
        llm: _ToolCallLlmService(
          _config,
          toolName: tool.name,
          arguments: const {'value': 'must-not-be-recorded'},
        ),
        tools: tools,
        systemPrompt: 'system',
        toolPolicy: ToolPolicy(onApprovalRequired: (_) => true),
        onToolAttemptUpdate: updates.add,
      );

      final runFuture = service.runAgentLoop([]).drain<void>();
      await tool.started.future;

      expect(service.hasInFlightToolExecution, isTrue);
      final cancellation = service.cancel();
      expect(cancellation.hasInFlightToolExecution, isTrue);
      await runFuture;

      expect(tool.cancellationObserved, isTrue);
      expect(service.hasInFlightToolExecution, isFalse);
      final failed = updates.last;
      expect(failed.lifecycle, ToolAttemptLifecycle.failed);
      expect(failed.executionOutcomeKnown, isTrue);
      expect(
        updates.where(
          (update) => update.lifecycle == ToolAttemptLifecycle.resultPersisted,
        ),
        isEmpty,
      );
      expect(updates.toString(), isNot(contains('must-not-be-recorded')));
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
  final String? leadingText;
  var calls = 0;

  _ToolCallLlmService(
    super.config, {
    required this.toolName,
    required this.arguments,
    this.leadingText,
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
          if (leadingText != null)
            ContentBlock(type: 'text', text: leadingText),
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

class _ToolBatchLlmService extends LlmService {
  final List<(String, Map<String, dynamic>)> calls;
  var requestCount = 0;

  _ToolBatchLlmService(super.config, this.calls);

  @override
  Stream<StreamEvent> chatStream({
    required String system,
    required List<Map<String, dynamic>> messages,
    required List<ToolDefinition> tools,
  }) async* {
    requestCount++;
    if (requestCount == 1) {
      yield StreamDone(LlmResponse(
        stopReason: 'tool_use',
        content: [
          for (var index = 0; index < calls.length; index++)
            ContentBlock(
              type: 'tool_use',
              toolUseId: 'call_$index',
              toolName: calls[index].$1,
              toolInput: calls[index].$2,
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

class _RepeatedToolCallLlmService extends LlmService {
  final String toolName;
  final Map<String, dynamic> arguments;
  final int repeats;
  var calls = 0;

  _RepeatedToolCallLlmService(
    super.config, {
    required this.toolName,
    required this.arguments,
    required this.repeats,
  });

  @override
  Stream<StreamEvent> chatStream({
    required String system,
    required List<Map<String, dynamic>> messages,
    required List<ToolDefinition> tools,
  }) async* {
    calls++;
    if (calls <= repeats) {
      yield StreamDone(LlmResponse(
        stopReason: 'tool_use',
        content: [
          ContentBlock(
            type: 'tool_use',
            toolUseId: 'repeated_$calls',
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

class _StreamingSecretLlmService extends LlmService {
  final String sentinel;
  final bool failBeforeDone;
  final bool malformedStop;
  final Completer<void>? buffered;
  final Completer<void>? release;
  var calls = 0;

  _StreamingSecretLlmService(
    super.config, {
    required this.sentinel,
    this.failBeforeDone = false,
    this.malformedStop = false,
    this.buffered,
    this.release,
  });

  @override
  Stream<StreamEvent> chatStream({
    required String system,
    required List<Map<String, dynamic>> messages,
    required List<ToolDefinition> tools,
  }) async* {
    calls++;
    if (calls > 1) {
      yield StreamDone(const LlmResponse(
        stopReason: 'end_turn',
        content: [ContentBlock(type: 'text', text: 'done')],
      ));
      return;
    }
    yield TextDelta('visible $sentinel');
    yield ReasoningDelta('reasoning $sentinel');
    yield ToolUseStart('secret_call', 'set_env_var');
    yield ToolInputDelta(
      '{"name":"STREAM_TOKEN","value":"$sentinel"}',
    );
    if (buffered != null && !buffered!.isCompleted) buffered!.complete();
    if (release != null) await release!.future;
    if (failBeforeDone || release != null) {
      yield StreamError('stream interrupted');
      return;
    }
    if (malformedStop) {
      yield StreamDone(LlmResponse(
        stopReason: 'end_turn',
        content: [ContentBlock(type: 'text', text: 'visible $sentinel')],
      ));
      return;
    }
    yield StreamDone(LlmResponse(
      stopReason: 'tool_use',
      content: [
        ContentBlock(
          type: 'text',
          text: 'visible $sentinel',
          reasoningContent: 'reasoning $sentinel',
        ),
        ContentBlock(
          type: 'tool_use',
          toolUseId: 'secret_call',
          toolName: 'set_env_var',
          toolInput: {
            'name': 'STREAM_TOKEN',
            'value': sentinel,
          },
        ),
      ],
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

class _CapturingLlmService extends LlmService {
  List<Map<String, dynamic>> receivedMessages = const [];

  _CapturingLlmService(super.config);

  @override
  Stream<StreamEvent> chatStream({
    required String system,
    required List<Map<String, dynamic>> messages,
    required List<ToolDefinition> tools,
  }) async* {
    receivedMessages = messages;
    yield StreamDone(const LlmResponse(
      stopReason: 'end_turn',
      content: [ContentBlock(type: 'text', text: 'done')],
    ));
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

VerifiedSkillUse _verifiedSkill(ExtensionCapabilitySnapshot capabilities) =>
    VerifiedSkillUse(
      id: 'com.example.active',
      name: 'Active',
      path: '/root/workspace/skills/com.example.active/SKILL.md',
      skillContent: 'active skill',
      capabilities: capabilities,
      manifestDigest: List.filled(64, 'a').join(),
      contentDigest: List.filled(64, 'b').join(),
      trustDigest: List.filled(64, 'c').join(),
      legacy: false,
    );

class _RecordingTool extends Tool {
  @override
  final String name;

  final executedInputs = <Map<String, dynamic>>[];
  final executedOperationIds = <String>[];

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

  @override
  Future<ToolResultPayload> executeResultWithOperation(
    Map<String, dynamic> input, {
    String? sessionId,
    required String operationId,
  }) async {
    executedOperationIds.add(operationId);
    return super.executeResultWithOperation(
      input,
      sessionId: sessionId,
      operationId: operationId,
    );
  }
}

class _EnvRecordingTool extends _RecordingTool {
  _EnvRecordingTool() : super(name: 'set_env_var');

  @override
  Map<String, dynamic> get inputSchema => const {
        'type': 'object',
        'properties': {
          'name': {'type': 'string'},
          'value': {'type': 'string'},
          'action': {
            'type': 'string',
            'enum': ['set', 'delete'],
          },
        },
        'required': ['name'],
      };

  @override
  Future<String> execute(Map<String, dynamic> input) async {
    executedInputs.add(Map<String, dynamic>.from(input));
    return 'stored ${input['value']}';
  }
}

class _CancellationAwareTool extends Tool {
  final Completer<void> started = Completer<void>();
  bool cancellationObserved = false;

  @override
  String get name => 'cancellable_http';

  @override
  String get description => 'Cancellation-aware test tool';

  @override
  Map<String, dynamic> get inputSchema => const {
        'type': 'object',
        'properties': {
          'value': {'type': 'string'},
        },
      };

  @override
  Future<String> execute(Map<String, dynamic> input) async {
    throw UnimplementedError();
  }

  @override
  Future<ToolResultPayload> executeResultWithOperationAndCancellation(
    Map<String, dynamic> input, {
    String? sessionId,
    required String operationId,
    required ToolCancellationSignal cancellationSignal,
  }) async {
    if (!started.isCompleted) started.complete();
    await cancellationSignal.whenCancelled;
    cancellationObserved = true;
    throw const ToolExecutionCancelledException(sideEffectsPrevented: true);
  }
}
