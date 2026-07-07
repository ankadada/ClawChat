import 'dart:convert';

import '../memory_service.dart';
import 'tool_registry.dart';

class MemoryGetTool extends Tool {
  @override
  String get name => 'memory_get';

  @override
  String get description =>
      'Read the user-approved cross-session memories available to this session.';

  @override
  Map<String, dynamic> get inputSchema => const {
        'type': 'object',
        'properties': {},
      };

  @override
  Future<String> execute(Map<String, dynamic> input) async {
    if (!MemoryService.isEnabledForCurrentSessionSync()) {
      return jsonEncode({'ok': false, 'error': 'memory_disabled'});
    }
    final memories = await MemoryService.getMemories();
    return jsonEncode({'ok': true, 'memories': memories});
  }
}

class MemoryWriteTool extends Tool {
  @override
  String get name => 'memory_write';

  @override
  String get description =>
      'Request adding a durable user memory. Requires user approval and writes an audit entry.';

  @override
  Map<String, dynamic> get inputSchema => const {
        'type': 'object',
        'properties': {
          'fact': {
            'type': 'string',
            'description': 'The concise fact or preference to remember.',
          },
        },
        'required': ['fact'],
      };

  @override
  Future<String> execute(Map<String, dynamic> input) async {
    if (!MemoryService.isEnabledForCurrentSessionSync()) {
      return jsonEncode({'ok': false, 'error': 'memory_disabled'});
    }
    final fact = input['fact']?.toString() ?? '';
    final result = await MemoryService.addMemory(
      fact,
      source: 'agent_tool',
      sessionId: MemoryService.currentSessionId,
    );
    return jsonEncode({
      'ok': result.added,
      'added': result.added,
      'truncated': result.truncated,
      'index': result.index,
      'count': result.count,
    });
  }
}

class MemoryDeleteTool extends Tool {
  @override
  String get name => 'memory_delete';

  @override
  String get description =>
      'Request deleting a durable user memory by index or exact fact. Requires user approval and writes an audit entry.';

  @override
  Map<String, dynamic> get inputSchema => const {
        'type': 'object',
        'properties': {
          'index': {
            'type': 'integer',
            'description': 'Zero-based memory index to delete.',
          },
          'fact': {
            'type': 'string',
            'description': 'Exact memory text to delete when index is absent.',
          },
        },
      };

  @override
  Future<String> execute(Map<String, dynamic> input) async {
    if (!MemoryService.isEnabledForCurrentSessionSync()) {
      return jsonEncode({'ok': false, 'error': 'memory_disabled'});
    }
    final rawIndex = input['index'];
    final MemoryDeleteResult result;
    if (rawIndex is num) {
      result = await MemoryService.removeMemory(
        rawIndex.toInt(),
        source: 'agent_tool',
        sessionId: MemoryService.currentSessionId,
      );
    } else {
      result = await MemoryService.deleteMemoryText(
        input['fact']?.toString() ?? '',
        source: 'agent_tool',
        sessionId: MemoryService.currentSessionId,
      );
    }
    return jsonEncode({
      'ok': result.deleted,
      'deleted': result.deleted,
      'count': result.count,
    });
  }
}
