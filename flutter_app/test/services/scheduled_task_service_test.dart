import 'package:clawchat/models/background_task.dart';
import 'package:clawchat/models/scheduled_task.dart';
import 'package:clawchat/services/scheduled_task_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DateTime now;
  late InMemoryScheduledTaskStore store;
  late ScheduledTaskService service;

  setUp(() {
    now = DateTime.utc(2026, 9, 26, 9);
    store = InMemoryScheduledTaskStore();
    var id = 0;
    service = ScheduledTaskService(
      store: store,
      clock: () => now,
      newId: () => 'schedule-${++id}',
    );
  });

  test('creates one local plan per background task', () async {
    final first = await service.create(
      taskId: 'task-1',
      kind: 'remember_fact_v1',
      cadence: ScheduledTaskCadence.once,
      firstRunAt: now.add(const Duration(hours: 1)),
    );

    expect(first.scheduleId, 'schedule-1');
    expect(first.taskId, 'task-1');
    expect(first.paused, isFalse);
    expect(first.intervalMinutes, 0);
    expect(first.nextRunAt, now.add(const Duration(hours: 1)));

    await expectLater(
      service.create(
        taskId: 'task-1',
        kind: 'remember_fact_v1',
        cadence: ScheduledTaskCadence.once,
        firstRunAt: now,
      ),
      throwsA(isA<ScheduledTaskFormatException>()),
    );
    expect(await service.list(), hasLength(1));
  });

  test('interval plans must stay inside the allowed window', () async {
    for (final invalid in const [0, 1, 14, 24 * 60 + 1]) {
      await expectLater(
        service.create(
          taskId: 'task-$invalid',
          kind: 'remember_fact_v1',
          cadence: ScheduledTaskCadence.interval,
          firstRunAt: now,
          intervalMinutes: invalid,
        ),
        throwsA(isA<ScheduledTaskFormatException>()),
      );
    }
    final plan = await service.create(
      taskId: 'task-ok',
      kind: 'remember_fact_v1',
      cadence: ScheduledTaskCadence.interval,
      firstRunAt: now,
      intervalMinutes: 30,
    );
    expect(plan.intervalMinutes, 30);
  });

  test('due() returns only active plans whose time arrived', () async {
    await service.create(
      taskId: 'due-soon',
      kind: 'remember_fact_v1',
      cadence: ScheduledTaskCadence.once,
      firstRunAt: now.subtract(const Duration(minutes: 1)),
    );
    await service.create(
      taskId: 'future',
      kind: 'remember_fact_v1',
      cadence: ScheduledTaskCadence.once,
      firstRunAt: now.add(const Duration(hours: 2)),
    );
    await service.create(
      taskId: 'paused',
      kind: 'remember_fact_v1',
      cadence: ScheduledTaskCadence.once,
      firstRunAt: now.subtract(const Duration(hours: 1)),
    );
    await service.pause('schedule-3');

    final due = await service.due();
    expect(due.map((plan) => plan.taskId), ['due-soon']);
  });

  test('a once plan completes after one run and records history', () async {
    await service.create(
      taskId: 'task-1',
      kind: 'remember_fact_v1',
      cadence: ScheduledTaskCadence.once,
      firstRunAt: now,
    );

    final updated = await service.markRun(
      scheduleId: 'schedule-1',
      backgroundTaskId: 'background-1',
      state: BackgroundTaskState.succeeded.wireValue,
    );

    expect(updated, isNotNull);
    expect(updated!.isFinished, isTrue);
    expect(updated.nextRunAt, isNull);
    expect(updated.lastState, 'succeeded');
    expect(updated.failureCount, 0);
    expect(updated.history, hasLength(1));
    expect(updated.history.single.backgroundTaskId, 'background-1');
    expect(updated.nextRunSummary(now), '已完成');
    expect(await service.due(), isEmpty);
  });

  test('an interval plan advances without replaying missed runs', () async {
    await service.create(
      taskId: 'task-1',
      kind: 'remember_fact_v1',
      cadence: ScheduledTaskCadence.interval,
      firstRunAt: now,
      intervalMinutes: 60,
    );

    final firstRun = await service.markRun(
      scheduleId: 'schedule-1',
      backgroundTaskId: 'background-1',
      state: BackgroundTaskState.succeeded.wireValue,
      now: now.add(const Duration(minutes: 5)),
    );
    // The next occurrence follows the planned time, not the confirmation time.
    expect(
      firstRun!.nextRunAt,
      now.add(const Duration(minutes: 60)),
    );

    // A long pause must not fire every missed occurrence at once.
    final afterPause = await service.markRun(
      scheduleId: 'schedule-1',
      backgroundTaskId: 'background-2',
      state: BackgroundTaskState.succeeded.wireValue,
      now: now.add(const Duration(days: 3)),
    );
    expect(afterPause!.nextRunAt!.isAfter(now.add(const Duration(days: 3))), isTrue);
    expect(
      afterPause.nextRunAt!.difference(now.add(const Duration(days: 3))).inMinutes,
      lessThanOrEqualTo(60),
    );
  });

  test('failures are counted, retried, and bounded in history', () async {
    await service.create(
      taskId: 'task-1',
      kind: 'remember_fact_v1',
      cadence: ScheduledTaskCadence.interval,
      firstRunAt: now,
      intervalMinutes: 15,
    );

    var current = now;
    for (var index = 0; index < maxScheduledTaskHistoryEntries + 5; index++) {
      current = current.add(const Duration(minutes: 15));
      final updated = await service.markRun(
        scheduleId: 'schedule-1',
        backgroundTaskId: 'background-$index',
        state: BackgroundTaskState.failed.wireValue,
        now: current,
      );
      expect(updated!.failureCount, greaterThan(0));
    }

    final plan = (await service.list()).single;
    expect(plan.history, hasLength(maxScheduledTaskHistoryEntries));
    expect(plan.failureCount, lessThanOrEqualTo(plan.retryLimit + 1));
    expect(plan.lastOutcomeSummary, contains('失败'));

    final recovered = await service.markRun(
      scheduleId: 'schedule-1',
      backgroundTaskId: 'background-recovered',
      state: BackgroundTaskState.succeeded.wireValue,
      now: current.add(const Duration(minutes: 15)),
    );
    expect(recovered!.failureCount, 0);
    expect(recovered.lastOutcomeSummary, '上次成功');
  });

  test('pause, resume, and delete keep the plan local', () async {
    await service.create(
      taskId: 'task-1',
      kind: 'remember_fact_v1',
      cadence: ScheduledTaskCadence.once,
      firstRunAt: now.add(const Duration(hours: 1)),
    );

    expect(await service.pause('schedule-1'), isTrue);
    expect((await service.list()).single.paused, isTrue);
    expect(await service.pause('schedule-1'), isFalse);

    expect(await service.resume('schedule-1'), isTrue);
    expect((await service.list()).single.paused, isFalse);

    expect(await service.delete('schedule-1'), isTrue);
    expect(await service.list(), isEmpty);
    expect(await service.delete('schedule-1'), isFalse);
  });

  test('a consumed once plan needs an explicit new time to resume', () async {
    await service.create(
      taskId: 'task-1',
      kind: 'remember_fact_v1',
      cadence: ScheduledTaskCadence.once,
      firstRunAt: now,
    );
    await service.markRun(
      scheduleId: 'schedule-1',
      backgroundTaskId: 'background-1',
      state: BackgroundTaskState.succeeded.wireValue,
      now: now,
    );

    expect(await service.resume('schedule-1'), isFalse);
    expect(
      await service.resume(
        'schedule-1',
        nextRunAt: now.add(const Duration(days: 1)),
      ),
      isTrue,
    );
    final plan = (await service.list()).single;
    expect(plan.nextRunAt, now.add(const Duration(days: 1)));
    expect(plan.paused, isFalse);
  });

  test('the protected preferences store round-trips bounded records', () async {
    SharedPreferences.setMockInitialValues({});
    final store = SharedPreferencesScheduledTaskStore();
    final service = ScheduledTaskService(
      store: store,
      clock: () => now,
      newId: () => 'schedule-round-trip',
    );
    await service.create(
      taskId: 'task-1',
      kind: 'remember_fact_v1',
      cadence: ScheduledTaskCadence.interval,
      firstRunAt: now,
      intervalMinutes: 15,
    );
    await service.markRun(
      scheduleId: 'schedule-round-trip',
      backgroundTaskId: 'background-1',
      state: BackgroundTaskState.failed.wireValue,
      now: now.add(const Duration(minutes: 15)),
    );

    final reopened = ScheduledTaskService(
      store: SharedPreferencesScheduledTaskStore(),
      clock: () => now,
    );
    final plan = (await reopened.list()).single;
    expect(plan.scheduleId, 'schedule-round-trip');
    expect(plan.failureCount, 1);
    expect(plan.history.single.state, 'failed');
  });

  test('a corrupt store fails closed instead of guessing', () async {
    SharedPreferences.setMockInitialValues({
      SharedPreferencesScheduledTaskStore.storageKey: '{"schemaVersion":9}',
    });
    final service = ScheduledTaskService(
      store: SharedPreferencesScheduledTaskStore(),
    );
    await expectLater(
      service.list(),
      throwsA(isA<ScheduledTaskFormatException>()),
    );
  });

  test('record limit is enforced locally', () async {
    for (var index = 0; index < maxScheduledTaskRecords; index++) {
      await service.create(
        taskId: 'task-$index',
        kind: 'remember_fact_v1',
        cadence: ScheduledTaskCadence.once,
        firstRunAt: now,
      );
    }
    await expectLater(
      service.create(
        taskId: 'task-overflow',
        kind: 'remember_fact_v1',
        cadence: ScheduledTaskCadence.once,
        firstRunAt: now,
      ),
      throwsA(isA<ScheduledTaskFormatException>()),
    );
  });
}
