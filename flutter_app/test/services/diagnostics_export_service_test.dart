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
        type: 'provider.error',
        sessionId: 'session-1',
        data: {
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
      expect(report, contains('api.example.com'));
      expect(report, contains('safeMode: true'));
      expect(report, isNot(contains('sk-secret-secret-secret')));
      expect(report, isNot(contains('verysecretbearertoken')));
      expect(report, isNot(contains('data:image/png;base64')));
      expect(report, isNot(contains('aaaaaaaaaaaaaaaaaaaaaaaa')));
      expect(report, contains('messageLength'));
    });

    test('redacts nested diagnostic payload keys at every depth', () {
      const service = DiagnosticsExportService();
      final event = RuntimeDebugEvent(
        type: 'provider.debug',
        sessionId: 'session-2',
        data: {
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

      expect(report, contains('eventType'));
      expect(report, contains('provider_error'));
      expect(report, contains('messageCount'));
      expect(report, contains('toolCallCount'));
      expect(report, contains('contentLength'));
      expect(report, contains('tool_result'));
      expect(report, contains('"request":"[redacted]"'));
      expect(report, contains('"messages":"[redacted]"'));
      expect(report, contains('"tool_output":"[redacted]"'));
      expect(report, contains('"raw_provider_payload":"[redacted]"'));
      expect(report, isNot(contains('synthetic nested prompt text')));
      expect(report, isNot(contains('synthetic raw request payload')));
      expect(report, isNot(contains('synthetic tool output')));
      expect(report, isNot(contains('synthetic provider content')));
    });
  });
}
