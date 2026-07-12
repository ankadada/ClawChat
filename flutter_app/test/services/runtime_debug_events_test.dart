import 'package:clawchat/services/runtime_debug_events.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RuntimeDebugEventService', () {
    test('starts disabled and captures neither events nor traces', () {
      final service = RuntimeDebugEventService();

      service.record(RuntimeDebugEvent(type: 'ignored', sessionId: 's1'));

      expect(service.tracingEnabled, isFalse);
      expect(service.recent(), isEmpty);
      expect(service.startRunTrace('s1'), isNull);
      expect(service.recentRunTraces(), isEmpty);
    });

    test('keeps only the newest events inside the ring buffer', () {
      final service = RuntimeDebugEventService(
        capacity: 3,
        tracingEnabled: true,
      );

      for (var i = 0; i < 5; i++) {
        service.record(RuntimeDebugEvent(
          type: 'stream.started',
          sessionId: 's1',
          data: {'attempt': 1, 'latencyMs': i},
        ));
      }

      expect(
        service.recent().map((event) => event.data['latencyMs']),
        [2, 3, 4],
      );
    });

    test('filters recent events by session id and limit', () {
      final service = RuntimeDebugEventService(tracingEnabled: true);

      service.record(RuntimeDebugEvent(
        type: 'stream.started',
        sessionId: 's1',
        data: const {'attempt': 1, 'latencyMs': 1},
      ));
      service.record(RuntimeDebugEvent(
        type: 'model.attempt.started',
        sessionId: 's2',
        data: const {'attempt': 1, 'modelLabel': 'openai/gpt-test'},
      ));
      service.record(RuntimeDebugEvent(
        type: 'stream.reset',
        sessionId: 's1',
        data: const {
          'attempt': 1,
          'count': 1,
          'completeness': 'interrupted',
        },
      ));

      expect(
        service.recent(sessionId: 's1').map((event) => event.type),
        ['stream.started', 'stream.reset'],
      );
      expect(
        service.recent(limit: 2).map((event) => event.type),
        ['model.attempt.started', 'stream.reset'],
      );
    });

    test('clears all events or a single session', () {
      final service = RuntimeDebugEventService(tracingEnabled: true);

      service.record(RuntimeDebugEvent(
        type: 'stream.started',
        sessionId: 's1',
        data: const {'attempt': 1, 'latencyMs': 1},
      ));
      service.record(RuntimeDebugEvent(
        type: 'stream.started',
        sessionId: 's2',
        data: const {'attempt': 1, 'latencyMs': 2},
      ));
      service.clear(sessionId: 's1');

      expect(service.recent().map((event) => event.sessionId), ['s2']);

      service.clear();
      expect(service.recent(), isEmpty);
    });

    test('drops unknown top-level aliases and every nested value at ingestion',
        () {
      final service = RuntimeDebugEventService(tracingEnabled: true);
      final traceId = service.startRunTrace('s1')!;

      service.record(RuntimeDebugEvent(
        type: 'stream.terminal',
        sessionId: 's1',
        data: const {
          'attempt': 1,
          'status': 'completed',
          'completeness': 'complete',
          'durationMs': 12,
          'inputTokens': 10,
          'prompt': 'DROP_PROMPT_VALUE',
          'instructions': 'DROP_INSTRUCTIONS_VALUE',
          'body': 'DROP_BODY_VALUE',
          'requestData': 'DROP_REQUEST_VALUE',
          'responseBody': 'DROP_RESPONSE_VALUE',
          'tool_args': 'DROP_TOOL_ARGUMENT_VALUE',
          'resultText': 'DROP_RESULT_VALUE',
          'shellText': 'DROP_SHELL_VALUE',
          'endpointUrl': 'DROP_ENDPOINT_VALUE',
          'headers': 'DROP_HEADER_VALUE',
          'credentials': 'DROP_CREDENTIAL_VALUE',
          'secretValue': 'DROP_SECRET_VALUE',
          'encodedBlob': 'DROP_ENCODED_VALUE',
          'filesystemPath': 'DROP_PATH_VALUE',
          'nested': {
            'command': 'DROP_NESTED_COMMAND',
            'content': 'DROP_NESTED_CONTENT',
            'base64': 'DROP_NESTED_ENCODED_VALUE',
            'secret': 'DROP_NESTED_SECRET_VALUE',
          },
        },
      ));

      final data = service.recent().single.data;
      expect(data, {
        'attempt': 1,
        'status': 'completed',
        'completeness': 'complete',
        'durationMs': 12,
        'inputTokens': 10,
      });
      final traceEvent = service
          .runTrace(traceId)!
          .events
          .singleWhere((event) => event.type == 'stream.terminal');
      expect(traceEvent.data, data);
      expect(service.recent().toString(), isNot(contains('DROP_')));
      expect(
        service.runTrace(traceId)!.events.toString(),
        isNot(contains('DROP_')),
      );
    });

    test('drops unsafe values even when supplied under allowlisted keys', () {
      final service = RuntimeDebugEventService(tracingEnabled: true);

      service.record(RuntimeDebugEvent(
        type: 'model.fallback.failed',
        sessionId: 's1',
        data: const {
          'candidate': 'https://private.invalid/v1',
          'reason': 'user_message',
          'attemptIndex': 1,
        },
      ));

      final data = service.recent().single.data;
      expect(data, {'attemptIndex': 1});
    });

    test('documents and retains safe scalar fields for every event category',
        () {
      final cases = <String, Map<String, Object?>>{
        'run.started': {
          'runAttemptId': 'run-1',
          'trigger': 'message',
          'profileLabel': 'profile_1',
          'providerKind': 'anthropicNative',
          'modelLabel': 'anthropic/claude-test',
          'modelGroupLabel': 'configured',
        },
        'context.assembly.completed': {
          'mode': 'send',
          'durationMs': 5,
          'messageCount': 3,
          'generated': true,
          'reused': false,
          'failed': false,
          'coveredMessageCount': 2,
          'droppedMessageCount': 1,
          'droppedBlockCount': 0,
          'finalTokenBudget': 4096,
          'compressedToolResultCount': 1,
        },
        'model.fallback.attempt': {
          'primary': 'anthropic/primary-model',
          'candidate': 'fallback-model',
          'reason': 'network_or_timeout',
          'attemptIndex': 1,
        },
        'stream.terminal': {
          'attempt': 1,
          'status': 'completed',
          'completeness': 'complete',
          'durationMs': 9,
          'inputTokens': 8,
          'outputTokens': 4,
          'inputTokensIncludeCache': true,
          'hadToolCalls': false,
        },
        'tool.attempt.started': {
          'runAttemptId': 'run-1',
          'operationId': 'op-1',
          'toolName': 'read_file',
          'risk': 'safe',
        },
        'tool.preflight.repaired': {
          'repairCount': 3,
          'jsonClosureRepairCount': 1,
          'fieldNameRepairCount': 1,
          'typeCoercionRepairCount': 1,
        },
        'provider.transform.warning': {
          'warningCount': 1,
          'warningCode': 'image_unsupported',
          'droppedBlockCount': 1,
        },
        'token.calibration.updated': {
          'oldMultiplier': 1.0,
          'ratio': 1.2,
          'newMultiplier': 1.06,
        },
      };

      for (final entry in cases.entries) {
        final event = RuntimeDebugEvent(
          type: entry.key,
          sessionId: 's1',
          data: entry.value,
        );
        expect(event.type, entry.key, reason: entry.key);
        expect(event.data, entry.value, reason: entry.key);
        expect(
          RuntimeDebugEventService.allowedMetadataKeysForEvent(entry.key),
          containsAll(entry.value.keys),
          reason: entry.key,
        );
      }
    });

    test('non-positive capacity stores no events', () {
      final service = RuntimeDebugEventService(
        capacity: 0,
        tracingEnabled: true,
      );

      service.record(RuntimeDebugEvent(type: 'ignored', sessionId: 's1'));

      expect(service.recent(), isEmpty);
    });

    test('run traces are opt-in, bounded, ordered, and metadata only', () {
      final service = RuntimeDebugEventService(
        tracingEnabled: true,
        traceCapacity: 2,
        traceEventCapacity: 3,
      );

      final traceId = service.startRunTrace('s1', data: {
        'trigger': 'message',
        'profileLabel': 'profile_1',
        'prompt': 'RAW_USER_PROMPT',
      });
      expect(traceId, isNotNull);
      service.record(RuntimeDebugEvent(
        type: 'tool.attempt.started',
        sessionId: 's1',
        data: {
          'runAttemptId': 'run-1',
          'operationId': 'op-1',
          'toolName': 'bash',
          'risk': 'dangerous',
          'tool_args': {'command': 'cat private.txt'},
          'content': 'RAW_TOOL_OUTPUT',
          'authorization': 'Bearer private-token',
        },
      ));
      service.record(RuntimeDebugEvent(
        type: 'stream.started',
        sessionId: 's1',
        data: {'latencyMs': 12},
      ));
      service.finishRunTrace(traceId!, RunTraceStatus.completed);

      final trace = service.runTrace(traceId)!;
      expect(trace.status, RunTraceStatus.completed);
      expect(trace.events, hasLength(3));
      expect(trace.events.map((event) => event.sequence), [2, 3, 4]);
      expect(trace.events.first.data['toolName'], 'bash');
      expect(trace.events.first.data, isNot(contains('tool_args')));
      expect(trace.events.first.data, isNot(contains('content')));
      expect(trace.events.toString(), isNot(contains('RAW_USER_PROMPT')));
      expect(trace.events.toString(), isNot(contains('RAW_TOOL_OUTPUT')));
      expect(trace.events.toString(), isNot(contains('private-token')));

      final second = service.startRunTrace('s2');
      service.finishRunTrace(second!, RunTraceStatus.failed);
      final third = service.startRunTrace('s3');
      service.finishRunTrace(third!, RunTraceStatus.cancelled);
      expect(service.recentRunTraces().map((trace) => trace.sessionId), [
        's2',
        's3',
      ]);
    });

    test('concurrent sessions stay isolated and superseded runs interrupt', () {
      final service = RuntimeDebugEventService(tracingEnabled: true);
      final firstS1 = service.startRunTrace('s1')!;
      final s2 = service.startRunTrace('s2')!;

      service.record(RuntimeDebugEvent(
        type: 'stream.started',
        sessionId: 's1',
        data: const {'attempt': 1, 'latencyMs': 1},
      ));
      service.record(RuntimeDebugEvent(
        type: 'model.attempt.started',
        sessionId: 's2',
        data: const {'attempt': 1, 'modelLabel': 'openai/gpt-test'},
      ));
      final secondS1 = service.startRunTrace('s1')!;

      expect(service.runTrace(firstS1)!.status, RunTraceStatus.interrupted);
      expect(service.runTrace(s2)!.status, RunTraceStatus.inFlight);
      expect(service.activeTraceIdForSession('s1'), secondS1);
      expect(
        service.runTrace(firstS1)!.events.map((event) => event.type),
        contains('stream.started'),
      );
      expect(
        service.runTrace(firstS1)!.events.map((event) => event.type),
        isNot(contains('model.attempt.started')),
      );
    });

    test('turning Developer Mode off clears every store and stops capture', () {
      final service = RuntimeDebugEventService(tracingEnabled: true);
      service.startRunTrace('s1');
      service.record(RuntimeDebugEvent(
        type: 'stream.started',
        sessionId: 's1',
        data: const {'attempt': 1, 'latencyMs': 1},
      ));
      expect(service.recent(), isNotEmpty);
      expect(service.recentRunTraces(), isNotEmpty);

      service.setTracingEnabled(false);
      expect(service.recent(), isEmpty);
      expect(service.recentRunTraces(), isEmpty);
      expect(service.activeTraceIdForSession('s1'), isNull);
      expect(service.startRunTrace('s2'), isNull);

      service.record(RuntimeDebugEvent(
        type: 'stream.started',
        sessionId: 's2',
        data: const {'attempt': 1, 'latencyMs': 1},
      ));
      expect(service.recent(), isEmpty);
      expect(service.recentRunTraces(), isEmpty);
    });

    test('disabling an active run drops later events and re-enable is fresh',
        () {
      final service = RuntimeDebugEventService(tracingEnabled: true);
      final oldTraceId = service.startRunTrace('s1')!;
      service.record(RuntimeDebugEvent(
        type: 'stream.started',
        sessionId: 's1',
        data: const {'attempt': 1, 'latencyMs': 1},
      ));

      service.setTracingEnabled(false);
      service.record(RuntimeDebugEvent(
        type: 'stream.reset',
        sessionId: 's1',
        data: const {
          'attempt': 1,
          'count': 1,
          'completeness': 'interrupted',
        },
      ));
      service.finishRunTrace(oldTraceId, RunTraceStatus.completed);

      expect(service.recent(), isEmpty);
      expect(service.recentRunTraces(), isEmpty);
      expect(service.runTrace(oldTraceId), isNull);

      service.setTracingEnabled(true);
      expect(service.recent(), isEmpty);
      expect(service.recentRunTraces(), isEmpty);
      service.record(RuntimeDebugEvent(
        type: 'stream.started',
        sessionId: 's1',
        data: const {'attempt': 1, 'latencyMs': 2},
      ));
      expect(service.recent().single.type, 'stream.started');
      expect(service.recentRunTraces(), isEmpty);
    });
  });
}
