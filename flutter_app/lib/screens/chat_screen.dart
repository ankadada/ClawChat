import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import '../app.dart';
import '../constants.dart';
import '../models/chat_models.dart';
import '../providers/chat_provider.dart';
import '../services/preferences_service.dart';
import '../services/file_attachment_service.dart';
import '../services/llm_service.dart';
import '../widgets/streaming_text.dart';
import '../widgets/tool_call_card.dart';
import '../widgets/agent_status_bar.dart';
import '../widgets/compare_view.dart';
import '../services/tts_service.dart';
import '../services/whisper_service.dart';
import 'settings_screen.dart';
import 'chat_sessions_screen.dart';
import '../l10n/app_strings.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();
  final stt.SpeechToText _speech = stt.SpeechToText();
  final TtsService _tts = TtsService();
  final WhisperService _whisper = WhisperService();
  bool _isListening = false;
  bool _isWhisperRecording = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tts.addListener(_onTtsStateChanged);
    _initSpeech();
  }

  void _onTtsStateChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _initSpeech() async {
    try {
      final available = await _speech.initialize(
        onError: (error) {
          if (mounted) setState(() => _isListening = false);
        },
      );
      debugPrint('Speech init: available=$available');
    } catch (e) {
      debugPrint('Speech init failed: $e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tts.removeListener(_onTtsStateChanged);
    _speech.cancel();
    _inputController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _startListening() async {
    // Check and request RECORD_AUDIO permission
    const channel = MethodChannel('com.anka.clawbot/native');
    try {
      final hasPermission = await channel.invokeMethod<bool>('hasAudioPermission') ?? false;
      if (!hasPermission) {
        await channel.invokeMethod('requestAudioPermission');
        // Wait for user to respond to permission dialog
        await Future.delayed(const Duration(milliseconds: 500));
        final granted = await channel.invokeMethod<bool>('hasAudioPermission') ?? false;
        if (!granted) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text(AppStrings.audioPermissionDenied)),
            );
          }
          return;
        }
      }
    } catch (_) {}

    if (!_speech.isAvailable) {
      await _initSpeech();
    }

    if (_speech.isAvailable) {
      setState(() => _isListening = true);
      try {
        await _speech.listen(
          onResult: (result) {
            if (result.finalResult) {
              _inputController.text += result.recognizedWords;
              _inputController.selection = TextSelection.collapsed(
                offset: _inputController.text.length,
              );
            }
          },
          localeId: 'zh_CN',
          listenMode: stt.ListenMode.dictation,
        );
      } catch (e) {
        debugPrint('Speech listen failed: $e');
        if (mounted) setState(() => _isListening = false);
      }
    } else {
      // Fallback: native recording + Whisper API transcription
      _startWhisperRecording();
    }
  }

  void _startWhisperRecording() async {
    final prefs = PreferencesService();
    final model = prefs.whisperModel;
    if (model == null || model.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(AppStrings.whisperModelRequired)),
        );
      }
      return;
    }
    await _whisper.startRecording();
    if (_whisper.isRecording && mounted) {
      setState(() => _isWhisperRecording = true);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(AppStrings.voiceUnavailable)),
      );
    }
  }

  void _stopWhisperRecording() async {
    if (!_isWhisperRecording) return;
    setState(() => _isWhisperRecording = false);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(AppStrings.transcribing), duration: Duration(seconds: 10)),
      );
    }

    final text = await _whisper.stopAndTranscribe();
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();

    if (text != null && text.isNotEmpty) {
      _inputController.text += text;
      _inputController.selection = TextSelection.collapsed(
        offset: _inputController.text.length,
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(AppStrings.transcribeFailed)),
      );
    }
  }

  void _stopListening() {
    _speech.stop();
    setState(() => _isListening = false);
  }

  @override
  void didChangeMetrics() {
    // Only scroll to bottom if keyboard actually appeared
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
      if (bottomInset > 0 && _scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
    });
  }

  String? _lastSessionId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncDraftForSession();
  }

  void _syncDraftForSession() {
    final provider = context.read<ChatProvider>();
    final currentId = provider.currentSession?.id;
    if (currentId != null && currentId != _lastSessionId) {
      if (_lastSessionId != null) {
        provider.saveDraft(_lastSessionId!, _inputController.text);
      }
      _lastSessionId = currentId;
      final draft = provider.getDraft(currentId);
      if (_inputController.text != draft) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _inputController.text = draft;
          _inputController.selection = TextSelection.collapsed(
            offset: draft.length,
          );
        });
      }
    }
  }

  void _sendMessage() {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    _inputController.clear();
    final provider = context.read<ChatProvider>();
    if (provider.currentSession != null) {
      provider.saveDraft(provider.currentSession!.id, '');
    }
    provider.sendMessage(text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Consumer<ChatProvider>(
          builder: (_, provider, __) {
            return Text(
              provider.currentSession?.title ?? AppStrings.appName,
              overflow: TextOverflow.ellipsis,
            );
          },
        ),
        automaticallyImplyLeading: false,
        leading: MediaQuery.of(context).size.width >= 700
            ? null
            : IconButton(
                icon: const Icon(Icons.menu),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ChatSessionsScreen()),
                ),
              ),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: AppStrings.newChat,
            onPressed: () => context.read<ChatProvider>().createSession(),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'settings':
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
                case 'system_prompt':
                  _showSystemPromptDialog();
                case 'session_system_prompt':
                  _showSessionSystemPromptDialog();
                case 'switch_model':
                  _showSwitchModelDialog();
                case 'regenerate':
                  context.read<ChatProvider>().regenerateLastResponse();
                case 'compare':
                  _showCompareDialog();
              }
            },
            itemBuilder: (_) {
              final provider = context.read<ChatProvider>();
              return [
                if (provider.currentSession?.messages.isNotEmpty == true)
                  const PopupMenuItem(value: 'regenerate', child: ListTile(
                    leading: Icon(Icons.refresh),
                    title: Text(AppStrings.regenerate),
                    dense: true,
                  )),
                const PopupMenuItem(value: 'compare', child: ListTile(
                  leading: Icon(Icons.compare_arrows),
                  title: Text(AppStrings.compareMode),
                  dense: true,
                )),
                const PopupMenuItem(value: 'switch_model', child: ListTile(
                  leading: Icon(Icons.swap_horiz),
                  title: Text(AppStrings.switchModel),
                  dense: true,
                )),
                const PopupMenuItem(value: 'session_system_prompt', child: ListTile(
                  leading: Icon(Icons.tune),
                  title: Text(AppStrings.systemPromptTitle),
                  dense: true,
                )),
                const PopupMenuItem(value: 'system_prompt', child: ListTile(
                  leading: Icon(Icons.psychology),
                  title: Text(AppStrings.editSystemPrompt),
                  dense: true,
                )),
                const PopupMenuItem(value: 'settings', child: ListTile(
                  leading: Icon(Icons.settings),
                  title: Text(AppStrings.settings),
                  dense: true,
                )),
              ];
            },
          ),
        ],
      ),
      body: Column(
        children: [
          const AgentStatusBar(),
          Expanded(
            child: Selector<ChatProvider, ({List<ChatMessage> messages, bool hasStreaming, String? sessionId})>(
              selector: (_, p) => (
                messages: p.currentSession?.messages ?? [],
                hasStreaming: p.agentStatus == AgentStatus.streaming || p.streamingText.isNotEmpty,
                sessionId: p.currentSession?.id,
              ),
              builder: (context, data, __) {
                final messages = data.messages;
                final hasStreaming = data.hasStreaming;

                // Sync draft when session changes via Selector rebuild
                final currentId = data.sessionId;
                if (currentId != null && currentId != _lastSessionId) {
                  _syncDraftForSession();
                }

                if (messages.isEmpty && !hasStreaming) {
                  return _buildEmptyState(theme);
                }

                final itemCount = messages.length + (hasStreaming ? 1 : 0);
                return ListView.builder(
                  controller: _scrollController,
                  reverse: true,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  itemCount: itemCount,
                  itemBuilder: (context, index) {
                    final reversedIndex = itemCount - 1 - index;
                    if (reversedIndex == messages.length && hasStreaming) {
                      return Consumer<ChatProvider>(
                        builder: (_, provider, __) =>
                            _buildStreamingBubble(provider.streamingText, theme),
                      );
                    }
                    return _buildMessageBubble(messages[reversedIndex], reversedIndex, theme);
                  },
                );
              },
            ),
          ),
          // Compare view
          Consumer<ChatProvider>(
            builder: (_, provider, __) {
              if (provider.compareResults == null) return const SizedBox.shrink();
              return CompareView(
                results: provider.compareResults!,
                isComparing: provider.isComparing,
                onDismiss: () => provider.clearCompareResults(),
              );
            },
          ),
          _buildQuickPrompts(),
          _buildInputArea(theme),
        ],
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.chat_bubble_outline, size: 64,
              color: theme.colorScheme.onSurfaceVariant.withAlpha(100)),
          const SizedBox(height: 16),
          Text(AppStrings.sendMessageToStart,
              style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 8),
          Text(AppStrings.aiAssistantCapabilities,
              style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage message, int messageIndex, ThemeData theme) {
    final isUser = message.role == 'user';
    final messageId = '${message.timestamp.millisecondsSinceEpoch}_$messageIndex';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              isUser ? AppStrings.userLabel : AppStrings.aiLabel,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          for (final content in message.content)
            _buildContentBlock(content, isUser, theme, messageId: messageId),
          if (!isUser && message.alternatives != null && message.alternatives!.isNotEmpty)
            _buildAlternativesNav(message, messageIndex, theme),
          if (!isUser) _buildAssistantFooter(message, messageId, theme),
        ],
      ),
    );
  }

  Widget _buildAssistantFooter(ChatMessage message, String messageId, ThemeData theme) {
    final textContent = message.textContent;
    final hasText = textContent.isNotEmpty;
    final hasTokens = message.inputTokens != null || message.outputTokens != null;

    if (!hasText && !hasTokens) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasText)
            SizedBox(
              height: 28,
              width: 28,
              child: _tts.isLoadingMessage(messageId)
                  ? Padding(
                      padding: const EdgeInsets.all(6),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: theme.colorScheme.onSurfaceVariant.withAlpha(150),
                        ),
                      ),
                    )
                  : IconButton(
                      padding: EdgeInsets.zero,
                      iconSize: 16,
                      icon: Icon(
                        _tts.isPlayingMessage(messageId) ? Icons.stop : Icons.volume_up,
                        color: theme.colorScheme.onSurfaceVariant.withAlpha(150),
                      ),
                      tooltip: _tts.isPlayingMessage(messageId) ? AppStrings.ttsStop : AppStrings.ttsPlay,
                      onPressed: () {
                        _tts.speak(textContent, messageId).then((ok) {
                          if (!mounted) return;
                          if (!ok && _tts.lastError != null) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(_tts.lastError!)),
                            );
                          }
                          setState(() {});
                        });
                      },
                    ),
            ),
          if (hasTokens) ...[
            const SizedBox(width: 8),
            Text(
              [
                if (message.inputTokens != null) '↑${message.inputTokens}',
                if (message.outputTokens != null) '↓${message.outputTokens}',
              ].join(' '),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant.withAlpha(120),
                fontSize: 11,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildContentBlock(MessageContent content, bool isUser, ThemeData theme, {String? messageId}) {
    switch (content) {
      case TextContent(:final text):
        return Semantics(
          label: isUser ? '用户消息' : 'AI 消息',
          child: GestureDetector(
          onLongPress: () {
            showModalBottomSheet(
              context: context,
              builder: (ctx) => SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ListTile(
                      leading: const Icon(Icons.copy),
                      title: const Text(AppStrings.copy),
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: text));
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text(AppStrings.copied), duration: Duration(seconds: 1)),
                        );
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.format_quote),
                      title: const Text(AppStrings.quoteReply),
                      onTap: () {
                        Navigator.pop(ctx);
                        final quoted = text.length > 200
                            ? '${text.substring(0, 200)}...'
                            : text;
                        _inputController.text = '> $quoted\n\n${_inputController.text}';
                        _inputController.selection = TextSelection.collapsed(
                          offset: _inputController.text.length,
                        );
                        _focusNode.requestFocus();
                      },
                    ),
                  ],
                ),
              ),
            );
          },
          child: Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.85,
            ),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isUser
                  ? AppColors.accent.withAlpha(20)
                  : theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isUser
                    ? AppColors.accent.withAlpha(50)
                    : theme.colorScheme.outline.withAlpha(50),
              ),
            ),
            child: StreamingText(text: text),
          ),
        ),
        );

      case ToolUseContent():
        return ToolCallCard(toolUse: content);

      case ToolResultContent():
        return const SizedBox.shrink();
    }
  }

  Widget _buildStreamingBubble(String text, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(AppStrings.aiLabel,
                style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600)),
          ),
          Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.85,
            ),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: theme.colorScheme.outline.withAlpha(50),
              ),
            ),
            child: StreamingText(text: text, isStreaming: true),
          ),
        ],
      ),
    );
  }

  Future<void> _showSystemPromptDialog() async {
    final prefs = PreferencesService();
    await prefs.init();
    final controller = TextEditingController(text: prefs.systemPrompt ?? AppConstants.defaultSystemPrompt);

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(AppStrings.editSystemPrompt),
        content: SizedBox(
          width: double.maxFinite,
          height: 300,
          child: TextField(
            controller: controller,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'System prompt...',
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text(AppStrings.cancel)),
          TextButton(
            onPressed: () { controller.text = AppConstants.defaultSystemPrompt; },
            child: const Text(AppStrings.resetDefault),
          ),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text(AppStrings.save)),
        ],
      ),
    );
    if (result != null) {
      prefs.systemPrompt = result;
    }
  }

  Future<void> _showSessionSystemPromptDialog() async {
    final provider = context.read<ChatProvider>();
    final session = provider.currentSession;
    if (session == null) return;

    final controller = TextEditingController(text: session.systemPrompt ?? '');

    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(AppStrings.systemPromptTitle),
        content: SizedBox(
          width: double.maxFinite,
          height: 300,
          child: TextField(
            controller: controller,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              hintText: AppStrings.systemPromptHint,
              helperText: controller.text.isEmpty ? AppStrings.useGlobalDefault : null,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(AppStrings.cancel),
          ),
          TextButton(
            onPressed: () {
              controller.text = '';
              Navigator.pop(ctx, '');
            },
            child: const Text(AppStrings.useGlobalDefault),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text(AppStrings.save),
          ),
        ],
      ),
    );
    if (result != null) {
      provider.updateSessionSystemPrompt(result.isEmpty ? null : result);
    }
  }

  Future<void> _showSwitchModelDialog() async {
    final provider = context.read<ChatProvider>();
    final prefs = PreferencesService();
    await prefs.init();

    final controller = TextEditingController(
      text: provider.currentSession?.modelOverride ?? '',
    );

    List<String> availableModels = [];
    bool loading = false;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text(AppStrings.switchModel),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (loading)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: CircularProgressIndicator(),
                )
              else if (availableModels.isNotEmpty)
                DropdownButtonFormField<String>(
                  value: availableModels.contains(controller.text) ? controller.text : null,
                  decoration: InputDecoration(
                    labelText: AppStrings.selectModel,
                    hintText: AppStrings.useGlobalDefault,
                  ),
                  isExpanded: true,
                  items: [
                    const DropdownMenuItem(value: '', child: Text(AppStrings.useGlobalDefault)),
                    ...availableModels.map((m) => DropdownMenuItem(
                      value: m,
                      child: Text(m, overflow: TextOverflow.ellipsis),
                    )),
                  ],
                  onChanged: (v) => controller.text = v ?? '',
                )
              else
                TextField(
                  controller: controller,
                  decoration: InputDecoration(
                    labelText: AppStrings.modelName,
                    hintText: AppStrings.useGlobalDefault,
                    helperText: AppStrings.leaveEmptyForDefault,
                  ),
                ),
              const SizedBox(height: 8),
              TextButton.icon(
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text(AppStrings.fetchModelsButton),
                onPressed: () async {
                  setDialogState(() => loading = true);
                  try {
                    availableModels = await LlmService.fetchModels(
                      apiFormat: prefs.apiFormat ?? 'anthropic',
                      apiKey: prefs.apiKey ?? '',
                      baseUrl: prefs.baseUrl,
                    );
                  } catch (_) {}
                  setDialogState(() => loading = false);
                },
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text(AppStrings.cancel)),
            FilledButton(
              onPressed: () {
                provider.updateSessionModel(model: controller.text.isEmpty ? null : controller.text);
                Navigator.pop(ctx);
              },
              child: const Text(AppStrings.confirm),
            ),
          ],
        ),
      ),
    );
  }

  void _showAttachOptions() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.image),
              title: const Text(AppStrings.pickImage),
              onTap: () { Navigator.pop(ctx); _pickAndAttach(FileType.image); },
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file),
              title: const Text(AppStrings.pickFile),
              onTap: () { Navigator.pop(ctx); _pickAndAttach(FileType.any); },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickAndAttach(FileType type) async {
    final files = await FileAttachmentService.pickFiles(type: type);
    if (files.isEmpty) return;

    for (final file in files) {
      try {
        final path = await FileAttachmentService.importToWorkspace(file);
        final size = FileAttachmentService.formatFileSize(file.size);
        _inputController.text += '[Attached: $path ($size)]';
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${AppStrings.attachFailed}: $e')),
          );
        }
      }
    }
  }

  Widget _buildQuickPrompts() {
    const prompts = [
      (AppStrings.promptTranslate, AppStrings.promptTranslateTemplate),
      (AppStrings.promptSummarize, AppStrings.promptSummarizeTemplate),
      (AppStrings.promptExplainCode, AppStrings.promptExplainCodeTemplate),
      (AppStrings.promptWriteEmail, AppStrings.promptWriteEmailTemplate),
      (AppStrings.promptPolish, AppStrings.promptPolishTemplate),
      (AppStrings.promptBrainstorm, AppStrings.promptBrainstormTemplate),
    ];

    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: prompts.map((p) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ActionChip(
            label: Text(p.$1, style: const TextStyle(fontSize: 13)),
            onPressed: () {
              final current = _inputController.text;
              _inputController.text = p.$2 + current;
              _inputController.selection = TextSelection.collapsed(
                offset: _inputController.text.length,
              );
              _focusNode.requestFocus();
            },
          ),
        )).toList(),
      ),
    );
  }

  Widget _buildAlternativesNav(ChatMessage message, int messageIndex, ThemeData theme) {
    final current = message.displayIndex;
    final total = message.totalVersions;

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 28,
            height: 28,
            child: IconButton(
              padding: EdgeInsets.zero,
              iconSize: 16,
              icon: Icon(
                Icons.chevron_left,
                color: current > 1
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant.withAlpha(80),
              ),
              onPressed: current > 1
                  ? () => context.read<ChatProvider>().previousAlternative(messageIndex)
                  : null,
            ),
          ),
          Text(
            AppStrings.alternativeOf(current, total),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
          SizedBox(
            width: 28,
            height: 28,
            child: IconButton(
              padding: EdgeInsets.zero,
              iconSize: 16,
              icon: Icon(
                Icons.chevron_right,
                color: current < total
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant.withAlpha(80),
              ),
              onPressed: current < total
                  ? () => context.read<ChatProvider>().nextAlternative(messageIndex)
                  : null,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showCompareDialog() async {
    final prefs = PreferencesService();
    await prefs.init();

    List<String> availableModels = [];
    final selectedModels = <String>{};
    bool loading = false;
    final textController = TextEditingController();

    // Pre-populate with the current input text
    textController.text = _inputController.text;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text(AppStrings.compareMode),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: textController,
                  maxLines: 3,
                  minLines: 1,
                  decoration: InputDecoration(
                    hintText: AppStrings.inputHint,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  AppStrings.selectModels,
                  style: Theme.of(ctx).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                if (loading)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: CircularProgressIndicator(),
                    ),
                  )
                else if (availableModels.isNotEmpty)
                  SizedBox(
                    height: 200,
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: availableModels.length,
                      itemBuilder: (_, i) {
                        final model = availableModels[i];
                        return CheckboxListTile(
                          dense: true,
                          title: Text(model, overflow: TextOverflow.ellipsis),
                          value: selectedModels.contains(model),
                          onChanged: (v) {
                            setDialogState(() {
                              if (v == true) {
                                selectedModels.add(model);
                              } else {
                                selectedModels.remove(model);
                              }
                            });
                          },
                        );
                      },
                    ),
                  )
                else
                  Text(
                    AppStrings.fetchModelsButton,
                    style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    ),
                  ),
                const SizedBox(height: 8),
                TextButton.icon(
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text(AppStrings.fetchModelsButton),
                  onPressed: () async {
                    setDialogState(() => loading = true);
                    try {
                      availableModels = await LlmService.fetchModels(
                        apiFormat: prefs.apiFormat ?? 'anthropic',
                        apiKey: prefs.apiKey ?? '',
                        baseUrl: prefs.baseUrl,
                      );
                    } catch (_) {}
                    setDialogState(() => loading = false);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text(AppStrings.cancel),
            ),
            FilledButton(
              onPressed: selectedModels.length >= 2
                  ? () {
                      Navigator.pop(ctx);
                      final text = textController.text.trim();
                      if (text.isNotEmpty) {
                        _inputController.clear();
                        final provider = context.read<ChatProvider>();
                        if (provider.currentSession != null) {
                          provider.saveDraft(provider.currentSession!.id, '');
                        }
                        provider.sendCompare(text, selectedModels.toList());
                      }
                    }
                  : null,
              child: const Text(AppStrings.compareStart),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputArea(ThemeData theme) {
    return Consumer<ChatProvider>(
      builder: (_, provider, __) {
        final isRunning = provider.agentStatus != AgentStatus.idle &&
            provider.agentStatus != AgentStatus.error;

        return Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          decoration: BoxDecoration(
            color: theme.scaffoldBackgroundColor,
            border: Border(
              top: BorderSide(color: theme.colorScheme.outline.withAlpha(50)),
            ),
          ),
          child: SafeArea(
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.attach_file),
                  tooltip: AppStrings.attachFile,
                  onPressed: isRunning ? null : _showAttachOptions,
                ),
                Expanded(
                  child: TextField(
                    controller: _inputController,
                    focusNode: _focusNode,
                    enabled: !isRunning,
                    maxLines: 5,
                    minLines: 1,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendMessage(),
                    decoration: InputDecoration(
                      hintText: isRunning ? AppStrings.aiProcessing : AppStrings.inputHint,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    ),
                  ),
                ),
                if (!isRunning)
                  GestureDetector(
                    onLongPressStart: (_) {
                      if (!_isWhisperRecording) _startListening();
                    },
                    onLongPressEnd: (_) {
                      if (_isWhisperRecording) {
                        _stopWhisperRecording();
                      } else {
                        _stopListening();
                      }
                    },
                    child: IconButton(
                      icon: Icon(
                        (_isListening || _isWhisperRecording) ? Icons.mic : Icons.mic_none,
                        color: (_isListening || _isWhisperRecording) ? Colors.red : null,
                      ),
                      onPressed: () {
                        if (_isWhisperRecording) {
                          _stopWhisperRecording();
                        } else if (_isListening) {
                          _stopListening();
                        } else {
                          _startListening();
                        }
                      },
                    ),
                  ),
                const SizedBox(width: 4),
                if (isRunning)
                  IconButton.filled(
                    onPressed: provider.cancelAgent,
                    icon: const Icon(Icons.stop),
                    style: IconButton.styleFrom(
                      backgroundColor: AppColors.statusRed,
                    ),
                  )
                else
                  IconButton.filled(
                    onPressed: _sendMessage,
                    icon: const Icon(Icons.send),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
