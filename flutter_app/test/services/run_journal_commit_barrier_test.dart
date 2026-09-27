import 'dart:async';
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
  ToolAttemptLifecycle lifecycle = ToolAttemptLifecycle.started,
  bool outcomeKnown = false,
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
    executionStartedAt: DateTime.utc(2026, 9, 27, 12, 0, 1),
    executionOutcomeKnown: outcomeKnown,
  );
}

/// A store that can block, fail, and record the order of its commits.
final class _ControllableStore implements RunJournalStore {
  String? content;
  final List<String> written = <String>[];
  final List<int> writtenRevisions = <int>[];
  int writeCalls = 0;

  /// When set, the next write waits for it before proceeding.
  Completer<void>? blockNextWrite;
  bool failNextWrite = false;

  /// When non-empty, reads consume these completers instead of the content.
  final List<Completer<String?>> readQueue = <Completer<String?>>[];

  @override
  Future<String?> read() async {
    if (readQueue.isNotEmpty) {
      return await readQueue.removeAt(0).future;
    }
    return content;
  }

  @override
  Future<void> write(String value) async {
    writeCalls++;
    final blocker = blockNextWrite;
    if (blocker != null) {
      blockNextWrite = null;
      await blocker.future;
    }
    if (failNextWrite) {
      failNextWrite = false;
      throw const FormatException('store_write_failed');
    }
    final revision = (jsonDecode(value) as Map)['revision'];
    if (revision is int && revision <= _lastCommittedRevision) {
      throw const FormatException('run_journal_stale_write');
    }
    if (revision is int) _lastCommittedRevision = revision;
    content = value;
    written.add(value);
    writtenRevisions.add(revision is int ? revision : -1);
  }

  int _lastCommittedRevision = 0;

  @override
  Future<void> clear() async {
    content = null;
    _lastCommittedRevision = 0;
  }
}

Map<String, dynamic> _runJson(String payload, int index) =>
    (jsonDecode(payload)['runs'] as List)[index] as Map<String, dynamic>;

void main() {
  late _ControllableStore store;
  late RunJournalService service;

  setUp(() {
    store = _ControllableStore();
    service = RunJournalService(
      store: store,
      clock: () => DateTime.utc(2026, 9, 27, 12),
    );
  });

  test('begin, tool transition and terminal commit in order', () async {
    await service.beginRun(runAttemptId: 'run-1', sessionId: 'session_1');
    await service.mirrorMarker(
      runAttemptId: 'run-1',
      sessionId: 'session_1',
      attempts: [_attempt('op-1')],
    );
    await service.endRun(
      runAttemptId: 'run-1',
      state: RunJournalState.completed,
    );

    // The barrier awaits each commit, so the store saw one payload per step.
    expect(store.written, hasLength(3));
    final first = _runJson(store.written[0], 0);
    expect(first['state'], 'running');
    expect(first['toolAttempts'], isEmpty);
    final second = _runJson(store.written[1], 0);
    expect(
      (second['toolAttempts'] as List).single['state'],
      'started',
    );
    final third = _runJson(store.written[2], 0);
    // The attempt never produced a result, so the terminal record cannot claim
    // a clean completion.
    expect(third['state'], 'unknown_outcome');
    expect(service.isRunIncomplete('run-1'), isFalse);
    expect(service.writeFailed, isFalse);
  });

  test('a hung store is bounded and marks the run incomplete', () async {
    final blocker = Completer<void>();
    store.blockNextWrite = blocker;
    final stopwatch = Stopwatch()..start();
    final entry = await service.beginRun(
      runAttemptId: 'run-1',
      sessionId: 'session_1',
    );
    stopwatch.stop();

    // The commit is bounded: the run is not blocked on a hung encrypted write.
    expect(stopwatch.elapsed,
        greaterThanOrEqualTo(RunJournalService.commitTimeout));
    expect(
      stopwatch.elapsed,
      lessThan(RunJournalService.commitTimeout + const Duration(seconds: 2)),
    );
    expect(entry, isNull);
    expect(service.isRunIncomplete('run-1'), isTrue);
    expect(service.writeFailed, isTrue);
    expect(store.written, isEmpty);

    // Let the wedged write finish; a later commit for another run lands and the
    // journal keeps working.
    blocker.complete();
    await Future<void>.delayed(Duration.zero);
    await service.beginRun(runAttemptId: 'run-2', sessionId: 'session_1');
    expect(service.isRunIncomplete('run-2'), isFalse);
    // run-1 stays flagged: its trajectory is not complete.
    expect(service.isRunIncomplete('run-1'), isTrue);
  });

  test('a failing store never pretends the record landed', () async {
    store.failNextWrite = true;
    await service.beginRun(runAttemptId: 'run-1', sessionId: 'session_1');
    expect(service.isRunIncomplete('run-1'), isTrue);
    expect(service.writeFailed, isTrue);
    expect(store.written, isEmpty);
    expect(await service.recentRuns(), isEmpty);

    // A later successful commit records the run; run-1 stays incomplete.
    await service.beginRun(runAttemptId: 'run-2', sessionId: 'session_1');
    expect(await service.recentRuns(), hasLength(1));
    expect(service.isRunIncomplete('run-2'), isFalse);
    expect(service.writeFailed, isTrue);
  });

  test('a process-restart window is reconciled to interrupted, never re-run',
      () async {
    await service.beginRun(runAttemptId: 'run-1', sessionId: 'session_1');
    await service.mirrorMarker(
      runAttemptId: 'run-1',
      sessionId: 'session_1',
      attempts: [_attempt('op-1')],
    );

    // A new process reads the same store: the run was still `running`.
    final restarted = RunJournalService(
      store: store,
      clock: () => DateTime.utc(2026, 9, 27, 13),
    );
    await restarted.reconcileAtStartup();

    final runs = await restarted.recentRuns();
    expect(runs, hasLength(1));
    expect(runs.single.state, RunJournalState.interrupted);
    expect(runs.single.endReason, 'process_death');
    expect(
        runs.single.toolAttempts.single.state, RunJournalToolState.interrupted);
    expect(runs.single.toolAttempts.single.outcomeKnown, isFalse);
    // The journal exposes no execute/resume API: recovery is display only.
    expect(await restarted.pendingRunForSession('session_1'), isNotNull);
  });

  test('the byte budget trims the oldest terminal runs', () async {
    // Each run carries 64 attempts with long-but-valid identifiers, so the
    // journal would exceed 96 KB long before the 24-run count bound.
    for (var run = 0; run < 12; run++) {
      final runId = 'run-${run.toString().padLeft(2, '0')}-${'a' * 60}';
      await service.beginRun(
        runAttemptId: runId,
        sessionId: 'session_1',
        now: DateTime.utc(2026, 9, 27, 12).add(Duration(minutes: run)),
      );
      final attempts = <ToolAttemptRecoveryMetadata>[];
      for (var op = 0; op < maxRunJournalAttemptsPerEntry; op++) {
        attempts.add(_attempt(
          'op-$run-${op.toString().padLeft(3, '0')}-${'b' * 50}',
          toolName: 'tool_${run}_${op}_${'c' * 40}',
        ));
      }
      await service.mirrorMarker(
        runAttemptId: runId,
        sessionId: 'session_1',
        attempts: attempts,
      );
      await service.endRun(
        runAttemptId: runId,
        state: RunJournalState.cancelled,
      );
    }

    final payload = store.content!;
    expect(utf8.encode(payload).length,
        lessThanOrEqualTo(maxRunJournalPayloadBytes));
    final stored =
        (jsonDecode(payload)['runs'] as List).cast<Map<String, dynamic>>();
    expect(stored.length, lessThan(maxRunJournalEntries));
    // The newest run survived the trim.
    expect(
      stored.map((run) => run['runAttemptId']),
      contains('run-11-${'a' * 60}'),
    );
    expect(service.writeFailed, isFalse);
  });

  test('the store refuses a payload over the hard byte budget', () async {
    final storage = _FakeProtectedStorage();
    final encrypted = SecureRunJournalStore(storage: storage);
    final runs = <Map<String, dynamic>>[];
    for (var index = 0; index < 6; index++) {
      final attempts = <Map<String, dynamic>>[];
      for (var op = 0; op < maxRunJournalAttemptsPerEntry; op++) {
        attempts.add(RunJournalToolAttempt.fromRecoveryMetadata(
          _attempt(
            'op-$index-${op.toString().padLeft(3, '0')}-${'d' * 60}',
            toolName: 'tool_${index}_${'e' * 60}',
          ),
          now: DateTime.utc(2026, 9, 27, 12),
        ).toJson());
      }
      runs.add(RunJournalEntry(
        runAttemptId: 'run-${index.toString().padLeft(2, '0')}',
        sessionId: 'session_1',
        startedAt: DateTime.utc(2026, 9, 27, 12),
        state: RunJournalState.running,
        toolAttempts: [
          for (final json in attempts) RunJournalToolAttempt.fromJson(json),
        ],
      ).toJson());
    }
    final oversized = jsonEncode({'schemaVersion': 1, 'runs': runs});
    expect(
        utf8.encode(oversized).length, greaterThan(maxRunJournalPayloadBytes));

    await expectLater(
      encrypted.write(oversized),
      throwsA(isA<FormatException>()),
    );
  });

  test('the writer tail keeps the real write order under a slow write',
      () async {
    final service = RunJournalService(
      store: store,
      clock: () => DateTime.utc(2026, 9, 27, 12),
      commitTimeout: const Duration(milliseconds: 150),
    );
    final blocker = Completer<void>();
    store.blockNextWrite = blocker;

    // Commit A starts and holds the writer; commit B queues behind it.
    final first = service.beginRun(
      runAttemptId: 'run-1',
      sessionId: 'session_1',
    );
    final second = service.beginRun(
      runAttemptId: 'run-2',
      sessionId: 'session_1',
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    // A's caller gave up (bounded barrier) but the queue did not overtake it.
    expect(await first, isNull);
    expect(store.written, isEmpty);
    expect(store.writtenRevisions, isEmpty);

    blocker.complete();
    // Both callers already returned (their bounded wait expired); drain the
    // writer queue to observe what actually lands.
    for (var attempt = 0;
        attempt < 100 && store.writtenRevisions.length < 2;
        attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(await second, isNull);
    // A really finished before B: revisions are strictly increasing and in
    // start order, so an older payload can never land after a newer one.
    expect(store.writtenRevisions, hasLength(2));
    expect(store.writtenRevisions[0], lessThan(store.writtenRevisions[1]));
    final finalPayload = jsonDecode(store.content!) as Map<String, dynamic>;
    expect(finalPayload['revision'], store.writtenRevisions[1]);
    expect((finalPayload['runs'] as List), hasLength(2));
  });

  test('a store rejects a stale revision that arrives late', () async {
    final realStore = InMemoryRunJournalStore();
    final first = RunJournalService(store: realStore);
    await first.beginRun(runAttemptId: 'run-1', sessionId: 'session_1');
    final afterFirst = realStore.content;

    final second = RunJournalService(store: realStore);
    await second.beginRun(runAttemptId: 'run-2', sessionId: 'session_1');
    final afterSecond = realStore.content;
    expect(afterSecond, isNot(afterFirst));

    // A delayed older payload (lower revision) is refused, not applied.
    await expectLater(
      realStore.write(afterFirst!),
      throwsA(isA<FormatException>()),
    );
    expect(realStore.content, afterSecond);
  });

  test('an incomplete run stays incomplete and can never complete cleanly',
      () async {
    store.failNextWrite = true;
    await service.beginRun(runAttemptId: 'run-1', sessionId: 'session_1');
    expect(service.isRunIncomplete('run-1'), isTrue);

    // A later successful commit for the SAME run does not erase the gap.
    await service.mirrorMarker(
      runAttemptId: 'run-1',
      sessionId: 'session_1',
      attempts: [_attempt('op-1')],
    );
    await service.mirrorMarker(
      runAttemptId: 'run-1',
      sessionId: 'session_1',
      attempts: [_attempt('op-2')],
    );
    expect(service.isRunIncomplete('run-1'), isTrue);

    final ended = await service.endRun(
      runAttemptId: 'run-1',
      state: RunJournalState.completed,
    );
    // The terminal record cannot claim a clean completion after a lost commit.
    expect(ended!.state, RunJournalState.unknownOutcome);
    expect(service.isRunIncomplete('run-1'), isTrue);
    expect(service.writeFailed, isTrue);

    // A different run starts clean.
    await service.beginRun(runAttemptId: 'run-2', sessionId: 'session_1');
    final clean = await service.endRun(
      runAttemptId: 'run-2',
      state: RunJournalState.completed,
    );
    expect(clean!.state, RunJournalState.completed);
    expect(service.isRunIncomplete('run-2'), isFalse);
    // run-1 still gaps the journal, so the global flag stays set.
    expect(service.writeFailed, isTrue);
  });

  test(
      'the service trims with the store envelope in mind and the real store '
      'accepts the result', () async {
    final storage = _FakeProtectedStorage();
    final encrypted = SecureRunJournalStore(storage: storage);
    final service = RunJournalService(store: encrypted);
    for (var run = 0; run < 12; run++) {
      final runId = 'run-${run.toString().padLeft(2, '0')}-${'a' * 60}';
      await service.beginRun(
        runAttemptId: runId,
        sessionId: 'session_1',
        now: DateTime.utc(2026, 9, 27, 12).add(Duration(minutes: run)),
      );
      await service.mirrorMarker(
        runAttemptId: runId,
        sessionId: 'session_1',
        attempts: [
          for (var op = 0; op < maxRunJournalAttemptsPerEntry; op++)
            _attempt(
              'op-$run-${op.toString().padLeft(3, '0')}-${'b' * 50}',
              toolName: 'tool_${run}_${op}_${'c' * 40}',
            ),
        ],
      );
      await service.endRun(
        runAttemptId: runId,
        state: RunJournalState.cancelled,
      );
    }

    // Every commit was accepted by the real encrypted store: the service's
    // trimming reserved room for the envelope instead of overshooting.
    expect(service.writeFailed, isFalse);
    expect(service.hasIncompleteRuns, isFalse);
    final envelope =
        utf8.encode(storage.values[SecureRunJournalStore.storageKey]!);
    expect(envelope.length, lessThanOrEqualTo(maxRunJournalPayloadBytes));

    // And the stored envelope still reads back through a fresh service.
    final reopened = RunJournalService(
        store: SecureRunJournalStore(
      storage: storage,
    ));
    final runs = await reopened.recentRuns();
    expect(runs, isNotEmpty);
    expect(reopened.writeFailed, isFalse);
  });

  test('a queued commit never starts its underlying write early', () async {
    final store = _ControllableStore();
    final service = RunJournalService(
      store: store,
      commitTimeout: const Duration(milliseconds: 200),
    );
    final blocker = Completer<void>();
    store.blockNextWrite = blocker;

    final first = service.beginRun(
      runAttemptId: 'run-1',
      sessionId: 'session_1',
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final second = service.beginRun(
      runAttemptId: 'run-2',
      sessionId: 'session_1',
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));

    // A's underlying write is still pending: B has not reached the store.
    expect(store.writeCalls, 1);
    expect(store.writtenRevisions, isEmpty);

    blocker.complete();
    for (var attempt = 0;
        attempt < 100 && store.writtenRevisions.length < 2;
        attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    // B only started after A's real write finished, in revision order.
    expect(store.writeCalls, 2);
    expect(store.writtenRevisions, hasLength(2));
    expect(store.writtenRevisions[0], lessThan(store.writtenRevisions[1]));
    // A's own commit completed once its storage did, and the final payload is
    // B's (the highest revision): nothing was overwritten out of order.
    expect(await first, isNotNull);
    expect(await second, isNotNull);
    final finalPayload = jsonDecode(store.content!) as Map<String, dynamic>;
    expect(finalPayload['revision'], store.writtenRevisions[1]);
    expect((finalPayload['runs'] as List), hasLength(2));
  });
}

final class _FakeProtectedStorage implements MemoryTrustProtectedStorage {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}
