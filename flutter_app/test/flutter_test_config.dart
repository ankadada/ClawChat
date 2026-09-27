import 'dart:async';

import 'package:clawchat/services/run_journal_service.dart';
import 'package:clawchat/services/run_journal_store.dart';

/// Every Flutter test runs with an in-memory run journal by default.
///
/// The production journal is the encrypted platform store; widget tests run
/// under a fake async clock, and a lifecycle commit barrier that waits on a
/// real platform round trip can deadlock that clock. Tests that want to
/// exercise journal storage construct their own service with their own store;
/// this only replaces the shared default.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  RunJournalService.instance = RunJournalService(
    store: InMemoryRunJournalStore(),
    // Widget tests run under a fake clock. A commit that cannot complete before
    // the (bounded) barrier fires is recorded as incomplete, exactly like a slow
    // production store - the UI never waits longer than the barrier.
    commitTimeout: const Duration(milliseconds: 50),
  );
  await testMain();
}
