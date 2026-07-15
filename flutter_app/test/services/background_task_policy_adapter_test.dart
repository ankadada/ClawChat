import 'package:flutter_test/flutter_test.dart';

import 'package:clawchat/models/background_task.dart';
import 'package:clawchat/services/background_task_policy_adapter.dart';
import 'package:clawchat/services/tools/tool_policy.dart';

void main() {
  group('SharedBackgroundTaskPolicyAdapter', () {
    test('hard deny wins before approval', () async {
      final gateway = _Gateway();
      final adapter = _adapter(
        gateway: gateway,
        settings: const BackgroundTaskPolicySettingsSnapshot(
          approvalPolicy: 'always',
          deniedToolNames: {'memory_add'},
          bashCommandDenyPatterns: [],
        ),
      );

      final result = await adapter.hardAndSkillPreflight(
        task: _record(),
        operationId: 'operation-1',
      );

      expect(result.allowed, isFalse);
      expect(result.reasonCode, 'task_hard_deny');
      expect(gateway.standardRequests, 0);
    });

    test('skill deny stays separate from hard deny', () async {
      final gateway = _Gateway();
      final adapter = SharedBackgroundTaskPolicyAdapter(
        bindings: _Bindings(skillStorageReference: true),
        settings: const _Settings(BackgroundTaskPolicySettingsSnapshot(
          approvalPolicy: 'always',
          deniedToolNames: {},
          bashCommandDenyPatterns: [],
        )),
        approvals: gateway,
      );

      final result = await adapter.hardAndSkillPreflight(
        task: _record(),
        operationId: 'operation-1',
      );

      expect(result.allowed, isFalse);
      expect(result.reasonCode, 'task_skill_deny');
      expect(gateway.standardRequests, 0);
    });

    test('Auto Allow cannot replace external JIT confirmation', () async {
      final gateway = _Gateway();
      final adapter = _adapter(
        gateway: gateway,
        settings: const BackgroundTaskPolicySettingsSnapshot(
          approvalPolicy: 'auto',
          deniedToolNames: {},
          bashCommandDenyPatterns: [],
        ),
      );

      final result = await adapter.requestExternalSendConfirmation(
        task: _record(),
        operationId: 'operation-1',
      );

      expect(result.allowed, isTrue);
      expect(gateway.externalRequests, 1);
      expect(gateway.standardRequests, 0);
      expect(gateway.lastExternal?.task.taskId, 'task-1');
      expect(gateway.lastExternal?.operationId, 'operation-1');
      expect(gateway.lastExternal?.safeTargetSummary, '受保护的本地测试目标');
    });

    test('session-first approval is shared only for non-external operations',
        () async {
      final gateway = _Gateway();
      final adapter = _adapter(
        gateway: gateway,
        settings: const BackgroundTaskPolicySettingsSnapshot(
          approvalPolicy: 'session_first',
          deniedToolNames: {},
          bashCommandDenyPatterns: [],
        ),
      );

      final first = await adapter.requestStandardApproval(
        task: _record(),
        operationId: 'operation-1',
      );
      final second = await adapter.requestStandardApproval(
        task: _record(),
        operationId: 'operation-2',
      );

      expect(first.allowed, isTrue);
      expect(second.allowed, isTrue);
      expect(gateway.standardRequests, 1);
    });
  });
}

SharedBackgroundTaskPolicyAdapter _adapter({
  required _Gateway gateway,
  required BackgroundTaskPolicySettingsSnapshot settings,
}) =>
    SharedBackgroundTaskPolicyAdapter(
      bindings: _Bindings(),
      settings: _Settings(settings),
      approvals: gateway,
    );

BackgroundTaskRecord _record() => BackgroundTaskRecord(
      taskId: 'task-1',
      sessionId: 'session-1',
      createdAt: DateTime.utc(2026, 7, 15),
      updatedAt: DateTime.utc(2026, 7, 15),
      state: BackgroundTaskState.localApproved,
      taskKind: 'memory',
      localPayload: const {'value': 'safe'},
      preview: const BackgroundTaskPreview(
        safeSummary: 'Safe preview',
        sideEffectSummary: 'Local write',
      ),
      previewDigest: List.filled(64, 'a').join(),
      requiresExternalSend: false,
      lastOperationId: 'operation-1',
      lastOutcomeKnown: false,
    );

final class _Bindings implements BackgroundTaskPolicyBindingResolver {
  _Bindings({this.skillStorageReference = false});

  final bool skillStorageReference;

  @override
  BackgroundTaskPolicyBinding? bindingFor(BackgroundTaskRecord task) =>
      BackgroundTaskPolicyBinding(
        toolName: 'memory_add',
        risk: ToolRisk.moderate,
        argumentsFor: (_) => <String, dynamic>{
          if (skillStorageReference)
            'path': '/root/workspace/skills/test/SKILL.md',
          'fact': 'safe',
        },
        safeTargetFor: (_) => '受保护的本地测试目标',
      );
}

final class _Settings implements BackgroundTaskPolicySettings {
  const _Settings(this.value);

  final BackgroundTaskPolicySettingsSnapshot value;

  @override
  Future<BackgroundTaskPolicySettingsSnapshot> read() async => value;
}

final class _Gateway implements BackgroundTaskApprovalGateway {
  int standardRequests = 0;
  int externalRequests = 0;
  BackgroundTaskApprovalPrompt? lastExternal;

  @override
  Future<bool> requestExternalSend(BackgroundTaskApprovalPrompt prompt) async {
    externalRequests++;
    lastExternal = prompt;
    return true;
  }

  @override
  Future<bool> requestStandard(BackgroundTaskApprovalPrompt prompt) async {
    standardRequests++;
    return true;
  }
}
