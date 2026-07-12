import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../l10n/app_strings.dart';
import '../models/chat_models.dart';
import 'usage_summary_service.dart';

class SessionSummary {
  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? folder;

  SessionSummary({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.folder,
  });
}

class SessionPreview {
  final String? preview;
  final String? modelOverride;

  const SessionPreview({
    this.preview,
    this.modelOverride,
  });
}

class SessionSearchResult {
  final SessionSummary summary;
  final String? matchPreview;

  const SessionSearchResult({
    required this.summary,
    this.matchPreview,
  });

  factory SessionSearchResult.fromJson(Map<String, dynamic> json) {
    return SessionSearchResult(
      summary: SessionSummary(
        id: json['id'] as String,
        title: json['title'] as String,
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
            DateTime.now(),
        updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
            DateTime.now(),
        folder: json['folder'] as String?,
      ),
      matchPreview: json['matchPreview'] as String?,
    );
  }
}

enum SessionImportConflictPolicy { keepExisting, importAsCopy, replace }

enum SessionImportMutationStep {
  journalPrepared,
  beforeSessionWrite,
  afterSessionWrite,
  beforeCommit,
}

typedef SessionImportMutationFaultInjector = FutureOr<void> Function(
  SessionImportMutationStep step,
);

final class SessionExportPreview {
  const SessionExportPreview({
    required this.sessionCount,
    required this.earliest,
    required this.latest,
    required this.estimatedBytes,
  });

  final int sessionCount;
  final DateTime? earliest;
  final DateTime? latest;
  final int estimatedBytes;
}

final class SessionImportPreview {
  const SessionImportPreview._({
    required this.schemaVersion,
    required this.validCount,
    required this.invalidCount,
    required this.duplicateCount,
    required this.conflictCount,
    required this.newCount,
    required this.requiredBytes,
    required List<ChatSession> sessions,
    required Set<String> duplicateIds,
    required Set<String> conflictIds,
    required Set<String> existingIds,
    required Map<String, String> existingDigests,
  })  : _sessions = sessions,
        _duplicateIds = duplicateIds,
        _conflictIds = conflictIds,
        _existingIds = existingIds,
        _existingDigests = existingDigests;

  final int schemaVersion;
  final int validCount;
  final int invalidCount;
  final int duplicateCount;
  final int conflictCount;
  final int newCount;
  final int requiredBytes;
  final List<ChatSession> _sessions;
  final Set<String> _duplicateIds;
  final Set<String> _conflictIds;
  final Set<String> _existingIds;
  final Map<String, String> _existingDigests;

  bool get canApply => invalidCount == 0 && validCount > 0;
}

final class SessionImportResult {
  const SessionImportResult({
    required this.imported,
    required this.skipped,
    required this.replaced,
    required this.backupPath,
  });

  final int imported;
  final int skipped;
  final int replaced;
  final String? backupPath;
}

final class SessionTrashEntry {
  const SessionTrashEntry({
    required this.sessionId,
    required this.title,
    required this.deletedAt,
    required this.expiresAt,
  });

  final String sessionId;
  final String title;
  final DateTime deletedAt;
  final DateTime expiresAt;
}

class SessionTombstonedException implements Exception {
  final String sessionId;

  const SessionTombstonedException(this.sessionId);

  @override
  String toString() => 'Session $sessionId has been deleted';
}

abstract interface class SessionCommitAuthority {
  int get generation;
  bool get isValid;
  SessionCommitPermit? tryAcquireCommit();
}

abstract interface class SessionCommitPermit {
  void complete();
}

final class SessionCommitGuard {
  const SessionCommitGuard({
    required this.sessionId,
    required this.sessionGeneration,
    required this.authorizationGeneration,
    required this.authority,
  });

  final String sessionId;
  final int sessionGeneration;
  final int authorizationGeneration;
  final SessionCommitAuthority authority;
}

class SessionCommitRejectedException implements Exception {
  const SessionCommitRejectedException();

  @override
  String toString() => 'Session commit authorization is no longer valid';
}

class SessionStorage {
  static final _validSessionIdPattern = RegExp(r'^[a-zA-Z0-9_-]+$');
  static const maxTransferBytes = 25 * 1024 * 1024;
  static const maxTransferSessions = 500;
  static const maxTrashEntries = 20;
  static const maxTrashBytes = 25 * 1024 * 1024;
  static const trashRetention = Duration(days: 7);
  static Future<void> _mutationTail = Future<void>.value();

  SessionStorage({
    Future<void> Function(String sessionId)? beforeCommitForTesting,
    Future<void> Function(String sessionId)? afterCommitPermitForTesting,
    SessionImportMutationFaultInjector? importMutationFaultInjector,
  })  : _beforeCommitForTesting = beforeCommitForTesting,
        _afterCommitPermitForTesting = afterCommitPermitForTesting,
        _importMutationFaultInjector = importMutationFaultInjector;

  Directory? _sessionsDir;
  final Future<void> Function(String sessionId)? _beforeCommitForTesting;
  final Future<void> Function(String sessionId)? _afterCommitPermitForTesting;
  final SessionImportMutationFaultInjector? _importMutationFaultInjector;
  final Map<String, Future<void>> _saveTails = {};
  final Map<String, int> _sessionGenerations = {};
  final Set<String> _tombstonedSessionIds = {};
  final Expando<int> _sessionObjectGenerations =
      Expando<int>('sessionStorageGeneration');

  int sessionGeneration(String id) => _sessionGenerations[id] ?? 0;

  bool isSessionGenerationCurrent(String id, int generation) =>
      !_tombstonedSessionIds.contains(id) &&
      sessionGeneration(id) == generation;

  bool isSessionTombstoned(String id) => _tombstonedSessionIds.contains(id);

  void tombstoneSession(String id) {
    if (!_validSessionIdPattern.hasMatch(id) ||
        !_tombstonedSessionIds.add(id)) {
      return;
    }
    _sessionGenerations[id] = sessionGeneration(id) + 1;
  }

  Future<void> init() async {
    if (_sessionsDir != null) return;
    final appDir = await getApplicationDocumentsDirectory();
    _sessionsDir = Directory('${appDir.path}/clawchat_sessions');
    if (!await _sessionsDir!.exists()) {
      await _sessionsDir!.create(recursive: true);
    }
    // One-time migration from SharedPreferences
    await _migrateFromSharedPreferences();
    await _reconcileImportTransaction();
    await _reconcileTrash();
  }

  Future<File?> _sessionFile(String id) async {
    if (!_validSessionIdPattern.hasMatch(id)) return null;

    final sessionsPath = await _canonicalSessionsDirPath();
    final file = File('$sessionsPath${Platform.pathSeparator}$id.json');
    if (!await file.parent.exists()) {
      await file.parent.create(recursive: true);
    }
    final targetParentPath = await _canonicalPath(file.parent);
    if (targetParentPath != sessionsPath) return null;

    final targetPath = file.absolute.path;
    if (!_isInsideSessionsDir(targetPath, sessionsPath)) return null;

    return file;
  }

  Future<String> _canonicalSessionsDirPath() async {
    if (!await _sessionsDir!.exists()) {
      await _sessionsDir!.create(recursive: true);
    }
    return _canonicalPath(_sessionsDir!);
  }

  Future<String> _canonicalPath(FileSystemEntity entity) async {
    try {
      return await entity.resolveSymbolicLinks();
    } catch (_) {
      return entity.absolute.path;
    }
  }

  bool _isInsideSessionsDir(String targetPath, String sessionsPath) {
    final normalizedDir = sessionsPath.endsWith(Platform.pathSeparator)
        ? sessionsPath
        : '$sessionsPath${Platform.pathSeparator}';
    return targetPath.startsWith(normalizedDir);
  }

  /// Migrates existing sessions from SharedPreferences to individual JSON files.
  /// After migration, the SharedPreferences keys are removed.
  Future<void> _migrateFromSharedPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList('clawchat_session_ids');
    if (ids == null || ids.isEmpty) return;

    for (final id in ids) {
      final json = prefs.getString('clawchat_session_$id');
      if (json == null) continue;
      try {
        final session = ChatSession.fromJson(jsonDecode(json));
        final file = await _sessionFile(session.id);
        if (file != null && !await file.exists()) {
          await file.writeAsString(jsonEncode(session.toJson()));
        }
      } catch (_) {
        // Skip malformed legacy sessions
      }
      await prefs.remove('clawchat_session_$id');
    }
    await prefs.remove('clawchat_session_ids');
  }

  Future<List<String>> getSessionIds() async {
    await init();
    final ids = <String>[];
    await for (final entity in _sessionsDir!.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final filename = entity.uri.pathSegments.last;
      final id = filename.substring(0, filename.length - 5); // strip .json
      if (_validSessionIdPattern.hasMatch(id) &&
          !_tombstonedSessionIds.contains(id)) {
        ids.add(id);
      }
    }
    return ids;
  }

  Future<List<ChatSession>> getAllSessions() async {
    await init();
    final sessions = <ChatSession>[];
    await for (final entity in _sessionsDir!.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final id = _idFromSessionFile(entity);
      if (id == null || _tombstonedSessionIds.contains(id)) continue;
      final session = await getSession(id);
      if (session != null) sessions.add(session);
    }
    sessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return sessions;
  }

  Future<UsageSummaryAggregate> getUsageSummaryAggregate() async {
    await init();
    final payloads = <String>[];
    await for (final entity in _sessionsDir!.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final id = _idFromSessionFile(entity);
      if (id == null || _tombstonedSessionIds.contains(id)) continue;
      try {
        payloads.add(await entity.readAsString());
      } catch (_) {
        // Skip unreadable session files; parsing happens in the worker isolate.
      }
    }
    final result = await compute(_usageSummaryAggregateFromPayloads, payloads);
    return UsageSummaryAggregate.fromJson(Map<String, dynamic>.from(result));
  }

  Future<List<SessionSummary>> getSessionsSummary() async {
    await init();
    final summaries = <SessionSummary>[];
    await for (final entity in _sessionsDir!.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final id = _idFromSessionFile(entity);
      if (id == null || _tombstonedSessionIds.contains(id)) continue;
      final session = await getSession(id);
      if (session == null) continue;
      summaries.add(SessionSummary(
        id: session.id,
        title: session.title,
        createdAt: session.createdAt,
        updatedAt: session.updatedAt,
        folder: session.folder,
      ));
    }
    summaries.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return summaries;
  }

  Future<List<SessionSearchResult>> searchSessions(String query) async {
    await init();
    final normalizedQuery = query.trim().toLowerCase();
    if (normalizedQuery.isEmpty) return const [];

    final payloads = <Map<String, String>>[];
    await for (final entity in _sessionsDir!.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final id = _idFromSessionFile(entity);
      if (id == null || _tombstonedSessionIds.contains(id)) continue;
      final primaryRaw = await _readRawIfExists(entity);
      final backupRaw = await _readRawIfExists(_backupFileFor(entity));
      if (primaryRaw != null || backupRaw != null) {
        payloads.add({
          'json': primaryRaw ?? '',
          if (backupRaw != null) 'backupJson': backupRaw,
        });
      }
    }

    final rawResults = await compute(_searchSessionPayloads, {
      'query': normalizedQuery,
      'payloads': payloads,
    });
    return rawResults.map(SessionSearchResult.fromJson).toList();
  }

  Future<String?> _readRawIfExists(File file) async {
    try {
      if (!await file.exists()) return null;
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  Future<ChatSession?> getSession(String id) async {
    if (_tombstonedSessionIds.contains(id)) return null;
    final generation = sessionGeneration(id);
    await init();
    if (!isSessionGenerationCurrent(id, generation)) return null;
    final file = await _sessionFile(id);
    if (file == null) return null;
    final session = await _readSessionWithBackupRecovery(file);
    if (!isSessionGenerationCurrent(id, generation) || session == null) {
      return null;
    }
    _sessionObjectGenerations[session] = generation;
    return session;
  }

  Future<SessionPreview?> getSessionPreview(String id) async {
    await init();
    final session = await getSession(id);
    if (session == null) return null;
    final map = session.toJson();
    final messages = map['messages'];
    String? preview;
    if (messages is List) {
      for (final message in messages.reversed) {
        preview = _previewTextFromMessage(message);
        if (preview != null) break;
      }
    }
    return SessionPreview(
      preview: preview,
      modelOverride: map['modelOverride'] as String?,
    );
  }

  String? _previewTextFromMessage(Object? rawMessage) {
    if (rawMessage is! Map) return null;
    final activeAlternative = rawMessage['activeAlternative'];
    final alternatives = rawMessage['alternatives'];
    if (activeAlternative is int &&
        activeAlternative >= 0 &&
        alternatives is List &&
        activeAlternative < alternatives.length) {
      final alternative = alternatives[activeAlternative];
      if (alternative is String) return _nonEmptyText(alternative);
    }
    final content = rawMessage['content'];
    return _previewTextFromContent(content);
  }

  String? _previewTextFromContent(Object? content) {
    if (content is String) return _nonEmptyText(content);
    if (content is! List) return null;

    final parts = <String>[];
    for (final block in content) {
      if (block is! Map || block['type'] != 'text') continue;
      final text = block['text'];
      if (text is! String) continue;
      final compact = _nonEmptyText(text);
      if (compact != null) parts.add(compact);
    }
    return parts.isEmpty ? null : parts.join('\n');
  }

  String? _nonEmptyText(String text) {
    final trimmed = text.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  String? _idFromSessionFile(File file) {
    final filename = file.uri.pathSegments.last;
    if (!filename.endsWith('.json')) return null;
    final id = filename.substring(0, filename.length - 5);
    return _validSessionIdPattern.hasMatch(id) ? id : null;
  }

  File _backupFileFor(File file) => File('${file.path}.bak');

  Future<ChatSession?> _tryReadSession(File file) async {
    try {
      final content = await file.readAsString();
      return ChatSession.fromJson(jsonDecode(content) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<ChatSession?> _readSessionWithBackupRecovery(File file) async {
    if (await file.exists()) {
      final session = await _tryReadSession(file);
      if (session != null) return session;

      final backup = _backupFileFor(file);
      final backupSession =
          await backup.exists() ? await _tryReadSession(backup) : null;
      await _quarantineCorruptedFile(file);
      if (backupSession != null) {
        try {
          await backup.copy(file.path);
        } catch (_) {
          // Keep returning the backup even if restoring the primary fails.
        }
        return backupSession;
      }
      return null;
    }

    final backup = _backupFileFor(file);
    if (!await backup.exists()) return null;
    final backupSession = await _tryReadSession(backup);
    if (backupSession == null) return null;
    try {
      await backup.copy(file.path);
    } catch (_) {
      // Keep returning the backup even if restoring the primary fails.
    }
    return backupSession;
  }

  Future<void> _quarantineCorruptedFile(File file) async {
    if (!await file.exists()) return;
    final quarantine = File(
      '${file.path}.corrupt-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await file.rename(quarantine.path);
    } catch (_) {
      // If quarantine fails, leave the corrupted file in place for inspection.
    }
  }

  Future<void> saveSession(
    ChatSession session, {
    int? expectedGeneration,
    SessionCommitGuard? commitGuard,
  }) {
    // Snapshot synchronously at invocation time. A queued older write must not
    // serialize fields mutated by a newer lifecycle update while it waits.
    session.updatedAt = DateTime.now();
    final sessionId = session.id;
    final objectGeneration = _sessionObjectGenerations[session];
    if (_tombstonedSessionIds.contains(sessionId) ||
        (objectGeneration != null &&
            objectGeneration != sessionGeneration(sessionId)) ||
        (expectedGeneration != null &&
            expectedGeneration != sessionGeneration(sessionId))) {
      return Future<void>.error(SessionTombstonedException(sessionId));
    }
    final generation = expectedGeneration ?? sessionGeneration(sessionId);
    if (commitGuard != null &&
        (commitGuard.sessionId != sessionId ||
            commitGuard.sessionGeneration != generation ||
            commitGuard.authorizationGeneration !=
                commitGuard.authority.generation ||
            !commitGuard.authority.isValid)) {
      return Future<void>.error(const SessionCommitRejectedException());
    }
    _sessionObjectGenerations[session] = generation;
    final payload = jsonEncode(session.toJson());
    final commitToken = commitGuard == null
        ? null
        : _SessionCommitToken(
            guard: commitGuard,
            payloadDigest: sha256.convert(utf8.encode(payload)).toString(),
          );
    final previous = _saveTails[sessionId];

    final operation = _saveSessionInOrder(
      sessionId,
      payload,
      generation: generation,
      previous: previous,
      commitToken: commitToken,
    );
    _saveTails[sessionId] = operation;
    unawaited(operation.then<void>(
      (_) => _removeSaveTail(sessionId, operation),
      onError: (Object _, StackTrace __) {
        _removeSaveTail(sessionId, operation);
      },
    ));
    return operation;
  }

  Future<void> _saveSessionInOrder(
    String sessionId,
    String payload, {
    required int generation,
    required Future<void>? previous,
    required _SessionCommitToken? commitToken,
  }) async {
    if (previous != null) {
      try {
        await previous;
      } catch (_) {
        // A failed write must not poison later saves for this session.
      }
    }
    await _writeSessionPayload(
      sessionId,
      payload,
      generation,
      commitToken: commitToken,
    );
  }

  void _removeSaveTail(String sessionId, Future<void> operation) {
    if (identical(_saveTails[sessionId], operation)) {
      _saveTails.remove(sessionId);
    }
  }

  Future<void> _writeSessionPayload(
      String sessionId, String payload, int generation,
      {required _SessionCommitToken? commitToken}) async {
    _throwIfSessionGenerationStale(sessionId, generation);
    await init();
    _throwIfSessionGenerationStale(sessionId, generation);
    final file = await _sessionFile(sessionId);
    if (file == null) {
      throw Exception('Invalid session id');
    }
    final temp = File(
      '${file.path}.tmp-${DateTime.now().microsecondsSinceEpoch}',
    );
    IOSink? sink;
    try {
      sink = temp.openWrite();
      sink.write(payload);
      await sink.flush();
      await sink.close();
      sink = null;

      await _beforeCommitForTesting?.call(sessionId);
      _throwIfSessionGenerationStale(sessionId, generation);
      if (await file.exists()) {
        final previous = await _tryReadSession(file);
        if (previous != null) {
          await file.copy(_backupFileFor(file).path);
        }
      }
      _throwIfSessionGenerationStale(sessionId, generation);
      SessionCommitPermit? permit;
      if (commitToken != null) {
        final currentDigest = sha256.convert(utf8.encode(payload)).toString();
        if (commitToken.guard.sessionId != sessionId ||
            commitToken.guard.sessionGeneration != generation ||
            commitToken.guard.authorizationGeneration !=
                commitToken.guard.authority.generation ||
            commitToken.payloadDigest != currentDigest) {
          throw const SessionCommitRejectedException();
        }
        permit = commitToken.guard.authority.tryAcquireCommit();
        if (permit == null) {
          throw const SessionCommitRejectedException();
        }
      }
      try {
        if (commitToken != null) {
          await _afterCommitPermitForTesting?.call(sessionId);
        }
        _throwIfSessionGenerationStale(sessionId, generation);
        await temp.rename(file.path);
      } finally {
        permit?.complete();
      }
    } finally {
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {
          // Ignore cleanup failures from a failed write.
        }
      }
      if (await temp.exists()) {
        try {
          await temp.delete();
        } catch (_) {
          // Ignore temp cleanup failures.
        }
      }
    }
  }

  void _throwIfSessionGenerationStale(String id, int generation) {
    if (!isSessionGenerationCurrent(id, generation)) {
      throw SessionTombstonedException(id);
    }
  }

  Future<void> deleteSession(String id) =>
      _deleteSession(id, retainInTrash: true);

  Future<void> deleteSessionPermanently(String id) =>
      _deleteSession(id, retainInTrash: false);

  Future<void> _deleteSession(String id, {required bool retainInTrash}) {
    if (!_validSessionIdPattern.hasMatch(id)) return Future<void>.value();
    tombstoneSession(id);
    final previous = _saveTails[id];
    final operation = _deleteSessionInOrder(
      id,
      previous: previous,
      retainInTrash: retainInTrash,
    );
    _saveTails[id] = operation;
    unawaited(operation.then<void>(
      (_) => _removeSaveTail(id, operation),
      onError: (Object _, StackTrace __) {
        _removeSaveTail(id, operation);
      },
    ));
    return operation;
  }

  Future<void> _deleteSessionInOrder(
    String id, {
    required Future<void>? previous,
    required bool retainInTrash,
  }) async {
    if (previous != null) {
      try {
        await previous;
      } catch (_) {
        // Stale saves are expected to fail after the tombstone is installed.
      }
    }
    await init();
    final file = await _sessionFile(id);
    if (file == null) return;
    File? trashFile;
    try {
      if (retainInTrash && await file.exists()) {
        trashFile = await _writeTrashEntry(file, id);
      }
      if (await file.exists()) await file.delete();
      final backup = _backupFileFor(file);
      if (await backup.exists()) await backup.delete();
    } catch (_) {
      if (await file.exists()) {
        if (trashFile != null && await trashFile.exists()) {
          await trashFile.delete();
        }
        _sessionGenerations[id] = sessionGeneration(id) + 1;
        _tombstonedSessionIds.remove(id);
      }
      rethrow;
    }
  }

  Future<void> recreateDeletedSession(ChatSession session) {
    final id = session.id;
    if (!_tombstonedSessionIds.contains(id)) {
      return Future<void>.error(
        StateError('Session must be deleted before explicit recreation.'),
      );
    }
    _sessionGenerations[id] = sessionGeneration(id) + 1;
    _tombstonedSessionIds.remove(id);
    _sessionObjectGenerations[session] = sessionGeneration(id);
    return saveSession(session);
  }

  Future<ChatSession?> forkSession(
      String sessionId, int upToMessageIndex) async {
    final source = await getSession(sessionId);
    if (source == null ||
        upToMessageIndex < 0 ||
        upToMessageIndex >= source.messages.length) {
      return null;
    }

    final copiedMessages = source.messages
        .take(upToMessageIndex + 1)
        .where((message) => !message.isSystemNotice)
        .map(_deepCopyMessage)
        .toList();
    if (copiedMessages.isEmpty) return null;

    final fork = ChatSession(
      id: const Uuid().v4(),
      title: AppStrings.forkedFromTitle(source.title),
      messages: copiedMessages,
      modelOverride: source.modelOverride,
      baseUrlOverride: source.baseUrlOverride,
      apiFormatOverride: source.apiFormatOverride,
      systemPrompt: source.systemPrompt,
      folder: source.folder,
      modelGroupId: source.modelGroupId,
    );
    await saveSession(fork);
    return fork;
  }

  Future<ChatSession?> forkSessionBeforeMessage(
      String sessionId, int messageIndex) async {
    final source = await getSession(sessionId);
    if (source == null ||
        messageIndex < 0 ||
        messageIndex >= source.messages.length) {
      return null;
    }

    final copiedMessages = source.messages
        .take(messageIndex)
        .where((message) => !message.isSystemNotice)
        .map(_deepCopyMessage)
        .toList();

    final fork = ChatSession(
      id: const Uuid().v4(),
      title: AppStrings.forkedFromTitle(source.title),
      messages: copiedMessages,
      modelOverride: source.modelOverride,
      baseUrlOverride: source.baseUrlOverride,
      apiFormatOverride: source.apiFormatOverride,
      systemPrompt: source.systemPrompt,
      folder: source.folder,
      modelGroupId: source.modelGroupId,
    );
    await saveSession(fork);
    return fork;
  }

  Future<void> clearAll() async {
    await init();
    final ids = <String>{..._saveTails.keys};
    await for (final entity in _sessionsDir!.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final id = _idFromSessionFile(entity);
      if (id != null) ids.add(id);
    }
    for (final id in ids) {
      tombstoneSession(id);
    }
    await Future.wait(ids.map(deleteSession));
    await for (final entity in _sessionsDir!.list()) {
      if (entity is File) await entity.delete();
    }
  }

  Future<SessionExportPreview> previewExport() async {
    final sessions = await getAllSessions();
    final encoded = _encodeExport(sessions);
    return SessionExportPreview(
      sessionCount: sessions.length,
      earliest: sessions.isEmpty
          ? null
          : sessions.map((s) => s.createdAt).reduce(
                (a, b) => a.isBefore(b) ? a : b,
              ),
      latest: sessions.isEmpty
          ? null
          : sessions.map((s) => s.updatedAt).reduce(
                (a, b) => a.isAfter(b) ? a : b,
              ),
      estimatedBytes: utf8.encode(encoded).length,
    );
  }

  Future<String> exportAllAsJson() async {
    final sessions = await getAllSessions();
    if (sessions.length > maxTransferSessions) {
      throw const FormatException('Session export count exceeds limit.');
    }
    final encoded = _encodeExport(sessions);
    if (utf8.encode(encoded).length > maxTransferBytes) {
      throw const FormatException('Session export size exceeds limit.');
    }
    _parseImportEnvelope(encoded);
    return encoded;
  }

  String _encodeExport(List<ChatSession> sessions) => jsonEncode({
        'schema': 'clawchat.sessions',
        'version': 2,
        'exportedAt': DateTime.now().toUtc().toIso8601String(),
        'sessions': sessions.map(_exportSessionJson).toList(),
      });

  Map<String, dynamic> _exportSessionJson(ChatSession session) {
    final value = Map<String, dynamic>.from(session.toJson());
    value.remove('baseUrlOverride');
    value.remove('remoteAgentConnectorId');
    return value;
  }

  Future<SessionImportPreview> previewImport(String source) async {
    if (utf8.encode(source).length > maxTransferBytes) {
      throw const FormatException('Session import size exceeds limit.');
    }
    final parsed = _parseImportEnvelope(source);
    final existing = (await getSessionIds()).toSet();
    final sessions = <ChatSession>[];
    final seen = <String>{};
    final duplicates = <String>{};
    final conflicts = <String>{};
    final existingDigests = <String, String>{};
    var invalid = 0;
    for (final value in parsed.sessions) {
      try {
        if (value is! Map) throw const FormatException();
        final json = Map<String, dynamic>.from(value);
        _validateImportedSessionJson(json);
        final session = ChatSession.fromJson(json);
        if (!seen.add(session.id)) duplicates.add(session.id);
        if (existing.contains(session.id) || isSessionTombstoned(session.id)) {
          conflicts.add(session.id);
          final current = await getSession(session.id);
          if (current != null) {
            existingDigests[session.id] = sha256
                .convert(utf8.encode(jsonEncode(current.toJson())))
                .toString();
          }
        }
        sessions.add(session);
      } catch (_) {
        invalid += 1;
      }
    }
    return SessionImportPreview._(
      schemaVersion: parsed.version,
      validCount: sessions.length,
      invalidCount: invalid,
      duplicateCount: duplicates.length,
      conflictCount: conflicts.length,
      newCount: sessions.where((s) => !conflicts.contains(s.id)).length,
      requiredBytes: utf8.encode(source).length * 2,
      sessions: sessions,
      duplicateIds: duplicates,
      conflictIds: conflicts,
      existingIds: existing,
      existingDigests: existingDigests,
    );
  }

  Future<SessionImportResult> applyImport(
    SessionImportPreview preview,
    SessionImportConflictPolicy policy,
  ) =>
      _withMutationLock(() async {
        if (!preview.canApply) {
          throw const FormatException('Session import preview is not valid.');
        }
        if (policy == SessionImportConflictPolicy.replace &&
            preview._duplicateIds.isNotEmpty) {
          throw const FormatException(
            'Duplicate imported IDs cannot use replace policy.',
          );
        }
        final currentIds = (await getSessionIds()).toSet();
        for (final session in preview._sessions) {
          final wasExisting = preview._existingIds.contains(session.id);
          final isExisting = currentIds.contains(session.id) ||
              isSessionTombstoned(session.id);
          if (wasExisting != isExisting) {
            throw StateError('Session import preview is stale.');
          }
          final expectedDigest = preview._existingDigests[session.id];
          if (expectedDigest != null) {
            final current = await getSession(session.id);
            final currentDigest = current == null
                ? null
                : sha256
                    .convert(utf8.encode(jsonEncode(current.toJson())))
                    .toString();
            if (currentDigest != expectedDigest) {
              throw StateError('Session import preview is stale.');
            }
          }
        }
        final originals = <String, ChatSession>{};
        if (policy == SessionImportConflictPolicy.replace) {
          for (final id in preview._conflictIds) {
            final original = await getSession(id);
            if (original != null) originals[id] = original;
          }
        }
        final backupPath = originals.isEmpty
            ? null
            : await _writeImportBackup(originals.values.toList());
        final planned = <ChatSession>[];
        var imported = 0;
        var skipped = 0;
        var replaced = 0;
        final used = <String>{...currentIds};
        for (final source in preview._sessions) {
          final safeSource = source.copyWith(pendingWorkspaceImports: const []);
          final conflicts = used.contains(source.id) ||
              preview._duplicateIds.contains(source.id);
          if (conflicts && policy == SessionImportConflictPolicy.keepExisting) {
            skipped += 1;
            continue;
          }
          var session = safeSource;
          if (conflicts && policy == SessionImportConflictPolicy.importAsCopy) {
            session = safeSource.copyWith(
              id: const Uuid().v4(),
              title: '${source.title} (imported copy)',
              clearInFlightAgentRun: true,
              pendingWorkspaceImports: const [],
            );
          } else if (conflicts &&
              policy == SessionImportConflictPolicy.replace) {
            replaced += 1;
          }
          planned.add(session);
          used.add(session.id);
        }
        await _writeImportTransaction(
          originals: originals.values.toList(),
          plannedIds: planned.map((session) => session.id).toList(),
        );
        await _importMutationFaultInjector?.call(
          SessionImportMutationStep.journalPrepared,
        );
        try {
          for (final session in planned) {
            await _importMutationFaultInjector?.call(
              SessionImportMutationStep.beforeSessionWrite,
            );
            if (policy == SessionImportConflictPolicy.replace &&
                preview._conflictIds.contains(session.id)) {
              await deleteSessionPermanently(session.id);
              await recreateDeletedSession(session);
            } else {
              await saveSession(session);
            }
            await _importMutationFaultInjector?.call(
              SessionImportMutationStep.afterSessionWrite,
            );
            imported += 1;
          }
          await _importMutationFaultInjector?.call(
            SessionImportMutationStep.beforeCommit,
          );
          await _deleteImportTransaction();
        } catch (_) {
          await _reconcileImportTransaction();
          rethrow;
        }
        return SessionImportResult(
          imported: imported,
          skipped: skipped,
          replaced: replaced,
          backupPath: backupPath,
        );
      });

  Future<int> importFromJson(String source) async {
    final preview = await previewImport(source);
    final result = await applyImport(
      preview,
      SessionImportConflictPolicy.importAsCopy,
    );
    return result.imported;
  }

  Future<int> rollbackImportBackup(String backupPath) =>
      _withMutationLock(() async {
        await init();
        final directory = Directory('${_sessionsDir!.path}/.import-backups');
        final root = await _canonicalPath(directory);
        final file = File(backupPath);
        if (!await file.exists()) {
          throw const FormatException('Invalid import backup path.');
        }
        final canonicalFile = await _canonicalPath(file);
        if (!_isInsideSessionsDir(canonicalFile, root)) {
          throw const FormatException('Invalid import backup path.');
        }
        final source = await file.readAsString();
        if (utf8.encode(source).length > maxTransferBytes) {
          throw const FormatException('Import backup exceeds limit.');
        }
        final decoded = jsonDecode(source);
        if (decoded is! Map ||
            decoded['schema'] != 'clawchat.preimport-backup' ||
            decoded['version'] != 1 ||
            decoded['sessions'] is! List) {
          throw const FormatException('Invalid import backup.');
        }
        final sessions = (decoded['sessions'] as List)
            .map((value) => ChatSession.fromJson(
                  Map<String, dynamic>.from(value as Map),
                ))
            .toList();
        for (final session in sessions) {
          if (!isSessionTombstoned(session.id)) {
            tombstoneSession(session.id);
            await deleteSessionPermanently(session.id);
          }
          await recreateDeletedSession(session);
        }
        return sessions.length;
      });

  _ParsedImportEnvelope _parseImportEnvelope(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) throw const FormatException('Invalid export root.');
    final json = Map<String, dynamic>.from(decoded);
    final version = json['version'];
    if (version == 1) {
      if (json.keys
              .toSet()
              .difference(const {'version', 'sessions'}).isNotEmpty ||
          json['sessions'] is! List) {
        throw const FormatException('Invalid legacy session export.');
      }
      final sessions = json['sessions'] as List;
      if (sessions.length > maxTransferSessions) {
        throw const FormatException('Session import count exceeds limit.');
      }
      return _ParsedImportEnvelope(1, sessions);
    }
    if (version != 2 ||
        json.keys.toSet().difference(
          const {'schema', 'version', 'exportedAt', 'sessions'},
        ).isNotEmpty ||
        json['schema'] != 'clawchat.sessions' ||
        DateTime.tryParse(json['exportedAt']?.toString() ?? '') == null ||
        json['sessions'] is! List) {
      throw const FormatException('Invalid session export schema.');
    }
    final sessions = json['sessions'] as List;
    if (sessions.length > maxTransferSessions) {
      throw const FormatException('Session import count exceeds limit.');
    }
    return _ParsedImportEnvelope(2, sessions);
  }

  File get _importTransactionFile =>
      File('${_sessionsDir!.path}/.import-transaction.json');

  Future<void> _writeImportTransaction({
    required List<ChatSession> originals,
    required List<String> plannedIds,
  }) async {
    final encoded = jsonEncode({
      'schema': 'clawchat.session-import-transaction',
      'version': 1,
      'plannedIds': plannedIds,
      'originals': originals.map((session) => session.toJson()).toList(),
    });
    if (utf8.encode(encoded).length > maxTransferBytes ||
        plannedIds.length > maxTransferSessions ||
        originals.length > maxTransferSessions) {
      throw const FormatException('Session import transaction exceeds limit.');
    }
    await _atomicWrite(_importTransactionFile, encoded);
  }

  Future<void> _deleteImportTransaction() async {
    final file = _importTransactionFile;
    if (await file.exists()) await file.delete();
  }

  Future<void> _reconcileImportTransaction() async {
    final marker = _importTransactionFile;
    if (!await marker.exists()) return;
    if (await marker.length() > maxTransferBytes) {
      throw const FormatException('Invalid session import transaction.');
    }
    final decoded = jsonDecode(await marker.readAsString());
    if (decoded is! Map) {
      throw const FormatException('Invalid session import transaction.');
    }
    final json = Map<String, dynamic>.from(decoded);
    if (json.keys.toSet().difference(const {
          'schema',
          'version',
          'plannedIds',
          'originals',
        }).isNotEmpty ||
        json['schema'] != 'clawchat.session-import-transaction' ||
        json['version'] != 1 ||
        json['plannedIds'] is! List ||
        json['originals'] is! List) {
      throw const FormatException('Invalid session import transaction.');
    }
    final plannedIds = (json['plannedIds'] as List).map((value) {
      if (value is! String || !_validSessionIdPattern.hasMatch(value)) {
        throw const FormatException('Invalid session import transaction.');
      }
      return value;
    }).toList();
    final originals = (json['originals'] as List).map((value) {
      if (value is! Map) {
        throw const FormatException('Invalid session import transaction.');
      }
      final session = ChatSession.fromJson(Map<String, dynamic>.from(value));
      if (!_validSessionIdPattern.hasMatch(session.id)) {
        throw const FormatException('Invalid session import transaction.');
      }
      return session;
    }).toList();
    if (plannedIds.length > maxTransferSessions ||
        originals.length > maxTransferSessions ||
        plannedIds.toSet().length != plannedIds.length ||
        originals.map((session) => session.id).toSet().length !=
            originals.length) {
      throw const FormatException('Invalid session import transaction.');
    }
    final originalsById = {
      for (final session in originals) session.id: session,
    };
    for (final id in plannedIds) {
      tombstoneSession(id);
      final file = await _sessionFile(id);
      if (file != null && await file.exists()) await file.delete();
      if (file != null) {
        final backup = _backupFileFor(file);
        if (await backup.exists()) await backup.delete();
      }
    }
    for (final original in originalsById.values) {
      final file = await _sessionFile(original.id);
      if (file == null) {
        throw const FormatException('Invalid session import transaction.');
      }
      _sessionGenerations[original.id] = sessionGeneration(original.id) + 1;
      _tombstonedSessionIds.remove(original.id);
      _sessionObjectGenerations[original] = sessionGeneration(original.id);
      await _atomicWrite(file, jsonEncode(original.toJson()));
    }
    await marker.delete();
  }

  void _validateImportedSessionJson(Map<String, dynamic> json) {
    const allowed = {
      'id',
      'title',
      'createdAt',
      'updatedAt',
      'messages',
      'modelOverride',
      'apiFormatOverride',
      'systemPrompt',
      'folder',
      'modelGroupId',
      'contextSummary',
      'inFlightAgentRun',
      'pendingWorkspaceImports',
    };
    if (json.keys.toSet().difference(allowed).isNotEmpty ||
        json['id'] is! String ||
        !_validSessionIdPattern.hasMatch(json['id'] as String) ||
        json['title'] is! String ||
        json['messages'] is! List ||
        DateTime.tryParse(json['createdAt']?.toString() ?? '') == null ||
        DateTime.tryParse(json['updatedAt']?.toString() ?? '') == null) {
      throw const FormatException('Invalid imported session.');
    }
  }

  Future<String> _writeImportBackup(List<ChatSession> originals) async {
    final directory = Directory('${_sessionsDir!.path}/.import-backups');
    await directory.create(recursive: true);
    final id = const Uuid().v4();
    final file = File('${directory.path}/$id.json');
    final encoded = jsonEncode({
      'schema': 'clawchat.preimport-backup',
      'version': 1,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'sessions': originals.map((s) => s.toJson()).toList(),
    });
    if (utf8.encode(encoded).length > maxTransferBytes) {
      throw const FormatException('Pre-import backup exceeds limit.');
    }
    await _atomicWrite(file, encoded);
    final decoded = jsonDecode(await file.readAsString()) as Map;
    if (decoded['schema'] != 'clawchat.preimport-backup') {
      throw StateError('Pre-import backup verification failed.');
    }
    await _pruneDirectory(directory, maxEntries: 3);
    return file.path;
  }

  Future<List<SessionTrashEntry>> listTrash() async {
    await init();
    await _pruneTrash();
    final entries = <SessionTrashEntry>[];
    final directory = _trashDirectory;
    if (!await directory.exists()) return entries;
    await for (final entity in directory.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final envelope = await _readTrashEnvelope(entity);
      if (envelope == null || envelope.state != 'trashed') continue;
      entries.add(SessionTrashEntry(
        sessionId: envelope.session.id,
        title: envelope.session.title,
        deletedAt: envelope.deletedAt,
        expiresAt: envelope.expiresAt,
      ));
    }
    entries.sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
    return entries;
  }

  Future<ChatSession?> restoreFromTrash(String id) =>
      _withMutationLock(() async {
        await init();
        final match = await _latestTrashFile(id);
        if (match == null) return null;
        final envelope = await _readTrashEnvelope(match);
        if (envelope == null || envelope.state != 'trashed') return null;
        final restoring = envelope.copyWith(state: 'restoring');
        await _atomicWrite(match, restoring.encode());
        final session = restoring.session;
        if (!isSessionTombstoned(id)) tombstoneSession(id);
        await recreateDeletedSession(session);
        await match.delete();
        return session;
      });

  Future<void> permanentlyDeleteTrash(String id) => _withMutationLock(() async {
        await init();
        final directory = _trashDirectory;
        if (!await directory.exists()) return;
        await for (final entity in directory.list()) {
          if (entity is! File) continue;
          final envelope = await _readTrashEnvelope(entity);
          if (envelope?.session.id == id) await entity.delete();
        }
      });

  Directory get _trashDirectory => Directory('${_sessionsDir!.path}/.trash');

  Future<File> _writeTrashEntry(File source, String id) async {
    final session = await _tryReadSession(source);
    if (session == null || session.id != id) {
      throw StateError('Session cannot be safely moved to trash.');
    }
    final now = DateTime.now().toUtc();
    final safeSession = session.copyWith(
      clearInFlightAgentRun: true,
      pendingWorkspaceImports: const [],
    );
    final envelope = _TrashEnvelope(
      state: 'trashed',
      deletedAt: now,
      expiresAt: now.add(trashRetention),
      session: safeSession,
    );
    final encoded = envelope.encode();
    if (utf8.encode(encoded).length > maxTrashBytes) {
      throw const FormatException('Session is too large for trash retention.');
    }
    final directory = _trashDirectory;
    await directory.create(recursive: true);
    final file = File(
      '${directory.path}/${id}_${now.microsecondsSinceEpoch}.json',
    );
    try {
      await _atomicWrite(file, encoded);
      if (await _readTrashEnvelope(file) == null) {
        throw StateError('Trash verification failed.');
      }
      await _pruneTrash(protectedPath: file.path);
      return file;
    } catch (_) {
      if (await file.exists()) await file.delete();
      rethrow;
    }
  }

  Future<void> _reconcileTrash() async {
    final directory = _trashDirectory;
    if (!await directory.exists()) return;
    await for (final entity in directory.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final envelope = await _readTrashEnvelope(entity);
      if (envelope == null) continue;
      final file = await _sessionFile(envelope.session.id);
      if (file == null) continue;
      if (envelope.state == 'trashed') {
        tombstoneSession(envelope.session.id);
        if (await file.exists()) await file.delete();
        final backup = _backupFileFor(file);
        if (await backup.exists()) await backup.delete();
      } else if (envelope.state == 'restoring') {
        _tombstonedSessionIds.remove(envelope.session.id);
        _sessionGenerations[envelope.session.id] =
            sessionGeneration(envelope.session.id) + 1;
        await _atomicWrite(file, jsonEncode(envelope.session.toJson()));
        await entity.delete();
      }
    }
    await _pruneTrash();
  }

  Future<File?> _latestTrashFile(String id) async {
    final directory = _trashDirectory;
    if (!await directory.exists()) return null;
    final matches = <File>[];
    await for (final entity in directory.list()) {
      if (entity is File &&
          entity.uri.pathSegments.last.startsWith('${id}_') &&
          entity.path.endsWith('.json')) {
        matches.add(entity);
      }
    }
    matches.sort((a, b) => b.path.compareTo(a.path));
    return matches.firstOrNull;
  }

  Future<_TrashEnvelope?> _readTrashEnvelope(File file) async {
    try {
      if (await file.length() > maxTrashBytes) return null;
      return _TrashEnvelope.parse(await file.readAsString());
    } catch (_) {
      return null;
    }
  }

  Future<void> _pruneTrash({String? protectedPath}) async {
    final directory = _trashDirectory;
    if (!await directory.exists()) return;
    final files = await directory
        .list()
        .where((entity) => entity is File && entity.path.endsWith('.json'))
        .cast<File>()
        .toList();
    final now = DateTime.now().toUtc();
    final retained = <({File file, _TrashEnvelope envelope, int size})>[];
    for (final file in files) {
      final envelope = await _readTrashEnvelope(file);
      if (envelope == null) continue;
      if (file.path != protectedPath && envelope.expiresAt.isBefore(now)) {
        await file.delete();
        continue;
      }
      retained.add((file: file, envelope: envelope, size: await file.length()));
    }
    retained.sort(
      (a, b) => b.envelope.deletedAt.compareTo(a.envelope.deletedAt),
    );
    var bytes = 0;
    for (var index = 0; index < retained.length; index += 1) {
      final item = retained[index];
      bytes += item.size;
      if (item.file.path != protectedPath &&
          (index >= maxTrashEntries || bytes > maxTrashBytes)) {
        await item.file.delete();
      }
    }
  }

  Future<void> _pruneDirectory(
    Directory directory, {
    required int maxEntries,
  }) async {
    final files = await directory
        .list()
        .where((entity) => entity is File)
        .cast<File>()
        .toList();
    files
        .sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    for (final file in files.skip(maxEntries)) {
      await file.delete();
    }
  }

  Future<void> _atomicWrite(File file, String value) async {
    final temp = File('${file.path}.tmp-${const Uuid().v4()}');
    await temp.writeAsString(value, flush: true);
    try {
      await temp.rename(file.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  static Future<T> _withMutationLock<T>(Future<T> Function() action) async {
    final previous = _mutationTail;
    final release = Completer<void>();
    _mutationTail = release.future;
    await previous.catchError((_) {});
    try {
      return await action();
    } finally {
      release.complete();
    }
  }
}

final class _ParsedImportEnvelope {
  const _ParsedImportEnvelope(this.version, this.sessions);
  final int version;
  final List sessions;
}

final class _TrashEnvelope {
  const _TrashEnvelope({
    required this.state,
    required this.deletedAt,
    required this.expiresAt,
    required this.session,
  });

  final String state;
  final DateTime deletedAt;
  final DateTime expiresAt;
  final ChatSession session;

  _TrashEnvelope copyWith({required String state}) => _TrashEnvelope(
        state: state,
        deletedAt: deletedAt,
        expiresAt: expiresAt,
        session: session,
      );

  String encode() => jsonEncode({
        'schema': 'clawchat.session-trash',
        'version': 1,
        'state': state,
        'deletedAt': deletedAt.toIso8601String(),
        'expiresAt': expiresAt.toIso8601String(),
        'session': session.toJson(),
      });

  factory _TrashEnvelope.parse(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) throw const FormatException();
    final json = Map<String, dynamic>.from(decoded);
    if (json.keys.toSet().difference(const {
          'schema',
          'version',
          'state',
          'deletedAt',
          'expiresAt',
          'session',
        }).isNotEmpty ||
        json['schema'] != 'clawchat.session-trash' ||
        json['version'] != 1 ||
        !const {'trashed', 'restoring'}.contains(json['state']) ||
        json['session'] is! Map) {
      throw const FormatException();
    }
    final deletedAt = DateTime.parse(json['deletedAt'] as String);
    final expiresAt = DateTime.parse(json['expiresAt'] as String);
    if (!expiresAt.isAfter(deletedAt)) throw const FormatException();
    return _TrashEnvelope(
      state: json['state'] as String,
      deletedAt: deletedAt,
      expiresAt: expiresAt,
      session: ChatSession.fromJson(
        Map<String, dynamic>.from(json['session'] as Map),
      ),
    );
  }
}

final class _SessionCommitToken {
  const _SessionCommitToken({
    required this.guard,
    required this.payloadDigest,
  });

  final SessionCommitGuard guard;
  final String payloadDigest;
}

ChatMessage _deepCopyMessage(ChatMessage message) {
  return ChatMessage.fromJson(
    jsonDecode(jsonEncode(message.toJson())) as Map<String, dynamic>,
  );
}

Map<String, dynamic> _usageSummaryAggregateFromPayloads(List<String> payloads) {
  const service = UsageSummaryService();
  final summaries = <UsageSummary>[];
  var sessionCount = 0;
  for (final payload in payloads) {
    try {
      final session =
          ChatSession.fromJson(jsonDecode(payload) as Map<String, dynamic>);
      sessionCount++;
      summaries.add(service.forSession(session));
    } catch (_) {
      // Skip corrupted session files
    }
  }
  return UsageSummaryAggregate(
    sessionCount: sessionCount,
    summary: service.combine(summaries),
  ).toJson();
}

List<Map<String, dynamic>> _searchSessionPayloads(Map<String, dynamic> args) {
  final query = args['query'] as String;
  final payloads = (args['payloads'] as List)
      .map((item) => Map<String, String>.from(item as Map))
      .toList();
  final results = <Map<String, dynamic>>[];

  for (final payload in payloads) {
    try {
      final session = _decodeSearchSessionPayload(payload);
      if (session == null) continue;
      final titleMatch = session.title.toLowerCase().contains(query);
      String? matchPreview;

      for (final message in session.messages) {
        if (message.isSystemNotice) continue;
        final text = message.textContent;
        if (text.isEmpty) continue;
        if (text.toLowerCase().contains(query)) {
          matchPreview = _searchSnippet(text, query);
          break;
        }
      }

      if (!titleMatch && matchPreview == null) continue;

      results.add({
        'id': session.id,
        'title': session.title,
        'createdAt': session.createdAt.toIso8601String(),
        'updatedAt': session.updatedAt.toIso8601String(),
        if (session.folder != null) 'folder': session.folder,
        if (matchPreview != null) 'matchPreview': matchPreview,
      });
    } catch (_) {
      // Skip corrupted session payloads
    }
  }

  results.sort((a, b) {
    final aUpdated = DateTime.tryParse(a['updatedAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0);
    final bUpdated = DateTime.tryParse(b['updatedAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0);
    return bUpdated.compareTo(aUpdated);
  });
  return results;
}

ChatSession? _decodeSearchSessionPayload(Map<String, String> payload) {
  ChatSession? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return ChatSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  return decode(payload['json']) ?? decode(payload['backupJson']);
}

String _searchSnippet(String text, String query) {
  final compact = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  final lower = compact.toLowerCase();
  final index = lower.indexOf(query);
  if (index < 0) {
    return compact.length > 120 ? '${compact.substring(0, 120)}...' : compact;
  }

  final start = math.max(0, index - 36);
  final end = math.min(compact.length, index + query.length + 72);
  final prefix = start > 0 ? '...' : '';
  final suffix = end < compact.length ? '...' : '';
  return '$prefix${compact.substring(start, end)}$suffix';
}
