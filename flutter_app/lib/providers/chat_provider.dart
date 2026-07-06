import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
export '../models/agent_state.dart' show AgentStatus, QueuedMessage;

import '../constants.dart';
import '../models/agent_state.dart';
import '../models/chat_models.dart';
import '../models/model_capabilities.dart';
import '../models/provider_profile.dart';
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
import '../services/session_storage.dart';
import '../services/startup_restore_guard.dart';
import '../services/tools/tool_policy.dart';
import '../services/tools/tool_registry.dart';
import '../services/tool_call_expansion_state.dart';
import '../services/preferences_service.dart';
import '../services/skill_service.dart';
import '../services/memory_service.dart';
import '../l10n/app_strings.dart';

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
  late final ToolRegistry _tools;
  final _uuid = const Uuid();

  final PreferencesService _prefs = PreferencesService();
  bool _prefsInitialized = false;
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

  int _messageVersion = 0;
  int get messageVersion => _messageVersion;
  final Map<String, String> _drafts = {};
  final Map<String, AgentState> _agentStates = {};
  final Set<String> _manualContextSummarySessions = {};
  String? _fallbackErrorMessage;
  ToolApprovalRequest? pendingApproval;
  AgentState? _pendingApprovalState;
  Completer<bool>? _approvalCompleter;
  bool _appInBackground = false;

  static const _agentServiceThinkingText = 'AI 正在思考...';
  static const _agentServiceToolingText = 'AI 正在执行命令...';
  static const _agentServiceStreamingText = 'AI 正在回复...';
  static const _liveReasoningPreviewMaxChars = 12000;
  static const _liveReasoningPreviewTrimAt = 14000;

  AgentState _getOrCreateState(String sessionId) {
    return _agentStates.putIfAbsent(sessionId, () => AgentState(sessionId));
  }

  AgentState? _getState(String? sessionId) {
    return sessionId != null ? _agentStates[sessionId] : null;
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

  Future<void> _startAgentServiceForState(AgentState state, String text) async {
    if (_disposed) return;
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
      await _updateAgentNativeStatusForState(
        state,
        _statusForAgentServiceText(text),
      );
    } catch (e) {
      if (generation == state.agentServiceGeneration) {
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
  }) async {
    if (_disposed) return;
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

  Future<void> _stopAgentServiceForState(AgentState state) async {
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
  ) async {
    try {
      await _updateAgentNativeStatusForState(
        state,
        'complete',
        previewText: finalText,
      );
      await _showCompletionNotificationIfNeeded(state, finalText);
      if (_appInBackground) {
        await Future.delayed(const Duration(seconds: 2));
      }
    } finally {
      await _stopAgentServiceForState(state);
      if (completer != null && !completer.isCompleted) {
        completer.complete();
      }
      state.agentCompletionFinalizing = false;
      Future.microtask(() => _cleanupIdleState(state.sessionId));
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

  void _appendStreamingDelta(AgentState state, String text) {
    state.status = AgentStatus.streaming;
    state.streamBuffer.write(text);
    state.streamFlushScheduler.schedule(
      delta: text,
      flush: () {
        _flushStreamingState(state);
        unawaited(_startAgentServiceForState(
          state,
          _agentServiceStreamingText,
        ));
      },
    );
  }

  void _appendStreamingReasoningDelta(AgentState state, String text) {
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
  })  : _storage = storage ?? SessionStorage(),
        _llmServiceFactory = llmServiceFactory ?? LlmService.new,
        runtimeDebugEvents = runtimeDebugEvents ?? RuntimeDebugEventService(),
        _startupRestoreGuard = startupRestoreGuard ?? StartupRestoreGuard(),
        _diagnosticsExportService =
            diagnosticsExportService ?? const DiagnosticsExportService(),
        _attachmentBudget = attachmentBudget ?? const AttachmentBudget() {
    _contextManager = ContextManager(
      contextSummaryServiceFactory:
          contextSummaryServiceFactory ?? ContextSummaryService.new,
      providerTransformPreflight: providerTransformPreflight ??
          const ProviderMessageTransform().transformCanonical,
      runtimeDebugEvents: this.runtimeDebugEvents,
    );
    NativeBridge.setAgentStopRequestedHandler(
      ({String? sessionId}) => cancelAgent(sessionId: sessionId),
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
    NativeBridge.setAgentStopRequestedHandler(null);
    NativeBridge.setNavigateToSessionHandler(null);
    unawaited(_stopAgentService());
    unawaited(_tools.dispose());
    _completePendingApproval(false);
    for (final state in _agentStates.values) {
      state.dispose();
    }
    _agentStates.clear();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      await _prefs.init();
      await _tools.refreshMcpTools();
      await _contextManager.init();
      _prefsInitialized = true;
      await _storage.init();
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
      await _contextManager.init();
      _prefsInitialized = true;
    }
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
      currentSession = await _storage.getSession(id);
      if (currentSession != null) {
        _restorePersistedAssistantErrorState(currentSession!);
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
    final state = _agentStates[id];
    if (state != null && state.isSending) {
      cancelAgent(sessionId: id, savePartial: false);
    }
    _agentStates.remove(id)?.dispose();
    await _storage.deleteSession(id);
    sessions.removeWhere((s) => s.id == id);
    if (currentSession?.id == id) {
      currentSession = null;
      _clearSessionScopedState();
      if (sessions.isNotEmpty) {
        currentSession = await _storage.getSession(sessions.first.id);
      }
    }
    notifyListeners();
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
        cancelAgent(sessionId: id, savePartial: false);
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
    ToolApprovalRequest request,
  ) async {
    if (_disposed) return false;
    await _ensurePrefs();
    if (_disposed) return false;

    final policy = _prefs.toolApprovalPolicy;
    final isCurrentSession = state.sessionId == currentSession?.id;
    final userPresent = isCurrentSession && !_appInBackground;
    if (!userPresent) return false;

    if (policy == PreferencesService.toolApprovalAuto) return true;
    if (policy == PreferencesService.toolApprovalSessionFirst &&
        state.sessionApprovedTools.contains(request.toolName)) {
      return true;
    }

    _completePendingApproval(false, notify: false);
    final completer = Completer<bool>();
    _approvalCompleter = completer;
    _pendingApprovalState = state;
    pendingApproval = request;
    notifyListeners();
    final approved = await completer.future;
    if (approved &&
        policy == PreferencesService.toolApprovalSessionFirst &&
        !_disposed) {
      state.sessionApprovedTools.add(request.toolName);
    }
    return approved;
  }

  void resolveToolApproval(bool approved, {bool rememberForSession = false}) {
    final request = pendingApproval;
    if (approved && request != null) {
      _rememberToolApproval(
        _pendingApprovalState,
        request.toolName,
        explicitSessionApproval: rememberForSession,
      );
    }
    _completePendingApproval(approved);
  }

  void setAppInBackground(bool inBackground) {
    if (_appInBackground == inBackground) return;
    _appInBackground = inBackground;
    if (!_appInBackground) {
      unawaited(NativeBridge.setAgentOverlayVisible(false));
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
    }
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
    if (state == null) return;
    final policy = _prefsInitialized
        ? _prefs.toolApprovalPolicy
        : PreferencesService.defaultToolApprovalPolicy;
    if (policy == PreferencesService.toolApprovalAlways) return;
    if (explicitSessionApproval ||
        policy == PreferencesService.toolApprovalSessionFirst) {
      state.sessionApprovedTools.add(toolName);
    }
  }

  void _completePendingApproval(bool approved, {bool notify = true}) {
    pendingApproval = null;
    _pendingApprovalState = null;
    final completer = _approvalCompleter;
    _approvalCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(approved);
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
  }) async {
    final trimmedText = text.trim();
    final pendingAlternativesForSend = pendingAlternatives == null
        ? null
        : List<String>.from(pendingAlternatives);

    if (trimmedText.isEmpty && attachments.isEmpty) return;

    AgentState? activeState;
    try {
      await _ensurePrefs();
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
      if (targetSessionId != null) {
        session = currentSession?.id == targetSessionId
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

      AgentState? sessionState =
          session != null ? _getOrCreateState(session.id) : null;
      if (sessionState != null && sessionState.isSending) {
        _enqueueMessage(sessionState, trimmedText, attachments);
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
      }

      final activeSession = session;
      final state = sessionState!;
      activeState = state;
      state.pendingAlternatives = null;
      state.isSending = true;
      state.wasCancelled = false;
      state.pendingAlternatives = pendingAlternativesForSend;
      activeSession.messages.add(ChatMessage.userContent([
        if (trimmedText.isNotEmpty) TextContent(trimmedText),
        ...attachments,
      ]));
      activeSession.autoTitle();
      state.sessionTitle = activeSession.title;
      await _storage.saveSession(activeSession);
      _syncCurrentSessionReference(activeSession);
      notifyListeners();

      final llmConfig = _buildLlmConfigFromSnapshot(
        providerSnapshot,
        activeSession,
      );
      if (state.cachedLlm == null || state.cachedLlmConfig != llmConfig) {
        state.cachedLlm?.dispose();
        state.cachedLlm = _llmServiceFactory(
          llmConfig,
          isInBackground: () => _appInBackground,
        );
        state.cachedLlmConfig = llmConfig;
      }
      final llm = state.cachedLlm!;

      // Refresh skills (and memory) to pick up any user toggle changes
      _skills = await SkillService.scanSkills();
      await MemoryService.getMemories();
      await _tools.refreshMcpTools();

      final basePrompt = activeSession.systemPrompt ??
          _prefs.systemPrompt ??
          AppConstants.defaultSystemPrompt;
      final skillIndex = SkillService.buildSkillIndex(_skills);
      final memoryPrompt = MemoryService.buildMemoryPrompt();
      final fullPrompt = basePrompt + skillIndex + memoryPrompt;

      state.status = AgentStatus.thinking;
      state.streamingText = '';
      state.errorMessage = null;
      notifyListeners();
      unawaited(_startAgentServiceForState(
        state,
        _agentServiceThinkingText,
      ));

      final fullApiMessages = activeSession.toApiMessages();
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
            state.status = AgentStatus.thinking;
            notifyListeners();
            unawaited(_startAgentServiceForState(
              state,
              AppStrings.contextSummaryGenerating,
            ));
          },
        ),
      );
      final primaryPatchSnapshot =
          _ContextSessionPatchSnapshot.capture(activeSession);
      var primaryPatchRolledBack = false;
      var preservingPrimaryPatchForRecovery = false;
      Future<void> rollbackPrimaryPatchIfSafe() async {
        if (primaryPatchRolledBack) return;
        primaryPatchRolledBack = await _restoreContextSessionPatchSnapshot(
          activeSession,
          primaryPatchSnapshot,
          assembly.patch,
        );
      }

      await _applyContextSessionPatch(activeSession, assembly.patch);
      final promptWithSummary = assembly.systemPrompt;
      final apiMessages = assembly.messages;
      final initialApiMsgCount = assembly.initialApiMsgCount;
      state.initialApiMsgCount = initialApiMsgCount;
      state.partialAgentResponseSaved = false;
      state.agent = _createAgentService(
        llm: llm,
        systemPrompt: promptWithSummary,
        state: state,
      );
      try {
        var runResult = await _runAgentForState(
          state,
          activeSession,
          apiMessages,
          assemblyId: assembly.assemblyId,
        );
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
            );
            state.status = AgentStatus.error;
            state.errorMessage = emptyRecoveryError;
            await _persistAssistantFailureMarker(
              state: state,
              session: activeSession,
              error: originalError,
              source: 'encrypted_recovery_empty',
            );
            notifyListeners();
          } else {
            state.agent = _createAgentService(
              llm: llm,
              systemPrompt: promptWithSummary,
              state: state,
            );
            state.status = AgentStatus.thinking;
            state.streamingText = '';
            state.errorMessage = null;
            state.partialAgentResponseSaved = false;
            notifyListeners();
            unawaited(_startAgentServiceForState(
              state,
              _agentServiceThinkingText,
            ));

            runResult = await _runAgentForState(
              state,
              activeSession,
              recoveryMessages,
              assemblyId: recoveryAssembly.assemblyId,
            );
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
              );
              _persistSanitizedMessages(activeSession);
              _appendEncryptedContentRecoveryNotice(activeSession);
              await _storage.saveSession(activeSession);
              _syncCurrentSessionReference(activeSession);
              notifyListeners();
            }
          }
        } else if (state.wasCancelled) {
          if (!preservingPrimaryPatchForRecovery) {
            await rollbackPrimaryPatchIfSafe();
          }
        } else if (runResult != null || state.status == AgentStatus.error) {
          if (!preservingPrimaryPatchForRecovery) {
            await rollbackPrimaryPatchIfSafe();
          }
          final fallbackOutcome = await _tryRunModelFallback(
            state: state,
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
          if (!fallbackOutcome.success && !state.wasCancelled) {
            await _persistAssistantFailureMarker(
              state: state,
              session: activeSession,
              error: runResult ?? _AgentRuntimeError(state.errorMessage),
              source: 'provider_failure',
              fallbackReasonCode: fallbackOutcome.reasonCode,
            );
          }
        }
      } catch (e) {
        await rollbackPrimaryPatchIfSafe();
        state.status = AgentStatus.error;
        state.errorMessage = _sanitizeProviderErrorMessage(e);
        await _persistAssistantFailureMarker(
          state: state,
          session: activeSession,
          error: e,
          source: 'provider_exception',
        );
        notifyListeners();
      } finally {
        _contextManager.discardCompletion(assembly.assemblyId);
        state.agentSubscription = null;
        state.agentCompleter = null;
        state.partialAgentResponseSaved = false;
        state.initialApiMsgCount = 0;
        unawaited(_stopAgentServiceForState(state));
      }
    } finally {
      final state = activeState;
      if (state != null) {
        state.pendingAlternatives = null;
        state.isSending = false;
        notifyListeners();
        _drainMessageQueue(state);
      }
    }
  }

  void cancelAgent({String? sessionId, bool savePartial = true}) {
    final id = sessionId ?? currentSession?.id;
    if (id == null) return;
    final state = _agentStates[id];
    if (state == null || !state.isSending) return;

    state.wasCancelled = true;
    state.messageQueueDrainTimer?.cancel();
    state.messageQueueDrainTimer = null;
    state.agent?.cancel();
    state.cachedLlm?.dispose();
    state.cachedLlm = null;
    state.cachedLlmConfig = null;
    unawaited(_stopAgentServiceForState(state));
    if (identical(_pendingApprovalState, state)) {
      _completePendingApproval(false);
    }
    state.agentSubscription?.cancel();
    state.agentSubscription = null;
    if (savePartial) {
      _flushStreamingNow(state, notify: false);
      _savePartialAgentResponse(state);
    }
    _clearStreamingState(state);
    if (state.agentCompleter != null && !state.agentCompleter!.isCompleted) {
      state.agentCompleter!.complete();
    }
    state.isSending = false;
    state.status = AgentStatus.idle;
    notifyListeners();
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
      state.wasCancelled = false;
      _cleanupIdleState(state.sessionId);
      return;
    }
    final next = state.messageQueue.first;
    notifyListeners();
    state.messageQueueDrainTimer?.cancel();
    state.messageQueueDrainTimer = Timer(const Duration(seconds: 1), () {
      state.messageQueueDrainTimer = null;
      if (!_disposed && !state.wasCancelled) {
        final activeCount = _activeAgentStates.length;
        if (activeCount >= maxConcurrentAgents) {
          notifyListeners();
          return;
        }
        if (state.messageQueue.isEmpty ||
            state.messageQueue.first.id != next.id) {
          if (state.messageQueue.isEmpty) {
            _cleanupIdleState(state.sessionId);
          }
          return;
        }
        state.messageQueue.removeAt(0);
        notifyListeners();
        sendMessage(
          next.text,
          attachments: next.attachments,
          targetSessionId: state.sessionId,
        );
      }
    });
  }

  void removeQueuedMessage(String id) {
    final state = _getState(currentSession?.id);
    if (state == null) return;
    state.messageQueue.removeWhere((m) => m.id == id);
    if (state.messageQueue.isEmpty) {
      state.messageQueueDrainTimer?.cancel();
      state.messageQueueDrainTimer = null;
    }
    _cleanupIdleState(state.sessionId);
    notifyListeners();
  }

  void clearMessageQueue() {
    final state = _getState(currentSession?.id);
    if (state == null) return;
    state.messageQueue.clear();
    state.messageQueueDrainTimer?.cancel();
    state.messageQueueDrainTimer = null;
    state.wasCancelled = false;
    _cleanupIdleState(state.sessionId);
    notifyListeners();
  }

  void sendNextQueued() {
    final id = currentSession?.id;
    if (id == null) return;
    final state = _getState(id);
    if (state == null || state.isSending || state.messageQueue.isEmpty) return;
    state.messageQueueDrainTimer?.cancel();
    state.messageQueueDrainTimer = null;
    state.wasCancelled = false;
    final next = state.messageQueue.removeAt(0);
    notifyListeners();
    sendMessage(next.text, attachments: next.attachments, targetSessionId: id);
  }

  void _savePartialAgentResponse(AgentState state) {
    if (state.partialAgentResponseSaved || state.agentCompletionFinalizing) {
      return;
    }
    final agent = state.agent;
    if (agent == null) return;

    final partialText = state.streamBuffer.toString();
    state.partialAgentResponseSaved = true;
    final session =
        currentSession?.id == state.sessionId ? currentSession : null;
    if (session != null) {
      _savePartialAgentResponseToSession(state, session, agent, partialText);
      return;
    }

    unawaited(_storage.getSession(state.sessionId).then((session) {
      if (session == null) return;
      _savePartialAgentResponseToSession(state, session, agent, partialText);
    }).catchError((Object e) {
      debugPrint('Failed to load session for partial agent response: $e');
    }));
  }

  void _savePartialAgentResponseToSession(
    AgentState state,
    ChatSession session,
    AgentService agent,
    String partialText,
  ) {
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
      session.messages.add(ChatMessage(
        role: 'assistant',
        content: [TextContent(partialText)],
        alternatives: state.pendingAlternatives,
        activeAlternative: -1,
      ));
      state.pendingAlternatives = null;
    }

    _syncCurrentSessionReference(session);
    unawaited(_storage.saveSession(session).catchError((Object e) {
      debugPrint('Failed to save partial agent response: $e');
    }));
  }

  Future<void> regenerateLastResponse() async {
    final id = currentSession?.id;
    final state = _getState(id);
    if (state != null && state.messageQueue.isNotEmpty) {
      state.errorMessage = AppStrings.clearQueueBeforeRegenerate;
      notifyListeners();
      return;
    }
    if (currentSession == null || (state?.isSending ?? false)) return;
    final messages = currentSession!.messages;

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

    await _storage.saveSession(currentSession!);
    notifyListeners();

    await sendMessage(
      lastUserText,
      attachments: retryAttachments,
      pendingAlternatives: pendingAlternatives,
    );
  }

  Future<AssistantRetryStatus> retryAssistantMessage(int messageIndex) async {
    final session = currentSession;
    if (session == null ||
        messageIndex < 0 ||
        messageIndex >= session.messages.length) {
      return AssistantRetryStatus.invalidMessage;
    }

    final state = _getState(session.id);
    if ((state?.isSending ?? false) ||
        (state?.messageQueue.isNotEmpty ?? false)) {
      return AssistantRetryStatus.busy;
    }

    final failedMessage = session.messages[messageIndex];
    final error = failedMessage.assistantError;
    if (error == null || !error.canRetry) {
      return AssistantRetryStatus.notRetryable;
    }

    final lastContentIndex = _lastNonSystemMessageIndex(session.messages);
    if (lastContentIndex != messageIndex) {
      return AssistantRetryStatus.notRetryable;
    }

    final userIndex = _retryUserMessageIndexBefore(session, messageIndex);
    if (userIndex == null) return AssistantRetryStatus.invalidMessage;

    await _ensurePrefs();
    if (_prefs.activeProfile.apiKey.trim().isEmpty) {
      return AssistantRetryStatus.missingApiKey;
    }
    final activeCount = _activeAgentStates.length;
    if (activeCount >= maxConcurrentAgents) {
      return AssistantRetryStatus.busy;
    }

    final userMessage =
        ChatMessage.fromJson(session.messages[userIndex].toJson());
    final retryText = userMessage.textContent.trim();
    final retryAttachments = _retryableAttachmentsFor(userMessage);
    if (retryText.isEmpty && retryAttachments.isEmpty) {
      return AssistantRetryStatus.invalidMessage;
    }

    session.messages.removeRange(userIndex, session.messages.length);
    session.updatedAt = DateTime.now();
    final retryState = _getOrCreateState(session.id);
    retryState.status = AgentStatus.idle;
    retryState.errorMessage = null;
    retryState.wasCancelled = false;
    await _storage.saveSession(session);
    _syncCurrentSessionReference(session);
    notifyListeners();

    await sendMessage(retryText, attachments: retryAttachments);
    return AssistantRetryStatus.started;
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
  bool _isComparing = false;
  bool get isComparing => _isComparing;

  Future<void> sendCompare(String text, List<String> models) async {
    if (currentSession == null) await createSession();
    final currentState = _getState(currentSession?.id);
    if ((currentState?.isSending ?? false) || _isComparing) {
      errorMessage =
          (currentState?.isSending ?? false) ? '当前会话正在发送中' : '正在对比中，请等待完成';
      notifyListeners();
      return;
    }
    final compareModels =
        models.where((model) => model.trim().isNotEmpty).toList();
    if (text.trim().isEmpty || compareModels.length < 2) {
      errorMessage = text.trim().isEmpty ? '请输入对比内容' : '请选择至少两个模型';
      notifyListeners();
      return;
    }
    final comparePrompt = text.trim();

    _isComparing = true;
    compareResults = [];
    errorMessage = null;
    notifyListeners();

    try {
      await _ensurePrefs();
      final apiKey = _prefs.apiKey;
      if (apiKey == null || apiKey.isEmpty) {
        errorMessage = AppStrings.apiKeyNotConfigured;
        compareResults!.add(CompareResult(
          model: 'Error',
          text: AppStrings.apiKeyNotConfigured,
        ));
        return;
      }

      _skills = await SkillService.scanSkills();
      await MemoryService.getMemories();
      final skillIndex = SkillService.buildSkillIndex(_skills);
      final memoryPrompt = MemoryService.buildMemoryPrompt();

      final session = currentSession!;
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
      final compareSystemPrompt = assembly.systemPrompt;
      final compareMessages = assembly.messages;
      notifyListeners();

      for (final model in compareModels) {
        if (_disposed) break;
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
          try {
            final response = await llm.chat(
              system: compareSystemPrompt,
              messages: compareMessages,
              tools: [],
            );
            final responseText = response.content
                .where((b) => b.type == 'text')
                .map((b) => b.text ?? '')
                .join();
            compareResults!.add(CompareResult(
              model: model,
              text: responseText,
              tokens: response.outputTokens,
            ));
          } finally {
            llm.dispose();
          }
        } catch (e) {
          compareResults!.add(CompareResult(model: model, text: 'Error: $e'));
        }
        notifyListeners();
      }
    } catch (e) {
      errorMessage = '对比失败: $e';
      compareResults ??= [];
      compareResults!.add(CompareResult(model: 'Error', text: '$e'));
    } finally {
      if (compareResults != null && compareResults!.isEmpty) {
        compareResults!.add(CompareResult(
          model: 'Error',
          text: '对比失败：没有生成任何结果',
        ));
      }
      _isComparing = false;
      notifyListeners();
    }
  }

  void clearCompareResults() {
    compareResults = null;
    notifyListeners();
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
        'errorType': e.runtimeType.toString(),
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
  }) async {
    if (state.wasCancelled) return;
    final sanitizedMessage = _sanitizeProviderErrorMessage(
      state.errorMessage ?? error,
    );
    final reason = _fallbackReasonFor(error, sanitizedMessage);
    final metadata = AssistantErrorMetadata(
      message: sanitizedMessage,
      code: reason.code,
      canRetry: _canRetryAssistantFailure(state, reason),
      source: source,
      fallbackReasonCode: fallbackReasonCode,
      fallbackReasonLabel: fallbackReasonCode == null ? null : reason.label,
    );

    _removeTrailingAssistantErrorMarkers(session);
    session.messages.add(ChatMessage.assistantError(error: metadata));
    session.updatedAt = DateTime.now();
    await _storage.saveSession(session);
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
    final reason = _fallbackReasonFor(primaryError, state.errorMessage);
    if (!_isFallbackSafeForState(state)) {
      _recordModelFallbackEvent(activeSession.id, 'model.fallback.skipped', {
        'reason': 'unsafe_after_partial_run',
        'primaryReason': reason.code,
      });
      return const _ModelFallbackOutcome.failed('unsafe_after_partial_run');
    }
    if (!reason.canFallback) {
      _recordModelFallbackEvent(activeSession.id, 'model.fallback.skipped', {
        'reason': reason.code,
      });
      return _ModelFallbackOutcome.failed(reason.code);
    }

    final candidates = _resolveModelFallbackCandidates(
      primaryConfig,
      providerSnapshot,
    );
    if (candidates.isEmpty) {
      _recordModelFallbackEvent(activeSession.id, 'model.fallback.skipped', {
        'reason': 'no_configured_candidate',
        'primaryReason': reason.code,
      });
      return const _ModelFallbackOutcome.failed('no_configured_candidate');
    }

    var attemptIndex = 0;
    var lastFailureReason = reason.code;
    for (final candidate in candidates) {
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
        _recordModelFallbackEvent(activeSession.id, 'model.fallback.skipped', {
          'reason': skipReason,
          'candidate': candidate.safeLabel,
          'attemptIndex': attemptIndex,
        });
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
              state.status = AgentStatus.thinking;
              notifyListeners();
              unawaited(_startAgentServiceForState(
                state,
                AppStrings.contextSummaryGenerating,
              ));
            },
          ),
        );

        state.cachedLlm?.dispose();
        state.cachedLlm = llm;
        state.cachedLlmConfig = candidate.config;
        state.agent = _createAgentService(
          llm: llm,
          systemPrompt: assembly.systemPrompt,
          state: state,
        );
        state.status = AgentStatus.thinking;
        state.streamingText = '';
        state.errorMessage = null;
        state.partialAgentResponseSaved = false;
        notifyListeners();
        unawaited(_startAgentServiceForState(
          state,
          _agentServiceThinkingText,
        ));

        _recordModelFallbackEvent(activeSession.id, 'model.fallback.attempt', {
          'primary': _safeModelLabel(primaryConfig),
          'candidate': candidate.safeLabel,
          'reason': reason.code,
          'attemptIndex': attemptIndex,
        });

        runResult = await _runAgentForState(
          state,
          activeSession,
          assembly.messages,
          assemblyId: assembly.assemblyId,
        );
      } catch (e) {
        runResult = e;
        state.status = AgentStatus.error;
        state.errorMessage = _sanitizeProviderErrorMessage(e);
        notifyListeners();
      } finally {
        if (assembly != null) {
          _contextManager.discardCompletion(assembly.assemblyId);
        }
      }

      final failed = state.wasCancelled ||
          runResult != null ||
          state.status == AgentStatus.error;
      if (!failed) {
        if (assembly != null) {
          await _applyContextSessionPatch(activeSession, assembly.patch);
        }
        _appendModelFallbackNotice(
          activeSession,
          primary: _safeModelLabel(primaryConfig),
          fallback: candidate.safeLabel,
          reason: reason.label,
        );
        await _storage.saveSession(activeSession);
        _syncCurrentSessionReference(activeSession);
        _recordModelFallbackEvent(activeSession.id, 'model.fallback.success', {
          'primary': _safeModelLabel(primaryConfig),
          'fallback': candidate.safeLabel,
          'reason': reason.code,
          'attemptIndex': attemptIndex,
        });
        notifyListeners();
        return const _ModelFallbackOutcome.success();
      }

      final candidateReason = _fallbackReasonFor(runResult, state.errorMessage);
      lastFailureReason = candidateReason.code;
      _recordModelFallbackEvent(activeSession.id, 'model.fallback.failed', {
        'candidate': candidate.safeLabel,
        'reason': candidateReason.code,
        'attemptIndex': attemptIndex,
      });

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
    String sessionId,
    String type,
    Map<String, Object?> data,
  ) {
    _recordRuntimeEvent(sessionId, type, data);
  }

  String _safeModelLabel(LlmConfig config) {
    return '${config.format.name}/${_safeFallbackLabelText(config.model)}';
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

  LlmConfig _buildLlmConfig(ChatSession session) {
    final snapshot = _captureProviderProfileSnapshot(session);
    return _buildLlmConfigForProfileSnapshot(snapshot.activeProfile, session);
  }

  AgentService _createAgentService({
    required LlmService llm,
    required String systemPrompt,
    required AgentState state,
  }) {
    return AgentService(
      llm: llm,
      tools: _tools,
      systemPrompt: systemPrompt,
      toolPolicy: ToolPolicy(
        onApprovalRequired: (request) => _requestToolApproval(
          state,
          request,
        ),
        deniedToolNames: _prefs.deniedToolNames,
        bashCommandDenyPatterns: _prefs.bashCommandDenyPatterns,
      ),
      maxIterations: _prefs.agentMaxIterations,
      privacyMode: _prefs.privacyMode,
      supportsTools: llm.resolvedModelProfile.capabilities.supportsTools,
      envVars: _prefs.envVars,
      runtimeDebugEvents: runtimeDebugEvents,
      sessionId: state.sessionId,
    );
  }

  void _recordRuntimeEvent(
    String sessionId,
    String type,
    Map<String, Object?> data,
  ) {
    try {
      runtimeDebugEvents.record(RuntimeDebugEvent(
        type: type,
        sessionId: sessionId,
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
    required String assemblyId,
  }) async {
    final completer = Completer<void>();
    state.agentCompleter = completer;
    state.agentCompletionFinalizing = false;
    state.initialApiMsgCount = apiMessages.length;
    state.fallbackTextEmitted = false;
    state.fallbackToolStarted = false;
    state.fallbackMessagesPersisted = false;
    Object? errorCause;
    bool isCurrentRun() => identical(state.agentCompleter, completer);
    void completeRun() {
      if (!completer.isCompleted) completer.complete();
    }

    late final StreamSubscription<AgentEvent> subscription;
    subscription = state.agent!.runAgentLoop(apiMessages).listen(
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
            ));

          case AgentTextDelta(:final text):
            if (text.isNotEmpty) state.fallbackTextEmitted = true;
            _appendStreamingDelta(state, text);

          case AgentReasoningDelta(:final text):
            if (text.isNotEmpty) {
              _appendStreamingReasoningDelta(state, text);
            }

          case AgentToolStart(:final toolName):
            state.fallbackToolStarted = true;
            _flushStreamingNow(state);
            state.status = AgentStatus.tooling;
            notifyListeners();
            unawaited(_startAgentServiceForState(
              state,
              _agentServiceToolingText,
            ));
            unawaited(_updateAgentNativeStatusForState(
              state,
              'tooling',
              toolName: toolName,
            ));

          case AgentToolDone():
            notifyListeners();

          case AgentIterationDone(:final messages):
            _clearStreamingState(state);
            if (messages.length > state.initialApiMsgCount) {
              state.fallbackMessagesPersisted = true;
            }
            _appendNewAgentMessages(
              state,
              activeSession,
              messages,
              state.initialApiMsgCount,
            );
            state.initialApiMsgCount = messages.length;
            _syncCurrentSessionReference(activeSession);
            unawaited(_storage.saveSession(activeSession).then((_) {
              if (!_disposed) notifyListeners();
            }));
            notifyListeners();

          case AgentComplete(
              :final finalText,
              :final inputTokens,
              :final outputTokens,
              :final usage,
              :final hadToolCalls,
            ):
            _flushStreamingNow(state, notify: false);
            state.status = AgentStatus.idle;
            if (state.agent!.messages.length > state.initialApiMsgCount) {
              state.fallbackMessagesPersisted = true;
            }
            _appendNewAgentMessages(
              state,
              activeSession,
              state.agent!.messages,
              state.initialApiMsgCount,
            );
            state.initialApiMsgCount = state.agent!.messages.length;
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
            _storage.saveSession(activeSession).then((_) {
              if (!_disposed) notifyListeners();
            });
            state.agentCompletionFinalizing = true;
            _clearStreamingState(state);
            unawaited(_finishAgentComplete(state, finalText, completer));

          case AgentError(:final message, :final cause):
            _clearStreamingState(state);
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
              unawaited(_stopAgentServiceForState(state));
            }
        }
      },
      onError: (Object e) {
        if (!isCurrentRun()) return;
        errorCause = e;
        _clearStreamingState(state);
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
            unawaited(_stopAgentServiceForState(state));
          }
        }
      },
      onDone: () {
        if (!isCurrentRun()) return;
        if (!state.agentCompletionFinalizing) {
          completeRun();
          if (errorCause is! EncryptedContentError) {
            unawaited(_stopAgentServiceForState(state));
          }
        }
      },
      cancelOnError: false,
    );
    state.agentSubscription = subscription;
    await completer.future;
    if (identical(state.agentSubscription, subscription)) {
      state.agentSubscription = null;
    }
    return errorCause;
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
    final trailing = session.messages.skip(snapshot.messageCount);
    if (!trailing.every((message) => message.isSystemNotice)) {
      return false;
    }
    session.contextSummary = snapshot.contextSummary;
    if (session.messages.length > snapshot.messageCount) {
      session.messages.removeRange(
        snapshot.messageCount,
        session.messages.length,
      );
    }
    await _storage.saveSession(session);
    _syncCurrentSessionReference(session);
    notifyListeners();
    return true;
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

class CompareResult {
  final String model;
  final String text;
  final int? tokens;
  CompareResult({required this.model, required this.text, this.tokens});
}
