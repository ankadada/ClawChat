import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import '../models/background_task.dart';
import 'background_task_foreground_lease.dart';
import 'background_task_store.dart';
import 'strict_json_decoder.dart';

final class BackgroundTaskDefinition {
  const BackgroundTaskDefinition({
    required this.kind,
    required this.requiresExternalSend,
    required this.dryRun,
    required this.execute,
  });

  final String kind;
  final bool requiresExternalSend;

  /// This is deliberately synchronous and receives no executor/lease handle.
  /// It validates and creates the deterministic local preview only.
  final BackgroundTaskPreview Function(Map<String, Object?> localPayload)
      dryRun;
  final Future<BackgroundTaskExecutionResult> Function(
    BackgroundTaskRecord task,
  ) execute;
}

final class BackgroundTaskExecutionResult {
  const BackgroundTaskExecutionResult({
    required this.succeeded,
    required this.outcomeKnown,
    required this.safeSummary,
  });

  final bool succeeded;
  final bool outcomeKnown;
  final String safeSummary;
}

final class BackgroundTaskPolicyDecision {
  const BackgroundTaskPolicyDecision.allow()
      : allowed = true,
        reasonCode = null;

  const BackgroundTaskPolicyDecision.deny(this.reasonCode) : allowed = false;

  final bool allowed;
  final String? reasonCode;
}

/// The production adapter must route this through the shared hard-deny,
/// SkillCapabilityPolicy, and current per-call approval contract. This v2.8
/// coordinator cannot create an allow path by itself.
abstract interface class BackgroundTaskPolicy {
  Future<BackgroundTaskPolicyDecision> hardAndSkillPreflight({
    required BackgroundTaskRecord task,
    required String operationId,
  });

  Future<BackgroundTaskPolicyDecision> requestStandardApproval({
    required BackgroundTaskRecord task,
    required String operationId,
  });

  /// This is the exact second external-send confirmation. It replaces—not
  /// supplements—the normal Ask prompt for this external dispatch.
  Future<BackgroundTaskPolicyDecision> requestExternalSendConfirmation({
    required BackgroundTaskRecord task,
    required String operationId,
  });
}

/// Fail closed unless an integration explicitly supplies the shared-policy
/// adapter. It is intentionally not a convenience Auto Allow default.
final class DenyBackgroundTaskPolicy implements BackgroundTaskPolicy {
  const DenyBackgroundTaskPolicy();

  @override
  Future<BackgroundTaskPolicyDecision> hardAndSkillPreflight({
    required BackgroundTaskRecord task,
    required String operationId,
  }) async =>
      const BackgroundTaskPolicyDecision.deny('task_policy_unconfigured');

  @override
  Future<BackgroundTaskPolicyDecision> requestExternalSendConfirmation({
    required BackgroundTaskRecord task,
    required String operationId,
  }) async =>
      const BackgroundTaskPolicyDecision.deny('task_policy_unconfigured');

  @override
  Future<BackgroundTaskPolicyDecision> requestStandardApproval({
    required BackgroundTaskRecord task,
    required String operationId,
  }) async =>
      const BackgroundTaskPolicyDecision.deny('task_policy_unconfigured');
}

/// Durable local task authority. It never schedules, boot-resumes, retries,
/// or executes from reconciliation. Native foreground service calls are only
/// acquired after authorization and are released after a terminal transition.
final class BackgroundTaskCoordinator {
  BackgroundTaskCoordinator({
    required BackgroundTaskStore store,
    required Iterable<BackgroundTaskDefinition> definitions,
    required BackgroundTaskPolicy policy,
    required BackgroundTaskForegroundLease foregroundLease,
    DateTime Function()? clock,
    String Function()? newId,
  })  : _store = store,
        _definitions = _definitionMap(definitions),
        _policy = policy,
        _foregroundLease = foregroundLease,
        _clock = clock ?? DateTime.now,
        _newId = newId ?? const Uuid().v4 {
    if (foregroundLease is BackgroundTaskLeaseInterruptionSource) {
      (foregroundLease as BackgroundTaskLeaseInterruptionSource)
          .setInterruptedHandler(_handleLeaseInterrupted);
    }
  }

  final BackgroundTaskStore _store;
  final Map<String, BackgroundTaskDefinition> _definitions;
  final BackgroundTaskPolicy _policy;
  final BackgroundTaskForegroundLease _foregroundLease;
  final DateTime Function() _clock;
  final String Function() _newId;
  final Map<String, _BackgroundTaskLeaseEpoch> _leaseEpochs = {};
  final Map<String, _BackgroundTaskMutationGate> _mutationGates = {};
  var _nextLeaseEpoch = 0;

  static Map<String, BackgroundTaskDefinition> _definitionMap(
    Iterable<BackgroundTaskDefinition> definitions,
  ) {
    final result = <String, BackgroundTaskDefinition>{};
    for (final definition in definitions) {
      if (result.containsKey(definition.kind)) {
        throw ArgumentError.value(
            definition.kind, 'definitions', 'duplicate kind');
      }
      result[definition.kind] = definition;
    }
    return result;
  }

  Future<BackgroundTaskRecord> createPreview({
    required String sessionId,
    required String taskKind,
    required Map<String, Object?> localPayload,
  }) async {
    final definition = _definitions[taskKind];
    final now = _clock().toUtc();
    final draft = BackgroundTaskRecord(
      taskId: _newId(),
      sessionId: sessionId,
      createdAt: now,
      updatedAt: now,
      state: BackgroundTaskState.draft,
      taskKind: taskKind,
      localPayload: _copyPayload(localPayload),
      preview: null,
      previewDigest: null,
      requiresExternalSend: definition?.requiresExternalSend ?? false,
      lastOutcomeKnown: true,
    );
    await _store.write(draft);
    if (definition == null) {
      return _persistInvalid(draft, 'task_kind_unregistered');
    }

    late final BackgroundTaskPreview preview;
    try {
      preview = definition.dryRun(draft.localPayload);
    } on BackgroundTaskFormatException catch (error) {
      return _persistInvalid(draft, error.reasonCode);
    } catch (_) {
      return _persistInvalid(draft, 'dry_run_invalid');
    }
    final previewDigest = _previewDigest(
      taskKind: taskKind,
      payload: draft.localPayload,
      preview: preview,
      requiresExternalSend: definition.requiresExternalSend,
    );
    final preflight = await _policy.hardAndSkillPreflight(
      task: draft.copyWith(
        preview: preview,
        previewDigest: previewDigest,
        updatedAt: _clock().toUtc(),
      ),
      operationId: 'preflight-${draft.taskId}',
    );
    if (!preflight.allowed) {
      return _persistInvalid(
          draft, _reasonOr(preflight, 'task_preflight_denied'));
    }
    final previewReady = draft.copyWith(
      state: BackgroundTaskState.previewReady,
      updatedAt: _clock().toUtc(),
      preview: preview,
      previewDigest: previewDigest,
    );
    await _store.write(previewReady);
    return previewReady;
  }

  Future<BackgroundTaskRecord> approvePlan({
    required String taskId,
    required String previewDigest,
  }) async {
    final task = await _requireTask(taskId);
    if (task.state != BackgroundTaskState.previewReady ||
        task.previewDigest != previewDigest) {
      throw StateError('task_preview_approval_stale');
    }
    final approved = task.copyWith(
      state: BackgroundTaskState.localApproved,
      updatedAt: _clock().toUtc(),
      planApprovedAt: _clock().toUtc(),
    );
    await _store.write(approved);
    return approved;
  }

  /// Starts an explicit foreground dispatch. For external tasks this records a
  /// fresh operation and stops at JIT confirmation; it never sends here.
  Future<BackgroundTaskRecord> dispatch({
    required String taskId,
    required String previewDigest,
  }) async {
    final task = await _requireTask(taskId);
    if (task.state != BackgroundTaskState.localApproved ||
        task.previewDigest != previewDigest) {
      throw StateError('task_dispatch_not_authorized');
    }
    final operationId = _newId();
    final proposed = task.copyWith(
      updatedAt: _clock().toUtc(),
      lastOperationId: operationId,
      lastReceipt: _receipt(
        operationId: operationId,
        state: BackgroundTaskReceiptState.proposed,
        outcomeKnown: false,
        safeSummary: 'Task dispatch proposed',
      ),
      lastOutcomeKnown: false,
    );
    await _store.write(proposed);
    final preflight = await _policy.hardAndSkillPreflight(
      task: proposed,
      operationId: operationId,
    );
    if (!preflight.allowed) {
      return _persistDenied(
          proposed, _reasonOr(preflight, 'task_preflight_denied'));
    }
    if (proposed.requiresExternalSend) {
      final waiting = proposed.copyWith(
        state: BackgroundTaskState.awaitingExternalApproval,
        updatedAt: _clock().toUtc(),
        lastReceipt: _receipt(
          operationId: operationId,
          state: BackgroundTaskReceiptState.approvalPending,
          outcomeKnown: false,
          safeSummary: 'External confirmation required',
        ),
      );
      await _store.write(waiting);
      return waiting;
    }
    final decision = await _policy.requestStandardApproval(
      task: proposed,
      operationId: operationId,
    );
    if (!decision.allowed) {
      return _persistDenied(
          proposed, _reasonOr(decision, 'task_approval_denied'));
    }
    return _executeApproved(proposed);
  }

  /// Performs the second and final user confirmation for external-send work.
  /// It intentionally does not call normal Ask/Auto approval afterward.
  Future<BackgroundTaskRecord> confirmExternalSend({
    required String taskId,
    required String operationId,
    required String previewDigest,
  }) async {
    final task = await _requireTask(taskId);
    if (task.state != BackgroundTaskState.awaitingExternalApproval ||
        task.lastOperationId != operationId ||
        task.previewDigest != previewDigest ||
        !task.requiresExternalSend) {
      throw StateError('task_external_confirmation_stale');
    }
    final decision = await _policy.requestExternalSendConfirmation(
      task: task,
      operationId: operationId,
    );
    if (!decision.allowed) {
      return _persistDenied(
          task, _reasonOr(decision, 'external_confirmation_denied'));
    }
    return _executeApproved(task);
  }

  /// Startup/service-loss reconciliation never starts, retries, or requeues.
  Future<List<BackgroundTaskRecord>> reconcileOnStartup() async {
    final reconciled = <BackgroundTaskRecord>[];
    final records = await _store.readAll();
    for (final task in records) {
      if (task.state.isTerminal) {
        reconciled.add(task);
        continue;
      }
      final next = task.state == BackgroundTaskState.executing
          ? _unknownOutcome(task, 'process_loss_after_started')
          : _recoveryRequired(task, 'process_loss_before_execution');
      await _store.write(next);
      reconciled.add(next);
    }
    return List.unmodifiable(reconciled);
  }

  /// Reads durable local state for a foreground task-center refresh. This is
  /// intentionally distinct from startup reconciliation: it never changes a
  /// record, schedules work, or attempts execution.
  Future<List<BackgroundTaskRecord>> listTasks() => _store.readAll();

  Future<BackgroundTaskRecord> discardAfterRecovery(String taskId) async {
    final task = await _requireTask(taskId);
    if (task.state != BackgroundTaskState.unknownOutcome &&
        task.state != BackgroundTaskState.recoveryRequired) {
      throw StateError('task_discard_not_available');
    }
    final cancelled = task.copyWith(
      state: BackgroundTaskState.cancelled,
      updatedAt: _clock().toUtc(),
      lastOutcomeKnown: task.lastOutcomeKnown,
      recoveryReason: task.recoveryReason ?? 'discarded_after_recovery',
    );
    await _store.write(cancelled);
    return cancelled;
  }

  Future<BackgroundTaskRecord> _executeApproved(
    BackgroundTaskRecord task,
  ) async {
    final operationId = task.lastOperationId;
    final definition = _definitions[task.taskKind];
    if (operationId == null || definition == null) {
      return _persistInvalid(task, 'task_execution_contract_invalid');
    }
    final approved = task.copyWith(
      state: BackgroundTaskState.approvedNotStarted,
      updatedAt: _clock().toUtc(),
      lastReceipt: _receipt(
        operationId: operationId,
        state: BackgroundTaskReceiptState.approvedNotStarted,
        outcomeKnown: false,
        safeSummary: 'Task approved and not started',
      ),
      lastOutcomeKnown: false,
    );
    await _store.write(approved);
    var leaseAcquired = false;
    var effectStarted = false;
    _BackgroundTaskLeaseEpoch? leaseEpoch;
    try {
      leaseAcquired = await _foregroundLease.acquire(
        taskId: approved.taskId,
        sessionId: approved.sessionId,
      );
      if (!leaseAcquired) {
        return await _persistFailedBeforeStart(
            approved, 'foreground_lease_unavailable');
      }
      leaseEpoch = _activateLease(approved);
      final leaseConfirmed = await _foregroundLease.update(
        taskId: approved.taskId,
        sessionId: approved.sessionId,
        status: BackgroundTaskLeaseStatus.working,
      );
      if (!leaseConfirmed) {
        return await _persistFailedBeforeStart(
          approved,
          'foreground_lease_interrupted',
          leaseEpoch: leaseEpoch,
        );
      }
      final executing = approved.copyWith(
        state: BackgroundTaskState.executing,
        updatedAt: _clock().toUtc(),
        lastReceipt: _receipt(
          operationId: operationId,
          state: BackgroundTaskReceiptState.started,
          outcomeKnown: false,
          safeSummary: 'Task execution started',
        ),
        lastOutcomeKnown: false,
      );
      final executingSaved = await _withTaskMutation(task.taskId, () async {
        // The interruption callback invalidates this epoch before it waits on
        // the same gate, so a stop during this write cannot be overwritten.
        if (!_isLeaseCurrent(leaseEpoch!)) return false;
        await _store.write(executing);
        return _isLeaseCurrent(leaseEpoch);
      });
      if (!executingSaved) {
        return await _readAfterLeaseChange(task.taskId, approved);
      }
      // This is deliberately the final synchronous check before the effect
      // call. There is no await between it and definition.execute.
      if (!_isLeaseCurrent(leaseEpoch)) {
        return await _readAfterLeaseChange(task.taskId, approved);
      }
      effectStarted = true;
      final result = await definition.execute(executing);
      if (!result.outcomeKnown) {
        final unknown = _unknownOutcome(executing, 'execution_outcome_unknown');
        return await _persistTerminalIfCurrent(leaseEpoch, unknown, executing);
      }
      final completed = executing.copyWith(
        state: result.succeeded
            ? BackgroundTaskState.succeeded
            : BackgroundTaskState.failed,
        updatedAt: _clock().toUtc(),
        lastReceipt: _receipt(
          operationId: operationId,
          state: BackgroundTaskReceiptState.resultPersisted,
          outcomeKnown: true,
          safeSummary: result.safeSummary,
        ),
        lastOutcomeKnown: true,
      );
      return await _persistTerminalIfCurrent(leaseEpoch, completed, executing);
    } catch (_) {
      if (!effectStarted) {
        if (leaseEpoch != null && !_isLeaseCurrent(leaseEpoch)) {
          return await _readAfterLeaseChange(task.taskId, approved);
        }
        return await _persistFailedBeforeStart(
          approved,
          'foreground_lease_unavailable',
          leaseEpoch: leaseEpoch,
        );
      }
      if (leaseEpoch == null) {
        return await _persistFailedBeforeStart(
            approved, 'execution_exception_unknown');
      }
      return await _persistExceptionIfCurrent(leaseEpoch, approved);
    } finally {
      if (leaseEpoch != null) {
        leaseEpoch.valid = false;
        if (identical(_leaseEpochs[approved.taskId], leaseEpoch)) {
          _leaseEpochs.remove(approved.taskId);
        }
      }
      if (leaseAcquired) {
        try {
          await _foregroundLease.release(
            taskId: approved.taskId,
            sessionId: approved.sessionId,
          );
        } catch (_) {
          // Lease release cannot revise a durable terminal task receipt.
        }
      }
    }
  }

  Future<bool> _handleLeaseInterrupted({
    required String taskId,
    required String sessionId,
    required String reasonCode,
  }) async {
    final epoch = _leaseEpochs[taskId];
    if (epoch == null || epoch.sessionId != sessionId || !epoch.valid) {
      return false;
    }
    // Invalidate before the first await. Dispatch's post-write and
    // pre-effect checks therefore fail even while this handler is queued.
    epoch.valid = false;
    final changed = await _withTaskMutation(taskId, () async {
      final task = await _store.read(taskId);
      if (task == null ||
          task.sessionId != sessionId ||
          task.state.isTerminal) {
        return false;
      }
      final next = task.state == BackgroundTaskState.executing
          ? _unknownOutcome(task, reasonCode)
          : _recoveryRequired(task, reasonCode);
      await _store.write(next);
      return true;
    });
    try {
      await _foregroundLease.release(taskId: taskId, sessionId: sessionId);
    } catch (_) {
      // Service loss may make release impossible; task state is already local.
    }
    if (identical(_leaseEpochs[taskId], epoch)) {
      _leaseEpochs.remove(taskId);
    }
    return changed;
  }

  void dispose() {
    if (_foregroundLease is BackgroundTaskLeaseInterruptionSource) {
      (_foregroundLease as BackgroundTaskLeaseInterruptionSource)
          .setInterruptedHandler(null);
    }
  }

  Future<BackgroundTaskRecord> _requireTask(String taskId) async {
    final task = await _store.read(taskId);
    if (task == null) throw StateError('task_not_found');
    return task;
  }

  Future<BackgroundTaskRecord> _persistInvalid(
    BackgroundTaskRecord task,
    String reasonCode,
  ) async {
    final invalid = task.copyWith(
      state: BackgroundTaskState.invalid,
      updatedAt: _clock().toUtc(),
      recoveryReason: _boundedReason(reasonCode),
      lastOutcomeKnown: true,
    );
    await _store.write(invalid);
    return invalid;
  }

  Future<BackgroundTaskRecord> _persistDenied(
    BackgroundTaskRecord task,
    String reasonCode,
  ) async {
    final operationId = task.lastOperationId ?? _newId();
    final denied = task.copyWith(
      state: BackgroundTaskState.denied,
      updatedAt: _clock().toUtc(),
      lastOperationId: operationId,
      lastReceipt: _receipt(
        operationId: operationId,
        state: BackgroundTaskReceiptState.denied,
        outcomeKnown: true,
        safeSummary: 'Task denied: ${_boundedReason(reasonCode)}',
      ),
      lastOutcomeKnown: true,
      recoveryReason: _boundedReason(reasonCode),
    );
    await _store.write(denied);
    return denied;
  }

  Future<BackgroundTaskRecord> _persistFailedBeforeStart(
    BackgroundTaskRecord task,
    String reasonCode, {
    _BackgroundTaskLeaseEpoch? leaseEpoch,
  }) async {
    final result = await _withTaskMutation<BackgroundTaskRecord?>(
      task.taskId,
      () async {
        if (leaseEpoch != null && !_isLeaseCurrent(leaseEpoch)) {
          return await _store.read(task.taskId) ?? task;
        }
        final operationId = task.lastOperationId ?? _newId();
        final failed = task.copyWith(
          state: BackgroundTaskState.failed,
          updatedAt: _clock().toUtc(),
          lastOperationId: operationId,
          lastReceipt: _receipt(
            operationId: operationId,
            state: BackgroundTaskReceiptState.resultPersisted,
            outcomeKnown: true,
            safeSummary: 'Task did not start',
          ),
          lastOutcomeKnown: true,
          recoveryReason: _boundedReason(reasonCode),
        );
        await _store.write(failed);
        return leaseEpoch == null || _isLeaseCurrent(leaseEpoch)
            ? failed
            : null;
      },
    );
    return result ?? await _readAfterLeaseChange(task.taskId, task);
  }

  _BackgroundTaskLeaseEpoch _activateLease(BackgroundTaskRecord task) {
    final epoch = _BackgroundTaskLeaseEpoch(
      taskId: task.taskId,
      sessionId: task.sessionId,
      value: ++_nextLeaseEpoch,
    );
    _leaseEpochs[task.taskId] = epoch;
    return epoch;
  }

  bool _isLeaseCurrent(_BackgroundTaskLeaseEpoch epoch) =>
      epoch.valid &&
      identical(_leaseEpochs[epoch.taskId], epoch) &&
      _leaseEpochs[epoch.taskId]?.value == epoch.value;

  Future<BackgroundTaskRecord> _readAfterLeaseChange(
    String taskId,
    BackgroundTaskRecord fallback,
  ) =>
      _withTaskMutation(
        taskId,
        () async => await _store.read(taskId) ?? fallback,
      );

  Future<BackgroundTaskRecord> _persistTerminalIfCurrent(
    _BackgroundTaskLeaseEpoch epoch,
    BackgroundTaskRecord next,
    BackgroundTaskRecord fallback,
  ) async {
    final result = await _withTaskMutation<BackgroundTaskRecord?>(
      next.taskId,
      () async {
        if (!_isLeaseCurrent(epoch)) {
          return await _store.read(next.taskId) ?? fallback;
        }
        await _store.write(next);
        return _isLeaseCurrent(epoch) ? next : null;
      },
    );
    return result ?? await _readAfterLeaseChange(next.taskId, fallback);
  }

  Future<BackgroundTaskRecord> _persistExceptionIfCurrent(
    _BackgroundTaskLeaseEpoch epoch,
    BackgroundTaskRecord fallback,
  ) async {
    final result = await _withTaskMutation<BackgroundTaskRecord?>(
      fallback.taskId,
      () async {
        final latest = await _store.read(fallback.taskId) ?? fallback;
        if (!_isLeaseCurrent(epoch)) return latest;
        final unknown = _unknownOutcome(latest, 'execution_exception_unknown');
        await _store.write(unknown);
        return _isLeaseCurrent(epoch) ? unknown : null;
      },
    );
    return result ?? await _readAfterLeaseChange(fallback.taskId, fallback);
  }

  Future<T> _withTaskMutation<T>(
    String taskId,
    Future<T> Function() action,
  ) {
    final gate = _mutationGates.putIfAbsent(
      taskId,
      _BackgroundTaskMutationGate.new,
    );
    return gate.run(action);
  }

  BackgroundTaskRecord _unknownOutcome(
    BackgroundTaskRecord task,
    String reasonCode,
  ) {
    final operationId = task.lastOperationId ?? _newId();
    return task.copyWith(
      state: BackgroundTaskState.unknownOutcome,
      updatedAt: _clock().toUtc(),
      lastOperationId: operationId,
      lastReceipt: _receipt(
        operationId: operationId,
        state: BackgroundTaskReceiptState.unknownOutcome,
        outcomeKnown: false,
        safeSummary: 'Task outcome needs review',
      ),
      lastOutcomeKnown: false,
      recoveryReason: _boundedReason(reasonCode),
    );
  }

  BackgroundTaskRecord _recoveryRequired(
    BackgroundTaskRecord task,
    String reasonCode,
  ) =>
      task.copyWith(
        state: BackgroundTaskState.recoveryRequired,
        updatedAt: _clock().toUtc(),
        recoveryReason: _boundedReason(reasonCode),
      );

  BackgroundTaskReceipt _receipt({
    required String operationId,
    required BackgroundTaskReceiptState state,
    required bool outcomeKnown,
    required String safeSummary,
  }) =>
      BackgroundTaskReceipt(
        receiptId: _newId(),
        operationId: operationId,
        state: state,
        outcomeKnown: outcomeKnown,
        createdAt: _clock().toUtc(),
        safeSummary: safeSummary.length <= 256
            ? safeSummary
            : safeSummary.substring(0, 256),
      );

  String _previewDigest({
    required String taskKind,
    required Map<String, Object?> payload,
    required BackgroundTaskPreview preview,
    required bool requiresExternalSend,
  }) =>
      sha256
          .convert(
            utf8.encode(
              jsonEncode({
                'taskKind': taskKind,
                'localPayload': payload,
                'preview': preview.toJson(),
                'requiresExternalSend': requiresExternalSend,
              }),
            ),
          )
          .toString();

  Map<String, Object?> _copyPayload(Map<String, Object?> payload) {
    final source = jsonEncode(payload);
    if (utf8.encode(source).length > maxBackgroundTaskPayloadBytes) {
      throw const BackgroundTaskFormatException('task_payload_too_large');
    }
    final decoded = const StrictJsonDecoder(
      maxUtf8Bytes: maxBackgroundTaskPayloadBytes,
      maxNestingDepth: 24,
    ).decodeString(source);
    if (decoded is! Map) {
      throw const BackgroundTaskFormatException('task_payload_invalid');
    }
    return Map<String, Object?>.unmodifiable(
      decoded.map((key, value) => MapEntry(key.toString(), value)),
    );
  }

  String _reasonOr(BackgroundTaskPolicyDecision decision, String fallback) =>
      _boundedReason(decision.reasonCode ?? fallback);

  String _boundedReason(String value) {
    final normalized = value.replaceAll(RegExp(r'[^a-z0-9._-]'), '_');
    final nonEmpty = normalized.isEmpty ? 'unknown' : normalized;
    return nonEmpty.substring(0, nonEmpty.length.clamp(1, 96));
  }
}

final class _BackgroundTaskLeaseEpoch {
  _BackgroundTaskLeaseEpoch({
    required this.taskId,
    required this.sessionId,
    required this.value,
  });

  final String taskId;
  final String sessionId;
  final int value;
  bool valid = true;
}

final class _BackgroundTaskMutationGate {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() action) async {
    final previous = _tail;
    final completed = Completer<void>();
    _tail = completed.future;
    await previous;
    try {
      return await action();
    } finally {
      completed.complete();
    }
  }
}
