import 'dart:convert';

import 'package:clawchat/models/chat_models.dart';
import 'package:clawchat/models/run_journal.dart';
import 'package:flutter_test/flutter_test.dart';

ToolAttemptRecoveryMetadata _attempt({
  String operationId = 'op-1',
  String toolName = 'read_file',
  RecoveryToolRisk risk = RecoveryToolRisk.safe,
  ToolAttemptLifecycle lifecycle = ToolAttemptLifecycle.resultPersisted,
  bool outcomeKnown = true,
  DateTime? executionStartedAt,
  DateTime? stamp,
}) {
  final at = stamp ?? DateTime.utc(2026, 9, 27, 12);
  return ToolAttemptRecoveryMetadata(
    operationId: operationId,
    toolName: toolName,
    risk: risk,
    lifecycle: lifecycle,
    proposedAt: at,
    updatedAt: at.add(const Duration(seconds: 1)),
    executionStartedAt: executionStartedAt,
    executionOutcomeKnown: outcomeKnown,
  );
}

void main() {
  const runId = '3f0b6b54-1111-4222-8333-abcdefabcdef';
  const sessionId = 'session_1';

  Map<String, dynamic> validEntryJson({List<Object?>? attempts}) => {
        'schemaVersion': 1,
        'runAttemptId': runId,
        'sessionId': sessionId,
        'startedAt': '2026-09-27T12:00:00.000Z',
        'endedAt': '2026-09-27T12:05:00.000Z',
        'state': 'completed',
        'endReason': 'user_cancelled',
        'toolAttempts': attempts ??
            [
              RunJournalToolAttempt.fromRecoveryMetadata(
                _attempt(),
                now: DateTime.utc(2026, 9, 27, 12),
              ).toJson(),
            ],
      };

  test('an entry round-trips through its strict JSON shape', () {
    final entry = RunJournalEntry.fromJson(validEntryJson());
    expect(entry.runAttemptId, runId);
    expect(entry.sessionId, sessionId);
    expect(entry.state, RunJournalState.completed);
    expect(entry.endReason, 'user_cancelled');
    expect(entry.toolAttempts, hasLength(1));
    expect(entry.toolAttempts.single.toolName, 'read_file');
    expect(entry.toolAttempts.single.risk, RecoveryToolRisk.safe);

    final reparsed = RunJournalEntry.fromJson(
      Map<String, dynamic>.from(jsonDecode(jsonEncode(entry.toJson())) as Map),
    );
    expect(reparsed.toJson(), entry.toJson());
  });

  test('an entry rejects malformed or widened JSON', () {
    final cases = <Map<String, dynamic>>[
      {
        ...validEntryJson(),
        'arguments': {'path': '/tmp/secret'}
      },
      {...validEntryJson()}..remove('sessionId'),
      {...validEntryJson(), 'schemaVersion': 2},
      {...validEntryJson(), 'runAttemptId': 'has space'},
      {...validEntryJson(), 'state': 'maybe'},
      {...validEntryJson(), 'endReason': 'user cancelled'},
      {...validEntryJson(), 'endReason': 'A' * 41},
      {...validEntryJson(), 'startedAt': 'not-a-time'},
      {...validEntryJson(), 'toolAttempts': 'not-a-list'},
      {
        ...validEntryJson(),
        'toolAttempts': List<Object?>.filled(
          maxRunJournalAttemptsPerEntry + 1,
          RunJournalToolAttempt.fromRecoveryMetadata(
            _attempt(),
            now: DateTime.utc(2026, 9, 27, 12),
          ).toJson(),
        ),
      },
      {
        ...validEntryJson(),
        'toolAttempts': [
          RunJournalToolAttempt.fromRecoveryMetadata(
            _attempt(),
            now: DateTime.utc(2026, 9, 27, 12),
          ).toJson(),
          RunJournalToolAttempt.fromRecoveryMetadata(
            _attempt(),
            now: DateTime.utc(2026, 9, 27, 12),
          ).toJson(),
        ],
      },
    ];
    for (final json in cases) {
      expect(
        RunJournalEntry.isSanitizedJson(json),
        isFalse,
        reason: json.keys.join(','),
      );
      expect(
        () => RunJournalEntry.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    }
  });

  test('a tool attempt rejects widened or unsafe JSON', () {
    final valid = RunJournalToolAttempt.fromRecoveryMetadata(
      _attempt(),
      now: DateTime.utc(2026, 9, 27, 12),
    ).toJson();
    final cases = <Map<String, dynamic>>[
      {...valid, 'arguments': 'secret'},
      {...valid, 'result': 'secret'},
      valid..remove('toolName'),
      {...valid, 'toolName': 'bad tool name'},
      {...valid, 'risk': 'harmless'},
      {...valid, 'state': 'running'},
      {...valid, 'proposedAt': 12},
      {...valid, 'outcomeKnown': 'yes'},
    ];
    for (final json in cases) {
      expect(RunJournalToolAttempt.isSanitizedJson(json), isFalse);
      expect(
        () => RunJournalToolAttempt.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    }
  });

  test('recovery metadata maps onto the journal states', () {
    final cases = {
      ToolAttemptLifecycle.proposed: RunJournalToolState.proposed,
      ToolAttemptLifecycle.approvalPending: RunJournalToolState.approvalPending,
      ToolAttemptLifecycle.approvedNotStarted: RunJournalToolState.approved,
      ToolAttemptLifecycle.started: RunJournalToolState.started,
      ToolAttemptLifecycle.completed: RunJournalToolState.completed,
      ToolAttemptLifecycle.failed: RunJournalToolState.failed,
      ToolAttemptLifecycle.resultPersisted: RunJournalToolState.persisted,
      ToolAttemptLifecycle.interruptedUnknown: RunJournalToolState.interrupted,
    };
    for (final entry in cases.entries) {
      final mapped = RunJournalToolAttempt.fromRecoveryMetadata(
        _attempt(
          lifecycle: entry.key,
          outcomeKnown: entry.key != ToolAttemptLifecycle.interruptedUnknown,
          executionStartedAt: entry.key == ToolAttemptLifecycle.started
              ? DateTime.utc(2026, 9, 27, 12, 0, 30)
              : null,
        ),
        now: DateTime.utc(2026, 9, 27, 12),
      );
      expect(mapped.state, entry.value, reason: entry.key.name);
    }

    final started = RunJournalToolAttempt.fromRecoveryMetadata(
      _attempt(
        lifecycle: ToolAttemptLifecycle.started,
        executionStartedAt: DateTime.utc(2026, 9, 27, 12, 0, 30),
      ),
      now: DateTime.utc(2026, 9, 27, 12),
    );
    expect(started.hasUnknownOutcome, isTrue);
    expect(started.resultPersisted, isFalse);

    final persisted = RunJournalToolAttempt.fromRecoveryMetadata(
      _attempt(),
      now: DateTime.utc(2026, 9, 27, 12),
    );
    expect(persisted.resultPersisted, isTrue);
    expect(persisted.hasUnknownOutcome, isFalse);
  });

  test('withAttempts upserts by operationId and stays bounded', () {
    final entry = RunJournalEntry(
      runAttemptId: runId,
      sessionId: sessionId,
      startedAt: DateTime.utc(2026, 9, 27, 12),
      state: RunJournalState.running,
    );
    final attempts = <RunJournalToolAttempt>[];
    for (var index = 0; index < maxRunJournalAttemptsPerEntry + 6; index++) {
      attempts.add(RunJournalToolAttempt.fromRecoveryMetadata(
        _attempt(
          operationId: 'op-$index',
          stamp: DateTime.utc(2026, 9, 27, 12).add(Duration(minutes: index)),
        ),
        now: DateTime.utc(2026, 9, 27, 12),
      ));
    }
    final merged = entry.withAttempts(attempts);
    expect(
      merged.toolAttempts,
      hasLength(maxRunJournalAttemptsPerEntry),
    );
    // Newest kept, oldest pruned.
    expect(merged.toolAttempts.first.operationId, 'op-6');
    expect(merged.toolAttempts.last.operationId,
        'op-${maxRunJournalAttemptsPerEntry + 5}');

    // Upserting the same operationId replaces instead of duplicating.
    final updated = merged.withAttempts([
      RunJournalToolAttempt.fromRecoveryMetadata(
        _attempt(
          operationId: 'op-6',
          lifecycle: ToolAttemptLifecycle.interruptedUnknown,
          outcomeKnown: false,
        ),
        now: DateTime.utc(2026, 9, 27, 12),
      ),
    ]);
    expect(
      updated.toolAttempts.where((attempt) => attempt.operationId == 'op-6'),
      hasLength(1),
    );
    expect(updated.hasUnknownOutcome, isTrue);
  });

  test('markInterrupted turns running/started records into unknown outcomes',
      () {
    final entry = RunJournalEntry(
      runAttemptId: runId,
      sessionId: sessionId,
      startedAt: DateTime.utc(2026, 9, 27, 12),
      state: RunJournalState.running,
      toolAttempts: [
        RunJournalToolAttempt.fromRecoveryMetadata(
          _attempt(
            lifecycle: ToolAttemptLifecycle.started,
            executionStartedAt: DateTime.utc(2026, 9, 27, 12, 0, 30),
          ),
          now: DateTime.utc(2026, 9, 27, 12),
        ),
        RunJournalToolAttempt.fromRecoveryMetadata(
          _attempt(operationId: 'op-2'),
          now: DateTime.utc(2026, 9, 27, 12),
        ),
      ],
    );
    final interrupted = entry.markInterrupted(DateTime.utc(2026, 9, 27, 13));
    expect(interrupted.state, RunJournalState.interrupted);
    expect(interrupted.endReason, 'process_death');
    expect(interrupted.endedAt, DateTime.utc(2026, 9, 27, 13));
    expect(interrupted.requiresConfirmation, isTrue);
    expect(
        interrupted.toolAttempts.first.state, RunJournalToolState.interrupted);
    expect(interrupted.toolAttempts.first.outcomeKnown, isFalse);
    // The already persisted attempt is untouched.
    expect(interrupted.toolAttempts.last.state, RunJournalToolState.persisted);
  });
}
