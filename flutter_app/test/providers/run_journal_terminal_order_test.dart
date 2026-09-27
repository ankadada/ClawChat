import 'dart:async';
import 'dart:convert';

import 'package:clawchat/models/chat_models.dart';
import 'package:clawchat/models/provider_profile.dart';
import 'package:clawchat/providers/chat_provider.dart';
import 'package:clawchat/services/llm_service.dart';
import 'package:clawchat/services/preferences_service.dart';
import 'package:clawchat/services/run_journal_service.dart';
import 'package:clawchat/services/run_journal_store.dart';
import 'package:clawchat/services/session_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Terminal ordering: the journal must commit the run's terminal state before
/// the recovery marker is dropped or the terminal state is published, on every
/// exit path (completion, model error, cancellation, dismissal, truncation).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _OrderLog log;
  late _OrderedSessionStorage storage;
  late _OrderedJournalStore journalStore;
  late RunJournalService journal;
  late ChatProvider provider;

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (call) async {
      switch (call.method) {
        case 'read':
          return null;
        case 'readAll':
          return <String, String>{};
        case 'containsKey':
          return false;
      }
      return null;
    });
    PreferencesService.resetForTesting();
    await PreferencesService().init();
    await PreferencesService().setProfiles([
      ProviderProfile.defaults(name: 'Primary').copyWith(
        id: 'primary',
        apiFormat: ProviderProfile.anthropicFormat,
        apiKey: 'sk-test',
        baseUrl: 'https://api.invalid',
        model: 'test-model',
      ),
    ]);
    await PreferencesService().setActiveProfileId('primary');
    log = _OrderLog();
    storage = _OrderedSessionStorage(log);
    journalStore = _OrderedJournalStore(log);
    journal = RunJournalService(store: journalStore);
    provider = ChatProvider(storage: storage, runJournal: journal);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });

  tearDown(() async {
    provider.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
    PreferencesService.resetForTesting();
  });

  int lastIndexWhere(bool Function(String event) predicate) {
    for (var index = log.events.length - 1; index >= 0; index--) {
      if (predicate(log.events[index])) return index;
    }
    return -1;
  }

  int journalIndex(String state) =>
      log.events.indexWhere((event) => event.endsWith('journal:$state'));
  int markerClearIndex() =>
      lastIndexWhere((event) => event.endsWith('marker-cleared'));

  /// The last terminal journal commit for one of [states] must precede the
  /// last recovery-marker clear.
  void expectTerminalBeforeMarkerClear(List<String> states) {
    final terminal =
        states.map(journalIndex).fold<int>(-1, (a, b) => a > b ? a : b);
    final cleared = markerClearIndex();
    expect(terminal, greaterThanOrEqualTo(0), reason: log.events.join(', '));
    expect(cleared, greaterThanOrEqualTo(0), reason: log.events.join(', '));
    expect(terminal, lessThan(cleared), reason: log.events.join(', '));
  }

  test('normal completion commits the terminal journal before the marker drop',
      () async {
    provider.dispose();
    provider = ChatProvider(
      storage: storage,
      runJournal: journal,
      llmServiceFactory: (config, {isInBackground}) =>
          _ImmediateLlmService(config),
    );
    final session = await provider.createSession();
    await provider.sendMessage('hello');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(session.id, isNotEmpty);

    expectTerminalBeforeMarkerClear(const ['completed']);
  });

  test('a provider error commits the terminal journal before the marker drop',
      () async {
    provider.dispose();
    provider = ChatProvider(
      storage: storage,
      runJournal: journal,
      llmServiceFactory: (config, {isInBackground}) =>
          _ThrowingLlmService(config),
    );
    await provider.createSession();
    await provider.sendMessage('hello');
    await Future<void>.delayed(const Duration(milliseconds: 300));

    // No tool attempt ever started, so the failure is proven: `failed` (or the
    // unknown-outcome downgrade) must both land before the marker clear.
    expectTerminalBeforeMarkerClear(const ['failed', 'unknown_outcome']);
  });

  test('cancellation commits the terminal journal before the marker drop',
      () async {
    final started = Completer<void>();
    final release = Completer<void>();
    provider.dispose();
    provider = ChatProvider(
      storage: storage,
      runJournal: journal,
      llmServiceFactory: (config, {isInBackground}) =>
          _BlockingLlmService(config, started: started, release: release),
    );
    final session = await provider.createSession();
    unawaited(provider.sendMessage('hello'));
    for (var attempt = 0; attempt < 200 && !started.isCompleted; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(started.isCompleted, isTrue);

    await provider.cancelAgent(sessionId: session.id);
    release.complete();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expectTerminalBeforeMarkerClear(
      const ['cancelled', 'unknown_outcome'],
    );
  });

  test('dismissing an interrupted run commits before dropping the marker',
      () async {
    final interrupted = ChatSession(
      id: 'run_order_dismiss',
      title: 'Interrupted run',
      messages: [ChatMessage.user('previous run')],
      inFlightAgentRun: AgentRunRecoveryMarker(
        runAttemptId: 'run-interrupted',
        startedAt: DateTime.utc(2026, 9, 27, 12),
        updatedAt: DateTime.utc(2026, 9, 27, 12),
      ),
    );
    storage.seed(interrupted);
    await journal.beginRun(
      runAttemptId: 'run-interrupted',
      sessionId: interrupted.id,
    );
    await provider.selectSession(interrupted.id);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await provider.dismissInterruptedAgentRun();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expectTerminalBeforeMarkerClear(const ['interrupted']);
  });

  test('deleting from a message commits before dropping the marker', () async {
    final truncated = ChatSession(
      id: 'run_order_delete',
      title: 'Truncated run',
      messages: [ChatMessage.user('one'), ChatMessage.user('two')],
      inFlightAgentRun: AgentRunRecoveryMarker(
        runAttemptId: 'run-truncated',
        startedAt: DateTime.utc(2026, 9, 27, 12),
        updatedAt: DateTime.utc(2026, 9, 27, 12),
      ),
    );
    storage.seed(truncated);
    await journal.beginRun(
      runAttemptId: 'run-truncated',
      sessionId: truncated.id,
    );
    await provider.selectSession(truncated.id);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(await provider.deleteMessagesFrom(0), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expectTerminalBeforeMarkerClear(const ['interrupted']);
  });

  test('a delayed journal write keeps the marker until the commit lands',
      () async {
    final interrupted = ChatSession(
      id: 'run_order_delay',
      title: 'Interrupted run',
      messages: [ChatMessage.user('previous run')],
      inFlightAgentRun: AgentRunRecoveryMarker(
        runAttemptId: 'run-delay',
        startedAt: DateTime.utc(2026, 9, 27, 12),
        updatedAt: DateTime.utc(2026, 9, 27, 12),
      ),
    );
    storage.seed(interrupted);
    await journal.beginRun(
      runAttemptId: 'run-delay',
      sessionId: interrupted.id,
    );
    await provider.selectSession(interrupted.id);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final blocker = Completer<void>();
    journalStore.blockNextWrite = blocker;
    final dismiss = provider.dismissInterruptedAgentRun();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    // The journal commit has not landed: the marker is still there and no
    // save cleared it.
    expect(provider.currentSession?.inFlightAgentRun, isNotNull);
    expect(markerClearIndex(), -1, reason: log.events.join(', '));
    expect(journalIndex('interrupted'), -1, reason: log.events.join(', '));

    blocker.complete();
    await dismiss;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(provider.currentSession?.inFlightAgentRun, isNull);
    expectTerminalBeforeMarkerClear(const ['interrupted']);
  });

  test('a journal timeout is recorded before the marker is cleared', () async {
    final timedOutJournal = RunJournalService(
      store: journalStore,
      commitTimeout: const Duration(milliseconds: 40),
    );
    provider.dispose();
    provider = ChatProvider(storage: storage, runJournal: timedOutJournal);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final interrupted = ChatSession(
      id: 'run_order_timeout',
      title: 'Interrupted run',
      messages: [ChatMessage.user('previous run')],
      inFlightAgentRun: AgentRunRecoveryMarker(
        runAttemptId: 'run-timeout',
        startedAt: DateTime.utc(2026, 9, 27, 12),
        updatedAt: DateTime.utc(2026, 9, 27, 12),
      ),
    );
    storage.seed(interrupted);
    await timedOutJournal.beginRun(
      runAttemptId: 'run-timeout',
      sessionId: interrupted.id,
    );
    await provider.selectSession(interrupted.id);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // The journal write never lands: the bounded barrier expires, the failure
    // is recorded, and only then is the marker allowed to clear.
    journalStore.blockNextWrite = Completer<void>();
    await provider.dismissInterruptedAgentRun();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(timedOutJournal.isRunIncomplete('run-timeout'), isTrue);
    expect(provider.currentSession?.inFlightAgentRun, isNull);
    expect(markerClearIndex(), greaterThanOrEqualTo(0));
  });
}

/// Shared, ordered event log. Journal commits and marker saves both append here
/// so a test can assert which happened first.
final class _OrderLog {
  final List<String> events = <String>[];
  int _sequence = 0;

  void add(String event) => events.add('${++_sequence}:$event');
}

final class _OrderedJournalStore implements RunJournalStore {
  _OrderedJournalStore(this.log);

  final _OrderLog log;
  String? content;
  int _revision = 0;
  Completer<void>? blockNextWrite;

  @override
  Future<String?> read() async => content;

  @override
  Future<void> write(String value) async {
    final blocker = blockNextWrite;
    if (blocker != null) {
      blockNextWrite = null;
      await blocker.future;
    }
    final decoded = jsonDecode(value) as Map<String, dynamic>;
    final revision = decoded['revision'] as int;
    if (revision <= _revision) {
      throw const FormatException('run_journal_stale_write');
    }
    _revision = revision;
    content = value;
    final runs = decoded['runs'] as List;
    if (runs.isEmpty) {
      log.add('journal:empty');
      return;
    }
    // A payload can carry several runs; the newest state is the observable
    // terminal transition for this test.
    final states = [
      for (final run in runs) (run as Map<String, dynamic>)['state'],
    ];
    log.add('journal:${states.last}');
  }

  @override
  Future<void> clear() async {
    content = null;
    _revision = 0;
  }
}

final class _OrderedSessionStorage extends SessionStorage {
  _OrderedSessionStorage(this.log);

  final _OrderLog log;
  final Map<String, ChatSession> _sessions = <String, ChatSession>{};
  bool _hadMarker = false;

  void seed(ChatSession session) {
    _sessions[session.id] = session;
    if (session.inFlightAgentRun != null) _hadMarker = true;
  }

  @override
  Future<void> init() async {}

  @override
  Future<List<SessionSummary>> getSessionsSummary() async => [
        for (final session in _sessions.values)
          SessionSummary(
            id: session.id,
            title: session.title,
            createdAt: session.createdAt,
            updatedAt: session.updatedAt,
            folder: session.folder,
          ),
      ];

  @override
  Future<ChatSession?> getSession(String id) async => _sessions[id];

  @override
  Future<void> saveSession(
    ChatSession session, {
    int? expectedGeneration,
    SessionCommitGuard? commitGuard,
  }) async {
    _sessions[session.id] = ChatSession.fromJson(
      jsonDecode(jsonEncode(session.toJson())) as Map<String, dynamic>,
    );
    if (session.inFlightAgentRun != null) {
      _hadMarker = true;
      log.add('marker-saved');
    } else if (_hadMarker) {
      _hadMarker = false;
      log.add('marker-cleared');
    }
  }

  @override
  Future<void> deleteSession(String id) async {
    _sessions.remove(id);
  }

  @override
  Future<void> clearAll() async {
    _sessions.clear();
  }
}

class _ImmediateLlmService extends LlmService {
  _ImmediateLlmService(super.config);

  @override
  Stream<StreamEvent> chatStream({
    required String system,
    required List<Map<String, dynamic>> messages,
    required List<ToolDefinition> tools,
  }) async* {
    yield StreamDone(const LlmResponse(
      stopReason: 'end_turn',
      content: [ContentBlock(type: 'text', text: 'completed')],
    ));
  }
}

class _ThrowingLlmService extends LlmService {
  _ThrowingLlmService(super.config);

  @override
  Stream<StreamEvent> chatStream({
    required String system,
    required List<Map<String, dynamic>> messages,
    required List<ToolDefinition> tools,
  }) async* {
    throw const FormatException('provider_unavailable');
  }
}

class _BlockingLlmService extends LlmService {
  _BlockingLlmService(
    super.config, {
    required this.started,
    required this.release,
  });

  final Completer<void> started;
  final Completer<void> release;

  @override
  Stream<StreamEvent> chatStream({
    required String system,
    required List<Map<String, dynamic>> messages,
    required List<ToolDefinition> tools,
  }) async* {
    if (!started.isCompleted) started.complete();
    await release.future;
    yield StreamDone(const LlmResponse(
      stopReason: 'end_turn',
      content: [ContentBlock(type: 'text', text: 'completed')],
    ));
  }
}
