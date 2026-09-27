import 'package:clawchat/models/background_task.dart';
import 'package:clawchat/models/scheduled_task.dart';
import 'package:clawchat/screens/scheduled_tasks_screen.dart';
import 'package:clawchat/services/scheduled_task_service.dart';
import 'package:clawchat/services/background_task_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A store whose first reads fail, so the screen's error state can be driven
/// deterministically (no sleeps, no timing games).
class _FailingReadStore implements ScheduledTaskStore {
  _FailingReadStore(this.inner);

  final ScheduledTaskStore inner;
  bool failReads = true;
  int readAttempts = 0;

  @override
  Future<List<ScheduledTaskRecord>> readAll() async {
    readAttempts++;
    if (failReads) throw StateError('store unavailable');
    return inner.readAll();
  }

  @override
  Future<void> writeAll(List<ScheduledTaskRecord> records) =>
      inner.writeAll(records);
}

void main() {
  testWidgets('shows the local plans and never auto-executes them',
      (tester) async {
    final store = InMemoryScheduledTaskStore();
    const kind = 'remember_fact_v1';
    final service = ScheduledTaskService(
      store: store,
      clock: () => DateTime.utc(2026, 9, 26, 9),
      newId: () => 'schedule-1',
    );
    await service.create(
      taskId: 'task-1',
      kind: kind,
      cadence: ScheduledTaskCadence.interval,
      firstRunAt: DateTime.utc(2026, 9, 26, 10),
      intervalMinutes: 60,
    );

    await tester.pumpWidget(MaterialApp(
      home: ScheduledTasksScreen(service: service),
    ));
    await tester.pumpAndSettle();

    expect(find.text('task-1'), findsOneWidget);
    expect(find.textContaining('每 60 分钟'), findsOneWidget);
    expect(find.textContaining('需要你再次确认才会执行'), findsOneWidget);

    // Pausing only changes the local plan; nothing is dispatched.
    await tester.tap(find.text('task-1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('暂停'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已暂停'), findsOneWidget);
    expect(await service.due(), isEmpty);
  });

  testWidgets('creating a plan requires the explicit confirmation checkbox',
      (tester) async {
    final service = ScheduledTaskService(
      store: InMemoryScheduledTaskStore(),
      clock: () => DateTime.utc(2026, 9, 26, 9),
      newId: () => 'schedule-1',
    );
    final task = BackgroundTaskRecord(
      taskId: 'task-1',
      sessionId: 'session-1',
      createdAt: DateTime.utc(2026, 9, 26, 8),
      updatedAt: DateTime.utc(2026, 9, 26, 8),
      state: BackgroundTaskState.localApproved,
      taskKind: 'remember_fact_v1',
      localPayload: const {'fact': 'note'},
      preview: null,
      previewDigest: null,
      requiresExternalSend: false,
      lastOutcomeKnown: true,
    );

    await tester.pumpWidget(MaterialApp(
      home: ScheduledTasksScreen(
        service: service,
        availableTasks: [task],
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('新建计划'));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byType(DropdownButtonFormField<BackgroundTaskRecord>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('task-1 · remember_fact_v1').last);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, '确定'));
    await tester.pumpAndSettle();

    // Without the checkbox the dialog stays open and no plan is stored.
    expect(find.text('请先确认计划不会自动执行'), findsOneWidget);
    expect(await service.list(), isEmpty);
  });

  testWidgets('a plan can be created without entering the task center first',
      (tester) async {
    // The settings entry opens this screen with no injected tasks: it has to
    // load the approved local tasks itself, otherwise 新建计划 is a dead end.
    final taskStore = InMemoryBackgroundTaskStore();
    await taskStore.write(BackgroundTaskRecord(
      taskId: 'task-1',
      sessionId: 'session-1',
      createdAt: DateTime.utc(2026, 9, 26, 8),
      updatedAt: DateTime.utc(2026, 9, 26, 8),
      state: BackgroundTaskState.localApproved,
      taskKind: 'remember_fact_v1',
      localPayload: const {'fact': 'note'},
      preview: null,
      previewDigest: null,
      requiresExternalSend: false,
      lastOutcomeKnown: true,
    ));
    final service = ScheduledTaskService(
      store: InMemoryScheduledTaskStore(),
      clock: () => DateTime.utc(2026, 9, 26, 9),
      newId: () => 'schedule-1',
    );

    await tester.pumpWidget(MaterialApp(
      home: ScheduledTasksScreen(service: service, taskStore: taskStore),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('新建计划'));
    await tester.pumpAndSettle();

    // The approved task is offered, so the plan really can be created here.
    await tester
        .tap(find.byType(DropdownButtonFormField<BackgroundTaskRecord>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('task-1 · remember_fact_v1').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '确定'));
    await tester.pumpAndSettle();

    expect(await service.list(), hasLength(1));
    expect(find.textContaining('到期后需要你在任务中心再次确认'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stays readable at 320dp and 200 percent text', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 720);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final service = ScheduledTaskService(
      store: InMemoryScheduledTaskStore(),
      clock: () => DateTime.utc(2026, 9, 26, 9),
      newId: () => 'schedule-1',
    );
    await service.create(
      taskId: 'task-1',
      kind: 'remember_fact_v1',
      cadence: ScheduledTaskCadence.interval,
      firstRunAt: DateTime.utc(2026, 9, 26, 10),
      intervalMinutes: 60,
    );

    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(
          size: Size(320, 720),
          textScaler: TextScaler.linear(2),
        ),
        child: ScheduledTasksScreen(service: service),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('task-1'), findsOneWidget);
    expect(find.textContaining('需要你再次确认才会执行'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed load shows a retry action that recovers',
      (tester) async {
    final store = _FailingReadStore(InMemoryScheduledTaskStore());
    final service = ScheduledTaskService(
      store: store,
      clock: () => DateTime.utc(2026, 9, 26, 9),
      newId: () => 'schedule-1',
    );

    await tester.pumpWidget(MaterialApp(
      home: ScheduledTasksScreen(service: service),
    ));
    await tester.pumpAndSettle();

    expect(find.text('无法读取本地计划'), findsOneWidget);
    final retry = find.widgetWithText(FilledButton, '重试');
    expect(retry, findsOneWidget);
    expect(store.readAttempts, 1);

    store.failReads = false;
    await tester.tap(retry);
    await tester.pumpAndSettle();

    expect(find.text('无法读取本地计划'), findsNothing);
    expect(find.text('暂无计划'), findsOneWidget);
    expect(store.readAttempts, greaterThan(1));
  });

  testWidgets('creating a plan confirms it still needs a manual run',
      (tester) async {
    final service = ScheduledTaskService(
      store: InMemoryScheduledTaskStore(),
      clock: () => DateTime.utc(2026, 9, 26, 9),
      newId: () => 'schedule-1',
    );
    final task = BackgroundTaskRecord(
      taskId: 'task-1',
      sessionId: 'session-1',
      createdAt: DateTime.utc(2026, 9, 26, 8),
      updatedAt: DateTime.utc(2026, 9, 26, 8),
      state: BackgroundTaskState.localApproved,
      taskKind: 'remember_fact_v1',
      localPayload: const {'fact': 'note'},
      preview: null,
      previewDigest: null,
      requiresExternalSend: false,
      lastOutcomeKnown: true,
    );

    await tester.pumpWidget(MaterialApp(
      home: ScheduledTasksScreen(service: service, availableTasks: [task]),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('新建计划'));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byType(DropdownButtonFormField<BackgroundTaskRecord>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('task-1 · remember_fact_v1').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, '确定'));
    await tester.pumpAndSettle();

    expect(await service.list(), hasLength(1));
    expect(
      find.textContaining('到期后需要你在任务中心再次确认'),
      findsOneWidget,
    );
  });

  testWidgets('deleting a plan names it and never claims it is reversible',
      (tester) async {
    final service = ScheduledTaskService(
      store: InMemoryScheduledTaskStore(),
      clock: () => DateTime.utc(2026, 9, 26, 9),
      newId: () => 'schedule-1',
    );
    await service.create(
      taskId: 'task-1',
      kind: 'remember_fact_v1',
      cadence: ScheduledTaskCadence.once,
      firstRunAt: DateTime.utc(2026, 9, 26, 10),
      intervalMinutes: 60,
    );

    await tester.pumpWidget(MaterialApp(
      home: ScheduledTasksScreen(service: service),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('task-1'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '删除'));
    await tester.pumpAndSettle();

    expect(find.textContaining('将删除「task-1」'), findsOneWidget);
    expect(find.textContaining('删除后无法恢复'), findsOneWidget);
    final confirm = find.widgetWithText(FilledButton, '删除');
    expect(confirm, findsOneWidget);

    await tester.tap(confirm);
    await tester.pumpAndSettle();

    expect(await service.list(), isEmpty);
    expect(find.textContaining('已删除计划：task-1'), findsOneWidget);
  });
}
