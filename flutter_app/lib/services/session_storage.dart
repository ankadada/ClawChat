import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/chat_models.dart';

class SessionSummary {
  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;

  SessionSummary({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
  });
}

class SessionStorage {
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

  File _sessionFile(String id) => File('${_sessionsDir!.path}/$id.json');

  /// Migrates existing sessions from SharedPreferences to individual JSON files.
  /// After migration, the SharedPreferences keys are removed.
  Future<void> _migrateFromSharedPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList('clawchat_session_ids');
    if (ids == null || ids.isEmpty) return;

    for (final id in ids) {
      final json = prefs.getString('clawchat_session_$id');
      if (json == null) continue;
      final file = _sessionFile(id);
      if (!await file.exists()) {
        await file.writeAsString(json);
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
      ids.add(filename.substring(0, filename.length - 5)); // strip .json
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
        summaries.add(SessionSummary(
          id: map['id'] as String,
          title: map['title'] as String? ?? '新对话',
          createdAt: DateTime.parse(map['createdAt'] as String),
          updatedAt: DateTime.parse(map['updatedAt'] as String),
        ));
      } catch (_) {
        // Skip corrupted session files
      }
    }
    summaries.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return summaries;
  }

  Future<ChatSession?> getSession(String id) async {
    await init();
    final file = _sessionFile(id);
    if (!await file.exists()) return null;
    try {
      final content = await file.readAsString();
      return ChatSession.fromJson(jsonDecode(content));
    } catch (_) {
      // Corrupted session file — treat as missing
      return null;
    }
  }

  Future<void> saveSession(ChatSession session) async {
    await init();
    session.updatedAt = DateTime.now();
    final file = _sessionFile(session.id);
    await file.writeAsString(jsonEncode(session.toJson()));
  }

  Future<void> deleteSession(String id) async {
    await init();
    final file = _sessionFile(id);
    if (await file.exists()) await file.delete();
  }

  Future<void> clearAll() async {
    await init();
    await for (final entity in _sessionsDir!.list()) {
      if (entity is File) await entity.delete();
    }
  }
}
