import 'chat_models.dart';

/// Bounds for the durable run journal. The journal is diagnostic only: it
/// never carries tool arguments, results, prompts, or credentials, and it has
/// no execution API.
const int maxRunJournalEntries = 24;
const int maxRunJournalAttemptsPerEntry = 64;

/// Upper bound for one serialized journal payload (before encryption).
const int maxRunJournalPayloadBytes = 96 * 1024;

/// Longest accepted opaque reason code (for example `user_cancelled`).
const int maxRunJournalReasonLength = 40;

/// Lifecycle state of one agent run, as the journal shows it.
///
/// `unknownOutcome` is the fail-closed state: the run ended but the app cannot
/// prove whether an effect landed. It is never shown as a success.
enum RunJournalState {
  running,
  completed,
  cancelled,
  failed,
  interrupted,
  unknownOutcome,
}

extension RunJournalStateWire on RunJournalState {
  String get wireValue => switch (this) {
        RunJournalState.running => 'running',
        RunJournalState.completed => 'completed',
        RunJournalState.cancelled => 'cancelled',
        RunJournalState.failed => 'failed',
        RunJournalState.interrupted => 'interrupted',
        RunJournalState.unknownOutcome => 'unknown_outcome',
      };

  static RunJournalState parse(String value) {
    for (final state in RunJournalState.values) {
      if (state.wireValue == value) return state;
    }
    throw const FormatException('run_journal_state_invalid');
  }
}

/// One tool attempt as the journal records it.
///
/// Only the tool name, the risk class, the policy stage the lifecycle reached,
/// and whether the result was persisted. There is deliberately no field for an
/// argument, a result, or a receipt body.
enum RunJournalToolState {
  proposed,
  approvalPending,
  approved,
  started,
  completed,
  failed,
  interrupted,
  persisted,
}

extension RunJournalToolStateWire on RunJournalToolState {
  String get wireValue => switch (this) {
        RunJournalToolState.proposed => 'proposed',
        RunJournalToolState.approvalPending => 'approval_pending',
        RunJournalToolState.approved => 'approved',
        RunJournalToolState.started => 'started',
        RunJournalToolState.completed => 'completed',
        RunJournalToolState.failed => 'failed',
        RunJournalToolState.interrupted => 'interrupted',
        RunJournalToolState.persisted => 'persisted',
      };

  static RunJournalToolState parse(String value) {
    for (final state in RunJournalToolState.values) {
      if (state.wireValue == value) return state;
    }
    throw const FormatException('run_journal_tool_state_invalid');
  }
}

final class RunJournalToolAttempt {
  static const _allowedJsonKeys = {
    'operationId',
    'toolName',
    'risk',
    'state',
    'proposedAt',
    'updatedAt',
    'startedAt',
    'endedAt',
    'outcomeKnown',
  };
  static const _requiredJsonKeys = {
    'operationId',
    'toolName',
    'risk',
    'state',
    'proposedAt',
    'updatedAt',
  };
  static final _safeIdPattern = RegExp(r'^[a-zA-Z0-9._:-]+$');
  static final _safeToolNamePattern = RegExp(r'^[a-zA-Z0-9._:-]+$');

  const RunJournalToolAttempt({
    required this.operationId,
    required this.toolName,
    required this.risk,
    required this.state,
    required this.proposedAt,
    required this.updatedAt,
    this.startedAt,
    this.endedAt,
    this.outcomeKnown = true,
  });

  final String operationId;
  final String toolName;
  final RecoveryToolRisk risk;
  final RunJournalToolState state;
  final DateTime proposedAt;
  final DateTime updatedAt;
  final DateTime? startedAt;
  final DateTime? endedAt;

  /// False when the attempt was handed to a tool but no terminal result was
  /// observed: the journal then reports `interrupted`/unknown, never success.
  final bool outcomeKnown;

  bool get hasUnknownOutcome =>
      !outcomeKnown ||
      state == RunJournalToolState.started ||
      state == RunJournalToolState.interrupted;

  /// A persisted result is the journal's receipt evidence: the result reached
  /// the transcript, so the attempt is proven to have completed.
  bool get resultPersisted => state == RunJournalToolState.persisted;

  bool get isTerminal => switch (state) {
        RunJournalToolState.failed ||
        RunJournalToolState.interrupted ||
        RunJournalToolState.persisted ||
        RunJournalToolState.completed =>
          true,
        _ => false,
      };

  RunJournalToolAttempt copyWith({
    RunJournalToolState? state,
    DateTime? updatedAt,
    DateTime? startedAt,
    DateTime? endedAt,
    bool? outcomeKnown,
  }) =>
      RunJournalToolAttempt(
        operationId: operationId,
        toolName: toolName,
        risk: risk,
        state: state ?? this.state,
        proposedAt: proposedAt,
        updatedAt: updatedAt ?? this.updatedAt,
        startedAt: startedAt ?? this.startedAt,
        endedAt: endedAt ?? this.endedAt,
        outcomeKnown: outcomeKnown ?? this.outcomeKnown,
      );

  Map<String, dynamic> toJson() => {
        'operationId': operationId,
        'toolName': toolName,
        'risk': risk.name,
        'state': state.wireValue,
        'proposedAt': proposedAt.toUtc().toIso8601String(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        if (startedAt != null)
          'startedAt': startedAt!.toUtc().toIso8601String(),
        if (endedAt != null) 'endedAt': endedAt!.toUtc().toIso8601String(),
        if (!outcomeKnown) 'outcomeKnown': false,
      };

  /// The exact shape the journal accepts back, so a tampered or hand-written
  /// payload fails closed instead of becoming a display record.
  static bool isSanitizedJson(Map<String, dynamic> json) =>
      json.keys.every(_allowedJsonKeys.contains) &&
      json.keys.toSet().containsAll(_requiredJsonKeys) &&
      json['operationId'] is String &&
      json['operationId'].toString().isNotEmpty &&
      json['operationId'].toString().length <= 120 &&
      _safeIdPattern.hasMatch(json['operationId'].toString()) &&
      json['toolName'] is String &&
      json['toolName'].toString().isNotEmpty &&
      json['toolName'].toString().length <= 120 &&
      _safeToolNamePattern.hasMatch(json['toolName'].toString()) &&
      RecoveryToolRisk.values.any((risk) => risk.name == json['risk']) &&
      RunJournalToolState.values
          .any((state) => state.wireValue == json['state']) &&
      _isTimestamp(json['proposedAt']) &&
      _isTimestamp(json['updatedAt']) &&
      (json['startedAt'] == null || _isTimestamp(json['startedAt'])) &&
      (json['endedAt'] == null || _isTimestamp(json['endedAt'])) &&
      (json['outcomeKnown'] == null || json['outcomeKnown'] is bool);

  factory RunJournalToolAttempt.fromJson(Map<String, dynamic> json) {
    if (!isSanitizedJson(json)) {
      throw const FormatException('run_journal_attempt_invalid');
    }
    return RunJournalToolAttempt(
      operationId: json['operationId'] as String,
      toolName: json['toolName'] as String,
      risk: RecoveryToolRisk.values
          .firstWhere((risk) => risk.name == json['risk']),
      state: RunJournalToolStateWire.parse(json['state'] as String),
      proposedAt: DateTime.parse(json['proposedAt'] as String).toUtc(),
      updatedAt: DateTime.parse(json['updatedAt'] as String).toUtc(),
      startedAt: json['startedAt'] == null
          ? null
          : DateTime.parse(json['startedAt'] as String).toUtc(),
      endedAt: json['endedAt'] == null
          ? null
          : DateTime.parse(json['endedAt'] as String).toUtc(),
      outcomeKnown: json['outcomeKnown'] as bool? ?? true,
    );
  }

  /// Maps the session recovery metadata to a journal attempt.
  static RunJournalToolAttempt fromRecoveryMetadata(
    ToolAttemptRecoveryMetadata attempt, {
    required DateTime now,
  }) {
    final state = switch (attempt.lifecycle) {
      ToolAttemptLifecycle.proposed => RunJournalToolState.proposed,
      ToolAttemptLifecycle.approvalPending =>
        RunJournalToolState.approvalPending,
      ToolAttemptLifecycle.approvedNotStarted => RunJournalToolState.approved,
      ToolAttemptLifecycle.started => RunJournalToolState.started,
      ToolAttemptLifecycle.completed => RunJournalToolState.completed,
      ToolAttemptLifecycle.failed => RunJournalToolState.failed,
      ToolAttemptLifecycle.resultPersisted => RunJournalToolState.persisted,
      ToolAttemptLifecycle.interruptedUnknown =>
        RunJournalToolState.interrupted,
    };
    final unknown = attempt.hasUnknownOutcome ||
        state == RunJournalToolState.started ||
        state == RunJournalToolState.interrupted;
    return RunJournalToolAttempt(
      operationId: attempt.operationId,
      toolName: attempt.toolName,
      risk: attempt.risk,
      state: state,
      proposedAt: attempt.proposedAt.toUtc(),
      updatedAt: attempt.updatedAt.toUtc(),
      startedAt: attempt.executionStartedAt?.toUtc(),
      endedAt: state == RunJournalToolState.interrupted
          ? attempt.updatedAt.toUtc()
          : null,
      outcomeKnown: attempt.executionOutcomeKnown && !unknown,
    );
  }

  static bool _isTimestamp(Object? value) =>
      value is String && DateTime.tryParse(value) != null;
}

/// One run record. The journal upserts these by [runAttemptId] and keeps the
/// newest [maxRunJournalEntries] entries.
final class RunJournalEntry {
  static const schemaVersion = 1;
  static const _allowedJsonKeys = {
    'schemaVersion',
    'runAttemptId',
    'sessionId',
    'startedAt',
    'endedAt',
    'state',
    'endReason',
    'toolAttempts',
  };
  static const _requiredJsonKeys = {
    'schemaVersion',
    'runAttemptId',
    'sessionId',
    'startedAt',
    'state',
    'toolAttempts',
  };
  static final _safeIdPattern = RegExp(r'^[a-zA-Z0-9._:-]+$');
  static final _safeReasonPattern = RegExp(r'^[a-z0-9_]+$');

  const RunJournalEntry({
    required this.runAttemptId,
    required this.sessionId,
    required this.startedAt,
    required this.state,
    this.endedAt,
    this.endReason,
    this.toolAttempts = const [],
  });

  final String runAttemptId;
  final String sessionId;
  final DateTime startedAt;
  final DateTime? endedAt;
  final RunJournalState state;

  /// Short machine code only (`user_cancelled`, `process_death`, ...). Never a
  /// message body.
  final String? endReason;
  final List<RunJournalToolAttempt> toolAttempts;

  bool get isActive => state == RunJournalState.running;

  /// True when this run needs the user's attention: it did not finish and its
  /// effects cannot be fully proven.
  bool get requiresConfirmation =>
      state == RunJournalState.interrupted ||
      state == RunJournalState.unknownOutcome;

  bool get hasUnknownOutcome =>
      state == RunJournalState.unknownOutcome ||
      toolAttempts.any((attempt) => attempt.hasUnknownOutcome);

  RunJournalEntry copyWith({
    RunJournalState? state,
    DateTime? endedAt,
    String? endReason,
    List<RunJournalToolAttempt>? toolAttempts,
  }) =>
      RunJournalEntry(
        runAttemptId: runAttemptId,
        sessionId: sessionId,
        startedAt: startedAt,
        state: state ?? this.state,
        endedAt: endedAt ?? this.endedAt,
        endReason: endReason ?? this.endReason,
        toolAttempts: toolAttempts ?? this.toolAttempts,
      );

  /// Upserts [attempts] by `operationId`, keeping the newest
  /// [maxRunJournalAttemptsPerEntry] and preserving their order.
  RunJournalEntry withAttempts(Iterable<RunJournalToolAttempt> attempts) {
    final merged = <String, RunJournalToolAttempt>{
      for (final attempt in toolAttempts) attempt.operationId: attempt,
      for (final attempt in attempts) attempt.operationId: attempt,
    };
    final values = merged.values.toList()
      ..sort((a, b) => a.proposedAt.compareTo(b.proposedAt));
    return copyWith(
      toolAttempts: values.length <= maxRunJournalAttemptsPerEntry
          ? values
          : values.sublist(values.length - maxRunJournalAttemptsPerEntry),
    );
  }

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'runAttemptId': runAttemptId,
        'sessionId': sessionId,
        'startedAt': startedAt.toUtc().toIso8601String(),
        if (endedAt != null) 'endedAt': endedAt!.toUtc().toIso8601String(),
        'state': state.wireValue,
        if (endReason != null) 'endReason': endReason,
        'toolAttempts':
            toolAttempts.map((attempt) => attempt.toJson()).toList(),
      };

  static bool isSanitizedJson(Map<String, dynamic> json) {
    if (!json.keys.every(_allowedJsonKeys.contains) ||
        !json.keys.toSet().containsAll(_requiredJsonKeys)) {
      return false;
    }
    if (json['schemaVersion'] != schemaVersion) return false;
    final runAttemptId = json['runAttemptId'];
    final sessionId = json['sessionId'];
    if (runAttemptId is! String ||
        runAttemptId.isEmpty ||
        runAttemptId.length > 120 ||
        !_safeIdPattern.hasMatch(runAttemptId)) {
      return false;
    }
    if (sessionId is! String ||
        sessionId.isEmpty ||
        sessionId.length > 120 ||
        !_safeIdPattern.hasMatch(sessionId)) {
      return false;
    }
    final startedAt = json['startedAt'];
    if (startedAt is! String || DateTime.tryParse(startedAt) == null) {
      return false;
    }
    final endedAt = json['endedAt'];
    if (endedAt != null &&
        (endedAt is! String || DateTime.tryParse(endedAt) == null)) {
      return false;
    }
    final state = json['state'];
    if (state is! String ||
        !RunJournalState.values.any((s) => s.wireValue == state)) {
      return false;
    }
    final reason = json['endReason'];
    if (reason != null &&
        (reason is! String ||
            reason.isEmpty ||
            reason.length > maxRunJournalReasonLength ||
            !_safeReasonPattern.hasMatch(reason))) {
      return false;
    }
    final attempts = json['toolAttempts'];
    if (attempts is! List || attempts.length > maxRunJournalAttemptsPerEntry) {
      return false;
    }
    final seen = <String>{};
    for (final raw in attempts) {
      if (raw is! Map) return false;
      final attemptJson = Map<String, dynamic>.from(raw);
      if (!RunJournalToolAttempt.isSanitizedJson(attemptJson)) return false;
      if (!seen.add(attemptJson['operationId'] as String)) return false;
    }
    return true;
  }

  factory RunJournalEntry.fromJson(Map<String, dynamic> json) {
    if (!isSanitizedJson(json)) {
      throw const FormatException('run_journal_entry_invalid');
    }
    return RunJournalEntry(
      runAttemptId: json['runAttemptId'] as String,
      sessionId: json['sessionId'] as String,
      startedAt: DateTime.parse(json['startedAt'] as String).toUtc(),
      endedAt: json['endedAt'] == null
          ? null
          : DateTime.parse(json['endedAt'] as String).toUtc(),
      state: RunJournalStateWire.parse(json['state'] as String),
      endReason: json['endReason'] as String?,
      toolAttempts: [
        for (final raw in (json['toolAttempts'] as List))
          RunJournalToolAttempt.fromJson(Map<String, dynamic>.from(raw as Map)),
      ],
    );
  }

  /// Marks a run that was still `running` at startup as interrupted.
  ///
  /// A `started` tool attempt becomes `interrupted` with an unknown outcome:
  /// the app has no proof that the effect landed.
  RunJournalEntry markInterrupted(DateTime now) {
    final attempts = [
      for (final attempt in toolAttempts)
        attempt.state == RunJournalToolState.started
            ? attempt.copyWith(
                state: RunJournalToolState.interrupted,
                updatedAt: now,
                endedAt: now,
                outcomeKnown: false,
              )
            : attempt,
    ];
    return copyWith(
      state: RunJournalState.interrupted,
      endedAt: now,
      endReason: 'process_death',
      toolAttempts: attempts,
    );
  }
}
