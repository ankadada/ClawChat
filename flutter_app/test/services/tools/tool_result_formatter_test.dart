import 'dart:convert';

import 'package:clawchat/services/tools/tool_result_formatter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ToolResultFormatter', () {
    test('omits base64 and data URLs from ForLLM only', () {
      final base64 = 'a' * 900;
      final dataUrl = 'data:image/png;base64,${'b' * 140}';
      final output = 'before $base64 middle $dataUrl after';

      final payload = ToolResultFormatter.generic(
        toolName: 'generic_tool',
        output: output,
      );

      expect(payload.forUser, output);
      expect(payload.forLlm, contains('[base64 omitted'));
      expect(payload.forLlm, contains('[data URL omitted'));
      expect(payload.forLlm, isNot(contains(base64)));
      expect(payload.forLlm, isNot(contains(dataUrl)));
      expect(payload.summary, contains('[base64 omitted'));
      expect(payload.summary, contains('[data URL omitted'));
      expect(payload.summary, isNot(contains(base64)));
      expect(payload.summary, isNot(contains(dataUrl)));
      expect(payload.metadata['omittedReason'], contains('base64'));
      expect(payload.metadata['originalChars'], output.length);
      expect(payload.metadata['llmChars'], payload.forLlm!.length);
    });

    test('compresses long lines', () {
      final longLine = '${'h:' * 500}${'m:' * 500}${'t:' * 200}';

      final payload = ToolResultFormatter.generic(
        toolName: 'generic_tool',
        output: longLine,
        limit: 2000,
      );
      final decoded = jsonDecode(payload.forLlm!) as Map<String, dynamic>;

      expect(payload.forUser, longLine);
      expect(decoded['output'], contains('[long line omitted'));
      expect(decoded['truncated'], isNull);
      expect(payload.metadata['truncated'], isFalse);
      expect(payload.metadata['omittedReason'], contains('long_line'));
      expect(payload.forLlm, isNot(contains('m:' * 500)));
    });

    test('uses head-tail truncation for long output', () {
      final lines = List.generate(500, (i) => 'line:$i').join('\n');

      final payload = ToolResultFormatter.generic(
        toolName: 'generic_tool',
        output: lines,
        limit: 500,
      );
      final decoded = jsonDecode(payload.forLlm!) as Map<String, dynamic>;
      final output = decoded['output'] as String;

      expect(output, startsWith('line:0'));
      expect(output, contains('[... omitted'));
      expect(output, endsWith('line:499'));
      expect(decoded['truncated'], isTrue);
      expect(payload.metadata['truncated'], isTrue);
      expect(payload.metadata['omittedReason'], contains('length'));
    });

    test('keeps structured metadata for tool-specific formatters', () {
      final payload = ToolResultFormatter.bash(
        input: const {'command': 'printf hello'},
        output: 'hello',
      );
      final decoded = jsonDecode(payload.forLlm!) as Map<String, dynamic>;

      expect(decoded['tool'], 'bash');
      expect(decoded['command'], 'printf hello');
      expect(decoded['status'], 'success');
      expect(payload.summary, 'bash completed: printf hello');
      expect(payload.metadata['toolName'], 'bash');
      expect(payload.metadata['status'], 'success');
    });

    test('redacts secrets from ForLLM and summary but preserves ForUser', () {
      const secret = 'sk-proj-abcdefghijklmnopqrstuvwxyz123456';
      const output = 'api_key=$secret\npassword=hunter2';

      final payload = ToolResultFormatter.generic(
        toolName: 'secret_tool',
        output: output,
      );

      expect(payload.forUser, output);
      expect(payload.forLlm, contains('[redacted: api_key]'));
      expect(payload.forLlm, contains('[redacted: password]'));
      expect(payload.forLlm, isNot(contains(secret)));
      expect(payload.forLlm, isNot(contains('hunter2')));
      expect(payload.summary, isNot(contains(secret)));
      expect(payload.summary, isNot(contains('hunter2')));
      expect(payload.metadata['sensitiveRedactions'], 2);
      expect(payload.metadata['sensitiveRedactionTypes'], {
        'api_key': 1,
        'password': 1,
      });
    });

    test('redacts secrets from model-facing tool input envelope fields', () {
      final payload = ToolResultFormatter.bash(
        input: const {
          'command':
              'curl -H "Authorization: Bearer abcdefghijklmnopqrstuvwxyz"',
        },
        output: 'ok',
      );
      final decoded = jsonDecode(payload.forLlm!) as Map<String, dynamic>;

      expect(decoded['output'], 'ok');
      expect(decoded['command'], contains('[redacted: bearer_token]'));
      expect(decoded['command'], isNot(contains('abcdefghijklmnopqrstuvwxyz')));
      expect(payload.summary, contains('[redacted: bearer_token]'));
      expect(payload.metadata['sensitiveRedactions'], 1);
    });
  });
}
