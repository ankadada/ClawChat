import 'package:uuid/uuid.dart';

import 'structured_result.dart';
import 'workspace_import_receipt.dart';

class ContextSummary {
  final int version;
  final String text;
  final int coveredMessageCount;
  final String coveredDigest;
  final int sourceEstimatedTokens;
  final int summaryEstimatedTokens;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? model;
  final String? apiFormat;

  const ContextSummary({
    required this.version,
    required this.text,
    required this.coveredMessageCount,
    required this.coveredDigest,
    required this.sourceEstimatedTokens,
    required this.summaryEstimatedTokens,
    required this.createdAt,
    required this.updatedAt,
    this.model,
    this.apiFormat,
  });

  Map<String, dynamic> toJson() => {
        'version': version,
        'text': text,
        'coveredMessageCount': coveredMessageCount,
        'coveredDigest': coveredDigest,
        'sourceEstimatedTokens': sourceEstimatedTokens,
        'summaryEstimatedTokens': summaryEstimatedTokens,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        if (model != null) 'model': model,
        if (apiFormat != null) 'apiFormat': apiFormat,
      };

  factory ContextSummary.fromJson(Map<String, dynamic> json) {
    return ContextSummary(
      version: json['version'] as int? ?? 1,
      text: json['text'] as String? ?? '',
      coveredMessageCount: json['coveredMessageCount'] as int? ?? 0,
      coveredDigest: json['coveredDigest'] as String? ?? '',
      sourceEstimatedTokens: json['sourceEstimatedTokens'] as int? ?? 0,
      summaryEstimatedTokens: json['summaryEstimatedTokens'] as int? ?? 0,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
      model: json['model'] as String?,
      apiFormat: json['apiFormat'] as String?,
    );
  }
}

enum AgentRunRecoveryPhase {
  modelPending,
  toolInFlight,
}

enum ToolAttemptLifecycle {
  proposed,
  approvalPending,
  approvedNotStarted,
  started,
  completed,
  failed,
  resultPersisted,
  interruptedUnknown,
}

enum RecoveryToolRisk {
  safe,
  moderate,
  dangerous,
  unknown,
}

enum InterruptedRunRecoveryKind {
  retryModelTurn,
  reauthorizeAction,
  unknownOutcome,
  inspectOnly,
}

class ToolAttemptRecoveryMetadata {
  static const _allowedJsonKeys = {
    'operationId',
    'toolName',
    'risk',
    'lifecycle',
    'proposedAt',
    'updatedAt',
    'executionStartedAt',
    'executionOutcomeKnown',
  };
  static const _requiredJsonKeys = {
    'operationId',
    'toolName',
    'risk',
    'lifecycle',
    'proposedAt',
    'updatedAt',
  };
  static final _safeIdPattern = RegExp(r'^[a-zA-Z0-9._:-]+$');
  static final _safeToolNamePattern = RegExp(r'^[a-zA-Z0-9._:-]+$');

  final String operationId;
  final String toolName;
  final RecoveryToolRisk risk;
  final ToolAttemptLifecycle lifecycle;
  final DateTime proposedAt;
  final DateTime updatedAt;
  final DateTime? executionStartedAt;
  final bool executionOutcomeKnown;

  const ToolAttemptRecoveryMetadata({
    required this.operationId,
    required this.toolName,
    required this.risk,
    required this.lifecycle,
    required this.proposedAt,
    required this.updatedAt,
    this.executionStartedAt,
    this.executionOutcomeKnown = false,
  });

  bool get hasUnknownOutcome =>
      lifecycle == ToolAttemptLifecycle.started ||
      lifecycle == ToolAttemptLifecycle.completed ||
      lifecycle == ToolAttemptLifecycle.interruptedUnknown ||
      (lifecycle == ToolAttemptLifecycle.failed &&
          executionStartedAt != null &&
          !executionOutcomeKnown);

  bool get needsRenewedApproval =>
      risk != RecoveryToolRisk.safe &&
      (lifecycle == ToolAttemptLifecycle.proposed ||
          lifecycle == ToolAttemptLifecycle.approvalPending ||
          lifecycle == ToolAttemptLifecycle.approvedNotStarted);

  Map<String, dynamic> toJson() => {
        'operationId': operationId,
        'toolName': toolName,
        'risk': risk.name,
        'lifecycle': lifecycle.name,
        'proposedAt': proposedAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        if (executionStartedAt != null)
          'executionStartedAt': executionStartedAt!.toIso8601String(),
        if (executionOutcomeKnown) 'executionOutcomeKnown': true,
      };

  factory ToolAttemptRecoveryMetadata.fromJson(Map<String, dynamic> json) {
    final proposedAt = _parseTimestamp(json['proposedAt']);
    return ToolAttemptRecoveryMetadata(
      operationId: _safeIdentifier(json['operationId']) ?? 'invalid_operation',
      toolName: _safeToolName(json['toolName']),
      risk: _enumByName(
        RecoveryToolRisk.values,
        json['risk'],
        RecoveryToolRisk.unknown,
      ),
      lifecycle: _enumByName(
        ToolAttemptLifecycle.values,
        json['lifecycle'],
        ToolAttemptLifecycle.interruptedUnknown,
      ),
      proposedAt: proposedAt,
      updatedAt: _parseTimestamp(json['updatedAt'], fallback: proposedAt),
      executionStartedAt: json['executionStartedAt'] == null
          ? null
          : DateTime.tryParse(json['executionStartedAt'].toString()),
      executionOutcomeKnown: json['executionOutcomeKnown'] == true,
    );
  }

  ToolAttemptRecoveryMetadata copyWith({
    ToolAttemptLifecycle? lifecycle,
    DateTime? updatedAt,
    DateTime? executionStartedAt,
    bool? executionOutcomeKnown,
  }) {
    return ToolAttemptRecoveryMetadata(
      operationId: operationId,
      toolName: toolName,
      risk: risk,
      lifecycle: lifecycle ?? this.lifecycle,
      proposedAt: proposedAt,
      updatedAt: updatedAt ?? this.updatedAt,
      executionStartedAt: executionStartedAt ?? this.executionStartedAt,
      executionOutcomeKnown:
          executionOutcomeKnown ?? this.executionOutcomeKnown,
    );
  }

  static bool isSanitizedJson(Map<String, dynamic> json) {
    final operationId = json['operationId'];
    final toolName = json['toolName'];
    final proposedAt = DateTime.tryParse(json['proposedAt']?.toString() ?? '');
    final updatedAt = DateTime.tryParse(json['updatedAt']?.toString() ?? '');
    final executionStartedAt = json['executionStartedAt'] == null
        ? null
        : DateTime.tryParse(json['executionStartedAt']?.toString() ?? '');
    final lifecycle = _enumByName(
      ToolAttemptLifecycle.values,
      json['lifecycle'],
      ToolAttemptLifecycle.interruptedUnknown,
    );
    final outcomeKnown = json['executionOutcomeKnown'] == true;
    final knownExecutionRequired = lifecycle == ToolAttemptLifecycle.started ||
        lifecycle == ToolAttemptLifecycle.completed ||
        lifecycle == ToolAttemptLifecycle.interruptedUnknown;
    final preStartLifecycle = lifecycle == ToolAttemptLifecycle.proposed ||
        lifecycle == ToolAttemptLifecycle.approvalPending ||
        lifecycle == ToolAttemptLifecycle.approvedNotStarted;
    return json.keys.every(_allowedJsonKeys.contains) &&
        json.keys.toSet().containsAll(_requiredJsonKeys) &&
        (json['executionOutcomeKnown'] == null ||
            json['executionOutcomeKnown'] is bool) &&
        operationId is String &&
        operationId.length <= 120 &&
        _safeIdPattern.hasMatch(operationId) &&
        toolName is String &&
        toolName.length <= 120 &&
        _safeToolNamePattern.hasMatch(toolName) &&
        RecoveryToolRisk.values.any((value) => value.name == json['risk']) &&
        ToolAttemptLifecycle.values
            .any((value) => value.name == json['lifecycle']) &&
        proposedAt != null &&
        updatedAt != null &&
        !updatedAt.isBefore(proposedAt) &&
        (json['executionStartedAt'] == null ||
            (executionStartedAt != null &&
                !executionStartedAt.isBefore(proposedAt) &&
                !executionStartedAt.isAfter(updatedAt))) &&
        (!knownExecutionRequired || executionStartedAt != null) &&
        (!preStartLifecycle || executionStartedAt == null) &&
        (!(preStartLifecycle || lifecycle == ToolAttemptLifecycle.started) ||
            !outcomeKnown) &&
        (lifecycle != ToolAttemptLifecycle.completed || outcomeKnown) &&
        (lifecycle != ToolAttemptLifecycle.resultPersisted || outcomeKnown) &&
        !(lifecycle == ToolAttemptLifecycle.interruptedUnknown &&
            outcomeKnown) &&
        !(lifecycle == ToolAttemptLifecycle.failed &&
            executionStartedAt == null &&
            !outcomeKnown);
  }

  static String? _safeIdentifier(Object? raw) {
    if (raw is! String ||
        raw.isEmpty ||
        raw.length > 120 ||
        !_safeIdPattern.hasMatch(raw)) {
      return null;
    }
    return raw;
  }

  static String _safeToolName(Object? raw) {
    if (raw is String &&
        raw.isNotEmpty &&
        raw.length <= 120 &&
        _safeToolNamePattern.hasMatch(raw)) {
      return raw;
    }
    return 'unknown';
  }
}

class RecoverySkillActivationMetadata {
  static const _allowedJsonKeys = {
    'sourceRunAttemptId',
    'skillId',
    'trustDigest',
  };
  static final _safeIdPattern = RegExp(r'^[a-zA-Z0-9._:-]+$');
  static final _safeSkillIdPattern = RegExp(r'^[a-zA-Z0-9._-]+$');
  static final _trustDigestPattern = RegExp(r'^[a-f0-9]{64}$');

  final String sourceRunAttemptId;
  final String skillId;
  final String trustDigest;

  const RecoverySkillActivationMetadata({
    required this.sourceRunAttemptId,
    required this.skillId,
    required this.trustDigest,
  });

  Map<String, dynamic> toJson() => {
        'sourceRunAttemptId': sourceRunAttemptId,
        'skillId': skillId,
        'trustDigest': trustDigest,
      };

  factory RecoverySkillActivationMetadata.fromJson(
    Map<String, dynamic> json,
  ) {
    return RecoverySkillActivationMetadata(
      sourceRunAttemptId: json['sourceRunAttemptId'] as String,
      skillId: json['skillId'] as String,
      trustDigest: json['trustDigest'] as String,
    );
  }

  static bool isSanitizedJson(Map<String, dynamic> json) {
    final sourceRunAttemptId = json['sourceRunAttemptId'];
    final skillId = json['skillId'];
    final trustDigest = json['trustDigest'];
    return json.length == _allowedJsonKeys.length &&
        json.keys.every(_allowedJsonKeys.contains) &&
        sourceRunAttemptId is String &&
        sourceRunAttemptId.isNotEmpty &&
        sourceRunAttemptId.length <= 120 &&
        _safeIdPattern.hasMatch(sourceRunAttemptId) &&
        skillId is String &&
        skillId.isNotEmpty &&
        skillId.length <= 120 &&
        _safeSkillIdPattern.hasMatch(skillId) &&
        trustDigest is String &&
        _trustDigestPattern.hasMatch(trustDigest);
  }
}

class AgentRunRecoveryMarker {
  static const currentVersion = 2;
  static const _allowedJsonKeys = {
    'version',
    'runAttemptId',
    'startedAt',
    'updatedAt',
    'phase',
    'toolAttempts',
    'skillActivation',
    'metadataCorrupted',
  };
  static const _requiredJsonKeys = {
    'version',
    'runAttemptId',
    'startedAt',
    'updatedAt',
    'phase',
    'toolAttempts',
  };
  static const _legacyJsonKeys = {'startedAt'};
  static final _safeIdPattern = RegExp(r'^[a-zA-Z0-9._:-]+$');

  final int version;
  final String runAttemptId;
  final DateTime startedAt;
  final DateTime updatedAt;
  final AgentRunRecoveryPhase phase;
  final List<ToolAttemptRecoveryMetadata> toolAttempts;
  final RecoverySkillActivationMetadata? skillActivation;
  final bool metadataCorrupted;

  const AgentRunRecoveryMarker({
    this.version = currentVersion,
    required this.runAttemptId,
    required this.startedAt,
    required this.updatedAt,
    this.phase = AgentRunRecoveryPhase.modelPending,
    this.toolAttempts = const [],
    this.skillActivation,
    this.metadataCorrupted = false,
  });

  InterruptedRunRecoveryKind get recoveryKind {
    if (metadataCorrupted) return InterruptedRunRecoveryKind.inspectOnly;
    if (toolAttempts.any((attempt) => attempt.hasUnknownOutcome)) {
      return InterruptedRunRecoveryKind.unknownOutcome;
    }
    if (toolAttempts.any((attempt) => attempt.needsRenewedApproval)) {
      return InterruptedRunRecoveryKind.reauthorizeAction;
    }
    return InterruptedRunRecoveryKind.retryModelTurn;
  }

  bool get hasPersistedToolResults => toolAttempts.any(
        (attempt) => attempt.lifecycle == ToolAttemptLifecycle.resultPersisted,
      );

  bool get canClearAfterPositiveTerminal =>
      !metadataCorrupted &&
      !toolAttempts.any((attempt) => attempt.hasUnknownOutcome);

  Map<String, dynamic> toJson() => {
        'version': version,
        'runAttemptId': runAttemptId,
        'startedAt': startedAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'phase': phase.name,
        'toolAttempts':
            toolAttempts.map((attempt) => attempt.toJson()).toList(),
        if (skillActivation != null)
          'skillActivation': skillActivation!.toJson(),
        if (metadataCorrupted) 'metadataCorrupted': true,
      };

  factory AgentRunRecoveryMarker.fromJson(Map<String, dynamic> json) {
    final startedAt = _parseTimestamp(json['startedAt']);
    final isLegacy = json['version'] == null && json['runAttemptId'] == null;
    final rawToolAttempts = json['toolAttempts'];
    final rawSkillActivation = json['skillActivation'];
    final toolAttempts = <ToolAttemptRecoveryMetadata>[];
    RecoverySkillActivationMetadata? skillActivation;
    var corrupted = json['metadataCorrupted'] == true;
    if (isLegacy) {
      if (!json.keys.every(_legacyJsonKeys.contains)) corrupted = true;
    } else {
      if (!json.keys.every(_allowedJsonKeys.contains) ||
          !json.keys.toSet().containsAll(_requiredJsonKeys) ||
          json['version'] is! int) {
        corrupted = true;
      }
    }
    if (json['metadataCorrupted'] != null &&
        json['metadataCorrupted'] is! bool) {
      corrupted = true;
    }
    if (rawSkillActivation != null) {
      if (rawSkillActivation is! Map) {
        corrupted = true;
      } else {
        final activationJson = Map<String, dynamic>.from(rawSkillActivation);
        if (!RecoverySkillActivationMetadata.isSanitizedJson(
          activationJson,
        )) {
          corrupted = true;
        } else {
          skillActivation =
              RecoverySkillActivationMetadata.fromJson(activationJson);
        }
      }
    }
    if (DateTime.tryParse(json['startedAt']?.toString() ?? '') == null) {
      corrupted = true;
    }
    if (!isLegacy &&
        (json['version'] != currentVersion ||
            DateTime.tryParse(json['updatedAt']?.toString() ?? '') == null)) {
      corrupted = true;
    }
    if (rawToolAttempts == null) {
      // Version 1 markers had only startedAt.
    } else if (rawToolAttempts is List) {
      if (rawToolAttempts.length > 100) corrupted = true;
      final operationIds = <String>{};
      for (final rawAttempt in rawToolAttempts.take(100)) {
        if (rawAttempt is! Map) {
          corrupted = true;
          continue;
        }
        final attemptJson = Map<String, dynamic>.from(rawAttempt);
        if (!ToolAttemptRecoveryMetadata.isSanitizedJson(attemptJson)) {
          corrupted = true;
        }
        final attempt = ToolAttemptRecoveryMetadata.fromJson(attemptJson);
        if (!operationIds.add(attempt.operationId)) {
          corrupted = true;
          continue;
        }
        toolAttempts.add(attempt);
      }
    } else {
      corrupted = true;
    }
    final rawRunAttemptId = json['runAttemptId'];
    final runAttemptId = _safeIdentifier(rawRunAttemptId) ??
        'legacy_${startedAt.microsecondsSinceEpoch}';
    if (!isLegacy && _safeIdentifier(rawRunAttemptId) == null) {
      corrupted = true;
    }
    final phase = _enumByName(
      AgentRunRecoveryPhase.values,
      json['phase'],
      AgentRunRecoveryPhase.modelPending,
    );
    if (!isLegacy &&
        !AgentRunRecoveryPhase.values
            .any((value) => value.name == json['phase'])) {
      corrupted = true;
    }
    final updatedAt = _parseTimestamp(json['updatedAt'], fallback: startedAt);
    if (updatedAt.isBefore(startedAt)) corrupted = true;
    for (final attempt in toolAttempts) {
      if (attempt.proposedAt.isBefore(startedAt) ||
          attempt.updatedAt.isAfter(updatedAt)) {
        corrupted = true;
      }
    }
    final expectedPhase = toolAttempts.isNotEmpty &&
            toolAttempts.any(
              (attempt) =>
                  attempt.lifecycle != ToolAttemptLifecycle.resultPersisted,
            )
        ? AgentRunRecoveryPhase.toolInFlight
        : AgentRunRecoveryPhase.modelPending;
    if (!isLegacy && phase != expectedPhase) corrupted = true;
    return AgentRunRecoveryMarker(
      version: currentVersion,
      runAttemptId: runAttemptId,
      startedAt: startedAt,
      updatedAt: updatedAt,
      phase: phase,
      toolAttempts: List.unmodifiable(toolAttempts),
      skillActivation: skillActivation,
      metadataCorrupted: corrupted,
    );
  }

  AgentRunRecoveryMarker copyWith({
    DateTime? updatedAt,
    AgentRunRecoveryPhase? phase,
    List<ToolAttemptRecoveryMetadata>? toolAttempts,
    RecoverySkillActivationMetadata? skillActivation,
    bool? metadataCorrupted,
  }) {
    return AgentRunRecoveryMarker(
      version: currentVersion,
      runAttemptId: runAttemptId,
      startedAt: startedAt,
      updatedAt: updatedAt ?? this.updatedAt,
      phase: phase ?? this.phase,
      toolAttempts: toolAttempts ?? this.toolAttempts,
      skillActivation: skillActivation ?? this.skillActivation,
      metadataCorrupted: metadataCorrupted ?? this.metadataCorrupted,
    );
  }

  AgentRunRecoveryMarker upsertToolAttempt(
    ToolAttemptRecoveryMetadata attempt,
  ) {
    final nextAttempts = List<ToolAttemptRecoveryMetadata>.from(toolAttempts);
    final index = nextAttempts.indexWhere(
      (existing) => existing.operationId == attempt.operationId,
    );
    if (index >= 0) {
      nextAttempts[index] = attempt;
    } else {
      nextAttempts.add(attempt);
    }
    return copyWith(
      updatedAt: attempt.updatedAt,
      phase: attempt.lifecycle == ToolAttemptLifecycle.resultPersisted
          ? (nextAttempts.every((candidate) =>
                  candidate.lifecycle == ToolAttemptLifecycle.resultPersisted)
              ? AgentRunRecoveryPhase.modelPending
              : AgentRunRecoveryPhase.toolInFlight)
          : AgentRunRecoveryPhase.toolInFlight,
      toolAttempts: List.unmodifiable(nextAttempts),
    );
  }

  static String? _safeIdentifier(Object? raw) {
    if (raw is! String ||
        raw.isEmpty ||
        raw.length > 120 ||
        !_safeIdPattern.hasMatch(raw)) {
      return null;
    }
    return raw;
  }
}

T _enumByName<T extends Enum>(List<T> values, Object? raw, T fallback) {
  if (raw is! String) return fallback;
  for (final value in values) {
    if (value.name == raw) return value;
  }
  return fallback;
}

DateTime _parseTimestamp(Object? raw, {DateTime? fallback}) {
  return DateTime.tryParse(raw?.toString() ?? '') ??
      fallback ??
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
}

class ChatSession {
  static final _validIdPattern = RegExp(r'^[a-zA-Z0-9_-]+$');

  final String id;
  String title;
  final DateTime createdAt;
  DateTime updatedAt;
  final List<ChatMessage> messages;
  String? modelOverride; // null = use global default
  String? baseUrlOverride; // null = use global default
  String? apiFormatOverride; // null = use global default
  String? systemPrompt; // null = use global default
  String? folder; // null = ungrouped
  String? modelGroupId; // null = use active provider profile
  String? remoteAgentConnectorId; // explicit per-session external opt-in
  ContextSummary? contextSummary;
  AgentRunRecoveryMarker? inFlightAgentRun;
  final List<WorkspaceImportReceipt> pendingWorkspaceImports;
  final List<StructuredActionReceipt> structuredActionReceipts;

  ChatSession({
    required this.id,
    this.title = '新对话',
    DateTime? createdAt,
    DateTime? updatedAt,
    List<ChatMessage>? messages,
    this.modelOverride,
    this.baseUrlOverride,
    this.apiFormatOverride,
    this.systemPrompt,
    this.folder,
    this.modelGroupId,
    this.remoteAgentConnectorId,
    this.contextSummary,
    this.inFlightAgentRun,
    List<WorkspaceImportReceipt>? pendingWorkspaceImports,
    List<StructuredActionReceipt>? structuredActionReceipts,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now(),
        messages = messages ?? [],
        pendingWorkspaceImports = pendingWorkspaceImports ?? [],
        structuredActionReceipts = structuredActionReceipts ?? [];

  void autoTitle() {
    final firstUserMsg = messages.where((m) => m.role == 'user').firstOrNull;
    if (firstUserMsg != null) {
      final text = firstUserMsg.textContent;
      if (text.isNotEmpty) {
        title = text.length > 50 ? '${text.substring(0, 50)}...' : text;
      }
    }
  }

  List<Map<String, dynamic>> toApiMessages() {
    return messages
        .where((m) => !m.isSystemNotice && !m.hasAssistantError)
        .map((m) => m.toApiJson())
        .where((m) =>
            m['content'] != null &&
            !(m['content'] is List && (m['content'] as List).isEmpty))
        .toList();
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'messages': messages.map((m) => m.toJson()).toList(),
        if (modelOverride != null) 'modelOverride': modelOverride,
        if (baseUrlOverride != null) 'baseUrlOverride': baseUrlOverride,
        if (apiFormatOverride != null) 'apiFormatOverride': apiFormatOverride,
        if (systemPrompt != null) 'systemPrompt': systemPrompt,
        if (folder != null) 'folder': folder,
        if (modelGroupId != null) 'modelGroupId': modelGroupId,
        if (remoteAgentConnectorId != null)
          'remoteAgentConnectorId': remoteAgentConnectorId,
        if (contextSummary != null) 'contextSummary': contextSummary!.toJson(),
        if (inFlightAgentRun != null)
          'inFlightAgentRun': inFlightAgentRun!.toJson(),
        if (pendingWorkspaceImports.isNotEmpty)
          'pendingWorkspaceImports': pendingWorkspaceImports
              .map((receipt) => receipt.toJson())
              .toList(),
        if (structuredActionReceipts.isNotEmpty)
          'structuredActionReceipts': structuredActionReceipts
              .map((receipt) => receipt.toJson())
              .toList(),
      };

  factory ChatSession.fromJson(Map<String, dynamic> json) {
    final rawSummary = json['contextSummary'];
    final rawInFlightAgentRun = json['inFlightAgentRun'];
    final messages = (json['messages'] as List)
        .map((message) => ChatMessage.fromJson(message))
        .toList();
    final parsedStructuredActionReceipts =
        _parseStructuredActionReceipts(json['structuredActionReceipts']);
    _validateStructuredResultOwnership(
      messages,
      parsedStructuredActionReceipts,
    );
    return ChatSession(
      id: _sanitizeId(json['id']?.toString()),
      title: json['title'] as String? ?? '新对话',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
      messages: messages,
      modelOverride: json['modelOverride'] as String?,
      baseUrlOverride: json['baseUrlOverride'] as String?,
      apiFormatOverride: json['apiFormatOverride'] as String?,
      systemPrompt: json['systemPrompt'] as String?,
      folder: json['folder'] as String?,
      modelGroupId: json['modelGroupId'] as String?,
      remoteAgentConnectorId:
          _sanitizeOptionalId(json['remoteAgentConnectorId']),
      contextSummary: rawSummary is Map
          ? ContextSummary.fromJson(Map<String, dynamic>.from(rawSummary))
          : null,
      inFlightAgentRun: rawInFlightAgentRun is Map
          ? AgentRunRecoveryMarker.fromJson(
              Map<String, dynamic>.from(rawInFlightAgentRun),
            )
          : null,
      pendingWorkspaceImports:
          _parsePendingWorkspaceImports(json['pendingWorkspaceImports']),
      structuredActionReceipts: parsedStructuredActionReceipts,
    );
  }

  static String _sanitizeId(String? id) {
    if (id != null && _validIdPattern.hasMatch(id)) return id;
    return const Uuid().v4();
  }

  static String? _sanitizeOptionalId(Object? value) {
    if (value is! String || !_validIdPattern.hasMatch(value)) return null;
    return value;
  }

  ChatSession copyWith({
    String? id,
    String? title,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<ChatMessage>? messages,
    String? modelOverride,
    String? baseUrlOverride,
    String? apiFormatOverride,
    String? systemPrompt,
    String? folder,
    String? modelGroupId,
    String? remoteAgentConnectorId,
    ContextSummary? contextSummary,
    AgentRunRecoveryMarker? inFlightAgentRun,
    List<WorkspaceImportReceipt>? pendingWorkspaceImports,
    List<StructuredActionReceipt>? structuredActionReceipts,
    bool clearFolder = false,
    bool clearModelGroup = false,
    bool clearRemoteAgentConnector = false,
    bool clearContextSummary = false,
    bool clearInFlightAgentRun = false,
  }) {
    return ChatSession(
      id: id ?? this.id,
      title: title ?? this.title,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      messages: messages ?? this.messages,
      modelOverride: modelOverride ?? this.modelOverride,
      baseUrlOverride: baseUrlOverride ?? this.baseUrlOverride,
      apiFormatOverride: apiFormatOverride ?? this.apiFormatOverride,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      folder: clearFolder ? null : (folder ?? this.folder),
      modelGroupId:
          clearModelGroup ? null : (modelGroupId ?? this.modelGroupId),
      remoteAgentConnectorId: clearRemoteAgentConnector
          ? null
          : (remoteAgentConnectorId ?? this.remoteAgentConnectorId),
      contextSummary:
          clearContextSummary ? null : (contextSummary ?? this.contextSummary),
      inFlightAgentRun: clearInFlightAgentRun
          ? null
          : (inFlightAgentRun ?? this.inFlightAgentRun),
      pendingWorkspaceImports:
          pendingWorkspaceImports ?? this.pendingWorkspaceImports,
      structuredActionReceipts:
          structuredActionReceipts ?? this.structuredActionReceipts,
    );
  }

  static List<WorkspaceImportReceipt> _parsePendingWorkspaceImports(
    Object? raw,
  ) {
    if (raw == null) return [];
    if (raw is! List || raw.length > 32) {
      throw const FormatException('Invalid pending workspace imports.');
    }
    final receipts = <WorkspaceImportReceipt>[];
    final operationIds = <String>{};
    final storedPaths = <String>{};
    for (final item in raw) {
      if (item is! Map) {
        throw const FormatException('Invalid pending workspace import.');
      }
      final receipt = WorkspaceImportReceipt.fromJson(
        Map<String, dynamic>.from(item),
      );
      if (!operationIds.add(receipt.operationId) ||
          !storedPaths.add(receipt.storedPath)) {
        throw const FormatException('Duplicate pending workspace import.');
      }
      receipts.add(receipt);
    }
    return receipts;
  }

  static List<StructuredActionReceipt> _parseStructuredActionReceipts(
    Object? raw,
  ) {
    if (raw == null) return [];
    if (raw is! List || raw.length > 256) {
      throw const FormatException('Invalid structured action receipts.');
    }
    final receipts = <StructuredActionReceipt>[];
    final operationIds = <String>{};
    for (final item in raw) {
      if (item is! Map ||
          !operationIds.add(item['operationId']?.toString() ?? '')) {
        throw const FormatException('Invalid structured action receipt.');
      }
      final receipt = StructuredActionReceipt.fromJson(
        Map<String, dynamic>.from(item),
      );
      receipts.add(receipt.reconcileAfterRestart());
    }
    return receipts;
  }

  static void _validateStructuredResultOwnership(
    List<ChatMessage> messages,
    List<StructuredActionReceipt> receipts,
  ) {
    final results = <String, StructuredResultContent>{};
    for (final message in messages) {
      for (final content in message.content) {
        if (content is! StructuredResultContent || content.isInvalid) continue;
        if (results.containsKey(content.document.resultId)) {
          throw const FormatException('Duplicate structured result ID.');
        }
        results[content.document.resultId] = content;
      }
    }
    for (final receipt in receipts) {
      final result = results[receipt.resultId];
      final action = result?.actionById(receipt.actionId);
      if (action == null ||
          action.kind != receipt.actionKind ||
          structuredActionInputDigest(action) != receipt.canonicalInputDigest) {
        throw const FormatException(
            'Structured receipt does not match result.');
      }
    }
  }
}

final class AssistantOutcomeProvenance {
  const AssistantOutcomeProvenance({
    required this.model,
    this.outputTokens,
    this.latencyMs,
  });

  final String model;
  final int? outputTokens;
  final int? latencyMs;

  Map<String, dynamic> toJson() => {
        'model': model,
        if (outputTokens != null) 'outputTokens': outputTokens,
        if (latencyMs != null) 'latencyMs': latencyMs,
      };

  factory AssistantOutcomeProvenance.fromJson(Map<String, dynamic> json) {
    final model = json['model'];
    if (model is! String || model.isEmpty || model.length > 120) {
      throw const FormatException('Invalid alternative provenance.');
    }
    final outputTokens = json['outputTokens'];
    final latencyMs = json['latencyMs'];
    if ((outputTokens != null &&
            (outputTokens is! int ||
                outputTokens < 0 ||
                outputTokens > 10000000)) ||
        (latencyMs != null &&
            (latencyMs is! int || latencyMs < 0 || latencyMs > 86400000))) {
      throw const FormatException('Invalid alternative provenance.');
    }
    return AssistantOutcomeProvenance(
      model: model,
      outputTokens: outputTokens as int?,
      latencyMs: latencyMs as int?,
    );
  }
}

class ChatMessage {
  static const int maxAlternatives = 4;
  final String role;
  List<MessageContent> content;
  final DateTime timestamp;
  int? inputTokens;
  int? outputTokens;
  int? cacheReadInputTokens;
  int? cacheCreationInputTokens;
  bool inputTokensIncludeCache;
  final List<String>? alternatives; // previous generation texts
  final List<AssistantOutcomeProvenance?>? alternativeProvenance;
  final AssistantOutcomeProvenance? currentProvenance;
  int activeAlternative; // -1 = current content, 0+ = index into alternatives
  final bool isSystemNotice;
  final AssistantErrorMetadata? assistantError;

  ChatMessage({
    required this.role,
    required this.content,
    DateTime? timestamp,
    this.inputTokens,
    this.outputTokens,
    this.cacheReadInputTokens,
    this.cacheCreationInputTokens,
    this.inputTokensIncludeCache = false,
    this.alternatives,
    this.alternativeProvenance,
    this.currentProvenance,
    this.activeAlternative = -1,
    this.isSystemNotice = false,
    this.assistantError,
  }) : timestamp = timestamp ?? DateTime.now();

  factory ChatMessage.assistantError({
    required AssistantErrorMetadata error,
    DateTime? timestamp,
  }) {
    return ChatMessage(
      role: 'assistant',
      content: const [],
      timestamp: timestamp,
      assistantError: error,
    );
  }

  /// Total number of versions (current + alternatives).
  int get totalVersions => 1 + (alternatives?.length ?? 0);

  /// Which version is currently showing (1-based for display).
  /// Current content is the latest (totalVersions), alternatives are 1..N.
  int get displayIndex {
    if (activeAlternative == -1) return totalVersions;
    return activeAlternative + 1;
  }

  /// Create a copy with current text pushed into alternatives and new content set.
  ChatMessage withNewAlternative(List<MessageContent> newContent) {
    final alts = List<String>.from(alternatives ?? []);
    final provenance = List<AssistantOutcomeProvenance?>.from(
      alternativeProvenance ?? List.filled(alts.length, null),
    );
    // Push the canonical latest text into alternatives.
    alts.add(latestTextContent);
    provenance.add(currentProvenance);
    if (alts.length > maxAlternatives) {
      final removeCount = alts.length - maxAlternatives;
      alts.removeRange(0, removeCount);
      provenance.removeRange(0, removeCount);
    }
    return ChatMessage(
      role: role,
      content: newContent,
      timestamp: DateTime.now(),
      alternatives: alts,
      alternativeProvenance: provenance,
      activeAlternative: -1,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      cacheReadInputTokens: cacheReadInputTokens,
      cacheCreationInputTokens: cacheCreationInputTokens,
      inputTokensIncludeCache: inputTokensIncludeCache,
    );
  }

  factory ChatMessage.user(String text) {
    return ChatMessage.userContent([TextContent(text)]);
  }

  factory ChatMessage.systemNotice(String text) {
    return ChatMessage(
      role: 'system',
      content: [TextContent(text)],
      isSystemNotice: true,
    );
  }

  factory ChatMessage.userContent(List<MessageContent> content) {
    return ChatMessage(
      role: 'user',
      content: content,
    );
  }

  factory ChatMessage.assistant(List<Map<String, dynamic>> contentBlocks) {
    final content = contentBlocks.map((block) {
      switch (block['type']) {
        case 'text':
          return TextContent(
            block['text'] as String,
            reasoningContent: block['reasoning_content'] as String?,
          );
        case 'image':
          return _imageContentFromMap(block);
        case 'tool_use':
          return ToolUseContent(
            id: block['id'] as String,
            name: block['name'] as String,
            input: Map<String, dynamic>.from(block['input'] ?? {}),
          );
        default:
          return TextContent(block.toString());
      }
    }).toList();
    return ChatMessage(
        role: 'assistant', content: content.cast<MessageContent>());
  }

  factory ChatMessage.toolResults(List<Map<String, dynamic>> results) {
    final content =
        results.map((r) => ToolResultContent.fromToolResultJson(r)).toList();
    return ChatMessage(role: 'user', content: content.cast<MessageContent>());
  }

  String get textContent {
    if (isViewingAlternative) {
      return alternatives![activeAlternative];
    }
    return latestTextContent;
  }

  String get latestTextContent => _contentText;

  bool get isViewingAlternative {
    final alts = alternatives;
    return alts != null &&
        activeAlternative >= 0 &&
        activeAlternative < alts.length;
  }

  String get _contentText {
    return content.whereType<TextContent>().map((c) => c.text).join('\n');
  }

  List<ToolUseContent> get toolUses =>
      content.whereType<ToolUseContent>().toList();
  List<ToolResultContent> get toolResults =>
      content.whereType<ToolResultContent>().toList();

  bool get hasAssistantError => role == 'assistant' && assistantError != null;

  Map<String, dynamic> toApiJson() {
    if (isViewingAlternative) {
      return {
        'role': role,
        'content': textContent,
      };
    }
    if (content.length == 1 && content[0] is TextContent) {
      final textContent = content[0] as TextContent;
      return {
        'role': role,
        'content': textContent.text,
        if (role == 'assistant' &&
            textContent.reasoningContent?.isNotEmpty == true)
          'reasoning_content': textContent.reasoningContent,
      };
    }
    final reasoningContent = role == 'assistant'
        ? content
            .whereType<TextContent>()
            .map((c) => c.reasoningContent ?? '')
            .where((reasoning) => reasoning.isNotEmpty)
            .join('\n')
        : '';
    final apiContent = content
        .where((item) => item is! StructuredResultContent)
        .toList(growable: false);
    final apiJson = {
      'role': role,
      'content': apiContent.map((c) => c.toApiJson()).toList(),
    };
    if (reasoningContent.isNotEmpty) {
      apiJson['reasoning_content'] = reasoningContent;
    }
    return apiJson;
  }

  Map<String, dynamic> toJson() => {
        'role': role,
        'timestamp': timestamp.toIso8601String(),
        'content': content.map((c) => c.toJson()).toList(),
        if (inputTokens != null) 'inputTokens': inputTokens,
        if (outputTokens != null) 'outputTokens': outputTokens,
        if (cacheReadInputTokens != null)
          'cacheReadInputTokens': cacheReadInputTokens,
        if (cacheCreationInputTokens != null)
          'cacheCreationInputTokens': cacheCreationInputTokens,
        if (inputTokensIncludeCache) 'inputTokensIncludeCache': true,
        if (alternatives != null && alternatives!.isNotEmpty)
          'alternatives': alternatives,
        if (alternativeProvenance != null && alternativeProvenance!.isNotEmpty)
          'alternativeProvenance':
              alternativeProvenance!.map((item) => item?.toJson()).toList(),
        if (currentProvenance != null)
          'currentProvenance': currentProvenance!.toJson(),
        if (activeAlternative != -1) 'activeAlternative': activeAlternative,
        if (isSystemNotice) 'isSystemNotice': true,
        if (assistantError != null) 'assistant_error': assistantError!.toJson(),
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final rawContent = json['content'];
    final List<MessageContent> content;
    if (rawContent is String) {
      content = [
        TextContent(
          rawContent,
          reasoningContent: json['reasoning_content'] as String?,
        ),
      ];
    } else {
      final contentList = rawContent as List;
      content = contentList
          .map((c) {
            final type = c['type'] as String;
            switch (type) {
              case 'text':
                return TextContent(
                  c['text'] as String,
                  reasoningContent: c['reasoning_content'] as String?,
                );
              case 'image':
                return _imageContentFromMap(c);
              case 'tool_use':
                return ToolUseContent(
                  id: c['id'] as String,
                  name: c['name'] as String,
                  input: Map<String, dynamic>.from(c['input'] ?? {}),
                );
              case 'tool_result':
                return ToolResultContent.fromToolResultJson(c);
              case 'structured_result':
                return StructuredResultContent.fromJson(c);
              default:
                return TextContent(c.toString());
            }
          })
          .cast<MessageContent>()
          .toList();
    }
    final altsList = json['alternatives'] as List?;
    final rawAlternativeProvenance = json['alternativeProvenance'];
    final rawCurrentProvenance = json['currentProvenance'];
    final alternatives = altsList
        ?.whereType<String>()
        .take(maxAlternatives)
        .toList(growable: false);
    final alternativeProvenance = rawAlternativeProvenance is List &&
            alternatives != null &&
            rawAlternativeProvenance.length == alternatives.length
        ? rawAlternativeProvenance.map<AssistantOutcomeProvenance?>((raw) {
            if (raw == null) return null;
            if (raw is! Map) return null;
            try {
              return AssistantOutcomeProvenance.fromJson(
                Map<String, dynamic>.from(raw),
              );
            } on FormatException {
              return null;
            }
          }).toList(growable: false)
        : null;
    final rawAssistantError = json['assistant_error'];
    return ChatMessage(
      role: json['role'] as String,
      content: content,
      timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ??
          DateTime.now(),
      inputTokens: json['inputTokens'] as int?,
      outputTokens: json['outputTokens'] as int?,
      cacheReadInputTokens: json['cacheReadInputTokens'] as int?,
      cacheCreationInputTokens: json['cacheCreationInputTokens'] as int?,
      inputTokensIncludeCache:
          json['inputTokensIncludeCache'] as bool? ?? false,
      alternatives: alternatives,
      alternativeProvenance: alternativeProvenance,
      currentProvenance: rawCurrentProvenance is Map
          ? (() {
              try {
                return AssistantOutcomeProvenance.fromJson(
                  Map<String, dynamic>.from(rawCurrentProvenance),
                );
              } on FormatException {
                return null;
              }
            })()
          : null,
      activeAlternative: switch (json['activeAlternative']) {
        final int value
            when value >= 0 && value < (alternatives?.length ?? 0) =>
          value,
        _ => -1,
      },
      isSystemNotice: json['isSystemNotice'] as bool? ?? false,
      assistantError: rawAssistantError is Map
          ? AssistantErrorMetadata.fromJson(
              Map<String, dynamic>.from(rawAssistantError),
            )
          : null,
    );
  }

  static ImageContent _imageContentFromMap(Map<dynamic, dynamic> block) {
    final source = block['source'];
    final sourceMap = source is Map ? source : const <String, dynamic>{};
    return ImageContent(
      data: (sourceMap['data'] ?? block['data'] ?? '') as String,
      mediaType: (sourceMap['media_type'] ?? block['media_type'] ?? 'image/png')
          as String,
      filename: block['filename'] as String?,
    );
  }
}

enum AssistantRetryAction { resendUserMessage, continueRecovery }

class AssistantErrorMetadata {
  static const int currentVersion = 1;

  final String message;
  final String code;
  final bool canRetry;
  final String? source;
  final String? fallbackReasonCode;
  final String? fallbackReasonLabel;
  final AssistantRetryAction retryAction;
  final String? recoveryRunAttemptId;

  const AssistantErrorMetadata({
    required this.message,
    required this.code,
    required this.canRetry,
    this.source,
    this.fallbackReasonCode,
    this.fallbackReasonLabel,
    this.retryAction = AssistantRetryAction.resendUserMessage,
    this.recoveryRunAttemptId,
  });

  bool get isRecoveryRetry =>
      retryAction == AssistantRetryAction.continueRecovery &&
      recoveryRunAttemptId != null;

  Map<String, dynamic> toJson() => {
        'version': currentVersion,
        'message': message,
        'code': code,
        'can_retry': canRetry,
        if (source?.isNotEmpty == true) 'source': source,
        if (fallbackReasonCode?.isNotEmpty == true)
          'fallback_reason_code': fallbackReasonCode,
        if (fallbackReasonLabel?.isNotEmpty == true)
          'fallback_reason_label': fallbackReasonLabel,
        if (isRecoveryRetry) 'retry_action': retryAction.name,
        if (isRecoveryRetry) 'recovery_run_attempt_id': recoveryRunAttemptId,
      };

  factory AssistantErrorMetadata.fromJson(Map<String, dynamic> json) {
    final rawRetryAction = json['retry_action'];
    final recoveryRunAttemptId =
        _optionalSafeIdentifier(json['recovery_run_attempt_id']);
    final recoveryRetry =
        rawRetryAction == AssistantRetryAction.continueRecovery.name &&
            recoveryRunAttemptId != null;
    final retryActionValid = rawRetryAction == null ||
        rawRetryAction == AssistantRetryAction.resendUserMessage.name ||
        recoveryRetry;
    return AssistantErrorMetadata(
      message: _safeText(json['message'], fallback: '模型请求失败'),
      code: _safeCode(json['code'], fallback: 'provider_error'),
      canRetry: (json['can_retry'] as bool? ?? false) && retryActionValid,
      source: _optionalSafeText(json['source']),
      fallbackReasonCode: _optionalSafeCode(json['fallback_reason_code']),
      fallbackReasonLabel: _optionalSafeText(json['fallback_reason_label']),
      retryAction: recoveryRetry
          ? AssistantRetryAction.continueRecovery
          : AssistantRetryAction.resendUserMessage,
      recoveryRunAttemptId: recoveryRetry ? recoveryRunAttemptId : null,
    );
  }

  static String _safeText(Object? value, {required String fallback}) {
    final text = value?.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text == null || text.isEmpty) return fallback;
    const maxRunes = 280;
    final runes = text.runes.toList(growable: false);
    if (runes.length <= maxRunes) return text;
    return '${String.fromCharCodes(runes.take(maxRunes))}...';
  }

  static String? _optionalSafeText(Object? value) {
    final text = _safeText(value, fallback: '');
    return text.isEmpty ? null : text;
  }

  static String _safeCode(Object? value, {required String fallback}) {
    final raw = value?.toString().trim() ?? '';
    final safe = raw.replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');
    return safe.isEmpty ? fallback : safe;
  }

  static String? _optionalSafeCode(Object? value) {
    final code = _safeCode(value, fallback: '');
    return code.isEmpty ? null : code;
  }

  static String? _optionalSafeIdentifier(Object? value) {
    if (value is! String ||
        value.isEmpty ||
        value.length > 120 ||
        !RegExp(r'^[a-zA-Z0-9._:-]+$').hasMatch(value)) {
      return null;
    }
    return value;
  }
}

sealed class MessageContent {
  const MessageContent();

  Map<String, dynamic> toApiJson();
  Map<String, dynamic> toJson();
}

class TextContent extends MessageContent {
  final String text;
  final String? reasoningContent;

  TextContent(this.text, {this.reasoningContent});

  @override
  Map<String, dynamic> toApiJson() => {'type': 'text', 'text': text};

  @override
  Map<String, dynamic> toJson() => {
        'type': 'text',
        'text': text,
        if (reasoningContent?.isNotEmpty == true)
          'reasoning_content': reasoningContent,
      };
}

class ImageContent extends MessageContent {
  final String data;
  final String mediaType;
  final String? filename;

  ImageContent({
    required this.data,
    required this.mediaType,
    this.filename,
  });

  @override
  Map<String, dynamic> toApiJson() => {
        'type': 'image',
        'source': {
          'type': 'base64',
          'media_type': mediaType,
          'data': data,
        },
      };

  @override
  Map<String, dynamic> toJson() => {
        ...toApiJson(),
        if (filename != null) 'filename': filename,
      };
}

class ToolUseContent extends MessageContent {
  static const redactedSecretValue = '[secret-redacted]';

  final String id;
  final String name;
  final Map<String, dynamic> input;
  String? output;
  bool isExecuting;
  bool isError;

  ToolUseContent({
    required this.id,
    required this.name,
    required Map<String, dynamic> input,
    this.output,
    this.isExecuting = false,
    this.isError = false,
  }) : input = sanitizedInput(name, input);

  static Map<String, dynamic> sanitizedInput(
    String toolName,
    Map<dynamic, dynamic> input,
  ) {
    final copy = <String, dynamic>{
      for (final entry in input.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };
    if (toolName == 'set_env_var' && copy.containsKey('value')) {
      copy['value'] = redactedSecretValue;
    }
    return copy;
  }

  @override
  Map<String, dynamic> toApiJson() => {
        'type': 'tool_use',
        'id': id,
        'name': name,
        'input': input,
      };

  @override
  Map<String, dynamic> toJson() => {
        'type': 'tool_use',
        'id': id,
        'name': name,
        'input': input,
        'output': output,
        'is_error': isError,
      };
}

class ToolResultContent extends MessageContent {
  final String toolUseId;
  final ToolResultPayload payload;
  final bool isError;

  ToolResultContent({
    required this.toolUseId,
    String? output,
    String? forLlm,
    String? summary,
    Map<String, dynamic>? metadata,
    ToolResultPayload? payload,
    this.isError = false,
  }) : payload = payload ??
            ToolResultPayload(
              forUser: output ?? '',
              forLlm: forLlm,
              summary: summary,
              metadata: metadata ?? const {},
            );

  factory ToolResultContent.fromToolResultJson(Map<dynamic, dynamic> json) {
    return ToolResultContent(
      toolUseId: json['tool_use_id']?.toString() ?? '',
      output: ToolResultPayload.stringifyContent(
        json['output'] ?? json['content'] ?? '',
      ),
      forLlm: json.containsKey('for_llm')
          ? ToolResultPayload.stringifyContent(json['for_llm'])
          : null,
      summary: json['summary']?.toString(),
      metadata: ToolResultPayload.metadataFromJson(json['metadata']),
      isError: json['is_error'] as bool? ?? false,
    );
  }

  String get output => payload.forUser;
  String get llmOutput => payload.forLlm ?? payload.forUser;
  String? get forLlm => payload.forLlm;
  String? get summary => payload.summary;
  Map<String, dynamic> get metadata => payload.metadata;

  @override
  Map<String, dynamic> toApiJson() => {
        'type': 'tool_result',
        'tool_use_id': toolUseId,
        'content': llmOutput,
        if (isError) 'is_error': true,
      };

  @override
  Map<String, dynamic> toJson() => {
        'type': 'tool_result',
        'tool_use_id': toolUseId,
        'output': output,
        if (payload.forLlm != null) 'for_llm': payload.forLlm,
        if (payload.summary != null) 'summary': payload.summary,
        if (payload.metadata.isNotEmpty) 'metadata': payload.metadata,
        'is_error': isError,
      };
}

class StructuredResultContent extends MessageContent {
  final StructuredResultDocument document;
  final bool isInvalid;
  final String? invalidReasonCode;
  final StructuredResultSkillProvenance? skillProvenance;
  final String? toolUseId;

  const StructuredResultContent({
    required this.document,
    this.isInvalid = false,
    this.invalidReasonCode,
    this.skillProvenance,
    this.toolUseId,
  });

  factory StructuredResultContent.invalid([String? reasonCode]) {
    return StructuredResultContent(
      document: StructuredResultDocument.invalid(),
      isInvalid: true,
      invalidReasonCode: reasonCode,
    );
  }

  factory StructuredResultContent.fromJson(Map<dynamic, dynamic> json) {
    try {
      final raw = json['documentJson'];
      if (raw is! String) {
        return StructuredResultContent.invalid('missing_document');
      }
      return StructuredResultContent(
        document: StructuredResultDocument.parseJson(raw),
        skillProvenance: json['skillProvenance'] == null
            ? null
            : StructuredResultSkillProvenance.fromJson(
                json['skillProvenance'],
              ),
        toolUseId: _structuredToolUseId(json['toolUseId']),
      );
    } on StructuredResultParseException catch (error) {
      return StructuredResultContent.invalid(error.reasonCode);
    } on Object {
      return StructuredResultContent.invalid('invalid_document');
    }
  }

  String get projection => document.projection;

  StructuredResultAction? actionById(String actionId) {
    for (final block in document.blocks) {
      if (block case StructuredActionListBlock(:final actions)) {
        for (final action in actions) {
          if (action.actionId == actionId) return action;
        }
      }
    }
    return null;
  }

  @override
  Map<String, dynamic> toApiJson() => const <String, dynamic>{};

  @override
  Map<String, dynamic> toJson() => {
        'type': 'structured_result',
        'schemaVersion': 1,
        if (!isInvalid) 'documentJson': document.canonicalJson,
        if (skillProvenance != null)
          'skillProvenance': skillProvenance!.toJson(),
        if (toolUseId != null) 'toolUseId': toolUseId,
        if (isInvalid) ...{
          'invalid': true,
          if (invalidReasonCode != null) 'reasonCode': invalidReasonCode,
        },
      };

  static String? _structuredToolUseId(Object? raw) {
    if (raw == null) return null;
    if (raw is! String ||
        raw.isEmpty ||
        raw.length > 160 ||
        !RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(raw)) {
      throw const FormatException('invalid_structured_tool_use_id');
    }
    return raw;
  }
}

class ToolResultPayload {
  final String forUser;
  final String? forLlm;
  final String? summary;
  final Map<String, dynamic> metadata;

  const ToolResultPayload({
    required this.forUser,
    this.forLlm,
    this.summary,
    this.metadata = const {},
  });

  ToolResultPayload copyWith({
    String? forUser,
    String? forLlm,
    String? summary,
    Map<String, dynamic>? metadata,
    bool clearForLlm = false,
    bool clearSummary = false,
  }) {
    return ToolResultPayload(
      forUser: forUser ?? this.forUser,
      forLlm: clearForLlm ? null : (forLlm ?? this.forLlm),
      summary: clearSummary ? null : (summary ?? this.summary),
      metadata: metadata ?? this.metadata,
    );
  }

  String get llmOutput => forLlm ?? forUser;

  static Map<String, dynamic> metadataFromJson(Object? value) {
    if (value is! Map) return const {};
    return {
      for (final entry in value.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };
  }

  static String stringifyContent(Object? value) {
    if (value == null) return '';
    if (value is String) return value;
    if (value is Iterable) return value.map((e) => e.toString()).join('\n');
    return value.toString();
  }
}
