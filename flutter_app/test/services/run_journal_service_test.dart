import 'dart:convert';

import 'package:clawchat/models/chat_models.dart';
import 'package:clawchat/models/run_journal.dart';
import 'package:clawchat/services/memory_trust_store.dart';
import 'package:clawchat/services/run_journal_service.dart';
import 'package:clawchat/services/run_journal_store.dart';
import 'package:flutter_test/flutter_test.dart';

ToolAttemptRecoveryMetadata _attempt(
  String operationId, {
  String toolName = 'read_file',
  ToolAttemptLifecycle lifecycle = ToolAttemptLifecycle.resultPersisted,
  bool outcomeKnown = true,
  DateTime? stamp,
}) {
  final at = stamp ?? DateTime.utc(2026, 9, 27, 12);
  return ToolAttemptRecoveryMetadata(
    operationId: operationId,
    toolName: toolName,
    risk: RecoveryToolRisk.moderate,
    lifecycle: lifecycle,
    proposedAt: at,
    updatedAt: at.add(const Duration(seconds: 1)),
    executionStartedAt: lifecycle == ToolAttemptLifecycle.started ||
            lifecycle == ToolAttemptLifecycle.resultPersisted ||
            lifecycle == ToolAttemptLifecycle.completed
        ? at.add(const Duration(milliseconds: 500))
        : null,
    executionOutcomeKnown: outcomeKnown,
  );
}

/// A storage seam backed by a map, mirroring the encrypted store.
final class _FakeProtectedStorage implements MemoryTrustProtectedStorage {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

void main() {
  late InMemoryRunJournalStore store;
  late RunJournalService service;

  setUp(() {
    store = InMemoryRunJournalStore();
    service = RunJournalService(
      store: store,
      clock: () => DateTime.utc(2026, 9, 27, 12),
    );
  });

  test('records a run, its tool attempts and its terminal state', () async {
    await service.beginRun(runAttemptId: 'run-1', sessionId: 'session_1');
    await service.mirrorMarker(
      runAttemptId: 'run-1',
      sessionId: 'session_1',
      attempts: [_attempt('op-1')],
    );
    final ended = await service.endRun(
      runAttemptId: 'run-1',
      state: RunJournalState.completed,
      endReason: 'agent_turn_finished',
    );

    expect(ended, isNotNull);
    expect(ended!.state, RunJournalState.completed);
    expect(ended.endReason, 'agent_turn_finished');
    expect(ended.toolAttempts.single.toolName, 'read_file');
    expect(ended.toolAttempts.single.resultPersisted, isTrue);

    final runs = await service.recentRuns();
    expect(runs, hasLength(1));
    expect(runs.single.runAttemptId, 'run-1');
  });

  test('a completion without a proven outcome becomes unknown_outcome',
      () async {
    await service.beginRun(runAttemptId: 'run-1', sessionId: 'session_1');
    await service.mirrorMarker(
      runAttemptId: 'run-1',
      sessionId: 'session_1',
      attempts: [
        _attempt(
          'op-1',
          lifecycle: ToolAttemptLifecycle.started,
          outcomeKnown: false,
        ),
      ],
    );
    final ended = await service.endRun(
      runAttemptId: 'run-1',
      state: RunJournalState.completed,
    );

    expect(ended!.state, RunJournalState.unknownOutcome);
    expect(ended.requiresConfirmation, isTrue);
    expect(ended.hasUnknownOutcome, isTrue);
  });

  test('a cancellation with an in-flight attempt is never a clean cancel',
      () async {
    await service.beginRun(runAttemptId: 'run-1', sessionId: 'session_1');
    await service.mirrorMarker(
      runAttemptId: 'run-1',
      sessionId: 'session_1',
      attempts: [
        _attempt(
          'op-1',
          lifecycle: ToolAttemptLifecycle.started,
          outcomeKnown: false,
        ),
      ],
    );
    final cancelled = await service.endRun(
      runAttemptId: 'run-1',
      state: RunJournalState.cancelled,
      endReason: 'user_cancelled',
    );
    expect(cancelled!.state, RunJournalState.unknownOutcome);
    expect(cancelled.endReason, 'user_cancelled');

    // A cancellation whose attempts are all proven keeps the cancelled state.
    await service.beginRun(runAttemptId: 'run-2', sessionId: 'session_1');
    await service.mirrorMarker(
      runAttemptId: 'run-2',
      sessionId: 'session_1',
      attempts: [
        _attempt('op-2', lifecycle: ToolAttemptLifecycle.failed),
      ],
    );
    final cleanCancel = await service.endRun(
      runAttemptId: 'run-2',
      state: RunJournalState.cancelled,
      endReason: 'user_cancelled',
    );
    expect(cleanCancel!.state, RunJournalState.cancelled);
  });

  test('a late end call never reopens a terminal entry', () async {
    await service.beginRun(runAttemptId: 'run-1', sessionId: 'session_1');
    await service.endRun(
      runAttemptId: 'run-1',
      state: RunJournalState.cancelled,
    );
    final late = await service.endRun(
      runAttemptId: 'run-1',
      state: RunJournalState.completed,
    );
    expect(late!.state, RunJournalState.cancelled);
  });

  test('the journal is bounded and keeps the newest runs', () async {
    for (var index = 0; index < maxRunJournalEntries + 5; index++) {
      await service.beginRun(
        runAttemptId: 'run-$index',
        sessionId: 'session_1',
        now: DateTime.utc(2026, 9, 27, 12).add(Duration(minutes: index)),
      );
    }
    final runs = await service.recentRuns();
    expect(runs, hasLength(maxRunJournalEntries));
    expect(runs.first.runAttemptId, 'run-${maxRunJournalEntries + 4}');
    expect(
      runs.map((run) => run.runAttemptId).contains('run-0'),
      isFalse,
    );
  });

  test('reconcileAtStartup marks dead runs interrupted without executing',
      () async {
    await service.beginRun(runAttemptId: 'run-dead', sessionId: 'session_1');
    await service.mirrorMarker(
      runAttemptId: 'run-dead',
      sessionId: 'session_1',
      attempts: [
        _attempt(
          'op-1',
          lifecycle: ToolAttemptLifecycle.started,
          outcomeKnown: false,
        ),
      ],
    );
    await service.beginRun(runAttemptId: 'run-live', sessionId: 'session_2');

    await service.reconcileAtStartup(liveRunAttemptIds: const ['run-live']);

    final dead = (await service.recentRuns())
        .firstWhere((run) => run.runAttemptId == 'run-dead');
    expect(dead.state, RunJournalState.interrupted);
    expect(dead.endReason, 'process_death');
    expect(dead.toolAttempts.single.state, RunJournalToolState.interrupted);
    expect(dead.toolAttempts.single.outcomeKnown, isFalse);

    final live = (await service.recentRuns())
        .firstWhere((run) => run.runAttemptId == 'run-live');
    expect(live.state, RunJournalState.running);
    expect(await service.pendingRunForSession('session_1'), isNotNull);
  });

  test('a corrupt store fails closed but still accepts new runs', () async {
    await store.write('{"schemaVersion":9,"runs":"nope"}');
    expect(await service.recentRuns(), isEmpty);
    expect(service.readFailed, isTrue);

    await service.beginRun(runAttemptId: 'run-1', sessionId: 'session_1');
    final runs = await service.recentRuns();
    expect(runs, hasLength(1));
    expect(runs.single.runAttemptId, 'run-1');
    expect(service.readFailed, isFalse);
  });

  test('the encrypted store rejects a tampered payload', () async {
    final storage = _FakeProtectedStorage();
    final encrypted = SecureRunJournalStore(storage: storage);
    final encryptedService = RunJournalService(store: encrypted);
    await encryptedService.beginRun(
      runAttemptId: 'run-1',
      sessionId: 'session_1',
    );
    expect(await encryptedService.recentRuns(), hasLength(1));

    final envelope = jsonDecode(
      storage.values[SecureRunJournalStore.storageKey]!,
    ) as Map<String, dynamic>;
    final runs = (envelope['runs'] as List).cast<Map<String, dynamic>>();
    runs.first['state'] = 'completed';
    storage.values[SecureRunJournalStore.storageKey] =
        jsonEncode({...envelope, 'runs': runs});

    final fresh = RunJournalService(store: encrypted);
    expect(await fresh.recentRuns(), isEmpty);
    expect(fresh.readFailed, isTrue);
  });

  test('the journal payload only ever holds the allowlisted fields', () async {
    await service.beginRun(runAttemptId: 'run-1', sessionId: 'session_1');
    await service.mirrorMarker(
      runAttemptId: 'run-1',
      sessionId: 'session_1',
      attempts: [_attempt('op-1', toolName: 'phone_read')],
    );
    final payload = jsonDecode(store.content!) as Map<String, dynamic>;
    final runs = payload['runs'] as List;
    final runJson = runs.single as Map<String, dynamic>;

    expect(
      runJson.keys.toSet(),
      {
        'schemaVersion',
        'runAttemptId',
        'sessionId',
        'startedAt',
        'state',
        'toolAttempts',
      },
    );
    final attemptJson =
        (runJson['toolAttempts'] as List).single as Map<String, dynamic>;
    expect(
      attemptJson.keys.toSet(),
      {
        'operationId',
        'toolName',
        'risk',
        'state',
        'proposedAt',
        'updatedAt',
        'startedAt',
      },
    );
    // No argument, result, prompt, or receipt content anywhere in the payload.
    final rendered = store.content!;
    for (final forbidden in const [
      'arguments',
      'result',
      'content',
      'prompt',
      'apiKey',
      'token',
    ]) {
      expect(rendered.contains(forbidden), isFalse, reason: forbidden);
    }
  });

  test('clear empties the journal', () async {
    await service.beginRun(runAttemptId: 'run-1', sessionId: 'session_1');
    await service.clear();
    expect(await service.recentRuns(), isEmpty);
  });
}
