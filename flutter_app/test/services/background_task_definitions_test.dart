import 'package:flutter_test/flutter_test.dart';

import 'package:clawchat/models/background_task.dart';
import 'package:clawchat/services/background_task_coordinator.dart';
import 'package:clawchat/services/background_task_definitions.dart';
import 'package:clawchat/services/background_task_foreground_lease.dart';
import 'package:clawchat/services/background_task_store.dart';

void main() {
  group('BackgroundTaskProductionDefinitions', () {
    test('local memory preview is sanitized and has no write side effect',
        () async {
      var writes = 0;
      final definitions = BackgroundTaskProductionDefinitions(
        writeMemory: (_, __) async {
          writes++;
          return true;
        },
      );
      final coordinator = _coordinator(definitions);

      final preview = await coordinator.createPreview(
        sessionId: 'session-1',
        taskKind: BackgroundTaskProductionDefinitions.rememberFactKind,
        localPayload: definitions.payloadFor(
          kind: BackgroundTaskProductionDefinitions.rememberFactKind,
          text: 'private fact that must stay local',
        ),
      );

      expect(preview.state, BackgroundTaskState.previewReady);
      expect(preview.preview!.safeSummary, isNot(contains('private fact')));
      expect(writes, 0);

      final approved = await coordinator.approvePlan(
        taskId: preview.taskId,
        previewDigest: preview.previewDigest!,
      );
      final complete = await coordinator.dispatch(
        taskId: approved.taskId,
        previewDigest: approved.previewDigest!,
      );
      expect(complete.state, BackgroundTaskState.succeeded);
      expect(writes, 1);
    });

    test('share kind pauses for JIT and never claims external delivery known',
        () async {
      var shares = 0;
      final definitions = BackgroundTaskProductionDefinitions(
        launchShare: (_, __) async {
          shares++;
          return true;
        },
      );
      final policy = _AllowPolicy();
      final coordinator = _coordinator(definitions, policy: policy);
      final preview = await coordinator.createPreview(
        sessionId: 'session-1',
        taskKind: BackgroundTaskProductionDefinitions.shareTextKind,
        localPayload: definitions.payloadFor(
          kind: BackgroundTaskProductionDefinitions.shareTextKind,
          text: 'sensitive shared text',
          subject: 'subject',
        ),
      );
      expect(preview.preview!.safeSummary, isNot(contains('sensitive shared')));
      expect(preview.preview!.targetSummary, '系统分享面板');

      final approved = await coordinator.approvePlan(
        taskId: preview.taskId,
        previewDigest: preview.previewDigest!,
      );
      final waiting = await coordinator.dispatch(
        taskId: approved.taskId,
        previewDigest: approved.previewDigest!,
      );
      expect(waiting.state, BackgroundTaskState.awaitingExternalApproval);
      expect(shares, 0);
      expect(policy.standardApprovals, 0);

      final outcome = await coordinator.confirmExternalSend(
        taskId: waiting.taskId,
        operationId: waiting.lastOperationId!,
        previewDigest: waiting.previewDigest!,
      );
      expect(shares, 1);
      expect(policy.externalApprovals, 1);
      expect(outcome.state, BackgroundTaskState.unknownOutcome);
      expect(outcome.lastOutcomeKnown, isFalse);
    });

    test('unregistered kind cannot obtain a runnable definition', () async {
      final coordinator = _coordinator(BackgroundTaskProductionDefinitions());
      final invalid = await coordinator.createPreview(
        sessionId: 'session-1',
        taskKind: 'arbitrary_executor',
        localPayload: const {'version': 1},
      );

      expect(invalid.state, BackgroundTaskState.invalid);
      expect(invalid.recoveryReason, 'task_kind_unregistered');
    });

    test('registered kind rejects an unexpected payload shape before execution',
        () async {
      var writes = 0;
      final definitions = BackgroundTaskProductionDefinitions(
        writeMemory: (_, __) async {
          writes++;
          return true;
        },
      );
      final coordinator = _coordinator(definitions);

      final invalid = await coordinator.createPreview(
        sessionId: 'session-1',
        taskKind: BackgroundTaskProductionDefinitions.rememberFactKind,
        localPayload: const {'version': 1, 'fact': 'safe', 'extra': true},
      );

      expect(invalid.state, BackgroundTaskState.invalid);
      expect(invalid.recoveryReason, 'task_payload_fields_invalid');
      expect(writes, 0);
    });
  });
}

BackgroundTaskCoordinator _coordinator(
  BackgroundTaskProductionDefinitions definitions, {
  BackgroundTaskPolicy? policy,
}) =>
    BackgroundTaskCoordinator(
      store: InMemoryBackgroundTaskStore(),
      definitions: definitions.definitions,
      policy: policy ?? _AllowPolicy(),
      foregroundLease: _Lease(),
      clock: () => DateTime.utc(2026, 7, 15),
      newId: _Ids().next,
    );

final class _AllowPolicy implements BackgroundTaskPolicy {
  int standardApprovals = 0;
  int externalApprovals = 0;

  @override
  Future<BackgroundTaskPolicyDecision> hardAndSkillPreflight({
    required BackgroundTaskRecord task,
    required String operationId,
  }) async =>
      const BackgroundTaskPolicyDecision.allow();

  @override
  Future<BackgroundTaskPolicyDecision> requestExternalSendConfirmation({
    required BackgroundTaskRecord task,
    required String operationId,
  }) async {
    externalApprovals++;
    return const BackgroundTaskPolicyDecision.allow();
  }

  @override
  Future<BackgroundTaskPolicyDecision> requestStandardApproval({
    required BackgroundTaskRecord task,
    required String operationId,
  }) async {
    standardApprovals++;
    return const BackgroundTaskPolicyDecision.allow();
  }
}

final class _Lease implements BackgroundTaskForegroundLease {
  @override
  Future<bool> acquire({
    required String taskId,
    required String sessionId,
  }) async =>
      true;

  @override
  Future<bool> release({
    required String taskId,
    required String sessionId,
  }) async =>
      true;

  @override
  Future<bool> update({
    required String taskId,
    required String sessionId,
    required BackgroundTaskLeaseStatus status,
  }) async =>
      true;
}

final class _Ids {
  int _value = 0;

  String next() => 'id-${++_value}';
}
