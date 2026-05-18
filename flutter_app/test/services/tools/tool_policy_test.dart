import 'package:clawchat/services/tools/tool_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ToolPolicy approval flow', () {
    test('safe tools pass without approval callback', () async {
      final policy = ToolPolicy(
        onApprovalRequired: (_) => fail('safe tool should not request approval'),
      );

      final approved = await policy.approve(const ToolApprovalRequest(
        toolName: 'read_file',
        arguments: {'path': '/root/workspace/file.txt'},
        risk: ToolRisk.safe,
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
      );

      expect(await policy.approve(request), isTrue);
      expect(await policy.approve(request), isTrue);
      expect(callbackCount, 1);
    });
  });
}
