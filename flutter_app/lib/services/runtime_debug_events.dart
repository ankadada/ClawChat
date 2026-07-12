import 'llm_content_sanitizer.dart';

class RuntimeDebugEvent {
  final DateTime timestamp;
  final String type;
  final String sessionId;
  final String? traceId;
  final Map<String, Object?> data;

  RuntimeDebugEvent({
    DateTime? timestamp,
    required String type,
    required String sessionId,
    String? traceId,
    Map<String, Object?> data = const {},
  })  : timestamp = timestamp ?? DateTime.now(),
        type = RuntimeDebugEventService._normalizeEventType(type),
        sessionId = RuntimeDebugEventService._safeSessionId(sessionId),
        traceId = RuntimeDebugEventService._safeOptionalCorrelationId(traceId),
        data = RuntimeDebugEventService.sanitizeEventData(type, data);
}

enum RunTraceStatus { inFlight, completed, failed, cancelled, interrupted }

extension RunTraceStatusWireValue on RunTraceStatus {
  String get wireValue => switch (this) {
        RunTraceStatus.inFlight => 'in_flight',
        RunTraceStatus.completed => 'completed',
        RunTraceStatus.failed => 'failed',
        RunTraceStatus.cancelled => 'cancelled',
        RunTraceStatus.interrupted => 'interrupted',
      };
}

class RunTraceEvent {
  final int sequence;
  final DateTime timestamp;
  final String type;
  final Map<String, Object?> data;

  const RunTraceEvent({
    required this.sequence,
    required this.timestamp,
    required this.type,
    this.data = const {},
  });
}

class RunTraceSnapshot {
  static const schemaVersion = 1;

  final String traceId;
  final String sessionId;
  final DateTime startedAt;
  final DateTime? endedAt;
  final RunTraceStatus status;
  final List<RunTraceEvent> events;

  const RunTraceSnapshot({
    required this.traceId,
    required this.sessionId,
    required this.startedAt,
    required this.endedAt,
    required this.status,
    required this.events,
  });

  Duration get duration => (endedAt ?? DateTime.now()).difference(startedAt);
}

class _MutableRunTrace {
  final String traceId;
  final String sessionId;
  final DateTime startedAt;
  DateTime? endedAt;
  RunTraceStatus status = RunTraceStatus.inFlight;
  final List<RunTraceEvent> events = [];

  _MutableRunTrace({
    required this.traceId,
    required this.sessionId,
    required this.startedAt,
  });

  RunTraceSnapshot snapshot() => RunTraceSnapshot(
        traceId: traceId,
        sessionId: sessionId,
        startedAt: startedAt,
        endedAt: endedAt,
        status: status,
        events: List<RunTraceEvent>.unmodifiable(events),
      );
}

enum _RuntimeDebugValueKind {
  boolean,
  count,
  attempt,
  durationMs,
  tokenCount,
  decimal,
  code,
  errorCode,
  reasonCode,
  mode,
  trigger,
  providerKind,
  profileLabel,
  modelLabel,
  modelGroupLabel,
  toolName,
  correlationId,
  risk,
  lifecycle,
  status,
  completeness,
  stage,
  warningCode,
}

class RuntimeDebugEventService {
  static const defaultCapacity = 500;
  static const maxStringLength = 200;
  static const defaultTraceCapacity = 50;
  static const defaultTraceEventCapacity = 120;

  /// The only metadata fields accepted into memory for each event type.
  /// Values are also type-checked and bounded by [_RuntimeDebugValueKind].
  /// Unknown event types become `debug.unknown` with an empty data map.
  static const Map<String, Map<String, _RuntimeDebugValueKind>> _eventSchemas =
      {
    'run.started': {
      'runAttemptId': _RuntimeDebugValueKind.correlationId,
      'trigger': _RuntimeDebugValueKind.trigger,
      'profileLabel': _RuntimeDebugValueKind.profileLabel,
      'providerKind': _RuntimeDebugValueKind.providerKind,
      'modelLabel': _RuntimeDebugValueKind.modelLabel,
      'modelGroupLabel': _RuntimeDebugValueKind.modelGroupLabel,
    },
    'run.terminal': {
      'status': _RuntimeDebugValueKind.status,
      'errorCode': _RuntimeDebugValueKind.errorCode,
      'durationMs': _RuntimeDebugValueKind.durationMs,
    },
    'context.assembly.started': {
      'mode': _RuntimeDebugValueKind.mode,
      'autoCompact': _RuntimeDebugValueKind.boolean,
      'messageCount': _RuntimeDebugValueKind.count,
    },
    'context.assembly.completed': {
      'mode': _RuntimeDebugValueKind.mode,
      'durationMs': _RuntimeDebugValueKind.durationMs,
      'messageCount': _RuntimeDebugValueKind.count,
      'generated': _RuntimeDebugValueKind.boolean,
      'reused': _RuntimeDebugValueKind.boolean,
      'failed': _RuntimeDebugValueKind.boolean,
      'coveredMessageCount': _RuntimeDebugValueKind.count,
      'droppedMessageCount': _RuntimeDebugValueKind.count,
      'droppedBlockCount': _RuntimeDebugValueKind.count,
      'finalTokenBudget': _RuntimeDebugValueKind.tokenCount,
      'compressedToolResultCount': _RuntimeDebugValueKind.count,
    },
    'context.summary.reused': {
      'mode': _RuntimeDebugValueKind.mode,
      'coveredMessageCount': _RuntimeDebugValueKind.count,
      'summaryEstimatedTokens': _RuntimeDebugValueKind.tokenCount,
    },
    'context.summary.manual.generated': {
      'coveredMessageCount': _RuntimeDebugValueKind.count,
      'sourceEstimatedTokens': _RuntimeDebugValueKind.tokenCount,
      'summaryEstimatedTokens': _RuntimeDebugValueKind.tokenCount,
      'fallback': _RuntimeDebugValueKind.boolean,
    },
    'context.summary.manual.failed': {
      'stage': _RuntimeDebugValueKind.stage,
      'errorCode': _RuntimeDebugValueKind.errorCode,
    },
    'context.summary.generated': {
      'coveredMessageCount': _RuntimeDebugValueKind.count,
      'sourceEstimatedTokens': _RuntimeDebugValueKind.tokenCount,
      'summaryEstimatedTokens': _RuntimeDebugValueKind.tokenCount,
      'reused': _RuntimeDebugValueKind.boolean,
    },
    'context.summary.failed': {
      'stage': _RuntimeDebugValueKind.stage,
      'errorCode': _RuntimeDebugValueKind.errorCode,
    },
    'context.summary.stale': {
      'reason': _RuntimeDebugValueKind.reasonCode,
      'coveredMessageCount': _RuntimeDebugValueKind.count,
      'summaryEstimatedTokens': _RuntimeDebugValueKind.tokenCount,
    },
    'context.summary.manual.cleared': {
      'messageCount': _RuntimeDebugValueKind.count,
    },
    'context.truncated': {
      'droppedMessageCount': _RuntimeDebugValueKind.count,
      'droppedBlockCount': _RuntimeDebugValueKind.count,
      'estimatedTokens': _RuntimeDebugValueKind.tokenCount,
      'maxTokens': _RuntimeDebugValueKind.tokenCount,
      'overBudgetAfterTruncation': _RuntimeDebugValueKind.boolean,
    },
    'tool_result.compressed': {
      'compressedCount': _RuntimeDebugValueKind.count,
      'protectedTurnCount': _RuntimeDebugValueKind.count,
      'thresholdTokens': _RuntimeDebugValueKind.tokenCount,
    },
    'llm.sensitive_data_redacted': {
      'stage': _RuntimeDebugValueKind.stage,
      'totalCount': _RuntimeDebugValueKind.count,
    },
    'provider.transform.warning': {
      'warningCount': _RuntimeDebugValueKind.count,
      'warningCode': _RuntimeDebugValueKind.warningCode,
      'droppedBlockCount': _RuntimeDebugValueKind.count,
    },
    'token.calibration.updated': {
      'oldMultiplier': _RuntimeDebugValueKind.decimal,
      'ratio': _RuntimeDebugValueKind.decimal,
      'newMultiplier': _RuntimeDebugValueKind.decimal,
    },
    'token.calibration.skipped': {
      'reason': _RuntimeDebugValueKind.reasonCode,
      'estimatedInputTokens': _RuntimeDebugValueKind.tokenCount,
      'actualInputTokens': _RuntimeDebugValueKind.tokenCount,
    },
    'tool.execution.denied': {
      'runAttemptId': _RuntimeDebugValueKind.correlationId,
      'operationId': _RuntimeDebugValueKind.correlationId,
      'ruleType': _RuntimeDebugValueKind.code,
      'ruleId': _RuntimeDebugValueKind.code,
    },
    'tool.preflight.repaired': {
      'repairCount': _RuntimeDebugValueKind.count,
      'jsonClosureRepairCount': _RuntimeDebugValueKind.count,
      'fieldNameRepairCount': _RuntimeDebugValueKind.count,
      'typeCoercionRepairCount': _RuntimeDebugValueKind.count,
    },
    'chat.recovery.invalid_encrypted_content': {
      'retried': _RuntimeDebugValueKind.boolean,
      'success': _RuntimeDebugValueKind.boolean,
      'stage': _RuntimeDebugValueKind.stage,
    },
    'chat.run.cancelled': {
      'runAttemptId': _RuntimeDebugValueKind.correlationId,
      'lifecycle': _RuntimeDebugValueKind.lifecycle,
    },
    'model.fallback.skipped': {
      'reason': _RuntimeDebugValueKind.reasonCode,
      'primaryReason': _RuntimeDebugValueKind.reasonCode,
      'candidate': _RuntimeDebugValueKind.modelLabel,
      'attemptIndex': _RuntimeDebugValueKind.attempt,
    },
    'model.fallback.attempt': {
      'primary': _RuntimeDebugValueKind.modelLabel,
      'candidate': _RuntimeDebugValueKind.modelLabel,
      'reason': _RuntimeDebugValueKind.reasonCode,
      'attemptIndex': _RuntimeDebugValueKind.attempt,
    },
    'model.fallback.success': {
      'primary': _RuntimeDebugValueKind.modelLabel,
      'fallback': _RuntimeDebugValueKind.modelLabel,
      'reason': _RuntimeDebugValueKind.reasonCode,
      'attemptIndex': _RuntimeDebugValueKind.attempt,
    },
    'model.fallback.failed': {
      'candidate': _RuntimeDebugValueKind.modelLabel,
      'reason': _RuntimeDebugValueKind.reasonCode,
      'attemptIndex': _RuntimeDebugValueKind.attempt,
    },
    'model.attempt.started': {
      'attempt': _RuntimeDebugValueKind.attempt,
      'modelLabel': _RuntimeDebugValueKind.modelLabel,
    },
    'stream.started': {
      'attempt': _RuntimeDebugValueKind.attempt,
      'latencyMs': _RuntimeDebugValueKind.durationMs,
    },
    'stream.terminal': {
      'attempt': _RuntimeDebugValueKind.attempt,
      'status': _RuntimeDebugValueKind.status,
      'completeness': _RuntimeDebugValueKind.completeness,
      'durationMs': _RuntimeDebugValueKind.durationMs,
      'streamResetCount': _RuntimeDebugValueKind.count,
      'errorCode': _RuntimeDebugValueKind.errorCode,
      'inputTokens': _RuntimeDebugValueKind.tokenCount,
      'outputTokens': _RuntimeDebugValueKind.tokenCount,
      'cacheReadInputTokens': _RuntimeDebugValueKind.tokenCount,
      'cacheCreationInputTokens': _RuntimeDebugValueKind.tokenCount,
      'inputTokensIncludeCache': _RuntimeDebugValueKind.boolean,
      'hadToolCalls': _RuntimeDebugValueKind.boolean,
    },
    'stream.reset': {
      'attempt': _RuntimeDebugValueKind.attempt,
      'count': _RuntimeDebugValueKind.count,
      'completeness': _RuntimeDebugValueKind.completeness,
    },
  };

  static const Map<String, _RuntimeDebugValueKind> _toolAttemptSchema = {
    'runAttemptId': _RuntimeDebugValueKind.correlationId,
    'operationId': _RuntimeDebugValueKind.correlationId,
    'toolName': _RuntimeDebugValueKind.toolName,
    'risk': _RuntimeDebugValueKind.risk,
    'lifecycle': _RuntimeDebugValueKind.lifecycle,
  };

  static const _toolAttemptEventTypes = {
    'tool.attempt.proposed',
    'tool.attempt.approvalPending',
    'tool.attempt.approvedNotStarted',
    'tool.attempt.started',
    'tool.attempt.completed',
    'tool.attempt.failed',
    'tool.attempt.interruptedUnknown',
    'tool.attempt.resultPersisted',
  };

  /// Run traces intentionally remain memory-only. Persisting them beside chat
  /// recovery state would expand the privacy and migration surface for data
  /// that is useful only during an active Developer Mode debugging session.
  final int traceCapacity;
  final int traceEventCapacity;

  final int capacity;
  final List<RuntimeDebugEvent> _events = [];
  final List<_MutableRunTrace> _traces = [];
  final Map<String, String> _activeTraceBySession = {};
  int _traceCounter = 0;
  bool _tracingEnabled;

  RuntimeDebugEventService({
    this.capacity = defaultCapacity,
    this.traceCapacity = defaultTraceCapacity,
    this.traceEventCapacity = defaultTraceEventCapacity,
    bool tracingEnabled = false,
  }) : _tracingEnabled = tracingEnabled;

  bool get tracingEnabled => _tracingEnabled;

  void setTracingEnabled(bool enabled) {
    if (_tracingEnabled == enabled) {
      if (!enabled) {
        clear();
        clearRunTraces();
      }
      return;
    }
    _tracingEnabled = false;
    clear();
    clearRunTraces();
    _tracingEnabled = enabled;
  }

  String? startRunTrace(
    String sessionId, {
    Map<String, Object?> data = const {},
    DateTime? timestamp,
  }) {
    if (!_tracingEnabled || traceCapacity <= 0 || traceEventCapacity <= 0) {
      return null;
    }
    final safeSessionId = _safeSessionId(sessionId);
    final now = timestamp ?? DateTime.now();
    final previousId = _activeTraceBySession[safeSessionId];
    if (previousId != null) {
      finishRunTrace(
        previousId,
        RunTraceStatus.interrupted,
        errorCode: 'superseded_by_new_run',
        timestamp: now,
      );
    }
    _traceCounter++;
    final traceId =
        'run-${now.toUtc().microsecondsSinceEpoch}-${_traceCounter.toRadixString(36)}';
    final trace = _MutableRunTrace(
      traceId: traceId,
      sessionId: safeSessionId,
      startedAt: now,
    );
    _traces.add(trace);
    _activeTraceBySession[safeSessionId] = traceId;
    _appendTraceEvent(trace, 'run.started', data, now);
    _evictOldTraces();
    return traceId;
  }

  void finishRunTrace(
    String traceId,
    RunTraceStatus status, {
    String? errorCode,
    DateTime? timestamp,
  }) {
    final trace = _traceForId(traceId);
    if (trace == null || trace.status != RunTraceStatus.inFlight) return;
    final terminalStatus =
        status == RunTraceStatus.inFlight ? RunTraceStatus.interrupted : status;
    final now = timestamp ?? DateTime.now();
    _appendTraceEvent(
        trace,
        'run.terminal',
        {
          'status': terminalStatus.wireValue,
          if (errorCode != null) 'errorCode': errorCode,
          'durationMs': now.difference(trace.startedAt).inMilliseconds,
        },
        now);
    trace.status = terminalStatus;
    trace.endedAt = now;
    if (_activeTraceBySession[trace.sessionId] == traceId) {
      _activeTraceBySession.remove(trace.sessionId);
    }
  }

  void finishActiveRunTrace(
    String sessionId,
    RunTraceStatus status, {
    String? errorCode,
  }) {
    final traceId = _activeTraceBySession[_safeSessionId(sessionId)];
    if (traceId == null) return;
    finishRunTrace(traceId, status, errorCode: errorCode);
  }

  String? activeTraceIdForSession(String sessionId) =>
      _tracingEnabled ? _activeTraceBySession[_safeSessionId(sessionId)] : null;

  List<RunTraceSnapshot> recentRunTraces({
    String? sessionId,
    int limit = defaultTraceCapacity,
  }) {
    if (!_tracingEnabled) return const [];
    final safeLimit = limit < 0 ? 0 : limit;
    final safeSessionId = sessionId == null ? null : _safeSessionId(sessionId);
    final filtered = safeSessionId == null
        ? _traces
        : _traces.where((trace) => trace.sessionId == safeSessionId);
    final list = filtered.map((trace) => trace.snapshot()).toList();
    if (list.length <= safeLimit) return list;
    return list.sublist(list.length - safeLimit);
  }

  RunTraceSnapshot? runTrace(String traceId) =>
      _tracingEnabled ? _traceForId(traceId)?.snapshot() : null;

  void clearRunTraces({String? sessionId}) {
    if (sessionId == null) {
      _traces.clear();
      _activeTraceBySession.clear();
      return;
    }
    final safeSessionId = _safeSessionId(sessionId);
    _traces.removeWhere((trace) => trace.sessionId == safeSessionId);
    _activeTraceBySession.remove(safeSessionId);
  }

  void record(RuntimeDebugEvent event) {
    try {
      if (!_tracingEnabled) return;
      // Re-ingest defensively so no caller can bypass the constructor's
      // event-specific schema before the object reaches an in-memory store.
      final ingested = RuntimeDebugEvent(
        timestamp: event.timestamp,
        type: event.type,
        sessionId: event.sessionId,
        traceId: event.traceId,
        data: event.data,
      );
      if (capacity > 0) {
        _events.add(ingested);
        while (_events.length > capacity) {
          _events.removeAt(0);
        }
      }
      final traceId =
          ingested.traceId ?? _activeTraceBySession[ingested.sessionId];
      final trace = traceId == null ? null : _traceForId(traceId);
      if (trace != null && trace.status == RunTraceStatus.inFlight) {
        _appendTraceEvent(
          trace,
          ingested.type,
          ingested.data,
          ingested.timestamp,
        );
      }
    } catch (_) {
      // Debug events must never affect production behavior.
    }
  }

  List<RuntimeDebugEvent> recent({String? sessionId, int limit = 100}) {
    if (!_tracingEnabled) return const [];
    final safeLimit = limit < 0 ? 0 : limit;
    final safeSessionId = sessionId == null ? null : _safeSessionId(sessionId);
    final filtered = safeSessionId == null
        ? _events
        : _events.where((event) => event.sessionId == safeSessionId);
    final list = filtered.toList(growable: false);
    if (list.length <= safeLimit) return list;
    return list.sublist(list.length - safeLimit);
  }

  void clear({String? sessionId}) {
    if (sessionId == null) {
      _events.clear();
      return;
    }
    final safeSessionId = _safeSessionId(sessionId);
    _events.removeWhere((event) => event.sessionId == safeSessionId);
  }

  _MutableRunTrace? _traceForId(String traceId) {
    for (final trace in _traces.reversed) {
      if (trace.traceId == traceId) return trace;
    }
    return null;
  }

  void _appendTraceEvent(
    _MutableRunTrace trace,
    String type,
    Map<String, Object?> data,
    DateTime timestamp,
  ) {
    if (traceEventCapacity <= 0) return;
    trace.events.add(RunTraceEvent(
      sequence: trace.events.isEmpty ? 1 : trace.events.last.sequence + 1,
      timestamp: timestamp,
      type: _normalizeEventType(type),
      data: sanitizeEventData(type, data),
    ));
    while (trace.events.length > traceEventCapacity) {
      trace.events.removeAt(0);
    }
  }

  void _evictOldTraces() {
    while (_traces.length > traceCapacity) {
      var index = _traces.indexWhere(
        (trace) => trace.status != RunTraceStatus.inFlight,
      );
      if (index < 0) index = 0;
      final removed = _traces.removeAt(index);
      if (_activeTraceBySession[removed.sessionId] == removed.traceId) {
        _activeTraceBySession.remove(removed.sessionId);
      }
    }
  }

  static const _knownReasonCodes = {
    'auth_or_permission',
    'cache_share_too_high',
    'context_too_large',
    'context_window_larger',
    'context_window_not_larger',
    'context_window_smaller',
    'digest_mismatch',
    'estimate_too_small',
    'image_share_too_high',
    'invalid_or_tool_error',
    'large_block',
    'missing_actual_tokens',
    'model_unavailable',
    'network_or_timeout',
    'no_configured_candidate',
    'non_retryable',
    'provider_unavailable',
    'rate_limited',
    'ratio_out_of_range',
    'reasoning_budget_not_configured',
    'reasoning_not_supported',
    'recovery',
    'safety_or_refusal',
    'sensitive_data_redacted',
    'superseded_run',
    'tool_call_turn',
    'tool_share_too_high',
    'tools_not_supported',
    'unsafe_after_partial_run',
    'user_cancelled',
    'version_mismatch',
    'vision_not_supported',
  };

  static const _knownErrorCodes = {
    ..._knownReasonCodes,
    'agent_run_failed',
    'stream_interrupted',
    'superseded_by_new_run',
    'unexpected_exception',
  };

  static const _modeValues = {'send', 'compare', 'recovery'};
  static const _triggerValues = {
    'message',
    'interrupted_recovery',
    'regenerate',
    'retry',
  };
  static const _providerKindValues = {
    'anthropicNative',
    'openaiNative',
    'anthropicCompatible',
    'openRouter',
    'groq',
    'liteLlm',
    'genericOpenAICompatible',
  };
  static const _modelGroupLabelValues = {'none', 'configured'};
  static const _riskValues = {'safe', 'moderate', 'dangerous'};
  static const _lifecycleValues = {
    'proposed',
    'approvalPending',
    'approvedNotStarted',
    'started',
    'completed',
    'failed',
    'interruptedUnknown',
    'resultPersisted',
  };
  static const _statusValues = {
    'in_flight',
    'completed',
    'failed',
    'cancelled',
    'interrupted',
  };
  static const _completenessValues = {
    'complete',
    'partial',
    'none',
    'interrupted',
  };
  static const _stageValues = {
    'llm',
    'extractive',
    'provider',
    'provider_payload',
    'initial_error',
    'empty_recovery_payload',
    'retry_invalid_encrypted_content',
    'retry_error',
  };
  static const _warningCodeValues = {
    'image_unsupported',
    'tool_use_missing_identity',
    'tool_result_missing_id',
    'orphan_tool_use',
    'orphan_tool_result',
    'unknown',
  };
  static const _forbiddenMetadataMarkers = {
    'prompt',
    'message',
    'content',
    'reasoning',
    'request',
    'response',
    'tool_arg',
    'toolarg',
    'tool_output',
    'tooloutput',
    'command',
    'script',
    'endpoint',
    'url',
    'header',
    'authorization',
    'api_key',
    'apikey',
    'password',
    'passwd',
    'secret',
    'base64',
    'data_url',
    'filesystem',
    'file_path',
    'environment',
    'env_var',
  };

  /// Returns the documented ingestion allowlist for [type].
  static Set<String> allowedMetadataKeysForEvent(String type) =>
      Set<String>.unmodifiable(
        (_schemaForEvent(_normalizeEventType(type)) ?? const {}).keys,
      );

  /// Applies the event-specific schema before metadata reaches any store.
  static Map<String, Object?> sanitizeEventData(
    String type,
    Map<String, Object?> data,
  ) {
    final normalizedType = _normalizeEventType(type);
    final schema = _schemaForEvent(normalizedType);
    if (schema == null || schema.isEmpty) return const {};
    final safe = <String, Object?>{};
    for (final entry in schema.entries) {
      if (!data.containsKey(entry.key)) continue;
      final value = _sanitizeAllowedValue(entry.value, data[entry.key]);
      if (value != null) safe[entry.key] = value;
    }
    return Map<String, Object?>.unmodifiable(safe);
  }

  static Map<String, _RuntimeDebugValueKind>? _schemaForEvent(String type) {
    if (_toolAttemptEventTypes.contains(type)) return _toolAttemptSchema;
    return _eventSchemas[type];
  }

  static String _normalizeEventType(String type) {
    final trimmed = type.trim();
    return _schemaForEvent(trimmed) == null ? 'debug.unknown' : trimmed;
  }

  static Object? _sanitizeAllowedValue(
    _RuntimeDebugValueKind kind,
    Object? value,
  ) {
    switch (kind) {
      case _RuntimeDebugValueKind.boolean:
        return value is bool ? value : null;
      case _RuntimeDebugValueKind.count:
        return _boundedInt(value, min: 0, max: 1000000000);
      case _RuntimeDebugValueKind.attempt:
        return _boundedInt(value, min: 1, max: 1000);
      case _RuntimeDebugValueKind.durationMs:
        return _boundedInt(value, min: 0, max: 604800000);
      case _RuntimeDebugValueKind.tokenCount:
        return _boundedInt(value, min: 0, max: 1000000000000);
      case _RuntimeDebugValueKind.decimal:
        return _boundedDouble(value, min: 0, max: 1000);
      case _RuntimeDebugValueKind.code:
        return _safeCode(value);
      case _RuntimeDebugValueKind.errorCode:
        return _safeErrorCode(value);
      case _RuntimeDebugValueKind.reasonCode:
        return _safeKnownString(value, _knownReasonCodes);
      case _RuntimeDebugValueKind.mode:
        return _safeKnownString(value, _modeValues);
      case _RuntimeDebugValueKind.trigger:
        return _safeKnownString(value, _triggerValues);
      case _RuntimeDebugValueKind.providerKind:
        return _safeKnownString(value, _providerKindValues);
      case _RuntimeDebugValueKind.profileLabel:
        return _safeProfileLabel(value);
      case _RuntimeDebugValueKind.modelLabel:
        return _safeModelLabel(value);
      case _RuntimeDebugValueKind.modelGroupLabel:
        return _safeKnownString(value, _modelGroupLabelValues);
      case _RuntimeDebugValueKind.toolName:
        return _safeToolName(value);
      case _RuntimeDebugValueKind.correlationId:
        return _safeCorrelationId(value);
      case _RuntimeDebugValueKind.risk:
        return _safeKnownString(value, _riskValues);
      case _RuntimeDebugValueKind.lifecycle:
        return _safeKnownString(value, _lifecycleValues);
      case _RuntimeDebugValueKind.status:
        return _safeKnownString(value, _statusValues);
      case _RuntimeDebugValueKind.completeness:
        return _safeKnownString(value, _completenessValues);
      case _RuntimeDebugValueKind.stage:
        return _safeKnownString(value, _stageValues);
      case _RuntimeDebugValueKind.warningCode:
        return _safeKnownString(value, _warningCodeValues);
    }
  }

  static int? _boundedInt(
    Object? value, {
    required int min,
    required int max,
  }) {
    if (value is! int) return null;
    return value.clamp(min, max);
  }

  static double? _boundedDouble(
    Object? value, {
    required double min,
    required double max,
  }) {
    if (value is! num || !value.isFinite) return null;
    return value.toDouble().clamp(min, max);
  }

  static String? _stringValue(Object? value) {
    if (value is Enum) return value.name;
    return value is String ? value.trim() : null;
  }

  static String? _safeKnownString(Object? value, Set<String> allowed) {
    final string = _stringValue(value);
    return string != null && allowed.contains(string) ? string : null;
  }

  static String? _safeCode(Object? value) {
    final string = _stringValue(value);
    if (string == null || string.isEmpty || string.length > 64) return null;
    final sanitized = const LlmContentSanitizer().sanitizeText(string).text;
    if (sanitized != string) return null;
    return RegExp(r'^[A-Za-z0-9_][A-Za-z0-9._:-]{0,63}$').hasMatch(string)
        ? string
        : null;
  }

  static String? _safeErrorCode(Object? value) {
    final string = _stringValue(value);
    if (string == null) return null;
    if (_knownErrorCodes.contains(string)) return string;
    final code = _safeCode(string);
    if (code == null) return null;
    return RegExp(r'^_?[A-Za-z][A-Za-z0-9_]{0,55}(Error|Exception)$')
            .hasMatch(code)
        ? code
        : null;
  }

  static String? _safeProfileLabel(Object? value) {
    final string = _stringValue(value);
    if (string == null) return null;
    return RegExp(r'^profile_(custom|[1-9][0-9]{0,3})$').hasMatch(string)
        ? string
        : null;
  }

  static String? _safeModelLabel(Object? value) {
    final string = _stringValue(value);
    if (string == null || string.isEmpty) return null;
    final sanitized = const LlmContentSanitizer().sanitizeText(string).text;
    if (sanitized != string || _containsForbiddenMetadataMarker(string)) {
      return null;
    }
    final normalized = string
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll(RegExp(r'[^A-Za-z0-9._:/+()-]'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    if (normalized.isEmpty || normalized.contains('://')) return null;
    return normalized.length <= 80 ? normalized : normalized.substring(0, 80);
  }

  static String? _safeToolName(Object? value) {
    final string = _stringValue(value);
    if (string == null || string.isEmpty || string.length > 64) return null;
    final sanitized = const LlmContentSanitizer().sanitizeText(string).text;
    if (sanitized != string) return null;
    return RegExp(r'^[A-Za-z0-9_][A-Za-z0-9._:-]{0,63}$').hasMatch(string)
        ? string
        : null;
  }

  static String _safeSessionId(String value) =>
      _safeCorrelationId(value) ?? 'session-unknown';

  static String? _safeOptionalCorrelationId(String? value) =>
      value == null ? null : _safeCorrelationId(value);

  static String? _safeCorrelationId(Object? value) {
    final string = _stringValue(value);
    if (string == null || string.isEmpty || string.length > 128) return null;
    final sanitized = const LlmContentSanitizer().sanitizeText(string).text;
    if (sanitized != string || _containsForbiddenMetadataMarker(string)) {
      return null;
    }
    return RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(string)
        ? string
        : null;
  }

  static bool _containsForbiddenMetadataMarker(String value) {
    final normalized = value.toLowerCase().replaceAll('-', '_');
    return _forbiddenMetadataMarkers.any(normalized.contains);
  }
}
