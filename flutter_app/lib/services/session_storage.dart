import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
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

class SessionStorage {
  static final _validSessionIdPattern = RegExp(r'^[a-zA-Z0-9_-]+$');

  Directory? _sessionsDir;

  Future<void> init() async {
    if (_sessionsDir != null) return;
    final appDir = await getApplicationDocumentsDirectory();
    _sessionsDir = Directory('${appDir.path}/clawchat_sessions');
    if (!await _sessionsDir!.exists()) {
      await _sessionsDir!.create(recursive: true);
    }
    // One-time migration from SharedPreferences
    await _migrateFromSharedPreferences();
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
      if (_validSessionIdPattern.hasMatch(id)) ids.add(id);
    }
    return ids;
  }

  Future<List<ChatSession>> getAllSessions() async {
    await init();
    final sessions = <ChatSession>[];
    await for (final entity in _sessionsDir!.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final id = _idFromSessionFile(entity);
      if (id == null) continue;
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
      if (id == null) continue;
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
      if (id == null) continue;
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
      if (id == null) continue;
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
    await init();
    final file = await _sessionFile(id);
    if (file == null) return null;
    return _readSessionWithBackupRecovery(file);
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

  Future<void> saveSession(ChatSession session) async {
    await init();
    session.updatedAt = DateTime.now();
    final file = await _sessionFile(session.id);
    if (file == null) {
      throw Exception('Invalid session id');
    }
    final payload = jsonEncode(session.toJson());
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

      if (await file.exists()) {
        final previous = await _tryReadSession(file);
        if (previous != null) {
          await file.copy(_backupFileFor(file).path);
        }
      }
      await temp.rename(file.path);
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

  Future<void> deleteSession(String id) async {
    await init();
    final file = await _sessionFile(id);
    if (file == null) return;
    if (await file.exists()) await file.delete();
    final backup = _backupFileFor(file);
    if (await backup.exists()) await backup.delete();
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
    await for (final entity in _sessionsDir!.list()) {
      if (entity is File) await entity.delete();
    }
  }

  Future<String> exportAllAsJson() async {
    final sessions = await getAllSessions();
    final data = sessions.map((s) => s.toJson()).toList();
    return jsonEncode({'version': 1, 'sessions': data});
  }

  Future<int> importFromJson(String jsonStr) async {
    final data = jsonDecode(jsonStr) as Map<String, dynamic>;
    final sessions = (data['sessions'] as List)
        .map((j) => ChatSession.fromJson(j as Map<String, dynamic>))
        .toList();
    int count = 0;
    final usedIds = (await getSessionIds()).toSet();
    for (final session in sessions) {
      var sessionToSave = session;
      if (usedIds.contains(sessionToSave.id)) {
        sessionToSave = sessionToSave.copyWith(
          id: const Uuid().v4(),
          title: '${sessionToSave.title} (imported copy)',
        );
      }
      while (usedIds.contains(sessionToSave.id)) {
        sessionToSave = sessionToSave.copyWith(id: const Uuid().v4());
      }
      if (!_validSessionIdPattern.hasMatch(sessionToSave.id)) continue;
      final file = await _sessionFile(sessionToSave.id);
      if (file == null) continue;
      await saveSession(sessionToSave);
      usedIds.add(sessionToSave.id);
      count++;
    }
    return count;
  }
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
