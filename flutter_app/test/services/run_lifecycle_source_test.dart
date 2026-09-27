import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins the v2.17 run-journal contract at the source level: the journal is
/// display-only, startup never resumes a run, and boot never starts the agent.
void main() {
  final root = _flutterRoot();
  String read(String relativePath) =>
      File('${root.path}/$relativePath').readAsStringSync();

  late String journalService;
  late String journalModel;
  late String chatProvider;

  setUp(() {
    journalService = read('lib/services/run_journal_service.dart');
    journalModel = read('lib/models/run_journal.dart');
    chatProvider = read('lib/providers/chat_provider.dart');
  });

  test('the journal has no execution, retry, or resume API', () {
    for (final forbidden in const [
      'ToolRegistry',
      'AgentService',
      'LlmService',
      'executeTool',
      'dispatchTool',
      'retryRun',
      'resumeRun',
      'continueInterruptedAgentRun',
      'startAgentService',
    ]) {
      expect(journalService.contains(forbidden), isFalse, reason: forbidden);
      expect(journalModel.contains(forbidden), isFalse, reason: forbidden);
    }
    // The model exposes only redacted fields: no argument/result/prompt keys.
    for (final forbidden in const [
      "'arguments'",
      "'result'",
      "'content'",
      "'prompt'",
      "'receipt'",
      'apiKey',
    ]) {
      expect(journalModel.contains(forbidden), isFalse, reason: forbidden);
    }
  });

  test('the chat provider mirrors run lifecycle into the journal', () {
    expect(chatProvider,
        contains('_journalBeginRun(activeSession, replacementMarker)'));
    expect(chatProvider, contains('_journalMirrorMarker(session)'));
    expect(chatProvider, contains('_journalEndRun('));
    expect(chatProvider, contains('reconcileAtStartup('));
    // Terminal mapping: cancelled / failed / completed all end the entry, and
    // the service downgrades unproven outcomes to unknown_outcome.
    expect(chatProvider, contains('RunJournalState.cancelled'));
    expect(chatProvider, contains('RunJournalState.failed'));
    expect(chatProvider, contains('RunJournalState.completed'));
    expect(chatProvider, contains('RunJournalState.interrupted'));
  });

  test('startup reconciles the journal but never resumes a run', () {
    final initStart = chatProvider.indexOf('Future<void> _init() async {');
    expect(initStart, greaterThanOrEqualTo(0));
    final initEnd = chatProvider.indexOf('\n  Future<', initStart + 1);
    final initBody = chatProvider.substring(
      initStart,
      initEnd > initStart ? initEnd : chatProvider.length,
    );
    expect(initBody, contains('reconcileAtStartup('));
    for (final forbidden in const [
      'continueInterruptedAgentRun',
      '_sendMessage(',
      '_sendRemoteAgentMessage(',
    ]) {
      expect(initBody.contains(forbidden), isFalse, reason: forbidden);
    }
  });

  test('every terminal path commits the journal before dropping the marker',
      () {
    // Positive terminal helper.
    final positiveStart = chatProvider.indexOf(
      'Future<void> _clearRecoveryMarkerAfterOwnedPositiveTerminal(',
    );
    expect(positiveStart, greaterThan(0));
    final positive = chatProvider.substring(positiveStart, positiveStart + 900);
    expect(
      positive.indexOf('_journalEndRun('),
      lessThan(positive.indexOf('session.inFlightAgentRun = null;')),
      reason: positive,
    );

    // Cancellation helper.
    final cancelStart = chatProvider.indexOf(
      'Future<void> _clearInFlightAgentRunAwaited(',
    );
    expect(cancelStart, greaterThan(0));
    final cancel = chatProvider.substring(cancelStart, cancelStart + 900);
    expect(
      cancel.indexOf('_journalEndRun('),
      lessThan(cancel.indexOf('session!.inFlightAgentRun = null;')),
      reason: cancel,
    );

    // In-loop cancellation branch.
    final inLoopClear = chatProvider.indexOf(
      'activeSession.inFlightAgentRun = null;',
      chatProvider.indexOf('} else if (state.wasCancelled) {'),
    );
    expect(inLoopClear, greaterThan(0));
    final inLoop = chatProvider.substring(inLoopClear - 900, inLoopClear);
    expect(inLoop, contains('_journalEndRun('));

    // Failure terminals commit before the failure marker (and its marker drop).
    for (final source in const ['agent_run_failed', 'provider_exception']) {
      final marker = chatProvider.indexOf("endReason: '$source'");
      expect(marker, greaterThan(0), reason: source);
      final before = chatProvider.substring(marker, marker + 900);
      expect(before, contains('_persistAssistantFailureMarker('),
          reason: source);
    }

    // The model fallback success path goes through the positive helper, so it
    // inherits the same commit-then-clear ordering.
    final fallbackSuccess = chatProvider.indexOf('_appendModelFallbackNotice(');
    expect(fallbackSuccess, greaterThan(0));
    final fallback =
        chatProvider.substring(fallbackSuccess, fallbackSuccess + 900);
    expect(
      fallback,
      contains('_clearRecoveryMarkerAfterOwnedPositiveTerminal('),
    );

    // The streaming completion path routes through the same helper.
    final streamComplete = chatProvider.indexOf('_completePositiveTerminal(');
    expect(streamComplete, greaterThan(0));
  });

  test('the terminal path stops the foreground service and writes the journal',
      () {
    final terminal = chatProvider.indexOf('_finishRunToken(token);');
    expect(terminal, greaterThan(0));
    final window = chatProvider.substring(
      terminal - 1600 < 0 ? 0 : terminal - 1600,
      terminal + 200 > chatProvider.length
          ? chatProvider.length
          : terminal + 200,
    );
    // The terminal hook commits the journal (or finalizes the positive terminal
    // through the commit-then-clear helper) before publishing the end state.
    expect(window, contains('_journalEndRun('));
    expect(window, contains('_completePositiveTerminal('));
    // The foreground service is stopped on the terminal and cancellation
    // paths, not only when the app is backgrounded.
    expect(chatProvider,
        contains('_stopAgentServiceForState(state, runToken: runToken)'));
    expect(
        chatProvider,
        contains(
            '_stopAgentServiceForState(state, runToken: runToken).timeout('));
    expect(chatProvider, contains('_finishRunToken(runToken)'));
  });

  test('boot only runs cleanup, never the agent service or a model', () {
    final manifest = read('android/app/src/main/AndroidManifest.xml');
    expect(manifest, contains('android.permission.RECEIVE_BOOT_COMPLETED'));
    expect(manifest, contains('.CommandCleanupJobService'));

    final coordinator = read(
        'android/app/src/main/kotlin/com/anka/clawbot/CommandCleanupCoordinator.kt');
    final jobStart =
        coordinator.indexOf('class CommandCleanupJobService : JobService()');
    expect(jobStart, greaterThan(0));
    final jobBody = coordinator.substring(jobStart);
    expect(jobBody, contains('reconcile()'));
    for (final forbidden in const [
      'AgentTaskService',
      'reserveAgentCommand',
      'startReservedCommand',
      'Assistant',
      'Llm',
    ]) {
      expect(jobBody.contains(forbidden), isFalse, reason: forbidden);
    }

    final agentService = read(
        'android/app/src/main/kotlin/com/anka/clawbot/AgentTaskService.kt');
    for (final forbidden in const ['BOOT_COMPLETED', 'onReceive']) {
      expect(agentService.contains(forbidden), isFalse, reason: forbidden);
    }
  });
}

Directory _flutterRoot() {
  final current = Directory.current;
  if (File('${current.path}/pubspec.yaml').existsSync()) return current;
  final nested = Directory('${current.path}/flutter_app');
  if (File('${nested.path}/pubspec.yaml').existsSync()) return nested;
  return current;
}
