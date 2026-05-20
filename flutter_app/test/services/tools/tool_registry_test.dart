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
        'key-abcdefghijklmnopqrstuvwxyz secret=super-secret-value',
      );

      expect(sanitized, contains('key-[REDACTED]'));
      expect(sanitized, contains('secret=[REDACTED]'));
      expect(sanitized, isNot(contains('abcdefghijklmnopqrstuvwxyz')));
      expect(sanitized, isNot(contains('super-secret-value')));
    });

    test('sanitizes every executed tool output', () async {
      final registry = ToolRegistry()..register(_SecretEchoTool());

      final sanitized = await registry.executeTool('secret_echo', const {});

      expect(sanitized, contains('token=[REDACTED]'));
      expect(sanitized, contains('password=[REDACTED]'));
      expect(sanitized, contains('sk-[REDACTED]'));
      expect(sanitized, isNot(contains('abcdefghijklmnopqrstuvwxyz')));
      expect(sanitized, isNot(contains('hunter2')));
    });
  });
}
