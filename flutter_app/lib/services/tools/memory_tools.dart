import 'dart:convert';

import '../memory_service.dart';
import 'tool_registry.dart';
import '../../models/chat_models.dart';
import 'untrusted_data_policy.dart';
import 'tool_result_formatter.dart';

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
    return executeWithContext(input);
  }

  @override
  Future<String> executeWithContext(
    Map<String, dynamic> input, {
    String? sessionId,
  }) async {
    await MemoryService.ensureSessionModesLoaded();
    if (!MemoryService.isEnabledForSessionSync(sessionId)) {
      return jsonEncode({'ok': false, 'error': 'memory_disabled'});
    }
    final memories = await MemoryService.getMemories();
    final untrusted =
        await MemoryService.untrustedMemoriesForSession(sessionId);
    return jsonEncode({
      'ok': true,
      'memories': memories,
      // Facts written from untrusted tool data stay untrusted; the agent loop
      // re-seeds the run taint set from these instead of laundering them.
      if (untrusted.isNotEmpty)
        'untrustedMemories': [
          for (final entry in untrusted) entry['text'],
        ],
    });
  }

  @override
  Future<ToolResultPayload> executeResult(
    Map<String, dynamic> input, {
    String? sessionId,
    RunTaintSet? runTaintSet,
  }) async {
    final payload = await super.executeResult(
      input,
      sessionId: sessionId,
      runTaintSet: runTaintSet,
    );
    final untrusted =
        await MemoryService.untrustedMemoriesForSession(sessionId);
    if (untrusted.isEmpty) return payload;
    return payload.copyWith(metadata: {
      ...payload.metadata,
      'toolName': name,
      'untrustedValues': untrusted,
    });
  }
}

class MemoryWriteTool extends Tool {
  static const structuredActionInputSchema = <String, dynamic>{
    'type': 'object',
    'additionalProperties': false,
    'properties': {
      'fact': {
        'type': 'string',
        'description': 'The concise fact or preference to remember.',
        'minLength': 1,
        'maxLength': 2000,
      },
    },
    'required': ['fact'],
  };

  @override
  String get name => 'memory_write';

  @override
  String get description =>
      'Request adding a durable user memory; writes an audit entry when executed. The app may ask for confirmation depending on the tool approval policy.';

  @override
  Map<String, dynamic> get inputSchema => structuredActionInputSchema;

  /// The structured-action registry checks this exact, app-owned shape before
  /// dispatching.  A same-named plugin/tool cannot quietly widen the v2.7
  /// `save_to_memory` input surface.
  static bool isStructuredActionCompatibleSchema(Map<String, dynamic> schema) {
    if (schema['type'] != 'object' ||
        schema['additionalProperties'] != false ||
        schema['required'] is! List ||
        (schema['required'] as List).length != 1 ||
        (schema['required'] as List).single != 'fact') {
      return false;
    }
    final properties = schema['properties'];
    if (properties is! Map || properties.length != 1) return false;
    final fact = properties['fact'];
    return fact is Map &&
        fact['type'] == 'string' &&
        fact['minLength'] == 1 &&
        fact['maxLength'] == 2000;
  }

  /// The legacy adapter returns JSON, rather than throwing, for known memory
  /// outcomes.  Treat malformed/disabled results as failure; a duplicate fact
  /// is a known successful idempotent outcome and may be safely acknowledged.
  static bool isKnownSuccessfulOutput(String output) {
    try {
      final value = jsonDecode(output);
      if (value is! Map || value['ok'] != true) return false;
      return value['added'] is bool &&
          value['index'] is int &&
          (value['index'] as int) >= 0 &&
          value['count'] is int &&
          (value['count'] as int) > 0;
    } on FormatException {
      return false;
    }
  }

  @override
  Future<String> execute(Map<String, dynamic> input) async {
    return executeWithContext(input);
  }

  @override
  Future<ToolResultPayload> executeResult(
    Map<String, dynamic> input, {
    String? sessionId,
    RunTaintSet? runTaintSet,
  }) async {
    final output = await _write(
      input,
      sessionId: sessionId,
      runTaintSet: runTaintSet,
    );
    return ToolResultFormatter.format(
      toolName: name,
      input: input,
      output: output,
    );
  }

  @override
  Future<String> executeWithContext(
    Map<String, dynamic> input, {
    String? sessionId,
  }) =>
      _write(input, sessionId: sessionId, runTaintSet: null);

  Future<String> _write(
    Map<String, dynamic> input, {
    String? sessionId,
    RunTaintSet? runTaintSet,
  }) async {
    await MemoryService.ensureSessionModesLoaded();
    if (!MemoryService.isEnabledForSessionSync(sessionId)) {
      await MemoryService.auditMemoryToolRejected(
        name,
        source: 'agent_tool',
        sessionId: sessionId,
        reason: 'memory_disabled',
      );
      return jsonEncode({'ok': false, 'error': 'memory_disabled'});
    }
    final fact = input['fact']?.toString() ?? '';
    final result = await MemoryService.addMemory(
      fact,
      source: 'agent_tool',
      sessionId: sessionId,
      // The calling run's taint set decides whether this fact stays untrusted.
      runTaintSet: runTaintSet,
    );
    return jsonEncode({
      // A duplicate means this exact local memory is already durable; it is a
      // known idempotent success for a user-initiated structured retry.
      'ok': result.added || result.index >= 0,
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
      'Request deleting a durable user memory by index or exact fact; writes an audit entry when executed. The app may ask for confirmation depending on the tool approval policy.';

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
    return executeWithContext(input);
  }

  @override
  Future<String> executeWithContext(
    Map<String, dynamic> input, {
    String? sessionId,
  }) async {
    await MemoryService.ensureSessionModesLoaded();
    if (!MemoryService.isEnabledForSessionSync(sessionId)) {
      await MemoryService.auditMemoryToolRejected(
        name,
        source: 'agent_tool',
        sessionId: sessionId,
        reason: 'memory_disabled',
      );
      return jsonEncode({'ok': false, 'error': 'memory_disabled'});
    }
    final rawIndex = input['index'];
    final MemoryDeleteResult result;
    if (rawIndex is num) {
      result = await MemoryService.removeMemory(
        rawIndex.toInt(),
        source: 'agent_tool',
        sessionId: sessionId,
      );
    } else {
      result = await MemoryService.deleteMemoryText(
        input['fact']?.toString() ?? '',
        source: 'agent_tool',
        sessionId: sessionId,
      );
    }
    return jsonEncode({
      'ok': result.deleted,
      'deleted': result.deleted,
      'count': result.count,
    });
  }
}
