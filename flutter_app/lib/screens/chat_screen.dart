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
  bool _isListening = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initSpeech();
  }

  Future<void> _initSpeech() async {
    await _speech.initialize(
      onError: (error) {
        if (mounted) setState(() => _isListening = false);
      },
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _speech.cancel();
    _inputController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _startListening() async {
    if (!_speech.isAvailable) {
      await _initSpeech();
    }
    if (!_speech.isAvailable) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('语音识别不可用')),
        );
      }
      return;
    }

    setState(() => _isListening = true);
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
  }

  void _stopListening() {
    _speech.stop();
    setState(() => _isListening = false);
  }

  @override
  void didChangeMetrics() {
    // Keyboard appeared/disappeared — with reverse ListView, scroll to 0
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
    });
  }

  bool _isStreaming = false;
  String? _currentDraftSessionId;

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
                case 'switch_model':
                  _showSwitchModelDialog();
                case 'regenerate':
                  context.read<ChatProvider>().regenerateLastResponse();
              }
            },
            itemBuilder: (_) {
              final provider = context.read<ChatProvider>();
              return [
                if (provider.currentSession?.messages.isNotEmpty == true)
                  const PopupMenuItem(value: 'regenerate', child: ListTile(
                    leading: Icon(Icons.refresh),
                    title: Text('重新生成'),
                    dense: true,
                  )),
                const PopupMenuItem(value: 'switch_model', child: ListTile(
                  leading: Icon(Icons.swap_horiz),
                  title: Text(AppStrings.switchModel),
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

                // Draft saving / restoring on session switch
                final currentId = data.sessionId;
                if (currentId != null && currentId != _currentDraftSessionId) {
                  if (_currentDraftSessionId != null) {
                    context.read<ChatProvider>().saveDraft(
                      _currentDraftSessionId!, _inputController.text);
                  }
                  _currentDraftSessionId = currentId;
                  final draft = context.read<ChatProvider>().getDraft(currentId);
                  if (_inputController.text != draft) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      _inputController.text = draft;
                      _inputController.selection = TextSelection.collapsed(
                        offset: draft.length);
                    });
                  }
                }

                if (hasStreaming && !_isStreaming) {
                  _isStreaming = true;
                } else if (!hasStreaming && _isStreaming) {
                  _isStreaming = false;
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
                    return _buildMessageBubble(messages[reversedIndex], theme);
                  },
                );
              },
            ),
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

  Widget _buildMessageBubble(ChatMessage message, ThemeData theme) {
    final isUser = message.role == 'user';

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
            _buildContentBlock(content, isUser, theme),
        ],
      ),
    );
  }

  Widget _buildContentBlock(MessageContent content, bool isUser, ThemeData theme) {
    switch (content) {
      case TextContent(:final text):
        return GestureDetector(
          onLongPress: () {
            showModalBottomSheet(
              context: context,
              builder: (ctx) => SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ListTile(
                      leading: const Icon(Icons.copy),
                      title: const Text('复制'),
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
                      title: const Text('引用回复'),
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
              title: const Text('选择图片'),
              onTap: () { Navigator.pop(ctx); _pickAndAttach(FileType.image); },
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file),
              title: const Text('选择文件'),
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
            SnackBar(content: Text('附件失败: $e')),
          );
        }
      }
    }
  }

  Widget _buildQuickPrompts() {
    const prompts = [
      ('翻译这段', '请翻译以下内容：\n'),
      ('总结一下', '请总结：\n'),
      ('解释代码', '请解释这段代码：\n'),
      ('写邮件', '请帮我写一封邮件：\n'),
      ('修改润色', '请帮我修改润色以下文字：\n'),
      ('头脑风暴', '请帮我头脑风暴：\n'),
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
                  tooltip: '附件',
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
                    onLongPressStart: (_) => _startListening(),
                    onLongPressEnd: (_) => _stopListening(),
                    child: IconButton(
                      icon: Icon(
                        _isListening ? Icons.mic : Icons.mic_none,
                        color: _isListening ? Colors.red : null,
                      ),
                      onPressed: () {
                        if (_isListening) {
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
