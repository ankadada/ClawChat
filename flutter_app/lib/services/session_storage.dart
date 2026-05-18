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
  final String? folder;

  SessionSummary({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.folder,
  });
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
