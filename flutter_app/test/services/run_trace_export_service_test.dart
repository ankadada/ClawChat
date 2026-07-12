import 'dart:convert';

import 'package:clawchat/services/run_trace_export_service.dart';
import 'package:clawchat/services/runtime_debug_events.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RunTraceExportService', () {
    test('exports versioned metadata-only JSON with lifecycle and usage', () {
      final traces = RuntimeDebugEventService(tracingEnabled: true);
      final traceId = traces.startRunTrace('session-safe', data: {
        'trigger': 'retry',
        'providerKind': 'anthropicNative',
        'modelLabel': 'anthropic/claude-test',
        'endpoint': 'https://secret.example/v1',
        'prompt': 'PRIVATE USER MESSAGE',
      })!;
      traces.record(RuntimeDebugEvent(
        type: 'stream.terminal',
        sessionId: 'session-safe',
        data: {
          'status': 'completed',
          'completeness': 'complete',
          'inputTokens': 10,
          'outputTokens': 4,
          'cacheReadInputTokens': 3,
          'tool_output': 'PRIVATE TOOL OUTPUT',
          'reasoning': 'PRIVATE REASONING',
          'api_key': 'sk-private-value',
          'base64': 'data:image/png;base64,${'a' * 240}',
        },
      ));
      traces.finishRunTrace(traceId, RunTraceStatus.completed);

      final exported = const RunTraceExportService().buildJson(
        traces.recentRunTraces(),
        generatedAt: DateTime.utc(2026, 7, 10),
      );
      final decoded = jsonDecode(exported) as Map<String, dynamic>;

      expect(decoded['schemaVersion'], RunTraceSnapshot.schemaVersion);
      expect(decoded['privacy'], 'metadata_only');
      expect(decoded['persistence'], 'memory_only');
      expect(exported, contains('anthropic/claude-test'));
      expect(exported, contains('cacheReadInputTokens'));
      expect(exported, isNot(contains('secret.example')));
      expect(exported, isNot(contains('PRIVATE USER MESSAGE')));
      expect(exported, isNot(contains('PRIVATE TOOL OUTPUT')));
      expect(exported, isNot(contains('PRIVATE REASONING')));
      expect(exported, isNot(contains('sk-private-value')));
      expect(exported, isNot(contains('data:image/png;base64')));
    });

    test('clear removes all exportable traces', () {
      final traces = RuntimeDebugEventService(tracingEnabled: true);
      traces.startRunTrace('session');
      traces.clearRunTraces();

      final exported = const RunTraceExportService().buildJson(
        traces.recentRunTraces(),
      );
      final decoded = jsonDecode(exported) as Map<String, dynamic>;
      expect(decoded['traces'], isEmpty);
    });
  });
}
