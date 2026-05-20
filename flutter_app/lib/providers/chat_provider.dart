import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../constants.dart';
import '../models/chat_models.dart';
import '../models/provider_profile.dart';
import '../services/agent_service.dart';
import '../services/chat_context_utils.dart';
import '../services/llm_service.dart';
import '../services/native_bridge.dart';
import '../services/session_storage.dart';
import '../services/tools/tool_policy.dart';
import '../services/tools/tool_registry.dart';
import '../services/tool_call_expansion_state.dart';
import '../services/preferences_service.dart';
import '../services/skill_service.dart';
import '../services/memory_service.dart';
import '../l10n/app_strings.dart';

enum AgentStatus {
  idle,
  thinking,
  streaming,
  tooling,
  error,
}

class ChatProvider extends ChangeNotifier {
  List<SessionSummary> sessions = [];
  ChatSession? currentSession;
  AgentStatus agentStatus = AgentStatus.idle;
  String? errorMessage;
  String streamingText = '';

  final SessionStorage _storage = SessionStorage();
  late final ToolRegistry _tools;
  AgentService? _agent;
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

  List<SkillInfo> _skills = [];
  LlmService? _cachedLlm;
  LlmConfig? _cachedLlmConfig;
  bool _isSending = false;
  StreamSubscription<AgentEvent>? _agentSubscription;
  Completer<void>? _agentCompleter;
  Timer? _streamThrottle;
  StringBuffer _streamBuffer = StringBuffer();

  bool _disposed = false;

  final Map<String, String> _drafts = {};
  final Set<String> _sessionApprovedTools = {};
  ToolApprovalRequest? pendingApproval;
  Completer<bool>? _approvalCompleter;
  Timer? _approvalTimeout;
  bool _appInBackground = false;
  bool _agentServiceActive = false;
  String? _agentServiceText;
  int _agentServiceGeneration = 0;
  bool _agentCompletionFinalizing = false;

  static const _backgroundApprovalTimeout = Duration(seconds: 15);
  static const _agentServiceThinkingText = 'AI 正在思考...';
  static const _agentServiceToolingText = 'AI 正在执行命令...';
  static const _agentServiceStreamingText = 'AI 正在生成回复...';

  String getDraft(String sessionId) => _drafts[sessionId] ?? '';

  void _clearSessionScopedState() {
    _sessionApprovedTools.clear();
    ToolCallExpansionState.clear();
  }

  Future<void> _startAgentService(String text) async {
    if (_disposed) return;
    if (_agentServiceActive && _agentServiceText == text) return;
    final generation = ++_agentServiceGeneration;
    _agentServiceActive = true;
    _agentServiceText = text;
    try {
      await NativeBridge.startAgentService(text: text);
    } catch (e) {
      if (generation == _agentServiceGeneration) {
        _agentServiceActive = false;
        _agentServiceText = null;
      }
      debugPrint('Failed to start agent foreground service: $e');
    }
  }

  Future<void> _stopAgentService() async {
    _agentServiceGeneration++;
    final shouldStop = _agentServiceActive || _agentServiceText != null;
    _agentServiceActive = false;
    _agentServiceText = null;
    if (!shouldStop) return;
    try {
      await NativeBridge.stopAgentService();
    } catch (e) {
      debugPrint('Failed to stop agent foreground service: $e');
    }
  }

  String _completionNotificationPreview(String text) {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return String.fromCharCodes(normalized.runes.take(50));
  }

  Future<void> _showCompletionNotificationIfNeeded(String finalText) async {
    if (!_appInBackground || !_prefs.notifyOnComplete) return;
    try {
      await NativeBridge.showAgentCompleteNotification(
        _completionNotificationPreview(finalText),
      );
    } catch (e) {
      debugPrint('Failed to show agent completion notification: $e');
    }
  }

  Future<void> _finishAgentComplete(
    String finalText,
    Completer<void>? completer,
  ) async {
    try {
      await _showCompletionNotificationIfNeeded(finalText);
    } finally {
      await _stopAgentService();
      if (completer != null && !completer.isCompleted) {
        completer.complete();
      }
      _agentCompletionFinalizing = false;
    }
  }

  void saveDraft(String sessionId, String text) {
    if (text.isEmpty) {
      _drafts.remove(sessionId);
    } else {
      _drafts[sessionId] = text;
    }
  }

  ChatProvider() {
    _tools = ToolRegistry.withDefaults(prefs: _prefs);
    _init();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_stopAgentService());
    _completePendingApproval(false);
    _streamThrottle?.cancel();
    _agentSubscription?.cancel();
    if (_agentCompleter != null && !_agentCompleter!.isCompleted) {
      _agentCompleter!.completeError(StateError('Provider disposed'));
    }
    _cachedLlm?.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      await _prefs.init();
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
    notifyListeners();
  }

  Future<void> clearAllSessions() async {
    await _storage.clearAll();
    sessions.clear();
    currentSession = null;
    _clearSessionScopedState();
    notifyListeners();
  }

  Future<bool> _requestToolApproval(ToolApprovalRequest request) async {
    if (_disposed) return false;
    await _ensurePrefs();
    if (_disposed) return false;

    final policy = _prefs.toolApprovalPolicy;
    if (policy == PreferencesService.toolApprovalAuto) return true;
    if (policy == PreferencesService.toolApprovalSessionFirst &&
        _sessionApprovedTools.contains(request.toolName)) {
      return true;
    }

    _completePendingApproval(false, notify: false);
    final completer = Completer<bool>();
    _approvalCompleter = completer;
    pendingApproval = request;
    if (_appInBackground) {
      _startBackgroundApprovalTimeout(request);
    }
    notifyListeners();
    final approved = await completer.future;
    if (approved &&
        policy == PreferencesService.toolApprovalSessionFirst &&
        !_disposed) {
      _sessionApprovedTools.add(request.toolName);
    }
    return approved;
  }

  void resolveToolApproval(bool approved, {bool rememberForSession = false}) {
    final request = pendingApproval;
    if (approved && request != null) {
      _rememberToolApproval(
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
      if (pendingApproval != null && !_disposed) notifyListeners();
    }
  }

  void _rememberToolApproval(
    String toolName, {
    bool explicitSessionApproval = false,
  }) {
    final policy = _prefsInitialized
        ? _prefs.toolApprovalPolicy
        : PreferencesService.defaultToolApprovalPolicy;
    if (policy == PreferencesService.toolApprovalAlways) return;
    if (explicitSessionApproval ||
        policy == PreferencesService.toolApprovalSessionFirst) {
      _sessionApprovedTools.add(toolName);
    }
  }

  void _startBackgroundApprovalTimeout(ToolApprovalRequest request) {
    _approvalTimeout?.cancel();
    _approvalTimeout = Timer(_backgroundApprovalTimeout, () {
      if (_disposed || !identical(pendingApproval, request)) return;
      _rememberToolApproval(request.toolName);
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
  }) async {
    final trimmedText = text.trim();
    if (trimmedText.isEmpty && attachments.isEmpty) return;
    // Guard against concurrent sends. In single-threaded Dart, the check-then-set
    // is safe because no other code can run between the check and the assignment
    // (no preemption between await points). The real protection is that _isSending
    // is only cleared in the finally block after all awaits complete.
    if (_isSending) return;

    _isSending = true;

    try {
      await _ensurePrefs();
      final apiKey = _prefs.apiKey;
      if (apiKey == null || apiKey.isEmpty) {
        errorMessage = AppStrings.apiKeyNotConfigured;
        agentStatus = AgentStatus.error;
        notifyListeners();
        return;
      }

      if (currentSession == null) await createSession();

      final session = currentSession!;
      session.messages.add(ChatMessage.userContent([
        if (trimmedText.isNotEmpty) TextContent(trimmedText),
        ...attachments,
      ]));
      session.autoTitle();
      await _storage.saveSession(session);
      notifyListeners();

      final llmConfig = _buildLlmConfig(_prefs);
      if (_cachedLlm == null || _cachedLlmConfig != llmConfig) {
        _cachedLlm?.dispose();
        _cachedLlm = LlmService(llmConfig);
        _cachedLlmConfig = llmConfig;
      }
      final llm = _cachedLlm!;

      // Refresh skills (and memory) to pick up any user toggle changes
      _skills = await SkillService.scanSkills();
      await MemoryService.getMemories();

      final basePrompt = session.systemPrompt ??
          _prefs.systemPrompt ??
          AppConstants.defaultSystemPrompt;
      final skillIndex = SkillService.buildSkillIndex(_skills);
      final memoryPrompt = MemoryService.buildMemoryPrompt();
      final fullPrompt = basePrompt + skillIndex + memoryPrompt;

      _agent = AgentService(
        llm: llm,
        tools: _tools,
        systemPrompt: fullPrompt,
        toolPolicy: ToolPolicy(onApprovalRequired: _requestToolApproval),
      );

      agentStatus = AgentStatus.thinking;
      streamingText = '';
      errorMessage = null;
      notifyListeners();
      unawaited(_startAgentService(_agentServiceThinkingText));

      _agentCompleter = Completer<void>();
      final fullApiMessages = session.toApiMessages();
      final apiMessages = _truncateToFit(fullApiMessages);
      if (apiMessages.length < fullApiMessages.length) {
        _appendContextCompactionNotice(session, apiMessages.length);
        await _storage.saveSession(session);
        notifyListeners();
      }
      final initialApiMsgCount = apiMessages.length;
      try {
        _agentSubscription = _agent!.runAgentLoop(apiMessages).listen(
          (event) {
            switch (event) {
              case AgentThinking():
                agentStatus = AgentStatus.thinking;
                _streamBuffer = StringBuffer();
                notifyListeners();
                unawaited(_startAgentService(_agentServiceThinkingText));

              case AgentTextDelta(:final text):
                agentStatus = AgentStatus.streaming;
                unawaited(_startAgentService(_agentServiceStreamingText));
                _streamBuffer.write(text);
                _streamThrottle ??= Timer(const Duration(milliseconds: 50), () {
                  streamingText = _streamBuffer.toString();
                  _streamThrottle = null;
                  notifyListeners();
                });

              case AgentToolStart():
                agentStatus = AgentStatus.tooling;
                notifyListeners();
                unawaited(_startAgentService(_agentServiceToolingText));

              case AgentToolDone():
                notifyListeners();

              case AgentComplete(
                  :final finalText,
                  :final inputTokens,
                  :final outputTokens,
                ):
                _streamThrottle?.cancel();
                _streamThrottle = null;
                streamingText = _streamBuffer.toString();
                _streamBuffer = StringBuffer();
                agentStatus = AgentStatus.idle;
                streamingText = '';
                _appendNewAgentMessages(
                    session, _agent!.messages, initialApiMsgCount);
                // Store token usage on the last assistant message
                for (int i = session.messages.length - 1; i >= 0; i--) {
                  if (session.messages[i].role == 'assistant') {
                    session.messages[i].inputTokens = inputTokens;
                    session.messages[i].outputTokens = outputTokens;
                    break;
                  }
                }
                _storage.saveSession(session).then((_) {
                  if (!_disposed) notifyListeners();
                });
                final c = _agentCompleter;
                _agentCompletionFinalizing = true;
                unawaited(_finishAgentComplete(finalText, c));

              case AgentError(:final message):
                _streamThrottle?.cancel();
                _streamThrottle = null;
                _streamBuffer = StringBuffer();
                agentStatus = AgentStatus.error;
                errorMessage = message;
                notifyListeners();
                unawaited(_stopAgentService());
            }
          },
          onError: (Object e) {
            agentStatus = AgentStatus.error;
            errorMessage = '$e';
            _streamThrottle?.cancel();
            _streamThrottle = null;
            notifyListeners();
            if (!_agentCompletionFinalizing) {
              final c = _agentCompleter;
              if (c != null && !c.isCompleted) c.complete();
              unawaited(_stopAgentService());
            }
          },
          onDone: () {
            if (!_agentCompletionFinalizing) {
              final c = _agentCompleter;
              if (c != null && !c.isCompleted) c.complete();
              unawaited(_stopAgentService());
            }
          },
          cancelOnError: false,
        );
        await _agentCompleter!.future;
      } catch (e) {
        agentStatus = AgentStatus.error;
        errorMessage = '$e';
        notifyListeners();
      } finally {
        _agentSubscription = null;
        _agentCompleter = null;
        unawaited(_stopAgentService());
      }
    } finally {
      _isSending = false;
    }
  }

  void cancelAgent() {
    _agent?.cancel();
    unawaited(_stopAgentService());
    _completePendingApproval(false);
    _agentSubscription?.cancel();
    _agentSubscription = null;
    _streamThrottle?.cancel();
    _streamThrottle = null;
    _streamBuffer = StringBuffer();
    if (_agentCompleter != null && !_agentCompleter!.isCompleted) {
      _agentCompleter!.complete();
    }
    agentStatus = AgentStatus.idle;
    streamingText = '';
    notifyListeners();
  }

  // Stored alternatives from previous generations, used during regeneration
  List<String>? _pendingAlternatives;

  Future<void> regenerateLastResponse() async {
    if (currentSession == null || _isSending) return;
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

    // Save the old assistant text into _pendingAlternatives for reuse after regeneration
    if (lastAssistant != null) {
      _pendingAlternatives =
          List<String>.from(lastAssistant.alternatives ?? []);
      final currentText = lastAssistant.latestTextContent;
      if (currentText.isNotEmpty) {
        _pendingAlternatives!.add(currentText);
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

    await sendMessage(lastUserText);
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
    if (_isSending || _isComparing || currentSession == null) return;
    if (text.trim().isEmpty || models.isEmpty) return;

    _isComparing = true;
    compareResults = [];
    notifyListeners();

    await _ensurePrefs();
    final apiKey = _prefs.apiKey;
    if (apiKey == null || apiKey.isEmpty) {
      errorMessage = AppStrings.apiKeyNotConfigured;
      _isComparing = false;
      notifyListeners();
      return;
    }

    final session = currentSession!;
    // Don't persist the user message to session.messages in compare mode.
    // Compare is a one-shot inspection — results live in compareResults only.
    // If we persisted, the next real sendMessage would break role alternation
    // (two consecutive user messages without an assistant reply between them).
    notifyListeners();

    _skills = await SkillService.scanSkills();
    await MemoryService.getMemories();
    final skillIndex = SkillService.buildSkillIndex(_skills);
    final memoryPrompt = MemoryService.buildMemoryPrompt();

    final formatStr =
        session.apiFormatOverride ?? _prefs.apiFormat ?? 'anthropic';
    final format =
        formatStr == 'openai' ? ApiFormat.openai : ApiFormat.anthropic;

    for (final model in models) {
      if (_disposed) break;
      try {
        final config = LlmConfig(
          format: format,
          apiKey: apiKey,
          model: model,
          baseUrl: session.baseUrlOverride ??
              _prefs.baseUrl ??
              (format == ApiFormat.anthropic
                  ? 'https://api.anthropic.com'
                  : 'https://api.openai.com'),
          maxTokens: _prefs.maxTokens ?? AppConstants.defaultMaxTokens,
          thinkingBudget: _prefs.thinkingBudget,
          temperature: _prefs.temperature,
        );
        final llm = LlmService(config);
        try {
          final basePrompt = session.systemPrompt ??
              _prefs.systemPrompt ??
              AppConstants.defaultSystemPrompt;
          final fullPrompt = basePrompt + skillIndex + memoryPrompt;
          final response = await llm.chat(
            system: fullPrompt,
            messages: _truncateToFit(session.toApiMessages()),
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

    _isComparing = false;
    notifyListeners();
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
    _cachedLlm?.dispose();
    _cachedLlm = null;
    _cachedLlmConfig = null;
    notifyListeners();
  }

  Future<void> switchProfile(String profileId) async {
    await _ensurePrefs();
    await _prefs.setActiveProfileId(profileId);
    LlmService.clearTokenKeyOverrides();
    _cachedLlm?.dispose();
    _cachedLlm = null;
    _cachedLlmConfig = null;
    notifyListeners();
  }

  Future<void> updateSessionSystemPrompt(String? systemPrompt) async {
    if (currentSession == null) return;
    currentSession!.systemPrompt = systemPrompt;
    await _storage.saveSession(currentSession!);
    notifyListeners();
  }

  LlmConfig _buildLlmConfig(PreferencesService prefs) {
    final session = currentSession;

    final formatStr =
        session?.apiFormatOverride ?? prefs.apiFormat ?? 'anthropic';
    final format =
        formatStr == 'openai' ? ApiFormat.openai : ApiFormat.anthropic;

    return LlmConfig(
      format: format,
      apiKey: prefs.apiKey!,
      model: session?.modelOverride ?? prefs.model ?? AppConstants.defaultModel,
      baseUrl: session?.baseUrlOverride ??
          prefs.baseUrl ??
          (format == ApiFormat.anthropic
              ? 'https://api.anthropic.com'
              : 'https://api.openai.com'),
      maxTokens: prefs.maxTokens ?? AppConstants.defaultMaxTokens,
      thinkingBudget: prefs.thinkingBudget,
      temperature: prefs.temperature,
    );
  }

  List<Map<String, dynamic>> _truncateToFit(
      List<Map<String, dynamic>> messages) {
    return ChatContextUtils.truncateToFit(
      messages,
      maxChars: _prefs.contextLength,
      autoCompact: _prefs.autoCompact,
    );
  }

  void _appendContextCompactionNotice(ChatSession session, int retainedCount) {
    final text = AppStrings.contextCompactedNotice(retainedCount);
    if (session.messages.isNotEmpty) {
      final last = session.messages.last;
      if (last.isSystemNotice && last.textContent == text) return;
    }
    session.messages.add(ChatMessage.systemNotice(text));
  }

  void _appendNewAgentMessages(
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
      final role = msg['role'] as String;
      final content = msg['content'];

      List<MessageContent> contentList;
      if (content is String) {
        contentList = [
          TextContent(
            content,
            reasoningContent: role == 'assistant'
                ? msg['reasoning_content'] as String?
                : null,
          ),
        ];
      } else if (content is List) {
        contentList = content.map<MessageContent>((item) {
          if (item is Map<String, dynamic>) {
            switch (item['type']) {
              case 'text':
                return TextContent(
                  item['text'] as String,
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
        continue;
      }

      session.messages.add(ChatMessage(
        role: role,
        content: contentList,
      ));
    }

    // If we have pending alternatives from a regeneration, attach them to the last assistant message
    if (_pendingAlternatives != null && _pendingAlternatives!.isNotEmpty) {
      for (int i = session.messages.length - 1; i >= 0; i--) {
        if (session.messages[i].role == 'assistant') {
          final msg = session.messages[i];
          session.messages[i] = ChatMessage(
            role: msg.role,
            content: msg.content,
            timestamp: msg.timestamp,
            inputTokens: msg.inputTokens,
            outputTokens: msg.outputTokens,
            alternatives: _pendingAlternatives,
            activeAlternative: -1,
          );
          break;
        }
      }
      _pendingAlternatives = null;
    }
  }
}

class CompareResult {
  final String model;
  final String text;
  final int? tokens;
  CompareResult({required this.model, required this.text, this.tokens});
}
