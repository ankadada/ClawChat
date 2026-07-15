import 'dart:convert';

const int backgroundTaskSchemaVersion = 1;
const int maxBackgroundTaskPayloadBytes = 8 * 1024;
const int maxBackgroundTaskRecordBytes = 16 * 1024;

enum BackgroundTaskState {
  draft,
  previewReady,
  localApproved,
  awaitingExternalApproval,
  approvedNotStarted,
  executing,
  succeeded,
  failed,
  denied,
  cancelled,
  unknownOutcome,
  recoveryRequired,
  invalid,
}

extension BackgroundTaskStateWire on BackgroundTaskState {
  String get wireValue => switch (this) {
        BackgroundTaskState.draft => 'draft',
        BackgroundTaskState.previewReady => 'preview_ready',
        BackgroundTaskState.localApproved => 'local_approved',
        BackgroundTaskState.awaitingExternalApproval =>
          'awaiting_external_approval',
        BackgroundTaskState.approvedNotStarted => 'approved_not_started',
        BackgroundTaskState.executing => 'executing',
        BackgroundTaskState.succeeded => 'succeeded',
        BackgroundTaskState.failed => 'failed',
        BackgroundTaskState.denied => 'denied',
        BackgroundTaskState.cancelled => 'cancelled',
        BackgroundTaskState.unknownOutcome => 'unknown_outcome',
        BackgroundTaskState.recoveryRequired => 'recovery_required',
        BackgroundTaskState.invalid => 'invalid',
      };

  bool get canExecute => this == BackgroundTaskState.approvedNotStarted;
  bool get isTerminal => switch (this) {
        BackgroundTaskState.succeeded ||
        BackgroundTaskState.failed ||
        BackgroundTaskState.denied ||
        BackgroundTaskState.cancelled ||
        BackgroundTaskState.unknownOutcome ||
        BackgroundTaskState.invalid =>
          true,
        _ => false,
      };

  static BackgroundTaskState parse(Object? value) => switch (value) {
        'draft' => BackgroundTaskState.draft,
        'preview_ready' => BackgroundTaskState.previewReady,
        'local_approved' => BackgroundTaskState.localApproved,
        'awaiting_external_approval' =>
          BackgroundTaskState.awaitingExternalApproval,
        'approved_not_started' => BackgroundTaskState.approvedNotStarted,
        'executing' => BackgroundTaskState.executing,
        'succeeded' => BackgroundTaskState.succeeded,
        'failed' => BackgroundTaskState.failed,
        'denied' => BackgroundTaskState.denied,
        'cancelled' => BackgroundTaskState.cancelled,
        'unknown_outcome' => BackgroundTaskState.unknownOutcome,
        'recovery_required' => BackgroundTaskState.recoveryRequired,
        'invalid' => BackgroundTaskState.invalid,
        _ => throw const BackgroundTaskFormatException('task_state_invalid'),
      };
}

enum BackgroundTaskReceiptState {
  proposed,
  approvalPending,
  approvedNotStarted,
  started,
  resultPersisted,
  denied,
  unknownOutcome,
}

extension BackgroundTaskReceiptStateWire on BackgroundTaskReceiptState {
  String get wireValue => switch (this) {
        BackgroundTaskReceiptState.proposed => 'proposed',
        BackgroundTaskReceiptState.approvalPending => 'approval_pending',
        BackgroundTaskReceiptState.approvedNotStarted => 'approved_not_started',
        BackgroundTaskReceiptState.started => 'started',
        BackgroundTaskReceiptState.resultPersisted => 'result_persisted',
        BackgroundTaskReceiptState.denied => 'denied',
        BackgroundTaskReceiptState.unknownOutcome => 'unknown_outcome',
      };

  static BackgroundTaskReceiptState parse(Object? value) => switch (value) {
        'proposed' => BackgroundTaskReceiptState.proposed,
        'approval_pending' => BackgroundTaskReceiptState.approvalPending,
        'approved_not_started' => BackgroundTaskReceiptState.approvedNotStarted,
        'started' => BackgroundTaskReceiptState.started,
        'result_persisted' => BackgroundTaskReceiptState.resultPersisted,
        'denied' => BackgroundTaskReceiptState.denied,
        'unknown_outcome' => BackgroundTaskReceiptState.unknownOutcome,
        _ => throw const BackgroundTaskFormatException('receipt_state_invalid'),
      };
}

final class BackgroundTaskFormatException implements Exception {
  const BackgroundTaskFormatException(this.reasonCode);

  final String reasonCode;

  @override
  String toString() => 'BackgroundTaskFormatException($reasonCode)';
}

final class BackgroundTaskPreview {
  const BackgroundTaskPreview({
    required this.safeSummary,
    required this.sideEffectSummary,
    this.targetSummary,
    this.unknowns = const [],
  });

  final String safeSummary;
  final String sideEffectSummary;
  final String? targetSummary;
  final List<String> unknowns;

  Map<String, Object?> toJson() => {
        'safeSummary': safeSummary,
        'sideEffectSummary': sideEffectSummary,
        'targetSummary': targetSummary,
        'unknowns': List<String>.unmodifiable(unknowns),
      };

  factory BackgroundTaskPreview.fromJson(Object? value) {
    final json = _requiredMap(value, 'preview_invalid');
    _requireExactKeys(
      json,
      const {'safeSummary', 'sideEffectSummary', 'targetSummary', 'unknowns'},
      'preview_fields_invalid',
    );
    final unknowns = json['unknowns'];
    if (unknowns is! List || unknowns.length > 8) {
      throw const BackgroundTaskFormatException('preview_unknowns_invalid');
    }
    return BackgroundTaskPreview(
      safeSummary: _boundedString(
        json['safeSummary'],
        'preview_summary_invalid',
        max: 512,
      ),
      sideEffectSummary: _boundedString(
        json['sideEffectSummary'],
        'preview_side_effect_invalid',
        max: 256,
      ),
      targetSummary: _nullableBoundedString(
        json['targetSummary'],
        'preview_target_invalid',
        max: 256,
      ),
      unknowns: List<String>.unmodifiable(unknowns.map((item) {
        return _boundedString(item, 'preview_unknown_invalid', max: 256);
      })),
    );
  }
}

final class BackgroundTaskReceipt {
  const BackgroundTaskReceipt({
    required this.receiptId,
    required this.operationId,
    required this.state,
    required this.outcomeKnown,
    required this.createdAt,
    required this.safeSummary,
  });

  final String receiptId;
  final String operationId;
  final BackgroundTaskReceiptState state;
  final bool outcomeKnown;
  final DateTime createdAt;
  final String safeSummary;

  Map<String, Object?> toJson() => {
        'schemaVersion': backgroundTaskSchemaVersion,
        'receiptId': receiptId,
        'operationId': operationId,
        'state': state.wireValue,
        'outcomeKnown': outcomeKnown,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'safeSummary': safeSummary,
      };

  factory BackgroundTaskReceipt.fromJson(Object? value) {
    final json = _requiredMap(value, 'receipt_invalid');
    _requireExactKeys(
      json,
      const {
        'schemaVersion',
        'receiptId',
        'operationId',
        'state',
        'outcomeKnown',
        'createdAt',
        'safeSummary',
      },
      'receipt_fields_invalid',
    );
    if (json['schemaVersion'] != backgroundTaskSchemaVersion ||
        json['outcomeKnown'] is! bool) {
      throw const BackgroundTaskFormatException('receipt_schema_invalid');
    }
    return BackgroundTaskReceipt(
      receiptId: _identifier(json['receiptId'], 'receipt_id_invalid'),
      operationId:
          _identifier(json['operationId'], 'receipt_operation_invalid'),
      state: BackgroundTaskReceiptStateWire.parse(json['state']),
      outcomeKnown: json['outcomeKnown'] as bool,
      createdAt: _timestamp(json['createdAt'], 'receipt_timestamp_invalid'),
      safeSummary: _boundedString(
        json['safeSummary'],
        'receipt_summary_invalid',
        max: 256,
      ),
    );
  }
}

final class BackgroundTaskRecord {
  const BackgroundTaskRecord({
    required this.taskId,
    required this.sessionId,
    required this.createdAt,
    required this.updatedAt,
    required this.state,
    required this.taskKind,
    required this.localPayload,
    required this.preview,
    required this.previewDigest,
    required this.requiresExternalSend,
    required this.lastOutcomeKnown,
    this.lastOperationId,
    this.lastReceiptId,
    this.lastReceipt,
    this.recoveryReason,
    this.planApprovedAt,
  });

  final String taskId;
  final String sessionId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final BackgroundTaskState state;
  final String taskKind;
  final Map<String, Object?> localPayload;
  final BackgroundTaskPreview? preview;
  final String? previewDigest;
  final bool requiresExternalSend;
  final String? lastOperationId;
  final String? lastReceiptId;
  final BackgroundTaskReceipt? lastReceipt;
  final bool lastOutcomeKnown;
  final String? recoveryReason;
  final DateTime? planApprovedAt;

  Map<String, Object?> toJson() {
    final json = <String, Object?>{
      'schemaVersion': backgroundTaskSchemaVersion,
      'taskId': taskId,
      'sessionId': sessionId,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'updatedAt': updatedAt.toUtc().toIso8601String(),
      'state': state.wireValue,
      'taskKind': taskKind,
      'localPayload': localPayload,
      'preview': preview?.toJson(),
      'previewDigest': previewDigest,
      'requiresExternalSend': requiresExternalSend,
      'lastOperationId': lastOperationId,
      'lastReceiptId': lastReceiptId,
      'lastReceipt': lastReceipt?.toJson(),
      'lastOutcomeKnown': lastOutcomeKnown,
      'recoveryReason': recoveryReason,
      'planApprovedAt': planApprovedAt?.toUtc().toIso8601String(),
    };
    if (utf8.encode(jsonEncode(json)).length > maxBackgroundTaskRecordBytes) {
      throw const BackgroundTaskFormatException('task_record_too_large');
    }
    return json;
  }

  factory BackgroundTaskRecord.fromJson(Object? value) {
    final json = _requiredMap(value, 'task_record_invalid');
    _requireExactKeys(
      json,
      const {
        'schemaVersion',
        'taskId',
        'sessionId',
        'createdAt',
        'updatedAt',
        'state',
        'taskKind',
        'localPayload',
        'preview',
        'previewDigest',
        'requiresExternalSend',
        'lastOperationId',
        'lastReceiptId',
        'lastReceipt',
        'lastOutcomeKnown',
        'recoveryReason',
        'planApprovedAt',
      },
      'task_record_fields_invalid',
    );
    if (json['schemaVersion'] != backgroundTaskSchemaVersion ||
        json['requiresExternalSend'] is! bool ||
        json['lastOutcomeKnown'] is! bool) {
      throw const BackgroundTaskFormatException('task_record_schema_invalid');
    }
    final payload = _jsonObject(json['localPayload'], 'task_payload_invalid');
    if (utf8.encode(jsonEncode(payload)).length >
        maxBackgroundTaskPayloadBytes) {
      throw const BackgroundTaskFormatException('task_payload_too_large');
    }
    final receipt = json['lastReceipt'] == null
        ? null
        : BackgroundTaskReceipt.fromJson(json['lastReceipt']);
    final receiptId = _nullableIdentifier(
      json['lastReceiptId'],
      'task_receipt_id_invalid',
    );
    if ((receipt == null) != (receiptId == null) ||
        (receipt != null && receipt.receiptId != receiptId)) {
      throw const BackgroundTaskFormatException('task_receipt_link_invalid');
    }
    final preview = json['preview'] == null
        ? null
        : BackgroundTaskPreview.fromJson(json['preview']);
    final previewDigest = _nullableDigest(
      json['previewDigest'],
      'task_preview_digest_invalid',
    );
    if ((preview == null) != (previewDigest == null)) {
      throw const BackgroundTaskFormatException('task_preview_link_invalid');
    }
    return BackgroundTaskRecord(
      taskId: _identifier(json['taskId'], 'task_id_invalid'),
      sessionId: _identifier(json['sessionId'], 'task_session_invalid'),
      createdAt: _timestamp(json['createdAt'], 'task_created_at_invalid'),
      updatedAt: _timestamp(json['updatedAt'], 'task_updated_at_invalid'),
      state: BackgroundTaskStateWire.parse(json['state']),
      taskKind: _identifier(json['taskKind'], 'task_kind_invalid'),
      localPayload: payload,
      preview: preview,
      previewDigest: previewDigest,
      requiresExternalSend: json['requiresExternalSend'] as bool,
      lastOperationId: _nullableIdentifier(
        json['lastOperationId'],
        'task_operation_invalid',
      ),
      lastReceiptId: receiptId,
      lastReceipt: receipt,
      lastOutcomeKnown: json['lastOutcomeKnown'] as bool,
      recoveryReason: _nullableBoundedString(
        json['recoveryReason'],
        'task_recovery_reason_invalid',
        max: 96,
      ),
      planApprovedAt: json['planApprovedAt'] == null
          ? null
          : _timestamp(json['planApprovedAt'], 'task_plan_approval_invalid'),
    );
  }

  BackgroundTaskRecord copyWith({
    BackgroundTaskState? state,
    DateTime? updatedAt,
    BackgroundTaskPreview? preview,
    String? previewDigest,
    String? lastOperationId,
    BackgroundTaskReceipt? lastReceipt,
    bool? lastOutcomeKnown,
    String? recoveryReason,
    DateTime? planApprovedAt,
  }) =>
      BackgroundTaskRecord(
        taskId: taskId,
        sessionId: sessionId,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        state: state ?? this.state,
        taskKind: taskKind,
        localPayload: localPayload,
        preview: preview ?? this.preview,
        previewDigest: previewDigest ?? this.previewDigest,
        requiresExternalSend: requiresExternalSend,
        lastOperationId: lastOperationId ?? this.lastOperationId,
        lastReceiptId: lastReceipt?.receiptId ?? lastReceiptId,
        lastReceipt: lastReceipt ?? this.lastReceipt,
        lastOutcomeKnown: lastOutcomeKnown ?? this.lastOutcomeKnown,
        recoveryReason: recoveryReason ?? this.recoveryReason,
        planApprovedAt: planApprovedAt ?? this.planApprovedAt,
      );
}

Map<String, Object?> _requiredMap(Object? value, String reasonCode) {
  if (value is! Map) throw BackgroundTaskFormatException(reasonCode);
  return _jsonObject(value, reasonCode);
}

Map<String, Object?> _jsonObject(Object? value, String reasonCode) {
  if (value is! Map) throw BackgroundTaskFormatException(reasonCode);
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) throw BackgroundTaskFormatException(reasonCode);
    result[entry.key as String] = _jsonValue(entry.value, reasonCode, 0);
  }
  return Map.unmodifiable(result);
}

Object? _jsonValue(Object? value, String reasonCode, int depth) {
  if (depth > 24) throw BackgroundTaskFormatException(reasonCode);
  if (value == null || value is String || value is bool) return value;
  if (value is num && value.isFinite) return value;
  if (value is List) {
    return List<Object?>.unmodifiable(
      value.map((item) => _jsonValue(item, reasonCode, depth + 1)),
    );
  }
  if (value is Map) {
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      if (entry.key is! String) throw BackgroundTaskFormatException(reasonCode);
      result[entry.key as String] =
          _jsonValue(entry.value, reasonCode, depth + 1);
    }
    return Map<String, Object?>.unmodifiable(result);
  }
  throw BackgroundTaskFormatException(reasonCode);
}

void _requireExactKeys(
  Map<String, Object?> json,
  Set<String> expected,
  String reasonCode,
) {
  if (json.length != expected.length ||
      !json.keys.toSet().containsAll(expected)) {
    throw BackgroundTaskFormatException(reasonCode);
  }
}

String _identifier(Object? value, String reasonCode) {
  if (value is! String || !RegExp(r'^[A-Za-z0-9._-]{1,128}$').hasMatch(value)) {
    throw BackgroundTaskFormatException(reasonCode);
  }
  return value;
}

String? _nullableIdentifier(Object? value, String reasonCode) =>
    value == null ? null : _identifier(value, reasonCode);

String? _nullableDigest(Object? value, String reasonCode) {
  if (value == null) return null;
  if (value is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
    throw BackgroundTaskFormatException(reasonCode);
  }
  return value;
}

String _boundedString(Object? value, String reasonCode, {required int max}) {
  if (value is! String || value.isEmpty || value.length > max) {
    throw BackgroundTaskFormatException(reasonCode);
  }
  return value;
}

String? _nullableBoundedString(
  Object? value,
  String reasonCode, {
  required int max,
}) =>
    value == null ? null : _boundedString(value, reasonCode, max: max);

DateTime _timestamp(Object? value, String reasonCode) {
  if (value is! String) throw BackgroundTaskFormatException(reasonCode);
  final parsed = DateTime.tryParse(value);
  if (parsed == null) throw BackgroundTaskFormatException(reasonCode);
  return parsed.toUtc();
}
