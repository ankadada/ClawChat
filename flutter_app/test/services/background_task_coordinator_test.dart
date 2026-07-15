import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:clawchat/models/background_task.dart';
import 'package:clawchat/services/background_task_coordinator.dart';
import 'package:clawchat/services/background_task_foreground_lease.dart';
import 'package:clawchat/services/background_task_store.dart';

void main() {
  group('BackgroundTaskCoordinator', () {
    test('dry-run preview has no execution or lease side effect', () async {
      final definition = _DefinitionHarness();
      final policy = _PolicyHarness();
      final lease = _LeaseHarness();
      final coordinator = _coordinator(
        definition: definition,
        policy: policy,
        lease: lease,
      );

      final preview = await coordinator.createPreview(
        sessionId: 'session-1',
        taskKind: 'local_test',
        localPayload: const {'value': 'safe'},
      );

      expect(preview.state, BackgroundTaskState.previewReady);
      expect(preview.previewDigest, isNotNull);
      expect(definition.dryRunCount, 1);
      expect(definition.executeCount, 0);
      expect(lease.acquireCount, 0);
      expect(policy.preflightCount, 1);
    });

    test('non-external task persists start and result before terminal state',
        () async {
      final definition = _DefinitionHarness();
      final policy = _PolicyHarness();
      final lease = _LeaseHarness();
      final store = InMemoryBackgroundTaskStore();
      final coordinator = _coordinator(
        definition: definition,
        policy: policy,
        lease: lease,
        store: store,
      );
      final preview = await coordinator.createPreview(
        sessionId: 'session-1',
        taskKind: 'local_test',
        localPayload: const {'value': 'safe'},
      );
      final approved = await coordinator.approvePlan(
        taskId: preview.taskId,
        previewDigest: preview.previewDigest!,
      );

      final completed = await coordinator.dispatch(
        taskId: approved.taskId,
        previewDigest: approved.previewDigest!,
      );

      expect(completed.state, BackgroundTaskState.succeeded);
      expect(completed.lastReceipt?.state,
          BackgroundTaskReceiptState.resultPersisted);
      expect(completed.lastReceipt?.outcomeKnown, isTrue);
      expect(policy.standardApprovalCount, 1);
      expect(policy.externalApprovalCount, 0);
      expect(definition.executeCount, 1);
      expect(lease.acquireCount, 1);
      expect(lease.releaseCount, 1);
    });

    test('unconfirmed owner lease cannot cross the effect boundary', () async {
      final definition = _DefinitionHarness();
      final lease = _LeaseHarness(acquireResult: false);
      final coordinator = _coordinator(
        definition: definition,
        policy: _PolicyHarness(),
        lease: lease,
      );
      final preview = await coordinator.createPreview(
        sessionId: 'session-1',
        taskKind: 'local_test',
        localPayload: const {'value': 'safe'},
      );
      final approved = await coordinator.approvePlan(
        taskId: preview.taskId,
        previewDigest: preview.previewDigest!,
      );

      final failed = await coordinator.dispatch(
        taskId: approved.taskId,
        previewDigest: approved.previewDigest!,
      );

      expect(failed.state, BackgroundTaskState.failed);
      expect(failed.recoveryReason, 'foreground_lease_unavailable');
      expect(definition.executeCount, 0);
      expect(lease.acquireCount, 1);
      expect(lease.updateCount, 0);
      expect(lease.releaseCount, 0);
    });

    test('lost owner lease confirmation still cannot execute', () async {
      final definition = _DefinitionHarness();
      final lease = _LeaseHarness(updateResult: false);
      final coordinator = _coordinator(
        definition: definition,
        policy: _PolicyHarness(),
        lease: lease,
      );
      final preview = await coordinator.createPreview(
        sessionId: 'session-1',
        taskKind: 'local_test',
        localPayload: const {'value': 'safe'},
      );
      final approved = await coordinator.approvePlan(
        taskId: preview.taskId,
        previewDigest: preview.previewDigest!,
      );

      final failed = await coordinator.dispatch(
        taskId: approved.taskId,
        previewDigest: approved.previewDigest!,
      );

      expect(failed.state, BackgroundTaskState.failed);
      expect(failed.recoveryReason, 'foreground_lease_interrupted');
      expect(definition.executeCount, 0);
      expect(lease.updateCount, 1);
      expect(lease.releaseCount, 1);
    });

    test('interruption during executing save fences effect and terminal write',
        () async {
      final definition = _DefinitionHarness();
      final lease = _LeaseHarness();
      final store = _PausingExecutingStore();
      final coordinator = _coordinator(
        definition: definition,
        policy: _PolicyHarness(),
        lease: lease,
        store: store,
      );
      final preview = await coordinator.createPreview(
        sessionId: 'session-1',
        taskKind: 'local_test',
        localPayload: const {'value': 'safe'},
      );
      final approved = await coordinator.approvePlan(
        taskId: preview.taskId,
        previewDigest: preview.previewDigest!,
      );
      final dispatch = coordinator.dispatch(
        taskId: approved.taskId,
        previewDigest: approved.previewDigest!,
      );

      await store.executingWriteStarted.future;
      final interruption = lease.interrupt(
        taskId: approved.taskId,
        sessionId: approved.sessionId,
        reasonCode: 'foreground_service_interrupted',
      );
      await Future<void>.delayed(Duration.zero);
      store.allowExecutingWrite.complete();

      final result = await dispatch;
      expect(await interruption, isTrue);
      expect(definition.executeCount, 0);
      expect(result.state, BackgroundTaskState.unknownOutcome);
      expect(result.recoveryReason, 'foreground_service_interrupted');
      expect((await store.read(approved.taskId))!.state,
          BackgroundTaskState.unknownOutcome);
      expect((await store.read(approved.taskId))!.lastReceipt?.state,
          BackgroundTaskReceiptState.unknownOutcome);
    });

    test('interruption during effect prevents a later terminal overwrite',
        () async {
      final definitionStarted = Completer<void>();
      final allowDefinition = Completer<void>();
      final definition = _DefinitionHarness(
        executionStarted: definitionStarted,
        allowExecution: allowDefinition,
      );
      final lease = _LeaseHarness();
      final store = InMemoryBackgroundTaskStore();
      final coordinator = _coordinator(
        definition: definition,
        policy: _PolicyHarness(),
        lease: lease,
        store: store,
      );
      final preview = await coordinator.createPreview(
        sessionId: 'session-1',
        taskKind: 'local_test',
        localPayload: const {'value': 'safe'},
      );
      final approved = await coordinator.approvePlan(
        taskId: preview.taskId,
        previewDigest: preview.previewDigest!,
      );
      final dispatch = coordinator.dispatch(
        taskId: approved.taskId,
        previewDigest: approved.previewDigest!,
      );
      await definitionStarted.future;

      expect(
        await lease.interrupt(
          taskId: approved.taskId,
          sessionId: approved.sessionId,
          reasonCode: 'foreground_service_interrupted',
        ),
        isTrue,
      );
      allowDefinition.complete();

      final result = await dispatch;
      expect(definition.executeCount, 1);
      expect(result.state, BackgroundTaskState.unknownOutcome);
      expect((await store.read(approved.taskId))!.state,
          BackgroundTaskState.unknownOutcome);
    });

    test('external task requires plan plus JIT confirmation and no third ask',
        () async {
      final definition = _DefinitionHarness(requiresExternalSend: true);
      final policy = _PolicyHarness();
      final coordinator = _coordinator(
        definition: definition,
        policy: policy,
        lease: _LeaseHarness(),
      );
      final preview = await coordinator.createPreview(
        sessionId: 'session-1',
        taskKind: 'external_test',
        localPayload: const {'value': 'safe'},
      );
      final planApproved = await coordinator.approvePlan(
        taskId: preview.taskId,
        previewDigest: preview.previewDigest!,
      );
      final waiting = await coordinator.dispatch(
        taskId: planApproved.taskId,
        previewDigest: planApproved.previewDigest!,
      );

      expect(waiting.state, BackgroundTaskState.awaitingExternalApproval);
      expect(policy.standardApprovalCount, 0);
      expect(policy.externalApprovalCount, 0);
      expect(definition.executeCount, 0);

      final completed = await coordinator.confirmExternalSend(
        taskId: waiting.taskId,
        operationId: waiting.lastOperationId!,
        previewDigest: waiting.previewDigest!,
      );

      expect(completed.state, BackgroundTaskState.succeeded);
      expect(policy.standardApprovalCount, 0);
      expect(policy.externalApprovalCount, 1);
      expect(definition.executeCount, 1);
    });

    test('unknown outcome is never retried by reconciliation', () async {
      final definition = _DefinitionHarness(outcomeKnown: false);
      final policy = _PolicyHarness();
      final store = InMemoryBackgroundTaskStore();
      final coordinator = _coordinator(
        definition: definition,
        policy: policy,
        lease: _LeaseHarness(),
        store: store,
      );
      final preview = await coordinator.createPreview(
        sessionId: 'session-1',
        taskKind: 'local_test',
        localPayload: const {'value': 'safe'},
      );
      final approved = await coordinator.approvePlan(
        taskId: preview.taskId,
        previewDigest: preview.previewDigest!,
      );
      final unknown = await coordinator.dispatch(
        taskId: approved.taskId,
        previewDigest: approved.previewDigest!,
      );

      expect(unknown.state, BackgroundTaskState.unknownOutcome);
      expect(definition.executeCount, 1);
      await coordinator.reconcileOnStartup();
      expect(definition.executeCount, 1);
      expect(
        () => coordinator.dispatch(
          taskId: unknown.taskId,
          previewDigest: unknown.previewDigest!,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('process-loss reconciliation marks before-start and started records',
        () async {
      final store = InMemoryBackgroundTaskStore();
      final coordinator = _coordinator(
        definition: _DefinitionHarness(),
        policy: _PolicyHarness(),
        lease: _LeaseHarness(),
        store: store,
      );
      final before = _record(
        taskId: 'before-start',
        state: BackgroundTaskState.approvedNotStarted,
        operationId: 'operation-before',
      );
      final started = _record(
        taskId: 'started',
        state: BackgroundTaskState.executing,
        operationId: 'operation-started',
      );
      await store.write(before);
      await store.write(started);

      final reconciled = await coordinator.reconcileOnStartup();

      expect(
        reconciled.singleWhere((task) => task.taskId == before.taskId).state,
        BackgroundTaskState.recoveryRequired,
      );
      expect(
        reconciled.singleWhere((task) => task.taskId == started.taskId).state,
        BackgroundTaskState.unknownOutcome,
      );
    });

    test('owner-scoped native interruption cannot mutate another task',
        () async {
      final lease = _LeaseHarness();
      final executionStarted = Completer<void>();
      final allowExecution = Completer<void>();
      final definition = _DefinitionHarness(
        executionStarted: executionStarted,
        allowExecution: allowExecution,
      );
      final store = InMemoryBackgroundTaskStore();
      final coordinator = _coordinator(
        definition: definition,
        policy: _PolicyHarness(),
        lease: lease,
        store: store,
      );
      final preview = await coordinator.createPreview(
        sessionId: 'session-1',
        taskKind: 'local_test',
        localPayload: const {'value': 'safe'},
      );
      final approved = await coordinator.approvePlan(
        taskId: preview.taskId,
        previewDigest: preview.previewDigest!,
      );
      final second = _record(
        taskId: 'task-second',
        state: BackgroundTaskState.executing,
        operationId: 'operation-second',
      );
      await store.write(second);
      final dispatch = coordinator.dispatch(
        taskId: approved.taskId,
        previewDigest: approved.previewDigest!,
      );
      await executionStarted.future;

      expect(
        await lease.interrupt(
          taskId: approved.taskId,
          sessionId: approved.sessionId,
          reasonCode: 'foreground_service_interrupted',
        ),
        isTrue,
      );

      expect((await store.read(approved.taskId))!.state,
          BackgroundTaskState.unknownOutcome);
      expect((await store.read(second.taskId))!.state,
          BackgroundTaskState.executing);
      expect(lease.releaseCount, 1);
      expect(
        await lease.interrupt(
          taskId: second.taskId,
          sessionId: 'wrong-session',
          reasonCode: 'foreground_service_interrupted',
        ),
        isFalse,
      );
      allowExecution.complete();
      await dispatch;
    });

    test('secure store keeps a strict local record and rejects corruption',
        () async {
      final protected = _ProtectedStorage();
      final store = SecureBackgroundTaskStore(storage: protected);
      final record = _record(
        taskId: 'stored-task',
        state: BackgroundTaskState.previewReady,
      );
      await store.write(record);

      expect((await store.read(record.taskId))!.taskId, record.taskId);
      protected.value = jsonEncode({
        'schemaVersion': 1,
        'records': [42]
      });
      await expectLater(
        store.readAll(),
        throwsA(isA<BackgroundTaskFormatException>()),
      );

      protected.value = '{"schemaVersion":1,"schemaVersion":1,"records":[]}';
      await expectLater(
        store.readAll(),
        throwsA(
          isA<BackgroundTaskFormatException>().having(
            (error) => error.reasonCode,
            'reasonCode',
            'task_store_duplicate_key',
          ),
        ),
      );
      await expectLater(
        _coordinator(
          definition: _DefinitionHarness(),
          policy: _PolicyHarness(),
          lease: _LeaseHarness(),
          store: store,
        ).reconcileOnStartup(),
        throwsA(isA<BackgroundTaskFormatException>()),
      );
    });
  });
}

BackgroundTaskCoordinator _coordinator({
  required _DefinitionHarness definition,
  required _PolicyHarness policy,
  required _LeaseHarness lease,
  BackgroundTaskStore? store,
}) =>
    BackgroundTaskCoordinator(
      store: store ?? InMemoryBackgroundTaskStore(),
      definitions: [definition.definition],
      policy: policy,
      foregroundLease: lease,
      clock: () => DateTime.utc(2026, 7, 15),
      newId: _IdSequence().next,
    );

BackgroundTaskRecord _record({
  required String taskId,
  required BackgroundTaskState state,
  String? operationId,
}) =>
    BackgroundTaskRecord(
      taskId: taskId,
      sessionId: 'session-1',
      createdAt: DateTime.utc(2026, 7, 15),
      updatedAt: DateTime.utc(2026, 7, 15),
      state: state,
      taskKind: 'local_test',
      localPayload: const {'value': 'safe'},
      preview: const BackgroundTaskPreview(
        safeSummary: 'Safe preview',
        sideEffectSummary: 'Local action',
      ),
      previewDigest: List.filled(64, 'a').join(),
      requiresExternalSend: false,
      lastOperationId: operationId,
      lastReceiptId: null,
      lastReceipt: null,
      lastOutcomeKnown: state != BackgroundTaskState.executing,
    );

final class _DefinitionHarness {
  _DefinitionHarness({
    this.requiresExternalSend = false,
    this.outcomeKnown = true,
    this.executionStarted,
    this.allowExecution,
  }) {
    definition = BackgroundTaskDefinition(
      kind: requiresExternalSend ? 'external_test' : 'local_test',
      requiresExternalSend: requiresExternalSend,
      dryRun: (payload) {
        dryRunCount++;
        return const BackgroundTaskPreview(
          safeSummary: 'Safe preview',
          sideEffectSummary: 'Registered test action',
        );
      },
      execute: (_) async {
        executeCount++;
        if (executionStarted != null && !executionStarted!.isCompleted) {
          executionStarted!.complete();
        }
        if (allowExecution != null) await allowExecution!.future;
        return BackgroundTaskExecutionResult(
          succeeded: true,
          outcomeKnown: outcomeKnown,
          safeSummary: 'Test action complete',
        );
      },
    );
  }

  final bool requiresExternalSend;
  final bool outcomeKnown;
  final Completer<void>? executionStarted;
  final Completer<void>? allowExecution;
  late final BackgroundTaskDefinition definition;
  int dryRunCount = 0;
  int executeCount = 0;
}

final class _PolicyHarness implements BackgroundTaskPolicy {
  int preflightCount = 0;
  int standardApprovalCount = 0;
  int externalApprovalCount = 0;

  @override
  Future<BackgroundTaskPolicyDecision> hardAndSkillPreflight({
    required BackgroundTaskRecord task,
    required String operationId,
  }) async {
    preflightCount++;
    return const BackgroundTaskPolicyDecision.allow();
  }

  @override
  Future<BackgroundTaskPolicyDecision> requestExternalSendConfirmation({
    required BackgroundTaskRecord task,
    required String operationId,
  }) async {
    externalApprovalCount++;
    return const BackgroundTaskPolicyDecision.allow();
  }

  @override
  Future<BackgroundTaskPolicyDecision> requestStandardApproval({
    required BackgroundTaskRecord task,
    required String operationId,
  }) async {
    standardApprovalCount++;
    return const BackgroundTaskPolicyDecision.allow();
  }
}

final class _LeaseHarness
    implements
        BackgroundTaskForegroundLease,
        BackgroundTaskLeaseInterruptionSource {
  _LeaseHarness({this.acquireResult = true, this.updateResult = true});

  final bool acquireResult;
  final bool updateResult;
  int acquireCount = 0;
  int updateCount = 0;
  int releaseCount = 0;
  Future<bool> Function({
    required String taskId,
    required String sessionId,
    required String reasonCode,
  })? _handler;

  @override
  Future<bool> acquire({
    required String taskId,
    required String sessionId,
  }) async {
    acquireCount++;
    return acquireResult;
  }

  @override
  Future<bool> release({
    required String taskId,
    required String sessionId,
  }) async {
    releaseCount++;
    return true;
  }

  @override
  Future<bool> update({
    required String taskId,
    required String sessionId,
    required BackgroundTaskLeaseStatus status,
  }) async {
    updateCount++;
    return updateResult;
  }

  @override
  void setInterruptedHandler(
    Future<bool> Function({
      required String taskId,
      required String sessionId,
      required String reasonCode,
    })? handler,
  ) {
    _handler = handler;
  }

  Future<bool> interrupt({
    required String taskId,
    required String sessionId,
    required String reasonCode,
  }) async =>
      await _handler?.call(
        taskId: taskId,
        sessionId: sessionId,
        reasonCode: reasonCode,
      ) ??
      false;
}

final class _PausingExecutingStore implements BackgroundTaskStore {
  final _delegate = InMemoryBackgroundTaskStore();
  final executingWriteStarted = Completer<void>();
  final allowExecutingWrite = Completer<void>();

  @override
  Future<BackgroundTaskRecord?> read(String taskId) => _delegate.read(taskId);

  @override
  Future<List<BackgroundTaskRecord>> readAll() => _delegate.readAll();

  @override
  Future<void> write(BackgroundTaskRecord record) async {
    if (record.state == BackgroundTaskState.executing &&
        !executingWriteStarted.isCompleted) {
      executingWriteStarted.complete();
      await allowExecutingWrite.future;
    }
    await _delegate.write(record);
  }
}

final class _ProtectedStorage implements BackgroundTaskProtectedStorage {
  String? value;

  @override
  Future<String?> read(String key) async => value;

  @override
  Future<void> write(String key, String next) async {
    value = next;
  }
}

final class _IdSequence {
  int _next = 0;

  String next() => 'id-${++_next}';
}
