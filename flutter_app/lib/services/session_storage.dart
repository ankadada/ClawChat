import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../l10n/app_strings.dart';
import '../models/chat_models.dart';

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
    final targetParentPath = await file.parent.resolveSymbolicLinks();
    if (targetParentPath != sessionsPath) return null;

    final targetPath = file.absolute.path;
    if (!_isInsideSessionsDir(targetPath, sessionsPath)) return null;

    return file;
  }

  Future<String> _canonicalSessionsDirPath() async {
    try {
      return await _sessionsDir!.resolveSymbolicLinks();
    } catch (_) {
      return _sessionsDir!.absolute.path;
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
      try {
        final content = await entity.readAsString();
        sessions.add(ChatSession.fromJson(jsonDecode(content)));
      } catch (_) {
        // Skip corrupted session files
      }
    }
    sessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return sessions;
  }

  Future<List<SessionSummary>> getSessionsSummary() async {
    await init();
    final summaries = <SessionSummary>[];
    await for (final entity in _sessionsDir!.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final content = await entity.readAsString();
        final map = jsonDecode(content) as Map<String, dynamic>;
        final session = ChatSession.fromJson(map);
        summaries.add(SessionSummary(
          id: session.id,
          title: session.title,
          createdAt: session.createdAt,
          updatedAt: session.updatedAt,
          folder: session.folder,
        ));
      } catch (_) {
        // Skip corrupted session files
      }
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
      try {
        payloads.add({'json': await entity.readAsString()});
      } catch (_) {
        // Skip unreadable session files
      }
    }

    final rawResults = await compute(_searchSessionPayloads, {
      'query': normalizedQuery,
      'payloads': payloads,
    });
    return rawResults.map(SessionSearchResult.fromJson).toList();
  }

  Future<ChatSession?> getSession(String id) async {
    await init();
    final file = await _sessionFile(id);
    if (file == null) return null;
    if (!await file.exists()) return null;
    try {
      final content = await file.readAsString();
      return ChatSession.fromJson(jsonDecode(content));
    } catch (_) {
      // Corrupted session file — treat as missing
      return null;
    }
  }

  Future<SessionPreview?> getSessionPreview(String id) async {
    await init();
    final file = await _sessionFile(id);
    if (file == null) return null;
    if (!await file.exists()) return null;
    try {
      final content = await file.readAsString();
      final map = jsonDecode(content) as Map<String, dynamic>;
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
    } catch (_) {
      return null;
    }
  }

  String? _previewTextFromMessage(Object? rawMessage) {
    if (rawMessage is! Map) return null;
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

  Future<void> saveSession(ChatSession session) async {
    await init();
    session.updatedAt = DateTime.now();
    final file = await _sessionFile(session.id);
    if (file == null) {
      throw Exception('Invalid session id');
    }
    await file.writeAsString(jsonEncode(session.toJson()));
  }

  Future<void> deleteSession(String id) async {
    await init();
    final file = await _sessionFile(id);
    if (file == null) return;
    if (await file.exists()) await file.delete();
  }

  Future<ChatSession?> forkSession(String sessionId, int upToMessageIndex) async {
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
    for (final session in sessions) {
      if (!_validSessionIdPattern.hasMatch(session.id)) continue;
      final file = await _sessionFile(session.id);
      if (file == null) continue;
      await saveSession(session);
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

List<Map<String, dynamic>> _searchSessionPayloads(Map<String, dynamic> args) {
  final query = args['query'] as String;
  final payloads = (args['payloads'] as List)
      .map((item) => Map<String, String>.from(item as Map))
      .toList();
  final results = <Map<String, dynamic>>[];

  for (final payload in payloads) {
    try {
      final session = ChatSession.fromJson(
        jsonDecode(payload['json']!) as Map<String, dynamic>,
      );
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
