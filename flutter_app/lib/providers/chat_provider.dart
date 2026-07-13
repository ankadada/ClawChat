import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
export '../models/agent_state.dart' show AgentStatus, QueuedMessage;

import '../constants.dart';
import '../models/agent_state.dart';
import '../models/agent_run_center.dart';
import '../models/chat_models.dart';
import '../models/model_capabilities.dart';
import '../models/provider_profile.dart';
import '../models/remote_agent_connector.dart';
import '../models/workspace_import_receipt.dart';
import '../services/agent_service.dart';
import '../services/attachment_budget.dart';
import '../services/context_manager.dart';
import '../services/context_summary_service.dart';
import '../services/diagnostics_export_service.dart';
import '../services/llm_content_sanitizer.dart';
import '../services/llm_service.dart';
import '../services/native_bridge.dart';
import '../services/provider_message_transform.dart';
import '../services/runtime_debug_events.dart';
import '../services/skill_capability_policy.dart';
import '../services/session_storage.dart';
import '../services/startup_restore_guard.dart';
import '../services/tools/tool_policy.dart';
import '../services/tools/tool_registry.dart';
import '../services/tool_call_expansion_state.dart';
import '../services/preferences_service.dart';
import '../services/remote_agent_configuration_service.dart';
import '../services/remote_agent_connector.dart';
import '../services/skill_service.dart';
import '../services/memory_service.dart';
import '../l10n/app_strings.dart';

final class MessageQueueUndo {
  const MessageQueueUndo._({
    required this.sessionId,
    required this.startIndex,
    required this.messages,
  });

  final String sessionId;
  final int startIndex;
  final List<QueuedMessage> messages;
}

final class MessageQueueRestoreResult {
  const MessageQueueRestoreResult({
    required this.restoredCount,
    required this.remainingUndo,
    this.sessionMissing = false,
  });

  final int restoredCount;
  final MessageQueueUndo? remainingUndo;
  final bool sessionMissing;

  int get remainingCount => remainingUndo?.messages.length ?? 0;
  bool get restoredAny => restoredCount > 0;
}

typedef MessageQueueDrainTimerFactory = Timer Function(
  Duration duration,
  void Function() callback,
);

typedef LlmServiceFactory = LlmService Function(
  LlmConfig config, {
  bool Function()? isInBackground,
});

enum EditUserMessageBranchStatus {
  started,
  empty,
  invalidMessage,
  busy,
  missingApiKey,
  failed,
}

enum AssistantRetryStatus {
  started,
  invalidMessage,
  notRetryable,
  busy,
  missingApiKey,
}

enum _ToolApprovalDecisionSource { inApp, notification }

typedef SkillCapabilityPolicyFactory = SkillCapabilityPolicy Function(
  Map<String, String> fixedToolDomains,
);

typedef RemoteConnectorPreflight = FutureOr<void> Function();

/// Mutable Remote Agent capability owned by the app root and observed by one
/// long-lived [ChatProvider]. Changes cancel only active remote operations
/// before publishing the new capability.
final class RemoteAgentRuntimeBinding {
  RemoteAgentRuntimeBinding({
    RemoteAgentConfigurationService? configuration,
    RemoteAgentConnector? connector,
    String unavailableReason = '远程 Agent 当前不可用。',
  })  : _configuration = configuration,
        _connector = connector,
        _unavailableReason = unavailableReason,
        _acceptingClaims = configuration != null {
    if ((configuration == null) != (connector == null)) {
      throw ArgumentError(
        'Remote configuration and connector must be attached together.',
      );
    }
  }

  RemoteAgentConfigurationService? _configuration;
  RemoteAgentConnector? _connector;
  String _unavailableReason;
  Object? _owner;
  VoidCallback? _beforeChange;
  VoidCallback? _afterChange;
  final Set<RemoteAgentRuntimeLease> _leases = {};
  final Set<_RemoteAgentRuntimeCommitPermit> _commitPermits = {};
  int _generation = 0;
  bool _acceptingClaims;
  bool _disposed = false;

  RemoteAgentConfigurationService? get configuration => _configuration;
  RemoteAgentConnector? get connector => _connector;
  String get unavailableReason => _unavailableReason;
  bool get isAttached =>
      _acceptingClaims && _configuration != null && _connector != null;
  int get generation => _generation;

  RemoteAgentRuntimeLease? claim(RemoteAgentCancellation cancellation) {
    _ensureActive();
    final configuration = _configuration;
    final connector = _connector;
    if (!isAttached ||
        configuration == null ||
        connector == null ||
        cancellation.isCancelled) {
      return null;
    }
    final lease = RemoteAgentRuntimeLease._(
      owner: this,
      generation: _generation,
      configuration: configuration,
      connector: connector,
      cancellation: cancellation,
    );
    _leases.add(lease);
    return lease;
  }

  Future<void> attach(
    RemoteAgentConfigurationService configuration,
    RemoteAgentConnector connector,
  ) async {
    _ensureActive();
    if (identical(_configuration, configuration) &&
        identical(_connector, connector) &&
        isAttached) {
      return;
    }
    await _invalidateAttachment();
    _configuration = configuration;
    _connector = connector;
    _unavailableReason = '';
    _acceptingClaims = true;
    _afterChange?.call();
  }

  Future<void> detach({required String reason}) async {
    _ensureActive();
    if (_configuration == null &&
        _connector == null &&
        _unavailableReason == reason) {
      return;
    }
    await _invalidateAttachment();
    _configuration = null;
    _connector = null;
    _unavailableReason = reason;
    _afterChange?.call();
  }

  Future<void> _invalidateAttachment() async {
    _acceptingClaims = false;
    _generation += 1;
    for (final lease in _leases.toList(growable: false)) {
      lease._revoke();
    }
    _leases.clear();
    _beforeChange?.call();
    final permits = _commitPermits
        .map((permit) => permit.completed.future)
        .toList(growable: false);
    if (permits.isNotEmpty) await Future.wait(permits);
  }

  void bind({
    required Object owner,
    required VoidCallback beforeChange,
    required VoidCallback afterChange,
  }) {
    _ensureActive();
    if (_owner != null && !identical(_owner, owner)) {
      throw StateError('Remote runtime binding already has an owner.');
    }
    _owner = owner;
    _beforeChange = beforeChange;
    _afterChange = afterChange;
  }

  void unbind(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _beforeChange = null;
    _afterChange = null;
  }

  void dispose() {
    if (_disposed) return;
    _acceptingClaims = false;
    _generation += 1;
    for (final lease in _leases.toList(growable: false)) {
      lease._revoke();
    }
    _leases.clear();
    _beforeChange?.call();
    _disposed = true;
    _configuration = null;
    _connector = null;
    _owner = null;
    _beforeChange = null;
    _afterChange = null;
  }

  void _ensureActive() {
    if (_disposed) throw StateError('Remote runtime binding is disposed.');
  }

  bool _isLeaseValid(RemoteAgentRuntimeLease lease) =>
      !_disposed &&
      _acceptingClaims &&
      lease.generation == _generation &&
      identical(lease.configuration, _configuration) &&
      identical(lease.connector, _connector) &&
      _leases.contains(lease) &&
      !lease.cancellation.isCancelled;

  void _releaseLease(RemoteAgentRuntimeLease lease) => _leases.remove(lease);

  SessionCommitPermit? _acquireCommit(RemoteAgentRuntimeLease lease) {
    if (!_isLeaseValid(lease)) return null;
    final permit = _RemoteAgentRuntimeCommitPermit(this);
    _commitPermits.add(permit);
    return permit;
  }

  void _completeCommit(_RemoteAgentRuntimeCommitPermit permit) {
    if (!_commitPermits.remove(permit)) return;
    if (!permit.completed.isCompleted) permit.completed.complete();
  }
}

final class RemoteAgentRuntimeLease implements SessionCommitAuthority {
  RemoteAgentRuntimeLease._({
    required RemoteAgentRuntimeBinding owner,
    required this.generation,
    required this.configuration,
    required this.connector,
    required this.cancellation,
  }) : _owner = owner;

  final RemoteAgentRuntimeBinding _owner;
  @override
  final int generation;
  final RemoteAgentConfigurationService configuration;
  final RemoteAgentConnector connector;
  final RemoteAgentCancellation cancellation;
  bool _revoked = false;
  bool _released = false;

  @override
  bool get isValid => !_released && _owner._isLeaseValid(this);
  bool get wasRevoked => _revoked;

  void release() {
    if (_released) return;
    _released = true;
    _owner._releaseLease(this);
  }

  void _revoke() {
    if (_released || _revoked) return;
    _revoked = true;
    cancellation.cancel();
  }

  @override
  SessionCommitPermit? tryAcquireCommit() => _owner._acquireCommit(this);
}

final class _RemoteAgentRuntimeCommitPermit implements SessionCommitPermit {
  _RemoteAgentRuntimeCommitPermit(this._owner);

  final RemoteAgentRuntimeBinding _owner;
  final Completer<void> completed = Completer<void>();
  bool _complete = false;

  @override
  void complete() {
    if (_complete) return;
    _complete = true;
    _owner._completeCommit(this);
  }
}

final class _RemoteCompositeCommitAuthority implements SessionCommitAuthority {
  const _RemoteCompositeCommitAuthority(this.runtime, this.authorization);

  final RemoteAgentRuntimeLease runtime;
  final RemoteAgentAuthorizationLease authorization;

  @override
  int get generation =>
      Object.hash(runtime.generation, authorization.generation);

  @override
  bool get isValid => runtime.isValid && authorization.isValid;

  @override
  SessionCommitPermit? tryAcquireCommit() {
    final runtimePermit = runtime.tryAcquireCommit();
    if (runtimePermit == null) return null;
    final authorizationPermit = authorization.tryAcquireCommit();
    if (authorizationPermit == null) {
      runtimePermit.complete();
      return null;
    }
    return _RemoteCompositeCommitPermit(
      runtimePermit,
      authorizationPermit,
    );
  }
}

final class _RemoteCompositeCommitPermit implements SessionCommitPermit {
  _RemoteCompositeCommitPermit(this.runtime, this.authorization);

  final SessionCommitPermit runtime;
  final SessionCommitPermit authorization;
  bool _complete = false;

  @override
  void complete() {
    if (_complete) return;
    _complete = true;
    authorization.complete();
    runtime.complete();
  }
}

class ManualContextSummaryResult {
  final bool success;
  final String message;
  final ContextSummary? summary;
  final int requestedApiMessageCount;
  final int coveredMessageCount;

  const ManualContextSummaryResult({
    required this.success,
    required this.message,
    this.summary,
    this.requestedApiMessageCount = 0,
    this.coveredMessageCount = 0,
  });
}

class ChatProvider extends ChangeNotifier {
  static const int maxQueuedMessages = 3;

  List<SessionSummary> sessions = [];
  ChatSession? currentSession;

  final SessionStorage _storage;
  final LlmServiceFactory _llmServiceFactory;
  late final ContextManager _contextManager;
  final RuntimeDebugEventService runtimeDebugEvents;
  final StartupRestoreGuard _startupRestoreGuard;
  final DiagnosticsExportService _diagnosticsExportService;
  final AttachmentBudget _attachmentBudget;
  final SkillCapabilityPolicyFactory _skillCapabilityPolicyFactory;
  final RemoteAgentRuntimeBinding _remoteAgentRuntimeBinding;
  final bool _ownsRemoteAgentRuntimeBinding;
  RemoteAgentConfigurationService? get _remoteAgentConfiguration =>
      _remoteAgentRuntimeBinding.configuration;
  RemoteAgentConnector? get _remoteAgentConnector =>
      _remoteAgentRuntimeBinding.connector;
  final MessageQueueDrainTimerFactory _messageQueueDrainTimerFactory;
  final RemoteConnectorPreflight? _beforeRemoteConnectorSendForTesting;
  final Map<String, RemoteAgentCancellation> _remoteAgentCancellations = {};
  late final ToolRegistry _tools;
  final _uuid = const Uuid();

  final PreferencesService _prefs = PreferencesService();
  bool _prefsInitialized = false;
  bool _persistedDeveloperModeApplied = false;
  String get configuredModel {
    if (!_prefsInitialized) return AppConstants.defaultModel;
    return _prefs.model ?? AppConstants.defaultModel;
  }

  String get configuredProfileName {
    if (!_prefsInitialized) return '';
    return _prefs.activeProfile.displayName;
  }

  String get configuredModelLabel {
    if (!_prefsInitialized) return AppConstants.defaultModel;
    final profile = _prefs.activeProfile;
    return '${profile.displayName} · ${profile.effectiveModel}';
  }

  List<ProviderProfile> get providerProfiles {
    if (!_prefsInitialized) return const [];
    return _prefs.profiles;
  }

  String? get activeProfileId {
    if (!_prefsInitialized) return null;
    return _prefs.activeProfileId;
  }

  String get toolApprovalPolicy {
    if (!_prefsInitialized) return PreferencesService.defaultToolApprovalPolicy;
    return _prefs.toolApprovalPolicy;
  }

  int get maxConcurrentAgents {
    if (!_prefsInitialized) {
      return PreferencesService.defaultMaxConcurrentAgents;
    }
    return _prefs.maxConcurrentAgents;
  }

  List<SkillInfo> _skills = [];

  bool _disposed = false;
  bool _safeMode = false;
  bool _startupRestoreGuardReady = false;
  String? _pendingStartupSessionId;
  int _startupFailureCount = 0;
  bool get safeMode => _safeMode;
  int get startupFailureCount => _startupFailureCount;
  bool get developerMode => runtimeDebugEvents.tracingEnabled;

  void setDeveloperMode(bool enabled) {
    _prefs.developerMode = enabled;
    runtimeDebugEvents.setTracingEnabled(enabled);
    _persistedDeveloperModeApplied = true;
    notifyListeners();
  }

  int _messageVersion = 0;
  int get messageVersion => _messageVersion;
  final Map<String, String> _drafts = {};
  final Map<String, AgentState> _agentStates = {};
  final Map<String, _AgentRunToken> _activeRunTokens = {};
  final Map<String, _SessionReplayOperation> _sessionReplayOperations = {};
  int _nextSessionReplayGeneration = 0;
  final Set<String> _deletingSessionIds = {};
  final Set<String> _manualContextSummarySessions = {};
  String? _fallbackErrorMessage;
  ToolApprovalRequest? pendingApproval;
  AgentState? _pendingApprovalState;
  Completer<bool>? _approvalCompleter;
  _ToolApprovalDecisionSource? _approvalDecisionSource;
  bool _appInBackground = false;

  static const _agentServiceThinkingText = 'AI 正在思考...';
  static const _agentServiceToolingText = 'AI 正在执行命令...';
  static const _agentServiceStreamingText = 'AI 正在回复...';
  static const _agentServiceReconnectingText = '连接中断，正在重新生成...';
  static const _liveReasoningPreviewMaxChars = 12000;
  static const _liveReasoningPreviewTrimAt = 14000;
  static const _agentRunRecoveryPrompt =
      '上次任务被中断。请基于当前会话继续完成被中断的任务；如果已有部分内容，请不要重复已经完成的部分。';
  static const _agentRunReauthorizationPrompt =
      '上次任务在工具执行前被中断，旧授权已经失效。请基于当前会话重新评估；如仍需该操作，请作为新的工具尝试提出并重新请求授权，不要直接重放旧调用。';
  static const _agentRunUnknownOutcomePrompt =
      '上次工具操作的完成结果未知。请把它视为一次新的恢复请求，不要重放或假定旧调用成功；如仍需执行任何操作，请先说明风险并重新请求授权。';
  static const _agentRunPersistedResultPrompt =
      '上次任务被中断，但已完成工具的结果已经保存在当前会话。请从已保存结果继续，不要再次执行已经完成的工具调用。';
  static const _backgroundApprovalUnavailableMessage =
      '后台工具审批不可用。请回到 ClawChat，启用系统通知后重试；本次工具不会执行。';

  AgentState _getOrCreateState(String sessionId) {
    return _agentStates.putIfAbsent(sessionId, () => AgentState(sessionId));
  }

  AgentState? _getState(String? sessionId) {
    return sessionId != null ? _agentStates[sessionId] : null;
  }

  void _bindAgentStateToSession(AgentState state, ChatSession session) {
    state
      ..sessionTitle = session.title
      ..sessionExecutionMetadataKnown = true
      ..isRemoteSessionExecution = session.remoteAgentConnectorId != null
      ..safeExecutionDisplayName = _safeExecutionDisplayName(session);
  }

  String? _safeExecutionDisplayName(ChatSession session) {
    final connectorId = session.remoteAgentConnectorId;
    if (connectorId != null) {
      final config = _remoteAgentConfiguration?.config;
      return config?.id == connectorId ? config?.displayName : null;
    }
    final model = session.modelOverride?.trim();
    if (model?.isNotEmpty == true) return model;
    final groupId = session.modelGroupId;
    if (groupId != null) {
      for (final group in modelGroups) {
        if (group.id == groupId) return group.displayName;
      }
    }
    return null;
  }

  _AgentRunToken _beginRun(
    AgentState state,
    String runAttemptId, {
    _RecoverySkillProvenance skillProvenance =
        const _RecoverySkillProvenance.empty(),
  }) {
    final generation = ++state.runGeneration;
    state.activeRunAttemptId = runAttemptId;
    final token = _AgentRunToken(
      state: state,
      runAttemptId: runAttemptId,
      generation: generation,
      storageGeneration: _storage.sessionGeneration(state.sessionId),
      skillProvenance: skillProvenance,
    );
    _activeRunTokens[state.sessionId] = token;
    return token;
  }

  bool _ownsRun(_AgentRunToken token) {
    return identical(_activeRunTokens[token.state.sessionId], token) &&
        token.state.runGeneration == token.generation &&
        token.state.activeRunAttemptId == token.runAttemptId &&
        _storage.isSessionGenerationCurrent(
          token.state.sessionId,
          token.storageGeneration,
        );
  }

  bool _runMayContinue(_AgentRunToken token) =>
      _ownsRun(token) && !token.state.wasCancelled;

  bool _ownsSessionReplay(_SessionReplayOperation operation) {
    return operation.claimed &&
        identical(_sessionReplayOperations[operation.sessionId], operation) &&
        !_deletingSessionIds.contains(operation.sessionId) &&
        _storage.isSessionGenerationCurrent(
          operation.sessionId,
          operation.storageGeneration,
        );
  }

  _SessionReplayOperation _claimSessionReplay({
    required ChatSession session,
    ChatSession? sessionSnapshot,
    required String prompt,
    required List<MessageContent> attachments,
    required List<String>? pendingAlternatives,
    required String traceTrigger,
  }) {
    final current = _sessionReplayOperations[session.id];
    final canClaim = current?._commitInProgress != true;
    final operation = _SessionReplayOperation(
      owner: this,
      sessionId: session.id,
      storageGeneration: _storage.sessionGeneration(session.id),
      operationGeneration: ++_nextSessionReplayGeneration,
      liveSession: session,
      sessionSnapshot:
          sessionSnapshot ?? ChatSession.fromJson(session.toJson()),
      prompt: prompt,
      attachments: List<MessageContent>.unmodifiable(
        attachments.map(_copyMessageContent),
      ),
      pendingAlternatives: pendingAlternatives == null
          ? null
          : List<String>.unmodifiable(pendingAlternatives),
      traceTrigger: traceTrigger,
      claimed: canClaim,
    );
    if (canClaim) _sessionReplayOperations[session.id] = operation;
    return operation;
  }

  MessageContent _copyMessageContent(MessageContent content) {
    final copied = ChatMessage.fromJson(
      ChatMessage(role: 'user', content: [content]).toJson(),
    );
    return copied.content.single;
  }

  void _retireSessionReplay(_SessionReplayOperation operation) {
    if (identical(_sessionReplayOperations[operation.sessionId], operation)) {
      _sessionReplayOperations.remove(operation.sessionId);
    }
  }

  void _publishSessionReplayBoundary(_SessionReplayOperation operation) {
    final live = operation.liveSession;
    final snapshot = operation.sessionSnapshot;
    live.messages
      ..clear()
      ..addAll(snapshot.messages.map(
        (message) => ChatMessage.fromJson(message.toJson()),
      ));
    live.updatedAt = snapshot.updatedAt;
    live.inFlightAgentRun = snapshot.inFlightAgentRun;
  }

  void _finishRunToken(_AgentRunToken token) {
    if (_ownsRun(token)) {
      _activeRunTokens.remove(token.state.sessionId);
      token.state.activeRunAttemptId = null;
    }
    if (!token.finished.isCompleted) token.finished.complete();
  }

  Iterable<AgentState> get _activeAgentStates =>
      _agentStates.values.where((state) => state.isSending);

  AgentStatus get agentStatus =>
      _getState(currentSession?.id)?.status ?? AgentStatus.idle;

  String get streamingText =>
      _getState(currentSession?.id)?.streamingText ?? '';

  String get streamingReasoningText =>
      _getState(currentSession?.id)?.streamingReasoningText ?? '';

  int get streamingReasoningTotalLength =>
      _getState(currentSession?.id)?.streamingReasoningTotalLength ?? 0;

  ContextSummary? get currentContextSummary => currentSession?.contextSummary;

  AgentRunRecoveryMarker? get currentInterruptedAgentRun {
    final session = currentSession;
    final marker = session?.inFlightAgentRun;
    if (session == null || marker == null) return null;
    final activeToken = _activeRunTokens[session.id];
    if (activeToken != null &&
        _ownsRun(activeToken) &&
        activeToken.runAttemptId == marker.runAttemptId) {
      return null;
    }
    return marker;
  }

  List<ModelGroup> get modelGroups =>
      _prefsInitialized ? _prefs.modelGroups : const [];

  bool get isCurrentContextSummaryRebuilding {
    final session = currentSession;
    return session != null &&
        _manualContextSummarySessions.contains(session.id);
  }

  bool get canRebuildCurrentContextSummary {
    final session = currentSession;
    return session != null && !_isManualContextSummaryBusy(session);
  }

  String? get errorMessage =>
      _getState(currentSession?.id)?.errorMessage ?? _fallbackErrorMessage;
  set errorMessage(String? value) {
    final state = _getState(currentSession?.id);
    if (value == null) _fallbackErrorMessage = null;
    if (state != null) {
      state.errorMessage = value;
    } else {
      _fallbackErrorMessage = value;
    }
  }

  List<QueuedMessage> get messageQueue => List.unmodifiable(
      _getState(currentSession?.id)?.messageQueue ?? const []);

  Set<String> get activeAgentSessionIds => _agentStates.entries
      .where((entry) => entry.value.isSending)
      .map((entry) => entry.key)
      .toSet();

  AgentStatus agentStatusFor(String sessionId) =>
      _agentStates[sessionId]?.status ?? AgentStatus.idle;

  bool isSessionSending(String sessionId) =>
      _agentStates[sessionId]?.isSending ?? false;

  /// Metadata-only run-center projection. Nothing returned here is persisted;
  /// the underlying AgentState and ChatSession records stay authoritative.
  List<AgentRunCenterItem> get agentRunCenterItems {
    final items = <AgentRunCenterItem>[];
    for (final entry in _agentStates.entries) {
      final state = entry.value;
      if (!state.isSending &&
          state.messageQueue.isEmpty &&
          state.errorMessage == null) {
        continue;
      }
      final waitingApproval =
          identical(_pendingApprovalState, state) && pendingApproval != null;
      final context = !state.sessionExecutionMetadataKnown
          ? AgentRunCenterContext.unknown
          : state.isRemoteSessionExecution
              ? AgentRunCenterContext.external
              : AgentRunCenterContext.local;
      items.add(AgentRunCenterItem(
        sessionId: entry.key,
        sessionTitle: _sessionTitleForState(state),
        phase: waitingApproval
            ? AgentRunCenterPhase.waitingApproval
            : AgentRunCenterItem.phaseForStatus(state.status),
        context: context,
        queuedCount: state.messageQueue.length,
        waitingApproval: waitingApproval,
        safeExecutionDisplayName: state.safeExecutionDisplayName,
      ));
    }
    final session = currentSession;
    final marker = currentInterruptedAgentRun;
    if (session != null &&
        marker != null &&
        items.every((item) => item.sessionId != session.id)) {
      final unknown =
          marker.recoveryKind == InterruptedRunRecoveryKind.unknownOutcome ||
              marker.recoveryKind == InterruptedRunRecoveryKind.inspectOnly;
      items.add(AgentRunCenterItem(
        sessionId: session.id,
        sessionTitle: session.title,
        phase: unknown
            ? AgentRunCenterPhase.unknownOutcome
            : AgentRunCenterPhase.interrupted,
        context: session.remoteAgentConnectorId == null
            ? AgentRunCenterContext.local
            : AgentRunCenterContext.external,
        recoveryKind: marker.recoveryKind,
        safeExecutionDisplayName: _safeExecutionDisplayName(session),
      ));
    }
    items.sort((a, b) {
      final activeOrder = (b.isActive ? 1 : 0) - (a.isActive ? 1 : 0);
      if (activeOrder != 0) return activeOrder;
      return a.sessionTitle.compareTo(b.sessionTitle);
    });
    return List.unmodifiable(items);
  }

  /// Reads a bounded metadata snapshot from authoritative local sessions.
  /// The UI may discard this result at any time; it is not another run store.
  Future<List<AgentRunCenterItem>> loadRecoverableAgentRunCenterItems() async {
    final recoverable = <AgentRunCenterItem>[];
    for (final summary in sessions.take(100)) {
      try {
        final session = currentSession?.id == summary.id
            ? currentSession
            : await _storage.getSession(summary.id);
        final marker = session?.inFlightAgentRun;
        if (session == null || marker == null) continue;
        final active = _activeRunTokens[session.id];
        if (active != null &&
            _ownsRun(active) &&
            active.runAttemptId == marker.runAttemptId) {
          continue;
        }
        final unknown =
            marker.recoveryKind == InterruptedRunRecoveryKind.unknownOutcome ||
                marker.recoveryKind == InterruptedRunRecoveryKind.inspectOnly;
        recoverable.add(AgentRunCenterItem(
          sessionId: session.id,
          sessionTitle: session.title,
          phase: unknown
              ? AgentRunCenterPhase.unknownOutcome
              : AgentRunCenterPhase.interrupted,
          context: session.remoteAgentConnectorId == null
              ? AgentRunCenterContext.local
              : AgentRunCenterContext.external,
          recoveryKind: marker.recoveryKind,
          safeExecutionDisplayName: _safeExecutionDisplayName(session),
        ));
      } catch (_) {
        // A damaged or concurrently deleted session must not hide the rest.
      }
    }
    return List.unmodifiable(recoverable);
  }

  String getDraft(String sessionId) => _drafts[sessionId] ?? '';

  bool _isManualContextSummaryBusy(ChatSession session) {
    if (_manualContextSummarySessions.contains(session.id)) return true;
    final state = _getState(session.id);
    if (state == null) return false;
    return state.isSending ||
        state.status == AgentStatus.streaming ||
        state.messageQueue.isNotEmpty;
  }

  void _syncCurrentSessionReference(ChatSession session) {
    if (currentSession?.id == session.id) {
      currentSession = session;
    }
  }

  String _sessionTitleForState(AgentState state) {
    final currentTitle =
        currentSession?.id == state.sessionId ? currentSession?.title : null;
    final summaryTitle = sessions
        .where((session) => session.id == state.sessionId)
        .map((session) => session.title)
        .firstOrNull;
    final title = (currentTitle?.trim().isNotEmpty ?? false)
        ? currentTitle!
        : (state.sessionTitle.trim().isNotEmpty
            ? state.sessionTitle
            : (summaryTitle?.trim().isNotEmpty ?? false)
                ? summaryTitle!
                : '未命名会话');
    state.sessionTitle = title;
    return title;
  }

  void _clearSessionScopedState() {
    ToolCallExpansionState.clear();
  }

  Future<void> _startAgentServiceForState(
    AgentState state,
    String text, {
    _AgentRunToken? runToken,
  }) async {
    if (_disposed || (runToken != null && !_runMayContinue(runToken))) return;
    final shouldStartService =
        !state.agentServiceActive || state.agentServiceText != text;
    final generation = ++state.agentServiceGeneration;
    state.agentServiceActive = true;
    state.agentServiceText = text;
    if (!_appInBackground && !state.agentOverlayPermissionRequestStarted) {
      state.agentOverlayPermissionRequestStarted = true;
      unawaited(
        NativeBridge.requestAgentOverlayPermissionIfNeeded().catchError((
          Object e,
        ) {
          debugPrint('Agent overlay permission prompt failed: $e');
          return false;
        }),
      );
    }
    try {
      if (shouldStartService) {
        await NativeBridge.startAgentService(
          sessionId: state.sessionId,
          sessionTitle: _sessionTitleForState(state),
          text: text,
        );
      }
      if (runToken != null && !_runMayContinue(runToken)) return;
      await _updateAgentNativeStatusForState(
        state,
        _statusForAgentServiceText(text),
      );
    } catch (e) {
      if (generation == state.agentServiceGeneration &&
          (runToken == null || _runMayContinue(runToken))) {
        state.agentServiceActive = false;
        state.agentServiceText = null;
      }
      debugPrint('Failed to start agent foreground service: $e');
    }
  }

  String _statusForAgentServiceText(String text) {
    if (text == _agentServiceThinkingText) return 'thinking';
    if (text == _agentServiceStreamingText) return 'streaming';
    if (text == _agentServiceToolingText) return 'tooling';
    return 'thinking';
  }

  Future<void> _updateAgentNativeStatusForState(
    AgentState state,
    String status, {
    String? previewText,
    String? toolName,
    _AgentRunToken? runToken,
  }) async {
    if (_disposed || (runToken != null && !_runMayContinue(runToken))) return;
    try {
      await NativeBridge.updateAgentNotification(
        sessionId: state.sessionId,
        sessionTitle: _sessionTitleForState(state),
        status: status,
        previewText: previewText ?? _tailOfStreamBuffer(state, 250),
        toolName: toolName,
        overlayVisible: _appInBackground && _activeAgentStates.isNotEmpty,
      );
    } catch (e) {
      debugPrint('Failed to update agent notification: $e');
    }
  }

  String _tailOfStreamBuffer(AgentState state, int maxLength) {
    final s = state.streamBuffer.toString();
    return s.length <= maxLength ? s : s.substring(s.length - maxLength);
  }

  AgentState? _nextActiveStateAfter(AgentState state) {
    for (final candidate in _agentStates.values) {
      if (!identical(candidate, state) && candidate.isSending) {
        return candidate;
      }
    }
    return null;
  }

  String _agentServiceTextForState(AgentState state) {
    return state.agentServiceText ??
        switch (state.status) {
          AgentStatus.streaming => _agentServiceStreamingText,
          AgentStatus.tooling => _agentServiceToolingText,
          AgentStatus.thinking => _agentServiceThinkingText,
          AgentStatus.idle => _agentServiceThinkingText,
          AgentStatus.error => _agentServiceThinkingText,
        };
  }

  Future<void> _stopAgentServiceForState(
    AgentState state, {
    _AgentRunToken? runToken,
  }) async {
    if (runToken != null && !_ownsRun(runToken)) return;
    state.agentServiceGeneration++;
    final shouldStop =
        state.agentServiceActive || state.agentServiceText != null;
    state.agentServiceActive = false;
    state.agentServiceText = null;

    if (shouldStop) {
      try {
        await NativeBridge.stopAgentServiceForSession(state.sessionId);
      } catch (e) {
        debugPrint('Failed to stop agent foreground service: $e');
      }
    }

    if (runToken != null && !_ownsRun(runToken)) return;

    final nextState = _nextActiveStateAfter(state);
    if (nextState != null) {
      await _startAgentServiceForState(
        nextState,
        _agentServiceTextForState(nextState),
      );
    }
  }

  Future<void> _stopAgentService() async {
    for (final state in _agentStates.values) {
      state.agentServiceGeneration++;
      state.agentServiceActive = false;
      state.agentServiceText = null;
    }
    try {
      await NativeBridge.stopAgentService();
    } catch (e) {
      debugPrint('Failed to stop agent foreground service: $e');
    }
  }

  void _clearIdleLlmCaches() {
    for (final state in _agentStates.values) {
      if (state.isSending) continue;
      state.cachedLlm?.dispose();
      state.cachedLlm = null;
      state.cachedLlmConfig = null;
    }
  }

  void _cleanupIdleState(String sessionId) {
    final state = _agentStates[sessionId];
    if (state == null || state.isSending) return;
    if (state.messageQueue.isNotEmpty) return;
    if (state.status == AgentStatus.error) return;
    state.dispose();
    _agentStates.remove(sessionId);
  }

  String _completionNotificationPreview(String text) {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return String.fromCharCodes(normalized.runes.take(50));
  }

  Future<void> _showCompletionNotificationIfNeeded(
    AgentState state,
    String finalText,
  ) async {
    if (!_appInBackground || !_prefs.notifyOnComplete) return;
    try {
      await NativeBridge.showAgentCompleteNotification(
        sessionId: state.sessionId,
        sessionTitle: _sessionTitleForState(state),
        preview: _completionNotificationPreview(finalText),
      );
    } catch (e) {
      debugPrint('Failed to show agent completion notification: $e');
    }
  }

  Future<void> _finishAgentComplete(
    AgentState state,
    String finalText,
    Completer<void>? completer,
    Future<void>? persistCompletion,
    _AgentRunToken runToken,
  ) async {
    try {
      if (!_runMayContinue(runToken)) return;
      await _updateAgentNativeStatusForState(
        state,
        'complete',
        previewText: finalText,
        runToken: runToken,
      );
      if (!_runMayContinue(runToken)) return;
      await _showCompletionNotificationIfNeeded(state, finalText);
      if (!_runMayContinue(runToken)) return;
      if (_appInBackground) {
        await Future.delayed(const Duration(seconds: 2));
      }
    } finally {
      await persistCompletion;
      if (!_runMayContinue(runToken)) {
        if (completer != null && !completer.isCompleted) completer.complete();
      } else {
        await _stopAgentServiceForState(state, runToken: runToken);
        if (completer != null && !completer.isCompleted) {
          completer.complete();
        }
        if (_runMayContinue(runToken)) {
          state.agentCompletionFinalizing = false;
          Future.microtask(() {
            if (_runMayContinue(runToken)) _cleanupIdleState(state.sessionId);
          });
        }
      }
    }
  }

  void _flushStreamingState(AgentState state, {bool notify = true}) {
    state.streamingText = state.streamBuffer.toString();
    if (notify && !_disposed) notifyListeners();
  }

  void _flushStreamingReasoningState(
    AgentState state, {
    bool notify = true,
  }) {
    state.streamingReasoningText = state.reasoningPreviewBuffer.toString();
    if (notify && !_disposed) notifyListeners();
  }

  void _cancelStreamingFlush(AgentState state) {
    state.streamFlushScheduler.cancel();
    state.reasoningFlushScheduler.cancel();
  }

  void _flushStreamingNow(AgentState state, {bool notify = true}) {
    state.streamFlushScheduler.flushNow(() {
      _flushStreamingState(state, notify: false);
    });
    state.reasoningFlushScheduler.flushNow(() {
      _flushStreamingReasoningState(state, notify: false);
    });
    if (notify && !_disposed) notifyListeners();
  }

  void _clearStreamingState(AgentState state, {bool notify = false}) {
    _cancelStreamingFlush(state);
    state.streamingText = '';
    state.streamingReasoningText = '';
    state.streamingReasoningTotalLength = 0;
    state.streamBuffer = StringBuffer();
    state.reasoningPreviewBuffer = StringBuffer();
    if (notify && !_disposed) notifyListeners();
  }

  void _appendStreamingDelta(
    AgentState state,
    String text, {
    required _AgentRunToken runToken,
  }) {
    if (!_runMayContinue(runToken)) return;
    final replacingReconnectNotice =
        text.isNotEmpty && state.streamingText == _agentServiceReconnectingText;
    state.status = AgentStatus.streaming;
    state.streamBuffer.write(text);
    if (replacingReconnectNotice) {
      _flushStreamingState(state);
      unawaited(_startAgentServiceForState(
        state,
        _agentServiceStreamingText,
        runToken: runToken,
      ));
      return;
    }
    state.streamFlushScheduler.schedule(
      delta: text,
      flush: () {
        if (!_runMayContinue(runToken)) return;
        _flushStreamingState(state);
        unawaited(_startAgentServiceForState(
          state,
          _agentServiceStreamingText,
          runToken: runToken,
        ));
      },
    );
  }

  void _appendStreamingReasoningDelta(
    AgentState state,
    String text, {
    required _AgentRunToken runToken,
  }) {
    if (!_runMayContinue(runToken)) return;
    state.streamingReasoningTotalLength += text.length;
    state.reasoningPreviewBuffer.write(text);
    if (state.reasoningPreviewBuffer.length > _liveReasoningPreviewTrimAt) {
      final current = state.reasoningPreviewBuffer.toString();
      state.reasoningPreviewBuffer = StringBuffer(
        current.substring(current.length - _liveReasoningPreviewMaxChars),
      );
    }
    state.reasoningFlushScheduler.schedule(
      delta: text,
      flushOnBoundary: false,
      flush: () {
        if (!_runMayContinue(runToken)) return;
        _flushStreamingReasoningState(state);
      },
    );
  }

  void saveDraft(String sessionId, String text) {
    if (text.isEmpty) {
      _drafts.remove(sessionId);
    } else {
      _drafts[sessionId] = text;
    }
  }

  ChatProvider({
    SessionStorage? storage,
    LlmServiceFactory? llmServiceFactory,
    ContextSummaryServiceFactory? contextSummaryServiceFactory,
    ProviderTransformPreflight? providerTransformPreflight,
    RuntimeDebugEventService? runtimeDebugEvents,
    StartupRestoreGuard? startupRestoreGuard,
    DiagnosticsExportService? diagnosticsExportService,
    AttachmentBudget? attachmentBudget,
    ToolRegistry? toolRegistry,
    SkillCapabilityPolicyFactory? skillCapabilityPolicyFactory,
    RemoteAgentRuntimeBinding? remoteAgentRuntimeBinding,
    RemoteAgentConfigurationService? remoteAgentConfiguration,
    RemoteAgentConnector? remoteAgentConnector,
    RemoteConnectorPreflight? beforeRemoteConnectorSendForTesting,
    MessageQueueDrainTimerFactory? messageQueueDrainTimerFactory,
  })  : _storage = storage ?? SessionStorage(),
        _llmServiceFactory = llmServiceFactory ?? LlmService.new,
        runtimeDebugEvents = runtimeDebugEvents ?? RuntimeDebugEventService(),
        _startupRestoreGuard = startupRestoreGuard ?? StartupRestoreGuard(),
        _diagnosticsExportService =
            diagnosticsExportService ?? const DiagnosticsExportService(),
        _attachmentBudget = attachmentBudget ?? const AttachmentBudget(),
        _remoteAgentRuntimeBinding = remoteAgentRuntimeBinding ??
            RemoteAgentRuntimeBinding(
              configuration: remoteAgentConfiguration,
              connector: remoteAgentConnector,
            ),
        _ownsRemoteAgentRuntimeBinding = remoteAgentRuntimeBinding == null,
        _beforeRemoteConnectorSendForTesting =
            beforeRemoteConnectorSendForTesting,
        _messageQueueDrainTimerFactory =
            messageQueueDrainTimerFactory ?? Timer.new,
        _skillCapabilityPolicyFactory = skillCapabilityPolicyFactory ??
            ((fixedToolDomains) => SkillCapabilityPolicy(
                  fixedToolDomains: fixedToolDomains,
                )) {
    _remoteAgentRuntimeBinding.bind(
      owner: this,
      beforeChange: _cancelActiveRemoteAgentOperations,
      afterChange: _handleRemoteRuntimeChanged,
    );
    _contextManager = ContextManager(
      contextSummaryServiceFactory: contextSummaryServiceFactory ??
          () => ContextSummaryService(
                llmFactory: (config) => _llmServiceFactory(
                  config,
                  isInBackground: () => _appInBackground,
                ),
              ),
      providerTransformPreflight: providerTransformPreflight ??
          const ProviderMessageTransform().transformCanonical,
      runtimeDebugEvents: this.runtimeDebugEvents,
    );
    NativeBridge.setAgentStopRequestedHandler(
      ({String? sessionId}) => cancelAgent(sessionId: sessionId),
    );
    NativeBridge.setToolApprovalDecisionHandler(
      ({
        required sessionId,
        required approvalId,
        required approved,
      }) async =>
          _resolveToolApprovalFromNotification(
        sessionId: sessionId,
        approvalId: approvalId,
        approved: approved,
      ),
    );
    NativeBridge.setNavigateToSessionHandler((sessionId) {
      if (!_startupRestoreGuardReady) {
        _pendingStartupSessionId = sessionId;
        return;
      }
      if (!_safeMode) {
        unawaited(selectSession(sessionId));
      }
    });
    _tools = toolRegistry ?? ToolRegistry.withDefaults(prefs: _prefs);
    _init();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final llm in _compareLlmByModel.values) {
      llm.dispose();
    }
    _compareLlmByModel.clear();
    for (final cancellation in _remoteAgentCancellations.values) {
      cancellation.cancel();
    }
    _remoteAgentCancellations.clear();
    _remoteAgentRuntimeBinding.unbind(this);
    if (_ownsRemoteAgentRuntimeBinding) {
      _remoteAgentRuntimeBinding.dispose();
    }
    NativeBridge.setAgentStopRequestedHandler(null);
    NativeBridge.setToolApprovalDecisionHandler(null);
    NativeBridge.setNavigateToSessionHandler(null);
    unawaited(_stopAgentService());
    unawaited(_tools.dispose());
    _completePendingApproval(false);
    for (final state in _agentStates.values) {
      state.dispose();
    }
    for (final token in _activeRunTokens.values) {
      if (!token.finished.isCompleted) token.finished.complete();
    }
    _activeRunTokens.clear();
    _agentStates.clear();
    super.dispose();
  }

  void _cancelActiveRemoteAgentOperations() {
    for (final cancellation in _remoteAgentCancellations.values) {
      cancellation.cancel();
    }
  }

  void _handleRemoteRuntimeChanged() {
    if (_remoteAgentRuntimeBinding.isAttached) {
      for (final state in _agentStates.values) {
        if (!state.isRemoteSessionExecution ||
            state.isSending ||
            state.messageQueue.isEmpty) {
          continue;
        }
        if (state.status == AgentStatus.error) {
          state.status = AgentStatus.idle;
          state.errorMessage = null;
        }
        _drainMessageQueue(state);
      }
    }
    notifyListeners();
  }

  Future<void> _init() async {
    try {
      await _prefs.init();
      _applyPersistedDeveloperModeOnce();
      await _tools.refreshMcpTools();
      await _contextManager.init();
      _prefsInitialized = true;
      await _storage.init();
      await _reconcileUnclaimedWorkspaceImports();
      final guardState = await _startupRestoreGuard.state();
      _safeMode = guardState.safeMode;
      _startupFailureCount = guardState.failureCount;
      sessions = await _storage.getSessionsSummary();
      _startupRestoreGuardReady = true;
      notifyListeners();
      await loadSkills();
      MemoryService.getMemories();
      await _startupRestoreGuard.recordStartupSuccess();
      if (!_safeMode) {
        _startupFailureCount = 0;
        final pendingSessionId = _pendingStartupSessionId;
        _pendingStartupSessionId = null;
        if (pendingSessionId != null && pendingSessionId.isNotEmpty) {
          unawaited(selectSession(pendingSessionId));
        }
      } else {
        _pendingStartupSessionId = null;
      }
    } catch (e) {
      debugPrint('ChatProvider init failed: $e');
      final guardState = await _recordStartupFailureBestEffort();
      _safeMode = guardState.safeMode;
      _startupFailureCount = guardState.failureCount;
      _startupRestoreGuardReady = true;
      _pendingStartupSessionId = null;
      // Initialize with empty state rather than silently failing
      sessions = [];
      _fallbackErrorMessage = '启动恢复失败，已进入安全打开模式';
      notifyListeners();
    }
  }

  Future<void> loadSkills() async {
    _skills = await SkillService.scanSkills();
    notifyListeners();
  }

  Future<void> _ensurePrefs() async {
    if (!_prefsInitialized) {
      await _prefs.init();
      _applyPersistedDeveloperModeOnce();
      await _contextManager.init();
      _prefsInitialized = true;
    }
    _applyPersistedDeveloperModeOnce();
  }

  void _applyPersistedDeveloperModeOnce() {
    if (_persistedDeveloperModeApplied) return;
    runtimeDebugEvents.setTracingEnabled(_prefs.developerMode);
    _persistedDeveloperModeApplied = true;
  }

  Future<ChatSession> createSession({String? modelGroupId}) async {
    String? resolvedModelGroupId;
    final requestedModelGroupId = modelGroupId?.trim();
    if (requestedModelGroupId != null && requestedModelGroupId.isNotEmpty) {
      await _ensurePrefs();
      if (_prefs.modelGroupById(requestedModelGroupId) != null) {
        resolvedModelGroupId = requestedModelGroupId;
      }
    }
    final session = ChatSession(
      id: _uuid.v4(),
      modelGroupId: resolvedModelGroupId,
    );
    await _storage.saveSession(session);
    sessions.insert(
        0,
        SessionSummary(
          id: session.id,
          title: session.title,
          createdAt: session.createdAt,
          updatedAt: session.updatedAt,
          folder: session.folder,
        ));
    currentSession = session;
    _clearSessionScopedState();
    notifyListeners();
    return session;
  }

  Future<void> selectSession(String id) async {
    if (_safeMode) {
      _fallbackErrorMessage = '安全模式已启用，已跳过自动恢复。请手动退出安全模式后再打开会话。';
      notifyListeners();
      return;
    }
    if (currentSession?.id != id) {
      _clearSessionScopedState();
    }
    try {
      final selectedSession = await _storage.getSession(id);
      final storageGeneration = _storage.sessionGeneration(id);
      currentSession = selectedSession;
      if (selectedSession != null) {
        await _reconcileWorkspaceImportsOnReload(selectedSession);
        if (_deletingSessionIds.contains(id) ||
            currentSession?.id != id ||
            !_storage.isSessionGenerationCurrent(id, storageGeneration)) {
          if (identical(currentSession, selectedSession)) {
            currentSession = null;
          }
          return;
        }
        await _reconcileInterruptedRunOnReload(selectedSession);
        if (_deletingSessionIds.contains(id) ||
            currentSession?.id != id ||
            !_storage.isSessionGenerationCurrent(id, storageGeneration)) {
          if (identical(currentSession, selectedSession)) {
            currentSession = null;
          }
          return;
        }
        _restorePersistedAssistantErrorState(selectedSession);
      }
      await _startupRestoreGuard.recordStartupSuccess();
      notifyListeners();
    } catch (e) {
      final guardState = await _recordStartupFailureBestEffort();
      _safeMode = guardState.safeMode;
      _startupFailureCount = guardState.failureCount;
      currentSession = null;
      _clearSessionScopedState();
      _fallbackErrorMessage = '会话恢复失败，已进入安全打开状态: $e';
      notifyListeners();
    }
  }

  Future<void> dismissInterruptedAgentRun() async {
    final session = currentSession;
    if (session?.inFlightAgentRun == null) return;
    _discardUnpairedInterruptedToolTail(session!);
    session.inFlightAgentRun = null;
    await _storage.saveSession(session);
    _syncCurrentSessionReference(session);
    notifyListeners();
  }

  Future<bool> continueInterruptedAgentRun({
    List<MessageContent> attachments = const [],
  }) async {
    final session = currentSession;
    if (session?.inFlightAgentRun == null) return false;
    final activeSession = session!;
    final marker = activeSession.inFlightAgentRun!;
    if (marker.recoveryKind == InterruptedRunRecoveryKind.inspectOnly) {
      _fallbackErrorMessage = '恢复记录已损坏。请先查看详情，然后忽略该记录或手动重新发送任务。';
      notifyListeners();
      return false;
    }
    final sessionId = activeSession.id;
    final prompt = switch (marker.recoveryKind) {
      InterruptedRunRecoveryKind.reauthorizeAction =>
        _agentRunReauthorizationPrompt,
      InterruptedRunRecoveryKind.unknownOutcome =>
        _agentRunUnknownOutcomePrompt,
      InterruptedRunRecoveryKind.retryModelTurn =>
        marker.hasPersistedToolResults
            ? _agentRunPersistedResultPrompt
            : _agentRunRecoveryPrompt,
      InterruptedRunRecoveryKind.inspectOnly => _agentRunRecoveryPrompt,
    };
    await _sendMessage(
      '',
      attachments: attachments,
      targetSessionId: sessionId,
      traceTrigger: 'interrupted_recovery',
      recoveryRequest: _RecoveryRunRequest(
        expectedRunAttemptId: marker.runAttemptId,
        previousMarker: marker,
        prompt: prompt,
      ),
    );
    final nextMarker = currentSession?.id == sessionId
        ? currentSession?.inFlightAgentRun
        : (await _storage.getSession(sessionId))?.inFlightAgentRun;
    return nextMarker == null || nextMarker.runAttemptId != marker.runAttemptId;
  }

  Future<void> _reconcileInterruptedRunOnReload(ChatSession session) async {
    final marker = session.inFlightAgentRun;
    if (marker == null) return;
    final storageGeneration = _storage.sessionGeneration(session.id);
    final persistedOperationIds = session.messages
        .expand((message) => message.toolResults)
        .map((result) => result.metadata['operationId'])
        .whereType<String>()
        .toSet();
    var nextMarker = marker;
    var changed = false;
    final now = DateTime.now();
    for (final attempt in marker.toolAttempts) {
      ToolAttemptLifecycle? nextLifecycle;
      if (persistedOperationIds.contains(attempt.operationId)) {
        nextLifecycle = ToolAttemptLifecycle.resultPersisted;
      } else if (attempt.lifecycle == ToolAttemptLifecycle.resultPersisted ||
          (attempt.hasUnknownOutcome &&
              attempt.lifecycle != ToolAttemptLifecycle.interruptedUnknown)) {
        nextLifecycle = ToolAttemptLifecycle.interruptedUnknown;
      }
      if (nextLifecycle == null || nextLifecycle == attempt.lifecycle) continue;
      nextMarker = nextMarker.upsertToolAttempt(
        attempt.copyWith(lifecycle: nextLifecycle, updatedAt: now),
      );
      changed = true;
    }
    if (!changed) return;
    if (_deletingSessionIds.contains(session.id) ||
        !_storage.isSessionGenerationCurrent(
          session.id,
          storageGeneration,
        )) {
      return;
    }
    session.inFlightAgentRun = nextMarker;
    try {
      await _storage.saveSession(
        session,
        expectedGeneration: storageGeneration,
      );
    } on SessionTombstonedException {
      return;
    }
  }

  Future<void> _reconcileWorkspaceImportsOnReload(ChatSession session) async {
    if (session.pendingWorkspaceImports.isEmpty) return;
    final storageGeneration = _storage.sessionGeneration(session.id);
    final acknowledged = <String>{};
    for (final receipt in List<WorkspaceImportReceipt>.from(
      session.pendingWorkspaceImports,
    )) {
      if (_deletingSessionIds.contains(session.id) ||
          !_storage.isSessionGenerationCurrent(
            session.id,
            storageGeneration,
          )) {
        return;
      }
      try {
        await NativeBridge.acknowledgeWorkspaceImport(receipt);
        if (_deletingSessionIds.contains(session.id) ||
            !_storage.isSessionGenerationCurrent(
              session.id,
              storageGeneration,
            )) {
          return;
        }
        acknowledged.add(receipt.operationId);
      } catch (_) {
        // Retain the durable receipt for a later idempotent reconciliation.
      }
    }
    if (acknowledged.isEmpty) return;
    if (_deletingSessionIds.contains(session.id) ||
        !_storage.isSessionGenerationCurrent(
          session.id,
          storageGeneration,
        )) {
      return;
    }
    session.pendingWorkspaceImports.removeWhere(
      (receipt) => acknowledged.contains(receipt.operationId),
    );
    try {
      await _storage.saveSession(
        session,
        expectedGeneration: storageGeneration,
      );
    } on SessionTombstonedException {
      return;
    }
  }

  Future<void> _reconcileUnclaimedWorkspaceImports() async {
    final pending = await NativeBridge.listPendingWorkspaceImports();
    if (pending.isEmpty) return;
    final storedSessions = await _storage.getAllSessions();
    for (final receipt in pending) {
      ChatSession? owner;
      for (final session in storedSessions) {
        final ledgerOwns = session.pendingWorkspaceImports.any(
          (candidate) => candidate.operationId == receipt.operationId,
        );
        final messageOwns = session.messages.any(
          (message) =>
              message.role == 'user' &&
              message.textContent.contains(receipt.storedPath),
        );
        if (ledgerOwns || messageOwns) {
          owner = session;
          break;
        }
      }
      if (owner == null) {
        try {
          await NativeBridge.discardWorkspaceImport(receipt);
        } catch (_) {
          // Native evidence remains for the next bounded startup pass.
        }
        continue;
      }
      final storageGeneration = _storage.sessionGeneration(owner.id);
      if (_deletingSessionIds.contains(owner.id) ||
          !_storage.isSessionGenerationCurrent(
            owner.id,
            storageGeneration,
          )) {
        continue;
      }
      if (!owner.pendingWorkspaceImports.any(
        (candidate) => candidate.operationId == receipt.operationId,
      )) {
        owner.pendingWorkspaceImports.add(receipt);
        try {
          await _storage.saveSession(
            owner,
            expectedGeneration: storageGeneration,
          );
        } catch (_) {
          owner.pendingWorkspaceImports.removeWhere(
            (candidate) => candidate.operationId == receipt.operationId,
          );
          continue;
        }
      }
      try {
        await NativeBridge.acknowledgeWorkspaceImport(receipt);
        if (_deletingSessionIds.contains(owner.id) ||
            !_storage.isSessionGenerationCurrent(
              owner.id,
              storageGeneration,
            )) {
          continue;
        }
        owner.pendingWorkspaceImports.removeWhere(
          (candidate) => candidate.operationId == receipt.operationId,
        );
        await _storage.saveSession(
          owner,
          expectedGeneration: storageGeneration,
        );
      } catch (_) {
        // Keep the durable receipt for idempotent recovery on the next load.
      }
    }
  }

  void _discardUnpairedInterruptedToolTail(ChatSession session) {
    final resultIds = session.messages
        .expand((message) => message.toolResults)
        .map((result) => result.toolUseId)
        .toSet();
    for (var index = session.messages.length - 1; index >= 0; index--) {
      final message = session.messages[index];
      if (message.role != 'assistant') continue;
      final retained = message.content.where((content) {
        return content is! ToolUseContent || resultIds.contains(content.id);
      }).toList();
      if (retained.length == message.content.length) continue;
      if (retained.isEmpty) {
        session.messages.removeAt(index);
      } else {
        message.content = retained;
      }
    }
  }

  Future<StartupRestoreGuardState> _recordStartupFailureBestEffort() async {
    try {
      return await _startupRestoreGuard.recordStartupFailure();
    } catch (guardError) {
      debugPrint('Startup restore guard failure recording failed: $guardError');
      return const StartupRestoreGuardState(
        failureCount: StartupRestoreGuard.failureThreshold,
        safeMode: true,
      );
    }
  }

  Future<void> exitSafeMode() async {
    await _startupRestoreGuard.clear();
    _safeMode = false;
    _startupFailureCount = 0;
    _fallbackErrorMessage = null;
    notifyListeners();
  }

  Future<String> buildDiagnosticsReport() async {
    await _ensurePrefs();
    ResolvedModelProfile? resolvedProfile;
    try {
      final session = currentSession ??
          ChatSession(
            id: 'diagnostics',
            modelOverride: _prefs.model,
            baseUrlOverride: _prefs.baseUrl,
            apiFormatOverride: _prefs.apiFormat,
          );
      final llmConfig = _buildLlmConfig(session);
      final llm = _llmServiceFactory(
        llmConfig,
        isInBackground: () => _appInBackground,
      );
      try {
        resolvedProfile = llm.resolvedModelProfile;
      } finally {
        llm.dispose();
      }
    } catch (_) {
      resolvedProfile = null;
    }

    return _diagnosticsExportService.buildReport(DiagnosticsExportSummary(
      activeProfileId: _prefs.activeProfileId,
      activeProfile: _prefs.activeProfile,
      resolvedModelProfile: resolvedProfile,
      currentSessionId: currentSession?.id,
      lastError: errorMessage,
      safeMode: _safeMode,
      startupFailureCount: _startupFailureCount,
      events: runtimeDebugEvents.recent(limit: 120),
    ));
  }

  Future<void> deleteSession(String id) async {
    if (!_deletingSessionIds.add(id)) return;
    try {
      final sessionToDelete = currentSession?.id == id
          ? currentSession
          : await _storage.getSession(id);
      final receipts = List<WorkspaceImportReceipt>.from(
        sessionToDelete?.pendingWorkspaceImports ?? const [],
      );
      final state = _agentStates[id];
      if (state != null && state.isSending) {
        await cancelAgent(sessionId: id, savePartial: false);
      }

      // Install the generation boundary before any receipt completion or late
      // run callback can enqueue another durable write for this session.
      _storage.tombstoneSession(id);
      for (final receipt in receipts) {
        try {
          await NativeBridge.discardWorkspaceImport(receipt);
        } catch (_) {
          // The session tombstone still prevents receipt ACK callbacks from
          // resurrecting ownership; native cleanup can retry independently.
        }
      }
      _agentStates.remove(id)?.dispose();
      await _storage.deleteSession(id);
      sessions.removeWhere((s) => s.id == id);
      if (currentSession?.id == id) {
        currentSession = null;
        _clearSessionScopedState();
        if (sessions.isNotEmpty) {
          currentSession = await _storage.getSession(sessions.first.id);
          if (currentSession != null) {
            await _reconcileWorkspaceImportsOnReload(currentSession!);
          }
        }
      }
      notifyListeners();
    } finally {
      _deletingSessionIds.remove(id);
    }
  }

  Future<bool> restoreDeletedSession(String id) async {
    final restored = await _storage.restoreFromTrash(id);
    if (restored == null) return false;
    sessions = await _storage.getSessionsSummary();
    if (currentSession == null) {
      currentSession = restored;
      _clearSessionScopedState();
    }
    notifyListeners();
    return true;
  }

  Future<void> renameSession(String id, String newTitle) async {
    final session = await _storage.getSession(id);
    if (session == null) return;
    session.title = newTitle;
    await _storage.saveSession(session);
    // Update the summary list
    final idx = sessions.indexWhere((s) => s.id == id);
    if (idx >= 0) {
      sessions[idx] = SessionSummary(
        id: session.id,
        title: newTitle,
        createdAt: session.createdAt,
        updatedAt: session.updatedAt,
        folder: session.folder,
      );
    }
    if (currentSession?.id == id) {
      currentSession!.title = newTitle;
    }
    final state = _getState(id);
    if (state != null) {
      state.sessionTitle = newTitle;
    }
    notifyListeners();
  }

  Future<void> clearAllSessions() async {
    for (final id in _agentStates.keys.toList()) {
      if (_agentStates[id]?.isSending ?? false) {
        await cancelAgent(sessionId: id, savePartial: false);
      }
    }
    for (final state in _agentStates.values) {
      state.dispose();
    }
    _agentStates.clear();
    await _storage.clearAll();
    sessions.clear();
    currentSession = null;
    _clearSessionScopedState();
    notifyListeners();
  }

  Future<bool> _requestToolApproval(
    AgentState state,
    ToolApprovalRequest request, {
    required _AgentRunToken runToken,
  }) async {
    if (_disposed || !_runMayContinue(runToken)) return false;
    await _ensurePrefs();
    if (_disposed || !_runMayContinue(runToken)) return false;

    final policy = _prefs.toolApprovalPolicy;
    final forceRenewedApproval = state.forceToolApprovalForRun;
    // Auto Allow is an authorization decision, not an approval-surface
    // preference. Run validity, hard-deny, and interrupted-run reauthorization
    // checks happen before it; lifecycle, session visibility, and notification
    // capability must not downgrade an otherwise valid operation to Ask or Deny.
    if (!forceRenewedApproval &&
        policy == PreferencesService.toolApprovalAuto) {
      return true;
    }
    if (!forceRenewedApproval &&
        policy == PreferencesService.toolApprovalSessionFirst &&
        state.sessionApprovedTools.contains(request.toolName)) {
      return true;
    }

    final isCurrentSession = state.sessionId == currentSession?.id;
    if (!isCurrentSession) return false;

    final approvalRequest = request.toolName == 'set_env_var'
        ? ToolApprovalRequest(
            toolName: request.toolName,
            arguments: ToolUseContent.sanitizedInput(
              request.toolName,
              request.arguments,
            ),
            risk: request.risk,
            runAttemptId: request.runAttemptId,
            operationId: request.operationId,
          )
        : request;
    _completePendingApproval(false, notify: false);
    final completer = Completer<bool>();
    _approvalCompleter = completer;
    _approvalDecisionSource = null;
    _pendingApprovalState = state;
    pendingApproval = approvalRequest;
    notifyListeners();
    if (_appInBackground) {
      await _publishPendingToolApprovalNotification();
    }
    final approvedByUser = await completer.future;
    final decisionSource = _approvalDecisionSource;
    final approvalStillCurrent = !_disposed &&
        _runMayContinue(runToken) &&
        state.sessionId == currentSession?.id &&
        (decisionSource == _ToolApprovalDecisionSource.notification ||
            !_appInBackground);
    final approved = approvedByUser && approvalStillCurrent;
    return approved;
  }

  bool resolveToolApproval({
    required String operationId,
    required bool approved,
    bool rememberForSession = false,
  }) {
    final request = pendingApproval;
    if (_disposed ||
        request == null ||
        request.operationId != operationId ||
        _approvalCompleter?.isCompleted != false) {
      return false;
    }
    if (approved) {
      _rememberToolApproval(
        _pendingApprovalState,
        request.toolName,
        explicitSessionApproval: rememberForSession,
      );
    }
    _approvalDecisionSource = _ToolApprovalDecisionSource.inApp;
    _completePendingApproval(approved);
    return true;
  }

  String _toolApprovalId(ToolApprovalRequest request) => request.operationId;

  Future<bool> _showPendingToolApprovalNotification() async {
    final request = pendingApproval;
    final state = _pendingApprovalState;
    if (request == null || state == null || !_appInBackground) return false;
    try {
      return await NativeBridge.showToolApprovalNotification(
        sessionId: state.sessionId,
        sessionTitle: _sessionTitleForState(state),
        approvalId: _toolApprovalId(request),
        toolName: request.toolName,
        risk: request.risk.name,
      );
    } catch (e) {
      debugPrint('Failed to show tool approval notification: $e');
      return false;
    }
  }

  Future<void> _publishPendingToolApprovalNotification() async {
    final request = pendingApproval;
    final state = _pendingApprovalState;
    if (request == null || state == null || !_appInBackground) return;
    final shown = await _showPendingToolApprovalNotification();
    if (shown ||
        !_appInBackground ||
        !identical(pendingApproval, request) ||
        !identical(_pendingApprovalState, state)) {
      return;
    }
    state.errorMessage = _backgroundApprovalUnavailableMessage;
    final session = currentSession;
    if (session?.id == state.sessionId) {
      if (session!.messages.isEmpty ||
          !session.messages.last.isSystemNotice ||
          session.messages.last.textContent !=
              _backgroundApprovalUnavailableMessage) {
        session.messages.add(
          ChatMessage.systemNotice(_backgroundApprovalUnavailableMessage),
        );
        try {
          await _storage.saveSession(session);
        } catch (_) {
          // The in-memory notice remains visible; approval still fails closed.
        }
      }
    }
    _approvalDecisionSource = _ToolApprovalDecisionSource.notification;
    _completePendingApproval(false);
  }

  Future<void> _hidePendingToolApprovalNotification() async {
    final request = pendingApproval;
    final state = _pendingApprovalState;
    if (request == null || state == null) return;
    try {
      await NativeBridge.clearToolApprovalNotification(
        sessionId: state.sessionId,
        approvalId: _toolApprovalId(request),
      );
    } catch (_) {
      // Foreground UI remains authoritative if notification cleanup fails.
    }
  }

  Future<bool> _resolveToolApprovalFromNotification({
    required String sessionId,
    required String approvalId,
    required bool approved,
  }) async {
    final request = pendingApproval;
    final state = _pendingApprovalState;
    final matches = !_disposed &&
        _appInBackground &&
        request != null &&
        state != null &&
        state.sessionId == sessionId &&
        currentSession?.id == sessionId &&
        _toolApprovalId(request) == approvalId &&
        _approvalCompleter?.isCompleted == false;
    if (!matches) return false;
    _approvalDecisionSource = _ToolApprovalDecisionSource.notification;
    _completePendingApproval(approved);
    return true;
  }

  @visibleForTesting
  Future<bool> resolveToolApprovalFromNotificationForTesting({
    required String sessionId,
    required String approvalId,
    required bool approved,
  }) =>
      _resolveToolApprovalFromNotification(
        sessionId: sessionId,
        approvalId: approvalId,
        approved: approved,
      );

  void setAppInBackground(bool inBackground) {
    if (_appInBackground == inBackground) return;
    _appInBackground = inBackground;
    if (!_appInBackground) {
      unawaited(NativeBridge.setAgentOverlayVisible(false));
      unawaited(_hidePendingToolApprovalNotification());
      _resumeActiveAgentStreamAfterForeground();
      if (pendingApproval != null && !_disposed) notifyListeners();
    } else if (_activeAgentStates.isNotEmpty) {
      unawaited(NativeBridge.setAgentOverlayVisible(true));
      for (final state in _activeAgentStates) {
        unawaited(_updateAgentNativeStatusForState(
          state,
          _statusForAgentServiceText(_agentServiceTextForState(state)),
        ));
      }
      unawaited(_publishPendingToolApprovalNotification());
    }
  }

  bool confirmAppResumedApprovalSurface({String? approvalId}) {
    final request = pendingApproval;
    if (approvalId == null) {
      if (request != null) return false;
    } else if (request == null || request.operationId != approvalId) {
      return false;
    }
    setAppInBackground(false);
    return true;
  }

  void _resumeActiveAgentStreamAfterForeground() {
    if (_disposed) return;
    for (final state in _activeAgentStates) {
      switch (state.status) {
        case AgentStatus.thinking:
          unawaited(_startAgentServiceForState(
            state,
            _agentServiceThinkingText,
          ));
        case AgentStatus.streaming:
          unawaited(_startAgentServiceForState(
            state,
            _agentServiceStreamingText,
          ));
        case AgentStatus.tooling:
          unawaited(_startAgentServiceForState(
            state,
            _agentServiceToolingText,
          ));
        case AgentStatus.idle:
        case AgentStatus.error:
          break;
      }
    }
  }

  void _rememberToolApproval(
    AgentState? state,
    String toolName, {
    bool explicitSessionApproval = false,
  }) {
    if (state != null && explicitSessionApproval) {
      state.sessionApprovedTools.add(toolName);
    }
  }

  void _completePendingApproval(bool approved, {bool notify = true}) {
    final request = pendingApproval;
    final state = _pendingApprovalState;
    pendingApproval = null;
    _pendingApprovalState = null;
    final completer = _approvalCompleter;
    _approvalCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(approved);
    }
    if (request != null && state != null) {
      unawaited(
        NativeBridge.clearToolApprovalNotification(
          sessionId: state.sessionId,
          approvalId: _toolApprovalId(request),
        ).catchError((Object _) => false),
      );
    }
    if (notify && !_disposed) notifyListeners();
  }

  Future<void> moveToFolder(String sessionId, String? folder) async {
    final normalizedFolder = folder?.trim();
    final nextFolder = normalizedFolder == null || normalizedFolder.isEmpty
        ? null
        : normalizedFolder;
    final session = await _storage.getSession(sessionId);
    if (session == null) return;
    session.folder = nextFolder;
    await _storage.saveSession(session);
    final idx = sessions.indexWhere((s) => s.id == sessionId);
    if (idx >= 0) {
      sessions[idx] = SessionSummary(
        id: session.id,
        title: session.title,
        createdAt: session.createdAt,
        updatedAt: session.updatedAt,
        folder: nextFolder,
      );
    }
    if (currentSession?.id == sessionId) {
      currentSession!.folder = nextFolder;
    }
    notifyListeners();
  }

  Future<ChatSession?> forkFromMessage(
      String sessionId, int messageIndex) async {
    final fork = await _storage.forkSession(sessionId, messageIndex);
    if (fork == null) return null;

    sessions.insert(
        0,
        SessionSummary(
          id: fork.id,
          title: fork.title,
          createdAt: fork.createdAt,
          updatedAt: fork.updatedAt,
          folder: fork.folder,
        ));
    currentSession = fork;
    _clearSessionScopedState();
    notifyListeners();
    return fork;
  }

  Future<EditUserMessageBranchStatus> editUserMessageAndResend(
    int messageIndex,
    String editedText,
  ) async {
    final trimmedText = editedText.trim();
    if (trimmedText.isEmpty) return EditUserMessageBranchStatus.empty;

    final source = currentSession;
    if (source == null ||
        messageIndex < 0 ||
        messageIndex >= source.messages.length) {
      return EditUserMessageBranchStatus.invalidMessage;
    }

    final sourceState = _getState(source.id);
    if ((sourceState?.isSending ?? false) ||
        (sourceState?.messageQueue.isNotEmpty ?? false)) {
      if (sourceState != null) {
        sourceState.errorMessage = AppStrings.editMessageBlockedActive;
      } else {
        _fallbackErrorMessage = AppStrings.editMessageBlockedActive;
      }
      notifyListeners();
      return EditUserMessageBranchStatus.busy;
    }

    final sourceMessage = source.messages[messageIndex];
    if (!_isEditableUserMessage(sourceMessage)) {
      return EditUserMessageBranchStatus.invalidMessage;
    }

    await _ensurePrefs();
    final apiKey = _prefs.apiKey;
    if (apiKey == null || apiKey.isEmpty) {
      _fallbackErrorMessage = AppStrings.editMessageMissingApiKey;
      notifyListeners();
      return EditUserMessageBranchStatus.missingApiKey;
    }

    final activeCount = _activeAgentStates.length;
    if (activeCount >= maxConcurrentAgents) {
      _fallbackErrorMessage = AppStrings.maxConcurrentAgentsReached(
        maxConcurrentAgents,
      );
      notifyListeners();
      return EditUserMessageBranchStatus.busy;
    }

    final attachments = _retryableAttachmentsFor(sourceMessage);
    final branch = await _storage.forkSessionBeforeMessage(
      source.id,
      messageIndex,
    );
    if (branch == null) return EditUserMessageBranchStatus.failed;

    sessions.insert(
      0,
      SessionSummary(
        id: branch.id,
        title: branch.title,
        createdAt: branch.createdAt,
        updatedAt: branch.updatedAt,
        folder: branch.folder,
      ),
    );
    currentSession = branch;
    _clearSessionScopedState();
    notifyListeners();

    await sendMessage(trimmedText, attachments: attachments);
    return EditUserMessageBranchStatus.started;
  }

  bool _isEditableUserMessage(ChatMessage message) {
    return message.role == 'user' &&
        message.textContent.trim().isNotEmpty &&
        message.toolResults.isEmpty;
  }

  List<MessageContent> _retryableAttachmentsFor(ChatMessage message) {
    final copied = ChatMessage.fromJson(message.toJson());
    return copied.content
        .where((content) =>
            content is! TextContent && content is! ToolResultContent)
        .toList();
  }

  Future<void> sendMessage(
    String text, {
    List<MessageContent> attachments = const [],
    List<String>? pendingAlternatives,
    String? targetSessionId,
    String traceTrigger = 'message',
  }) {
    return _sendMessage(
      text,
      attachments: attachments,
      pendingAlternatives: pendingAlternatives,
      targetSessionId: targetSessionId,
      traceTrigger: traceTrigger,
    );
  }

  Future<bool> sendMessageWithWorkspaceImports(
    String text, {
    List<MessageContent> attachments = const [],
    required List<WorkspaceImportReceipt> workspaceImports,
  }) {
    if (workspaceImports.isEmpty) {
      unawaited(sendMessage(text, attachments: attachments));
      return Future.value(true);
    }
    final commit = Completer<bool>();
    unawaited(_sendMessage(
      text,
      attachments: attachments,
      workspaceImports: List.unmodifiable(workspaceImports),
      workspaceCommit: commit,
    ));
    return commit.future;
  }

  Future<void> _sendMessage(
    String text, {
    List<MessageContent> attachments = const [],
    List<String>? pendingAlternatives,
    String? targetSessionId,
    String traceTrigger = 'message',
    _RecoveryRunRequest? recoveryRequest,
    List<WorkspaceImportReceipt> workspaceImports = const [],
    Completer<bool>? workspaceCommit,
    _SessionReplayOperation? sessionReplay,
  }) async {
    if (sessionReplay != null && !_ownsSessionReplay(sessionReplay)) return;
    final trimmedText = text.trim();
    final pendingAlternativesForSend = pendingAlternatives == null
        ? null
        : List<String>.from(pendingAlternatives);

    if (trimmedText.isEmpty &&
        attachments.isEmpty &&
        workspaceImports.isEmpty &&
        recoveryRequest == null) {
      return;
    }

    _AgentRunToken? runToken;
    try {
      await _ensurePrefs();
      if (sessionReplay != null && !_ownsSessionReplay(sessionReplay)) return;
      if (workspaceImports.length > 16 ||
          workspaceImports
              .any((receipt) => !trimmedText.contains(receipt.marker))) {
        _fallbackErrorMessage = '工作区附件引用无效，请移除后重新附加。';
        notifyListeners();
        return;
      }
      try {
        _attachmentBudget.checkMessageAttachments(attachments);
      } on AttachmentBudgetException catch (e) {
        final message = e.message;
        final targetState = _getState(targetSessionId ?? currentSession?.id);
        if (targetState != null) {
          targetState.status = AgentStatus.error;
          targetState.errorMessage = message;
        } else {
          _fallbackErrorMessage = message;
        }
        notifyListeners();
        return;
      }

      ChatSession? session;
      if (sessionReplay != null) {
        session = sessionReplay.liveSession;
      } else if (targetSessionId != null) {
        // Recovery must prove the target and old evidence still exist on disk;
        // a stale in-memory session is not enough to reserve a replacement.
        session =
            recoveryRequest == null && currentSession?.id == targetSessionId
                ? currentSession
                : await _storage.getSession(targetSessionId);
        if (session == null) {
          _fallbackErrorMessage = '会话不存在';
          notifyListeners();
          return;
        }
      } else {
        session = currentSession;
      }

      if (session != null && _deletingSessionIds.contains(session.id)) {
        _fallbackErrorMessage = '会话正在删除，无法开始新的请求。';
        notifyListeners();
        return;
      }
      if (sessionReplay != null && !_ownsSessionReplay(sessionReplay)) return;

      AgentState? sessionState =
          session != null ? _getOrCreateState(session.id) : null;
      if (sessionState != null && session != null) {
        _bindAgentStateToSession(sessionState, session);
      }
      if (sessionState != null && sessionState.isSending) {
        if (sessionReplay != null) {
          sessionState.errorMessage = '该会话已有任务正在运行，请稍后重试。';
          notifyListeners();
        } else if (recoveryRequest == null && workspaceImports.isEmpty) {
          _enqueueMessage(sessionState, trimmedText, attachments);
        } else if (workspaceImports.isNotEmpty) {
          sessionState.status = AgentStatus.error;
          sessionState.errorMessage = '当前会话忙碌，请稍后重新发送工作区附件。';
          notifyListeners();
        }
        return;
      }

      if (recoveryRequest != null) {
        final persistedMarker = session?.inFlightAgentRun;
        if (persistedMarker == null ||
            persistedMarker.runAttemptId !=
                recoveryRequest.expectedRunAttemptId ||
            persistedMarker.updatedAt !=
                recoveryRequest.previousMarker.updatedAt ||
            persistedMarker.recoveryKind !=
                recoveryRequest.previousMarker.recoveryKind) {
          _fallbackErrorMessage = '恢复状态已变化，请重新查看后再继续。';
          notifyListeners();
          return;
        }
      }

      if (session?.remoteAgentConnectorId != null) {
        await _sendRemoteAgentMessage(
          session!,
          trimmedText,
          attachments: attachments,
          recoveryRequest: recoveryRequest,
          sessionReplay: sessionReplay,
        );
        return;
      }

      final providerSnapshot = _captureProviderProfileSnapshot(session);
      final apiKey = providerSnapshot.activeProfile.apiKey.trim();
      if (apiKey.isEmpty) {
        if (sessionState != null) {
          sessionState.errorMessage = AppStrings.apiKeyNotConfigured;
          sessionState.status = AgentStatus.error;
        } else {
          _fallbackErrorMessage = AppStrings.apiKeyNotConfigured;
        }
        notifyListeners();
        return;
      }

      final activeCount = _activeAgentStates.length;
      final concurrentLimit = maxConcurrentAgents;
      if (activeCount >= concurrentLimit) {
        final message = AppStrings.maxConcurrentAgentsReached(concurrentLimit);
        if (sessionState != null) {
          sessionState.errorMessage = message;
        } else {
          _fallbackErrorMessage = message;
        }
        notifyListeners();
        return;
      }

      if (session == null) {
        session = await createSession();
        sessionState = _getOrCreateState(session.id);
        _bindAgentStateToSession(sessionState, session);
      }

      final activeSession = session;
      final state = sessionState!;
      final llmConfig = _buildLlmConfigFromSnapshot(
        providerSnapshot,
        activeSession,
      );
      final reusesCachedLlm =
          state.cachedLlm != null && state.cachedLlmConfig == llmConfig;
      late final LlmService llm;
      try {
        llm = reusesCachedLlm
            ? state.cachedLlm!
            : _llmServiceFactory(
                llmConfig,
                isInBackground: () => _appInBackground,
              );
      } catch (e) {
        state.status = AgentStatus.error;
        state.errorMessage = _sanitizeProviderErrorMessage(e);
        notifyListeners();
        return;
      }

      final previousMessages = activeSession.messages
          .map((message) => ChatMessage.fromJson(message.toJson()))
          .toList(growable: false);
      final previousMarker = activeSession.inFlightAgentRun;
      final previousWorkspaceImports = List<WorkspaceImportReceipt>.from(
          activeSession.pendingWorkspaceImports);
      final runStartedAt = DateTime.now();
      final runAttemptId = _uuid.v4();
      final skillProvenance = _recoverySkillProvenance(
        activeSession,
        recoveryRequest,
      );
      final replacementMarker = recoveryRequest == null
          ? AgentRunRecoveryMarker(
              runAttemptId: runAttemptId,
              startedAt: runStartedAt,
              updatedAt: runStartedAt,
            )
          : AgentRunRecoveryMarker(
              runAttemptId: runAttemptId,
              startedAt: previousMarker!.startedAt,
              updatedAt: runStartedAt,
              phase: previousMarker.phase,
              toolAttempts: previousMarker.toolAttempts,
              skillActivation: skillProvenance.toRecoveryMetadata(),
            );

      if (sessionReplay != null && !_ownsSessionReplay(sessionReplay)) return;

      runToken = _beginRun(
        state,
        runAttemptId,
        skillProvenance: skillProvenance,
      );
      state.pendingAlternatives = null;
      state.isSending = true;
      state.wasCancelled = false;
      state.pendingAlternatives = pendingAlternativesForSend;
      if (recoveryRequest == null) {
        activeSession.messages.add(ChatMessage.userContent([
          if (trimmedText.isNotEmpty) TextContent(trimmedText),
          ...attachments,
        ]));
        activeSession.autoTitle();
        final knownOperations = activeSession.pendingWorkspaceImports
            .map((receipt) => receipt.operationId)
            .toSet();
        for (final receipt in workspaceImports) {
          if (!knownOperations.add(receipt.operationId)) {
            throw StateError('Duplicate workspace import receipt.');
          }
          activeSession.pendingWorkspaceImports.add(receipt);
        }
      } else {
        _discardUnpairedInterruptedToolTail(activeSession);
        _removeTrailingAssistantErrorMarkers(activeSession);
      }
      activeSession.inFlightAgentRun = replacementMarker;
      state.sessionTitle = activeSession.title;
      try {
        await _storage.saveSession(
          activeSession,
          expectedGeneration: runToken.storageGeneration,
          commitGuard: sessionReplay?.commitGuard,
        );
      } catch (e) {
        activeSession.messages
          ..clear()
          ..addAll(previousMessages);
        activeSession.inFlightAgentRun = previousMarker;
        activeSession.pendingWorkspaceImports
          ..clear()
          ..addAll(previousWorkspaceImports);
        if (!reusesCachedLlm) llm.dispose();
        if (_ownsRun(runToken)) {
          state.pendingAlternatives = null;
          state.forceToolApprovalForRun = false;
          state.isSending = false;
          state.status = AgentStatus.error;
          state.errorMessage = _sanitizeProviderErrorMessage(e);
        }
        _finishRunToken(runToken);
        _syncCurrentSessionReference(activeSession);
        notifyListeners();
        return;
      }
      if (workspaceCommit != null && !workspaceCommit.isCompleted) {
        workspaceCommit.complete(true);
      }
      if (workspaceImports.isNotEmpty) {
        try {
          for (final receipt in workspaceImports) {
            if (!_runMayContinue(runToken)) return;
            await NativeBridge.acknowledgeWorkspaceImport(receipt);
            if (!_runMayContinue(runToken)) return;
          }
          final acknowledgedIds =
              workspaceImports.map((receipt) => receipt.operationId).toSet();
          activeSession.pendingWorkspaceImports.removeWhere(
            (receipt) => acknowledgedIds.contains(receipt.operationId),
          );
          try {
            await _storage.saveSession(
              activeSession,
              expectedGeneration: runToken.storageGeneration,
            );
          } catch (_) {
            if (!_runMayContinue(runToken)) return;
            activeSession.pendingWorkspaceImports
              ..clear()
              ..addAll(previousWorkspaceImports)
              ..addAll(workspaceImports);
          }
        } catch (e) {
          if (!_runMayContinue(runToken)) return;
          activeSession.inFlightAgentRun = previousMarker;
          try {
            await _storage.saveSession(
              activeSession,
              expectedGeneration: runToken.storageGeneration,
            );
          } catch (_) {
            // The first durable save still owns the receipt and reference.
          }
          if (!reusesCachedLlm) llm.dispose();
          if (_ownsRun(runToken)) {
            state.pendingAlternatives = null;
            state.forceToolApprovalForRun = false;
            state.isSending = false;
            state.status = AgentStatus.error;
            state.errorMessage = '工作区附件确认失败，已保留待恢复引用。';
          }
          _finishRunToken(runToken);
          _syncCurrentSessionReference(activeSession);
          notifyListeners();
          return;
        }
      }
      if (!_runMayContinue(runToken)) {
        if (!reusesCachedLlm) llm.dispose();
        return;
      }
      if (!reusesCachedLlm) {
        state.cachedLlm?.dispose();
        state.cachedLlm = llm;
        state.cachedLlmConfig = llmConfig;
      }
      if (recoveryRequest != null) {
        state.sessionApprovedTools.clear();
        // Every risky tool in a recovery-origin run needs a fresh,
        // current-state approval, including legacy/model-only Continue.
        state.forceToolApprovalForRun = true;
      }
      _syncCurrentSessionReference(activeSession);
      notifyListeners();

      runToken.traceId = runtimeDebugEvents.startRunTrace(
        activeSession.id,
        data: {
          'runAttemptId': runAttemptId,
          'trigger': traceTrigger,
          'profileLabel': _safeProfileSlotLabel(providerSnapshot),
          'providerKind': llm.resolvedModelProfile.provider.kind.name,
          'modelLabel': _safeModelLabel(llmConfig),
          'modelGroupLabel':
              activeSession.modelGroupId == null ? 'none' : 'configured',
        },
      );

      // Refresh skills (and memory) to pick up any user toggle changes
      final scannedSkills = await SkillService.scanSkills();
      if (!_runMayContinue(runToken)) return;
      _skills = scannedSkills;
      await MemoryService.getMemories();
      if (!_runMayContinue(runToken)) return;
      await _tools.refreshMcpTools();
      if (!_runMayContinue(runToken)) return;

      final basePrompt = activeSession.systemPrompt ??
          _prefs.systemPrompt ??
          AppConstants.defaultSystemPrompt;
      final skillIndex = SkillService.buildSkillIndex(_skills);
      final memoryPrompt =
          MemoryService.buildMemoryPrompt(sessionId: activeSession.id);
      final fullPrompt = basePrompt + skillIndex + memoryPrompt;

      state.status = AgentStatus.thinking;
      state.streamingText = '';
      state.errorMessage = null;
      notifyListeners();
      unawaited(_startAgentServiceForState(
        state,
        _agentServiceThinkingText,
        runToken: runToken,
      ));

      final fullApiMessages = activeSession.toApiMessages();
      if (recoveryRequest != null) {
        fullApiMessages.add(ChatMessage.userContent([
          TextContent(recoveryRequest.prompt),
          ...attachments,
        ]).toApiJson());
      }
      final capabilities = llm.resolvedModelProfile.capabilities;
      final toolDefinitions = _toolDefinitionsForBudget(
        llmConfig,
        capabilities: capabilities,
      );
      final assembly = await _contextManager.assembleForSend(
        ContextSendRequest(
          sessionId: activeSession.id,
          fullApiMessages: fullApiMessages,
          existingSummary: activeSession.contextSummary,
          llmConfig: llmConfig,
          systemPrompt: fullPrompt,
          capabilities: capabilities,
          toolDefinitions: toolDefinitions,
          contextTokenBudget: _prefs.contextTokenBudget,
          autoCompact: _prefs.autoCompact,
          activeProfileId: providerSnapshot.activeProfileId,
          onSummaryGenerationStarted: () {
            if (!_runMayContinue(runToken!)) return;
            state.status = AgentStatus.thinking;
            notifyListeners();
            unawaited(_startAgentServiceForState(
              state,
              AppStrings.contextSummaryGenerating,
              runToken: runToken,
            ));
          },
        ),
      );
      if (!_runMayContinue(runToken)) return;
      final primaryPatchSnapshot =
          _ContextSessionPatchSnapshot.capture(activeSession);
      var primaryPatchRolledBack = false;
      var preservingPrimaryPatchForRecovery = false;
      Future<void> rollbackPrimaryPatchIfSafe() async {
        if (primaryPatchRolledBack || !_ownsRun(runToken!)) return;
        primaryPatchRolledBack = await _restoreContextSessionPatchSnapshot(
          activeSession,
          primaryPatchSnapshot,
          assembly.patch,
        );
      }

      await _applyContextSessionPatch(activeSession, assembly.patch);
      if (!_runMayContinue(runToken)) return;
      final promptWithSummary = assembly.systemPrompt;
      final apiMessages = assembly.messages;
      final initialApiMsgCount = assembly.initialApiMsgCount;
      state.initialApiMsgCount = initialApiMsgCount;
      state.partialAgentResponseSaved = false;
      state.agent = _createAgentService(
        llm: llm,
        systemPrompt: promptWithSummary,
        state: state,
        activeSession: activeSession,
        runToken: runToken,
      );
      try {
        var runResult = await _runAgentForState(
          state,
          activeSession,
          apiMessages,
          runToken: runToken,
          preserveRecoveryMarker: recoveryRequest != null,
          assemblyId: assembly.assemblyId,
          attempt: 1,
          modelLabel: _safeModelLabel(llmConfig),
        );
        if (!_ownsRun(runToken)) return;
        if (runResult is EncryptedContentError) {
          preservingPrimaryPatchForRecovery = true;
          final originalError = runResult;
          _contextManager.discardCompletion(assembly.assemblyId);
          _recordRuntimeEvent(
            activeSession.id,
            'chat.recovery.invalid_encrypted_content',
            {
              'retried': true,
              'success': false,
              'stage': 'initial_error',
            },
            traceId: runToken.traceId,
          );
          final recoveryAssembly = await _contextManager.assembleForRecovery(
            ContextRecoveryRequest(
              sessionId: activeSession.id,
              messages: apiMessages,
              llmConfig: llmConfig,
              systemPrompt: promptWithSummary,
              finalTokenBudget: assembly.finalTokenBudget,
              estimator: assembly.estimator,
              capabilities: capabilities,
              autoCompact: _prefs.autoCompact,
            ),
          );
          final recoveryMessages = recoveryAssembly.messages;
          if (!_runMayContinue(runToken)) return;
          final emptyRecoveryError = _encryptedRecoveryEmptyError(
            originalError,
            recoveryMessages,
          );
          if (emptyRecoveryError != null) {
            _recordRuntimeEvent(
              activeSession.id,
              'chat.recovery.invalid_encrypted_content',
              {
                'retried': false,
                'success': false,
                'stage': 'empty_recovery_payload',
              },
              traceId: runToken.traceId,
            );
            state.status = AgentStatus.error;
            state.errorMessage = emptyRecoveryError;
            await _persistAssistantFailureMarker(
              state: state,
              session: activeSession,
              error: originalError,
              source: 'encrypted_recovery_empty',
              runToken: runToken,
              preserveRecoveryMarker: recoveryRequest != null,
            );
            notifyListeners();
          } else {
            state.agent = _createAgentService(
              llm: llm,
              systemPrompt: promptWithSummary,
              state: state,
              activeSession: activeSession,
              runToken: runToken,
              historicalSkillActivation: SkillService.latestActivationReference(
                    activeSession.messages,
                    runAttemptIds: {
                      ...runToken.skillProvenance.historicalSkillRunAttemptIds,
                      runToken.runAttemptId,
                    },
                  ) ??
                  runToken.skillProvenance.historicalSkillActivation,
            );
            state.status = AgentStatus.thinking;
            state.streamingText = '';
            state.errorMessage = null;
            state.partialAgentResponseSaved = false;
            notifyListeners();
            unawaited(_startAgentServiceForState(
              state,
              _agentServiceThinkingText,
              runToken: runToken,
            ));

            runResult = await _runAgentForState(
              state,
              activeSession,
              recoveryMessages,
              runToken: runToken,
              preserveRecoveryMarker: recoveryRequest != null,
              assemblyId: recoveryAssembly.assemblyId,
              attempt: 2,
              modelLabel: _safeModelLabel(llmConfig),
            );
            if (!_runMayContinue(runToken)) return;
            if (runResult != null || state.status == AgentStatus.error) {
              final recoveryError = runResult is EncryptedContentError
                  ? 'sanitized retry also failed: ${runResult.message}'
                  : state.errorMessage;
              _recordRuntimeEvent(
                activeSession.id,
                'chat.recovery.invalid_encrypted_content',
                {
                  'retried': true,
                  'success': false,
                  'stage': runResult is EncryptedContentError
                      ? 'retry_invalid_encrypted_content'
                      : 'retry_error',
                },
                traceId: runToken.traceId,
              );
              state.status = AgentStatus.error;
              state.errorMessage = [
                originalError.message,
                AppStrings.encryptedContentRecoveryFailed,
                if (recoveryError?.isNotEmpty == true) recoveryError!,
              ].join('\n');
              await _persistAssistantFailureMarker(
                state: state,
                session: activeSession,
                error: runResult ?? _AgentRuntimeError(state.errorMessage),
                source: 'encrypted_recovery_failed',
                runToken: runToken,
                preserveRecoveryMarker: recoveryRequest != null,
              );
              notifyListeners();
            } else {
              _recordRuntimeEvent(
                activeSession.id,
                'chat.recovery.invalid_encrypted_content',
                {
                  'retried': true,
                  'success': true,
                },
                traceId: runToken.traceId,
              );
              _persistSanitizedMessages(activeSession);
              _appendEncryptedContentRecoveryNotice(activeSession);
              _clearRecoveryMarkerAfterOwnedPositiveTerminal(
                activeSession,
                runToken,
              );
              await _storage.saveSession(
                activeSession,
                expectedGeneration: runToken.storageGeneration,
              );
              if (!_runMayContinue(runToken)) return;
              _syncCurrentSessionReference(activeSession);
              notifyListeners();
            }
          }
        } else if (state.wasCancelled) {
          final preservesStartedToolEvidence =
              _hasStartedToolRecoveryEvidence(activeSession.inFlightAgentRun);
          if (!preservingPrimaryPatchForRecovery &&
              !preservesStartedToolEvidence) {
            await rollbackPrimaryPatchIfSafe();
          }
          if (!preservesStartedToolEvidence) {
            activeSession.inFlightAgentRun = null;
            try {
              await _storage
                  .saveSession(
                    activeSession,
                    expectedGeneration: runToken.storageGeneration,
                  )
                  .timeout(
                    const Duration(milliseconds: 500),
                  );
            } on TimeoutException {
              // The ordered cancellation save remains ahead of any later run.
            }
            if (!_ownsRun(runToken)) return;
          }
        } else if (runResult != null || state.status == AgentStatus.error) {
          if (!preservingPrimaryPatchForRecovery) {
            await rollbackPrimaryPatchIfSafe();
          }
          final fallbackOutcome = await _tryRunModelFallback(
            state: state,
            runToken: runToken,
            preserveRecoveryMarker: recoveryRequest != null,
            activeSession: activeSession,
            primaryConfig: llmConfig,
            primaryAssembly: assembly,
            fullApiMessages: fullApiMessages,
            fullPrompt: fullPrompt,
            primaryCapabilities: capabilities,
            primaryToolDefinitions: toolDefinitions,
            primaryError: runResult ?? _AgentRuntimeError(state.errorMessage),
            providerSnapshot: providerSnapshot,
          );
          if (!_runMayContinue(runToken)) return;
          if (!fallbackOutcome.success && !state.wasCancelled) {
            await _persistAssistantFailureMarker(
              state: state,
              session: activeSession,
              error: runResult ?? _AgentRuntimeError(state.errorMessage),
              source: 'provider_failure',
              fallbackReasonCode: fallbackOutcome.reasonCode,
              runToken: runToken,
              preserveRecoveryMarker: recoveryRequest != null,
            );
          }
        }
      } catch (e) {
        if (!_runMayContinue(runToken)) return;
        await rollbackPrimaryPatchIfSafe();
        if (!_runMayContinue(runToken)) return;
        state.status = AgentStatus.error;
        state.errorMessage = _sanitizeProviderErrorMessage(e);
        await _persistAssistantFailureMarker(
          state: state,
          session: activeSession,
          error: e,
          source: 'provider_exception',
          runToken: runToken,
          preserveRecoveryMarker: recoveryRequest != null,
        );
        notifyListeners();
      } finally {
        _contextManager.discardCompletion(assembly.assemblyId);
        if (_ownsRun(runToken)) {
          state.agentSubscription = null;
          state.agentCompleter = null;
          state.partialAgentResponseSaved = false;
          state.initialApiMsgCount = 0;
          unawaited(
            _stopAgentServiceForState(state, runToken: runToken),
          );
        }
      }
    } catch (_) {
      final token = runToken;
      if (token?.traceId != null) {
        runtimeDebugEvents.finishRunTrace(
          token!.traceId!,
          RunTraceStatus.failed,
          errorCode: 'unexpected_exception',
        );
      }
      rethrow;
    } finally {
      if (workspaceCommit != null && !workspaceCommit.isCompleted) {
        workspaceCommit.complete(false);
      }
      final token = runToken;
      if (token != null) {
        final state = token.state;
        if (_ownsRun(token)) {
          if (token.traceId != null) {
            runtimeDebugEvents.finishRunTrace(
              token.traceId!,
              state.wasCancelled
                  ? RunTraceStatus.cancelled
                  : state.status == AgentStatus.error
                      ? RunTraceStatus.failed
                      : RunTraceStatus.completed,
              errorCode:
                  state.status == AgentStatus.error ? 'agent_run_failed' : null,
            );
          }
          state.pendingAlternatives = null;
          state.forceToolApprovalForRun = false;
          state.isSending = false;
          if (state.wasCancelled) state.status = AgentStatus.idle;
          notifyListeners();
          _finishRunToken(token);
          _drainMessageQueue(state);
        } else {
          _finishRunToken(token);
        }
      }
    }
  }

  Future<void> _sendRemoteAgentMessage(
    ChatSession session,
    String text, {
    required List<MessageContent> attachments,
    required _RecoveryRunRequest? recoveryRequest,
    _SessionReplayOperation? sessionReplay,
  }) async {
    final state = _getOrCreateState(session.id);
    if (attachments.isNotEmpty || recoveryRequest != null || text.isEmpty) {
      state.status = AgentStatus.error;
      state.errorMessage = '远程 Agent 当前仅支持纯文本消息。';
      notifyListeners();
      return;
    }
    final activeCount = _activeAgentStates.length;
    if (activeCount >= maxConcurrentAgents) {
      state.status = AgentStatus.error;
      state.errorMessage =
          AppStrings.maxConcurrentAgentsReached(maxConcurrentAgents);
      notifyListeners();
      return;
    }

    final cancellation = RemoteAgentCancellation();
    final runtimeLease = _remoteAgentRuntimeBinding.claim(cancellation);
    if (runtimeLease == null) {
      state.status = AgentStatus.error;
      state.errorMessage = _remoteAgentRuntimeBinding.unavailableReason;
      notifyListeners();
      return;
    }
    final existingCancellation = _remoteAgentCancellations[session.id];
    if (existingCancellation != null) {
      runtimeLease.release();
      state.status = AgentStatus.error;
      state.errorMessage = '该会话已有远程请求正在运行。';
      notifyListeners();
      return;
    }
    _remoteAgentCancellations[session.id] = cancellation;
    state.isSending = true;
    state.wasCancelled = false;
    state.status = AgentStatus.thinking;
    state.errorMessage = null;
    _syncCurrentSessionReference(session);
    notifyListeners();

    final configuration = runtimeLease.configuration;
    final connector = runtimeLease.connector;
    RemoteAgentAuthorizationLease? authorizationLease;
    var userTurnSaved = false;
    var generation = _storage.sessionGeneration(session.id);
    final previousMessages = session.messages
        .map((message) => ChatMessage.fromJson(message.toJson()))
        .toList(growable: false);
    try {
      await configuration.init(cancellation: cancellation);
      _requireRemoteRuntimeAuthorization(runtimeLease, sessionReplay);

      authorizationLease = await configuration.claimAuthorization(
        session.remoteAgentConnectorId!,
        cancellation,
        runtimeAuthorizationGuard: () => runtimeLease.isValid,
      );
      _requireRemoteRuntimeAuthorization(
        runtimeLease,
        sessionReplay,
        authorizationLease: authorizationLease,
      );

      _removeTrailingAssistantErrorMarkers(session);
      session.messages.add(ChatMessage.user(text));
      session.autoTitle();
      session.updatedAt = DateTime.now();
      generation = _storage.sessionGeneration(session.id);
      await _storage.saveSession(
        session,
        expectedGeneration: generation,
        commitGuard: sessionReplay?.commitGuard,
      );
      userTurnSaved = true;
      _requireRemoteRuntimeAuthorization(
        runtimeLease,
        sessionReplay,
        authorizationLease: authorizationLease,
      );

      final requestMessages = session.messages
          .where((message) =>
              !message.isSystemNotice &&
              !message.hasAssistantError &&
              (message.role == 'user' || message.role == 'assistant') &&
              message.textContent.trim().isNotEmpty)
          .map((message) => RemoteAgentMessage(
                role: message.role,
                text: message.textContent,
              ))
          .toList(growable: false);
      await _beforeRemoteConnectorSendForTesting?.call();
      _requireRemoteRuntimeAuthorization(
        runtimeLease,
        sessionReplay,
        authorizationLease: authorizationLease,
      );

      RemoteAgentComplete? terminal;
      await for (final event in connector.send(
        authorizationLease.config,
        authorizationLease.consent,
        RemoteAgentRequest(
          localSessionId: session.id,
          messages: requestMessages,
        ),
        cancellation: cancellation,
        authorizationGuard: () =>
            runtimeLease.isValid && authorizationLease!.isValid,
      )) {
        if (event is RemoteAgentComplete) terminal = event;
      }
      _requireRemoteRuntimeAuthorization(
        runtimeLease,
        sessionReplay,
        authorizationLease: authorizationLease,
      );
      if (terminal == null) {
        return;
      }
      if (_deletingSessionIds.contains(session.id) ||
          !_storage.isSessionGenerationCurrent(session.id, generation)) {
        return;
      }
      session.messages.add(ChatMessage.assistant([
        {'type': 'text', 'text': terminal.text},
      ]));
      session.updatedAt = DateTime.now();
      try {
        await _storage.saveSession(
          session,
          expectedGeneration: generation,
          commitGuard: SessionCommitGuard(
            sessionId: session.id,
            sessionGeneration: generation,
            authorizationGeneration: Object.hash(
              runtimeLease.generation,
              authorizationLease.generation,
            ),
            authority: _RemoteCompositeCommitAuthority(
              runtimeLease,
              authorizationLease,
            ),
          ),
        );
      } catch (_) {
        session.messages.removeLast();
        rethrow;
      }
      state.status = AgentStatus.idle;
      _syncCurrentSessionReference(session);
    } on RemoteAgentFailure catch (failure) {
      if (!runtimeLease.wasRevoked &&
          authorizationLease?.wasRevoked != true &&
          (failure.code == RemoteAgentErrorCode.cancelled ||
              cancellation.isCancelled)) {
        state.status = AgentStatus.idle;
        return;
      }
      final durableFailure =
          runtimeLease.wasRevoked || authorizationLease?.wasRevoked == true
              ? const RemoteAgentFailure(
                  RemoteAgentErrorCode.consentRequired,
                  retryable: true,
                )
              : failure;
      state.status = AgentStatus.error;
      state.errorMessage = durableFailure.publicMessage;
      if (userTurnSaved) {
        await _persistRemoteAgentFailure(
          session,
          durableFailure,
          expectedGeneration: generation,
        );
      } else if (runtimeLease.isValid && !cancellation.isCancelled) {
        _removeTrailingAssistantErrorMarkers(session);
        session.messages
          ..add(ChatMessage.user(text))
          ..add(ChatMessage.assistantError(
            error: _remoteAgentErrorMetadata(durableFailure),
          ));
        session.autoTitle();
        try {
          await _storage.saveSession(
            session,
            expectedGeneration: generation,
            commitGuard: sessionReplay?.commitGuard,
          );
        } catch (_) {
          session.messages
            ..clear()
            ..addAll(previousMessages);
        }
      }
    } catch (_) {
      if (cancellation.isCancelled &&
          !runtimeLease.wasRevoked &&
          authorizationLease?.wasRevoked != true) {
        return;
      }
      final failure =
          runtimeLease.wasRevoked || authorizationLease?.wasRevoked == true
              ? const RemoteAgentFailure(
                  RemoteAgentErrorCode.consentRequired,
                  retryable: true,
                )
              : const RemoteAgentFailure(
                  RemoteAgentErrorCode.transportFailure,
                  retryable: true,
                );
      state.status = AgentStatus.error;
      state.errorMessage = failure.publicMessage;
      if (userTurnSaved) {
        await _persistRemoteAgentFailure(
          session,
          failure,
          expectedGeneration: generation,
        );
      } else {
        session.messages
          ..clear()
          ..addAll(previousMessages);
      }
    } finally {
      authorizationLease?.release();
      runtimeLease.release();
      if (identical(_remoteAgentCancellations[session.id], cancellation)) {
        _remoteAgentCancellations.remove(session.id);
        state.isSending = false;
        if (state.wasCancelled) state.status = AgentStatus.idle;
        notifyListeners();
        _drainMessageQueue(state);
      }
    }
  }

  void _requireRemoteRuntimeAuthorization(
    RemoteAgentRuntimeLease runtimeLease,
    _SessionReplayOperation? sessionReplay, {
    RemoteAgentAuthorizationLease? authorizationLease,
  }) {
    if (!runtimeLease.isValid ||
        runtimeLease.cancellation.isCancelled ||
        authorizationLease?.isValid == false ||
        (sessionReplay != null && !_ownsSessionReplay(sessionReplay))) {
      throw const RemoteAgentFailure(
        RemoteAgentErrorCode.consentRequired,
        retryable: true,
      );
    }
  }

  Future<void> _persistRemoteAgentFailure(
    ChatSession session,
    RemoteAgentFailure failure, {
    required int expectedGeneration,
  }) async {
    if (_deletingSessionIds.contains(session.id) ||
        !_storage.isSessionGenerationCurrent(session.id, expectedGeneration)) {
      return;
    }
    final marker = ChatMessage.assistantError(
      error: _remoteAgentErrorMetadata(failure),
    );
    session.messages.add(marker);
    session.updatedAt = DateTime.now();
    try {
      await _storage.saveSession(
        session,
        expectedGeneration: expectedGeneration,
      );
      _syncCurrentSessionReference(session);
    } catch (_) {
      session.messages.remove(marker);
    }
  }

  AssistantErrorMetadata _remoteAgentErrorMetadata(
    RemoteAgentFailure failure,
  ) {
    final canRetry = failure.code == RemoteAgentErrorCode.transportFailure ||
        failure.code == RemoteAgentErrorCode.deadlineExceeded;
    return AssistantErrorMetadata(
      message: failure.publicMessage,
      code: 'remote_agent_${failure.code.name}',
      canRetry: canRetry,
      source: 'remote_agent',
    );
  }

  Future<void> cancelAgent({String? sessionId, bool savePartial = true}) async {
    final id = sessionId ?? currentSession?.id;
    if (id == null) return;
    final state = _agentStates[id];
    if (state == null || !state.isSending) return;
    final remoteCancellation = _remoteAgentCancellations[id];
    if (remoteCancellation != null) {
      state.wasCancelled = true;
      remoteCancellation.cancel();
      return;
    }
    final runToken = _activeRunTokens[id];
    if (runToken == null || !_ownsRun(runToken)) return;

    state.wasCancelled = true;
    _cancelMessageQueueDrain(state);
    final runAgent = state.agent;
    final runCompleter = state.agentCompleter;
    final runSubscription = state.agentSubscription;
    final cancellation =
        runAgent?.cancel() ?? const AgentCancellationSnapshot();
    state.cachedLlm?.dispose();
    state.cachedLlm = null;
    state.cachedLlmConfig = null;
    if (identical(_pendingApprovalState, state)) {
      _completePendingApproval(false);
    }
    if (runSubscription != null) {
      try {
        await runSubscription.cancel().timeout(
              const Duration(milliseconds: 250),
              onTimeout: () {},
            );
      } catch (_) {
        // Cancellation is best effort; arbitrary tools may not stop promptly.
      }
    }
    if (_ownsRun(runToken) &&
        identical(state.agentSubscription, runSubscription)) {
      state.agentSubscription = null;
    }
    try {
      await _stopAgentServiceForState(state, runToken: runToken).timeout(
        const Duration(milliseconds: 250),
      );
    } on TimeoutException {
      // Native teardown is bounded by the same generation guard.
    }
    try {
      final preservedToolRecovery = await _persistCancelledToolRecovery(
        state,
        cancellation,
        runToken,
      );
      if (!_ownsRun(runToken)) return;
      if (savePartial && !preservedToolRecovery) {
        _flushStreamingNow(state, notify: false);
        _savePartialAgentResponse(
          state,
          interruptionNote: '回复已取消，内容可能不完整。',
          runToken: runToken,
        );
      }
      if (!preservedToolRecovery) {
        try {
          await _clearInFlightAgentRunAwaited(state, runToken).timeout(
            const Duration(milliseconds: 500),
          );
        } on TimeoutException {
          // The ordered save remains queued ahead of any later run marker.
        }
      }
    } finally {
      if (_ownsRun(runToken)) {
        if (runToken.traceId != null) {
          runtimeDebugEvents.finishRunTrace(
            runToken.traceId!,
            RunTraceStatus.cancelled,
            errorCode: 'user_cancelled',
          );
        }
        _clearStreamingState(state);
        if (runCompleter != null && !runCompleter.isCompleted) {
          runCompleter.complete();
        }
        try {
          await runToken.finished.future.timeout(
            const Duration(milliseconds: 500),
          );
        } on TimeoutException {
          // Establish a new generation boundary without waiting forever for a
          // non-cancellable tool or delayed completion persistence.
        }
      }
      if (_ownsRun(runToken)) {
        state.isSending = false;
        state.status = AgentStatus.idle;
        state.forceToolApprovalForRun = false;
        _finishRunToken(runToken);
        notifyListeners();
      }
    }
  }

  Future<bool> _persistCancelledToolRecovery(
    AgentState state,
    AgentCancellationSnapshot cancellation,
    _AgentRunToken runToken,
  ) async {
    if (!_ownsRun(runToken)) return false;
    final session = currentSession?.id == state.sessionId
        ? currentSession
        : await _storage.getSession(state.sessionId);
    final marker = session?.inFlightAgentRun;
    if (!_ownsRun(runToken) ||
        session == null ||
        marker == null ||
        marker.runAttemptId != runToken.runAttemptId) {
      return false;
    }
    final now = DateTime.now();
    final interruptedOperationIds = <String>{};
    var preservesStartedToolEvidence = false;
    var nextMarker = marker;
    for (final attempt in marker.toolAttempts) {
      if (_hasStartedToolRecoveryEvidenceForAttempt(attempt)) {
        preservesStartedToolEvidence = true;
      }
      final wasExecuting =
          cancellation.inFlightOperationIds.contains(attempt.operationId) ||
              attempt.lifecycle == ToolAttemptLifecycle.started ||
              attempt.lifecycle == ToolAttemptLifecycle.completed ||
              attempt.lifecycle == ToolAttemptLifecycle.interruptedUnknown ||
              (attempt.lifecycle == ToolAttemptLifecycle.failed &&
                  attempt.executionStartedAt != null &&
                  !attempt.executionOutcomeKnown);
      if (!wasExecuting ||
          attempt.lifecycle == ToolAttemptLifecycle.resultPersisted) {
        continue;
      }
      interruptedOperationIds.add(attempt.operationId);
      nextMarker = nextMarker.upsertToolAttempt(
        attempt.copyWith(
          lifecycle: ToolAttemptLifecycle.interruptedUnknown,
          updatedAt: now,
          executionStartedAt: attempt.executionStartedAt ?? now,
          executionOutcomeKnown: false,
        ),
      );
    }
    if (!preservesStartedToolEvidence) return false;
    session.inFlightAgentRun = nextMarker;
    try {
      await _storage
          .saveSession(
            session,
            expectedGeneration: runToken.storageGeneration,
          )
          .timeout(
            const Duration(milliseconds: 500),
          );
    } on TimeoutException {
      // Invocation ordering is already reserved by SessionStorage. Keep the
      // unknown evidence and allow the UI to stop waiting for cancellation.
      return true;
    }
    if (!_ownsRun(runToken)) return true;
    _syncCurrentSessionReference(session);
    for (final operationId in interruptedOperationIds) {
      _recordRuntimeEvent(
          state.sessionId,
          'tool.attempt.interruptedUnknown',
          {
            'runAttemptId': marker.runAttemptId,
            'operationId': operationId,
            'lifecycle': ToolAttemptLifecycle.interruptedUnknown.name,
          },
          traceId: runToken.traceId);
    }
    _recordRuntimeEvent(
        state.sessionId,
        'chat.run.cancelled',
        {
          'runAttemptId': marker.runAttemptId,
          'lifecycle': interruptedOperationIds.isNotEmpty
              ? ToolAttemptLifecycle.interruptedUnknown.name
              : ToolAttemptLifecycle.failed.name,
        },
        traceId: runToken.traceId);
    return true;
  }

  bool _hasStartedToolRecoveryEvidence(AgentRunRecoveryMarker? marker) {
    return marker?.toolAttempts.any(
          _hasStartedToolRecoveryEvidenceForAttempt,
        ) ??
        false;
  }

  bool _hasStartedToolRecoveryEvidenceForAttempt(
    ToolAttemptRecoveryMetadata attempt,
  ) {
    if (attempt.lifecycle == ToolAttemptLifecycle.resultPersisted) {
      return false;
    }
    if (attempt.executionStartedAt != null) return true;
    // Fail closed for malformed in-memory state. Failed without a start is a
    // known pre-start failure and is the only failed state safe to clear.
    return attempt.lifecycle == ToolAttemptLifecycle.started ||
        attempt.lifecycle == ToolAttemptLifecycle.completed ||
        attempt.lifecycle == ToolAttemptLifecycle.interruptedUnknown;
  }

  void _clearRecoveryMarkerAfterOwnedPositiveTerminal(
    ChatSession session,
    _AgentRunToken runToken,
  ) {
    final marker = session.inFlightAgentRun;
    if (marker == null ||
        marker.runAttemptId != runToken.runAttemptId ||
        !marker.canClearAfterPositiveTerminal) {
      return;
    }
    session.inFlightAgentRun = null;
  }

  Future<void> _clearInFlightAgentRunAwaited(
    AgentState state,
    _AgentRunToken runToken,
  ) async {
    if (!_ownsRun(runToken)) return;
    final session = currentSession?.id == state.sessionId
        ? currentSession
        : await _storage.getSession(state.sessionId);
    if (!_ownsRun(runToken) ||
        session?.inFlightAgentRun?.runAttemptId != runToken.runAttemptId) {
      return;
    }
    session!.inFlightAgentRun = null;
    await _storage.saveSession(
      session,
      expectedGeneration: runToken.storageGeneration,
    );
    if (!_ownsRun(runToken)) return;
    _syncCurrentSessionReference(session);
  }

  void _enqueueMessage(
    AgentState state,
    String text,
    List<MessageContent> attachments,
  ) {
    if (state.messageQueue.length >= maxQueuedMessages) {
      state.errorMessage = AppStrings.messageQueueFull(maxQueuedMessages);
      notifyListeners();
      return;
    }
    state.messageQueue.add(QueuedMessage(
      text: text,
      attachments: List<MessageContent>.from(attachments),
    ));
    notifyListeners();
  }

  void _drainMessageQueue(AgentState state) {
    if (state.messageQueue.isEmpty ||
        _disposed ||
        state.wasCancelled ||
        state.status == AgentStatus.error) {
      _cancelMessageQueueDrain(state);
      state.wasCancelled = false;
      _cleanupIdleState(state.sessionId);
      return;
    }
    if (state.isSending) return;
    final next = state.messageQueue.first;
    if (state.messageQueueDrainTimer?.isActive == true &&
        state.messageQueueDrainHeadId == next.id) {
      return;
    }
    _cancelMessageQueueDrain(state);
    notifyListeners();
    final epoch = ++state.messageQueueDrainEpoch;
    state.messageQueueDrainHeadId = next.id;
    state.messageQueueDrainTimer = _messageQueueDrainTimerFactory(
      const Duration(seconds: 1),
      () {
        if (state.messageQueueDrainEpoch != epoch) return;
        state.messageQueueDrainTimer = null;
        state.messageQueueDrainHeadId = null;
        if (_disposed || state.wasCancelled) return;
        if (state.isSending ||
            state.messageQueue.isEmpty ||
            state.messageQueue.first.id != next.id) {
          _drainMessageQueue(state);
          return;
        }
        final activeCount = _activeAgentStates.length;
        if (activeCount >= maxConcurrentAgents) {
          _drainMessageQueue(state);
          return;
        }
        state.messageQueue.removeAt(0);
        notifyListeners();
        sendMessage(
          next.text,
          attachments: next.attachments,
          targetSessionId: state.sessionId,
        );
      },
    );
  }

  void _cancelMessageQueueDrain(AgentState state) {
    state.messageQueueDrainTimer?.cancel();
    state.messageQueueDrainTimer = null;
    state.messageQueueDrainHeadId = null;
    state.messageQueueDrainEpoch++;
  }

  MessageQueueUndo? removeQueuedMessage(String id) {
    final state = _getState(currentSession?.id);
    if (state == null) return null;
    final index = state.messageQueue.indexWhere((message) => message.id == id);
    if (index < 0) return null;
    final removedHead = index == 0;
    final removed = state.messageQueue.removeAt(index);
    if (state.messageQueue.isEmpty) {
      _cancelMessageQueueDrain(state);
    } else if (removedHead) {
      _drainMessageQueue(state);
    }
    notifyListeners();
    return MessageQueueUndo._(
      sessionId: state.sessionId,
      startIndex: index,
      messages: List.unmodifiable([removed]),
    );
  }

  MessageQueueUndo? clearMessageQueue() {
    final state = _getState(currentSession?.id);
    if (state == null || state.messageQueue.isEmpty) return null;
    final removed = List<QueuedMessage>.from(state.messageQueue);
    state.messageQueue.clear();
    _cancelMessageQueueDrain(state);
    state.wasCancelled = false;
    notifyListeners();
    return MessageQueueUndo._(
      sessionId: state.sessionId,
      startIndex: 0,
      messages: List.unmodifiable(removed),
    );
  }

  bool restoreMessageQueue(MessageQueueUndo undo) {
    final result = restoreMessageQueueWithResult(undo);
    return result.restoredAny && result.remainingUndo == null;
  }

  MessageQueueRestoreResult restoreMessageQueueWithResult(
    MessageQueueUndo undo,
  ) {
    if (!sessions.any((session) => session.id == undo.sessionId)) {
      return const MessageQueueRestoreResult(
        restoredCount: 0,
        remainingUndo: null,
        sessionMissing: true,
      );
    }
    final state = _getOrCreateState(undo.sessionId);
    if (undo.messages.any(
      (removed) => state.messageQueue.any((item) => item.id == removed.id),
    )) {
      return MessageQueueRestoreResult(
        restoredCount: 0,
        remainingUndo: undo,
      );
    }
    final available = maxQueuedMessages - state.messageQueue.length;
    final restoreCount = available.clamp(0, undo.messages.length);
    if (restoreCount == 0) {
      return MessageQueueRestoreResult(
        restoredCount: 0,
        remainingUndo: undo,
      );
    }
    final index = undo.startIndex.clamp(0, state.messageQueue.length);
    final restored = undo.messages.take(restoreCount).toList(growable: false);
    state.messageQueue.insertAll(index, restored);
    final remainingMessages = undo.messages.skip(restoreCount).toList(
          growable: false,
        );
    final remaining = remainingMessages.isEmpty
        ? null
        : MessageQueueUndo._(
            sessionId: undo.sessionId,
            startIndex: index + restoreCount,
            messages: List.unmodifiable(remainingMessages),
          );
    _drainMessageQueue(state);
    notifyListeners();
    return MessageQueueRestoreResult(
      restoredCount: restoreCount,
      remainingUndo: remaining,
    );
  }

  void expireMessageQueueUndo(MessageQueueUndo undo) {
    _cleanupIdleState(undo.sessionId);
  }

  void sendNextQueued() {
    final id = currentSession?.id;
    if (id == null) return;
    final state = _getState(id);
    if (state == null || state.isSending || state.messageQueue.isEmpty) return;
    _cancelMessageQueueDrain(state);
    state.wasCancelled = false;
    final next = state.messageQueue.removeAt(0);
    notifyListeners();
    sendMessage(next.text, attachments: next.attachments, targetSessionId: id);
  }

  void _savePartialAgentResponse(
    AgentState state, {
    String? interruptionNote,
    required _AgentRunToken runToken,
  }) {
    if (!_ownsRun(runToken) ||
        state.partialAgentResponseSaved ||
        state.agentCompletionFinalizing) {
      return;
    }
    final agent = state.agent;
    if (agent == null) return;

    final partialText = state.streamBuffer.toString();
    state.partialAgentResponseSaved = true;
    final session =
        currentSession?.id == state.sessionId ? currentSession : null;
    if (session != null) {
      _savePartialAgentResponseToSession(
        state,
        session,
        agent,
        partialText,
        runToken,
        interruptionNote: interruptionNote,
      );
      return;
    }

    unawaited(_storage.getSession(state.sessionId).then((session) {
      if (session == null || !_ownsRun(runToken)) return;
      _savePartialAgentResponseToSession(
        state,
        session,
        agent,
        partialText,
        runToken,
        interruptionNote: interruptionNote,
      );
    }).catchError((Object e) {
      debugPrint('Failed to load session for partial agent response: $e');
    }));
  }

  void _savePartialAgentResponseToSession(
    AgentState state,
    ChatSession session,
    AgentService agent,
    String partialText,
    _AgentRunToken runToken, {
    String? interruptionNote,
  }) {
    if (!_ownsRun(runToken)) return;
    _appendNewAgentMessages(
      state,
      session,
      agent.messages,
      state.initialApiMsgCount,
    );

    final lastAgentMsg = agent.messages.isNotEmpty ? agent.messages.last : null;
    final lastMsgIsAssistant =
        lastAgentMsg != null && lastAgentMsg['role'] == 'assistant';
    if (partialText.isNotEmpty && !lastMsgIsAssistant) {
      final savedText = _partialTextWithInterruptionNote(
        partialText,
        interruptionNote,
      );
      session.messages.add(ChatMessage(
        role: 'assistant',
        content: [TextContent(savedText)],
        alternatives: state.pendingAlternatives,
        activeAlternative: -1,
      ));
      state.pendingAlternatives = null;
    }

    _syncCurrentSessionReference(session);
    unawaited(_storage
        .saveSession(
      session,
      expectedGeneration: runToken.storageGeneration,
    )
        .catchError((Object e) {
      debugPrint('Failed to save partial agent response: $e');
    }));
  }

  String _partialTextWithInterruptionNote(String text, String? note) {
    final trimmedNote = note?.trim();
    if (trimmedNote == null || trimmedNote.isEmpty) return text;
    return '$text\n\n[$trimmedNote]';
  }

  Future<void> regenerateLastResponse() async {
    final source = currentSession;
    final id = source?.id;
    final state = _getState(id);
    if (state != null && state.messageQueue.isNotEmpty) {
      state.errorMessage = AppStrings.clearQueueBeforeRegenerate;
      notifyListeners();
      return;
    }
    if (source == null || (state?.isSending ?? false)) return;
    final sourceSnapshot = ChatSession.fromJson(source.toJson());
    final messages = sourceSnapshot.messages;

    // Find the last assistant message to preserve its text as an alternative
    ChatMessage? lastAssistant;
    for (int i = messages.length - 1; i >= 0; i--) {
      if (messages[i].role == 'assistant') {
        lastAssistant = messages[i];
        break;
      }
    }

    // Find the last user message text and retryable attachments.
    String? lastUserText;
    ChatMessage? lastUserMessage;
    for (int i = messages.length - 1; i >= 0; i--) {
      if (messages[i].role == 'user' && messages[i].textContent.isNotEmpty) {
        lastUserText = messages[i].textContent;
        lastUserMessage = messages[i];
        break;
      }
    }
    if (lastUserText == null) return;
    final retryAttachments = _retryableAttachmentsFor(lastUserMessage!);

    // Save the old assistant text for reuse after regeneration
    List<String>? pendingAlternatives;
    if (lastAssistant != null) {
      pendingAlternatives = List<String>.from(lastAssistant.alternatives ?? []);
      final currentText = lastAssistant.latestTextContent;
      if (currentText.isNotEmpty) {
        pendingAlternatives.add(currentText);
      }
    }

    // Remove trailing messages until we find the last user message with TEXT
    // content (not tool_result). Tool_result user messages must be removed too
    // because their matching tool_use assistant messages will be regenerated.
    while (messages.isNotEmpty) {
      final last = messages.last;
      if (last.role == 'user' && last.textContent.isNotEmpty) break;
      messages.removeLast();
    }
    if (messages.isEmpty) return;

    // Remove the user message too; sendMessage will re-add it
    messages.removeLast();

    final operation = _claimSessionReplay(
      session: source,
      sessionSnapshot: sourceSnapshot,
      prompt: lastUserText,
      attachments: retryAttachments,
      pendingAlternatives: pendingAlternatives,
      traceTrigger: 'regenerate',
    );
    try {
      await _storage.saveSession(
        operation.sessionSnapshot,
        expectedGeneration: operation.storageGeneration,
        commitGuard: operation.commitGuard,
      );
      if (!_ownsSessionReplay(operation)) return;
      _publishSessionReplayBoundary(operation);
      _syncCurrentSessionReference(operation.liveSession);
      notifyListeners();
      await _sendMessage(
        operation.prompt,
        attachments: operation.attachments,
        pendingAlternatives: operation.pendingAlternatives,
        targetSessionId: operation.sessionId,
        traceTrigger: operation.traceTrigger,
        sessionReplay: operation,
      );
    } catch (error) {
      if (_ownsSessionReplay(operation)) {
        final ownedState = _getOrCreateState(operation.sessionId);
        ownedState.status = AgentStatus.error;
        ownedState.errorMessage = _sanitizeProviderErrorMessage(error);
        notifyListeners();
      }
    } finally {
      _retireSessionReplay(operation);
    }
  }

  Future<AssistantRetryStatus> retryAssistantMessage(int messageIndex) async {
    final source = currentSession;
    if (source == null ||
        messageIndex < 0 ||
        messageIndex >= source.messages.length) {
      return AssistantRetryStatus.invalidMessage;
    }

    final state = _getState(source.id);
    if ((state?.isSending ?? false) ||
        (state?.messageQueue.isNotEmpty ?? false)) {
      return AssistantRetryStatus.busy;
    }

    final session = ChatSession.fromJson(source.toJson());
    final failedMessage = session.messages[messageIndex];
    final error = failedMessage.assistantError;
    if (error == null || !error.canRetry) {
      return AssistantRetryStatus.notRetryable;
    }

    final lastContentIndex = _lastNonSystemMessageIndex(session.messages);
    if (lastContentIndex != messageIndex) {
      return AssistantRetryStatus.notRetryable;
    }

    final recoveryMarker = session.inFlightAgentRun;
    if (recoveryMarker != null || error.isRecoveryRetry) {
      if (recoveryMarker == null ||
          recoveryMarker.recoveryKind ==
              InterruptedRunRecoveryKind.inspectOnly ||
          (error.recoveryRunAttemptId != null &&
              error.recoveryRunAttemptId != recoveryMarker.runAttemptId)) {
        return AssistantRetryStatus.notRetryable;
      }
      final operation = _claimSessionReplay(
        session: source,
        sessionSnapshot: session,
        prompt: '',
        attachments: const [],
        pendingAlternatives: null,
        traceTrigger: 'interrupted_recovery',
      );
      try {
        await _ensurePrefs();
        if (!_ownsSessionReplay(operation)) {
          return AssistantRetryStatus.invalidMessage;
        }
        if (_prefs.activeProfile.apiKey.trim().isEmpty) {
          return AssistantRetryStatus.missingApiKey;
        }
        if (_activeAgentStates.length >= maxConcurrentAgents) {
          return AssistantRetryStatus.busy;
        }
        final started = await _continueInterruptedReplay(
          operation,
          recoveryMarker,
        );
        return started
            ? AssistantRetryStatus.started
            : AssistantRetryStatus.invalidMessage;
      } finally {
        _retireSessionReplay(operation);
      }
    }

    final userIndex = _retryUserMessageIndexBefore(session, messageIndex);
    if (userIndex == null) return AssistantRetryStatus.invalidMessage;

    final userMessage =
        ChatMessage.fromJson(session.messages[userIndex].toJson());
    final retryText = userMessage.textContent.trim();
    final retryAttachments = _retryableAttachmentsFor(userMessage);
    if (retryText.isEmpty && retryAttachments.isEmpty) {
      return AssistantRetryStatus.invalidMessage;
    }
    final operation = _claimSessionReplay(
      session: source,
      sessionSnapshot: session,
      prompt: retryText,
      attachments: retryAttachments,
      pendingAlternatives: null,
      traceTrigger: 'retry',
    );
    try {
      await _ensurePrefs();
      if (!_ownsSessionReplay(operation)) {
        return AssistantRetryStatus.invalidMessage;
      }
      if (session.remoteAgentConnectorId == null &&
          _prefs.activeProfile.apiKey.trim().isEmpty) {
        return AssistantRetryStatus.missingApiKey;
      }
      final activeCount = _activeAgentStates.length;
      if (activeCount >= maxConcurrentAgents) {
        return AssistantRetryStatus.busy;
      }
      operation.sessionSnapshot.messages.removeRange(
        userIndex,
        operation.sessionSnapshot.messages.length,
      );
      operation.sessionSnapshot.updatedAt = DateTime.now();
      await _storage.saveSession(
        operation.sessionSnapshot,
        expectedGeneration: operation.storageGeneration,
        commitGuard: operation.commitGuard,
      );
      if (!_ownsSessionReplay(operation)) {
        return AssistantRetryStatus.invalidMessage;
      }
      _publishSessionReplayBoundary(operation);
      final retryState = _getOrCreateState(operation.sessionId);
      retryState.status = AgentStatus.idle;
      retryState.errorMessage = null;
      retryState.wasCancelled = false;
      _syncCurrentSessionReference(operation.liveSession);
      notifyListeners();
      await _sendMessage(
        operation.prompt,
        attachments: operation.attachments,
        targetSessionId: operation.sessionId,
        traceTrigger: operation.traceTrigger,
        sessionReplay: operation,
      );
      return AssistantRetryStatus.started;
    } catch (error) {
      if (_ownsSessionReplay(operation)) {
        final retryState = _getOrCreateState(operation.sessionId);
        retryState.status = AgentStatus.error;
        retryState.errorMessage = _sanitizeProviderErrorMessage(error);
        notifyListeners();
      }
      return AssistantRetryStatus.invalidMessage;
    } finally {
      _retireSessionReplay(operation);
    }
  }

  Future<bool> _continueInterruptedReplay(
    _SessionReplayOperation operation,
    AgentRunRecoveryMarker marker,
  ) async {
    if (!_ownsSessionReplay(operation)) return false;
    final prompt = switch (marker.recoveryKind) {
      InterruptedRunRecoveryKind.reauthorizeAction =>
        _agentRunReauthorizationPrompt,
      InterruptedRunRecoveryKind.unknownOutcome =>
        _agentRunUnknownOutcomePrompt,
      InterruptedRunRecoveryKind.retryModelTurn =>
        marker.hasPersistedToolResults
            ? _agentRunPersistedResultPrompt
            : _agentRunRecoveryPrompt,
      InterruptedRunRecoveryKind.inspectOnly => _agentRunRecoveryPrompt,
    };
    await _sendMessage(
      '',
      attachments: operation.attachments,
      targetSessionId: operation.sessionId,
      traceTrigger: operation.traceTrigger,
      recoveryRequest: _RecoveryRunRequest(
        expectedRunAttemptId: marker.runAttemptId,
        previousMarker: marker,
        prompt: prompt,
      ),
      sessionReplay: operation,
    );
    if (!_storage.isSessionGenerationCurrent(
      operation.sessionId,
      operation.storageGeneration,
    )) {
      return false;
    }
    final current = currentSession?.id == operation.sessionId
        ? currentSession
        : await _storage.getSession(operation.sessionId);
    final nextMarker = current?.inFlightAgentRun;
    return nextMarker == null || nextMarker.runAttemptId != marker.runAttemptId;
  }

  int? _lastNonSystemMessageIndex(List<ChatMessage> messages) {
    for (var i = messages.length - 1; i >= 0; i--) {
      if (!messages[i].isSystemNotice) return i;
    }
    return null;
  }

  int? _retryUserMessageIndexBefore(ChatSession session, int messageIndex) {
    for (var i = messageIndex - 1; i >= 0; i--) {
      final message = session.messages[i];
      if (message.isSystemNotice) continue;
      if (message.role == 'user' &&
          (message.textContent.trim().isNotEmpty ||
              message.content.any((content) =>
                  content is! TextContent && content is! ToolResultContent))) {
        return i;
      }
      return null;
    }
    return null;
  }

  void switchAlternative(int messageIndex, int altIndex) {
    if (currentSession == null) return;
    final messages = currentSession!.messages;
    if (messageIndex < 0 || messageIndex >= messages.length) return;

    final msg = messages[messageIndex];
    if (msg.alternatives == null || msg.alternatives!.isEmpty) return;

    final totalVersions = msg.totalVersions;
    if (altIndex < 0 || altIndex >= totalVersions) return;
    final activeAlternative = altIndex == totalVersions - 1 ? -1 : altIndex;

    // Replace the message in the session
    messages[messageIndex] = ChatMessage(
      role: msg.role,
      content: msg.content,
      timestamp: msg.timestamp,
      inputTokens: msg.inputTokens,
      outputTokens: msg.outputTokens,
      cacheReadInputTokens: msg.cacheReadInputTokens,
      cacheCreationInputTokens: msg.cacheCreationInputTokens,
      inputTokensIncludeCache: msg.inputTokensIncludeCache,
      alternatives: msg.alternatives,
      activeAlternative: activeAlternative,
      isSystemNotice: msg.isSystemNotice,
      assistantError: msg.assistantError,
      alternativeProvenance: msg.alternativeProvenance,
      currentProvenance: msg.currentProvenance,
    );

    _messageVersion++;
    _storage.saveSession(currentSession!);
    notifyListeners();
  }

  /// Navigate to the previous alternative for a message.
  void previousAlternative(int messageIndex) {
    if (currentSession == null) return;
    final msg = currentSession!.messages[messageIndex];
    final current = msg.displayIndex; // 1-based
    if (current > 1) {
      switchAlternative(messageIndex, current - 2);
    }
  }

  /// Navigate to the next alternative for a message.
  void nextAlternative(int messageIndex) {
    if (currentSession == null) return;
    final msg = currentSession!.messages[messageIndex];
    final current = msg.displayIndex; // 1-based
    if (current < msg.totalVersions) {
      switchAlternative(messageIndex, current);
    }
  }

  // ── Multi-model compare ──────────────────────────────────────────
  List<CompareResult>? compareResults;
  _CompareOwner? _compareOwner;
  final Set<String> _cancelledCompareModels = {};
  final Map<String, LlmService> _compareLlmByModel = {};
  int _compareGeneration = 0;
  bool _isComparing = false;
  bool get isComparing => _isComparing;
  String? get compareOwnerSessionId => _compareOwner?.sessionId;
  int? get compareOwnerStorageGeneration => _compareOwner?.storageGeneration;
  int? get compareOperationGeneration => _compareOwner?.compareGeneration;
  bool get compareBelongsToCurrentSession =>
      _compareOwner?.sessionId == currentSession?.id;

  bool _ownsCompare(_CompareOwner owner) =>
      identical(_compareOwner, owner) &&
      _compareGeneration == owner.compareGeneration &&
      _storage.isSessionGenerationCurrent(
        owner.sessionId,
        owner.storageGeneration,
      );

  Future<void> sendCompare(String text, List<String> models) async {
    // Everything below is captured synchronously before the first await. A
    // session switch can only affect UI visibility, never request ownership.
    final initiatingSession = currentSession;
    final comparePrompt = text.trim();
    final compareModels = models
        .map((model) => model.trim())
        .where((model) => model.isNotEmpty)
        .toSet()
        .take(ChatMessage.maxAlternatives + 1)
        .toList(growable: false);
    if (initiatingSession == null) {
      _fallbackErrorMessage = '请先打开一个会话';
      notifyListeners();
      return;
    }
    final currentState = _getState(initiatingSession.id);
    if ((currentState?.isSending ?? false) || _isComparing) {
      errorMessage =
          (currentState?.isSending ?? false) ? '当前会话正在发送中' : '正在对比中，请等待完成';
      notifyListeners();
      return;
    }
    if (comparePrompt.isEmpty || compareModels.length < 2) {
      errorMessage = comparePrompt.isEmpty ? '请输入对比内容' : '请选择至少两个模型';
      notifyListeners();
      return;
    }
    final compareGeneration = ++_compareGeneration;
    final owner = _CompareOwner(
      sessionId: initiatingSession.id,
      storageGeneration: _storage.sessionGeneration(initiatingSession.id),
      prompt: comparePrompt,
      compareGeneration: compareGeneration,
      sessionSnapshot: ChatSession.fromJson(initiatingSession.toJson()),
    );
    _compareOwner = owner;
    _isComparing = true;
    _cancelledCompareModels.clear();
    compareResults = compareModels
        .map((model) => CompareResult.loading(model: model))
        .toList();
    errorMessage = null;
    notifyListeners();

    try {
      await _ensurePrefs();
      if (!_ownsCompare(owner) || compareResults == null) {
        return;
      }
      final apiKey = _prefs.apiKey;
      if (apiKey == null || apiKey.isEmpty) {
        errorMessage = AppStrings.apiKeyNotConfigured;
        compareResults = compareModels
            .map((model) => CompareResult.error(
                  model: model,
                  errorCode: 'missing_api_key',
                ))
            .toList();
        return;
      }

      _skills = await SkillService.scanSkills();
      if (!_ownsCompare(owner)) return;
      await MemoryService.getMemories();
      if (!_ownsCompare(owner)) return;
      final session = owner.sessionSnapshot;
      final skillIndex = SkillService.buildSkillIndex(_skills);
      final memoryPrompt =
          MemoryService.buildMemoryPrompt(sessionId: session.id);

      final formatStr =
          session.apiFormatOverride ?? _prefs.apiFormat ?? 'anthropic';
      final format =
          formatStr == 'openai' ? ApiFormat.openai : ApiFormat.anthropic;
      final baseUrl = session.baseUrlOverride ??
          _prefs.baseUrl ??
          (format == ApiFormat.anthropic
              ? 'https://api.anthropic.com'
              : 'https://api.openai.com');
      final basePrompt = session.systemPrompt ??
          _prefs.systemPrompt ??
          AppConstants.defaultSystemPrompt;
      final fullPrompt = basePrompt + skillIndex + memoryPrompt;
      final compareBudgetConfig = LlmConfig(
        format: format,
        apiKey: apiKey,
        model: compareModels.first,
        baseUrl: baseUrl,
        maxTokens: _prefs.maxTokens ?? AppConstants.defaultMaxTokens,
        thinkingBudget: _prefs.thinkingBudget,
        temperature: _prefs.temperature,
      );
      // Don't persist the user message to session.messages in compare mode.
      // Compare is a one-shot inspection — results live in compareResults only.
      // If we persisted, the next real sendMessage would break role alternation
      // (two consecutive user messages without an assistant reply between them).
      final assembly = await _contextManager.assembleForCompare(
        ContextCompareRequest(
          sessionId: session.id,
          sessionApiMessages: session.toApiMessages(),
          comparePrompt: comparePrompt,
          existingSummary: session.contextSummary,
          llmConfig: compareBudgetConfig,
          systemPrompt: fullPrompt,
          compareModels: compareModels,
          contextTokenBudget: _prefs.contextTokenBudget,
          autoCompact: _prefs.autoCompact,
        ),
      );
      if (!_ownsCompare(owner) || compareResults == null) {
        return;
      }
      final compareSystemPrompt = assembly.systemPrompt;
      final compareMessages = assembly.messages;
      notifyListeners();

      for (var index = 0; index < compareModels.length; index++) {
        final model = compareModels[index];
        if (_disposed) break;
        if (!_ownsCompare(owner) || compareResults == null) {
          return;
        }
        if (_cancelledCompareModels.contains(model)) continue;
        final stopwatch = Stopwatch()..start();
        try {
          final config = LlmConfig(
            format: format,
            apiKey: apiKey,
            model: model,
            baseUrl: baseUrl,
            maxTokens: _prefs.maxTokens ?? AppConstants.defaultMaxTokens,
            thinkingBudget: _prefs.thinkingBudget,
            temperature: _prefs.temperature,
          );
          final llm = _llmServiceFactory(
            config,
            isInBackground: () => _appInBackground,
          );
          _compareLlmByModel[model] = llm;
          try {
            final response = await llm.chat(
              system: compareSystemPrompt,
              messages: compareMessages,
              tools: [],
            );
            if (!_ownsCompare(owner) || compareResults == null) {
              return;
            }
            final responseText = response.content
                .where((b) => b.type == 'text')
                .map((b) => b.text ?? '')
                .join();
            if (_cancelledCompareModels.contains(model)) continue;
            compareResults![index] = CompareResult.complete(
              model: model,
              text: responseText,
              tokens: response.outputTokens,
              latencyMs: stopwatch.elapsedMilliseconds,
            );
          } finally {
            if (identical(_compareLlmByModel[model], llm)) {
              _compareLlmByModel.remove(model);
            }
            llm.dispose();
          }
        } catch (_) {
          if (!_ownsCompare(owner) || compareResults == null) {
            return;
          }
          if (!_cancelledCompareModels.contains(model)) {
            compareResults![index] = CompareResult.error(
              model: model,
              errorCode: 'provider_failure',
            );
          }
        }
        if (_ownsCompare(owner)) notifyListeners();
      }
    } catch (e) {
      if (!_ownsCompare(owner)) return;
      errorMessage = '对比失败，请检查配置后重试';
      compareResults ??= [];
      compareResults = compareResults!
          .map((result) => result.state == CompareResultState.loading
              ? CompareResult.error(
                  model: result.model,
                  errorCode: 'compare_failure',
                )
              : result)
          .toList();
    } finally {
      if (identical(_compareOwner, owner) &&
          _compareGeneration == compareGeneration) {
        _isComparing = false;
        notifyListeners();
      }
    }
  }

  bool clearCompareResults({
    required String ownerSessionId,
    required int compareGeneration,
  }) {
    final owner = _compareOwner;
    if (owner == null ||
        owner.sessionId != ownerSessionId ||
        owner.compareGeneration != compareGeneration) {
      return false;
    }
    _compareGeneration++;
    for (final llm in _compareLlmByModel.values) {
      llm.dispose();
    }
    _compareLlmByModel.clear();
    compareResults = null;
    _isComparing = false;
    _compareOwner = null;
    _cancelledCompareModels.clear();
    notifyListeners();
    return true;
  }

  void cancelCompareResult(
    String model, {
    required String ownerSessionId,
    required int compareGeneration,
  }) {
    final owner = _compareOwner;
    if (owner == null ||
        owner.sessionId != ownerSessionId ||
        owner.compareGeneration != compareGeneration) {
      return;
    }
    final results = compareResults;
    if (results == null) return;
    final index = results.indexWhere(
      (result) =>
          result.model == model && result.state == CompareResultState.loading,
    );
    if (index < 0) return;
    _cancelledCompareModels.add(model);
    _compareLlmByModel.remove(model)?.dispose();
    results[index] = CompareResult.cancelled(model: model);
    notifyListeners();
  }

  Future<void> retryCompareResult(String model) async {
    final previousOwner = _compareOwner;
    final results = compareResults;
    if (_isComparing ||
        previousOwner == null ||
        results == null ||
        !_ownsCompare(previousOwner)) {
      return;
    }
    final index = results.indexWhere((result) =>
        result.model == model && result.state == CompareResultState.error);
    if (index < 0) return;
    _isComparing = true;
    final compareGeneration = ++_compareGeneration;
    final owner = previousOwner.withCompareGeneration(compareGeneration);
    _compareOwner = owner;
    _cancelledCompareModels.remove(model);
    results[index] = CompareResult.loading(model: model);
    notifyListeners();
    final stopwatch = Stopwatch()..start();
    try {
      await _ensurePrefs();
      if (!_ownsCompare(owner) || compareResults == null) {
        return;
      }
      final apiKey = _prefs.apiKey;
      if (apiKey == null || apiKey.isEmpty) {
        results[index] = CompareResult.error(
          model: model,
          errorCode: 'missing_api_key',
        );
        return;
      }
      final session = owner.sessionSnapshot;
      final formatStr =
          session.apiFormatOverride ?? _prefs.apiFormat ?? 'anthropic';
      final format =
          formatStr == 'openai' ? ApiFormat.openai : ApiFormat.anthropic;
      final baseUrl = session.baseUrlOverride ??
          _prefs.baseUrl ??
          (format == ApiFormat.anthropic
              ? 'https://api.anthropic.com'
              : 'https://api.openai.com');
      _skills = await SkillService.scanSkills();
      if (!_ownsCompare(owner)) return;
      await MemoryService.getMemories();
      if (!_ownsCompare(owner)) return;
      final systemPrompt = (session.systemPrompt ??
              _prefs.systemPrompt ??
              AppConstants.defaultSystemPrompt) +
          SkillService.buildSkillIndex(_skills) +
          MemoryService.buildMemoryPrompt(sessionId: session.id);
      final config = LlmConfig(
        format: format,
        apiKey: apiKey,
        model: model,
        baseUrl: baseUrl,
        maxTokens: _prefs.maxTokens ?? AppConstants.defaultMaxTokens,
        thinkingBudget: _prefs.thinkingBudget,
        temperature: _prefs.temperature,
      );
      final assembly = await _contextManager.assembleForCompare(
        ContextCompareRequest(
          sessionId: session.id,
          sessionApiMessages: session.toApiMessages(),
          comparePrompt: owner.prompt,
          existingSummary: session.contextSummary,
          llmConfig: config,
          systemPrompt: systemPrompt,
          compareModels: [model],
          contextTokenBudget: _prefs.contextTokenBudget,
          autoCompact: _prefs.autoCompact,
        ),
      );
      if (!_ownsCompare(owner) || compareResults == null) {
        return;
      }
      final llm = _llmServiceFactory(
        config,
        isInBackground: () => _appInBackground,
      );
      _compareLlmByModel[model] = llm;
      try {
        final response = await llm.chat(
          system: assembly.systemPrompt,
          messages: assembly.messages,
          tools: const [],
        );
        if (!_ownsCompare(owner) || compareResults == null) {
          return;
        }
        if (_cancelledCompareModels.contains(model)) return;
        results[index] = CompareResult.complete(
          model: model,
          text: response.content
              .where((block) => block.type == 'text')
              .map((block) => block.text ?? '')
              .join(),
          tokens: response.outputTokens,
          latencyMs: stopwatch.elapsedMilliseconds,
        );
      } finally {
        if (identical(_compareLlmByModel[model], llm)) {
          _compareLlmByModel.remove(model);
        }
        llm.dispose();
      }
    } catch (_) {
      if (_ownsCompare(owner) && !_cancelledCompareModels.contains(model)) {
        results[index] = CompareResult.error(
          model: model,
          errorCode: 'provider_failure',
        );
      }
    } finally {
      if (identical(_compareOwner, owner) &&
          _compareGeneration == compareGeneration) {
        _isComparing = false;
        notifyListeners();
      }
    }
  }

  Future<bool> useCompareResult(int selectedIndex) async {
    final owner = _compareOwner;
    final results = compareResults;
    if (owner == null ||
        !_ownsCompare(owner) ||
        results == null ||
        selectedIndex < 0 ||
        selectedIndex >= results.length ||
        results[selectedIndex].state != CompareResultState.complete) {
      return false;
    }
    final session = await _storage.getSession(owner.sessionId);
    if (session == null || !_ownsCompare(owner)) return false;
    final selected = results[selectedIndex];
    final successful = results
        .where((result) => result.state == CompareResultState.complete)
        .toList(growable: false);
    final alternatives = successful
        .where((result) => !identical(result, selected))
        .take(ChatMessage.maxAlternatives)
        .toList(growable: false);
    session.messages
      ..add(ChatMessage.user(owner.prompt))
      ..add(ChatMessage(
        role: 'assistant',
        content: [TextContent(selected.text)],
        outputTokens: selected.tokens,
        alternatives: alternatives.map((result) => result.text).toList(),
        alternativeProvenance: alternatives
            .map<AssistantOutcomeProvenance?>((result) => result.provenance)
            .toList(),
        currentProvenance: selected.provenance,
      ));
    session
      ..updatedAt = DateTime.now()
      ..autoTitle();
    try {
      await _storage.saveSession(
        session,
        expectedGeneration: owner.storageGeneration,
      );
    } on SessionTombstonedException {
      return false;
    }
    if (!_ownsCompare(owner)) return false;
    _syncCurrentSessionReference(session);
    clearCompareResults(
      ownerSessionId: owner.sessionId,
      compareGeneration: owner.compareGeneration,
    );
    return true;
  }

  Future<void> updateSessionModel({
    String? model,
    String? baseUrl,
    String? apiFormat,
  }) async {
    if (currentSession == null) return;
    currentSession!.modelOverride = model;
    currentSession!.baseUrlOverride = baseUrl;
    currentSession!.apiFormatOverride = apiFormat;
    await _storage.saveSession(currentSession!);
    _clearIdleLlmCaches();
    notifyListeners();
  }

  Future<void> switchProfile(String profileId) async {
    await _ensurePrefs();
    await _prefs.setActiveProfileId(profileId);
    LlmService.clearTokenKeyOverrides();
    _clearIdleLlmCaches();
    notifyListeners();
  }

  Future<void> updateSessionSystemPrompt(String? systemPrompt) async {
    if (currentSession == null) return;
    currentSession!.systemPrompt = systemPrompt;
    await _storage.saveSession(currentSession!);
    notifyListeners();
  }

  bool get remoteAgentAvailable =>
      _remoteAgentConfiguration?.isReady == true &&
      _remoteAgentConnector != null;

  @visibleForTesting
  int get activeRemoteCancellationCount => _remoteAgentCancellations.length;

  String get remoteAgentUnavailableReason =>
      _remoteAgentRuntimeBinding.unavailableReason;

  bool get currentSessionUsesRemoteAgent =>
      currentSession?.remoteAgentConnectorId != null;

  String get currentExecutionContextLabel {
    final session = currentSession;
    if (session?.remoteAgentConnectorId != null) {
      final config = _remoteAgentConfiguration?.config;
      if (config != null && config.id == session!.remoteAgentConnectorId) {
        return 'External · ${config.displayName}';
      }
      return 'External · unavailable';
    }
    final localIdentity = session?.modelOverride ??
        session?.modelGroupId ??
        'default model group';
    return 'Local · $localIdentity';
  }

  Future<bool> setCurrentSessionRemoteAgentEnabled(bool enabled) async {
    final session = currentSession;
    if (session == null || (_getState(session.id)?.isSending ?? false)) {
      return false;
    }
    if (enabled) {
      final config = _remoteAgentConfiguration?.config;
      if (config == null || !remoteAgentAvailable) return false;
      session.remoteAgentConnectorId = config.id;
    } else {
      session.remoteAgentConnectorId = null;
    }
    await _storage.saveSession(session);
    _clearIdleLlmCaches();
    notifyListeners();
    return true;
  }

  Future<void> clearCurrentContextSummary() async {
    final session = currentSession;
    if (session == null || session.contextSummary == null) return;
    session.contextSummary = null;
    await _storage.saveSession(session);
    _syncCurrentSessionReference(session);
    _recordRuntimeEvent(session.id, 'context.summary.manual.cleared', {
      'messageCount': session.toApiMessages().length,
    });
    notifyListeners();
  }

  Future<ManualContextSummaryResult> rebuildContextSummaryBeforeMessage(
    int messageIndex,
  ) async {
    final session = currentSession;
    if (session == null) {
      return const ManualContextSummaryResult(
        success: false,
        message: AppStrings.contextSummaryNoSession,
      );
    }
    if (messageIndex <= 0 || messageIndex > session.messages.length) {
      return const ManualContextSummaryResult(
        success: false,
        message: AppStrings.contextSummarySelectLaterMessage,
      );
    }
    if (_isManualContextSummaryBusy(session)) {
      return const ManualContextSummaryResult(
        success: false,
        message: AppStrings.contextSummaryBusy,
      );
    }
    _manualContextSummarySessions.add(session.id);
    notifyListeners();
    var requestedApiMessageCount = 0;
    var coveredMessageCount = 0;
    try {
      await _ensurePrefs();
      if (_prefs.apiKey == null || _prefs.apiKey!.isEmpty) {
        return const ManualContextSummaryResult(
          success: false,
          message: AppStrings.apiKeyNotConfigured,
        );
      }

      final requestedPrefix = _apiPrefixBeforeMessage(session, messageIndex);
      requestedApiMessageCount = requestedPrefix.length;
      final safeCount = _safeManualSummaryPrefixCount(requestedPrefix);
      if (safeCount <= 0) {
        return ManualContextSummaryResult(
          success: false,
          message: AppStrings.contextSummaryNoSafePrefix,
          requestedApiMessageCount: requestedApiMessageCount,
        );
      }
      final safePrefix = requestedPrefix.take(safeCount).toList();
      coveredMessageCount = safePrefix.length;
      final summary = await _contextManager.buildManualSummary(
        ContextManualSummaryRequest(
          sessionId: session.id,
          apiPrefixMessages: safePrefix,
          llmConfig: _buildLlmConfig(session),
          contextTokenBudget: _prefs.contextTokenBudget,
        ),
      );
      session.contextSummary = summary;
      await _storage.saveSession(session);
      _syncCurrentSessionReference(session);
      notifyListeners();
      return ManualContextSummaryResult(
        success: true,
        message: AppStrings.contextSummaryRebuilt(
          summary.coveredMessageCount,
        ),
        summary: summary,
        requestedApiMessageCount: requestedPrefix.length,
        coveredMessageCount: summary.coveredMessageCount,
      );
    } catch (e) {
      _recordRuntimeEvent(session.id, 'context.summary.manual.failed', {
        'stage': 'provider',
        'errorCode': e.runtimeType.toString(),
      });
      return ManualContextSummaryResult(
        success: false,
        message: AppStrings.contextSummaryRebuildFailed(_briefError(e)),
        requestedApiMessageCount: requestedApiMessageCount,
        coveredMessageCount: coveredMessageCount,
      );
    } finally {
      _manualContextSummarySessions.remove(session.id);
      if (!_disposed) notifyListeners();
    }
  }

  List<Map<String, dynamic>> _apiPrefixBeforeMessage(
    ChatSession session,
    int messageIndex,
  ) {
    final prefix = <Map<String, dynamic>>[];
    final cappedIndex = messageIndex.clamp(0, session.messages.length).toInt();
    for (var i = 0; i < cappedIndex; i++) {
      final message = session.messages[i];
      if (message.isSystemNotice) continue;
      prefix.add(message.toApiJson());
    }
    return prefix;
  }

  int _safeManualSummaryPrefixCount(List<Map<String, dynamic>> messages) {
    for (var count = messages.length; count > 0; count--) {
      if (_isSafeManualSummaryPrefix(messages.take(count))) {
        return count;
      }
    }
    return 0;
  }

  bool _isSafeManualSummaryPrefix(Iterable<Map<String, dynamic>> messages) {
    final toolUseIds = <String>{};
    final toolResultIds = <String>{};
    for (final message in messages) {
      toolUseIds.addAll(_toolUseIds(message));
      toolResultIds.addAll(_toolResultIds(message));
    }
    return toolUseIds.containsAll(toolResultIds) &&
        toolResultIds.containsAll(toolUseIds);
  }

  Set<String> _toolUseIds(Map<String, dynamic> message) {
    final content = message['content'];
    if (content is! List) return const {};
    return content
        .whereType<Map>()
        .where((block) => block['type'] == 'tool_use')
        .map((block) => block['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();
  }

  Set<String> _toolResultIds(Map<String, dynamic> message) {
    final content = message['content'];
    if (content is! List) return const {};
    return content
        .whereType<Map>()
        .where((block) => block['type'] == 'tool_result')
        .map((block) => block['tool_use_id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();
  }

  String _briefError(Object error) {
    final text = error.toString().replaceFirst('Exception: ', '');
    return text.length > 160 ? '${text.substring(0, 160)}...' : text;
  }

  String _sanitizeProviderErrorMessage(Object? error) {
    final raw = (error?.toString() ?? '').replaceFirst('Exception: ', '');
    if (raw.isEmpty) return '模型请求失败';
    final sanitized = const LlmContentSanitizer().sanitizeText(raw).text;
    return sanitized.length > 240
        ? '${sanitized.substring(0, 240)}...'
        : sanitized;
  }

  void _restorePersistedAssistantErrorState(ChatSession session) {
    final lastIndex = _lastNonSystemMessageIndex(session.messages);
    if (lastIndex == null) return;
    final error = session.messages[lastIndex].assistantError;
    if (error == null) return;
    final state = _getOrCreateState(session.id);
    if (state.isSending) return;
    state.status = AgentStatus.error;
    state.errorMessage = error.message;
    state.wasCancelled = false;
  }

  Future<void> _persistAssistantFailureMarker({
    required AgentState state,
    required ChatSession session,
    required Object? error,
    required String source,
    String? fallbackReasonCode,
    _AgentRunToken? runToken,
    bool preserveRecoveryMarker = false,
  }) async {
    if (state.wasCancelled || (runToken != null && !_ownsRun(runToken))) {
      return;
    }
    final sanitizedMessage = _sanitizeProviderErrorMessage(
      state.errorMessage ?? error,
    );
    final reason = _fallbackReasonFor(error, sanitizedMessage);
    final recoveryMarker =
        preserveRecoveryMarker ? session.inFlightAgentRun : null;
    final recoveryRetryAllowed = recoveryMarker != null &&
        recoveryMarker.recoveryKind != InterruptedRunRecoveryKind.inspectOnly &&
        !state.wasCancelled &&
        reason.code != 'user_cancelled';
    final metadata = AssistantErrorMetadata(
      message: sanitizedMessage,
      code: reason.code,
      canRetry: recoveryMarker != null
          ? recoveryRetryAllowed
          : _canRetryAssistantFailure(state, reason),
      source: source,
      fallbackReasonCode: fallbackReasonCode,
      fallbackReasonLabel: fallbackReasonCode == null ? null : reason.label,
      retryAction: recoveryMarker != null
          ? AssistantRetryAction.continueRecovery
          : AssistantRetryAction.resendUserMessage,
      recoveryRunAttemptId: recoveryMarker?.runAttemptId,
    );

    _removeTrailingAssistantErrorMarkers(session);
    session.messages.add(ChatMessage.assistantError(error: metadata));
    if (!preserveRecoveryMarker) session.inFlightAgentRun = null;
    session.updatedAt = DateTime.now();
    await _storage.saveSession(
      session,
      expectedGeneration: runToken?.storageGeneration,
    );
    if (runToken != null && !_ownsRun(runToken)) return;
    _syncCurrentSessionReference(session);
  }

  bool _canRetryAssistantFailure(AgentState state, _FallbackReason reason) {
    if (state.wasCancelled || reason.code == 'user_cancelled') return false;
    if (state.fallbackToolStarted || state.fallbackMessagesPersisted) {
      return false;
    }
    return true;
  }

  void _removeTrailingAssistantErrorMarkers(ChatSession session) {
    while (session.messages.isNotEmpty &&
        session.messages.last.hasAssistantError) {
      session.messages.removeLast();
    }
  }

  _ProviderProfileSnapshot _captureProviderProfileSnapshot(
    ChatSession? session,
  ) {
    final profiles =
        _prefs.profiles.map(_snapshotProviderProfile).toList(growable: false);
    var activeProfile = _snapshotProviderProfile(_prefs.activeProfile);
    var activeProfileId = _prefs.activeProfileId ?? activeProfile.id;

    final group = _prefs.modelGroupById(session?.modelGroupId);
    if (group != null) {
      final profileById = {
        for (final profile in profiles) profile.id: profile,
      };
      final primaryProfile = profileById[group.primaryProfileId];
      if (primaryProfile != null) {
        activeProfile = primaryProfile.copyWith(
          fallbackTargets: List<ModelFallbackTarget>.unmodifiable(
            group.fallbackTargets.map((target) => target.copyWith()),
          ),
        );
        activeProfileId = primaryProfile.id;
      }
    }

    return _ProviderProfileSnapshot(
      activeProfileId: activeProfileId,
      activeProfile: activeProfile,
      profiles: profiles,
    );
  }

  ProviderProfile _snapshotProviderProfile(ProviderProfile profile) {
    return profile.copyWith(
      fallbackTargets: List<ModelFallbackTarget>.unmodifiable(
        profile.fallbackTargets.map((target) => target.copyWith()),
      ),
    );
  }

  Future<_ModelFallbackOutcome> _tryRunModelFallback({
    required AgentState state,
    required _AgentRunToken runToken,
    required bool preserveRecoveryMarker,
    required ChatSession activeSession,
    required LlmConfig primaryConfig,
    required ContextAssemblyResult primaryAssembly,
    required List<Map<String, dynamic>> fullApiMessages,
    required String fullPrompt,
    required ModelCapabilities primaryCapabilities,
    required List<Map<String, dynamic>> primaryToolDefinitions,
    required Object? primaryError,
    required _ProviderProfileSnapshot providerSnapshot,
  }) async {
    if (!_runMayContinue(runToken)) {
      return const _ModelFallbackOutcome.failed('superseded_run');
    }
    final reason = _fallbackReasonFor(primaryError, state.errorMessage);
    if (!_isFallbackSafeForState(state)) {
      _recordModelFallbackEvent(
          activeSession.id,
          'model.fallback.skipped',
          {
            'reason': 'unsafe_after_partial_run',
            'primaryReason': reason.code,
          },
          traceId: runToken.traceId);
      return const _ModelFallbackOutcome.failed('unsafe_after_partial_run');
    }
    if (!reason.canFallback) {
      _recordModelFallbackEvent(
          activeSession.id,
          'model.fallback.skipped',
          {
            'reason': reason.code,
          },
          traceId: runToken.traceId);
      return _ModelFallbackOutcome.failed(reason.code);
    }

    final candidates = _resolveModelFallbackCandidates(
      primaryConfig,
      providerSnapshot,
    );
    if (candidates.isEmpty) {
      _recordModelFallbackEvent(
          activeSession.id,
          'model.fallback.skipped',
          {
            'reason': 'no_configured_candidate',
            'primaryReason': reason.code,
          },
          traceId: runToken.traceId);
      return const _ModelFallbackOutcome.failed('no_configured_candidate');
    }

    var attemptIndex = 0;
    var lastFailureReason = reason.code;
    for (final candidate in candidates) {
      if (!_runMayContinue(runToken)) {
        return const _ModelFallbackOutcome.failed('superseded_run');
      }
      attemptIndex++;
      final llm = _llmServiceFactory(
        candidate.config,
        isInBackground: () => _appInBackground,
      );
      final capabilities = llm.resolvedModelProfile.capabilities;
      final skipReason = _fallbackCapabilitySkipReason(
        capabilities: capabilities,
        primaryCapabilities: primaryCapabilities,
        primaryConfig: primaryConfig,
        candidateConfig: candidate.config,
        primaryAssembly: primaryAssembly,
        primaryToolDefinitions: primaryToolDefinitions,
        fullApiMessages: fullApiMessages,
        primaryReason: reason,
      );
      if (skipReason != null) {
        llm.dispose();
        _recordModelFallbackEvent(
            activeSession.id,
            'model.fallback.skipped',
            {
              'reason': skipReason,
              'candidate': candidate.safeLabel,
              'attemptIndex': attemptIndex,
            },
            traceId: runToken.traceId);
        lastFailureReason = skipReason;
        continue;
      }

      final toolDefinitions = _toolDefinitionsForBudget(
        candidate.config,
        capabilities: capabilities,
      );
      ContextAssemblyResult? assembly;
      Object? runResult;
      try {
        assembly = await _contextManager.assembleForSend(
          ContextSendRequest(
            sessionId: activeSession.id,
            fullApiMessages: fullApiMessages,
            existingSummary: activeSession.contextSummary,
            llmConfig: candidate.config,
            systemPrompt: fullPrompt,
            capabilities: capabilities,
            toolDefinitions: toolDefinitions,
            contextTokenBudget: _prefs.contextTokenBudget,
            autoCompact: _prefs.autoCompact,
            activeProfileId: candidate.profile.id,
            onSummaryGenerationStarted: () {
              if (!_runMayContinue(runToken)) return;
              state.status = AgentStatus.thinking;
              notifyListeners();
              unawaited(_startAgentServiceForState(
                state,
                AppStrings.contextSummaryGenerating,
                runToken: runToken,
              ));
            },
          ),
        );
        if (!_runMayContinue(runToken)) {
          llm.dispose();
          return const _ModelFallbackOutcome.failed('superseded_run');
        }

        state.cachedLlm?.dispose();
        state.cachedLlm = llm;
        state.cachedLlmConfig = candidate.config;
        state.agent = _createAgentService(
          llm: llm,
          systemPrompt: assembly.systemPrompt,
          state: state,
          activeSession: activeSession,
          runToken: runToken,
        );
        state.status = AgentStatus.thinking;
        state.streamingText = '';
        state.errorMessage = null;
        state.partialAgentResponseSaved = false;
        notifyListeners();
        unawaited(_startAgentServiceForState(
          state,
          _agentServiceThinkingText,
          runToken: runToken,
        ));

        _recordModelFallbackEvent(
            activeSession.id,
            'model.fallback.attempt',
            {
              'primary': _safeModelLabel(primaryConfig),
              'candidate': candidate.safeLabel,
              'reason': reason.code,
              'attemptIndex': attemptIndex,
            },
            traceId: runToken.traceId);

        runResult = await _runAgentForState(
          state,
          activeSession,
          assembly.messages,
          runToken: runToken,
          preserveRecoveryMarker: preserveRecoveryMarker,
          assemblyId: assembly.assemblyId,
          attempt: attemptIndex + 1,
          modelLabel: candidate.safeLabel,
        );
      } catch (e) {
        if (!_runMayContinue(runToken)) {
          return const _ModelFallbackOutcome.failed('superseded_run');
        }
        runResult = e;
        state.status = AgentStatus.error;
        state.errorMessage = _sanitizeProviderErrorMessage(e);
        notifyListeners();
      } finally {
        if (assembly != null) {
          _contextManager.discardCompletion(assembly.assemblyId);
        }
      }

      if (!_runMayContinue(runToken)) {
        return const _ModelFallbackOutcome.failed('superseded_run');
      }

      final failed = state.wasCancelled ||
          runResult != null ||
          state.status == AgentStatus.error;
      if (!failed) {
        if (assembly != null) {
          await _applyContextSessionPatch(activeSession, assembly.patch);
          if (!_runMayContinue(runToken)) {
            return const _ModelFallbackOutcome.failed('superseded_run');
          }
        }
        _appendModelFallbackNotice(
          activeSession,
          primary: _safeModelLabel(primaryConfig),
          fallback: candidate.safeLabel,
          reason: reason.label,
        );
        _clearRecoveryMarkerAfterOwnedPositiveTerminal(
          activeSession,
          runToken,
        );
        await _storage.saveSession(
          activeSession,
          expectedGeneration: runToken.storageGeneration,
        );
        if (!_runMayContinue(runToken)) {
          return const _ModelFallbackOutcome.failed('superseded_run');
        }
        _syncCurrentSessionReference(activeSession);
        _recordModelFallbackEvent(
            activeSession.id,
            'model.fallback.success',
            {
              'primary': _safeModelLabel(primaryConfig),
              'fallback': candidate.safeLabel,
              'reason': reason.code,
              'attemptIndex': attemptIndex,
            },
            traceId: runToken.traceId);
        notifyListeners();
        return const _ModelFallbackOutcome.success();
      }

      final candidateReason = _fallbackReasonFor(runResult, state.errorMessage);
      lastFailureReason = candidateReason.code;
      _recordModelFallbackEvent(
          activeSession.id,
          'model.fallback.failed',
          {
            'candidate': candidate.safeLabel,
            'reason': candidateReason.code,
            'attemptIndex': attemptIndex,
          },
          traceId: runToken.traceId);

      final canContinue = _isFallbackSafeForState(state) &&
          candidateReason.canFallback &&
          !state.wasCancelled;
      if (identical(state.cachedLlm, llm)) {
        state.cachedLlm?.dispose();
        state.cachedLlm = null;
        state.cachedLlmConfig = null;
      } else {
        llm.dispose();
      }
      if (!canContinue) return _ModelFallbackOutcome.failed(lastFailureReason);
    }
    return _ModelFallbackOutcome.failed(lastFailureReason);
  }

  bool _isFallbackSafeForState(AgentState state) {
    return !state.wasCancelled &&
        !state.fallbackTextEmitted &&
        !state.fallbackToolStarted &&
        !state.fallbackMessagesPersisted;
  }

  List<_ModelFallbackCandidate> _resolveModelFallbackCandidates(
    LlmConfig primaryConfig,
    _ProviderProfileSnapshot providerSnapshot,
  ) {
    if (!_prefsInitialized) return const [];
    final activeProfile = providerSnapshot.activeProfile;
    final profiles = {
      for (final profile in providerSnapshot.profiles) profile.id: profile,
    };
    final seen = <String>{};
    final candidates = <_ModelFallbackCandidate>[];
    for (final target in activeProfile.fallbackTargets) {
      if (!target.enabled) continue;
      final targetId = target.targetProfileId.trim();
      if (targetId.isEmpty || targetId == activeProfile.id) continue;
      final profile = profiles[targetId];
      if (profile == null || profile.apiKey.trim().isEmpty) continue;
      final config = _buildLlmConfigForProfile(
        profile,
        modelOverride:
            target.hasModelOverride ? target.effectiveModelOverride : null,
      );
      if (_sameModelDestination(config, primaryConfig)) continue;
      final key = [
        profile.id,
        config.format.name,
        _normalizedBaseUrl(config.baseUrl),
        config.model,
      ].join('\n');
      if (!seen.add(key)) continue;
      candidates.add(_ModelFallbackCandidate(
        profile: profile,
        config: config,
      ));
    }
    return candidates;
  }

  LlmConfig _buildLlmConfigFromSnapshot(
    _ProviderProfileSnapshot snapshot,
    ChatSession session,
  ) {
    return _buildLlmConfigForProfileSnapshot(
      snapshot.activeProfile,
      session,
    );
  }

  LlmConfig _buildLlmConfigForProfileSnapshot(
    ProviderProfile profile,
    ChatSession session,
  ) {
    final formatStr = session.apiFormatOverride ?? profile.apiFormat;
    final format =
        formatStr == 'openai' ? ApiFormat.openai : ApiFormat.anthropic;
    final baseUrl = session.baseUrlOverride ??
        (profile.baseUrl.trim().isNotEmpty
            ? profile.baseUrl.trim()
            : (format == ApiFormat.anthropic
                ? 'https://api.anthropic.com'
                : 'https://api.openai.com'));

    return LlmConfig(
      format: format,
      apiKey: profile.apiKey.trim(),
      model: session.modelOverride ?? profile.effectiveModel,
      baseUrl: baseUrl,
      maxTokens: profile.maxTokens,
      thinkingBudget: profile.thinkingBudget,
      temperature: profile.temperature,
      capabilityOverride:
          session.modelOverride == null ? profile.capabilityOverride : null,
    );
  }

  LlmConfig _buildLlmConfigForProfile(
    ProviderProfile profile, {
    String? modelOverride,
  }) {
    final format = profile.apiFormat == ProviderProfile.openaiFormat
        ? ApiFormat.openai
        : ApiFormat.anthropic;
    final model = (modelOverride?.trim().isNotEmpty ?? false)
        ? modelOverride!.trim()
        : profile.effectiveModel;
    final baseUrl = profile.baseUrl.trim().isNotEmpty
        ? profile.baseUrl.trim()
        : (format == ApiFormat.anthropic
            ? 'https://api.anthropic.com'
            : 'https://api.openai.com');
    return LlmConfig(
      format: format,
      apiKey: profile.apiKey.trim(),
      model: model,
      baseUrl: baseUrl,
      maxTokens: profile.maxTokens,
      thinkingBudget: profile.thinkingBudget,
      temperature: profile.temperature,
      capabilityOverride:
          model == profile.effectiveModel ? profile.capabilityOverride : null,
    );
  }

  bool _sameModelDestination(LlmConfig a, LlmConfig b) {
    return a.format == b.format &&
        _normalizedBaseUrl(a.baseUrl) == _normalizedBaseUrl(b.baseUrl) &&
        a.model.trim() == b.model.trim();
  }

  String _normalizedBaseUrl(String value) {
    return value.trim().replaceFirst(RegExp(r'/+$'), '');
  }

  String? _fallbackCapabilitySkipReason({
    required ModelCapabilities capabilities,
    required ModelCapabilities primaryCapabilities,
    required LlmConfig primaryConfig,
    required LlmConfig candidateConfig,
    required ContextAssemblyResult primaryAssembly,
    required List<Map<String, dynamic>> primaryToolDefinitions,
    required List<Map<String, dynamic>> fullApiMessages,
    required _FallbackReason primaryReason,
  }) {
    if (primaryToolDefinitions.isNotEmpty && !capabilities.supportsTools) {
      return 'tools_not_supported';
    }
    if (_messagesContainImages(fullApiMessages) &&
        !capabilities.supportsImages) {
      return 'vision_not_supported';
    }
    if (primaryConfig.thinkingBudget > 0 &&
        candidateConfig.thinkingBudget <= 0) {
      return 'reasoning_budget_not_configured';
    }
    if (primaryConfig.thinkingBudget > 0 &&
        !capabilities.supportsReasoningContent &&
        !capabilities.supportsThinkingBudget) {
      return 'reasoning_not_supported';
    }
    final candidateWindow = capabilities.maxContextTokens;
    if (candidateWindow != null &&
        candidateWindow < primaryAssembly.budget.effectiveContextTokenBudget) {
      return 'context_window_smaller';
    }
    if (primaryReason.contextTooLarge) {
      final primaryWindow = primaryCapabilities.maxContextTokens;
      if (candidateWindow == null ||
          primaryWindow == null ||
          candidateWindow <= primaryWindow) {
        return 'context_window_not_larger';
      }
    }
    return null;
  }

  bool _messagesContainImages(List<Map<String, dynamic>> messages) {
    for (final message in messages) {
      if (_contentContainsImage(message['content'])) return true;
    }
    return false;
  }

  bool _contentContainsImage(Object? content) {
    if (content is Map) {
      final type = content['type']?.toString();
      if (type == 'image' || type == 'image_url') return true;
      return content.values.any(_contentContainsImage);
    }
    if (content is Iterable) {
      return content.any(_contentContainsImage);
    }
    return false;
  }

  _FallbackReason _fallbackReasonFor(Object? error, String? message) {
    final raw = [
      if (error != null) error.toString(),
      if (message?.isNotEmpty == true) message!,
    ].join('\n');
    final text = raw.toLowerCase();
    if (text.contains('cancel')) {
      return const _FallbackReason.blocked('user_cancelled', '用户取消');
    }
    if (_containsAny(text, const [
      '401',
      '403',
      'unauthorized',
      'forbidden',
      'authentication',
      'auth error',
      'api key',
      'apikey',
      'invalid key',
      'permission denied',
    ])) {
      return const _FallbackReason.blocked('auth_or_permission', '鉴权失败');
    }
    if (_containsAny(text, const [
      'content policy',
      'safety',
      'refusal',
      'refused',
      'moderation',
    ])) {
      return const _FallbackReason.blocked('safety_or_refusal', '安全策略');
    }
    if (_containsAny(text, const [
      'context length',
      'context_length',
      'maximum context',
      'token limit',
      'too many tokens',
      'context too large',
      'exceeds context',
    ])) {
      return const _FallbackReason.allowed(
        'context_too_large',
        '上下文过长',
        contextTooLarge: true,
      );
    }
    if (_containsAny(text, const [
      'tool approval',
      'tool execution',
      'tool error',
      'schema',
      'invalid request',
      'invalid_request',
      'bad request',
      '400',
      'unsupported',
      'unrecognized',
      'not permitted',
      'not allowed',
    ])) {
      return const _FallbackReason.blocked('invalid_or_tool_error', '请求无效');
    }
    if (_containsAny(text, const [
      '429',
      'rate limit',
      'rate_limit',
      'quota',
      'too many requests',
    ])) {
      return const _FallbackReason.allowed('rate_limited', '限流');
    }
    if (_containsAny(text, const [
      'timeout',
      'timed out',
      'socketexception',
      'handshakeexception',
      'connection closed',
      'connection reset',
      'network',
      'stream interrupted',
      'ended without finish_reason',
      'ended without message_stop',
      'temporarily unavailable',
    ])) {
      return const _FallbackReason.allowed('network_or_timeout', '网络异常');
    }
    if (_containsAny(text, const [
      '500',
      '502',
      '503',
      '504',
      '529',
      'overloaded',
      'server error',
      'service unavailable',
      'bad gateway',
      'gateway timeout',
    ])) {
      return const _FallbackReason.allowed('provider_unavailable', '服务不可用');
    }
    if ((text.contains('model') || text.contains('deployment')) &&
        _containsAny(text, const [
          'not found',
          'unavailable',
          'does not exist',
          'not available',
        ])) {
      return const _FallbackReason.allowed('model_unavailable', '模型不可用');
    }
    return const _FallbackReason.blocked('non_retryable', '不可重试错误');
  }

  bool _containsAny(String text, List<String> needles) {
    return needles.any(text.contains);
  }

  void _recordModelFallbackEvent(
      String sessionId, String type, Map<String, Object?> data,
      {String? traceId}) {
    _recordRuntimeEvent(sessionId, type, data, traceId: traceId);
  }

  String _safeModelLabel(LlmConfig config) {
    return '${config.format.name}/${_safeFallbackLabelText(config.model)}';
  }

  String _safeProfileSlotLabel(_ProviderProfileSnapshot snapshot) {
    final index = snapshot.profiles.indexWhere(
      (profile) => profile.id == snapshot.activeProfileId,
    );
    return index < 0 ? 'profile_custom' : 'profile_${index + 1}';
  }

  void _appendModelFallbackNotice(
    ChatSession session, {
    required String primary,
    required String fallback,
    required String reason,
  }) {
    final text = AppStrings.modelFallbackUsedNotice(
      primary: primary,
      fallback: fallback,
      reason: reason,
    );
    if (session.messages.isNotEmpty) {
      final last = session.messages.last;
      if (last.isSystemNotice && last.textContent == text) return;
    }
    session.messages.add(ChatMessage.systemNotice(text));
  }

  _RecoverySkillProvenance _recoverySkillProvenance(
    ChatSession session,
    _RecoveryRunRequest? recoveryRequest,
  ) {
    if (recoveryRequest == null) {
      return const _RecoverySkillProvenance.empty();
    }
    final persisted = recoveryRequest.previousMarker.skillActivation;
    if (persisted != null) {
      return _RecoverySkillProvenance(
        historicalSkillRunAttemptIds: {persisted.sourceRunAttemptId},
        historicalSkillActivation: SkillActivationReference(
          id: persisted.skillId,
          trustDigest: persisted.trustDigest,
        ),
      );
    }
    final runAttemptIds = {recoveryRequest.expectedRunAttemptId};
    return _RecoverySkillProvenance(
      historicalSkillRunAttemptIds: runAttemptIds,
      historicalSkillActivation: SkillService.latestActivationReference(
        session.messages,
        runAttemptIds: runAttemptIds,
      ),
    );
  }

  LlmConfig _buildLlmConfig(ChatSession session) {
    final snapshot = _captureProviderProfileSnapshot(session);
    return _buildLlmConfigForProfileSnapshot(snapshot.activeProfile, session);
  }

  AgentService _createAgentService({
    required LlmService llm,
    required String systemPrompt,
    required AgentState state,
    required ChatSession activeSession,
    required _AgentRunToken runToken,
    SkillActivationReference? historicalSkillActivation,
  }) {
    final runAttemptId = runToken.runAttemptId;
    final imageDomain = Uri.tryParse(
      _prefs.baseUrl ?? 'https://api.openai.com',
    )?.host;
    final skillCapabilityPolicy = _skillCapabilityPolicyFactory(
      {
        'web_search': 'html.duckduckgo.com',
        if (imageDomain != null && imageDomain.isNotEmpty)
          'generate_image': imageDomain,
      },
    );
    return AgentService(
      llm: llm,
      tools: _tools,
      systemPrompt: systemPrompt,
      toolPolicy: ToolPolicy(
        onApprovalRequired: (request) => _requestToolApproval(
          state,
          request,
          runToken: runToken,
        ),
        deniedToolNames: _prefs.deniedToolNames,
        bashCommandDenyPatterns: _prefs.bashCommandDenyPatterns,
        additionalDenyCheck: skillCapabilityPolicy.denyFor,
      ),
      skillCapabilityPolicy: skillCapabilityPolicy,
      historicalSkillActivation: historicalSkillActivation ??
          runToken.skillProvenance.historicalSkillActivation,
      maxIterations: _prefs.agentMaxIterations,
      privacyMode: _prefs.privacyMode,
      supportsTools: llm.resolvedModelProfile.capabilities.supportsTools,
      envVars: _prefs.envVars,
      runtimeDebugEvents: runtimeDebugEvents,
      runtimeTraceId: runToken.traceId,
      sessionId: state.sessionId,
      runAttemptId: runAttemptId,
      onToolAttemptUpdate: (update) => _persistToolAttemptUpdate(
        activeSession,
        update,
        runToken,
      ),
    );
  }

  Future<void> _persistToolAttemptUpdate(
    ChatSession session,
    ToolAttemptUpdate update,
    _AgentRunToken runToken,
  ) async {
    if (!_storage.isSessionGenerationCurrent(
      session.id,
      runToken.storageGeneration,
    )) {
      return;
    }
    final marker = session.inFlightAgentRun;
    if (marker == null || marker.runAttemptId != update.runAttemptId) return;
    final existing = marker.toolAttempts
        .where((attempt) => attempt.operationId == update.operationId)
        .firstOrNull;
    if (existing != null &&
        !_isValidToolLifecycleTransition(existing, update)) {
      return;
    }
    final attempt = ToolAttemptRecoveryMetadata(
      operationId: update.operationId,
      toolName: _sanitizedRecoveryToolName(update.toolName),
      risk: switch (update.risk) {
        ToolRisk.safe => RecoveryToolRisk.safe,
        ToolRisk.moderate => RecoveryToolRisk.moderate,
        ToolRisk.dangerous => RecoveryToolRisk.dangerous,
      },
      lifecycle: update.lifecycle,
      proposedAt: existing?.proposedAt ?? update.timestamp,
      updatedAt: update.timestamp,
      executionStartedAt: existing?.executionStartedAt ??
          (update.lifecycle == ToolAttemptLifecycle.started
              ? update.timestamp
              : null),
      executionOutcomeKnown: update.executionOutcomeKnown ||
          (existing?.executionOutcomeKnown ?? false),
    );
    if (!_storage.isSessionGenerationCurrent(
      session.id,
      runToken.storageGeneration,
    )) {
      return;
    }
    session.inFlightAgentRun = marker.upsertToolAttempt(attempt);
    await _storage.saveSession(
      session,
      expectedGeneration: runToken.storageGeneration,
    );
    if (!_storage.isSessionGenerationCurrent(
      session.id,
      runToken.storageGeneration,
    )) {
      return;
    }
    _syncCurrentSessionReference(session);
    if (!_disposed) notifyListeners();
  }

  bool _isValidToolLifecycleTransition(
    ToolAttemptRecoveryMetadata existing,
    ToolAttemptUpdate update,
  ) {
    if (existing.lifecycle == update.lifecycle) return true;
    return switch (existing.lifecycle) {
      ToolAttemptLifecycle.proposed =>
        update.lifecycle == ToolAttemptLifecycle.approvalPending ||
            update.lifecycle == ToolAttemptLifecycle.approvedNotStarted ||
            update.lifecycle == ToolAttemptLifecycle.failed,
      ToolAttemptLifecycle.approvalPending =>
        update.lifecycle == ToolAttemptLifecycle.approvedNotStarted ||
            update.lifecycle == ToolAttemptLifecycle.failed,
      ToolAttemptLifecycle.approvedNotStarted =>
        update.lifecycle == ToolAttemptLifecycle.started ||
            update.lifecycle == ToolAttemptLifecycle.failed,
      ToolAttemptLifecycle.started =>
        update.lifecycle == ToolAttemptLifecycle.completed ||
            update.lifecycle == ToolAttemptLifecycle.failed ||
            update.lifecycle == ToolAttemptLifecycle.interruptedUnknown,
      ToolAttemptLifecycle.completed =>
        update.lifecycle == ToolAttemptLifecycle.resultPersisted ||
            update.lifecycle == ToolAttemptLifecycle.interruptedUnknown,
      ToolAttemptLifecycle.failed =>
        update.lifecycle == ToolAttemptLifecycle.resultPersisted ||
            update.lifecycle == ToolAttemptLifecycle.interruptedUnknown,
      ToolAttemptLifecycle.interruptedUnknown =>
        update.lifecycle == ToolAttemptLifecycle.failed &&
            update.executionOutcomeKnown,
      ToolAttemptLifecycle.resultPersisted => false,
    };
  }

  String _sanitizedRecoveryToolName(String toolName) {
    if (toolName.isEmpty ||
        toolName.length > 120 ||
        !RegExp(r'^[a-zA-Z0-9._:-]+$').hasMatch(toolName)) {
      return 'unknown';
    }
    return toolName;
  }

  void _recordRuntimeEvent(
      String sessionId, String type, Map<String, Object?> data,
      {String? traceId}) {
    try {
      runtimeDebugEvents.record(RuntimeDebugEvent(
        type: type,
        sessionId: sessionId,
        traceId: traceId,
        data: data,
      ));
    } catch (_) {
      // Debug events must never affect chat flow.
    }
  }

  @visibleForTesting
  void recordProviderTransformWarningsBestEffortForTesting({
    required String sessionId,
    required List<Map<String, dynamic>> messages,
    required ProviderTransformOptions options,
  }) {
    _contextManager.recordProviderTransformWarningsBestEffortForTesting(
      sessionId: sessionId,
      messages: messages,
      options: options,
    );
  }

  List<Map<String, dynamic>> _toolDefinitionsForBudget(
    LlmConfig llmConfig, {
    required ModelCapabilities capabilities,
  }) {
    if (!capabilities.supportsTools) return const [];
    final definitions = _tools.getToolDefinitions();
    if (llmConfig.format == ApiFormat.anthropic) {
      return definitions.map((tool) => tool.toAnthropicJson()).toList();
    }
    return definitions.map((tool) => tool.toOpenAIJson()).toList();
  }

  Future<Object?> _runAgentForState(
    AgentState state,
    ChatSession activeSession,
    List<Map<String, dynamic>> apiMessages, {
    required _AgentRunToken runToken,
    required bool preserveRecoveryMarker,
    required String assemblyId,
    required int attempt,
    required String modelLabel,
  }) async {
    if (!_runMayContinue(runToken)) return null;
    final attemptStopwatch = Stopwatch()..start();
    var streamStarted = false;
    var terminalRecorded = false;
    var streamResetCount = 0;
    _recordRuntimeEvent(
        activeSession.id,
        'model.attempt.started',
        {
          'attempt': attempt,
          'modelLabel': modelLabel,
        },
        traceId: runToken.traceId);
    void recordStreamStart() {
      if (streamStarted) return;
      streamStarted = true;
      _recordRuntimeEvent(
          activeSession.id,
          'stream.started',
          {
            'attempt': attempt,
            'latencyMs': attemptStopwatch.elapsedMilliseconds,
          },
          traceId: runToken.traceId);
    }

    void recordStreamTerminal({
      required String status,
      required String completeness,
      String? errorCode,
      int? inputTokens,
      int? outputTokens,
      LlmUsage? usage,
      bool? hadToolCalls,
    }) {
      if (terminalRecorded) return;
      terminalRecorded = true;
      recordStreamStart();
      _recordRuntimeEvent(
          activeSession.id,
          'stream.terminal',
          {
            'attempt': attempt,
            'status': status,
            'completeness': completeness,
            'durationMs': attemptStopwatch.elapsedMilliseconds,
            'streamResetCount': streamResetCount,
            if (errorCode != null) 'errorCode': errorCode,
            if (inputTokens != null) 'inputTokens': inputTokens,
            if (outputTokens != null) 'outputTokens': outputTokens,
            if (usage?.cacheReadInputTokens != null)
              'cacheReadInputTokens': usage!.cacheReadInputTokens,
            if (usage?.cacheCreationInputTokens != null)
              'cacheCreationInputTokens': usage!.cacheCreationInputTokens,
            if (usage != null)
              'inputTokensIncludeCache': usage.inputTokensIncludeCache,
            if (hadToolCalls != null) 'hadToolCalls': hadToolCalls,
          },
          traceId: runToken.traceId);
    }

    final completer = Completer<void>();
    state.agentCompleter = completer;
    state.agentCompletionFinalizing = false;
    state.initialApiMsgCount = apiMessages.length;
    state.fallbackGuardedOutputObserved = false;
    state.fallbackTextEmitted = false;
    state.fallbackToolStarted = false;
    state.fallbackMessagesPersisted = false;
    Object? errorCause;
    bool isCurrentRun() =>
        _runMayContinue(runToken) && identical(state.agentCompleter, completer);
    void completeRun() {
      if (!completer.isCompleted) completer.complete();
    }

    Future<void> persistAgentMessages(
      List<Map<String, dynamic>> messages,
    ) async {
      if (!isCurrentRun() || messages.length <= state.initialApiMsgCount) {
        return;
      }
      state.fallbackMessagesPersisted = true;
      _appendNewAgentMessages(
        state,
        activeSession,
        messages,
        state.initialApiMsgCount,
      );
      state.initialApiMsgCount = messages.length;
      _markPersistedToolResults(activeSession);
      _syncCurrentSessionReference(activeSession);
      await _storage.saveSession(
        activeSession,
        expectedGeneration: runToken.storageGeneration,
      );
      if (isCurrentRun() && !_disposed) notifyListeners();
    }

    final runAgent = state.agent!;
    late final StreamSubscription<AgentEvent> subscription;
    subscription = runAgent
        .runAgentLoop(
      apiMessages,
      onMessagesUpdated: persistAgentMessages,
    )
        .listen(
      (event) {
        if (!isCurrentRun()) return;
        switch (event) {
          case AgentThinking():
            state.status = AgentStatus.thinking;
            _clearStreamingState(state);
            notifyListeners();
            unawaited(_startAgentServiceForState(
              state,
              _agentServiceThinkingText,
              runToken: runToken,
            ));

          case AgentStreamReset():
            streamResetCount++;
            state.fallbackGuardedOutputObserved = false;
            recordStreamStart();
            _recordRuntimeEvent(
                activeSession.id,
                'stream.reset',
                {
                  'attempt': attempt,
                  'count': streamResetCount,
                  'completeness': 'interrupted',
                },
                traceId: runToken.traceId);
            _clearStreamingState(state, notify: false);
            state.status = AgentStatus.thinking;
            state.streamingText = _agentServiceReconnectingText;
            notifyListeners();
            unawaited(_startAgentServiceForState(
              state,
              _agentServiceReconnectingText,
              runToken: runToken,
            ));

          case AgentGuardedOutputObserved():
            // This content-free signal must never be rendered or persisted.
            // It records transport completeness only. Guarded bytes remain
            // discardable and do not make a clean provider fallback unsafe.
            recordStreamStart();
            state.fallbackGuardedOutputObserved = true;

          case AgentTextDelta(:final text):
            recordStreamStart();
            if (text.isNotEmpty) state.fallbackTextEmitted = true;
            _appendStreamingDelta(state, text, runToken: runToken);

          case AgentReasoningDelta(:final text):
            recordStreamStart();
            if (text.isNotEmpty) {
              state.fallbackTextEmitted = true;
              _appendStreamingReasoningDelta(
                state,
                text,
                runToken: runToken,
              );
            }

          case AgentToolStart(:final toolName):
            state.fallbackToolStarted = true;
            _flushStreamingNow(state);
            state.status = AgentStatus.tooling;
            notifyListeners();
            unawaited(_startAgentServiceForState(
              state,
              _agentServiceToolingText,
              runToken: runToken,
            ));
            unawaited(_updateAgentNativeStatusForState(
              state,
              'tooling',
              toolName: toolName,
              runToken: runToken,
            ));

          case AgentToolDone():
            notifyListeners();

          case AgentIterationDone(:final messages):
            _clearStreamingState(state);
            if (messages.length > state.initialApiMsgCount) {
              state.fallbackMessagesPersisted = true;
            }
            notifyListeners();

          case AgentComplete(
              :final finalText,
              :final inputTokens,
              :final outputTokens,
              :final usage,
              :final hadToolCalls,
            ):
            recordStreamTerminal(
              status: 'completed',
              completeness: 'complete',
              inputTokens: inputTokens,
              outputTokens: outputTokens,
              usage: usage,
              hadToolCalls: hadToolCalls,
            );
            _flushStreamingNow(state, notify: false);
            state.status = AgentStatus.idle;
            _clearRecoveryMarkerAfterOwnedPositiveTerminal(
              activeSession,
              runToken,
            );
            if (runAgent.messages.length > state.initialApiMsgCount) {
              state.fallbackMessagesPersisted = true;
            }
            _appendNewAgentMessages(
              state,
              activeSession,
              runAgent.messages,
              state.initialApiMsgCount,
            );
            state.initialApiMsgCount = runAgent.messages.length;
            // Store token usage on the last assistant message
            for (int i = activeSession.messages.length - 1; i >= 0; i--) {
              if (activeSession.messages[i].role == 'assistant') {
                activeSession.messages[i].inputTokens = inputTokens;
                activeSession.messages[i].outputTokens = outputTokens;
                activeSession.messages[i].cacheReadInputTokens =
                    usage?.cacheReadInputTokens;
                activeSession.messages[i].cacheCreationInputTokens =
                    usage?.cacheCreationInputTokens;
                activeSession.messages[i].inputTokensIncludeCache =
                    usage?.inputTokensIncludeCache ?? false;
                break;
              }
            }
            _contextManager.recordCompletion(
              assemblyId: assemblyId,
              usage: usage,
              hadToolCalls: hadToolCalls,
            );
            _syncCurrentSessionReference(activeSession);
            final persistCompletion = _storage
                .saveSession(
              activeSession,
              expectedGeneration: runToken.storageGeneration,
            )
                .then((_) {
              if (_runMayContinue(runToken) && !_disposed) {
                notifyListeners();
              }
            }).catchError((Object e) {
              debugPrint('Failed to persist completed agent response: $e');
            });
            state.agentCompletionFinalizing = true;
            _clearStreamingState(state);
            unawaited(_finishAgentComplete(
              state,
              finalText,
              completer,
              persistCompletion,
              runToken,
            ));

          case AgentError(:final message, :final cause):
            recordStreamTerminal(
              status: 'failed',
              completeness: streamStarted ? 'partial' : 'none',
              errorCode: _fallbackReasonFor(cause, message).code,
            );
            if (cause is EncryptedContentError) {
              _clearStreamingState(state);
            } else {
              _flushStreamingNow(state, notify: false);
              _savePartialAgentResponse(
                state,
                interruptionNote: '回复中断，内容可能不完整。',
                runToken: runToken,
              );
              if (!preserveRecoveryMarker) {
                activeSession.inFlightAgentRun = null;
              }
              _clearStreamingState(state);
            }
            errorCause = cause ?? _AgentRuntimeError(message);
            if (cause is EncryptedContentError) {
              state.status = AgentStatus.thinking;
              state.errorMessage = null;
            } else {
              state.status = AgentStatus.error;
              state.errorMessage = _sanitizeProviderErrorMessage(message);
            }
            notifyListeners();
            completeRun();
            if (cause is! EncryptedContentError) {
              unawaited(
                _stopAgentServiceForState(state, runToken: runToken),
              );
            }
        }
      },
      onError: (Object e) {
        if (!isCurrentRun()) return;
        recordStreamTerminal(
          status: 'failed',
          completeness: streamStarted ? 'partial' : 'none',
          errorCode: _fallbackReasonFor(e, null).code,
        );
        errorCause = e;
        if (e is EncryptedContentError) {
          _clearStreamingState(state);
        } else {
          _flushStreamingNow(state, notify: false);
          _savePartialAgentResponse(
            state,
            interruptionNote: '回复中断，内容可能不完整。',
            runToken: runToken,
          );
          if (!preserveRecoveryMarker) {
            activeSession.inFlightAgentRun = null;
          }
          _clearStreamingState(state);
        }
        if (e is EncryptedContentError) {
          state.status = AgentStatus.thinking;
          state.errorMessage = null;
        } else {
          state.status = AgentStatus.error;
          state.errorMessage = _sanitizeProviderErrorMessage(e);
        }
        notifyListeners();
        if (!state.agentCompletionFinalizing) {
          completeRun();
          if (e is! EncryptedContentError) {
            unawaited(
              _stopAgentServiceForState(state, runToken: runToken),
            );
          }
        }
      },
      onDone: () {
        if (!isCurrentRun()) return;
        if (!state.agentCompletionFinalizing) {
          recordStreamTerminal(
            status: state.wasCancelled ? 'cancelled' : 'interrupted',
            completeness: streamStarted ? 'partial' : 'none',
            errorCode:
                state.wasCancelled ? 'user_cancelled' : 'stream_interrupted',
          );
          completeRun();
          if (errorCause is! EncryptedContentError) {
            unawaited(
              _stopAgentServiceForState(state, runToken: runToken),
            );
          }
        }
      },
      cancelOnError: false,
    );
    if (!isCurrentRun()) {
      await subscription.cancel();
      return errorCause;
    }
    state.agentSubscription = subscription;
    await completer.future;
    if (identical(state.agentSubscription, subscription)) {
      state.agentSubscription = null;
    }
    return errorCause;
  }

  void _markPersistedToolResults(ChatSession session) {
    final marker = session.inFlightAgentRun;
    if (marker == null || marker.toolAttempts.isEmpty) return;
    final persistedOperationIds = session.messages
        .expand((message) => message.toolResults)
        .map((result) => result.metadata['operationId'])
        .whereType<String>()
        .toSet();
    if (persistedOperationIds.isEmpty) return;
    var nextMarker = marker;
    var changed = false;
    final now = DateTime.now();
    for (final attempt in marker.toolAttempts) {
      if (!persistedOperationIds.contains(attempt.operationId) ||
          attempt.lifecycle == ToolAttemptLifecycle.resultPersisted) {
        continue;
      }
      nextMarker = nextMarker.upsertToolAttempt(
        attempt.copyWith(
          lifecycle: ToolAttemptLifecycle.resultPersisted,
          updatedAt: now,
        ),
      );
      changed = true;
    }
    if (changed) session.inFlightAgentRun = nextMarker;
  }

  Future<void> _applyContextSessionPatch(
    ChatSession session,
    ContextSessionPatch patch,
  ) async {
    if (patch.isEmpty) return;
    if (patch.hasSummaryUpdate) {
      session.contextSummary = patch.nextSummary;
    }
    for (final notice in patch.notices) {
      switch (notice.type) {
        case ContextNoticeType.summaryCompacted:
          _appendContextSummaryCompactedNotice(
            session,
            notice.coveredMessageCount,
          );
        case ContextNoticeType.summaryFailed:
          _appendContextSummaryFailedNotice(session);
        case ContextNoticeType.truncated:
          _appendContextCompactionNotice(
            session,
            notice.droppedMessageCount,
            notice.droppedBlockCount,
            notice.estimatedTokens,
          );
      }
    }
    await _storage.saveSession(session);
    _syncCurrentSessionReference(session);
    notifyListeners();
  }

  Future<bool> _restoreContextSessionPatchSnapshot(
    ChatSession session,
    _ContextSessionPatchSnapshot snapshot,
    ContextSessionPatch patch,
  ) async {
    if (patch.isEmpty || session.messages.length < snapshot.messageCount) {
      return false;
    }
    session.contextSummary = snapshot.contextSummary;
    _removeContextPatchNotices(
      session.messages,
      startIndex: snapshot.messageCount,
      notices: patch.notices,
    );
    await _storage.saveSession(session);
    _syncCurrentSessionReference(session);
    notifyListeners();
    return true;
  }

  @visibleForTesting
  static int removeContextPatchNoticesForTesting(
    List<ChatMessage> messages, {
    required int startIndex,
    required List<ContextNotice> notices,
  }) {
    return _removeContextPatchNotices(
      messages,
      startIndex: startIndex,
      notices: notices,
    );
  }

  static int _removeContextPatchNotices(
    List<ChatMessage> messages, {
    required int startIndex,
    required List<ContextNotice> notices,
  }) {
    var removedNotices = 0;
    for (final notice in notices) {
      final expectedText = _contextNoticeText(notice);
      var index = startIndex;
      while (index < messages.length) {
        final message = messages[index];
        if (message.isSystemNotice && message.textContent == expectedText) {
          messages.removeAt(index);
          removedNotices++;
          break;
        }
        index++;
      }
    }
    return removedNotices;
  }

  static String _contextNoticeText(ContextNotice notice) {
    return switch (notice.type) {
      ContextNoticeType.summaryCompacted =>
        AppStrings.contextSummaryCompactedNotice(notice.coveredMessageCount),
      ContextNoticeType.summaryFailed => AppStrings.contextSummaryFailed,
      ContextNoticeType.truncated => notice.droppedMessageCount > 0
          ? AppStrings.contextCompactedNotice(
              notice.droppedMessageCount,
              notice.estimatedTokens,
            )
          : AppStrings.contextToolCallsCleanedNotice(
              notice.droppedBlockCount,
              notice.estimatedTokens,
            ),
    };
  }

  void _appendContextCompactionNotice(
    ChatSession session,
    int droppedMessageCount,
    int droppedBlockCount,
    int estimatedTokens,
  ) {
    final text = droppedMessageCount > 0
        ? AppStrings.contextCompactedNotice(
            droppedMessageCount,
            estimatedTokens,
          )
        : AppStrings.contextToolCallsCleanedNotice(
            droppedBlockCount,
            estimatedTokens,
          );
    if (session.messages.isNotEmpty) {
      final last = session.messages.last;
      if (last.isSystemNotice && last.textContent == text) return;
    }
    session.messages.add(ChatMessage.systemNotice(text));
  }

  void _appendContextSummaryCompactedNotice(
    ChatSession session,
    int coveredMessageCount,
  ) {
    final text = AppStrings.contextSummaryCompactedNotice(coveredMessageCount);
    if (session.messages.isNotEmpty) {
      final last = session.messages.last;
      if (last.isSystemNotice && last.textContent == text) return;
    }
    session.messages.add(ChatMessage.systemNotice(text));
  }

  void _appendContextSummaryFailedNotice(ChatSession session) {
    const text = AppStrings.contextSummaryFailed;
    if (session.messages.isNotEmpty) {
      final last = session.messages.last;
      if (last.isSystemNotice && last.textContent == text) return;
    }
    session.messages.add(ChatMessage.systemNotice(text));
  }

  void _appendEncryptedContentRecoveryNotice(ChatSession session) {
    const text = AppStrings.encryptedContentRecoveryNotice;
    if (session.messages.isNotEmpty) {
      final last = session.messages.last;
      if (last.isSystemNotice && last.textContent == text) return;
    }
    session.messages.add(ChatMessage.systemNotice(text));
  }

  @visibleForTesting
  String? encryptedRecoveryEmptyErrorForTesting(
    EncryptedContentError originalError,
    List<Map<String, dynamic>> recoveryMessages,
  ) {
    return _encryptedRecoveryEmptyError(originalError, recoveryMessages);
  }

  String? _encryptedRecoveryEmptyError(
    EncryptedContentError originalError,
    List<Map<String, dynamic>> recoveryMessages,
  ) {
    if (recoveryMessages.isNotEmpty) return null;
    return [
      originalError.message,
      AppStrings.encryptedContentRecoveryFailed,
    ].join('\n');
  }

  void _persistSanitizedMessages(ChatSession session) {
    final sanitizedContentByIndex = <int, List<MessageContent>>{};
    final toolUseIds = <String>{};
    final toolResultIds = <String>{};

    for (var i = 0; i < session.messages.length; i++) {
      final msg = session.messages[i];
      if (msg.isSystemNotice) continue;
      final sanitizedContent = _sanitizeMessageContentForRecovery(msg.content);
      sanitizedContentByIndex[i] = sanitizedContent;
      for (final content in sanitizedContent) {
        if (content is ToolUseContent) {
          toolUseIds.add(content.id);
        } else if (content is ToolResultContent) {
          toolResultIds.add(content.toolUseId);
        }
      }
    }

    final pairedToolIds = toolUseIds.intersection(toolResultIds);
    final retainedMessages = <ChatMessage>[];
    for (var i = 0; i < session.messages.length; i++) {
      final msg = session.messages[i];
      if (msg.isSystemNotice) {
        retainedMessages.add(msg);
        continue;
      }

      final sanitizedContent = sanitizedContentByIndex[i] ?? const [];
      final pairedContent = sanitizedContent.where((content) {
        if (content is ToolUseContent) {
          return pairedToolIds.contains(content.id);
        }
        if (content is ToolResultContent) {
          return pairedToolIds.contains(content.toolUseId);
        }
        return true;
      }).toList();
      if (pairedContent.isEmpty) continue;
      msg.content = pairedContent;
      retainedMessages.add(msg);
    }

    session.messages
      ..clear()
      ..addAll(retainedMessages);
  }

  List<MessageContent> _sanitizeMessageContentForRecovery(
    List<MessageContent> content,
  ) {
    final sanitized = <MessageContent>[];
    for (final item in content) {
      switch (item) {
        case TextContent(:final text):
          sanitized.add(TextContent(text));
        case ImageContent(
            :final data,
            :final mediaType,
            :final filename,
          ):
          sanitized.add(ImageContent(
            data: data,
            mediaType: mediaType,
            filename: filename,
          ));
        case ToolUseContent(
            :final id,
            :final name,
            :final input,
            :final output,
            :final isExecuting,
            :final isError,
          ):
          final sanitizedTool = ToolUseContent(
            id: id,
            name: name,
            input: _sanitizeRecoveryMap(input),
            output: output,
            isExecuting: isExecuting,
            isError: isError,
          );
          sanitized.add(sanitizedTool);
        case ToolResultContent(
            :final toolUseId,
            :final payload,
            :final isError,
          ):
          sanitized.add(ToolResultContent(
            toolUseId: toolUseId,
            output: payload.forUser,
            forLlm: payload.forLlm,
            summary: payload.summary,
            metadata: _sanitizeRecoveryMap(payload.metadata),
            isError: isError,
          ));
      }
    }
    return sanitized;
  }

  Map<String, dynamic> _sanitizeRecoveryMap(Map<dynamic, dynamic> value) {
    return Map<String, dynamic>.from(
      ProviderMessageTransform.removeUnsafeMetadata(value) as Map,
    );
  }

  void _appendNewAgentMessages(
    AgentState state,
    ChatSession session,
    List<Map<String, dynamic>> agentMessages,
    int initialApiMsgCount,
  ) {
    // Only append messages added by the agent during this turn.
    // Preserves all prior session.messages (including alternatives, token usage,
    // and any messages dropped by _truncateToFit).
    if (agentMessages.length <= initialApiMsgCount) return;
    final newMessages = agentMessages.sublist(initialApiMsgCount);

    for (final msg in newMessages) {
      final chatMessage = _chatMessageFromApiMessage(msg);
      if (chatMessage != null) session.messages.add(chatMessage);
    }

    // If we have pending alternatives from a regeneration, attach them to the last assistant message
    if (state.pendingAlternatives != null &&
        state.pendingAlternatives!.isNotEmpty) {
      for (int i = session.messages.length - 1; i >= 0; i--) {
        if (session.messages[i].role == 'assistant') {
          final msg = session.messages[i];
          session.messages[i] = ChatMessage(
            role: msg.role,
            content: msg.content,
            timestamp: msg.timestamp,
            inputTokens: msg.inputTokens,
            outputTokens: msg.outputTokens,
            cacheReadInputTokens: msg.cacheReadInputTokens,
            cacheCreationInputTokens: msg.cacheCreationInputTokens,
            inputTokensIncludeCache: msg.inputTokensIncludeCache,
            alternatives: state.pendingAlternatives,
            activeAlternative: -1,
          );
          break;
        }
      }
      state.pendingAlternatives = null;
    }
  }

  ChatMessage? _chatMessageFromApiMessage(Map<String, dynamic> msg) {
    final role = msg['role'] as String?;
    if (role == null) return null;
    final content = msg['content'];

    List<MessageContent> contentList;
    if (content is String) {
      contentList = [TextContent(content)];
    } else if (content is List) {
      contentList = content.map<MessageContent>((item) {
        if (item is Map<String, dynamic>) {
          switch (item['type']) {
            case 'text':
              return TextContent(
                item['text'] as String? ?? '',
                reasoningContent: item['reasoning_content'] as String?,
              );
            case 'image':
              final source = item['source'];
              final sourceMap =
                  source is Map ? source : const <String, dynamic>{};
              return ImageContent(
                data: (sourceMap['data'] ?? item['data'] ?? '') as String,
                mediaType: (sourceMap['media_type'] ??
                    item['media_type'] ??
                    'image/png') as String,
                filename: item['filename'] as String?,
              );
            case 'tool_use':
              return ToolUseContent(
                id: item['id'] as String,
                name: item['name'] as String,
                input: Map<String, dynamic>.from(item['input'] ?? {}),
              );
            case 'tool_result':
              return ToolResultContent.fromToolResultJson(item);
            default:
              return TextContent(item.toString());
          }
        }
        return TextContent(item.toString());
      }).toList();
    } else {
      return null;
    }

    return ChatMessage(role: role, content: contentList);
  }
}

class _AgentRuntimeError implements Exception {
  final String message;

  _AgentRuntimeError(Object? message)
      : message = message?.toString() ?? 'LLM request failed';

  @override
  String toString() => message;
}

class _AgentRunToken {
  final AgentState state;
  final String runAttemptId;
  final int generation;
  final int storageGeneration;
  final _RecoverySkillProvenance skillProvenance;
  final Completer<void> finished = Completer<void>();
  String? traceId;

  _AgentRunToken({
    required this.state,
    required this.runAttemptId,
    required this.generation,
    required this.storageGeneration,
    required this.skillProvenance,
  });
}

final class _SessionReplayOperation implements SessionCommitAuthority {
  _SessionReplayOperation({
    required this.owner,
    required this.sessionId,
    required this.storageGeneration,
    required this.operationGeneration,
    required this.liveSession,
    required this.sessionSnapshot,
    required this.prompt,
    required this.attachments,
    required this.pendingAlternatives,
    required this.traceTrigger,
    required this.claimed,
  });

  final ChatProvider owner;
  final String sessionId;
  final int storageGeneration;
  final int operationGeneration;
  final ChatSession liveSession;
  final ChatSession sessionSnapshot;
  final String prompt;
  final List<MessageContent> attachments;
  final List<String>? pendingAlternatives;
  final String traceTrigger;
  final bool claimed;
  bool _commitInProgress = false;

  SessionCommitGuard get commitGuard => SessionCommitGuard(
        sessionId: sessionId,
        sessionGeneration: storageGeneration,
        authorizationGeneration: generation,
        authority: this,
      );

  @override
  int get generation => operationGeneration;

  @override
  bool get isValid => owner._ownsSessionReplay(this);

  @override
  SessionCommitPermit? tryAcquireCommit() {
    if (!isValid || _commitInProgress) return null;
    _commitInProgress = true;
    return _SessionReplayCommitPermit(this);
  }
}

final class _SessionReplayCommitPermit implements SessionCommitPermit {
  const _SessionReplayCommitPermit(this.operation);

  final _SessionReplayOperation operation;

  @override
  void complete() {
    operation._commitInProgress = false;
  }
}

class _RecoverySkillProvenance {
  final Set<String> historicalSkillRunAttemptIds;
  final SkillActivationReference? historicalSkillActivation;

  _RecoverySkillProvenance({
    Set<String> historicalSkillRunAttemptIds = const <String>{},
    this.historicalSkillActivation,
  }) : historicalSkillRunAttemptIds =
            Set<String>.unmodifiable(historicalSkillRunAttemptIds);

  const _RecoverySkillProvenance.empty()
      : historicalSkillRunAttemptIds = const <String>{},
        historicalSkillActivation = null;

  RecoverySkillActivationMetadata? toRecoveryMetadata() {
    final activation = historicalSkillActivation;
    if (activation == null || historicalSkillRunAttemptIds.length != 1) {
      return null;
    }
    return RecoverySkillActivationMetadata(
      sourceRunAttemptId: historicalSkillRunAttemptIds.single,
      skillId: activation.id,
      trustDigest: activation.trustDigest,
    );
  }
}

class _RecoveryRunRequest {
  final String expectedRunAttemptId;
  final AgentRunRecoveryMarker previousMarker;
  final String prompt;

  const _RecoveryRunRequest({
    required this.expectedRunAttemptId,
    required this.previousMarker,
    required this.prompt,
  });
}

class _FallbackReason {
  final String code;
  final String label;
  final bool canFallback;
  final bool contextTooLarge;

  const _FallbackReason._({
    required this.code,
    required this.label,
    required this.canFallback,
    this.contextTooLarge = false,
  });

  const _FallbackReason.allowed(
    String code,
    String label, {
    bool contextTooLarge = false,
  }) : this._(
          code: code,
          label: label,
          canFallback: true,
          contextTooLarge: contextTooLarge,
        );

  const _FallbackReason.blocked(String code, String label)
      : this._(
          code: code,
          label: label,
          canFallback: false,
        );
}

class _ProviderProfileSnapshot {
  final String activeProfileId;
  final ProviderProfile activeProfile;
  final List<ProviderProfile> profiles;

  const _ProviderProfileSnapshot({
    required this.activeProfileId,
    required this.activeProfile,
    required this.profiles,
  });
}

class _ContextSessionPatchSnapshot {
  final ContextSummary? contextSummary;
  final int messageCount;

  const _ContextSessionPatchSnapshot({
    required this.contextSummary,
    required this.messageCount,
  });

  factory _ContextSessionPatchSnapshot.capture(ChatSession session) {
    return _ContextSessionPatchSnapshot(
      contextSummary: session.contextSummary,
      messageCount: session.messages.length,
    );
  }
}

class _ModelFallbackCandidate {
  final ProviderProfile profile;
  final LlmConfig config;

  const _ModelFallbackCandidate({
    required this.profile,
    required this.config,
  });

  String get safeLabel => _safeFallbackLabelText(config.model);
}

class _ModelFallbackOutcome {
  final bool success;
  final String? reasonCode;

  const _ModelFallbackOutcome._({
    required this.success,
    this.reasonCode,
  });

  const _ModelFallbackOutcome.success() : this._(success: true);

  const _ModelFallbackOutcome.failed(String reasonCode)
      : this._(success: false, reasonCode: reasonCode);
}

String _safeFallbackLabelText(String raw) {
  final sanitized = const LlmContentSanitizer().sanitizeText(raw).text;
  final compact = sanitized.replaceAll(RegExp(r'\s+'), ' ').trim();
  final label = compact.isEmpty ? 'unknown-model' : compact;
  const maxRunes = 80;
  final runes = label.runes.toList(growable: false);
  if (runes.length <= maxRunes) return label;
  return '${String.fromCharCodes(runes.take(maxRunes))}...';
}

enum CompareResultState { loading, complete, error, cancelled }

final class _CompareOwner {
  const _CompareOwner({
    required this.sessionId,
    required this.storageGeneration,
    required this.prompt,
    required this.compareGeneration,
    required this.sessionSnapshot,
  });

  final String sessionId;
  final int storageGeneration;
  final String prompt;
  final int compareGeneration;
  final ChatSession sessionSnapshot;

  _CompareOwner withCompareGeneration(int value) => _CompareOwner(
        sessionId: sessionId,
        storageGeneration: storageGeneration,
        prompt: prompt,
        compareGeneration: value,
        sessionSnapshot: sessionSnapshot,
      );
}

class CompareResult {
  final String model;
  final String text;
  final int? tokens;
  final int? latencyMs;
  final CompareResultState state;
  final String? errorCode;

  const CompareResult._({
    required this.model,
    required this.text,
    required this.state,
    this.tokens,
    this.latencyMs,
    this.errorCode,
  });

  const CompareResult.loading({required String model})
      : this._(model: model, text: '', state: CompareResultState.loading);

  const CompareResult.complete({
    required String model,
    required String text,
    int? tokens,
    int? latencyMs,
  }) : this._(
          model: model,
          text: text,
          state: CompareResultState.complete,
          tokens: tokens,
          latencyMs: latencyMs,
        );

  const CompareResult.error({
    required String model,
    required String errorCode,
  }) : this._(
          model: model,
          text: '',
          state: CompareResultState.error,
          errorCode: errorCode,
        );

  const CompareResult.cancelled({required String model})
      : this._(
          model: model,
          text: '',
          state: CompareResultState.cancelled,
        );

  AssistantOutcomeProvenance get provenance => AssistantOutcomeProvenance(
        model: model,
        outputTokens: tokens,
        latencyMs: latencyMs,
      );
}
