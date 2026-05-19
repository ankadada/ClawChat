import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
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
import '../services/native_bridge.dart';
import '../services/tools/tool_policy.dart';
import '../services/voice_input_state.dart';
import '../widgets/streaming_text.dart';
import '../widgets/tool_call_card.dart';
import '../widgets/agent_status_bar.dart';
import '../widgets/compare_view.dart';
import '../services/tts_service.dart';
import '../services/whisper_service.dart';
import 'artifact_preview_screen.dart';
import 'settings_screen.dart';
import 'chat_sessions_screen.dart';
import '../l10n/app_strings.dart';

enum _NativeSpeechOutcome {
  recognized,
  empty,
  unavailable,
  busy,
  stale,
  timedOut,
  failed,
}

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
  final VoiceInputStateMachine _voiceInput = VoiceInputStateMachine();
  bool _showScrollToBottom = false;
  bool _approvalDialogOpen = false;
  ToolApprovalRequest? _shownApprovalRequest;
  final List<MessageContent> _pendingAttachments = [];
  final List<_PendingAttachmentPreview> _pendingAttachmentPreviews = [];
  final Set<String> _seenMessageAnimationIds = {};
  String? _seenAnimationSessionId;

  bool get _isListening => _voiceInput.isListening;
  bool get _isWhisperRecording => _voiceInput.isWhisperRecording;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_handleScroll);
    _tts.addListener(_onTtsStateChanged);
    _initSpeech();
  }

  void _onTtsStateChanged() {
    if (mounted) setState(() {});
  }

  String _briefError(Object error) {
    final text = error.toString().replaceFirst('Exception: ', '');
    return text.length > 160 ? '${text.substring(0, 160)}...' : text;
  }

  void _scheduleToolApprovalDialog(ToolApprovalRequest? request) {
    if (request == null ||
        _approvalDialogOpen ||
        identical(request, _shownApprovalRequest)) {
      return;
    }
    _approvalDialogOpen = true;
    _shownApprovalRequest = request;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (!identical(context.read<ChatProvider>().pendingApproval, request)) {
        _approvalDialogOpen = false;
        _shownApprovalRequest = null;
        return;
      }
      await _showToolApprovalDialog(request);
      if (!mounted) return;
      final provider = context.read<ChatProvider>();
      if (identical(provider.pendingApproval, request)) {
        provider.resolveToolApproval(false);
      }
      _approvalDialogOpen = false;
      if (provider.pendingApproval == null) {
        _shownApprovalRequest = null;
      }
    });
  }

  Future<void> _showToolApprovalDialog(ToolApprovalRequest request) {
    final provider = context.read<ChatProvider>();
    final riskColor = _riskColor(request.risk);
    final arguments = _formatToolArguments(request);

    return showModalBottomSheet<void>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      showDragHandle: false,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      backgroundColor: riskColor.withAlpha(28),
                      foregroundColor: riskColor,
                      child: Icon(_riskIcon(request.risk)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            AppStrings.toolApprovalTitle,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${request.toolName} · ${_riskLabel(request.risk)}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: riskColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  AppStrings.toolApprovalArguments,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 220),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(AppRadii.s),
                    border: Border.all(
                      color: theme.colorScheme.outline.withAlpha(50),
                    ),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      arguments,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    TextButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        provider.resolveToolApproval(false);
                      },
                      child: const Text(AppStrings.toolApprovalDeny),
                    ),
                    OutlinedButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        provider.resolveToolApproval(true);
                      },
                      child: const Text(AppStrings.toolApprovalAllowOnce),
                    ),
                    FilledButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        provider.resolveToolApproval(
                          true,
                          rememberForSession: true,
                        );
                      },
                      child: const Text(AppStrings.toolApprovalAllowSession),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _formatToolArguments(ToolApprovalRequest request) {
    if (request.toolName == 'bash') {
      final command = request.arguments['command'];
      if (command is String && command.isNotEmpty) return command;
    }
    if (request.toolName == 'read_file' || request.toolName == 'write_file') {
      final path = request.arguments['path'];
      if (path is String && path.isNotEmpty) {
        final buffer = StringBuffer(path);
        if (request.arguments.containsKey('content')) {
          final content = request.arguments['content']?.toString() ?? '';
          buffer
            ..writeln()
            ..writeln()
            ..write(content.length > 4000
                ? '${content.substring(0, 4000)}\n\n[content truncated]'
                : content);
        }
        return buffer.toString();
      }
    }
    try {
      return const JsonEncoder.withIndent('  ').convert(request.arguments);
    } catch (_) {
      return request.arguments.toString();
    }
  }

  String _riskLabel(ToolRisk risk) {
    return switch (risk) {
      ToolRisk.safe => AppStrings.riskLow,
      ToolRisk.moderate => AppStrings.riskMedium,
      ToolRisk.dangerous => AppStrings.riskHigh,
    };
  }

  IconData _riskIcon(ToolRisk risk) {
    return switch (risk) {
      ToolRisk.safe => Icons.verified_outlined,
      ToolRisk.moderate => Icons.warning_amber_outlined,
      ToolRisk.dangerous => Icons.report_problem_outlined,
    };
  }

  Color _riskColor(ToolRisk risk) {
    return switch (risk) {
      ToolRisk.safe => AppColors.statusGreen,
      ToolRisk.moderate => AppColors.statusAmber,
      ToolRisk.dangerous => AppColors.statusRed,
    };
  }

  Future<void> _initSpeech() async {
    try {
      final available = await _speech.initialize(
        onStatus: (status) {
          if (status == 'done' || status == 'notListening') {
            if (mounted &&
                _voiceInput.phase == VoiceInputPhase.pluginRecognition) {
              setState(() => _voiceInput.cancel());
            }
          }
        },
        onError: (error) {
          debugPrint('Speech error: ${error.errorMsg}');
          if (mounted &&
              _voiceInput.phase == VoiceInputPhase.pluginRecognition) {
            setState(() => _voiceInput.cancel());
          }
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
    unawaited(NativeBridge.cancelSpeechRecognition());
    unawaited(_whisper.cancelRecording());
    _speech.cancel();
    _scrollController.removeListener(_handleScroll);
    _inputController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _startListening() async {
    final token = _voiceInput.beginStart();
    if (token == null) return;
    if (mounted) setState(() {});
    await _startListeningImpl(token);
  }

  Future<void> _startListeningImpl(int token) async {
    if (!await _ensureAudioPermission(token)) return;
    if (!_voiceInput.isCurrent(token)) return;

    final nativeOutcome = await _tryNativeSpeechRecognition(token);
    switch (nativeOutcome) {
      case _NativeSpeechOutcome.recognized:
      case _NativeSpeechOutcome.empty:
      case _NativeSpeechOutcome.busy:
      case _NativeSpeechOutcome.stale:
      case _NativeSpeechOutcome.timedOut:
        return;
      case _NativeSpeechOutcome.unavailable:
      case _NativeSpeechOutcome.failed:
        break;
    }

    await _tryPluginSpeechRecognition(token);
  }

  Future<bool> _ensureAudioPermission(int token) async {
    try {
      final hasPermission = await NativeBridge.hasAudioPermission();
      if (!hasPermission) {
        await NativeBridge.requestAudioPermission();
        await Future.delayed(const Duration(milliseconds: 500));
        final granted = await NativeBridge.hasAudioPermission();
        if (!granted) {
          if (mounted && _voiceInput.isCurrent(token)) {
            setState(() => _voiceInput.complete(token));
          }
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text(AppStrings.audioPermissionDenied)),
            );
          }
          return false;
        }
      }
    } catch (_) {
      // Native recognition will surface a better error if permission probing
      // itself is unavailable on the current platform.
    }
    return _voiceInput.isCurrent(token);
  }

  Future<void> _tryPluginSpeechRecognition(int token) async {
    if (!_speech.isAvailable) {
      await _initSpeech();
    }
    if (!_voiceInput.isCurrent(token)) return;

    if (_speech.isAvailable) {
      if (mounted) {
        setState(() => _voiceInput.enterPluginRecognition(token));
      } else {
        _voiceInput.enterPluginRecognition(token);
      }
      try {
        await _speech.listen(
          onResult: (result) {
            if (!_voiceInput.isCurrent(token)) return;
            if (result.finalResult) {
              _appendRecognizedText(result.recognizedWords);
              if (mounted) setState(() => _voiceInput.complete(token));
            }
          },
          localeId: 'zh_CN',
          listenMode: stt.ListenMode.dictation,
        );
      } catch (e) {
        debugPrint('Speech listen failed: $e');
        await _startWhisperRecording(token);
      }
      return;
    }

    await _startWhisperRecording(token);
  }

  void _appendRecognizedText(String text) {
    if (text.isEmpty) return;
    _inputController.text += text;
    _inputController.selection = TextSelection.collapsed(
      offset: _inputController.text.length,
    );
  }

  Future<_NativeSpeechOutcome> _tryNativeSpeechRecognition(int token) async {
    try {
      if (mounted) {
        setState(() => _voiceInput.enterNativeRecognition(token));
      } else {
        _voiceInput.enterNativeRecognition(token);
      }
      final result =
          await NativeBridge.startSpeechRecognition(language: 'zh-CN')
              .timeout(const Duration(seconds: 70));
      if (!_voiceInput.isCurrent(token)) return _NativeSpeechOutcome.stale;

      final text = result?.trim();
      if (text == null || text.isEmpty) {
        if (mounted) setState(() => _voiceInput.complete(token));
        return _NativeSpeechOutcome.empty;
      }
      _appendRecognizedText(text);
      if (mounted) setState(() => _voiceInput.complete(token));
      return _NativeSpeechOutcome.recognized;
    } on TimeoutException catch (e) {
      debugPrint('Native speech recognition timed out: $e');
      if (mounted && _voiceInput.isCurrent(token)) {
        setState(() => _voiceInput.complete(token));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(AppStrings.voiceUnavailable)),
        );
      }
      return _NativeSpeechOutcome.timedOut;
    } on PlatformException catch (e) {
      debugPrint('Native speech recognition failed: ${e.code} ${e.message}');
      if (e.code == 'SPEECH_BUSY') {
        if (mounted && _voiceInput.isCurrent(token)) {
          setState(() => _voiceInput.complete(token));
        }
        return _NativeSpeechOutcome.busy;
      }
      if (e.code == 'SPEECH_UNAVAILABLE') {
        return _NativeSpeechOutcome.unavailable;
      }
      return _NativeSpeechOutcome.failed;
    } catch (e) {
      debugPrint('Native speech recognition failed: $e');
      return _NativeSpeechOutcome.failed;
    }
  }

  Future<void> _startWhisperRecording(int token) async {
    if (!_voiceInput.isCurrent(token)) return;
    final prefs = PreferencesService();
    final model = prefs.whisperModel;
    if (model == null || model.isEmpty) {
      if (mounted && _voiceInput.isCurrent(token)) {
        setState(() => _voiceInput.complete(token));
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(AppStrings.whisperModelRequired)),
        );
      }
      return;
    }
    await _whisper.startRecording();
    if (!_voiceInput.isCurrent(token)) {
      unawaited(_whisper.cancelRecording());
      return;
    }
    if (_whisper.isRecording) {
      if (mounted) setState(() => _voiceInput.enterWhisperRecording(token));
    } else {
      if (mounted) {
        setState(() => _voiceInput.complete(token));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(AppStrings.voiceUnavailable)),
        );
      }
    }
  }

  void _stopWhisperRecording() async {
    if (!_isWhisperRecording) return;
    final token = _voiceInput.activeToken;
    setState(() => _voiceInput.enterTranscribing(token));

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(AppStrings.transcribing),
            duration: Duration(seconds: 10)),
      );
    }

    String? text;
    try {
      text = await _whisper.stopAndTranscribe();
    } catch (e) {
      debugPrint('Whisper transcription failed: $e');
    }
    if (!mounted) {
      if (_voiceInput.isCurrent(token)) _voiceInput.complete(token);
      return;
    }
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    if (_voiceInput.isCurrent(token)) {
      setState(() => _voiceInput.complete(token));
    }

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
    unawaited(_speech.stop());
    unawaited(NativeBridge.cancelSpeechRecognition());
    unawaited(_whisper.cancelRecording());
    setState(() => _voiceInput.cancel());
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
      _pendingAttachments.clear();
      _pendingAttachmentPreviews.clear();
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
    final attachments = List<MessageContent>.from(_pendingAttachments);
    if (text.isEmpty && attachments.isEmpty) return;
    HapticFeedback.lightImpact();
    setState(() {
      _inputController.clear();
      _pendingAttachments.clear();
      _pendingAttachmentPreviews.clear();
    });
    final provider = context.read<ChatProvider>();
    if (provider.currentSession != null) {
      provider.saveDraft(provider.currentSession!.id, '');
    }
    provider.sendMessage(text, attachments: attachments);
  }

  void _handleScroll() {
    if (!_scrollController.hasClients) return;
    final offset = _scrollController.offset;
    final shouldShow = _showScrollToBottom ? offset > 120 : offset > 300;
    if (shouldShow == _showScrollToBottom) return;
    setState(() => _showScrollToBottom = shouldShow);
  }

  void _scrollToBottom() {
    HapticFeedback.lightImpact();
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pendingApproval = context.select<ChatProvider, ToolApprovalRequest?>(
      (provider) => provider.pendingApproval,
    );
    _scheduleToolApprovalDialog(pendingApproval);

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
                  CupertinoPageRoute(
                      builder: (_) => const ChatSessionsScreen()),
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
                  Navigator.of(context).push(CupertinoPageRoute(
                      builder: (_) => const SettingsScreen()));
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
                  const PopupMenuItem(
                      value: 'regenerate',
                      child: ListTile(
                        leading: Icon(Icons.refresh),
                        title: Text(AppStrings.regenerate),
                        dense: true,
                      )),
                const PopupMenuItem(
                    value: 'compare',
                    child: ListTile(
                      leading: Icon(Icons.compare_arrows),
                      title: Text(AppStrings.compareMode),
                      dense: true,
                    )),
                const PopupMenuItem(
                    value: 'switch_model',
                    child: ListTile(
                      leading: Icon(Icons.swap_horiz),
                      title: Text(AppStrings.switchModel),
                      dense: true,
                    )),
                const PopupMenuItem(
                    value: 'session_system_prompt',
                    child: ListTile(
                      leading: Icon(Icons.tune),
                      title: Text(AppStrings.systemPromptTitle),
                      dense: true,
                    )),
                const PopupMenuItem(
                    value: 'system_prompt',
                    child: ListTile(
                      leading: Icon(Icons.psychology),
                      title: Text(AppStrings.editSystemPrompt),
                      dense: true,
                    )),
                const PopupMenuItem(
                    value: 'settings',
                    child: ListTile(
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
            child: LayoutBuilder(
              builder: (context, constraints) {
                final maxContentWidth =
                    math.min(640.0, constraints.maxWidth * 0.86);
                return Selector<
                    ChatProvider,
                    ({
                      List<ChatMessage> messages,
                      bool hasStreaming,
                      AgentStatus status,
                      String? sessionId,
                      String modelName
                    })>(
                  selector: (_, p) => (
                    messages: p.currentSession?.messages ?? [],
                    hasStreaming: p.agentStatus == AgentStatus.streaming ||
                        p.streamingText.isNotEmpty,
                    status: p.agentStatus,
                    sessionId: p.currentSession?.id,
                    modelName:
                        p.currentSession?.modelOverride ?? p.configuredModel,
                  ),
                  builder: (context, data, __) {
                    final messages = data.messages;
                    final hasStreaming = data.hasStreaming;
                    final showTyping =
                        data.status == AgentStatus.thinking && !hasStreaming;

                    // Sync draft when session changes via Selector rebuild
                    final currentId = data.sessionId;
                    if (currentId != null && currentId != _lastSessionId) {
                      _syncDraftForSession();
                    }
                    _primeMessageAnimations(currentId, messages);

                    if (messages.isEmpty && !hasStreaming && !showTyping) {
                      return _buildEmptyState(
                          theme, data.modelName, maxContentWidth);
                    }

                    final itemCount = messages.length +
                        (hasStreaming ? 1 : 0) +
                        (showTyping ? 1 : 0);
                    return Stack(
                      children: [
                        ListView.builder(
                          controller: _scrollController,
                          reverse: true,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                          itemCount: itemCount,
                          itemBuilder: (context, index) {
                            final reversedIndex = itemCount - 1 - index;
                            if (reversedIndex == messages.length &&
                                hasStreaming) {
                              return Consumer<ChatProvider>(
                                builder: (_, provider, __) => RepaintBoundary(
                                  child: _buildStreamingBubble(
                                    provider.streamingText,
                                    theme,
                                    maxContentWidth,
                                    previousRole: messages.isEmpty
                                        ? null
                                        : messages.last.role,
                                  ),
                                ),
                              );
                            }
                            if (reversedIndex == messages.length &&
                                showTyping) {
                              return RepaintBoundary(
                                child: _buildTypingIndicatorBubble(
                                  theme,
                                  maxContentWidth,
                                  previousRole: messages.isEmpty
                                      ? null
                                      : messages.last.role,
                                ),
                              );
                            }
                            final message = messages[reversedIndex];
                            final previousRole = reversedIndex > 0
                                ? messages[reversedIndex - 1].role
                                : null;
                            final nextRole = reversedIndex < messages.length - 1
                                ? messages[reversedIndex + 1].role
                                : null;
                            final animationId = _messageAnimationId(message);
                            final animate =
                                _seenMessageAnimationIds.add(animationId);
                            return _AnimatedMessageEntry(
                              key: ValueKey(animationId),
                              animate: animate,
                              child: RepaintBoundary(
                                child: _buildMessageBubble(
                                  message,
                                  reversedIndex,
                                  theme,
                                  maxContentWidth,
                                  messages: messages,
                                  previousRole: previousRole,
                                  nextRole: nextRole,
                                ),
                              ),
                            );
                          },
                        ),
                        Positioned(
                          right: 16,
                          bottom: 16,
                          child: _buildScrollToBottomButton(theme),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
          // Compare view
          Consumer<ChatProvider>(
            builder: (_, provider, __) {
              if (provider.compareResults == null)
                return const SizedBox.shrink();
              return CompareView(
                results: provider.compareResults!,
                isComparing: provider.isComparing,
                onDismiss: () => provider.clearCompareResults(),
              );
            },
          ),
          Consumer<ChatProvider>(
            builder: (_, provider, __) {
              final messages = provider.currentSession?.messages;
              if (messages == null || messages.isEmpty) {
                return const SizedBox.shrink();
              }
              return _buildQuickPrompts(theme);
            },
          ),
          _buildInputArea(theme),
        ],
      ),
    );
  }

  void _primeMessageAnimations(String? sessionId, List<ChatMessage> messages) {
    if (_seenAnimationSessionId == sessionId) return;
    _seenAnimationSessionId = sessionId;
    _seenMessageAnimationIds
      ..clear()
      ..addAll(messages.map(_messageAnimationId));
  }

  String _messageAnimationId(ChatMessage message) {
    return '${message.timestamp.microsecondsSinceEpoch}-${message.role}-${message.content.length}';
  }

  Widget _buildScrollToBottomButton(ThemeData theme) {
    return IgnorePointer(
      ignoring: !_showScrollToBottom,
      child: AnimatedOpacity(
        opacity: _showScrollToBottom ? 1 : 0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        child: AnimatedScale(
          scale: _showScrollToBottom ? 1 : 0.92,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          child: FloatingActionButton.small(
            heroTag: 'chat-scroll-to-bottom',
            tooltip: AppStrings.scrollToBottom,
            onPressed: _scrollToBottom,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
            foregroundColor: theme.colorScheme.onSurface,
            child: const Icon(Icons.keyboard_arrow_down),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(
      ThemeData theme, String modelName, double maxContentWidth) {
    const prompts = [
      AppStrings.emptyPromptSummarizeCode,
      AppStrings.emptyPromptWriteEmail,
      AppStrings.emptyPromptTranslateText,
      AppStrings.emptyPromptExplainConcept,
    ];

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: math.min(480.0, maxContentWidth)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withAlpha(18),
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: theme.colorScheme.primary.withAlpha(45)),
                ),
                child: Icon(Icons.auto_awesome,
                    size: 34, color: theme.colorScheme.primary),
              ),
              const SizedBox(height: 18),
              Text(AppStrings.sendMessageToStart,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(AppStrings.aiAssistantCapabilities,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 12),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(AppRadii.xl),
                  border: Border.all(
                      color: theme.colorScheme.outline.withAlpha(45)),
                ),
                child: Text(AppStrings.currentModelLabel(modelName),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ),
              const SizedBox(height: 18),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final prompt in prompts)
                    ActionChip(
                      label: Text(prompt),
                      onPressed: () {
                        _inputController.text = prompt;
                        _inputController.selection = TextSelection.collapsed(
                          offset: _inputController.text.length,
                        );
                        _focusNode.requestFocus();
                      },
                      side: BorderSide(
                          color: theme.colorScheme.outline.withAlpha(70)),
                      backgroundColor: theme.colorScheme.surface,
                      labelStyle: theme.textTheme.labelMedium,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 6),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  double _halfMessageGap(String? adjacentRole, String role) {
    if (adjacentRole == null) return 6;
    return adjacentRole == role ? 2 : 8;
  }

  BorderRadius _bubbleRadius(bool isUser) {
    const tight = Radius.circular(4);
    const regular = Radius.circular(AppRadii.m);
    return BorderRadius.only(
      topLeft: regular,
      topRight: regular,
      bottomLeft: isUser ? regular : tight,
      bottomRight: isUser ? tight : regular,
    );
  }

  Widget _buildMessageBubble(
    ChatMessage message,
    int messageIndex,
    ThemeData theme,
    double maxContentWidth, {
    required List<ChatMessage> messages,
    String? previousRole,
    String? nextRole,
  }) {
    if (message.isSystemNotice) {
      return _buildSystemNotice(message, theme);
    }

    final isUser = message.role == 'user';
    final messageId =
        '${message.timestamp.millisecondsSinceEpoch}_$messageIndex';

    return Padding(
      padding: EdgeInsets.only(
        top: _halfMessageGap(previousRole, message.role),
        bottom: _halfMessageGap(nextRole, message.role),
      ),
      child: Column(
        crossAxisAlignment:
            isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
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
            _buildContentBlock(
              content,
              isUser,
              theme,
              maxContentWidth,
              messageId: messageId,
              message: message,
              messageIndex: messageIndex,
              messages: messages,
            ),
          if (!isUser &&
              message.alternatives != null &&
              message.alternatives!.isNotEmpty)
            _buildAlternativesNav(message, messageIndex, theme),
          if (!isUser) _buildAssistantFooter(message, messageId, theme),
        ],
      ),
    );
  }

  Widget _buildSystemNotice(ChatMessage message, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.info_outline,
              size: 14,
              color: theme.colorScheme.onSurfaceVariant.withAlpha(150),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                message.textContent,
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant.withAlpha(170),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAssistantFooter(
      ChatMessage message, String messageId, ThemeData theme) {
    final textContent = message.textContent;
    final hasText = textContent.isNotEmpty;
    final hasTokens =
        message.inputTokens != null || message.outputTokens != null;
    final ttsRouteLabel = _tts.routeLabelForMessage(messageId);
    final isTtsLoading = _tts.isLoadingMessage(messageId);
    final isTtsPlaying = _tts.isPlayingMessage(messageId);
    final isTtsPaused = _tts.isPausedMessage(messageId);
    final isSystemTts = _tts.isSystemMessage(messageId);
    final showTtsRouteLabel =
        ttsRouteLabel != null && (isTtsLoading || isTtsPlaying || isTtsPaused);

    if (!hasText && !hasTokens) return const SizedBox.shrink();

    final ttsIcon = isTtsPaused
        ? Icons.play_arrow
        : isTtsPlaying && isSystemTts
            ? Icons.pause
            : isTtsPlaying
                ? Icons.stop
                : Icons.volume_up;
    final ttsTooltip = isTtsPaused
        ? AppStrings.ttsResume
        : isTtsPlaying && isSystemTts
            ? AppStrings.ttsPause
            : isTtsPlaying
                ? AppStrings.ttsStop
                : AppStrings.ttsPlay;

    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasText)
            SizedBox(
              height: 44,
              width: 44,
              child: isTtsLoading
                  ? Center(
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color:
                              theme.colorScheme.onSurfaceVariant.withAlpha(150),
                        ),
                      ),
                    )
                  : IconButton(
                      padding: EdgeInsets.zero,
                      iconSize: 16,
                      icon: Icon(
                        ttsIcon,
                        color:
                            theme.colorScheme.onSurfaceVariant.withAlpha(150),
                      ),
                      tooltip: ttsTooltip,
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
          if (showTtsRouteLabel) ...[
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(AppRadii.s),
                border: Border.all(
                  color: theme.colorScheme.outline.withAlpha(45),
                ),
              ),
              child: Text(
                ttsRouteLabel,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontSize: 11,
                ),
              ),
            ),
          ],
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

  String _messageToMarkdown(ChatMessage? message,
      {required String fallbackText}) {
    if (message == null) return fallbackText;
    final role =
        message.role == 'user' ? AppStrings.userLabel : AppStrings.aiLabel;
    final buffer = StringBuffer('**$role**:\n');
    for (final content in message.content) {
      switch (content) {
        case TextContent(:final text):
          if (text.isNotEmpty) buffer.writeln(text);
        case ImageContent(:final filename, :final mediaType):
          buffer.writeln('[Image: ${filename ?? mediaType}]');
        case ToolUseContent(:final name, :final input):
          buffer.writeln('**Tool call**: `$name`');
          buffer.writeln('```json');
          buffer.writeln(const JsonEncoder.withIndent('  ').convert(input));
          buffer.writeln('```');
        case ToolResultContent(:final output):
          buffer.writeln('**Tool result**:');
          buffer.writeln('```');
          buffer.writeln(output.length > 2000
              ? '${output.substring(0, 2000)}\n\n[tool output truncated]'
              : output);
          buffer.writeln('```');
      }
    }
    return buffer.toString().trimRight();
  }

  Future<void> _forkFromMessage(int? messageIndex) async {
    final session = context.read<ChatProvider>().currentSession;
    if (session == null || messageIndex == null) return;

    final fork = await context.read<ChatProvider>().forkFromMessage(
          session.id,
          messageIndex,
        );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          fork == null ? AppStrings.forkFailed : AppStrings.forkCreated,
        ),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  String? _toolOutputFor(
    ToolUseContent toolUse,
    int? messageIndex,
    List<ChatMessage>? messages,
  ) {
    if (messageIndex == null || messages == null) return null;
    final resultIndex = messageIndex + 1;
    if (resultIndex >= messages.length) return null;

    final resultMessage = messages[resultIndex];
    if (resultMessage.role != 'user') return null;

    for (final result in resultMessage.toolResults) {
      if (result.toolUseId == toolUse.id) return result.output;
    }
    return null;
  }

  void _openArtifactPreview(String htmlContent) {
    Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => ArtifactPreviewScreen(
          htmlContent: htmlContent,
          title: AppStrings.artifactsPreview,
        ),
      ),
    );
  }

  Widget _buildContentBlock(
    MessageContent content,
    bool isUser,
    ThemeData theme,
    double maxContentWidth, {
    String? messageId,
    ChatMessage? message,
    int? messageIndex,
    List<ChatMessage>? messages,
  }) {
    switch (content) {
      case TextContent(:final text):
        return Semantics(
          label: isUser ? '用户消息' : 'AI 消息',
          child: GestureDetector(
            onLongPress: () {
              HapticFeedback.lightImpact();
              showModalBottomSheet(
                context: context,
                builder: (ctx) => SafeArea(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ListTile(
                        leading: const Icon(Icons.copy),
                        title: const Text(AppStrings.copyText),
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: text));
                          Navigator.pop(ctx);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text(AppStrings.copied),
                                duration: Duration(seconds: 1)),
                          );
                        },
                      ),
                      ListTile(
                        leading: const Icon(Icons.article_outlined),
                        title: const Text(AppStrings.copyMarkdown),
                        onTap: () {
                          Clipboard.setData(ClipboardData(
                            text:
                                _messageToMarkdown(message, fallbackText: text),
                          ));
                          Navigator.pop(ctx);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text(AppStrings.copied),
                                duration: Duration(seconds: 1)),
                          );
                        },
                      ),
                      ListTile(
                        leading: const Icon(Icons.share),
                        title: const Text(AppStrings.share),
                        onTap: () async {
                          Navigator.pop(ctx);
                          try {
                            await NativeBridge.shareText(
                              text: _messageToMarkdown(message,
                                  fallbackText: text),
                              subject: AppStrings.appName,
                            );
                          } catch (e) {
                            if (!mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                  content:
                                      Text('${AppStrings.shareFailed}: $e')),
                            );
                          }
                        },
                      ),
                      ListTile(
                        leading: const Icon(Icons.call_split),
                        title: const Text(AppStrings.forkConversation),
                        onTap: () async {
                          Navigator.pop(ctx);
                          await _forkFromMessage(messageIndex);
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
                          _inputController.text =
                              '> $quoted\n\n${_inputController.text}';
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
                maxWidth: maxContentWidth,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: isUser
                    ? AppColors.accent.withAlpha(45)
                    : theme.colorScheme.surface,
                borderRadius: _bubbleRadius(isUser),
                border: Border.all(
                  color: isUser
                      ? AppColors.accent.withAlpha(90)
                      : theme.colorScheme.outline.withAlpha(50),
                ),
              ),
              child: StreamingText(text: text),
            ),
          ),
        );

      case ToolUseContent():
        return GestureDetector(
          onLongPress: () async {
            HapticFeedback.lightImpact();
            await _forkFromMessage(messageIndex);
          },
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxContentWidth),
            child: ToolCallCard(
              toolUse: content,
              toolOutput: _toolOutputFor(content, messageIndex, messages),
            ),
          ),
        );

      case ToolResultContent(:final output):
        if (!isPreviewableHtml(output)) return const SizedBox.shrink();
        return Align(
          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxContentWidth),
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: ActionChip(
                avatar: Icon(
                  Icons.preview_outlined,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
                label: const Text(AppStrings.preview),
                onPressed: () => _openArtifactPreview(output),
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
        );

      case ImageContent(:final filename, :final mediaType):
        final label = filename ?? mediaType;
        return Semantics(
          label: AppStrings.imageAttachmentLabel(label),
          child: GestureDetector(
            onLongPress: () async {
              HapticFeedback.lightImpact();
              await _forkFromMessage(messageIndex);
            },
            child: Container(
              constraints: BoxConstraints(
                maxWidth: maxContentWidth,
              ),
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: isUser
                    ? AppColors.accent.withAlpha(45)
                    : theme.colorScheme.surface,
                borderRadius: _bubbleRadius(isUser),
                border: Border.all(
                  color: isUser
                      ? AppColors.accent.withAlpha(90)
                      : theme.colorScheme.outline.withAlpha(50),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.image,
                    color: theme.colorScheme.primary,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      label,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
    }
  }

  Widget _buildStreamingBubble(
    String text,
    ThemeData theme,
    double maxContentWidth, {
    String? previousRole,
  }) {
    return Padding(
      padding: EdgeInsets.only(
        top: _halfMessageGap(previousRole, 'assistant'),
        bottom: 8,
      ),
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
              maxWidth: maxContentWidth,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: _bubbleRadius(false),
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

  Widget _buildTypingIndicatorBubble(
    ThemeData theme,
    double maxContentWidth, {
    String? previousRole,
  }) {
    return Padding(
      padding: EdgeInsets.only(
        top: _halfMessageGap(previousRole, 'assistant'),
        bottom: 8,
      ),
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
            constraints: BoxConstraints(maxWidth: maxContentWidth),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: _bubbleRadius(false),
              border: Border.all(
                color: theme.colorScheme.outline.withAlpha(50),
              ),
            ),
            child: RepaintBoundary(
              child: _TypingDots(color: theme.colorScheme.primary),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showSystemPromptDialog() async {
    final prefs = PreferencesService();
    await prefs.init();
    final controller = TextEditingController(
        text: prefs.systemPrompt ?? AppConstants.defaultSystemPrompt);

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
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text(AppStrings.cancel)),
          TextButton(
            onPressed: () {
              controller.text = AppConstants.defaultSystemPrompt;
            },
            child: const Text(AppStrings.resetDefault),
          ),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text(AppStrings.save)),
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
              helperText:
                  controller.text.isEmpty ? AppStrings.useGlobalDefault : null,
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
                  value: availableModels.any((m) =>
                          LlmService.modelIdFromDisplay(m) == controller.text)
                      ? controller.text
                      : null,
                  decoration: InputDecoration(
                    labelText: AppStrings.selectModel,
                    hintText: AppStrings.useGlobalDefault,
                  ),
                  isExpanded: true,
                  items: [
                    const DropdownMenuItem(
                        value: '', child: Text(AppStrings.useGlobalDefault)),
                    ...availableModels.map((m) => DropdownMenuItem(
                          value: LlmService.modelIdFromDisplay(m),
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
                    if (availableModels.any(LlmService.isPresetModel) &&
                        mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(AppStrings.modelFetchPresetNotice),
                        ),
                      );
                    }
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                            content: Text(
                                AppStrings.modelFetchFailed(_briefError(e)))),
                      );
                    }
                  }
                  setDialogState(() => loading = false);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text(AppStrings.cancel)),
            FilledButton(
              onPressed: () {
                provider.updateSessionModel(
                    model: controller.text.isEmpty ? null : controller.text);
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
              onTap: () {
                Navigator.pop(ctx);
                _pickAndAttach(FileType.image);
              },
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file),
              title: const Text(AppStrings.pickFile),
              onTap: () {
                Navigator.pop(ctx);
                _pickAndAttach(FileType.any);
              },
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
        final prepared = await FileAttachmentService.prepareForMessage(file);
        if (!mounted) return;
        final insertedText = _appendAttachmentText(prepared.inputText);
        setState(() {
          if (prepared.includeAsContentBlock) {
            _pendingAttachments.add(prepared.content);
          }
          _pendingAttachmentPreviews.add(_PendingAttachmentPreview(
            content: prepared.content,
            inputText: prepared.inputText,
            insertedText: insertedText,
            includeAsContentBlock: prepared.includeAsContentBlock,
          ));
        });
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${AppStrings.attachFailed}: $e')),
          );
        }
      }
    }
  }

  String _appendAttachmentText(String text) {
    final current = _inputController.text;
    final separator = current.isEmpty || current.endsWith('\n') ? '' : '\n';
    final insertedText = '$separator$text\n';
    _inputController.text = '$current$insertedText';
    _inputController.selection = TextSelection.collapsed(
      offset: _inputController.text.length,
    );
    return insertedText;
  }

  Widget _buildQuickPrompts(ThemeData theme) {
    const prompts = [
      (AppStrings.promptTranslate, AppStrings.promptTranslateTemplate),
      (AppStrings.promptSummarize, AppStrings.promptSummarizeTemplate),
      (AppStrings.promptExplainCode, AppStrings.promptExplainCodeTemplate),
      (AppStrings.promptWriteEmail, AppStrings.promptWriteEmailTemplate),
      (AppStrings.promptPolish, AppStrings.promptPolishTemplate),
      (AppStrings.promptBrainstorm, AppStrings.promptBrainstormTemplate),
    ];

    return SizedBox(
      height: 48,
      child: Stack(
        children: [
          ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            children: prompts
                .map((p) => Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ActionChip(
                        label: Text(p.$1),
                        labelStyle: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurface,
                          fontWeight: FontWeight.w600,
                        ),
                        backgroundColor:
                            theme.colorScheme.surfaceContainerHighest,
                        side: BorderSide(
                            color: theme.colorScheme.outline.withAlpha(65)),
                        shape: const StadiumBorder(),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 7),
                        onPressed: () {
                          final current = _inputController.text;
                          _inputController.text = p.$2 + current;
                          _inputController.selection = TextSelection.collapsed(
                            offset: _inputController.text.length,
                          );
                          _focusNode.requestFocus();
                        },
                      ),
                    ))
                .toList(),
          ),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: IgnorePointer(
              child: Container(
                width: 18,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      theme.scaffoldBackgroundColor,
                      theme.scaffoldBackgroundColor.withAlpha(0),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            child: IgnorePointer(
              child: Container(
                width: 18,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      theme.scaffoldBackgroundColor.withAlpha(0),
                      theme.scaffoldBackgroundColor,
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _removePendingAttachment(_PendingAttachmentPreview preview) {
    setState(() {
      _pendingAttachmentPreviews.remove(preview);
      if (preview.includeAsContentBlock) {
        _pendingAttachments.remove(preview.content);
      }

      final current = _inputController.text;
      var updated = current.replaceFirst(preview.insertedText, '');
      if (updated == current) {
        updated = current.replaceFirst('${preview.inputText}\n', '');
      }
      if (updated == current) {
        updated = current.replaceFirst(preview.inputText, '');
      }
      _inputController.text = updated;
      _inputController.selection = TextSelection.collapsed(
        offset: _inputController.text.length,
      );
    });
  }

  Widget _buildAttachmentPreviews(ThemeData theme) {
    if (_pendingAttachmentPreviews.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SizedBox(
        height: 44,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: _pendingAttachmentPreviews.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final preview = _pendingAttachmentPreviews[index];
            return _buildAttachmentPreviewChip(theme, preview);
          },
        ),
      ),
    );
  }

  Widget _buildAttachmentPreviewChip(
    ThemeData theme,
    _PendingAttachmentPreview preview,
  ) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 220),
      padding: const EdgeInsets.fromLTRB(6, 5, 2, 5),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadii.l),
        border: Border.all(color: theme.colorScheme.outline.withAlpha(55)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _attachmentPreviewLeading(theme, preview.content),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              _attachmentPreviewLabel(preview),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          SizedBox(
            width: 30,
            height: 30,
            child: IconButton(
              tooltip: AppStrings.removeAttachment,
              padding: EdgeInsets.zero,
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              onPressed: () => _removePendingAttachment(preview),
              icon: const Icon(Icons.close),
            ),
          ),
        ],
      ),
    );
  }

  Widget _attachmentPreviewLeading(ThemeData theme, MessageContent content) {
    if (content is ImageContent) {
      try {
        return ClipRRect(
          borderRadius: BorderRadius.circular(AppRadii.s),
          child: Image.memory(
            base64Decode(content.data),
            width: 32,
            height: 32,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => _filePreviewIcon(theme),
          ),
        );
      } catch (_) {
        return _filePreviewIcon(theme);
      }
    }
    return _filePreviewIcon(theme);
  }

  Widget _filePreviewIcon(ThemeData theme) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(AppRadii.s),
      ),
      child: Icon(
        Icons.insert_drive_file_outlined,
        size: 18,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }

  String _attachmentPreviewLabel(_PendingAttachmentPreview preview) {
    final content = preview.content;
    if (content is ImageContent) {
      return content.filename ?? content.mediaType;
    }

    final firstLine = preview.inputText.trim().split('\n').first;
    if (firstLine.startsWith('File: ')) {
      return firstLine.substring('File: '.length);
    }

    final attachedMatch =
        RegExp(r'^\[Attached: ([^\s\]]+)').firstMatch(firstLine);
    if (attachedMatch != null) {
      final path = attachedMatch.group(1)!;
      return path.split('/').last;
    }

    return firstLine;
  }

  Widget _buildAlternativesNav(
      ChatMessage message, int messageIndex, ThemeData theme) {
    final current = message.displayIndex;
    final total = message.totalVersions;

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 44,
            height: 44,
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
                  ? () => context
                      .read<ChatProvider>()
                      .previousAlternative(messageIndex)
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
            width: 44,
            height: 44,
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
                  ? () =>
                      context.read<ChatProvider>().nextAlternative(messageIndex)
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
                        final modelId = LlmService.modelIdFromDisplay(model);
                        return CheckboxListTile(
                          dense: true,
                          title: Text(model, overflow: TextOverflow.ellipsis),
                          value: selectedModels.contains(modelId),
                          onChanged: (v) {
                            setDialogState(() {
                              if (v == true) {
                                selectedModels.add(modelId);
                              } else {
                                selectedModels.remove(modelId);
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
                      if (availableModels.any(LlmService.isPresetModel) &&
                          mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(AppStrings.modelFetchPresetNotice),
                          ),
                        );
                      }
                    } catch (e) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                              content: Text(
                                  AppStrings.modelFetchFailed(_briefError(e)))),
                        );
                      }
                    }
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
        final isRecording = _isListening || _isWhisperRecording;

        return Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
          decoration: BoxDecoration(
            color: theme.scaffoldBackgroundColor,
            border: Border(
              top: BorderSide(color: theme.colorScheme.outline.withAlpha(70)),
            ),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildAttachmentPreviews(theme),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    SizedBox(
                      width: 44,
                      height: 48,
                      child: IconButton(
                        icon: const Icon(Icons.attach_file),
                        tooltip: AppStrings.attachFile,
                        style: IconButton.styleFrom(
                          backgroundColor:
                              theme.colorScheme.surfaceContainerHighest,
                          foregroundColor: theme.colorScheme.onSurfaceVariant,
                        ),
                        onPressed: isRunning ? null : _showAttachOptions,
                      ),
                    ),
                    const SizedBox(width: 8),
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
                          hintText: isRunning
                              ? AppStrings.aiProcessing
                              : AppStrings.inputHint,
                          filled: true,
                          fillColor: theme.colorScheme.surfaceContainerHighest,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(AppRadii.xl),
                            borderSide: BorderSide(
                                color: theme.colorScheme.outline.withAlpha(60)),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(AppRadii.xl),
                            borderSide: BorderSide(
                                color: theme.colorScheme.outline.withAlpha(60)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(AppRadii.xl),
                            borderSide: BorderSide(
                                color: theme.colorScheme.primary.withAlpha(180),
                                width: 1.5),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                        ),
                      ),
                    ),
                    if (!isRunning) const SizedBox(width: 6),
                    if (!isRunning)
                      GestureDetector(
                        onTap: () {
                          if (_isWhisperRecording) {
                            _stopWhisperRecording();
                          } else if (_isListening) {
                            _stopListening();
                          } else {
                            HapticFeedback.lightImpact();
                            _startListening();
                          }
                        },
                        child: Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: isRecording
                                ? AppColors.statusRed.withAlpha(28)
                                : theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(AppRadii.s),
                            border: Border.all(
                              color: isRecording
                                  ? AppColors.statusRed.withAlpha(120)
                                  : theme.colorScheme.outline.withAlpha(55),
                            ),
                          ),
                          child: Icon(
                            isRecording ? Icons.mic : Icons.mic_none,
                            color: isRecording
                                ? AppColors.statusRed
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    const SizedBox(width: 6),
                    if (isRunning)
                      SizedBox(
                        width: 52,
                        height: 48,
                        child: IconButton.filled(
                          onPressed: provider.cancelAgent,
                          icon: const Icon(Icons.stop),
                          iconSize: 20,
                          style: IconButton.styleFrom(
                            backgroundColor: AppColors.statusRed,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(AppRadii.xl),
                            ),
                          ),
                        ),
                      )
                    else
                      SizedBox(
                        width: 52,
                        height: 48,
                        child: IconButton.filled(
                          onPressed: _sendMessage,
                          icon: const Icon(Icons.send),
                          iconSize: 20,
                          style: IconButton.styleFrom(
                            backgroundColor: theme.colorScheme.primary,
                            foregroundColor: theme.colorScheme.onPrimary,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(AppRadii.xl),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _PendingAttachmentPreview {
  final MessageContent content;
  final String inputText;
  final String insertedText;
  final bool includeAsContentBlock;

  const _PendingAttachmentPreview({
    required this.content,
    required this.inputText,
    required this.insertedText,
    required this.includeAsContentBlock,
  });
}

class _AnimatedMessageEntry extends StatefulWidget {
  final Widget child;
  final bool animate;

  const _AnimatedMessageEntry({
    super.key,
    required this.child,
    required this.animate,
  });

  @override
  State<_AnimatedMessageEntry> createState() => _AnimatedMessageEntryState();
}

class _AnimatedMessageEntryState extends State<_AnimatedMessageEntry>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
    value: widget.animate ? 0 : 1,
  );
  late final CurvedAnimation _fadeAnimation = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );
  late final CurvedAnimation _slideAnimation = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );
  late final Animation<double> _opacity = _fadeAnimation;
  late final Animation<Offset> _offset = Tween<Offset>(
    begin: const Offset(0, 0.02),
    end: Offset.zero,
  ).animate(_slideAnimation);

  @override
  void initState() {
    super.initState();
    if (widget.animate) {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _slideAnimation.dispose();
    _fadeAnimation.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: FadeTransition(
        opacity: _opacity,
        child: SlideTransition(
          position: _offset,
          child: widget.child,
        ),
      ),
    );
  }
}

class _TypingDots extends StatefulWidget {
  final Color color;

  const _TypingDots({required this.color});

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 12,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(3, (index) {
              final phase = (_controller.value + index * 0.16) % 1;
              final lift = math.sin(phase * math.pi).clamp(0.0, 1.0);
              return Transform.translate(
                offset: Offset(0, -2 * lift),
                child: Container(
                  width: 6,
                  height: 6,
                  margin: EdgeInsets.only(right: index == 2 ? 0 : 5),
                  decoration: BoxDecoration(
                    color: widget.color.withAlpha(120 + (lift * 55).round()),
                    shape: BoxShape.circle,
                  ),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}
