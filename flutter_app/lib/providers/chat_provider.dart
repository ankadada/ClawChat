import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
export '../models/agent_state.dart' show AgentStatus, QueuedMessage;

import '../constants.dart';
import '../models/agent_state.dart';
import '../models/chat_models.dart';
import '../models/provider_profile.dart';
import '../services/agent_service.dart';
import '../services/chat_context_utils.dart';
import '../services/context_summary_service.dart';
import '../services/llm_service.dart';
import '../services/native_bridge.dart';
import '../services/provider_message_transform.dart';
import '../services/session_storage.dart';
import '../services/tools/tool_policy.dart';
import '../services/tools/tool_registry.dart';
import '../services/tool_call_expansion_state.dart';
import '../services/token_calibration_service.dart';
import '../services/preferences_service.dart';
import '../services/skill_service.dart';
import '../services/memory_service.dart';
import '../l10n/app_strings.dart';

typedef LlmServiceFactory = LlmService Function(
  LlmConfig config, {
  bool Function()? isInBackground,
});

typedef ContextSummaryServiceFactory = ContextSummaryService Function();

class _PendingTokenCalibration {
  final String key;
  final int estimatedInputTokens;
  final int rawEstimatedInputTokens;
  final int estimatedImageTokens;
  final int rawEstimatedImageTokens;
  final int estimatedToolTokens;
  final int rawEstimatedToolTokens;
  final int largestBlockTokens;
  final int rawLargestBlockTokens;

  const _PendingTokenCalibration({
    required this.key,
    required this.estimatedInputTokens,
    required this.rawEstimatedInputTokens,
    required this.estimatedImageTokens,
    required this.rawEstimatedImageTokens,
    required this.estimatedToolTokens,
    required this.rawEstimatedToolTokens,
    required this.largestBlockTokens,
    required this.rawLargestBlockTokens,
  });

  TokenCalibrationSample toSample(LlmUsage? usage) {
    return TokenCalibrationSample(
      key: key,
      estimatedInputTokens: estimatedInputTokens,
      rawEstimatedInputTokens: rawEstimatedInputTokens,
      actualInputTokens: usage?.inputTokens,
      estimatedImageTokens: estimatedImageTokens,
      rawEstimatedImageTokens: rawEstimatedImageTokens,
      estimatedToolTokens: estimatedToolTokens,
      rawEstimatedToolTokens: rawEstimatedToolTokens,
      largestBlockTokens: largestBlockTokens,
      rawLargestBlockTokens: rawLargestBlockTokens,
      cacheReadTokens: usage?.cacheReadInputTokens,
      cacheCreationTokens: usage?.cacheCreationInputTokens,
    );
  }
}

class _SummaryContextResult {
  final String systemPrompt;
  final List<Map<String, dynamic>> messages;
  final bool summaryGenerated;
  final bool summaryFailed;
  final int coveredMessageCount;

  const _SummaryContextResult({
    required this.systemPrompt,
    required this.messages,
    this.summaryGenerated = false,
    this.summaryFailed = false,
    this.coveredMessageCount = 0,
  });
}

class ChatProvider extends ChangeNotifier {
  static const int maxQueuedMessages = 3;

  List<SessionSummary> sessions = [];
  ChatSession? currentSession;

  final SessionStorage _storage;
  final LlmServiceFactory _llmServiceFactory;
  final ContextSummaryServiceFactory _contextSummaryServiceFactory;
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

  int _messageVersion = 0;
  int get messageVersion => _messageVersion;
  final Map<String, String> _drafts = {};
  final Map<String, AgentState> _agentStates = {};
  String? _fallbackErrorMessage;
  ToolApprovalRequest? pendingApproval;
  AgentState? _pendingApprovalState;
  Completer<bool>? _approvalCompleter;
  Timer? _approvalTimeout;
  bool _appInBackground = false;
  final TokenCalibrationService _tokenCalibration = TokenCalibrationService();
  final Map<String, _PendingTokenCalibration> _pendingTokenCalibration = {};

  static const _backgroundApprovalTimeout = Duration(seconds: 15);
  static const _agentServiceThinkingText = 'AI 正在思考...';
  static const _agentServiceToolingText = 'AI 正在执行命令...';
  static const _agentServiceStreamingText = 'AI 正在回复...';

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
    ToolRegistry? toolRegistry,
  })  : _storage = storage ?? SessionStorage(),
        _llmServiceFactory = llmServiceFactory ?? LlmService.new,
        _contextSummaryServiceFactory =
            contextSummaryServiceFactory ?? ContextSummaryService.new {
    NativeBridge.setAgentStopRequestedHandler(
      ({String? sessionId}) => cancelAgent(sessionId: sessionId),
    );
    NativeBridge.setNavigateToSessionHandler((sessionId) {
      unawaited(selectSession(sessionId));
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
      await _tokenCalibration.init();
      _prefsInitialized = true;
      await _storage.init();
      sessions = await _storage.getSessionsSummary();
      notifyListeners();
      await loadSkills();
      MemoryService.getMemories();
    } catch (e) {
      debugPrint('ChatProvider init failed: $e');
      // Initialize with empty state rather than silently failing
      sessions = [];
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
      await _tokenCalibration.init();
      _prefsInitialized = true;
    }
  }

  Future<ChatSession> createSession() async {
    final session = ChatSession(id: _uuid.v4());
    await _storage.saveSession(session);
    sessions.insert(
        0,
        SessionSummary(
          id: session.id,
          title: session.title,
          createdAt: session.createdAt,
          updatedAt: session.updatedAt,
        ));
    currentSession = session;
    _clearSessionScopedState();
    notifyListeners();
    return session;
  }

  Future<void> selectSession(String id) async {
    if (currentSession?.id != id) {
      _clearSessionScopedState();
    }
    currentSession = await _storage.getSession(id);
    notifyListeners();
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
    if (policy == PreferencesService.toolApprovalAuto) return true;
    if (policy == PreferencesService.toolApprovalSessionFirst &&
        state.sessionApprovedTools.contains(request.toolName)) {
      return true;
    }
    if (state.sessionId != currentSession?.id) {
      await Future.delayed(_backgroundApprovalTimeout);
      return !_disposed;
    }

    _completePendingApproval(false, notify: false);
    final completer = Completer<bool>();
    _approvalCompleter = completer;
    _pendingApprovalState = state;
    pendingApproval = request;
    if (_appInBackground) {
      _startBackgroundApprovalTimeout(request);
    }
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
      _cancelApprovalTimeout();
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

  void _startBackgroundApprovalTimeout(ToolApprovalRequest request) {
    _approvalTimeout?.cancel();
    _approvalTimeout = Timer(_backgroundApprovalTimeout, () {
      if (_disposed || !identical(pendingApproval, request)) return;
      _rememberToolApproval(_pendingApprovalState, request.toolName);
      unawaited(
        NativeBridge.showToolAutoApprovedNotification(request.toolName)
            .catchError((Object e) {
          debugPrint('Tool auto-approval notification failed: $e');
          return false;
        }),
      );
      _completePendingApproval(true);
    });
  }

  void _cancelApprovalTimeout() {
    _approvalTimeout?.cancel();
    _approvalTimeout = null;
  }

  void _completePendingApproval(bool approved, {bool notify = true}) {
    _cancelApprovalTimeout();
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
    final session = await _storage.getSession(sessionId);
    if (session == null) return;
    session.folder = folder;
    await _storage.saveSession(session);
    final idx = sessions.indexWhere((s) => s.id == sessionId);
    if (idx >= 0) {
      sessions[idx] = SessionSummary(
        id: session.id,
        title: session.title,
        createdAt: session.createdAt,
        updatedAt: session.updatedAt,
        folder: folder,
      );
    }
    if (currentSession?.id == sessionId) {
      currentSession!.folder = folder;
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

      final apiKey = _prefs.apiKey;
      if (apiKey == null || apiKey.isEmpty) {
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

      final llmConfig = _buildLlmConfig(_prefs, activeSession);
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
      final toolDefinitions = _toolDefinitionsForBudget(llmConfig);
      final estimator = _tokenEstimatorFor(llmConfig);
      final tokenBudget = _resolveContextTokenBudget(
        llmConfig: llmConfig,
        systemPrompt: fullPrompt,
        estimator: estimator,
        toolDefinitions: toolDefinitions,
      );
      final summaryResult = await _prepareSummaryContext(
        session: activeSession,
        fullApiMessages: fullApiMessages,
        llmConfig: llmConfig,
        systemPrompt: fullPrompt,
        tokenBudget: tokenBudget,
        estimator: estimator,
        state: state,
      );
      if (summaryResult.summaryGenerated) {
        _appendContextSummaryCompactedNotice(
          activeSession,
          summaryResult.coveredMessageCount,
        );
        await _storage.saveSession(activeSession);
        _syncCurrentSessionReference(activeSession);
        notifyListeners();
      } else if (summaryResult.summaryFailed) {
        _appendContextSummaryFailedNotice(activeSession);
        await _storage.saveSession(activeSession);
        _syncCurrentSessionReference(activeSession);
        notifyListeners();
      }
      final promptWithSummary = summaryResult.systemPrompt;
      final finalTokenBudget = _resolveContextTokenBudget(
        llmConfig: llmConfig,
        systemPrompt: promptWithSummary,
        estimator: estimator,
        toolDefinitions: toolDefinitions,
      );
      final truncation = _truncateToFit(
        summaryResult.messages,
        maxTokens: finalTokenBudget,
        estimator: estimator,
        preserveLastMessages: 2,
      );
      final apiMessages = truncation.messages;
      if (truncation.wasTruncated) {
        _appendContextCompactionNotice(
          activeSession,
          truncation.droppedMessageCount,
          truncation.droppedBlockCount,
          truncation.estimatedTokens,
        );
        await _storage.saveSession(activeSession);
        _syncCurrentSessionReference(activeSession);
        notifyListeners();
      }
      final initialApiMsgCount = apiMessages.length;
      state.initialApiMsgCount = initialApiMsgCount;
      state.partialAgentResponseSaved = false;
      state.agent = _createAgentService(
        llm: llm,
        systemPrompt: promptWithSummary,
        state: state,
      );
      _pendingTokenCalibration[state.sessionId] = _buildPendingTokenCalibration(
        llmConfig: llmConfig,
        estimator: estimator,
        messages: apiMessages,
        systemPrompt: promptWithSummary,
        toolDefinitions: toolDefinitions,
      );
      try {
        var runResult = await _runAgentForState(
          state,
          activeSession,
          apiMessages,
        );
        if (runResult is EncryptedContentError) {
          final originalError = runResult;
          _pendingTokenCalibration.remove(state.sessionId);
          final recoveryTransform = const ProviderMessageTransform()
              .transformCanonical(
                apiMessages,
                ProviderTransformOptions(
                  apiFormat: llmConfig.format == ApiFormat.anthropic
                      ? 'anthropic'
                      : 'openai',
                  modelId: LlmService.modelIdFromDisplay(llmConfig.model),
                  baseUrl: Uri.tryParse(llmConfig.baseUrl),
                  mode: ProviderTransformMode.recovery,
                  supportsImages: true,
                  supportsReasoningContent: false,
                ),
              )
              .messages;
          final recoveryTruncation = _truncateToFit(
            recoveryTransform,
            maxTokens: finalTokenBudget,
            estimator: estimator,
            preserveLastMessages: 2,
          );
          final recoveryMessages = recoveryTruncation.messages;
          final emptyRecoveryError = _encryptedRecoveryEmptyError(
            originalError,
            recoveryMessages,
          );
          if (emptyRecoveryError != null) {
            state.status = AgentStatus.error;
            state.errorMessage = emptyRecoveryError;
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
            );
            if (runResult != null || state.status == AgentStatus.error) {
              final recoveryError = runResult is EncryptedContentError
                  ? 'sanitized retry also failed: ${runResult.message}'
                  : state.errorMessage;
              state.status = AgentStatus.error;
              state.errorMessage = [
                originalError.message,
                AppStrings.encryptedContentRecoveryFailed,
                if (recoveryError?.isNotEmpty == true) recoveryError!,
              ].join('\n');
              notifyListeners();
            } else {
              _persistSanitizedMessages(activeSession);
              _appendEncryptedContentRecoveryNotice(activeSession);
              await _storage.saveSession(activeSession);
              _syncCurrentSessionReference(activeSession);
              notifyListeners();
            }
          }
        }
      } catch (e) {
        state.status = AgentStatus.error;
        state.errorMessage = '$e';
        notifyListeners();
      } finally {
        _pendingTokenCalibration.remove(state.sessionId);
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
    state.agent?.cancel();
    unawaited(_stopAgentServiceForState(state));
    if (identical(_pendingApprovalState, state)) {
      _completePendingApproval(false);
    }
    state.agentSubscription?.cancel();
    state.agentSubscription = null;
    state.streamThrottle?.cancel();
    state.streamThrottle = null;
    if (savePartial) {
      _savePartialAgentResponse(state);
    }
    state.streamBuffer = StringBuffer();
    if (state.agentCompleter != null && !state.agentCompleter!.isCompleted) {
      state.agentCompleter!.complete();
    }
    state.status = AgentStatus.idle;
    state.streamingText = '';
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
    Future.delayed(const Duration(seconds: 1), () {
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
    _cleanupIdleState(state.sessionId);
    notifyListeners();
  }

  void clearMessageQueue() {
    final state = _getState(currentSession?.id);
    if (state == null) return;
    state.messageQueue.clear();
    state.wasCancelled = false;
    _cleanupIdleState(state.sessionId);
    notifyListeners();
  }

  void sendNextQueued() {
    final id = currentSession?.id;
    if (id == null) return;
    final state = _getState(id);
    if (state == null || state.isSending || state.messageQueue.isEmpty) return;
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

    // Find the last user message text
    String? lastUserText;
    for (int i = messages.length - 1; i >= 0; i--) {
      if (messages[i].role == 'user' && messages[i].textContent.isNotEmpty) {
        lastUserText = messages[i].textContent;
        break;
      }
    }
    if (lastUserText == null) return;

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

    await sendMessage(lastUserText, pendingAlternatives: pendingAlternatives);
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
      alternatives: msg.alternatives,
      activeAlternative: activeAlternative,
      isSystemNotice: msg.isSystemNotice,
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
    debugPrint(
      '[COMPARE] sendCompare entered. models=$models, text="${text.substring(0, math.min(20, text.length))}"',
    );
    debugPrint(
      '[COMPARE] Guards: currentSending=${currentState?.isSending ?? false}, _isComparing=$_isComparing, session=${currentSession != null}',
    );
    if ((currentState?.isSending ?? false) || _isComparing) {
      errorMessage =
          (currentState?.isSending ?? false) ? '当前会话正在发送中' : '正在对比中，请等待完成';
      notifyListeners();
      return;
    }
    final compareModels =
        models.where((model) => model.trim().isNotEmpty).toList();
    debugPrint(
      '[COMPARE] compareModels=$compareModels, count=${compareModels.length}',
    );
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
      debugPrint(
        '[COMPARE] apiKey present: ${apiKey != null && apiKey.isNotEmpty}',
      );
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
      const compareEstimator = TokenEstimator();
      const compareToolDefinitions = <Map<String, dynamic>>[];
      final compareBudgetConfig = LlmConfig(
        format: format,
        apiKey: apiKey,
        model: compareModels.first,
        baseUrl: baseUrl,
        maxTokens: _prefs.maxTokens ?? AppConstants.defaultMaxTokens,
        thinkingBudget: _prefs.thinkingBudget,
        temperature: _prefs.temperature,
      );
      final baseCompareMessages = [
        ...session.toApiMessages(),
        {'role': 'user', 'content': comparePrompt},
      ];
      final baseCompareBudget = _resolveContextTokenBudget(
        llmConfig: compareBudgetConfig,
        systemPrompt: fullPrompt,
        estimator: compareEstimator,
        toolDefinitions: compareToolDefinitions,
      );
      final comparePlan = ChatContextUtils.planCompaction(
        baseCompareMessages,
        maxTokens: baseCompareBudget,
        estimator: compareEstimator,
      );
      final compareSummary = _summaryForCompare(
        session.contextSummary,
        baseCompareMessages,
        comparePlan,
      );
      final compareSystemPrompt =
          _systemPromptWithSummary(fullPrompt, compareSummary);
      final comparePayloadMessages = compareSummary == null
          ? baseCompareMessages
          : baseCompareMessages.sublist(compareSummary.coveredMessageCount);
      // Don't persist the user message to session.messages in compare mode.
      // Compare is a one-shot inspection — results live in compareResults only.
      // If we persisted, the next real sendMessage would break role alternation
      // (two consecutive user messages without an assistant reply between them).
      final compareMessages = _truncateToFit(
        comparePayloadMessages,
        maxTokens: _resolveContextTokenBudget(
          llmConfig: compareBudgetConfig,
          systemPrompt: compareSystemPrompt,
          estimator: compareEstimator,
          toolDefinitions: compareToolDefinitions,
        ),
        estimator: compareEstimator,
      ).messages;
      notifyListeners();

      debugPrint(
        '[COMPARE] Starting model loop for ${compareModels.length} models',
      );
      for (final model in compareModels) {
        if (_disposed) break;
        try {
          debugPrint('[COMPARE] Calling model: $model');
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
            debugPrint('[COMPARE] Model $model completed');
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

  LlmConfig _buildLlmConfig(PreferencesService prefs, ChatSession session) {
    final formatStr =
        session.apiFormatOverride ?? prefs.apiFormat ?? 'anthropic';
    final format =
        formatStr == 'openai' ? ApiFormat.openai : ApiFormat.anthropic;

    return LlmConfig(
      format: format,
      apiKey: prefs.apiKey!,
      model: session.modelOverride ?? prefs.model ?? AppConstants.defaultModel,
      baseUrl: session.baseUrlOverride ??
          prefs.baseUrl ??
          (format == ApiFormat.anthropic
              ? 'https://api.anthropic.com'
              : 'https://api.openai.com'),
      maxTokens: prefs.maxTokens ?? AppConstants.defaultMaxTokens,
      thinkingBudget: prefs.thinkingBudget,
      temperature: prefs.temperature,
    );
  }

  ContextTruncationResult _truncateToFit(
    List<Map<String, dynamic>> messages, {
    required int maxTokens,
    required TokenEstimator estimator,
    int preserveLastMessages = 2,
  }) {
    return ChatContextUtils.truncateToFit(
      messages,
      maxTokens: maxTokens,
      estimator: estimator,
      autoCompact: _prefs.autoCompact,
      preserveLastMessages: preserveLastMessages,
    );
  }

  int _resolveContextTokenBudget({
    required LlmConfig llmConfig,
    required String systemPrompt,
    required TokenEstimator estimator,
    required List<Map<String, dynamic>> toolDefinitions,
  }) {
    final systemTokens = estimator.estimateText(systemPrompt);
    final toolDefinitionTokens =
        estimator.estimateToolDefinitions(toolDefinitions);
    final configuredOutputReserve = llmConfig.maxTokens +
        (llmConfig.thinkingBudget > 0 ? llmConfig.thinkingBudget : 0);
    final maxOutputReserve = (_prefs.contextTokenBudget * 0.5).floor();
    final outputReserve = math.min(configuredOutputReserve, maxOutputReserve);
    const safetyMargin = 1024;
    final budget = _prefs.contextTokenBudget -
        systemTokens -
        toolDefinitionTokens -
        outputReserve -
        safetyMargin;
    if (budget <= 0) {
      debugPrint(
        'Context token budget exhausted: context=${_prefs.contextTokenBudget}, '
        'system=$systemTokens, tools=$toolDefinitionTokens, '
        'outputReserve=$outputReserve, '
        'safetyMargin=$safetyMargin.',
      );
      return 0;
    }
    return budget;
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
      ),
      maxIterations: _prefs.agentMaxIterations,
      privacyMode: _prefs.privacyMode,
      envVars: _prefs.envVars,
    );
  }

  Future<_SummaryContextResult> _prepareSummaryContext({
    required ChatSession session,
    required List<Map<String, dynamic>> fullApiMessages,
    required LlmConfig llmConfig,
    required String systemPrompt,
    required int tokenBudget,
    required TokenEstimator estimator,
    required AgentState state,
  }) async {
    if (!_prefs.autoCompact ||
        fullApiMessages.isEmpty ||
        estimator.estimateMessages(fullApiMessages) <= tokenBudget) {
      return _SummaryContextResult(
        systemPrompt: systemPrompt,
        messages: fullApiMessages,
      );
    }

    final plan = ChatContextUtils.planCompaction(
      fullApiMessages,
      maxTokens: tokenBudget,
      estimator: estimator,
    );
    if (!plan.needsSummary || plan.headForSummary.isEmpty) {
      return _SummaryContextResult(
        systemPrompt: systemPrompt,
        messages: fullApiMessages,
      );
    }

    var summary = _validatedSummaryForPrefix(
      session.contextSummary,
      fullApiMessages,
    );
    var generated = false;
    var failed = false;
    if (!_canReuseSummary(summary, plan, fullApiMessages)) {
      state.status = AgentStatus.thinking;
      notifyListeners();
      unawaited(_startAgentServiceForState(
        state,
        AppStrings.contextSummaryGenerating,
      ));
      final request = ContextSummaryRequest(
        messages: _messagesForSummaryGeneration(
          fullApiMessages,
          plan,
          summary,
        ),
        existingSummary: summary,
        llmConfig: llmConfig,
        summaryBudget: plan.summaryBudget,
        coveredDigest: plan.headDigest,
        coveredMessageCount: plan.headForSummary.length,
        sourceEstimatedTokens: plan.headEstimatedTokens,
        estimator: estimator,
        maxInputTokens: (_prefs.contextTokenBudget * 0.8).floor(),
      );
      final service = _contextSummaryServiceFactory();
      try {
        summary = await service.generateSummary(request);
        generated = true;
      } catch (e) {
        debugPrint('Context summary generation failed: $e');
        failed = true;
        try {
          summary = service.extractiveFallback(request);
        } catch (fallbackError) {
          debugPrint(
              'Context summary extractive fallback failed: $fallbackError');
          return _SummaryContextResult(
            systemPrompt: systemPrompt,
            messages: fullApiMessages,
            summaryFailed: true,
          );
        }
      }
      session.contextSummary = summary;
    }

    final promptWithSummary = _systemPromptWithSummary(systemPrompt, summary);
    final summaryTokens = estimator.estimateText(promptWithSummary) -
        estimator.estimateText(systemPrompt);
    final finalTailBudget = math.max(0, tokenBudget - summaryTokens);
    final tailTruncation = _truncateToFit(
      plan.recentTail,
      maxTokens: finalTailBudget,
      estimator: estimator,
      preserveLastMessages: 2,
    );
    return _SummaryContextResult(
      systemPrompt: promptWithSummary,
      messages: tailTruncation.messages,
      summaryGenerated: generated,
      summaryFailed: failed,
      coveredMessageCount: summary?.coveredMessageCount ?? 0,
    );
  }

  bool _canReuseSummary(
    ContextSummary? summary,
    ContextCompactionPlan plan,
    List<Map<String, dynamic>> fullMessages,
  ) {
    final currentSummary = _validatedSummaryForPrefix(summary, fullMessages);
    return currentSummary != null &&
        currentSummary.coveredDigest == plan.headDigest &&
        currentSummary.coveredMessageCount == plan.headForSummary.length;
  }

  ContextSummary? _summaryForCompare(
    ContextSummary? summary,
    List<Map<String, dynamic>> fullMessages,
    ContextCompactionPlan plan,
  ) {
    final currentSummary = _validatedSummaryForPrefix(summary, fullMessages);
    if (currentSummary == null || !plan.needsSummary) return null;
    if (currentSummary.coveredMessageCount > plan.headForSummary.length) {
      return null;
    }
    return currentSummary;
  }

  ContextSummary? _validatedSummaryForPrefix(
    ContextSummary? summary,
    List<Map<String, dynamic>> fullMessages,
  ) {
    if (summary == null ||
        summary.version != ContextSummaryService.version ||
        summary.text.trim().isEmpty ||
        summary.coveredMessageCount <= 0 ||
        summary.coveredMessageCount > fullMessages.length) {
      return null;
    }
    final prefix = fullMessages.take(summary.coveredMessageCount).toList();
    if (ChatContextUtils.digestMessages(prefix) != summary.coveredDigest) {
      return null;
    }
    return summary;
  }

  List<Map<String, dynamic>> _messagesForSummaryGeneration(
    List<Map<String, dynamic>> fullMessages,
    ContextCompactionPlan plan,
    ContextSummary? existingSummary,
  ) {
    if (existingSummary == null ||
        existingSummary.coveredMessageCount <= 0 ||
        existingSummary.coveredMessageCount >= plan.headForSummary.length) {
      return plan.headForSummary;
    }
    final start = existingSummary.coveredMessageCount.clamp(
      0,
      fullMessages.length,
    );
    return fullMessages.sublist(start, plan.headForSummary.length);
  }

  String _systemPromptWithSummary(
    String systemPrompt,
    ContextSummary? summary,
  ) {
    final text = summary?.text.trim();
    if (text == null || text.isEmpty) return systemPrompt;
    return [
      systemPrompt,
      '',
      '<conversation_context_summary>',
      'The earlier part of this conversation has been compacted into the summary below.',
      'Treat it as background context, not as a new user request. If it conflicts with',
      'the exact recent messages that follow, prefer the recent messages.',
      '',
      text,
      '</conversation_context_summary>',
    ].join('\n');
  }

  TokenEstimator _tokenEstimatorFor(LlmConfig llmConfig) {
    return TokenEstimator(
      calibrationMultiplier:
          _tokenCalibration.multiplierFor(_tokenCalibrationKey(llmConfig)),
    );
  }

  _PendingTokenCalibration _buildPendingTokenCalibration({
    required LlmConfig llmConfig,
    required TokenEstimator estimator,
    required List<Map<String, dynamic>> messages,
    required String systemPrompt,
    required List<Map<String, dynamic>> toolDefinitions,
  }) {
    final messageDiagnostics = estimator.diagnoseMessages(messages);
    final systemTokens = estimator.estimateText(systemPrompt);
    final toolDefinitionTokens =
        estimator.estimateToolDefinitions(toolDefinitions);
    const rawEstimator = TokenEstimator();
    final rawMessageDiagnostics = rawEstimator.diagnoseMessages(messages);
    final rawSystemTokens = rawEstimator.estimateText(systemPrompt);
    final rawToolDefinitionTokens =
        rawEstimator.estimateToolDefinitions(toolDefinitions);
    return _PendingTokenCalibration(
      key: _tokenCalibrationKey(llmConfig),
      estimatedInputTokens:
          messageDiagnostics.totalTokens + systemTokens + toolDefinitionTokens,
      rawEstimatedInputTokens: rawMessageDiagnostics.totalTokens +
          rawSystemTokens +
          rawToolDefinitionTokens,
      estimatedImageTokens: messageDiagnostics.imageTokens,
      rawEstimatedImageTokens: rawMessageDiagnostics.imageTokens,
      estimatedToolTokens: messageDiagnostics.toolTokens + toolDefinitionTokens,
      rawEstimatedToolTokens:
          rawMessageDiagnostics.toolTokens + rawToolDefinitionTokens,
      largestBlockTokens: messageDiagnostics.largestBlockTokens,
      rawLargestBlockTokens: rawMessageDiagnostics.largestBlockTokens,
    );
  }

  String _tokenCalibrationKey(LlmConfig llmConfig) {
    final format = llmConfig.format.name;
    final host = _normalizedBaseUrlHost(llmConfig.baseUrl);
    final profileId = _prefs.activeProfileId;
    final modelId = LlmService.modelIdFromDisplay(llmConfig.model);
    return '$format|$host|$profileId|$modelId';
  }

  String _normalizedBaseUrlHost(String baseUrl) {
    final trimmed = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(trimmed);
    final host = uri?.host;
    if (host != null && host.isNotEmpty) return host.toLowerCase();
    return trimmed.toLowerCase();
  }

  List<Map<String, dynamic>> _toolDefinitionsForBudget(LlmConfig llmConfig) {
    final definitions = _tools.getToolDefinitions();
    if (llmConfig.format == ApiFormat.anthropic) {
      return definitions.map((tool) => tool.toAnthropicJson()).toList();
    }
    return definitions.map((tool) => tool.toOpenAIJson()).toList();
  }

  Future<Object?> _runAgentForState(
    AgentState state,
    ChatSession activeSession,
    List<Map<String, dynamic>> apiMessages,
  ) async {
    final completer = Completer<void>();
    state.agentCompleter = completer;
    state.agentCompletionFinalizing = false;
    state.initialApiMsgCount = apiMessages.length;
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
            state.streamBuffer = StringBuffer();
            notifyListeners();
            unawaited(_startAgentServiceForState(
              state,
              _agentServiceThinkingText,
            ));

          case AgentTextDelta(:final text):
            state.status = AgentStatus.streaming;
            state.streamBuffer.write(text);
            state.streamThrottle ??=
                Timer(const Duration(milliseconds: 50), () {
              state.streamingText = state.streamBuffer.toString();
              state.streamThrottle = null;
              notifyListeners();
              unawaited(_startAgentServiceForState(
                state,
                _agentServiceStreamingText,
              ));
            });

          case AgentToolStart(:final toolName):
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
            state.streamThrottle?.cancel();
            state.streamThrottle = null;
            state.streamingText = '';
            state.streamBuffer = StringBuffer();
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
            state.streamThrottle?.cancel();
            state.streamThrottle = null;
            state.streamingText = state.streamBuffer.toString();
            state.streamBuffer = StringBuffer();
            state.status = AgentStatus.idle;
            state.streamingText = '';
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
                break;
              }
            }
            final pendingCalibration =
                _pendingTokenCalibration.remove(state.sessionId);
            if (pendingCalibration != null && !hadToolCalls) {
              _tokenCalibration.recordSample(
                pendingCalibration.toSample(usage),
              );
            }
            _syncCurrentSessionReference(activeSession);
            _storage.saveSession(activeSession).then((_) {
              if (!_disposed) notifyListeners();
            });
            state.agentCompletionFinalizing = true;
            unawaited(_finishAgentComplete(state, finalText, completer));

          case AgentError(:final message, :final cause):
            state.streamThrottle?.cancel();
            state.streamThrottle = null;
            state.streamBuffer = StringBuffer();
            errorCause = cause;
            if (cause is EncryptedContentError) {
              state.status = AgentStatus.thinking;
              state.errorMessage = null;
            } else {
              state.status = AgentStatus.error;
              state.errorMessage = message;
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
        state.streamThrottle?.cancel();
        state.streamThrottle = null;
        if (e is EncryptedContentError) {
          state.status = AgentStatus.thinking;
          state.errorMessage = null;
        } else {
          state.status = AgentStatus.error;
          state.errorMessage = '$e';
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
            :final output,
            :final isError,
          ):
          sanitized.add(ToolResultContent(
            toolUseId: toolUseId,
            output: output,
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
              final rawContent = item['content'];
              final String output;
              if (rawContent is String) {
                output = rawContent;
              } else if (rawContent is List) {
                output = rawContent.map((e) => e.toString()).join('\n');
              } else {
                output = rawContent?.toString() ?? '';
              }
              return ToolResultContent(
                toolUseId: item['tool_use_id'] as String,
                output: output,
                isError: item['is_error'] as bool? ?? false,
              );
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

class CompareResult {
  final String model;
  final String text;
  final int? tokens;
  CompareResult({required this.model, required this.text, this.tokens});
}
