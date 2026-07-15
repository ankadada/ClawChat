import 'dart:ui';

import 'package:clawchat/models/background_task.dart';
import 'package:clawchat/screens/background_task_center_screen.dart';
import 'package:clawchat/services/background_task_center_controller.dart';
import 'package:clawchat/services/background_task_coordinator.dart';
import 'package:clawchat/services/background_task_definitions.dart';
import 'package:clawchat/services/background_task_foreground_lease.dart';
import 'package:clawchat/services/background_task_policy_adapter.dart';
import 'package:clawchat/services/background_task_store.dart';
import 'package:clawchat/services/tools/tool_policy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'shows only sanitized local task information and safe recovery actions',
      (tester) async {
    final store = InMemoryBackgroundTaskStore();
    final record = _record(
      taskId: 'unknown-task',
      state: BackgroundTaskState.unknownOutcome,
      recoveryReason: 'process_loss_after_started',
      previewSummary:
          'Create a local note for https://private.example/secret recipient@example.com token=RAW_PREVIEW_SECRET',
      localPayload: const {
        'version': 1,
        'fact': 'RAW_PAYLOAD_SECRET',
        'target': 'RAW_TARGET_SECRET',
      },
    );
    await store.write(record);
    final controller = _controller(store);
    await controller.refresh();
    addTearDown(controller.dispose);

    await _pump(
      tester,
      size: const Size(320, 640),
      textScale: 2,
      child: BackgroundTaskCenterScreen(controller: controller),
    );

    expect(find.textContaining('结果未知，需要检查'), findsOneWidget);
    expect(find.textContaining('[已隐藏地址]'), findsOneWidget);
    expect(find.textContaining('[已隐藏收件人]'), findsOneWidget);
    expect(find.textContaining('[已隐藏敏感值]'), findsOneWidget);
    for (final hidden in [
      'RAW_PAYLOAD_SECRET',
      'RAW_TARGET_SECRET',
      'RAW_PREVIEW_SECRET',
      'recipient@example.com',
      'private.example',
      'RAW_EXTERNAL_RESPONSE',
    ]) {
      expect(find.textContaining(hidden), findsNothing);
    }

    await tester.tap(find.byKey(const Key('task-center-record-unknown-task')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('task-center-inspect')),
      240,
      scrollable: _scrollableIn(
        find.byKey(const Key('task-center-detail-unknown-task')),
      ),
    );
    expect(find.byKey(const Key('task-center-inspect')), findsOneWidget);
    await tester.tap(find.byKey(const Key('task-center-inspect')));
    await tester.pumpAndSettle();
    expect(find.text('已保存的本地预览'), findsOneWidget);
    expect(find.textContaining('应用中断后无法确认任务结果。'), findsOneWidget);
    expect(find.textContaining('RAW_PAYLOAD_SECRET'), findsNothing);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('task-center-discard')),
      240,
      scrollable: _scrollableIn(
        find.byKey(const Key('task-center-detail-unknown-task')),
      ),
    );
    expect(find.byKey(const Key('task-center-discard')), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('task-center-discard')))
          .onPressed,
      isNotNull,
    );
    expect(find.text('批准本地计划'), findsNothing);
    expect(find.text('显示即时外发确认'), findsNothing);
    expect(find.text('按当前策略开始'), findsNothing);

    await tester.tap(find.byKey(const Key('task-center-discard')));
    await tester.pumpAndSettle();
    expect(find.text('这只会弃置本机恢复记录，不会继续、重试或发送任务。'), findsOneWidget);
    await tester.tap(find.text('弃置'));
    await tester.pumpAndSettle();
    expect((await store.read('unknown-task'))!.state,
        BackgroundTaskState.cancelled);
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid records keep execution controls disabled',
      (tester) async {
    final store = InMemoryBackgroundTaskStore();
    await store.write(_record(
      taskId: 'invalid-task',
      state: BackgroundTaskState.invalid,
      recoveryReason: 'recipient@example.com/RAW_REASON_SECRET',
    ));
    final controller = _controller(store);
    await controller.refresh();
    addTearDown(controller.dispose);

    await _pump(
      tester,
      size: const Size(360, 700),
      child: BackgroundTaskCenterScreen(controller: controller),
    );

    await tester.tap(find.byKey(const Key('task-center-record-invalid-task')));
    await tester.pumpAndSettle();
    expect(find.text('本地数据无效'), findsOneWidget);
    expect(find.text('为保护本地状态，此记录不能在这里继续、重试或执行。'), findsOneWidget);
    expect(find.textContaining('RAW_REASON_SECRET'), findsNothing);
    await tester.scrollUntilVisible(
      find.byKey(const Key('task-center-inspect')),
      240,
      scrollable: _scrollableIn(
        find.byKey(const Key('task-center-detail-invalid-task')),
      ),
    );
    expect(find.byKey(const Key('task-center-inspect')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('task-center-discard')),
      240,
      scrollable: _scrollableIn(
        find.byKey(const Key('task-center-detail-invalid-task')),
      ),
    );
    expect(find.byKey(const Key('task-center-discard')), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('task-center-discard')))
          .onPressed,
      isNull,
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('task-center-new-task')),
      240,
      scrollable: _scrollableIn(
        find.byKey(const Key('task-center-detail-invalid-task')),
      ),
    );
    expect(find.byKey(const Key('task-center-new-task')), findsOneWidget);
    expect(find.text('批准本地计划'), findsNothing);
    expect(find.text('显示即时外发确认'), findsNothing);
    expect(find.text('按当前策略开始'), findsNothing);
  });

  testWidgets('corrupt durable state clears stale actions and shows safe code',
      (tester) async {
    final protected = _ProtectedTaskStorage();
    final store = SecureBackgroundTaskStore(storage: protected);
    await store.write(_record(
      taskId: 'previously-readable',
      state: BackgroundTaskState.localApproved,
    ));
    final controller = _controller(store);
    await controller.refresh();
    expect(controller.tasks, hasLength(1));

    protected.value = '{"schemaVersion":1,"schemaVersion":1,"records":[]}';
    await controller.refresh();
    addTearDown(controller.dispose);

    expect(controller.tasks, isEmpty);
    expect(controller.safeError, contains('task_store_duplicate_key'));
    await _pump(
      tester,
      size: const Size(360, 700),
      child: BackgroundTaskCenterScreen(controller: controller),
    );
    expect(find.textContaining('task_store_duplicate_key'), findsOneWidget);
    expect(find.byKey(const Key('task-center-record-previously-readable')),
        findsNothing);
    expect(find.byKey(const Key('task-center-dispatch')), findsNothing);
  });

  testWidgets('normal records expose app-owned plan approval and dispatch',
      (tester) async {
    final store = InMemoryBackgroundTaskStore();
    await store.write(_record(
      taskId: 'preview-task',
      state: BackgroundTaskState.previewReady,
    ));
    final controller = _controller(store);
    await controller.refresh();
    addTearDown(controller.dispose);

    await _pump(
      tester,
      size: const Size(360, 700),
      child: BackgroundTaskCenterScreen(controller: controller),
    );

    await tester.tap(find.byKey(const Key('task-center-record-preview-task')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('task-center-approve-plan')),
      240,
      scrollable: _scrollableIn(
        find.byKey(const Key('task-center-detail-preview-task')),
      ),
    );
    await tester.tap(find.byKey(const Key('task-center-approve-plan')));
    await tester.pumpAndSettle();
    expect(find.text('批准本地计划？'), findsOneWidget);
    await tester.tap(find.text('批准计划'));
    await tester.pumpAndSettle();
    expect((await store.read('preview-task'))!.state,
        BackgroundTaskState.localApproved);
    expect(find.byKey(const Key('task-center-dispatch')), findsOneWidget);

    await tester.tap(find.byKey(const Key('task-center-dispatch')));
    await tester.pumpAndSettle();
    expect(
        (await store.read('preview-task'))!.state, BackgroundTaskState.denied);
  });

  testWidgets('external task waits for the JIT external-send control',
      (tester) async {
    final store = InMemoryBackgroundTaskStore();
    await store.write(_record(
      taskId: 'external-task',
      state: BackgroundTaskState.localApproved,
      taskKind: BackgroundTaskProductionDefinitions.shareTextKind,
      localPayload: const {
        'version': 1,
        'text': 'safe share text',
        'subject': null,
      },
      requiresExternalSend: true,
    ));
    final controller = _controller(
      store,
      policy: const _AllowTaskPolicy(),
      foregroundLease: const _GrantLease(),
    );
    await controller.refresh();
    addTearDown(controller.dispose);

    await _pump(
      tester,
      size: const Size(360, 700),
      child: BackgroundTaskCenterScreen(controller: controller),
    );
    await tester.tap(find.byKey(const Key('task-center-record-external-task')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('task-center-dispatch')),
      240,
      scrollable: _scrollableIn(
        find.byKey(const Key('task-center-detail-external-task')),
      ),
    );
    await tester.tap(find.byKey(const Key('task-center-dispatch')));
    await tester.pumpAndSettle();
    expect((await store.read('external-task'))!.state,
        BackgroundTaskState.awaitingExternalApproval);
    expect(
      find.byKey(const Key('task-center-confirm-external')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('task-center-confirm-external')));
    await tester.pumpAndSettle();
    expect((await store.read('external-task'))!.state,
        BackgroundTaskState.unknownOutcome);
  });

  testWidgets(
      'pending approval stays bound to task operation and exact safe target',
      (tester) async {
    final store = InMemoryBackgroundTaskStore();
    final first = _record(
      taskId: 'external-a',
      state: BackgroundTaskState.awaitingExternalApproval,
      taskKind: BackgroundTaskProductionDefinitions.shareTextKind,
      localPayload: const {
        'version': 1,
        'text': 'safe share text A',
        'subject': null,
      },
      requiresExternalSend: true,
      targetSummary: '系统分享面板',
    );
    final second = _record(
      taskId: 'external-b',
      state: BackgroundTaskState.awaitingExternalApproval,
      taskKind: BackgroundTaskProductionDefinitions.shareTextKind,
      localPayload: const {
        'version': 1,
        'text': 'safe share text B',
        'subject': null,
      },
      requiresExternalSend: true,
      targetSummary: '另一个本地详情',
    );
    await store.write(first);
    await store.write(second);
    late BackgroundTaskCenterController controller;
    final policy = _PromptingTaskPolicy(() => controller);
    controller = _controller(
      store,
      policy: policy,
      foregroundLease: const _GrantLease(),
    );
    await controller.refresh();
    addTearDown(controller.dispose);

    await _pump(
      tester,
      size: const Size(900, 700),
      child: BackgroundTaskCenterScreen(controller: controller),
    );
    await tester.tap(find.byKey(const Key('task-center-record-external-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('task-center-confirm-external')));
    await tester.pumpAndSettle();

    expect(find.text('安全目标：系统分享面板'), findsOneWidget);
    expect(
        find.byKey(const Key('task-center-approve-operation')), findsOneWidget);

    await tester.tap(find.byKey(const Key('task-center-record-external-b')));
    await tester.pumpAndSettle();
    expect(find.text('安全目标：系统分享面板'), findsNothing);
    expect(
        find.byKey(const Key('task-center-approve-operation')), findsNothing);
    expect(
      controller.resolvePendingApproval(
        taskId: second.taskId,
        sessionId: second.sessionId,
        operationId: first.lastOperationId!,
        previewDigest: first.previewDigest!,
        safeTargetSummary: '系统分享面板',
        approved: true,
      ),
      isFalse,
    );

    await tester.tap(find.byKey(const Key('task-center-record-external-a')));
    await tester.pumpAndSettle();
    expect(find.text('安全目标：系统分享面板'), findsOneWidget);
    await tester.tap(find.byKey(const Key('task-center-approve-operation')));
    await tester.pumpAndSettle();

    expect((await store.read(first.taskId))!.state,
        BackgroundTaskState.unknownOutcome);
    expect((await store.read(second.taskId))!.state,
        BackgroundTaskState.awaitingExternalApproval);
  });

  testWidgets(
      'book, tabletop, IME, and 200 percent text keep controls out of fold',
      (tester) async {
    final store = InMemoryBackgroundTaskStore();
    await store.write(_record(
      taskId: 'fold-task',
      state: BackgroundTaskState.recoveryRequired,
      recoveryReason: 'process_loss_before_execution',
    ));
    final controller = _controller(store);
    await controller.refresh();
    addTearDown(controller.dispose);
    final media = ValueNotifier(
      const MediaQueryData(
        size: Size(800, 600),
        textScaler: TextScaler.linear(2),
        displayFeatures: [
          DisplayFeature(
            bounds: Rect.fromLTWH(390, 0, 20, 600),
            type: DisplayFeatureType.hinge,
            state: DisplayFeatureState.postureFlat,
          ),
        ],
      ),
    );
    addTearDown(media.dispose);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<MediaQueryData>(
          valueListenable: media,
          child: BackgroundTaskCenterScreen(controller: controller),
          builder: (_, data, child) => MediaQuery(data: data, child: child!),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final listTile = find.byKey(const Key('task-center-record-fold-task'));
    const hinge = Rect.fromLTWH(390, 0, 20, 600);
    expect(tester.getRect(listTile).left, greaterThanOrEqualTo(hinge.right));
    expect(tester.getRect(listTile).overlaps(hinge), isFalse);

    await tester.tap(listTile);
    await tester.pumpAndSettle();
    final inspect = find.byKey(const Key('task-center-inspect'));
    await tester.scrollUntilVisible(
      inspect,
      240,
      scrollable: _scrollableIn(
        find.byKey(const Key('task-center-detail-fold-task')),
      ),
    );
    expect(tester.getRect(inspect).right, lessThanOrEqualTo(hinge.left));
    expect(tester.getRect(inspect).overlaps(hinge), isFalse);

    tester.view.physicalSize = const Size(320, 600);
    media.value = const MediaQueryData(
      size: Size(320, 600),
      textScaler: TextScaler.linear(2),
      viewInsets: EdgeInsets.only(bottom: 260),
      displayFeatures: [
        DisplayFeature(
          bounds: Rect.fromLTWH(0, 300, 320, 20),
          type: DisplayFeatureType.fold,
          state: DisplayFeatureState.postureHalfOpened,
        ),
      ],
    );
    await tester.pumpAndSettle();

    const tabletopHinge = Rect.fromLTWH(0, 300, 320, 20);
    final appBar = find.byType(AppBar);
    expect(tester.getRect(appBar).bottom, lessThanOrEqualTo(tabletopHinge.top));
    expect(tester.getRect(appBar).overlaps(tabletopHinge), isFalse);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pump(
  WidgetTester tester, {
  required Size size,
  required Widget child,
  double textScale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(
        size: size,
        textScaler: TextScaler.linear(textScale),
      ),
      child: child,
    ),
  ));
  await tester.pumpAndSettle();
}

Finder _scrollableIn(Finder list) =>
    find.descendant(of: list, matching: find.byType(Scrollable));

BackgroundTaskCenterController _controller(
  BackgroundTaskStore store, {
  BackgroundTaskPolicy policy = const DenyBackgroundTaskPolicy(),
  BackgroundTaskForegroundLease foregroundLease = const _NoopLease(),
}) {
  final definitions = BackgroundTaskProductionDefinitions(
    writeMemory: (_, __) async => true,
    launchShare: (_, __) async => true,
  );
  return BackgroundTaskCenterController(
    coordinator: BackgroundTaskCoordinator(
      store: store,
      definitions: definitions.definitions,
      policy: policy,
      foregroundLease: foregroundLease,
    ),
    definitions: definitions,
    initializeOnCreate: false,
  );
}

BackgroundTaskRecord _record({
  required String taskId,
  required BackgroundTaskState state,
  String taskKind = BackgroundTaskProductionDefinitions.rememberFactKind,
  String? recoveryReason,
  String previewSummary = 'Prepare a safe local preview',
  Map<String, Object?> localPayload = const {'version': 1, 'fact': 'value'},
  bool requiresExternalSend = false,
  String targetSummary = 'RAW_TARGET_SECRET',
}) {
  const digest =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
  final now = DateTime.utc(2026, 7, 15, 10);
  return BackgroundTaskRecord(
    taskId: taskId,
    sessionId: 'session-$taskId',
    createdAt: now,
    updatedAt: now,
    state: state,
    taskKind: taskKind,
    localPayload: localPayload,
    preview: BackgroundTaskPreview(
      safeSummary: previewSummary,
      sideEffectSummary: 'Local only',
      targetSummary: targetSummary,
    ),
    previewDigest: digest,
    requiresExternalSend: requiresExternalSend,
    lastOperationId: 'operation-$taskId',
    lastReceiptId: 'receipt-$taskId',
    lastReceipt: BackgroundTaskReceipt(
      receiptId: 'receipt-$taskId',
      operationId: 'operation-$taskId',
      state: BackgroundTaskReceiptState.unknownOutcome,
      outcomeKnown: false,
      createdAt: now,
      safeSummary: 'RAW_EXTERNAL_RESPONSE',
    ),
    lastOutcomeKnown: false,
    recoveryReason: recoveryReason,
  );
}

final class _AllowTaskPolicy implements BackgroundTaskPolicy {
  const _AllowTaskPolicy();

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
  }) async =>
      const BackgroundTaskPolicyDecision.allow();

  @override
  Future<BackgroundTaskPolicyDecision> requestStandardApproval({
    required BackgroundTaskRecord task,
    required String operationId,
  }) async =>
      const BackgroundTaskPolicyDecision.allow();
}

final class _PromptingTaskPolicy implements BackgroundTaskPolicy {
  const _PromptingTaskPolicy(this.controller);

  final BackgroundTaskCenterController Function() controller;

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
    final approved = await controller().requestExternalSend(
      BackgroundTaskApprovalPrompt(
        task: task,
        operationId: operationId,
        request: ToolApprovalRequest(
          toolName: 'phone_intent',
          arguments: const <String, dynamic>{
            'action': 'share',
            'params': <String, dynamic>{},
          },
          risk: ToolRisk.dangerous,
          operationId: operationId,
        ),
        kind: BackgroundTaskApprovalKind.externalSend,
        safeTargetSummary: '系统分享面板',
      ),
    );
    return approved
        ? const BackgroundTaskPolicyDecision.allow()
        : const BackgroundTaskPolicyDecision.deny(
            'task_external_confirmation_denied');
  }

  @override
  Future<BackgroundTaskPolicyDecision> requestStandardApproval({
    required BackgroundTaskRecord task,
    required String operationId,
  }) async =>
      const BackgroundTaskPolicyDecision.allow();
}

final class _NoopLease implements BackgroundTaskForegroundLease {
  const _NoopLease();

  @override
  Future<bool> acquire(
          {required String taskId, required String sessionId}) async =>
      false;

  @override
  Future<bool> release(
          {required String taskId, required String sessionId}) async =>
      true;

  @override
  Future<bool> update({
    required String taskId,
    required String sessionId,
    required BackgroundTaskLeaseStatus status,
  }) async =>
      false;
}

final class _GrantLease implements BackgroundTaskForegroundLease {
  const _GrantLease();

  @override
  Future<bool> acquire(
          {required String taskId, required String sessionId}) async =>
      true;

  @override
  Future<bool> release(
          {required String taskId, required String sessionId}) async =>
      true;

  @override
  Future<bool> update({
    required String taskId,
    required String sessionId,
    required BackgroundTaskLeaseStatus status,
  }) async =>
      true;
}

final class _ProtectedTaskStorage implements BackgroundTaskProtectedStorage {
  String? value;

  @override
  Future<String?> read(String key) async => value;

  @override
  Future<void> write(String key, String next) async => value = next;
}
