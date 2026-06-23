import 'package:clawchat/services/tools/tool_registry.dart';
import 'package:flutter_test/flutter_test.dart';

class _SecretEchoTool extends Tool {
  @override
  String get name => 'secret_echo';

  @override
  String get description => 'Returns secret-shaped output';

  @override
  Map<String, dynamic> get inputSchema => const {
        'type': 'object',
        'properties': {},
      };

  @override
  Future<String> execute(Map<String, dynamic> input) async {
    return 'token=abcdefghijklmnopqrstuvwxyz password: hunter2 sk-abcdefghijklmnopqrstuvwxyz';
  }
}

void main() {
  group('ToolRegistry output sanitizer', () {
    test('redacts secret-shaped values from direct sanitizer calls', () {
      final sanitized = ToolRegistry.sanitizeToolOutput(
        'sk-abcdefghijklmnopqrstuvwxyz secret=super-secret-value',
      );

      expect(sanitized, contains('[redacted: api_key]'));
      expect(sanitized, contains('[redacted: secret]'));
      expect(sanitized, isNot(contains('abcdefghijklmnopqrstuvwxyz')));
      expect(sanitized, isNot(contains('super-secret-value')));
    });

    test('preserves executed tool ForUser and redacts model-facing output',
        () async {
      final registry = ToolRegistry()..register(_SecretEchoTool());

      final output = await registry.executeTool('secret_echo', const {});
      final payload = await registry.executeToolResult('secret_echo', const {});

      expect(output, contains('token=abcdefghijklmnopqrstuvwxyz'));
      expect(output, contains('password: hunter2'));
      expect(payload.forUser, output);
      expect(payload.forLlm, contains('token=[redacted: token]'));
      expect(payload.forLlm, contains('password: [redacted: password]'));
      expect(payload.forLlm, isNot(contains('hunter2')));
    });
  });
}
