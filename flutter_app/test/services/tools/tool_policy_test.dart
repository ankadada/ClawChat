import 'package:clawchat/services/tools/tool_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ToolPolicy approval flow', () {
    test('safe tools pass without approval callback', () async {
      final policy = ToolPolicy(
        onApprovalRequired: (_) =>
            fail('safe tool should not request approval'),
      );

      final approved = await policy.approve(const ToolApprovalRequest(
        toolName: 'read_file',
        arguments: {'path': '/root/workspace/file.txt'},
        risk: ToolRisk.safe,
        operationId: 'safe-operation',
      ));

      expect(approved, isTrue);
    });

    test('dangerous tools require callback approval', () async {
      ToolApprovalRequest? seenRequest;
      final policy = ToolPolicy(
        onApprovalRequired: (request) {
          seenRequest = request;
          return true;
        },
      );

      final approved = await policy.approve(const ToolApprovalRequest(
        toolName: 'bash',
        arguments: {'command': 'ls'},
        risk: ToolRisk.dangerous,
        operationId: 'dangerous-operation',
      ));

      expect(approved, isTrue);
      expect(seenRequest?.toolName, 'bash');
      expect(seenRequest?.arguments['command'], 'ls');
    });

    test('callback denial returns false', () async {
      final policy = ToolPolicy(onApprovalRequired: (_) => false);

      final approved = await policy.approve(const ToolApprovalRequest(
        toolName: 'write_file',
        arguments: {'path': '/root/workspace/file.txt'},
        risk: ToolRisk.moderate,
        operationId: 'denied-operation',
      ));

      expect(approved, isFalse);
    });

    test('session memory can be implemented by approval callback', () async {
      final rememberedTools = <String>{};
      var callbackCount = 0;
      final policy = ToolPolicy(
        onApprovalRequired: (request) {
          if (rememberedTools.contains(request.toolName)) return true;
          callbackCount++;
          rememberedTools.add(request.toolName);
          return true;
        },
      );

      const request = ToolApprovalRequest(
        toolName: 'bash',
        arguments: {'command': 'pwd'},
        risk: ToolRisk.dangerous,
        operationId: 'remember-operation',
      );

      expect(await policy.approve(request), isTrue);
      expect(await policy.approve(request), isTrue);
      expect(callbackCount, 1);
    });

    test('denied tools bypass approval callback', () async {
      var callbackCount = 0;
      final policy = ToolPolicy(
        deniedToolNames: const {'bash'},
        onApprovalRequired: (_) {
          callbackCount++;
          return true;
        },
      );

      const request = ToolApprovalRequest(
        toolName: 'bash',
        arguments: {'command': 'pwd'},
        risk: ToolRisk.dangerous,
        operationId: 'blocked-operation',
      );

      final deny = policy.denyFor(request);
      expect(deny?.ruleType, 'tool');
      expect(deny?.ruleId, 'tool:bash');
      expect(await policy.approve(request), isFalse);
      expect(callbackCount, 0);
    });

    test('bash deny patterns match before approval', () async {
      var callbackCount = 0;
      final policy = ToolPolicy(
        bashCommandDenyPatterns: const [r'rm\s+-rf'],
        onApprovalRequired: (_) {
          callbackCount++;
          return true;
        },
      );

      const request = ToolApprovalRequest(
        toolName: 'bash',
        arguments: {'command': 'rm -rf /tmp/example'},
        risk: ToolRisk.dangerous,
        operationId: 'pattern-operation',
      );

      final deny = policy.denyFor(request);
      expect(deny?.ruleType, 'bash_pattern');
      expect(deny?.ruleId, 'bash_pattern_1');
      expect(await policy.approve(request), isFalse);
      expect(callbackCount, 0);
    });

    test('bash deny patterns also apply to MCP command arguments', () async {
      var callbackCount = 0;
      final policy = ToolPolicy(
        bashCommandDenyPatterns: const [r'rm\s+-rf'],
        onApprovalRequired: (_) {
          callbackCount++;
          return true;
        },
      );

      const request = ToolApprovalRequest(
        toolName: 'mcp_12345678_shell_abcd1234',
        arguments: {'command': 'rm -rf /tmp/example'},
        risk: ToolRisk.moderate,
        operationId: 'mcp-pattern-operation',
      );

      final deny = policy.denyFor(request);
      expect(deny?.ruleType, 'bash_pattern');
      expect(deny?.ruleId, 'bash_pattern_1');
      expect(await policy.approve(request), isFalse);
      expect(callbackCount, 0);
    });
  });
}
