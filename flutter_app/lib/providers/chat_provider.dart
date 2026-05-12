import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../constants.dart';
import '../models/chat_models.dart';
import '../services/agent_service.dart';
import '../services/llm_service.dart';
import '../services/session_storage.dart';
import '../services/tools/tool_registry.dart';
import '../services/preferences_service.dart';
import '../services/skill_service.dart';
import '../l10n/app_strings.dart';

const int _maxContextChars = 100000; // ~25k tokens

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

  String getDraft(String sessionId) => _drafts[sessionId] ?? '';

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
    sessions.insert(0, SessionSummary(
      id: session.id,
      title: session.title,
      createdAt: session.createdAt,
      updatedAt: session.updatedAt,
    ));
    currentSession = session;
    notifyListeners();
    return session;
  }

  Future<void> selectSession(String id) async {
    currentSession = await _storage.getSession(id);
    notifyListeners();
  }

  Future<void> deleteSession(String id) async {
    await _storage.deleteSession(id);
    sessions.removeWhere((s) => s.id == id);
    if (currentSession?.id == id) {
      currentSession = null;
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
    notifyListeners();
  }

  Future<void> sendMessage(String text) async {
    if (text.trim().isEmpty) return;
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
      session.messages.add(ChatMessage.user(text));
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

      final basePrompt = _prefs.systemPrompt ?? AppConstants.defaultSystemPrompt;
      final skillIndex = SkillService.buildSkillIndex(_skills);
      final fullPrompt = basePrompt + skillIndex;

      _agent = AgentService(
        llm: llm,
        tools: _tools,
        systemPrompt: fullPrompt,
      );

      agentStatus = AgentStatus.thinking;
      streamingText = '';
      errorMessage = null;
      notifyListeners();

      _agentCompleter = Completer<void>();
      try {
        _agentSubscription = _agent!.runAgentLoop(
          _truncateToFit(session.toApiMessages()),
        ).listen(
          (event) {
            switch (event) {
              case AgentThinking():
                agentStatus = AgentStatus.thinking;
                _streamBuffer = StringBuffer();
                notifyListeners();

              case AgentTextDelta(:final text):
                agentStatus = AgentStatus.streaming;
                _streamBuffer.write(text);
                _streamThrottle ??= Timer(const Duration(milliseconds: 50), () {
                  streamingText = _streamBuffer.toString();
                  _streamThrottle = null;
                  notifyListeners();
                });

              case AgentToolStart():
                agentStatus = AgentStatus.tooling;
                notifyListeners();

              case AgentToolDone():
                notifyListeners();

              case AgentComplete():
                _streamThrottle?.cancel();
                _streamThrottle = null;
                streamingText = _streamBuffer.toString();
                _streamBuffer = StringBuffer();
                agentStatus = AgentStatus.idle;
                streamingText = '';
                _applyFinalAgentMessages(session, _agent!.messages);
                _storage.saveSession(session).then((_) {
                  if (!_disposed) notifyListeners();
                });
                if (_agentCompleter != null && !_agentCompleter!.isCompleted) {
                  _agentCompleter!.complete();
                }

              case AgentError(:final message):
                _streamThrottle?.cancel();
                _streamThrottle = null;
                _streamBuffer = StringBuffer();
                agentStatus = AgentStatus.error;
                errorMessage = message;
                notifyListeners();
            }
          },
          onError: (Object e) {
            agentStatus = AgentStatus.error;
            errorMessage = '$e';
            notifyListeners();
            if (!_agentCompleter!.isCompleted) _agentCompleter!.complete();
          },
          onDone: () {
            if (!_agentCompleter!.isCompleted) _agentCompleter!.complete();
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
      }
    } finally {
      _isSending = false;
    }
  }

  void cancelAgent() {
    _agent?.cancel();
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

  Future<void> regenerateLastResponse() async {
    if (currentSession == null || _isSending) return;
    final messages = currentSession!.messages;

    // Remove messages from the end until we hit the last user message
    while (messages.isNotEmpty && messages.last.role != 'user') {
      messages.removeLast();
    }
    if (messages.isEmpty) return;

    // Get the last user message text and re-send
    final lastUserText = messages.last.textContent;
    messages.removeLast(); // Remove it too, sendMessage will re-add it

    await _storage.saveSession(currentSession!);
    notifyListeners();

    await sendMessage(lastUserText);
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

  LlmConfig _buildLlmConfig(PreferencesService prefs) {
    final session = currentSession;

    final formatStr = session?.apiFormatOverride ?? prefs.apiFormat ?? 'anthropic';
    final format = formatStr == 'openai' ? ApiFormat.openai : ApiFormat.anthropic;

    return LlmConfig(
      format: format,
      apiKey: prefs.apiKey!,
      model: session?.modelOverride ?? prefs.model ?? AppConstants.defaultModel,
      baseUrl: session?.baseUrlOverride ?? prefs.baseUrl ?? (format == ApiFormat.anthropic
          ? 'https://api.anthropic.com'
          : 'https://api.openai.com'),
      maxTokens: prefs.maxTokens ?? AppConstants.defaultMaxTokens,
      thinkingBudget: prefs.thinkingBudget,
    );
  }

  int _charCount(Map<String, dynamic> msg) {
    final content = msg['content'];
    if (content is String) return content.length;
    if (content is List) {
      int count = 0;
      for (final item in content) {
        if (item is Map) {
          count += (item['text'] as String?)?.length ?? 0;
          count += (item['content'] as String?)?.length ?? 0;
        }
      }
      return count;
    }
    return 0;
  }

  bool _hasToolUseContent(Map<String, dynamic> msg) {
    final content = msg['content'];
    if (content is List) {
      return content.any((item) => item is Map && item['type'] == 'tool_use');
    }
    return false;
  }

  bool _hasToolResultContent(Map<String, dynamic> msg) {
    final content = msg['content'];
    if (content is List) {
      return content.any((item) => item is Map && item['type'] == 'tool_result');
    }
    return false;
  }

  List<Map<String, dynamic>> _truncateToFit(List<Map<String, dynamic>> messages) {
    final result = List<Map<String, dynamic>>.from(messages);
    int totalChars = 0;
    for (final msg in result) {
      totalChars += _charCount(msg);
    }
    while (result.length > 2 && totalChars > _maxContextChars) {
      final front = result[0];
      // If this is an assistant message with tool_use, also remove the following
      // user message containing the tool_result to keep them paired.
      if (_hasToolUseContent(front) && result.length > 2 && _hasToolResultContent(result[1])) {
        totalChars -= _charCount(result.removeAt(0));
        if (result.isNotEmpty) {
          totalChars -= _charCount(result.removeAt(0));
        }
      } else if (_hasToolResultContent(front)) {
        // Skip orphaned tool_result at the front — remove it
        totalChars -= _charCount(result.removeAt(0));
      } else {
        totalChars -= _charCount(result.removeAt(0));
      }
    }
    return result;
  }

  void _applyFinalAgentMessages(ChatSession session, List<Map<String, dynamic>> agentMessages) {
    // Build a map of original timestamps keyed by (role, position-among-same-role).
    // This preserves message timing when the agent loop replaces session messages.
    final timestampMap = <String, List<DateTime>>{};
    for (final msg in session.messages) {
      timestampMap.putIfAbsent(msg.role, () => []).add(msg.timestamp);
    }
    final roleCounters = <String, int>{};

    session.messages.clear();
    for (final msg in agentMessages) {
      final role = msg['role'] as String;
      final content = msg['content'];

      final idx = roleCounters[role] ?? 0;
      roleCounters[role] = idx + 1;
      final timestamps = timestampMap[role];
      final preservedTs = (timestamps != null && idx < timestamps.length)
          ? timestamps[idx]
          : null;

      if (content is String) {
        session.messages.add(ChatMessage(
          role: role,
          content: [TextContent(content)],
          timestamp: preservedTs,
        ));
      } else if (content is List) {
        final contentList = content.map<MessageContent>((item) {
          if (item is Map<String, dynamic>) {
            switch (item['type']) {
              case 'text':
                return TextContent(item['text'] as String);
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

        session.messages.add(ChatMessage(
          role: role,
          content: contentList,
          timestamp: preservedTs,
        ));
      }
    }
  }
}
