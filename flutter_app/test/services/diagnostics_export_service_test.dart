import 'package:clawchat/models/provider_profile.dart';
import 'package:clawchat/services/diagnostics_export_service.dart';
import 'package:clawchat/services/runtime_debug_events.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DiagnosticsExportService', () {
    test('exports sanitized summaries without raw secrets or payloads', () {
      const service = DiagnosticsExportService();
      final profile = ProviderProfile.defaults().copyWith(
        id: 'profile',
        apiKey: 'sk-secret-secret-secret',
        baseUrl: 'https://api.example.com/v1',
        model: 'gpt-test',
      );
      final event = RuntimeDebugEvent(
        type: 'stream.terminal',
        sessionId: 'session-1',
        data: {
          'attempt': 1,
          'status': 'failed',
          'completeness': 'none',
          'durationMs': 3,
          'errorCode': 'provider_unavailable',
          'api_key': 'sk-secret-secret-secret',
          'prompt': 'Authorization: Bearer verysecretbearertoken123456789',
          'payload': 'data:image/png;base64,${'a' * 200}',
          'messageLength': 123,
        },
      );

      final report = service.buildReport(DiagnosticsExportSummary(
        activeProfileId: 'profile',
        activeProfile: profile,
        lastError: 'bad sk-secret-secret-secret',
        safeMode: true,
        startupFailureCount: 2,
        events: [event],
      ));

      expect(report, contains('ClawChat diagnostics'));
      expect(report, isNot(contains('api.example.com')));
      expect(report, isNot(contains('baseUrlHost')));
      expect(report, contains('safeMode: true'));
      expect(report, isNot(contains('sk-secret-secret-secret')));
      expect(report, isNot(contains('verysecretbearertoken')));
      expect(report, isNot(contains('data:image/png;base64')));
      expect(report, isNot(contains('aaaaaaaaaaaaaaaaaaaaaaaa')));
      expect(report, contains('provider_unavailable'));
      expect(report, isNot(contains('messageLength')));
      expect(event.data.keys.toSet(), {
        'attempt',
        'status',
        'completeness',
        'durationMs',
        'errorCode',
      });
    });

    test('never exports unknown aliases or nested diagnostic payloads', () {
      const service = DiagnosticsExportService();
      final event = RuntimeDebugEvent(
        type: 'provider.transform.warning',
        sessionId: 'session-2',
        data: {
          'warningCount': 1,
          'warningCode': 'tool_result_missing_id',
          'droppedBlockCount': 1,
          'eventType': 'provider_error',
          'details': {
            'metadata': {'messageLength': 42},
            'request': 'synthetic raw request payload',
            'messages': ['synthetic nested prompt text'],
            'counts': {'messageCount': 1, 'toolCallCount': 2},
            'nested': [
              {
                'tool_output': 'synthetic tool output',
                'raw_provider_payload': 'synthetic provider content',
                'type': 'tool_result',
                'contentLength': 2048,
              },
            ],
          },
        },
      );

      final report = service.buildReport(DiagnosticsExportSummary(
        events: [event],
      ));

      expect(event.data, {
        'warningCount': 1,
        'warningCode': 'tool_result_missing_id',
        'droppedBlockCount': 1,
      });
      expect(report, contains('tool_result_missing_id'));
      expect(report, isNot(contains('eventType')));
      expect(report, isNot(contains('provider_error')));
      expect(report, isNot(contains('messageCount')));
      expect(report, isNot(contains('toolCallCount')));
      expect(report, isNot(contains('contentLength')));
      expect(report, isNot(contains('"request"')));
      expect(report, isNot(contains('"messages"')));
      expect(report, isNot(contains('"tool_output"')));
      expect(report, isNot(contains('"raw_provider_payload"')));
      expect(report, isNot(contains('synthetic nested prompt text')));
      expect(report, isNot(contains('synthetic raw request payload')));
      expect(report, isNot(contains('synthetic tool output')));
      expect(report, isNot(contains('synthetic provider content')));
    });
  });
}
