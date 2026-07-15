import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/background_task.dart';
import 'background_task_coordinator.dart';
import 'background_task_definitions.dart';
import 'background_task_foreground_lease.dart';
import 'background_task_policy_adapter.dart';
import 'background_task_store.dart';
import 'preferences_service.dart';

final class PreferencesBackgroundTaskPolicySettings
    implements BackgroundTaskPolicySettings {
  PreferencesBackgroundTaskPolicySettings({PreferencesService? preferences})
      : _preferences = preferences ?? PreferencesService();

  final PreferencesService _preferences;

  @override
  Future<BackgroundTaskPolicySettingsSnapshot> read() async {
    await _preferences.init();
    return BackgroundTaskPolicySettingsSnapshot(
      approvalPolicy: _preferences.toolApprovalPolicy,
      deniedToolNames: Set<String>.unmodifiable(_preferences.deniedToolNames),
      bashCommandDenyPatterns:
          List<String>.unmodifiable(_preferences.bashCommandDenyPatterns),
    );
  }
}

/// Local UI owner for v2.8 durable tasks. It receives all approval decisions
/// from the shared-policy adapter, but remains unable to alter native lease or
/// durable state directly; those operations stay in [BackgroundTaskCoordinator].
final class BackgroundTaskCenterController extends ChangeNotifier
    implements BackgroundTaskApprovalGateway {
  BackgroundTaskCenterController({
    required BackgroundTaskCoordinator coordinator,
    required BackgroundTaskProductionDefinitions definitions,
    this.defaultSessionId = 'background_task_center',
    bool initializeOnCreate = true,
  })  : _coordinator = coordinator,
        _definitions = definitions {
    if (initializeOnCreate) unawaited(reconcileAtStartup());
  }

  factory BackgroundTaskCenterController.createForApp({
    PreferencesService? preferences,
  }) {
    final definitions = BackgroundTaskProductionDefinitions();
    late final BackgroundTaskCenterController controller;
    final policy = SharedBackgroundTaskPolicyAdapter(
      bindings: definitions,
      settings: PreferencesBackgroundTaskPolicySettings(
        preferences: preferences,
      ),
      approvals: _DeferredBackgroundTaskApprovalGateway(
        () => controller,
      ),
    );
    final coordinator = BackgroundTaskCoordinator(
      store: SecureBackgroundTaskStore(),
      definitions: definitions.definitions,
      policy: policy,
      foregroundLease: NativeBackgroundTaskForegroundLease(),
    );
    controller = BackgroundTaskCenterController(
      coordinator: coordinator,
      definitions: definitions,
    );
    return controller;
  }

  final BackgroundTaskCoordinator _coordinator;
  final BackgroundTaskProductionDefinitions _definitions;
  final String defaultSessionId;
  final Set<String> _busyTaskIds = <String>{};
  List<BackgroundTaskRecord> _tasks = const [];
  BackgroundTaskApprovalPrompt? _pendingApproval;
  Completer<bool>? _pendingApprovalResult;
  String? _safeError;
  bool _disposed = false;

  List<BackgroundTaskRecord> get tasks => List.unmodifiable(_tasks);
  List<RegisteredBackgroundTaskKind> get registeredKinds =>
      BackgroundTaskProductionDefinitions.kinds;
  BackgroundTaskApprovalPrompt? get pendingApproval => _pendingApproval;
  bool get hasPendingApproval => _pendingApproval != null;
  String? get safeError => _safeError;
  bool isBusy(String taskId) => _busyTaskIds.contains(taskId);

  RegisteredBackgroundTaskKind? kindFor(String kind) =>
      _definitions.kindFor(kind);

  BackgroundTaskApprovalPrompt? pendingApprovalFor(
    BackgroundTaskRecord task,
  ) {
    final prompt = _pendingApproval;
    if (prompt == null ||
        prompt.task.taskId != task.taskId ||
        prompt.task.sessionId != task.sessionId ||
        prompt.operationId != task.lastOperationId ||
        prompt.task.previewDigest != task.previewDigest) {
      return null;
    }
    return prompt;
  }

  /// This is the only recovery entry point. It only marks interrupted records;
  /// it never restarts, retries, or requeues a task.
  Future<void> reconcileAtStartup() async {
    try {
      _tasks = _sort(await _coordinator.reconcileOnStartup());
      _safeError = null;
    } on BackgroundTaskFormatException catch (error) {
      _tasks = const [];
      _safeError = _storeRecoveryMessage(error.reasonCode);
    } on Object {
      _tasks = const [];
      _safeError = '本地任务状态暂时无法读取；旧状态已隔离，不会自动执行。';
    }
    _notify();
  }

  Future<void> refresh() async {
    try {
      _tasks = _sort(await _coordinator.listTasks());
      _safeError = null;
    } on BackgroundTaskFormatException catch (error) {
      _tasks = const [];
      _safeError = _storeRecoveryMessage(error.reasonCode);
    } on Object {
      _tasks = const [];
      _safeError = '本地任务状态暂时无法读取；旧状态已隔离，不会自动执行。';
    }
    _notify();
  }

  Future<BackgroundTaskRecord?> createPreview({
    required String kind,
    required String text,
    String? subject,
  }) async {
    if (_definitions.kindFor(kind) == null || text.trim().isEmpty) {
      _safeError = '请提供任务内容，并选择受支持的本地任务类型。';
      _notify();
      return null;
    }
    try {
      final record = await _coordinator.createPreview(
        sessionId: defaultSessionId,
        taskKind: kind,
        localPayload: _definitions.payloadFor(
          kind: kind,
          text: text,
          subject: subject,
        ),
      );
      await refresh();
      return record;
    } on Object {
      _safeError = '无法创建本地任务预览；没有执行任何操作。';
      _notify();
      return null;
    }
  }

  Future<void> approvePlan(BackgroundTaskRecord task) => _forTask(
        task.taskId,
        () async {
          final digest = task.previewDigest;
          if (digest == null) throw StateError('task_preview_missing');
          await _coordinator.approvePlan(
            taskId: task.taskId,
            previewDigest: digest,
          );
        },
      );

  Future<void> dispatch(BackgroundTaskRecord task) => _forTask(
        task.taskId,
        () async {
          final digest = task.previewDigest;
          if (digest == null) throw StateError('task_preview_missing');
          await _coordinator.dispatch(
              taskId: task.taskId, previewDigest: digest);
        },
      );

  Future<void> confirmExternalSend(BackgroundTaskRecord task) => _forTask(
        task.taskId,
        () async {
          final digest = task.previewDigest;
          final operationId = task.lastOperationId;
          if (digest == null || operationId == null) {
            throw StateError('task_external_confirmation_missing');
          }
          await _coordinator.confirmExternalSend(
            taskId: task.taskId,
            operationId: operationId,
            previewDigest: digest,
          );
        },
      );

  Future<void> discardAfterRecovery(BackgroundTaskRecord task) => _forTask(
        task.taskId,
        () => _coordinator.discardAfterRecovery(task.taskId),
      );

  @override
  Future<bool> requestStandard(BackgroundTaskApprovalPrompt prompt) =>
      _requestApproval(prompt);

  @override
  Future<bool> requestExternalSend(BackgroundTaskApprovalPrompt prompt) =>
      _requestApproval(prompt);

  bool resolvePendingApproval({
    required String taskId,
    required String sessionId,
    required String operationId,
    required String previewDigest,
    required String safeTargetSummary,
    required bool approved,
  }) {
    final prompt = _pendingApproval;
    final completer = _pendingApprovalResult;
    if (prompt == null ||
        prompt.task.taskId != taskId ||
        prompt.task.sessionId != sessionId ||
        prompt.operationId != operationId ||
        prompt.request.operationId != operationId ||
        prompt.task.previewDigest != previewDigest ||
        prompt.safeTargetSummary != safeTargetSummary ||
        completer == null ||
        completer.isCompleted) {
      return false;
    }
    _pendingApproval = null;
    _pendingApprovalResult = null;
    completer.complete(approved);
    _notify();
    return true;
  }

  Future<bool> _requestApproval(BackgroundTaskApprovalPrompt prompt) {
    if (_pendingApproval != null || !_isApprovalPromptBound(prompt)) {
      return Future<bool>.value(false);
    }
    final result = Completer<bool>();
    _pendingApproval = prompt;
    _pendingApprovalResult = result;
    _notify();
    return result.future;
  }

  Future<void> _forTask(
    String taskId,
    Future<void> Function() operation,
  ) async {
    if (_busyTaskIds.contains(taskId)) return;
    _busyTaskIds.add(taskId);
    _safeError = null;
    _notify();
    try {
      await operation();
    } on Object {
      _safeError = '任务状态未更新；不会自动重试。请检查本地任务详情。';
    } finally {
      _busyTaskIds.remove(taskId);
      await refresh();
    }
  }

  List<BackgroundTaskRecord> _sort(List<BackgroundTaskRecord> records) {
    final sorted = records.toList(growable: false)
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List.unmodifiable(sorted);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    final pending = _pendingApprovalResult;
    _pendingApproval = null;
    _pendingApprovalResult = null;
    if (pending != null && !pending.isCompleted) pending.complete(false);
    _coordinator.dispose();
    super.dispose();
  }
}

bool _isApprovalPromptBound(BackgroundTaskApprovalPrompt prompt) {
  final digest = prompt.task.previewDigest;
  return prompt.task.taskId.isNotEmpty &&
      prompt.task.sessionId.isNotEmpty &&
      digest != null &&
      prompt.task.lastOperationId == prompt.operationId &&
      prompt.request.operationId == prompt.operationId &&
      prompt.safeTargetSummary.isNotEmpty &&
      prompt.safeTargetSummary.length <= 160 &&
      !prompt.safeTargetSummary.contains(RegExp(r'[\x00-\x1f\x7f]'));
}

String _storeRecoveryMessage(String reasonCode) {
  final bounded = reasonCode.replaceAll(RegExp(r'[^a-z0-9._-]'), '_');
  final code = bounded.isEmpty
      ? 'task_store_invalid'
      : bounded.substring(0, bounded.length.clamp(1, 96));
  return '本地任务状态无法验证（$code）；旧状态已隔离，不会自动执行。';
}

final class _DeferredBackgroundTaskApprovalGateway
    implements BackgroundTaskApprovalGateway {
  const _DeferredBackgroundTaskApprovalGateway(this._controller);

  final BackgroundTaskCenterController Function() _controller;

  @override
  Future<bool> requestExternalSend(BackgroundTaskApprovalPrompt prompt) =>
      _controller().requestExternalSend(prompt);

  @override
  Future<bool> requestStandard(BackgroundTaskApprovalPrompt prompt) =>
      _controller().requestStandard(prompt);
}
