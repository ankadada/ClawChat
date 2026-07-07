import 'dart:convert';
import 'native_bridge.dart';
import 'preferences_service.dart';

enum SessionMemoryMode { followGlobal, enabled, disabled }

class MemoryWriteResult {
  final bool added;
  final bool truncated;
  final int index;
  final int count;

  const MemoryWriteResult({
    required this.added,
    required this.truncated,
    required this.index,
    required this.count,
  });
}

class MemoryDeleteResult {
  final bool deleted;
  final int count;

  const MemoryDeleteResult({
    required this.deleted,
    required this.count,
  });
}

/// Cross-session memory service.
///
/// Stores user-provided facts/preferences that should be remembered across
/// all conversations.
///
/// Integration: In ChatProvider.sendMessage(), append MemoryService.buildMemoryPrompt()
/// to the system prompt before sending to the LLM.
class MemoryService {
  static const _memoryPath = 'root/.clawchat_memory.json';
  static const _sessionMemoryPath = 'root/.clawchat_memory_sessions.json';
  static const _auditPath = 'root/.clawchat_memory_audit.jsonl';
  static const maxMemoryEntries = 100;
  static const maxMemoryBytes = 64 * 1024;
  static const maxMemoryChars = 2000;
  static List<String> _cachedMemories = [];
  static Map<String, SessionMemoryMode> _sessionModes = {};
  static bool _loaded = false;
  static bool _sessionModesLoaded = false;
  static String? _currentSessionId;

  static String? get currentSessionId => _currentSessionId;

  static void setCurrentSessionId(String? sessionId) {
    _currentSessionId = sessionId;
  }

  static Future<List<String>> getMemories() async {
    await _loadSessionModes();
    if (!_loaded) {
      try {
        final content = await NativeBridge.readRootfsFile(_memoryPath);
        if (content != null && content.isNotEmpty) {
          _cachedMemories = _sanitizeMemoryList(jsonDecode(content));
        }
      } catch (_) {}
      _enforceLimits();
      _loaded = true;
    }
    return List.unmodifiable(_cachedMemories);
  }

  static Future<MemoryWriteResult> addMemory(
    String fact, {
    String source = 'settings',
    String? sessionId,
  }) async {
    await getMemories();
    final normalized = _normalizeMemory(fact);
    if (normalized.text.isEmpty) {
      return MemoryWriteResult(
        added: false,
        truncated: normalized.truncated,
        index: -1,
        count: _cachedMemories.length,
      );
    }
    final existingIndex = _cachedMemories.indexOf(normalized.text);
    if (existingIndex >= 0) {
      await _audit('memory_write_duplicate', source, sessionId, {
        'index': existingIndex,
      });
      return MemoryWriteResult(
        added: false,
        truncated: normalized.truncated,
        index: existingIndex,
        count: _cachedMemories.length,
      );
    }
    _cachedMemories.add(normalized.text);
    _enforceLimits();
    await _save();
    final index = _cachedMemories.indexOf(normalized.text);
    await _audit('memory_write', source, sessionId, {
      'index': index,
      'truncated': normalized.truncated,
      'count': _cachedMemories.length,
    });
    return MemoryWriteResult(
      added: true,
      truncated: normalized.truncated,
      index: index,
      count: _cachedMemories.length,
    );
  }

  static Future<MemoryDeleteResult> removeMemory(
    int index, {
    String source = 'settings',
    String? sessionId,
  }) async {
    await getMemories();
    if (index >= 0 && index < _cachedMemories.length) {
      _cachedMemories.removeAt(index);
      await _save();
      await _audit('memory_delete', source, sessionId, {
        'index': index,
        'count': _cachedMemories.length,
      });
      return MemoryDeleteResult(deleted: true, count: _cachedMemories.length);
    }
    return MemoryDeleteResult(deleted: false, count: _cachedMemories.length);
  }

  static Future<MemoryDeleteResult> deleteMemoryText(
    String fact, {
    String source = 'agent_tool',
    String? sessionId,
  }) async {
    await getMemories();
    final normalized = _normalizeMemory(fact).text;
    final index = _cachedMemories.indexOf(normalized);
    return removeMemory(index, source: source, sessionId: sessionId);
  }

  static Future<SessionMemoryMode> getSessionMemoryMode(
    String sessionId,
  ) async {
    await _loadSessionModes();
    return _sessionModes[sessionId] ?? SessionMemoryMode.followGlobal;
  }

  static Future<void> setSessionMemoryMode(
    String sessionId,
    SessionMemoryMode mode,
  ) async {
    await _loadSessionModes();
    if (mode == SessionMemoryMode.followGlobal) {
      _sessionModes.remove(sessionId);
    } else {
      _sessionModes[sessionId] = mode;
    }
    await _saveSessionModes();
  }

  static bool isEnabledForCurrentSessionSync() {
    final global = PreferencesService().memoryEnabled;
    final sessionId = _currentSessionId;
    if (sessionId == null || sessionId.isEmpty) return global;
    final mode = _sessionModes[sessionId] ?? SessionMemoryMode.followGlobal;
    return switch (mode) {
      SessionMemoryMode.followGlobal => global,
      SessionMemoryMode.enabled => true,
      SessionMemoryMode.disabled => false,
    };
  }

  static Future<void> _save() async {
    await NativeBridge.writeRootfsFile(
        _memoryPath, jsonEncode(_cachedMemories));
  }

  static String buildMemoryPrompt() {
    if (!isEnabledForCurrentSessionSync() || _cachedMemories.isEmpty) {
      return '';
    }
    final memoryList = _cachedMemories.map((m) => '- $m').join('\n');
    return '\n\nUser memories (facts the user asked you to remember):\n$memoryList';
  }

  static Future<void> _loadSessionModes() async {
    if (_sessionModesLoaded) return;
    try {
      final content = await NativeBridge.readRootfsFile(_sessionMemoryPath);
      final decoded = content == null || content.isEmpty
          ? const <String, dynamic>{}
          : jsonDecode(content);
      if (decoded is Map) {
        _sessionModes = {
          for (final entry in decoded.entries)
            if (_sessionModeFromJson(entry.value) != null)
              entry.key.toString(): _sessionModeFromJson(entry.value)!,
        };
      }
    } catch (_) {
      _sessionModes = {};
    }
    _sessionModesLoaded = true;
  }

  static Future<void> _saveSessionModes() async {
    final encoded = {
      for (final entry in _sessionModes.entries) entry.key: entry.value.name,
    };
    await NativeBridge.writeRootfsFile(_sessionMemoryPath, jsonEncode(encoded));
  }

  static SessionMemoryMode? _sessionModeFromJson(Object? value) {
    final text = value?.toString();
    if (text == null || text.isEmpty) return null;
    for (final mode in SessionMemoryMode.values) {
      if (mode.name == text) return mode;
    }
    return null;
  }

  static ({String text, bool truncated}) _normalizeMemory(String fact) {
    final trimmed = fact.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (trimmed.runes.length <= maxMemoryChars) {
      return (text: trimmed, truncated: false);
    }
    final truncated =
        String.fromCharCodes(trimmed.runes.take(maxMemoryChars - 3));
    return (text: '$truncated...', truncated: true);
  }

  static List<String> _sanitizeMemoryList(Object? value) {
    if (value is! List) return const [];
    return value
        .map((item) => _normalizeMemory(item?.toString() ?? '').text)
        .where((item) => item.isNotEmpty)
        .toSet()
        .toList();
  }

  static void _enforceLimits() {
    if (_cachedMemories.length > maxMemoryEntries) {
      _cachedMemories =
          _cachedMemories.sublist(_cachedMemories.length - maxMemoryEntries);
    }
    while (_cachedMemories.length > 1 &&
        utf8.encode(jsonEncode(_cachedMemories)).length > maxMemoryBytes) {
      _cachedMemories.removeAt(0);
    }
  }

  static Future<void> _audit(
    String event,
    String source,
    String? sessionId,
    Map<String, Object?> data,
  ) async {
    final entry = jsonEncode({
      'ts': DateTime.now().toUtc().toIso8601String(),
      'event': event,
      'source': source,
      if (sessionId?.isNotEmpty == true) 'sessionId': sessionId,
      ...data,
    });
    try {
      final previous = await NativeBridge.readRootfsFile(_auditPath);
      final content = previous == null || previous.isEmpty
          ? '$entry\n'
          : '$previous$entry\n';
      await NativeBridge.writeRootfsFile(_auditPath, content);
    } catch (_) {
      // Audit failures should never block the user's explicit memory action.
    }
  }

  static void resetForTesting() {
    _cachedMemories = [];
    _sessionModes = {};
    _loaded = false;
    _sessionModesLoaded = false;
    _currentSessionId = null;
  }
}
