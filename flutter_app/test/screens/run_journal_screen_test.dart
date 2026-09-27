import 'dart:async';
import 'dart:convert';

import 'package:clawchat/l10n/app_strings.dart';
import 'package:clawchat/models/run_journal.dart';
import 'package:clawchat/services/run_journal_store.dart';
import 'package:clawchat/models/chat_models.dart';
import 'package:clawchat/screens/run_journal_screen.dart';
import 'package:clawchat/services/run_journal_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows interrupted runs, their attempts, and clears on demand',
      (tester) async {
    final store = InMemoryRunJournalStore();
    final service = RunJournalService(
      store: store,
      clock: () => DateTime.utc(2026, 9, 27, 12),
    );
    await service.beginRun(runAttemptId: 'run-1', sessionId: 'session_1');
    await service.mirrorMarker(
      runAttemptId: 'run-1',
      sessionId: 'session_1',
      attempts: [
        ToolAttemptRecoveryMetadata(
          operationId: 'op-1',
          toolName: 'phone_read',
          risk: RecoveryToolRisk.moderate,
          lifecycle: ToolAttemptLifecycle.started,
          proposedAt: DateTime.utc(2026, 9, 27, 12),
          updatedAt: DateTime.utc(2026, 9, 27, 12, 0, 1),
          executionStartedAt: DateTime.utc(2026, 9, 27, 12, 0, 1),
          executionOutcomeKnown: false,
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(home: RunJournalScreen(service: service)),
    );
    await tester.pumpAndSettle();

    // A live run shows as running before the process-death reconcile.
    expect(find.text('运行中'), findsOneWidget);

    await service.reconcileAtStartup();
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();

    expect(find.text('已中断'), findsOneWidget);
    expect(find.textContaining('phone_read'), findsNothing);

    await tester.tap(find.text('已中断'));
    await tester.pumpAndSettle();
    expect(find.text('phone_read'), findsOneWidget);
    expect(find.textContaining('中断（结果未知）'), findsOneWidget);
    expect(find.textContaining('结果未确认：不会自动重跑'), findsOneWidget);

    // Clearing is behind a confirmation and never touches a run.
    await tester.tap(find.byIcon(Icons.delete_sweep_outlined));
    await tester.pumpAndSettle();
    expect(find.text(AppStrings.runJournalClearConfirm), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, AppStrings.confirm));
    await tester.pumpAndSettle();

    expect(find.text(AppStrings.runJournalEmpty), findsOneWidget);
    expect(await service.recentRuns(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a disposed screen never writes back a late journal read',
      (tester) async {
    final store = _PendingStore();
    final service = RunJournalService(store: store);
    final pending = Completer<String?>();
    store.readQueue.add(pending);

    await tester.pumpWidget(
      MaterialApp(home: RunJournalScreen(service: service)),
    );
    await tester.pump();

    // The read is still in flight when the route goes away.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    pending.complete(_journalPayload(state: RunJournalState.interrupted));
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a stale read never overwrites a newer reload', (tester) async {
    final store = _PendingStore();
    final service = RunJournalService(store: store);
    final first = Completer<String?>();
    final second = Completer<String?>();
    store.readQueue
      ..add(first)
      ..add(second);

    await tester.pumpWidget(
      MaterialApp(home: RunJournalScreen(service: service)),
    );
    await tester.pump();
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();

    // The newest reload resolves first, then the stale one completes late.
    second.complete(_journalPayload(state: RunJournalState.interrupted));
    await tester.pumpAndSettle();
    expect(find.text('已中断'), findsOneWidget);

    first.complete(_journalPayload(state: RunJournalState.running));
    await tester.pumpAndSettle();
    expect(find.text('已中断'), findsOneWidget);
    expect(find.text('运行中'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed journal commit is visible instead of silently assumed',
      (tester) async {
    final store = _PendingStore()..failWrites = true;
    final service = RunJournalService(store: store);
    await service.beginRun(runAttemptId: 'run-1', sessionId: 'session_1');
    expect(service.writeFailed, isTrue);

    await tester.pumpWidget(
      MaterialApp(home: RunJournalScreen(service: service)),
    );
    await tester.pumpAndSettle();

    expect(find.text(AppStrings.runJournalIncomplete), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

String _journalPayload({required RunJournalState state}) => jsonEncode({
      'schemaVersion': 1,
      'runs': [
        RunJournalEntry(
          runAttemptId: 'run-1',
          sessionId: 'session_1',
          startedAt: DateTime.utc(2026, 9, 27, 12),
          state: state,
        ).toJson(),
      ],
    });

/// A store whose reads can be held open and whose writes can fail.
final class _PendingStore implements RunJournalStore {
  String? content;
  final List<Completer<String?>> readQueue = <Completer<String?>>[];
  bool failWrites = false;

  @override
  Future<String?> read() async {
    if (readQueue.isNotEmpty) {
      return await readQueue.removeAt(0).future;
    }
    return content;
  }

  @override
  Future<void> write(String value) async {
    if (failWrites) throw const FormatException('store_write_failed');
    content = value;
  }

  @override
  Future<void> clear() async {
    content = null;
  }
}
