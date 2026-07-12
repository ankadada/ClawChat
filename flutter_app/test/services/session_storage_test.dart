import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clawchat/models/chat_models.dart';
import 'package:clawchat/services/session_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('clawchat_session_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return tempDir.path;
      }
      return null;
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('SessionStorage session ID safety', () {
    test('valid UUID-like IDs are accepted', () async {
      final storage = SessionStorage();
      await storage.init();
      final session = ChatSession(
        id: 'session_123-abc',
        title: 'Valid',
        messages: [ChatMessage.user('hello')],
      );

      await storage.saveSession(session);

      final loaded = await storage.getSession('session_123-abc');
      expect(loaded?.id, 'session_123-abc');
      expect(await storage.getSessionIds(), contains('session_123-abc'));
    });

    test('atomic save keeps backup and restores readable backup', () async {
      final storage = SessionStorage();
      await storage.init();
      final session = ChatSession(
        id: 'atomic_session',
        title: 'Original',
        messages: [ChatMessage.user('hello')],
      );
      await storage.saveSession(session);

      session.title = 'Updated';
      await storage.saveSession(session);

      final sessionsDir = Directory('${tempDir.path}/clawchat_sessions');
      final primary = File('${sessionsDir.path}/atomic_session.json');
      final backup = File('${primary.path}.bak');
      expect(await primary.exists(), isTrue);
      expect(await backup.exists(), isTrue);
      expect(
        ChatSession.fromJson(
          jsonDecode(await backup.readAsString()) as Map<String, dynamic>,
        ).title,
        'Original',
      );

      await primary.writeAsString('{not valid json');

      final recovered = await storage.getSession('atomic_session');

      expect(recovered?.title, 'Original');
      expect(await primary.readAsString(), await backup.readAsString());
      final quarantined = await sessionsDir
          .list()
          .where(
              (entity) => entity.path.contains('atomic_session.json.corrupt'))
          .toList();
      expect(quarantined, isNotEmpty);
    });

    test('saveSession replaces existing primary and keeps previous backup',
        () async {
      final storage = SessionStorage();
      await storage.init();
      final session = ChatSession(
        id: 'replace_session',
        title: 'Before',
        messages: [ChatMessage.user('first version')],
      );
      await storage.saveSession(session);

      session.title = 'After';
      session.messages
        ..clear()
        ..add(ChatMessage.user('second version'));
      await storage.saveSession(session);

      final loaded = await storage.getSession('replace_session');
      expect(loaded?.title, 'After');
      expect(loaded?.messages.single.textContent, 'second version');

      final backup = File(
        '${tempDir.path}/clawchat_sessions/replace_session.json.bak',
      );
      final backupSession = ChatSession.fromJson(
        jsonDecode(await backup.readAsString()) as Map<String, dynamic>,
      );
      expect(backupSession.title, 'Before');
      expect(backupSession.messages.single.textContent, 'first version');
    });

    test('serializes lifecycle saves by invocation order per session',
        () async {
      final firstCommitEntered = Completer<void>();
      final releaseFirstCommit = Completer<void>();
      var commitCount = 0;
      final storage = SessionStorage(beforeCommitForTesting: (_) async {
        commitCount++;
        if (commitCount == 1) {
          firstCommitEntered.complete();
          await releaseFirstCommit.future;
        }
      });
      await storage.init();
      final timestamp = DateTime.utc(2026, 7, 10);
      final session = ChatSession(
        id: 'ordered_lifecycle',
        inFlightAgentRun: _recoveryMarker(
          timestamp,
          ToolAttemptLifecycle.completed,
          executionOutcomeKnown: true,
        ),
      );

      final completedSave = storage.saveSession(session);
      await firstCommitEntered.future;
      session.inFlightAgentRun = _recoveryMarker(
        timestamp,
        ToolAttemptLifecycle.interruptedUnknown,
      );
      final interruptedSave = storage.saveSession(session);
      session.inFlightAgentRun = _recoveryMarker(
        timestamp,
        ToolAttemptLifecycle.failed,
        executionOutcomeKnown: true,
      );
      final knownAbortSave = storage.saveSession(session);

      expect(commitCount, 1);
      releaseFirstCommit.complete();
      await Future.wait([completedSave, interruptedSave, knownAbortSave]);

      final loaded = await storage.getSession(session.id);
      expect(loaded, isNotNull);
      expect(loaded!.inFlightAgentRun!.toolAttempts.single.lifecycle,
          ToolAttemptLifecycle.failed);
      expect(loaded.inFlightAgentRun!.toolAttempts.single.executionOutcomeKnown,
          isTrue);
      final backup = File(
        '${tempDir.path}/clawchat_sessions/${session.id}.json.bak',
      );
      final backupSession = ChatSession.fromJson(
        jsonDecode(await backup.readAsString()) as Map<String, dynamic>,
      );
      expect(backupSession.inFlightAgentRun!.toolAttempts.single.lifecycle,
          ToolAttemptLifecycle.interruptedUnknown);
    });

    test('completion clear save cannot be overtaken by an older marker save',
        () async {
      final markerCommitEntered = Completer<void>();
      final releaseMarkerCommit = Completer<void>();
      var commitCount = 0;
      final storage = SessionStorage(beforeCommitForTesting: (_) async {
        commitCount++;
        if (commitCount == 1) {
          markerCommitEntered.complete();
          await releaseMarkerCommit.future;
        }
      });
      await storage.init();
      final timestamp = DateTime.utc(2026, 7, 11);
      final session = ChatSession(
        id: 'completion_clear_order',
        messages: [ChatMessage.user('normal request')],
        inFlightAgentRun: AgentRunRecoveryMarker(
          runAttemptId: 'ordered-run',
          startedAt: timestamp,
          updatedAt: timestamp,
        ),
      );

      final markerSave = storage.saveSession(session);
      await markerCommitEntered.future;
      session.messages.add(ChatMessage(
        role: 'assistant',
        content: [TextContent('completed')],
        timestamp: timestamp.add(const Duration(seconds: 1)),
      ));
      session.inFlightAgentRun = null;
      final completionSave = storage.saveSession(session);

      expect(commitCount, 1);
      releaseMarkerCommit.complete();
      await Future.wait([markerSave, completionSave]);

      final loaded = await storage.getSession(session.id);
      expect(loaded!.messages.last.textContent, 'completed');
      expect(loaded.inFlightAgentRun, isNull);
    });

    test('failed queued save does not poison the next save', () async {
      var commitCount = 0;
      final storage = SessionStorage(beforeCommitForTesting: (_) async {
        commitCount++;
        if (commitCount == 1) throw StateError('injected commit failure');
      });
      await storage.init();
      final session = ChatSession(id: 'save_failure_recovery', title: 'first');

      final failed = storage.saveSession(session);
      session.title = 'second';
      final recovered = storage.saveSession(session);

      await expectLater(failed, throwsStateError);
      await recovered;
      expect((await storage.getSession(session.id))?.title, 'second');
      expect(commitCount, 2);
    });

    test('delete tombstone invalidates a stalled save and prevents reload',
        () async {
      final commitEntered = Completer<void>();
      final releaseCommit = Completer<void>();
      final storage = SessionStorage(beforeCommitForTesting: (_) async {
        if (!commitEntered.isCompleted) commitEntered.complete();
        await releaseCommit.future;
      });
      await storage.init();
      final session = ChatSession(id: 'delete_stalled_save', title: 'stale');

      final staleSave = storage.saveSession(session);
      await commitEntered.future;
      final delete = storage.deleteSession(session.id);
      expect(storage.isSessionTombstoned(session.id), isTrue);
      await expectLater(storage.getSession(session.id), completion(isNull));

      releaseCommit.complete();
      await expectLater(
        staleSave,
        throwsA(isA<SessionTombstonedException>()),
      );
      await delete;
      expect(await storage.getSession(session.id), isNull);

      final reloaded = SessionStorage();
      await reloaded.init();
      expect(await reloaded.getSession(session.id), isNull);
    });

    test('late saves stay rejected until explicit recreation generation',
        () async {
      final storage = SessionStorage();
      await storage.init();
      final original = ChatSession(id: 'explicit_recreate', title: 'old');
      await storage.saveSession(original);
      final oldGeneration = storage.sessionGeneration(original.id);

      await storage.deleteSession(original.id);
      await expectLater(
        storage.saveSession(original),
        throwsA(isA<SessionTombstonedException>()),
      );

      final recreated = ChatSession(id: original.id, title: 'new identity');
      await storage.recreateDeletedSession(recreated);

      expect(
        storage.isSessionGenerationCurrent(original.id, oldGeneration),
        isFalse,
      );
      expect((await storage.getSession(original.id))!.title, 'new identity');
      original.title = 'late stale callback';
      await expectLater(
        storage.saveSession(original),
        throwsA(isA<SessionTombstonedException>()),
      );
      expect((await storage.getSession(original.id))!.title, 'new identity');
    });

    test('recreation queues after delete while stale commit is blocked',
        () async {
      final commitEntered = Completer<void>();
      final releaseCommit = Completer<void>();
      var blockFirst = true;
      final storage = SessionStorage(beforeCommitForTesting: (_) async {
        if (!blockFirst) return;
        blockFirst = false;
        commitEntered.complete();
        await releaseCommit.future;
      });
      await storage.init();
      final stale = ChatSession(id: 'queued_recreate', title: 'stale');
      final staleSave = storage.saveSession(stale);
      await commitEntered.future;

      final delete = storage.deleteSession(stale.id);
      final recreate = storage.recreateDeletedSession(
        ChatSession(id: stale.id, title: 'recreated'),
      );
      releaseCommit.complete();

      await expectLater(
        staleSave,
        throwsA(isA<SessionTombstonedException>()),
      );
      await delete;
      await recreate;
      expect((await storage.getSession(stale.id))!.title, 'recreated');
    });

    test('path traversal IDs are regenerated by ChatSession parsing', () {
      final session = ChatSession.fromJson(_sessionJson('../escape'));

      expect(session.id, isNot('../escape'));
      expect(session.id, matches(RegExp(r'^[a-zA-Z0-9_-]+$')));
    });

    test('invalid IDs cannot be loaded directly', () async {
      final storage = SessionStorage();
      await storage.init();

      expect(await storage.getSession('../escape'), isNull);
      expect(await storage.getSession('nested/path'), isNull);
    });

    test('import with invalid IDs is side-effect free', () async {
      final storage = SessionStorage();
      await storage.init();
      await expectLater(
        storage.importFromJson(jsonEncode({
          'version': 1,
          'sessions': [_sessionJson('../../outside')],
        })),
        throwsFormatException,
      );
      final sessionsDir = Directory('${tempDir.path}/clawchat_sessions');
      final files = await sessionsDir
          .list()
          .where((entity) => entity is File && entity.path.endsWith('.json'))
          .cast<File>()
          .toList();

      expect(files, isEmpty);
    });

    test('oversized import is rejected before mutation', () async {
      final storage = SessionStorage();
      await storage.init();
      await storage.saveSession(ChatSession(id: 'keep_local', title: 'Keep'));

      await expectLater(
        storage.previewImport('x' * (SessionStorage.maxTransferBytes + 1)),
        throwsFormatException,
      );

      expect((await storage.getSession('keep_local'))?.title, 'Keep');
      expect(await storage.getSessionIds(), contains('keep_local'));
    });

    test('import preserves existing session on id conflict', () async {
      final storage = SessionStorage();
      await storage.init();
      await storage.saveSession(ChatSession(
        id: 'same_id',
        title: 'Existing',
        messages: [ChatMessage.user('keep me')],
      ));

      final count = await storage.importFromJson(jsonEncode({
        'version': 1,
        'sessions': [
          _sessionJson(
            'same_id',
            title: 'Imported',
            messages: [
              ChatMessage.user('import me').toJson(),
            ],
          ),
        ],
      }));

      expect(count, 1);
      final existing = await storage.getSession('same_id');
      expect(existing?.title, 'Existing');
      expect(existing?.messages.single.textContent, 'keep me');

      final all = await storage.getAllSessions();
      expect(all, hasLength(2));
      final imported = all.singleWhere((session) => session.id != 'same_id');
      expect(imported.title, 'Imported (imported copy)');
      expect(imported.messages.single.textContent, 'import me');
    });

    test('versioned export is bounded and excludes endpoint selections',
        () async {
      final storage = SessionStorage();
      await storage.init();
      await storage.saveSession(ChatSession(
        id: 'export_safe',
        title: 'Local',
        baseUrlOverride: 'https://private.invalid',
        remoteAgentConnectorId: 'remote_choice',
        messages: [ChatMessage.user('local content')],
      ));

      final artifact = await storage.exportAllAsJson();
      final decoded = jsonDecode(artifact) as Map<String, dynamic>;
      final session = (decoded['sessions'] as List).single as Map;
      expect(decoded['schema'], 'clawchat.sessions');
      expect(decoded['version'], 2);
      expect(session.containsKey('baseUrlOverride'), isFalse);
      expect(session.containsKey('remoteAgentConnectorId'), isFalse);
      expect(utf8.encode(artifact).length,
          lessThanOrEqualTo(SessionStorage.maxTransferBytes));
    });

    test('import preview is dry-run and stale new-ID conflicts fail closed',
        () async {
      final storage = SessionStorage();
      await storage.init();
      final source = jsonEncode({
        'version': 1,
        'sessions': [_sessionJson('arrives_later')],
      });
      final preview = await storage.previewImport(source);
      expect(preview.newCount, 1);
      expect(await storage.getSessionIds(), isEmpty);

      await storage.saveSession(ChatSession(
        id: 'arrives_later',
        title: 'Concurrent local session',
      ));
      await expectLater(
        storage.applyImport(
          preview,
          SessionImportConflictPolicy.replace,
        ),
        throwsStateError,
      );
      expect((await storage.getSession('arrives_later'))?.title,
          'Concurrent local session');
    });

    test('replace creates verified backup and rollback restores original',
        () async {
      final storage = SessionStorage();
      await storage.init();
      await storage.saveSession(ChatSession(
        id: 'replace_me',
        title: 'Original',
        messages: [ChatMessage.user('original body')],
      ));
      final preview = await storage.previewImport(jsonEncode({
        'version': 1,
        'sessions': [
          _sessionJson(
            'replace_me',
            title: 'Imported',
            messages: [ChatMessage.user('imported body').toJson()],
          ),
        ],
      }));
      final result = await storage.applyImport(
        preview,
        SessionImportConflictPolicy.replace,
      );
      expect(result.replaced, 1);
      expect(result.backupPath, isNotNull);
      expect(await File(result.backupPath!).exists(), isTrue);
      expect((await storage.getSession('replace_me'))?.title, 'Imported');

      expect(await storage.rollbackImportBackup(result.backupPath!), 1);
      final restored = await storage.getSession('replace_me');
      expect(restored?.title, 'Original');
      expect(restored?.messages.single.textContent, 'original body');
    });

    test('changed conflict after preview is rejected without mutation',
        () async {
      final storage = SessionStorage();
      await storage.init();
      final existing = ChatSession(id: 'changed_conflict', title: 'First');
      await storage.saveSession(existing);
      final preview = await storage.previewImport(jsonEncode({
        'version': 1,
        'sessions': [_sessionJson('changed_conflict', title: 'Imported')],
      }));

      existing.title = 'Changed locally';
      await storage.saveSession(existing);

      await expectLater(
        storage.applyImport(preview, SessionImportConflictPolicy.replace),
        throwsStateError,
      );
      expect((await storage.getSession('changed_conflict'))?.title,
          'Changed locally');
    });

    test('failed multi-session apply rolls back from durable journal',
        () async {
      var writes = 0;
      final storage = SessionStorage(
        importMutationFaultInjector: (step) {
          if (step == SessionImportMutationStep.afterSessionWrite &&
              ++writes == 1) {
            throw StateError('injected import interruption');
          }
        },
      );
      await storage.init();
      await storage.saveSession(ChatSession(
        id: 'journal_original',
        title: 'Original',
      ));
      final preview = await storage.previewImport(jsonEncode({
        'version': 1,
        'sessions': [
          _sessionJson('journal_original', title: 'Replacement'),
          _sessionJson('journal_new', title: 'New'),
        ],
      }));

      await expectLater(
        storage.applyImport(preview, SessionImportConflictPolicy.replace),
        throwsStateError,
      );

      final restarted = SessionStorage();
      await restarted.init();
      expect(
          (await restarted.getSession('journal_original'))?.title, 'Original');
      expect(await restarted.getSession('journal_new'), isNull);
      expect(
        await File('${tempDir.path}/clawchat_sessions/.import-transaction.json')
            .exists(),
        isFalse,
      );
    });

    test('duplicate replacement is rejected without changing live session',
        () async {
      final storage = SessionStorage();
      await storage.init();
      await storage.saveSession(ChatSession(id: 'duplicate', title: 'Local'));
      final preview = await storage.previewImport(jsonEncode({
        'version': 1,
        'sessions': [
          _sessionJson('duplicate', title: 'First'),
          _sessionJson('duplicate', title: 'Second'),
        ],
      }));

      await expectLater(
        storage.applyImport(preview, SessionImportConflictPolicy.replace),
        throwsFormatException,
      );
      expect((await storage.getSession('duplicate'))?.title, 'Local');
    });

    test('trash survives restart and undo restores safe exact local state',
        () async {
      final first = SessionStorage();
      await first.init();
      await first.saveSession(ChatSession(
        id: 'trash_restart',
        title: 'Draft title',
        folder: 'Work',
        inFlightAgentRun: _recoveryMarker(
          DateTime.utc(2026, 7, 12),
          ToolAttemptLifecycle.started,
        ),
        messages: [ChatMessage.user('draft body')],
      ));
      await first.deleteSession('trash_restart');
      expect(await first.getSession('trash_restart'), isNull);
      expect(await first.listTrash(), hasLength(1));

      final restarted = SessionStorage();
      await restarted.init();
      expect(await restarted.getSession('trash_restart'), isNull);
      final restored = await restarted.restoreFromTrash('trash_restart');
      expect(restored?.title, 'Draft title');
      expect(restored?.folder, 'Work');
      expect(restored?.messages.single.textContent, 'draft body');
      expect(restored?.inFlightAgentRun, isNull);
      expect(await restarted.listTrash(), isEmpty);
      expect(
          (await restarted.getSession('trash_restart'))?.title, 'Draft title');
    });

    test('trash retention prunes deterministically to the entry bound',
        () async {
      final storage = SessionStorage();
      await storage.init();
      for (var index = 0;
          index < SessionStorage.maxTrashEntries + 2;
          index += 1) {
        final id = 'trash_$index';
        await storage.saveSession(ChatSession(id: id, title: 'Item $index'));
        await storage.deleteSession(id);
      }

      final trash = await storage.listTrash();
      expect(trash, hasLength(SessionStorage.maxTrashEntries));
      expect(trash.map((entry) => entry.title), contains('Item 21'));
      expect(trash.map((entry) => entry.title), isNot(contains('Item 0')));
    });
  });

  group('SessionStorage search', () {
    test('matches session message content and returns preview', () async {
      final storage = SessionStorage();
      await storage.init();
      final session = ChatSession(
        id: 'searchable',
        title: 'Daily notes',
        messages: [
          ChatMessage.user('hello'),
          ChatMessage(
            role: 'assistant',
            content: [
              TextContent('The deployment checklist mentions vector search.')
            ],
          ),
        ],
      );

      await storage.saveSession(session);

      final results = await storage.searchSessions('vector');
      expect(results.map((r) => r.summary.id), contains('searchable'));
      expect(results.first.matchPreview, contains('vector'));
    });

    test('uses backup for corrupted primary without mutating files', () async {
      final storage = SessionStorage();
      await storage.init();
      final session = ChatSession(
        id: 'search_backup',
        title: 'Backup searchable',
        messages: [ChatMessage.user('backup needle')],
      );
      await storage.saveSession(session);
      session.title = 'Primary current';
      session.messages
        ..clear()
        ..add(ChatMessage.user('current text'));
      await storage.saveSession(session);

      final sessionsDir = Directory('${tempDir.path}/clawchat_sessions');
      final primary = File('${sessionsDir.path}/search_backup.json');
      final backup = File('${primary.path}.bak');
      const corruptedPayload = '{not valid json';
      final backupBefore = await backup.readAsString();
      await primary.writeAsString(corruptedPayload);

      final results = await storage.searchSessions('needle');

      expect(results.map((result) => result.summary.id), ['search_backup']);
      expect(await primary.readAsString(), corruptedPayload);
      expect(await backup.readAsString(), backupBefore);
      final quarantined = await sessionsDir
          .list()
          .where((entity) => entity.path.contains('search_backup.json.corrupt'))
          .toList();
      expect(quarantined, isEmpty);
    });
  });

  group('SessionStorage preview', () {
    test('uses the active alternative text for message preview', () async {
      final storage = SessionStorage();
      await storage.init();
      final session = ChatSession(
        id: 'preview_alt',
        title: 'Preview',
        messages: [
          ChatMessage(
            role: 'assistant',
            content: [TextContent('latest')],
            alternatives: ['first'],
            activeAlternative: 0,
          ),
        ],
      );

      await storage.saveSession(session);

      final preview = await storage.getSessionPreview('preview_alt');
      expect(preview?.preview, 'first');
    });
  });

  group('SessionStorage usage summary', () {
    test('aggregates usage off stored payloads and skips corrupted sessions',
        () async {
      final storage = SessionStorage();
      await storage.init();
      await storage.saveSession(ChatSession(
        id: 'usage_one',
        title: 'Usage one',
        messages: [
          ChatMessage.user('hello'),
          ChatMessage(
            role: 'assistant',
            content: [TextContent('world')],
            inputTokens: 100,
            outputTokens: 20,
            cacheReadInputTokens: 30,
            cacheCreationInputTokens: 40,
          ),
        ],
      ));
      await storage.saveSession(ChatSession(
        id: 'usage_two',
        title: 'Usage two',
        messages: [
          ChatMessage(
            role: 'assistant',
            content: [TextContent('cached')],
            inputTokens: 50,
            outputTokens: 5,
            cacheReadInputTokens: 10,
            inputTokensIncludeCache: true,
          ),
          ChatMessage.systemNotice('ignored')
            ..inputTokens = 999
            ..outputTokens = 999,
        ],
      ));
      final corruptedFile = File(
        '${tempDir.path}/clawchat_sessions/corrupted.json',
      );
      await corruptedFile.writeAsString('{not valid json');

      final aggregate = await storage.getUsageSummaryAggregate();

      expect(await corruptedFile.exists(), isTrue);
      expect(aggregate.sessionCount, 2);
      expect(aggregate.summary.messageCount, 3);
      expect(aggregate.summary.messagesWithUsage, 2);
      expect(aggregate.summary.inputTokens, 150);
      expect(aggregate.summary.outputTokens, 25);
      expect(aggregate.summary.cacheReadInputTokens, 40);
      expect(aggregate.summary.cacheCreationInputTokens, 40);
      expect(aggregate.summary.totalTokens, 245);
    });
  });

  group('SessionStorage fork', () {
    test('copies messages through selected index and skips system notices',
        () async {
      final storage = SessionStorage();
      await storage.init();
      final source = ChatSession(
        id: 'source',
        title: 'Original',
        messages: [
          ChatMessage.user('first'),
          ChatMessage.systemNotice('context compacted'),
          ChatMessage(role: 'assistant', content: [TextContent('second')]),
          ChatMessage.user('third'),
        ],
      );
      await storage.saveSession(source);

      final fork = await storage.forkSession('source', 2);

      expect(fork, isNotNull);
      expect(fork!.id, isNot(source.id));
      expect(fork.title, '分支自: Original');
      expect(fork.messages.map((m) => m.textContent), ['first', 'second']);
      expect(fork.messages.any((m) => m.isSystemNotice), isFalse);

      fork.messages.first.content = [TextContent('changed')];
      final reloadedSource = await storage.getSession('source');
      expect(reloadedSource!.messages.first.textContent, 'first');
    });
  });

  group('ChatSession API messages', () {
    test('filters persisted system notices from API payload', () {
      final session = ChatSession(
        id: 'api_filter',
        messages: [
          ChatMessage.user('hello'),
          ChatMessage.systemNotice('对话上下文已压缩'),
          ChatMessage(role: 'assistant', content: [TextContent('hi')]),
        ],
      );

      final apiMessages = session.toApiMessages();
      expect(apiMessages, hasLength(2));
      expect(apiMessages.any((m) => m['role'] == 'system'), isFalse);
    });
  });
}

AgentRunRecoveryMarker _recoveryMarker(
  DateTime timestamp,
  ToolAttemptLifecycle lifecycle, {
  bool executionOutcomeKnown = false,
}) {
  return AgentRunRecoveryMarker(
    runAttemptId: 'ordered-run',
    startedAt: timestamp,
    updatedAt: timestamp,
    phase: AgentRunRecoveryPhase.toolInFlight,
    toolAttempts: [
      ToolAttemptRecoveryMetadata(
        operationId: 'ordered-operation',
        toolName: 'web_fetch',
        risk: RecoveryToolRisk.moderate,
        lifecycle: lifecycle,
        proposedAt: timestamp,
        updatedAt: timestamp,
        executionStartedAt: timestamp,
        executionOutcomeKnown: executionOutcomeKnown,
      ),
    ],
  );
}

Map<String, dynamic> _sessionJson(
  String id, {
  String title = 'Imported',
  List<Map<String, dynamic>>? messages,
}) {
  return {
    'id': id,
    'title': title,
    'createdAt': DateTime(2026, 1, 1).toIso8601String(),
    'updatedAt': DateTime(2026, 1, 1).toIso8601String(),
    'messages': messages ??
        [
          {
            'role': 'user',
            'timestamp': DateTime(2026, 1, 1).toIso8601String(),
            'content': [
              {'type': 'text', 'text': 'hello'}
            ],
          }
        ],
  };
}
