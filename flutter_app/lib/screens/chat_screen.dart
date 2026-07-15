import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import '../app.dart';
import '../constants.dart';
import '../models/chat_models.dart';
import '../models/provider_profile.dart';
import '../models/workspace_import_receipt.dart';
import '../providers/chat_provider.dart';
import '../services/preferences_service.dart';
import '../services/current_session_search.dart';
import '../services/file_attachment_service.dart';
import '../services/memory_service.dart';
import '../services/llm_service.dart';
import '../services/native_bridge.dart';
import '../services/chat_render_window.dart';
import '../services/shared_content.dart';
import '../services/tools/tool_policy.dart';
import '../services/usage_summary_service.dart';
import '../services/voice_input_state.dart';
import '../layout/foldable_layout.dart';
import '../widgets/streaming_text.dart';
import '../widgets/reasoning_text_panel.dart';
import '../widgets/tool_call_card.dart';
import '../widgets/agent_status_bar.dart';
import '../widgets/compare_view.dart';
import '../services/tts_service.dart';
import '../services/whisper_service.dart';
import 'artifact_preview_screen.dart';
import 'agent_run_center_screen.dart';
import 'full_response_screen.dart';
import 'dashboard_screen.dart';
import 'model_api_settings_screen.dart';
import 'settings_screen.dart';
import 'chat_sessions_screen.dart';
import 'terminal_screen.dart';
import '../l10n/app_strings.dart';

@visibleForTesting
bool isInteractiveChatLifecycle(AppLifecycleState? state) =>
    state == AppLifecycleState.resumed;

enum _NativeSpeechOutcome {
  recognized,
  empty,
  unavailable,
  busy,
  stale,
  timedOut,
  failed,
}

const _defaultNewChatModelGroupSelection = '__default_provider_profile__';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  static const int _initialRenderMessageWindow = 180;
  static const int _loadOlderMessageIncrement = 120;

  final _inputController = TextEditingController();
  final _sessionSearchController = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();
  final stt.SpeechToText _speech = stt.SpeechToText();
  final TtsService _tts = TtsService();
  final WhisperService _whisper = WhisperService();
  final VoiceInputStateMachine _voiceInput = VoiceInputStateMachine();
  Timer? _voiceElapsedTicker;
  DateTime? _voiceStartedAt;
  final SharedContentPreparer _sharedContentPreparer =
      const SharedContentPreparer();
  final UsageSummaryService _usageSummaryService = const UsageSummaryService();
  bool _showScrollToBottom = false;
  bool _approvalSurfaceEstablished = false;
  bool _approvalDialogRetirementScheduled = false;
  bool _appInBackground = false;
  bool _lifecycleSynced = false;
  ToolApprovalRequest? _shownApprovalRequest;
  DialogRoute<void>? _approvalDialogRoute;
  final List<MessageContent> _pendingAttachments = [];
  final List<_PendingAttachmentPreview> _pendingAttachmentPreviews = [];
  final Set<String> _workspaceImportsBeingCommitted = {};
  final Set<String> _seenMessageAnimationIds = {};
  String? _seenAnimationSessionId;
  bool _queueExpanded = false;
  bool _backgroundTasksExpanded = false;
  bool _userHasScrolledUp = false;
  bool _userIsActivelyScrolling = false;
  bool _agentJustCompleted = false;
  bool _isCompensatingScroll = false;
  bool _scrollCompensationScheduled = false;
  bool _loadOlderScrollCompensationScheduled = false;
  double? _lastMaxScrollExtent;
  String? _trackedAgentSessionId;
  bool _trackedAgentWasActive = false;
  ChatRenderWindowState _renderWindowState =
      ChatRenderWindowState.initial(_initialRenderMessageWindow);
  String? _renderWindowSessionId;
  int? _highlightedSearchMessageIndex;
  final Map<int, GlobalKey> _messageKeys = {};

  bool get _isListening => _voiceInput.isListening;
  bool get _isWhisperRecording => _voiceInput.isWhisperRecording;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_handleScroll);
    _tts.addListener(_onTtsStateChanged);
    NativeBridge.setShareIntentHandler(_handleSharedContent);
    _initSpeech();
  }

  void _onTtsStateChanged() {
    if (mounted) setState(() {});
  }

  String _briefError(Object error) {
    final text = error.toString().replaceFirst('Exception: ', '');
    return text.length > 160 ? '${text.substring(0, 160)}...' : text;
  }

  Future<void> _showContextSummaryDialog() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => Consumer<ChatProvider>(
        builder: (_, provider, __) {
          final summary = provider.currentContextSummary;
          return AlertDialog(
            title: const Text(AppStrings.contextSummary),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: summary == null
                  ? const Text(AppStrings.contextSummaryNone)
                  : SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            AppStrings.contextSummaryCoverage(
                              summary.coveredMessageCount,
                              summary.sourceEstimatedTokens,
                            ),
                            style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                                  color: Theme.of(ctx)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                          ),
                          const SizedBox(height: 12),
                          SelectableText(summary.text),
                        ],
                      ),
                    ),
            ),
            actions: [
              if (summary != null)
                TextButton(
                  onPressed: () async {
                    final confirmed = await showDialog<bool>(
                      context: ctx,
                      builder: (confirmCtx) => AlertDialog(
                        title: const Text(AppStrings.contextSummaryClear),
                        content: const Text(
                          AppStrings.contextSummaryClearConfirm,
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(confirmCtx, false),
                            child: const Text(AppStrings.cancel),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(confirmCtx, true),
                            child: const Text(AppStrings.confirm),
                          ),
                        ],
                      ),
                    );
                    if (confirmed != true) return;
                    await provider.clearCurrentContextSummary();
                  },
                  child: const Text(AppStrings.contextSummaryClear),
                ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text(AppStrings.close),
              ),
            ],
          );
        },
      ),
    );
  }

  void _scheduleToolApprovalDialog(ToolApprovalRequest? request) {
    if (request == null) {
      _retireToolApprovalDialog();
      return;
    }
    if (_shownApprovalRequest != null) {
      if (_shownApprovalRequest?.operationId != request.operationId) {
        _retireToolApprovalDialog();
      }
      return;
    }
    if (_appInBackground) {
      return;
    }
    _approvalSurfaceEstablished = false;
    _shownApprovalRequest = request;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final provider = context.read<ChatProvider>();
      if (_shownApprovalRequest?.operationId != request.operationId ||
          provider.pendingApproval?.operationId != request.operationId) {
        _approvalSurfaceEstablished = false;
        _shownApprovalRequest = null;
        return;
      }
      final navigator = Navigator.of(context, rootNavigator: true);
      final route = DialogRoute<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => _buildToolApprovalDialog(ctx, request),
      );
      _approvalDialogRoute = route;
      final dialog = navigator.push(route);
      _approvalSurfaceEstablished = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _appInBackground) return;
        final provider = context.read<ChatProvider>();
        if (provider.pendingApproval?.operationId == request.operationId &&
            identical(_approvalDialogRoute, route) &&
            _approvalSurfaceEstablished) {
          provider.confirmAppResumedApprovalSurface(
            approvalId: request.operationId,
          );
        }
      });
      await dialog;
      if (!mounted) return;
      final currentProvider = context.read<ChatProvider>();
      if (currentProvider.pendingApproval?.operationId == request.operationId) {
        currentProvider.resolveToolApproval(
          operationId: request.operationId,
          approved: false,
        );
      }
      if (!identical(_approvalDialogRoute, route)) return;
      _approvalDialogRoute = null;
      _approvalDialogRetirementScheduled = false;
      _approvalSurfaceEstablished = false;
      _shownApprovalRequest = null;
      setState(() {});
    });
  }

  void _retireToolApprovalDialog() {
    _approvalSurfaceEstablished = false;
    final route = _approvalDialogRoute;
    if (route == null) {
      _shownApprovalRequest = null;
      return;
    }
    if (_approvalDialogRetirementScheduled) return;
    _approvalDialogRetirementScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(_approvalDialogRoute, route)) return;
      final navigator = route.navigator;
      if (navigator != null && route.isActive) {
        navigator.removeRoute(route);
        return;
      }
      _approvalDialogRoute = null;
      _approvalDialogRetirementScheduled = false;
      _shownApprovalRequest = null;
      setState(() {});
    });
  }

  Widget _buildToolApprovalDialog(
    BuildContext dialogContext,
    ToolApprovalRequest request,
  ) {
    final provider = context.read<ChatProvider>();
    final riskColor = _riskColor(request.risk);
    final arguments = _formatToolArguments(request);
    final theme = Theme.of(dialogContext);
    return PopScope(
      canPop: false,
      child: AlertDialog(
        titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
        title: Row(
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
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
            ],
          ),
        ),
        actions: [
          TextButton(
            key: ValueKey('tool-approval-deny:${request.operationId}'),
            onPressed: () {
              provider.resolveToolApproval(
                operationId: request.operationId,
                approved: false,
              );
              Navigator.pop(dialogContext);
            },
            child: const Text(AppStrings.toolApprovalDeny),
          ),
          OutlinedButton(
            key: ValueKey(
              'tool-approval-allow-session:${request.operationId}',
            ),
            onPressed: () {
              provider.resolveToolApproval(
                operationId: request.operationId,
                approved: true,
                rememberForSession: true,
              );
              Navigator.pop(dialogContext);
            },
            child: const Text(AppStrings.toolApprovalAllowSession),
          ),
          FilledButton(
            key: ValueKey(
              'tool-approval-allow-once:${request.operationId}',
            ),
            onPressed: () {
              provider.resolveToolApproval(
                operationId: request.operationId,
                approved: true,
              );
              Navigator.pop(dialogContext);
            },
            child: const Text(AppStrings.toolApprovalAllowOnce),
          ),
        ],
      ),
    );
  }

  String _formatToolArguments(ToolApprovalRequest request) {
    if (request.toolName == 'set_env_var') {
      final safe = ToolUseContent.sanitizedInput(
        request.toolName,
        request.arguments,
      );
      try {
        return const JsonEncoder.withIndent('  ').convert(safe);
      } catch (_) {
        return '{"name":"invalid","value":"${ToolUseContent.redactedSecretValue}"}';
      }
    }
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
            if (mounted && _voiceInput.route == VoiceInputRoute.plugin) {
              setState(() => _voiceInput.cancel());
            }
          }
        },
        onError: (error) {
          debugPrint('Speech error: ${error.errorMsg}');
          if (mounted && _voiceInput.route == VoiceInputRoute.plugin) {
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
    NativeBridge.setShareIntentHandler(null);
    final previousSessionId = _lastSessionId;
    if (previousSessionId != null) {
      try {
        context.read<ChatProvider>().saveDraft(
              previousSessionId,
              _draftWithoutWorkspaceImports(),
            );
      } catch (_) {
        // Provider may already be detached during application teardown.
      }
    }
    unawaited(NativeBridge.cancelSpeechRecognition());
    unawaited(_whisper.cancelRecording());
    unawaited(_discardPendingWorkspaceImports());
    _voiceElapsedTicker?.cancel();
    _speech.cancel();
    _scrollController.removeListener(_handleScroll);
    _inputController.dispose();
    _sessionSearchController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _startListening() async {
    final token = _voiceInput.beginStart();
    if (token == null) return;
    _voiceStartedAt = DateTime.now();
    _voiceElapsedTicker?.cancel();
    _voiceElapsedTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || !_voiceInput.isBusy) {
        _voiceElapsedTicker?.cancel();
        return;
      }
      setState(() {});
    });
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
            setState(() => _voiceInput.fail(token, 'audio_permission_denied'));
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
          listenOptions: stt.SpeechListenOptions(
            listenMode: stt.ListenMode.dictation,
          ),
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
        setState(() => _voiceInput.fail(token, 'native_timeout'));
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
        setState(() => _voiceInput.fail(token, 'whisper_not_configured'));
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
        setState(() => _voiceInput.fail(token, 'recording_unavailable'));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(AppStrings.voiceUnavailable)),
        );
      }
    }
  }

  void _stopWhisperRecording() async {
    if (!_isWhisperRecording) return;
    final token = _voiceInput.activeToken;
    setState(() => _voiceInput.enterStopping(token));
    await Future<void>.delayed(Duration.zero);
    if (!mounted || !_voiceInput.isCurrent(token)) return;
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
    if (text != null && text.isNotEmpty) {
      if (_voiceInput.isCurrent(token)) {
        setState(() => _voiceInput.complete(token));
      }
      _inputController.text += text;
      _inputController.selection = TextSelection.collapsed(
        offset: _inputController.text.length,
      );
    } else {
      if (_voiceInput.isCurrent(token)) {
        setState(() => _voiceInput.fail(token, 'transcription_failed'));
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(AppStrings.transcribeFailed)),
      );
    }
  }

  Future<void> _stopListening() async {
    if (!_voiceInput.isListening) return;
    final token = _voiceInput.activeToken;
    setState(() => _voiceInput.enterStopping(token));
    await Future.wait<void>([
      _speech.stop(),
      NativeBridge.cancelSpeechRecognition(),
      _whisper.cancelRecording(),
    ]);
    if (mounted && _voiceInput.isCurrent(token)) {
      setState(() => _voiceInput.cancel());
    }
  }

  void _cancelVoiceInput() {
    if (!_voiceInput.isBusy) return;
    unawaited(_speech.cancel());
    unawaited(NativeBridge.cancelSpeechRecognition());
    unawaited(_whisper.cancelRecording());
    setState(() => _voiceInput.cancel());
  }

  @override
  void didChangeMetrics() {
    // Only scroll to bottom if keyboard actually appeared
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _lastMaxScrollExtent = null;
      final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
      if (bottomInset > 0 && _scrollController.hasClients) {
        if (!_userHasScrolledUp && _scrollController.offset < 50) {
          _scrollController.jumpTo(0);
        }
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final inBackground = !isInteractiveChatLifecycle(state);
    _appInBackground = inBackground;
    final provider = context.read<ChatProvider>();
    if (inBackground) {
      provider.setAppInBackground(true);
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _appInBackground) return;
      final pending = provider.pendingApproval;
      if (pending == null) {
        _retireToolApprovalDialog();
        provider.confirmAppResumedApprovalSurface();
      } else if (_approvalSurfaceEstablished &&
          _shownApprovalRequest?.operationId == pending.operationId) {
        provider.confirmAppResumedApprovalSurface(
          approvalId: pending.operationId,
        );
      } else {
        if (_shownApprovalRequest != null &&
            _shownApprovalRequest?.operationId != pending.operationId) {
          _retireToolApprovalDialog();
        }
        setState(() {});
      }
    });
  }

  String? _lastSessionId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_lifecycleSynced) {
      _lifecycleSynced = true;
      final state = WidgetsBinding.instance.lifecycleState;
      final inBackground = !isInteractiveChatLifecycle(state);
      _appInBackground = inBackground;
      final provider = context.read<ChatProvider>();
      if (inBackground) {
        provider.setAppInBackground(true);
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _appInBackground) return;
          if (provider.pendingApproval == null) {
            provider.confirmAppResumedApprovalSurface();
          }
        });
      }
    }
    _syncDraftForSession();
  }

  void _syncDraftForSession() {
    final provider = context.read<ChatProvider>();
    final currentId = provider.currentSession?.id;
    if (currentId != null && currentId != _lastSessionId) {
      if (_lastSessionId != null) {
        provider.saveDraft(_lastSessionId!, _draftWithoutWorkspaceImports());
      }
      unawaited(_discardPendingWorkspaceImports());
      _pendingAttachments.clear();
      _pendingAttachmentPreviews.clear();
      _lastSessionId = currentId;
      _resetScrollTrackingForSession();
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

  Future<void> _sendMessage() async {
    final text = _inputController.text.trim();
    final attachments = List<MessageContent>.from(_pendingAttachments);
    final receipts = _pendingAttachmentPreviews
        .map((preview) => preview.workspaceImportReceipt)
        .whereType<WorkspaceImportReceipt>()
        .toList(growable: false);
    if (text.isEmpty && attachments.isEmpty) return;
    HapticFeedback.lightImpact();
    final provider = context.read<ChatProvider>();
    _workspaceImportsBeingCommitted.addAll(
      receipts.map((receipt) => receipt.operationId),
    );
    final committed = await provider.sendMessageWithWorkspaceImports(
      text,
      attachments: attachments,
      workspaceImports: receipts,
    );
    _workspaceImportsBeingCommitted.removeAll(
      receipts.map((receipt) => receipt.operationId),
    );
    if (!committed) {
      if (!mounted) {
        for (final receipt in receipts) {
          unawaited(
            NativeBridge.discardWorkspaceImport(receipt).catchError((_) {}),
          );
        }
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _inputController.clear();
      _pendingAttachments.clear();
      _pendingAttachmentPreviews.clear();
    });
    if (provider.currentSession != null) {
      provider.saveDraft(provider.currentSession!.id, '');
    }
  }

  Future<void> _createNewChat() async {
    final provider = context.read<ChatProvider>();
    final groups = provider.modelGroups;
    String? modelGroupId;
    if (groups.isNotEmpty) {
      final selected = await _showModelGroupPicker(groups);
      if (!mounted || selected == null) return;
      if (selected != _defaultNewChatModelGroupSelection) {
        modelGroupId = selected;
      }
    }
    await provider.createSession(modelGroupId: modelGroupId);
  }

  Future<String?> _showModelGroupPicker(List<ModelGroup> groups) {
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text(AppStrings.selectModelGroup),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                leading: const Icon(Icons.tune),
                title: const Text(AppStrings.defaultModelGroup),
                subtitle: const Text(AppStrings.defaultModelGroupSubtitle),
                onTap: () => Navigator.pop(
                  dialogContext,
                  _defaultNewChatModelGroupSelection,
                ),
              ),
              for (final group in groups)
                ListTile(
                  leading: const Icon(Icons.account_tree_outlined),
                  title: Text(
                    group.displayName,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    AppStrings.modelGroupFallbackCount(
                      group.fallbackTargets
                          .where((target) => target.enabled)
                          .length,
                    ),
                  ),
                  onTap: () => Navigator.pop(dialogContext, group.id),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text(AppStrings.cancel),
          ),
        ],
      ),
    );
  }

  Future<void> _handleSharedContent(SharedContent content) async {
    if (!mounted || !content.hasPayload) return;
    final prepared = await _sharedContentPreparer.prepare(content);
    if (!mounted) {
      for (final attachment in prepared.attachments) {
        final receipt = attachment.workspaceImportReceipt;
        if (receipt != null) {
          unawaited(
            NativeBridge.discardWorkspaceImport(receipt).catchError((_) {}),
          );
        }
      }
      return;
    }

    final plan = SharedContentImportPlan.fromPrepared(prepared);
    if (!plan.createDraft) {
      if (plan.showFeedback) {
        _showShareImportSnack(prepared.warnings, contentReady: false);
      }
      return;
    }

    await _discardPendingWorkspaceImports();
    if (!mounted) {
      for (final attachment in prepared.attachments) {
        final receipt = attachment.workspaceImportReceipt;
        if (receipt != null) {
          unawaited(
            NativeBridge.discardWorkspaceImport(receipt).catchError((_) {}),
          );
        }
      }
      return;
    }
    final provider = context.read<ChatProvider>();
    final session = await provider.createSession();
    if (!mounted) {
      for (final attachment in prepared.attachments) {
        final receipt = attachment.workspaceImportReceipt;
        if (receipt != null) {
          unawaited(
            NativeBridge.discardWorkspaceImport(receipt).catchError((_) {}),
          );
        }
      }
      return;
    }

    setState(() {
      _lastSessionId = session.id;
      _pendingAttachments.clear();
      _pendingAttachmentPreviews.clear();
      _inputController.text = prepared.draftText;
      _inputController.selection = TextSelection.collapsed(
        offset: _inputController.text.length,
      );
    });

    final previews = <_PendingAttachmentPreview>[];
    final contentBlocks = <MessageContent>[];
    for (final attachment in prepared.attachments) {
      final insertedText = _appendAttachmentText(attachment.inputText);
      if (attachment.includeAsContentBlock) {
        contentBlocks.add(attachment.content);
      }
      previews.add(_PendingAttachmentPreview(
        content: attachment.content,
        inputText: attachment.inputText,
        insertedText: insertedText,
        includeAsContentBlock: attachment.includeAsContentBlock,
        workspaceImportReceipt: attachment.workspaceImportReceipt,
      ));
    }

    if (!mounted) return;
    setState(() {
      _pendingAttachments.addAll(contentBlocks);
      _pendingAttachmentPreviews.addAll(previews);
    });
    provider.saveDraft(session.id, _inputController.text);
    _focusNode.requestFocus();
    if (plan.showFeedback) _showShareImportSnack(prepared.warnings);
  }

  void _showShareImportSnack(
    List<String> warnings, {
    bool contentReady = true,
  }) {
    if (!mounted) return;
    final warningText = warnings.take(2).join('；');
    final message = contentReady
        ? warnings.isEmpty
            ? AppStrings.sharedContentReady
            : '${AppStrings.sharedContentReady}；$warningText'
        : warningText.isEmpty
            ? AppStrings.shareFailed
            : warningText;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _handleScroll() {
    if (!_scrollController.hasClients || _isCompensatingScroll) return;
    _updateScrollState();
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (!_scrollController.hasClients || _isCompensatingScroll) return false;
    if (notification is UserScrollNotification) {
      if (notification.direction == ScrollDirection.idle) {
        _userIsActivelyScrolling = false;
      } else {
        _userIsActivelyScrolling = true;
        if (notification.direction == ScrollDirection.forward) {
          _updateScrollState(userScrolledAway: true);
          return false;
        }
      }
    }
    if (notification is ScrollUpdateNotification ||
        notification is ScrollEndNotification ||
        notification is UserScrollNotification) {
      _updateScrollState();
    }
    return false;
  }

  void _updateScrollState({bool userScrolledAway = false}) {
    if (!_scrollController.hasClients) return;
    final offset = _scrollController.offset;
    _lastMaxScrollExtent ??= _scrollController.position.maxScrollExtent;
    final shouldShow = _showScrollToBottom ? offset > 120 : offset > 300;
    final atBottom = offset < 50;
    final nextUserHasScrolledUp = atBottom
        ? false
        : (userScrolledAway && offset > 100)
            ? true
            : _userHasScrolledUp;
    final nextAgentJustCompleted = atBottom ? false : _agentJustCompleted;
    if (shouldShow == _showScrollToBottom &&
        nextUserHasScrolledUp == _userHasScrolledUp &&
        nextAgentJustCompleted == _agentJustCompleted) {
      return;
    }
    setState(() {
      _showScrollToBottom = shouldShow;
      _userHasScrolledUp = nextUserHasScrolledUp;
      _agentJustCompleted = nextAgentJustCompleted;
    });
  }

  void _scheduleScrollExtentCompensation() {
    if (_scrollCompensationScheduled) return;
    _scrollCompensationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollCompensationScheduled = false;
      _compensateScrollExtentChange();
    });
  }

  void _scheduleLoadOlderScrollCompensation({
    required double previousMaxScrollExtent,
    required double previousOffset,
  }) {
    if (_loadOlderScrollCompensationScheduled) return;
    _loadOlderScrollCompensationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadOlderScrollCompensationScheduled = false;
      if (!mounted || !_scrollController.hasClients) return;
      final position = _scrollController.position;
      final target = compensatedScrollOffsetAfterPrepend(
        previousMaxScrollExtent: previousMaxScrollExtent,
        previousOffset: previousOffset,
        currentMinScrollExtent: position.minScrollExtent,
        currentMaxScrollExtent: position.maxScrollExtent,
      );
      if (target == null) return;
      _isCompensatingScroll = true;
      _scrollController.jumpTo(target);
      _isCompensatingScroll = false;
      _lastMaxScrollExtent = position.maxScrollExtent;
      _updateScrollState();
    });
  }

  void _compensateScrollExtentChange() {
    if (!mounted || !_scrollController.hasClients || _isCompensatingScroll) {
      return;
    }
    final position = _scrollController.position;
    final currentMax = position.maxScrollExtent;
    final previousMax = _lastMaxScrollExtent;
    final provider = context.read<ChatProvider>();
    final isStreaming = provider.agentStatus == AgentStatus.streaming;
    if (previousMax != null &&
        _userHasScrolledUp &&
        isStreaming &&
        position.pixels > 50 &&
        !_userIsActivelyScrolling) {
      final delta = currentMax - previousMax;
      if (delta > 0.5) {
        final target = (position.pixels + delta)
            .clamp(position.minScrollExtent, currentMax)
            .toDouble();
        _isCompensatingScroll = true;
        _scrollController.jumpTo(target);
        _isCompensatingScroll = false;
      }
    }
    _lastMaxScrollExtent = currentMax;
    _updateScrollState();
  }

  void _trackAgentCompletion({
    required String? sessionId,
    required bool isActive,
    required bool completed,
  }) {
    if (sessionId != _trackedAgentSessionId) {
      _trackedAgentSessionId = sessionId;
      _trackedAgentWasActive = isActive;
      _agentJustCompleted = false;
      return;
    }
    if (_trackedAgentWasActive &&
        completed &&
        _userHasScrolledUp &&
        _scrollController.hasClients &&
        _scrollController.offset >= 50) {
      _agentJustCompleted = true;
      _showScrollToBottom = true;
    }
    _trackedAgentWasActive = isActive;
  }

  void _resetScrollTrackingForSession() {
    _showScrollToBottom = false;
    _userHasScrolledUp = false;
    _userIsActivelyScrolling = false;
    _agentJustCompleted = false;
    _isCompensatingScroll = false;
    _scrollCompensationScheduled = false;
    _loadOlderScrollCompensationScheduled = false;
    _lastMaxScrollExtent = null;
    _trackedAgentSessionId = null;
    _trackedAgentWasActive = false;
    _highlightedSearchMessageIndex = null;
    _messageKeys.clear();
    _renderWindowState = _renderWindowState.reset(_initialRenderMessageWindow);
    _renderWindowSessionId = null;
  }

  void _showMoreHistory(int totalMessageCount) {
    final previousMaxScrollExtent = _scrollController.hasClients
        ? _scrollController.position.maxScrollExtent
        : 0.0;
    final previousOffset =
        _scrollController.hasClients ? _scrollController.offset : 0.0;
    setState(() {
      _renderWindowState = _renderWindowState.loadOlder(
        totalCount: totalMessageCount,
        increment: _loadOlderMessageIncrement,
      );
    });
    if (_scrollController.hasClients) {
      _scheduleLoadOlderScrollCompensation(
        previousMaxScrollExtent: previousMaxScrollExtent,
        previousOffset: previousOffset,
      );
    }
  }

  Future<void> _showSessionUsageDialog() async {
    final provider = context.read<ChatProvider>();
    final session = provider.currentSession;
    final summary = _usageSummaryService.forSession(session);
    await _showUsageSummaryDialog(
      title: AppStrings.sessionUsageSummary,
      subtitle: session?.title ?? AppStrings.appName,
      summary: summary,
    );
  }

  Future<void> _showRemoteAgentSessionDialog() async {
    final provider = context.read<ChatProvider>();
    final currentlyEnabled = provider.currentSessionUsesRemoteAgent;
    if (!currentlyEnabled && !provider.remoteAgentAvailable) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先在设置中配置并授权远程 Agent。')),
      );
      return;
    }
    final enable = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text(AppStrings.sessionRemoteAgent),
        content: Text(
          currentlyEnabled
              ? '关闭后，本对话将恢复使用本地配置的模型流程。'
              : '开启后，本对话文本会发送到你已授权的外部服务。其他对话和本地模型/工具流程不受影响。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text(AppStrings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, !currentlyEnabled),
            child: Text(currentlyEnabled ? '关闭' : '为本对话开启'),
          ),
        ],
      ),
    );
    if (enable == null || !mounted) return;
    final changed = await provider.setCurrentSessionRemoteAgentEnabled(enable);
    if (!changed && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前无法更改远程 Agent 选择。')),
      );
    }
  }

  Future<void> _showUsageSummaryDialog({
    required String title,
    required String subtitle,
    required UsageSummary summary,
  }) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              subtitle,
              style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 12),
            _usageRow(ctx, AppStrings.usageMessages,
                '${summary.messagesWithUsage}/${summary.messageCount}'),
            _usageRow(ctx, AppStrings.usageInputTokens,
                _formatTokenCount(summary.inputTokens)),
            _usageRow(ctx, AppStrings.usageOutputTokens,
                _formatTokenCount(summary.outputTokens)),
            _usageRow(ctx, AppStrings.usageTotalTokens,
                _formatTokenCount(summary.totalTokens)),
            _usageRow(
              ctx,
              AppStrings.usageCacheTokens,
              summary.hasCacheUsage
                  ? [
                      if (summary.cacheReadInputTokens != null)
                        'read ${_formatTokenCount(summary.cacheReadInputTokens!)}',
                      if (summary.cacheCreationInputTokens != null)
                        'create ${_formatTokenCount(summary.cacheCreationInputTokens!)}',
                    ].join(' · ')
                  : AppStrings.usageUnavailable,
            ),
            _usageRow(
              ctx,
              AppStrings.usageCost,
              AppStrings.usageCostUnavailable,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(AppStrings.close),
          ),
        ],
      ),
    );
  }

  Widget _usageRow(BuildContext context, String label, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  String _formatTokenCount(int value) {
    if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(2)}M';
    if (value >= 1000) return '${(value / 1000).toStringAsFixed(1)}K';
    return value.toString();
  }

  Future<void> _showCurrentSessionSearch() async {
    final provider = context.read<ChatProvider>();
    final messages = provider.currentSession?.messages ?? const <ChatMessage>[];
    const search = CurrentSessionSearch();
    var results = search.search(messages, _sessionSearchController.text);

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        final maxHeight = MediaQuery.sizeOf(sheetContext).height * 0.72;
        return StatefulBuilder(
          builder: (context, setSheetState) {
            void updateQuery(String value) {
              setSheetState(() {
                results = search.search(messages, value);
              });
            }

            return SafeArea(
              child: SizedBox(
                height: math.min(560.0, maxHeight),
                child: Padding(
                  padding: EdgeInsets.only(
                    left: 16,
                    right: 16,
                    bottom: 16 + MediaQuery.viewInsetsOf(context).bottom,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        AppStrings.searchCurrentConversation,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _sessionSearchController,
                        autofocus: true,
                        textInputAction: TextInputAction.search,
                        decoration: InputDecoration(
                          hintText: AppStrings.searchMessagesHint,
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: _sessionSearchController.text.isEmpty
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.close),
                                  onPressed: () {
                                    _sessionSearchController.clear();
                                    updateQuery('');
                                  },
                                ),
                          border: const OutlineInputBorder(),
                        ),
                        onChanged: updateQuery,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _sessionSearchController.text.trim().isEmpty
                            ? AppStrings.searchMessagesHint
                            : results.isEmpty
                                ? AppStrings.noSearchResults
                                : AppStrings.searchResultCount(results.length),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: results.isEmpty
                            ? const Center(
                                child: Text(AppStrings.noSearchResults),
                              )
                            : ListView.separated(
                                itemCount: results.length,
                                separatorBuilder: (_, __) =>
                                    const Divider(height: 1),
                                itemBuilder: (context, index) {
                                  final result = results[index];
                                  return ListTile(
                                    dense: true,
                                    leading: CircleAvatar(
                                      radius: 14,
                                      child: Text('${index + 1}'),
                                    ),
                                    title: Text(
                                      AppStrings.searchResultPosition(
                                        result.messageIndex,
                                      ),
                                    ),
                                    subtitle: Text(
                                      result.preview,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    onTap: () {
                                      Navigator.pop(sheetContext);
                                      _jumpToMessageIndex(
                                        result.messageIndex,
                                        messages.length,
                                      );
                                    },
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _jumpToMessageIndex(int messageIndex, int totalMessageCount) {
    if (totalMessageCount <= 0) return;
    final safeIndex = messageIndex.clamp(0, totalMessageCount - 1).toInt();
    setState(() {
      _highlightedSearchMessageIndex = safeIndex;
      _renderWindowState = _renderWindowState.ensureIncludes(
        totalCount: totalMessageCount,
        messageIndex: safeIndex,
      );
    });
    _scheduleScrollToMessageIndex(safeIndex, totalMessageCount);
  }

  void _scheduleScrollToMessageIndex(int messageIndex, int totalMessageCount) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final contextForKey = _messageKeys[messageIndex]?.currentContext;
      if (contextForKey != null) {
        Scrollable.ensureVisible(
          contextForKey,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          alignment: 0.18,
        );
        _updateScrollState();
        return;
      }

      final position = _scrollController.position;
      final window = _renderWindowState.windowFor(totalMessageCount);
      final target = estimatedReversedListOffsetForMessageIndex(
        window: window,
        messageIndex: messageIndex,
        maxScrollExtent: position.maxScrollExtent,
      );
      _isCompensatingScroll = true;
      _scrollController.jumpTo(
        target.clamp(position.minScrollExtent, position.maxScrollExtent),
      );
      _isCompensatingScroll = false;

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final contextForKey = _messageKeys[messageIndex]?.currentContext;
        if (contextForKey == null) return;
        Scrollable.ensureVisible(
          contextForKey,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          alignment: 0.18,
        );
        _updateScrollState();
      });
    });
  }

  _MessageWindow _messageWindowFor(List<ChatMessage> messages) {
    final window = _renderWindowState.windowFor(messages.length);
    return _MessageWindow(
      messages: messages.sublist(
        window.startIndex,
        window.endIndexExclusive,
      ),
      startIndex: window.startIndex,
      hiddenBeforeCount: window.hiddenBeforeCount,
    );
  }

  void _scrollToBottom() {
    HapticFeedback.lightImpact();
    debugPrint(
      '[SCROLL] _scrollToBottom called, offset='
      '${_scrollController.hasClients ? _scrollController.offset : 'no-client'}',
    );
    if (!_scrollController.hasClients) return;
    _userHasScrolledUp = false;
    _userIsActivelyScrolling = false;
    _agentJustCompleted = false;
    unawaited(
      _scrollController
          .animateTo(
        0,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      )
          .then((_) {
        if (mounted) {
          setState(() => _showScrollToBottom = false);
        }
      }).catchError((_) {}),
    );
  }

  Future<void> _showCommandSurface() async {
    final provider = context.read<ChatProvider>();
    final parentMedia = MediaQuery.of(context);
    final anchorLayout = FoldableLayout.resolve(
      parentMedia.size,
      parentMedia.displayFeatures,
      bottomInset: parentMedia.viewInsets.bottom,
    );
    final hostRect = _globalHostRect();
    final selected = await showGeneralDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.black54,
      anchorPoint:
          hostRect.isEmpty ? anchorLayout.primary.center : hostRect.center,
      transitionDuration: parentMedia.disableAnimations
          ? Duration.zero
          : const Duration(milliseconds: 180),
      pageBuilder: (sheetContext, _, __) {
        return LayoutBuilder(
          builder: (sheetContext, constraints) {
            final media = MediaQuery.of(sheetContext);
            final routeSize = _modalRouteSize(constraints, media);
            final bottomInset = media.viewInsets.bottom > 0
                ? media.viewInsets.bottom
                : parentMedia.viewInsets.bottom;
            final routeIsFullSize =
                (routeSize.width - parentMedia.size.width).abs() < 1 &&
                    (routeSize.height - parentMedia.size.height).abs() < 1;
            final displayFeatures =
                media.displayFeatures.isNotEmpty || !routeIsFullSize
                    ? media.displayFeatures
                    : parentMedia.displayFeatures;
            final viewInsetsAlreadyApplied = bottomInset > 0 &&
                routeSize.height <= parentMedia.size.height - bottomInset + 1;
            final hostPrimary = displayFeatures.isEmpty
                ? _hostPrimaryRectForRoute(
                    routeSize: routeSize,
                    windowSize: parentMedia.size,
                    hostRect: hostRect,
                  )
                : null;
            final foldable = FoldableLayout.resolve(
              routeSize,
              displayFeatures,
              bottomInset: viewInsetsAlreadyApplied ? 0 : bottomInset,
            );
            final primary = _usableCommandPrimaryRect(
              routeSize: routeSize,
              primary: hostPrimary ?? foldable.primary,
              posture: foldable.posture,
              bottomInset: bottomInset,
              viewInsetsAlreadyApplied: viewInsetsAlreadyApplied,
            );
            final surfaceRect = _commandSurfaceRect(
              routeSize: routeSize,
              primary: primary,
            );
            return SizedBox(
              width: routeSize.width,
              height: routeSize.height,
              child: Stack(
                children: [
                  Positioned.fromRect(
                    rect: surfaceRect,
                    child: _ChatCommandSurface(
                      key: const ValueKey('chat-command-surface'),
                      groups: _commandGroupsFor(provider),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
      transitionBuilder: (context, animation, _, child) {
        if (parentMedia.disableAnimations) return child;
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(opacity: curved, child: child);
      },
    );
    if (selected == null || !mounted) return;
    _handleCommandAction(selected);
  }

  Rect _globalHostRect() {
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) {
      return Rect.zero;
    }
    return renderObject.localToGlobal(Offset.zero) & renderObject.size;
  }

  Size _modalRouteSize(BoxConstraints constraints, MediaQueryData media) {
    final width = constraints.hasBoundedWidth
        ? math.min(constraints.maxWidth, media.size.width)
        : media.size.width;
    final height = constraints.hasBoundedHeight
        ? math.min(constraints.maxHeight, media.size.height)
        : media.size.height;
    return Size(width, height);
  }

  Rect? _hostPrimaryRectForRoute({
    required Size routeSize,
    required Size windowSize,
    required Rect hostRect,
  }) {
    if (hostRect.isEmpty) return null;
    final hostMatchesWindow = (hostRect.width - windowSize.width).abs() < 1 &&
        (hostRect.height - windowSize.height).abs() < 1;
    if (hostMatchesWindow) return null;
    final routeMatchesHost = (routeSize.width - hostRect.width).abs() < 1 &&
        (routeSize.height - hostRect.height).abs() < 1;
    if (routeMatchesHost) {
      return Offset.zero & routeSize;
    }
    final routeMatchesWindow = (routeSize.width - windowSize.width).abs() < 1 &&
        (routeSize.height - windowSize.height).abs() < 1;
    if (routeMatchesWindow) {
      return hostRect.intersect(Offset.zero & routeSize);
    }
    return null;
  }

  Rect _commandSurfaceRect({
    required Size routeSize,
    required Rect primary,
  }) {
    final routeRect = Offset.zero & routeSize;
    final safePrimary = primary.intersect(routeRect);
    if (safePrimary.isEmpty) return Rect.zero;
    final width = math.min(560.0, safePrimary.width);
    final height = safePrimary.height * 0.88;
    return Rect.fromLTWH(
      safePrimary.left + (safePrimary.width - width) / 2,
      safePrimary.bottom - height,
      width,
      height,
    );
  }

  Rect _usableCommandPrimaryRect({
    required Size routeSize,
    required Rect primary,
    required FoldablePosture posture,
    required double bottomInset,
    required bool viewInsetsAlreadyApplied,
  }) {
    final routeRect = Offset.zero & routeSize;
    var usable = primary.intersect(routeRect);
    if (usable.isEmpty) return Rect.zero;
    final shouldClipIme = bottomInset > 0 &&
        !viewInsetsAlreadyApplied &&
        posture != FoldablePosture.tabletop;
    if (!shouldClipIme) return usable;
    final keyboardTop = (routeSize.height - bottomInset)
        .clamp(0.0, routeSize.height)
        .toDouble();
    return usable.intersect(
      Rect.fromLTRB(0, 0, routeSize.width, keyboardTop),
    );
  }

  List<_ChatCommandGroup> _commandGroupsFor(ChatProvider provider) {
    final hasSession = provider.currentSession != null;
    final hasMessages = provider.currentSession?.messages.isNotEmpty == true;
    return [
      _ChatCommandGroup(
        label: '对话',
        actions: [
          if (hasMessages)
            const _ChatCommandAction(
              id: 'regenerate',
              icon: Icons.refresh,
              label: AppStrings.regenerate,
              description: '重新请求最近一条回复',
            ),
          const _ChatCommandAction(
            id: 'compare',
            icon: Icons.compare_arrows,
            label: AppStrings.compareMode,
            description: '用当前对话发起多模型对比',
          ),
          const _ChatCommandAction(
            id: 'context_summary',
            icon: Icons.summarize_outlined,
            label: AppStrings.contextSummary,
            description: '查看或清理当前上下文摘要',
          ),
          if (hasSession)
            const _ChatCommandAction(
              id: 'usage',
              icon: Icons.query_stats,
              label: AppStrings.usageSummary,
              description: '查看本会话 token 用量',
            ),
          const _ChatCommandAction(
            id: 'switch_model',
            icon: Icons.swap_horiz,
            label: AppStrings.switchModel,
            description: '为当前会话选择模型',
          ),
          if (hasSession)
            const _ChatCommandAction(
              id: 'remote_agent',
              icon: Icons.cloud_outlined,
              label: AppStrings.sessionRemoteAgent,
              description: '按会话切换本地或外部 Agent',
            ),
        ],
      ),
      const _ChatCommandGroup(
        label: '工作区与工具',
        actions: [
          _ChatCommandAction(
            id: 'terminal',
            icon: Icons.terminal,
            label: AppStrings.terminal,
            description: '打开本机 Alpine 终端',
          ),
          _ChatCommandAction(
            id: 'dashboard',
            icon: Icons.dashboard_outlined,
            label: AppStrings.dashboard,
            description: '查看本地运行状态',
          ),
          _ChatCommandAction(
            id: 'session_system_prompt',
            icon: Icons.tune,
            label: AppStrings.systemPromptTitle,
            description: '调整当前会话提示词',
          ),
        ],
      ),
      _ChatCommandGroup(
        label: '应用与设置',
        actions: [
          if (hasSession)
            const _ChatCommandAction(
              id: 'session_memory',
              icon: Icons.memory_outlined,
              label: AppStrings.sessionMemory,
              description: '管理当前会话记忆',
            ),
          const _ChatCommandAction(
            id: 'prompt_profiles',
            icon: Icons.badge_outlined,
            label: AppStrings.promptProfiles,
            description: '管理可复用提示词配置',
          ),
          const _ChatCommandAction(
            id: 'system_prompt',
            icon: Icons.psychology,
            label: AppStrings.editSystemPrompt,
            description: '编辑全局系统提示词',
          ),
          const _ChatCommandAction(
            id: 'settings',
            icon: Icons.settings,
            label: AppStrings.settings,
            description: '打开配置和关于信息',
          ),
        ],
      ),
    ];
  }

  void _handleCommandAction(String value) {
    switch (value) {
      case 'settings':
        Navigator.of(context)
            .push(CupertinoPageRoute(builder: (_) => const SettingsScreen()));
      case 'system_prompt':
        _showSystemPromptDialog();
      case 'session_system_prompt':
        _showSessionSystemPromptDialog();
      case 'session_memory':
        _showSessionMemoryDialog();
      case 'prompt_profiles':
        _showPromptProfilesDialog();
      case 'switch_model':
        _showSwitchModelDialog();
      case 'remote_agent':
        _showRemoteAgentSessionDialog();
      case 'regenerate':
        context.read<ChatProvider>().regenerateLastResponse();
      case 'compare':
        _showCompareDialog();
      case 'context_summary':
        _showContextSummaryDialog();
      case 'usage':
        _showSessionUsageDialog();
      case 'terminal':
        Navigator.of(context)
            .push(CupertinoPageRoute(builder: (_) => const TerminalScreen()));
      case 'dashboard':
        Navigator.of(context)
            .push(CupertinoPageRoute(builder: (_) => const DashboardScreen()));
    }
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
            icon: const Icon(Icons.search),
            tooltip: AppStrings.searchCurrentConversation,
            onPressed: _showCurrentSessionSearch,
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: AppStrings.newChat,
            onPressed: () => unawaited(_createNewChat()),
          ),
          IconButton(
            icon: const Icon(Icons.more_vert),
            tooltip: AppStrings.more,
            onPressed: _showCommandSurface,
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, chatConstraints) {
          final hasCompare = context.select<ChatProvider, bool>(
            (provider) =>
                provider.compareResults != null &&
                provider.compareBelongsToCurrentSession,
          );
          final compareWorkspaceMode =
              hasCompare && chatConstraints.maxHeight < 760;
          return Column(
            children: [
              const AgentStatusBar(),
              Consumer<ChatProvider>(
                builder: (_, provider, __) {
                  if (!provider.safeMode) return const SizedBox.shrink();
                  return Material(
                    color: theme.colorScheme.errorContainer,
                    child: SafeArea(
                      bottom: false,
                      child: ListTile(
                        leading: Icon(
                          Icons.health_and_safety_outlined,
                          color: theme.colorScheme.onErrorContainer,
                        ),
                        title: Text(
                          '安全模式已启用',
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: theme.colorScheme.onErrorContainer,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        subtitle: Text(
                          '已跳过自动恢复会话，避免重复打开异常长会话。',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onErrorContainer,
                          ),
                        ),
                        trailing: TextButton(
                          onPressed: provider.exitSafeMode,
                          child: const Text('退出'),
                        ),
                      ),
                    ),
                  );
                },
              ),
              Selector<ChatProvider, AgentRunRecoveryMarker?>(
                selector: (_, provider) => provider.currentInterruptedAgentRun,
                builder: (context, marker, __) {
                  if (marker == null) return const SizedBox.shrink();
                  return _buildInterruptedRunBanner(theme, marker);
                },
              ),
              if (!compareWorkspaceMode)
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
                            int messageVersion,
                            String modelLabel,
                            bool usesExternalExecutionContext,
                            String executionContextLabel,
                          })>(
                        selector: (_, p) => (
                          messages: p.currentSession?.messages ?? [],
                          hasStreaming:
                              p.agentStatus == AgentStatus.streaming ||
                                  p.streamingText.isNotEmpty ||
                                  p.streamingReasoningTotalLength > 0,
                          status: p.agentStatus,
                          sessionId: p.currentSession?.id,
                          messageVersion: p.messageVersion,
                          modelLabel: p.currentSession?.modelOverride != null
                              ? '${p.configuredProfileName} · '
                                  '${p.currentSession!.modelOverride}'
                              : p.configuredModelLabel,
                          usesExternalExecutionContext:
                              p.currentSessionUsesRemoteAgent,
                          executionContextLabel: p.currentExecutionContextLabel,
                        ),
                        builder: (context, data, __) {
                          final messages = data.messages;
                          final hasStreaming = data.hasStreaming;
                          final showTyping =
                              data.status == AgentStatus.thinking &&
                                  !hasStreaming;
                          final agentActive = hasStreaming ||
                              showTyping ||
                              data.status == AgentStatus.thinking ||
                              data.status == AgentStatus.streaming ||
                              data.status == AgentStatus.tooling;
                          _trackAgentCompletion(
                            sessionId: data.sessionId,
                            isActive: agentActive,
                            completed:
                                !agentActive && data.status == AgentStatus.idle,
                          );

                          // Sync draft when session changes via Selector rebuild
                          final currentId = data.sessionId;
                          if (currentId != null &&
                              currentId != _lastSessionId) {
                            _syncDraftForSession();
                          }
                          _primeMessageAnimations(currentId, messages);
                          if (currentId != _renderWindowSessionId) {
                            _renderWindowSessionId = currentId;
                            _renderWindowState = _renderWindowState
                                .reset(_initialRenderMessageWindow);
                          }

                          if (messages.isEmpty &&
                              !hasStreaming &&
                              !showTyping) {
                            return _buildEmptyState(
                              theme,
                              data.modelLabel,
                              maxContentWidth,
                              usesExternalExecutionContext:
                                  data.usesExternalExecutionContext,
                              executionContextLabel: data.executionContextLabel,
                            );
                          }

                          final window = _messageWindowFor(messages);
                          final visibleMessages = window.messages;
                          _retainMessageKeysForWindow(
                            window.startIndex,
                            window.startIndex + visibleMessages.length,
                          );
                          final hasLoadOlder = window.hiddenBeforeCount > 0;
                          final virtualMessageStart = hasLoadOlder ? 1 : 0;
                          final extraItemCount =
                              (hasStreaming ? 1 : 0) + (showTyping ? 1 : 0);
                          final itemCount = visibleMessages.length +
                              virtualMessageStart +
                              extraItemCount;
                          final streamingOrTypingIndex =
                              virtualMessageStart + visibleMessages.length;
                          if (_userHasScrolledUp && hasStreaming) {
                            _scheduleScrollExtentCompensation();
                          }
                          return Stack(
                            children: [
                              SelectionArea(
                                child: NotificationListener<ScrollNotification>(
                                  onNotification: _handleScrollNotification,
                                  child: ListView.builder(
                                    key: const ValueKey('chat-message-list'),
                                    controller: _scrollController,
                                    reverse: true,
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 16, vertical: 12),
                                    itemCount: itemCount,
                                    itemBuilder: (context, index) {
                                      final virtualIndex =
                                          itemCount - 1 - index;
                                      if (virtualIndex ==
                                              streamingOrTypingIndex &&
                                          hasStreaming) {
                                        return Consumer<ChatProvider>(
                                          builder: (_, provider, __) {
                                            return RepaintBoundary(
                                              child: _buildStreamingBubble(
                                                provider.streamingText,
                                                theme,
                                                maxContentWidth,
                                                reasoningText: provider
                                                    .streamingReasoningText,
                                                reasoningTotalLength: provider
                                                    .streamingReasoningTotalLength,
                                                previousRole: messages.isEmpty
                                                    ? null
                                                    : messages.last.role,
                                              ),
                                            );
                                          },
                                        );
                                      }
                                      if (virtualIndex ==
                                              streamingOrTypingIndex &&
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
                                      if (hasLoadOlder && virtualIndex == 0) {
                                        return _buildLoadOlderMessagesAffordance(
                                          theme,
                                          hiddenCount: window.hiddenBeforeCount,
                                          totalMessageCount: messages.length,
                                        );
                                      }
                                      final visibleIndex =
                                          virtualIndex - virtualMessageStart;
                                      final message =
                                          visibleMessages[visibleIndex];
                                      final originalIndex =
                                          originalMessageIndexForVisibleIndex(
                                        windowStartIndex: window.startIndex,
                                        visibleIndex: visibleIndex,
                                      );
                                      final previousRole = visibleIndex > 0
                                          ? visibleMessages[visibleIndex - 1]
                                              .role
                                          : null;
                                      final nextRole = visibleIndex <
                                              visibleMessages.length - 1
                                          ? visibleMessages[visibleIndex + 1]
                                              .role
                                          : null;
                                      final animationId =
                                          _messageAnimationId(message);
                                      final animate = _seenMessageAnimationIds
                                          .add(animationId);
                                      return _AnimatedMessageEntry(
                                        key: ValueKey(animationId),
                                        animate: animate,
                                        child: KeyedSubtree(
                                          key: _keyForMessageIndex(
                                              originalIndex),
                                          child: RepaintBoundary(
                                            child: _buildMessageBubble(
                                              message,
                                              originalIndex,
                                              theme,
                                              maxContentWidth,
                                              messages: messages,
                                              previousRole: previousRole,
                                              nextRole: nextRole,
                                              highlighted: originalIndex ==
                                                  _highlightedSearchMessageIndex,
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
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
                  if (provider.compareResults == null ||
                      !provider.compareBelongsToCurrentSession) {
                    return const SizedBox.shrink();
                  }
                  final ownerSessionId = provider.compareOwnerSessionId!;
                  final compareGeneration =
                      provider.compareOperationGeneration!;
                  return Expanded(
                    child: CompareView(
                      results: provider.compareResults!,
                      isComparing: provider.isComparing,
                      maxPanelHeight: chatConstraints.maxHeight,
                      onDismiss: () => provider.clearCompareResults(
                        ownerSessionId: ownerSessionId,
                        compareGeneration: compareGeneration,
                      ),
                      onUse: (index) =>
                          unawaited(provider.useCompareResult(index)),
                      onCancel: (model) => provider.cancelCompareResult(
                        model,
                        ownerSessionId: ownerSessionId,
                        compareGeneration: compareGeneration,
                      ),
                      onRetry: (model) =>
                          unawaited(provider.retryCompareResult(model)),
                    ),
                  );
                },
              ),
              if (!compareWorkspaceMode)
                Consumer<ChatProvider>(
                  builder: (_, provider, __) {
                    final messages = provider.currentSession?.messages;
                    if (messages == null || messages.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    return _buildQuickPrompts(theme);
                  },
                ),
              if (compareWorkspaceMode)
                Flexible(
                  child: SingleChildScrollView(
                    reverse: true,
                    child: _buildInputArea(theme),
                  ),
                )
              else
                _buildInputArea(theme),
            ],
          );
        },
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

  GlobalKey _keyForMessageIndex(int messageIndex) {
    return _messageKeys.putIfAbsent(
      messageIndex,
      () => GlobalObjectKey('chat-message-$messageIndex'),
    );
  }

  void _retainMessageKeysForWindow(int startIndex, int endIndexExclusive) {
    _messageKeys.removeWhere(
      (index, _) => index < startIndex || index >= endIndexExclusive,
    );
  }

  Widget _buildScrollToBottomButton(ThemeData theme) {
    final showCompletionNotice = _agentJustCompleted && _showScrollToBottom;
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
          child: showCompletionNotice
              ? Material(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(999),
                  elevation: 4,
                  child: InkWell(
                    onTap: _scrollToBottom,
                    borderRadius: BorderRadius.circular(999),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 9,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.keyboard_arrow_down,
                            size: 18,
                            color: theme.colorScheme.onPrimary,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'AI 回复完成 ↓',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.onPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              : FloatingActionButton.small(
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
    ThemeData theme,
    String modelName,
    double maxContentWidth, {
    required bool usesExternalExecutionContext,
    required String executionContextLabel,
  }) {
    const prompts = [
      (
        label: AppStrings.emptyPromptSummarizeCode,
        icon: Icons.description_outlined,
      ),
      (
        label: AppStrings.emptyPromptTranslateText,
        icon: Icons.translate_outlined,
      ),
      (
        label: AppStrings.emptyPromptExplainConcept,
        icon: Icons.psychology_alt_outlined,
      ),
      (
        label: AppStrings.emptyPromptWriteEmail,
        icon: Icons.mail_outline,
      ),
    ];
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: math.min(560.0, maxContentWidth)),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '本地工作区',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '消息、附件和会话记录以这台设备为准。发送后会按当前执行上下文处理。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 18),
              _EmptyStateFactRow(
                icon: usesExternalExecutionContext
                    ? Icons.public
                    : Icons.smartphone,
                label: '执行上下文',
                value: executionContextLabel,
              ),
              const SizedBox(height: 8),
              _EmptyStateFactRow(
                icon: Icons.memory_outlined,
                label: '当前模型',
                value: modelName,
              ),
              const SizedBox(height: 22),
              Text(
                '开始任务',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              DecoratedBox(
                decoration: BoxDecoration(
                  color:
                      theme.colorScheme.surfaceContainerHighest.withAlpha(80),
                  borderRadius: BorderRadius.circular(AppRadii.m),
                ),
                child: Column(
                  children: [
                    for (var index = 0; index < prompts.length; index++) ...[
                      _EmptyStatePromptRow(
                        icon: prompts[index].icon,
                        label: prompts[index].label,
                        onTap: () {
                          _inputController.text = prompts[index].label;
                          _inputController.selection = TextSelection.collapsed(
                            offset: _inputController.text.length,
                          );
                          _focusNode.requestFocus();
                        },
                      ),
                      if (index != prompts.length - 1)
                        Divider(
                          height: 1,
                          indent: 56,
                          color: theme.colorScheme.outline.withAlpha(35),
                        ),
                    ],
                  ],
                ),
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
    bool highlighted = false,
  }) {
    if (message.isSystemNotice) {
      return _buildSystemNotice(message, theme);
    }

    final isUser = message.role == 'user';
    final messageId =
        '${message.timestamp.millisecondsSinceEpoch}_$messageIndex';
    final visibleContent = !isUser && message.isViewingAlternative
        ? <MessageContent>[TextContent(message.textContent)]
        : message.content;

    final bubble = Padding(
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
          if (!isUser && message.assistantError != null)
            _buildAssistantErrorBanner(
              message,
              messageIndex,
              theme,
              maxContentWidth,
            ),
          for (final content in visibleContent)
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

    if (!highlighted) return bubble;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withAlpha(85),
        borderRadius: BorderRadius.circular(AppRadii.l),
        border: Border.all(
          color: theme.colorScheme.secondary.withAlpha(120),
        ),
      ),
      child: bubble,
    );
  }

  Widget _buildInterruptedRunBanner(
    ThemeData theme,
    AgentRunRecoveryMarker marker,
  ) {
    final colors = theme.colorScheme;
    final (subtitle, continueLabel) = switch (marker.recoveryKind) {
      InterruptedRunRecoveryKind.retryModelTurn => (
          marker.hasPersistedToolResults
              ? '工具结果已保存。继续只会恢复模型上下文，不会再次执行工具。'
              : '生成过程没有正常结束。确认后可重试模型回合，不会自动执行工具。',
          '继续',
        ),
      InterruptedRunRecoveryKind.reauthorizeAction => (
          '工具尚未开始，旧授权已失效。继续时必须重新授权。',
          '重新授权',
        ),
      InterruptedRunRecoveryKind.unknownOutcome => (
          '工具可能已经执行，但结果未知。不会重放；只能明确发起一次新操作。',
          '重新发起',
        ),
      InterruptedRunRecoveryKind.inspectOnly => (
          '恢复记录已损坏，已安全停止。请查看详情或忽略后手动处理。',
          null,
        ),
    };
    return Material(
      color: colors.tertiaryContainer,
      child: SafeArea(
        bottom: false,
        child: ListTile(
          leading: Icon(
            Icons.history_toggle_off,
            color: colors.onTertiaryContainer,
          ),
          title: Text(
            '上次任务被中断',
            style: theme.textTheme.titleSmall?.copyWith(
              color: colors.onTertiaryContainer,
              fontWeight: FontWeight.w700,
            ),
          ),
          subtitle: Text(
            subtitle,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onTertiaryContainer,
            ),
          ),
          trailing: Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: () => _showInterruptedRunInspection(marker),
                child: const Text('查看'),
              ),
              TextButton(
                onPressed: () =>
                    context.read<ChatProvider>().dismissInterruptedAgentRun(),
                child: const Text('忽略'),
              ),
              if (continueLabel != null)
                FilledButton.tonal(
                  onPressed: () => context
                      .read<ChatProvider>()
                      .continueInterruptedAgentRun(),
                  child: Text(continueLabel),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showInterruptedRunInspection(
    AgentRunRecoveryMarker marker,
  ) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('中断恢复详情', style: theme.textTheme.titleMedium),
                const SizedBox(height: 12),
                SelectableText(
                  'Run attempt: ${marker.runAttemptId}\n'
                  'Started: ${marker.startedAt.toIso8601String()}',
                  style: theme.textTheme.bodySmall,
                ),
                if (marker.toolAttempts.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  ...marker.toolAttempts.map(
                    (attempt) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        '${attempt.toolName} · ${attempt.risk.name} · '
                        '${attempt.lifecycle.name}\n'
                        'Operation: ${attempt.operationId}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('关闭'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildAssistantErrorBanner(
    ChatMessage message,
    int messageIndex,
    ThemeData theme,
    double maxContentWidth,
  ) {
    final error = message.assistantError!;
    final color = theme.colorScheme.error;
    final remoteAuthorizationError = error.source == 'remote_agent' &&
        const {
          'remote_agent_consentRequired',
          'remote_agent_invalidConfiguration',
          'remote_agent_credentialUnavailable',
        }.contains(error.code);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxContentWidth),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer.withAlpha(85),
          borderRadius: _bubbleRadius(false),
          border: Border.all(color: color.withAlpha(90)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(Icons.error_outline, size: 18, color: color),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        error.isRecoveryRetry
                            ? AppStrings.assistantRecoveryErrorTitle
                            : AppStrings.assistantErrorTitle,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: color,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        error.message,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (remoteAuthorizationError)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton(
                    onPressed: () async {
                      await context
                          .read<ChatProvider>()
                          .setCurrentSessionRemoteAgentEnabled(false);
                    },
                    child: const Text(AppStrings.useLocal),
                  ),
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).push(
                      CupertinoPageRoute(
                        builder: (_) => const SettingsScreen(),
                      ),
                    ),
                    child: const Text(AppStrings.reauthorizeExternal),
                  ),
                ],
              )
            else if (error.canRetry)
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: () => _retryAssistantMessage(messageIndex),
                  icon: const Icon(Icons.refresh, size: 16),
                  label: Text(
                    error.isRecoveryRetry
                        ? AppStrings.assistantRecoveryContinue
                        : AppStrings.retry,
                  ),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    minimumSize: const Size(0, 38),
                  ),
                ),
              )
            else
              Text(
                AppStrings.assistantErrorRetryUnavailable,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onErrorContainer.withAlpha(185),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _retryAssistantMessage(int messageIndex) async {
    final messenger = ScaffoldMessenger.of(context);
    final session = context.read<ChatProvider>().currentSession;
    final recoveryRetry = session != null &&
        messageIndex >= 0 &&
        messageIndex < session.messages.length &&
        session.messages[messageIndex].assistantError?.isRecoveryRetry == true;
    final status =
        await context.read<ChatProvider>().retryAssistantMessage(messageIndex);
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          recoveryRetry && status == AssistantRetryStatus.started
              ? AppStrings.assistantRecoveryStarted
              : _assistantRetryStatusText(status),
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  String _assistantRetryStatusText(AssistantRetryStatus status) {
    return switch (status) {
      AssistantRetryStatus.started => AppStrings.assistantRetryStarted,
      AssistantRetryStatus.invalidMessage => AppStrings.assistantRetryFailed,
      AssistantRetryStatus.notRetryable => AppStrings.assistantRetryUnavailable,
      AssistantRetryStatus.busy => AppStrings.assistantRetryBusy,
      AssistantRetryStatus.missingApiKey =>
        AppStrings.assistantRetryMissingApiKey,
    };
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

  Widget _buildLoadOlderMessagesAffordance(
    ThemeData theme, {
    required int hiddenCount,
    required int totalMessageCount,
  }) {
    final loadCount = math.min(hiddenCount, _loadOlderMessageIncrement);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Material(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(AppRadii.xl),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadii.xl),
            onTap: () => _showMoreHistory(totalMessageCount),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.keyboard_arrow_up,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    AppStrings.loadOlderMessages(loadCount),
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    AppStrings.hiddenOlderMessages(hiddenCount),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant.withAlpha(155),
                    ),
                  ),
                ],
              ),
            ),
          ),
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
    if (message.isViewingAlternative) {
      final text = message.textContent;
      if (text.isNotEmpty) buffer.writeln(text);
      return buffer.toString().trimRight();
    }
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

  Future<void> _compactBeforeMessage(int? messageIndex) async {
    if (messageIndex == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final provider = context.read<ChatProvider>();
    if (!provider.canRebuildCurrentContextSummary) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(AppStrings.contextSummaryBusy),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    messenger.showSnackBar(
      const SnackBar(content: Text(AppStrings.contextSummaryGenerating)),
    );
    final result = await provider.rebuildContextSummaryBeforeMessage(
      messageIndex,
    );
    if (!mounted) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(result.message),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  bool _canEditMessage(ChatMessage? message) {
    return message != null &&
        message.role == 'user' &&
        message.textContent.trim().isNotEmpty &&
        message.toolResults.isEmpty;
  }

  Future<void> _showEditMessageDialog(
    ChatMessage? message,
    int? messageIndex,
  ) async {
    if (!_canEditMessage(message) || messageIndex == null) return;
    final provider = context.read<ChatProvider>();
    final controller = TextEditingController(text: message!.textContent);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(AppStrings.editMessage),
        content: SizedBox(
          width: double.maxFinite,
          child: TextField(
            controller: controller,
            autofocus: true,
            minLines: 4,
            maxLines: 10,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: AppStrings.editMessageHint,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(AppStrings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text(AppStrings.editAndResend),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || result == null) return;

    final status = await provider.editUserMessageAndResend(
      messageIndex,
      result,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_editMessageStatusText(status)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  String _editMessageStatusText(EditUserMessageBranchStatus status) {
    return switch (status) {
      EditUserMessageBranchStatus.started =>
        AppStrings.editMessageBranchStarted,
      EditUserMessageBranchStatus.empty => AppStrings.editMessageEmpty,
      EditUserMessageBranchStatus.invalidMessage =>
        AppStrings.editMessageInvalid,
      EditUserMessageBranchStatus.busy => AppStrings.editMessageBlockedActive,
      EditUserMessageBranchStatus.missingApiKey =>
        AppStrings.editMessageMissingApiKey,
      EditUserMessageBranchStatus.failed => AppStrings.editMessageBranchFailed,
    };
  }

  void _showMessageActions({
    required String text,
    required ChatMessage? message,
    required int? messageIndex,
  }) {
    final actionText = text.isNotEmpty
        ? text
        : _messageToMarkdown(message, fallbackText: text);
    final compactEnabled =
        context.read<ChatProvider>().canRebuildCurrentContextSummary;
    HapticFeedback.lightImpact();
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_canEditMessage(message))
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text(AppStrings.editMessage),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _showEditMessageDialog(message, messageIndex);
                },
              ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text(AppStrings.copyText),
              onTap: () {
                Clipboard.setData(ClipboardData(text: actionText));
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
                  text: _messageToMarkdown(message, fallbackText: actionText),
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
                    text: _messageToMarkdown(message, fallbackText: actionText),
                    subject: AppStrings.appName,
                  );
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('${AppStrings.shareFailed}: $e')),
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
            if (messageIndex != null && messageIndex > 0)
              ListTile(
                leading: const Icon(Icons.summarize_outlined),
                title: const Text(AppStrings.contextSummaryManualCompactBefore),
                subtitle: compactEnabled
                    ? null
                    : const Text(AppStrings.contextSummaryBusy),
                enabled: compactEnabled,
                onTap: compactEnabled
                    ? () async {
                        Navigator.pop(ctx);
                        await _compactBeforeMessage(messageIndex);
                      }
                    : null,
              ),
            ListTile(
              leading: const Icon(Icons.format_quote),
              title: const Text(AppStrings.quoteReply),
              onTap: () {
                Navigator.pop(ctx);
                final quoted = actionText.length > 200
                    ? '${actionText.substring(0, 200)}...'
                    : actionText;
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
  }

  Widget _buildMessageActionButton(
    ThemeData theme, {
    required String text,
    required ChatMessage? message,
    required int? messageIndex,
  }) {
    return Material(
      color: theme.colorScheme.surface.withAlpha(170),
      borderRadius: BorderRadius.circular(AppRadii.s),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadii.s),
        onTap: () => _showMessageActions(
          text: text,
          message: message,
          messageIndex: messageIndex,
        ),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(
            Icons.more_horiz,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant.withAlpha(165),
          ),
        ),
      ),
    );
  }

  Widget _buildBubbleWithAction({
    required Widget child,
    required ThemeData theme,
    required String text,
    required ChatMessage? message,
    required int? messageIndex,
    EdgeInsetsGeometry? margin,
  }) {
    return Stack(
      children: [
        Padding(
          padding: margin ?? EdgeInsets.zero,
          child: child,
        ),
        Positioned(
          top: margin == null ? 6 : 10,
          right: 6,
          child: _buildMessageActionButton(
            theme,
            text: text,
            message: message,
            messageIndex: messageIndex,
          ),
        ),
      ],
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
      case TextContent(:final text, :final reasoningContent):
        return Semantics(
          label: isUser ? '用户消息' : 'AI 消息',
          child: _buildBubbleWithAction(
            theme: theme,
            text: text,
            message: message,
            messageIndex: messageIndex,
            child: Container(
              constraints: BoxConstraints(
                maxWidth: maxContentWidth,
              ),
              padding: const EdgeInsets.fromLTRB(16, 14, 42, 14),
              decoration: BoxDecoration(
                color: isUser
                    ? AppColors.accent.withAlpha(45)
                    : theme.colorScheme.surfaceContainerHighest.withAlpha(75),
                borderRadius: _bubbleRadius(isUser),
                border: isUser
                    ? Border.all(color: AppColors.accent.withAlpha(90))
                    : null,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!isUser && reasoningContent?.isNotEmpty == true) ...[
                    ReasoningTextPanel(text: reasoningContent!),
                    if (text.isNotEmpty) const SizedBox(height: 12),
                  ],
                  if (text.isNotEmpty)
                    StreamingText(
                      text: text,
                      onOpenFullResponse: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => FullResponseScreen(text: text),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );

      case ToolUseContent():
        return GestureDetector(
          onLongPress: () => _showMessageActions(
            text: message?.textContent ?? '',
            message: message,
            messageIndex: messageIndex,
          ),
          child: _buildBubbleWithAction(
            theme: theme,
            text: message?.textContent ?? '',
            message: message,
            messageIndex: messageIndex,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxContentWidth),
              child: ToolCallCard(
                toolUse: content,
                toolOutput: _toolOutputFor(content, messageIndex, messages),
              ),
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
            onLongPress: () => _showMessageActions(
              text: message?.textContent ?? label,
              message: message,
              messageIndex: messageIndex,
            ),
            child: _buildBubbleWithAction(
              theme: theme,
              text: message?.textContent ?? label,
              message: message,
              messageIndex: messageIndex,
              margin: const EdgeInsets.only(top: 4),
              child: Container(
                constraints: BoxConstraints(
                  maxWidth: maxContentWidth,
                ),
                padding: const EdgeInsets.fromLTRB(16, 14, 42, 14),
                decoration: BoxDecoration(
                  color: isUser
                      ? AppColors.accent.withAlpha(45)
                      : theme.colorScheme.surfaceContainerHighest.withAlpha(75),
                  borderRadius: _bubbleRadius(isUser),
                  border: isUser
                      ? Border.all(color: AppColors.accent.withAlpha(90))
                      : null,
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
          ),
        );
    }
  }

  Widget _buildStreamingBubble(
    String text,
    ThemeData theme,
    double maxContentWidth, {
    String reasoningText = '',
    int reasoningTotalLength = 0,
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (reasoningText.isNotEmpty || reasoningTotalLength > 0) ...[
                  ReasoningTextPanel(
                    text: reasoningText,
                    totalLength: reasoningTotalLength,
                    isStreaming: true,
                  ),
                  if (text.isNotEmpty) const SizedBox(height: 12),
                ],
                if (text.isNotEmpty)
                  StreamingText(text: text, isStreaming: true),
              ],
            ),
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
    if (!mounted) return;
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

  Future<void> _showSessionMemoryDialog() async {
    final provider = context.read<ChatProvider>();
    final session = provider.currentSession;
    if (session == null) return;
    final sessionId = session.id;
    var mode = await MemoryService.getSessionMemoryMode(sessionId);
    if (!mounted) return;

    final result = await showDialog<SessionMemoryMode>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text(AppStrings.sessionMemory),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioListTile<SessionMemoryMode>(
                value: SessionMemoryMode.followGlobal,
                groupValue: mode,
                title: const Text(AppStrings.sessionMemoryFollowGlobal),
                onChanged: (value) {
                  if (value != null) setDialogState(() => mode = value);
                },
              ),
              RadioListTile<SessionMemoryMode>(
                value: SessionMemoryMode.enabled,
                groupValue: mode,
                title: const Text(AppStrings.sessionMemoryOn),
                onChanged: (value) {
                  if (value != null) setDialogState(() => mode = value);
                },
              ),
              RadioListTile<SessionMemoryMode>(
                value: SessionMemoryMode.disabled,
                groupValue: mode,
                title: const Text(AppStrings.sessionMemoryOff),
                onChanged: (value) {
                  if (value != null) setDialogState(() => mode = value);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text(AppStrings.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, mode),
              child: const Text(AppStrings.save),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;
    await MemoryService.setSessionMemoryMode(sessionId, result);
    if (mounted) setState(() {});
  }

  Future<void> _showPromptProfilesDialog() async {
    final provider = context.read<ChatProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final prefs = PreferencesService();
    await prefs.init();
    if (!mounted) return;

    var profiles = prefs.promptProfiles;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          void reload() {
            setDialogState(() {
              profiles = prefs.promptProfiles;
            });
          }

          return AlertDialog(
            title: const Text(AppStrings.promptProfiles),
            content: SizedBox(
              width: double.maxFinite,
              height: 420,
              child: profiles.isEmpty
                  ? const Center(child: Text(AppStrings.promptProfilesEmpty))
                  : ListView.separated(
                      itemCount: profiles.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, index) {
                        final profile = profiles[index];
                        final hasSession = provider.currentSession != null;
                        return ListTile(
                          title: Text(profile.name),
                          subtitle: Text(
                            _promptProfilePreview(profile.systemPrompt),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: PopupMenuButton<String>(
                            onSelected: (value) async {
                              switch (value) {
                                case 'apply_global':
                                  prefs.systemPrompt = profile.systemPrompt;
                                  if (!dialogContext.mounted) return;
                                  Navigator.pop(dialogContext);
                                  messenger.showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        AppStrings.promptProfileAppliedGlobal,
                                      ),
                                    ),
                                  );
                                  return;
                                case 'apply_session':
                                  if (provider.currentSession == null) return;
                                  await provider.updateSessionSystemPrompt(
                                    profile.systemPrompt,
                                  );
                                  if (!dialogContext.mounted) return;
                                  Navigator.pop(dialogContext);
                                  messenger.showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        AppStrings.promptProfileAppliedSession,
                                      ),
                                    ),
                                  );
                                  return;
                                case 'edit':
                                  final saved =
                                      await _showPromptProfileEditorDialog(
                                    profile: profile,
                                  );
                                  if (!dialogContext.mounted) return;
                                  if (saved) reload();
                                  return;
                                case 'delete':
                                  final confirmed =
                                      await _confirmDeletePromptProfile();
                                  if (!dialogContext.mounted) return;
                                  if (confirmed) {
                                    await prefs.deletePromptProfile(profile.id);
                                    if (!dialogContext.mounted) return;
                                    reload();
                                  }
                                  return;
                              }
                            },
                            itemBuilder: (_) => [
                              const PopupMenuItem(
                                value: 'apply_global',
                                child: ListTile(
                                  leading: Icon(Icons.public),
                                  title: Text(
                                    AppStrings.promptProfileApplyGlobal,
                                  ),
                                  dense: true,
                                ),
                              ),
                              PopupMenuItem(
                                value: 'apply_session',
                                enabled: hasSession,
                                child: const ListTile(
                                  leading: Icon(Icons.chat_bubble_outline),
                                  title: Text(
                                    AppStrings.promptProfileApplySession,
                                  ),
                                  dense: true,
                                ),
                              ),
                              const PopupMenuItem(
                                value: 'edit',
                                child: ListTile(
                                  leading: Icon(Icons.edit_outlined),
                                  title: Text(AppStrings.promptProfileEdit),
                                  dense: true,
                                ),
                              ),
                              const PopupMenuItem(
                                value: 'delete',
                                child: ListTile(
                                  leading: Icon(Icons.delete_outline),
                                  title: Text(AppStrings.delete),
                                  dense: true,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text(AppStrings.close),
              ),
              FilledButton.icon(
                icon: const Icon(Icons.add),
                label: const Text(AppStrings.promptProfileAdd),
                onPressed: () async {
                  final saved = await _showPromptProfileEditorDialog();
                  if (!dialogContext.mounted) return;
                  if (saved) reload();
                },
              ),
            ],
          );
        },
      ),
    );
  }

  Future<bool> _showPromptProfileEditorDialog({
    PromptProfile? profile,
  }) async {
    final prefs = PreferencesService();
    await prefs.init();
    if (!mounted) return false;

    final nameController = TextEditingController(text: profile?.name ?? '');
    final promptController =
        TextEditingController(text: profile?.systemPrompt ?? '');
    final result = await showDialog<({String name, String prompt})>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          profile == null
              ? AppStrings.promptProfileAdd
              : AppStrings.promptProfileEdit,
        ),
        content: SizedBox(
          width: double.maxFinite,
          height: 360,
          child: Column(
            children: [
              TextField(
                controller: nameController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: AppStrings.promptProfileName,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: TextField(
                  controller: promptController,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  decoration: const InputDecoration(
                    labelText: AppStrings.promptProfilePrompt,
                    border: OutlineInputBorder(),
                  ),
                ),
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
            onPressed: () => Navigator.pop(ctx, (
              name: nameController.text,
              prompt: promptController.text,
            )),
            child: const Text(AppStrings.save),
          ),
        ],
      ),
    );
    nameController.dispose();
    promptController.dispose();
    if (result == null) return false;

    try {
      await prefs.savePromptProfile(
        id: profile?.id,
        name: result.name,
        systemPrompt: result.prompt,
      );
      return true;
    } on ArgumentError {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(AppStrings.promptProfileInvalid)),
      );
      return false;
    }
  }

  Future<bool> _confirmDeletePromptProfile() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(AppStrings.delete),
        content: const Text(AppStrings.promptProfileDeleteConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(AppStrings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(AppStrings.delete),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  String _promptProfilePreview(String prompt) {
    return prompt.trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  Future<void> _showSwitchModelDialog() async {
    final provider = context.read<ChatProvider>();
    final prefs = PreferencesService();
    await prefs.init();
    if (!mounted) return;
    final profiles = prefs.profiles;
    String selectedProfileId = prefs.activeProfileId ?? profiles.first.id;

    final controller = TextEditingController(
      text: provider.currentSession?.modelOverride ?? '',
    );

    List<String> availableModels = [];
    bool loading = false;

    ProviderProfile selectedProfile() {
      return profiles.firstWhere(
        (profile) => profile.id == selectedProfileId,
        orElse: () => profiles.first,
      );
    }

    Future<void> redirectToProfileSettings(
      BuildContext dialogContext,
      ProviderProfile profile,
    ) async {
      if (dialogContext.mounted) Navigator.pop(dialogContext);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppStrings.profileNeedsApiKey(profile.displayName)),
        ),
      );
      await Navigator.of(context).push(
        CupertinoPageRoute(
          builder: (_) => ModelApiSettingsScreen(initialProfileId: profile.id),
        ),
      );
    }

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final maxDialogHeight = math.min(
            MediaQuery.sizeOf(ctx).height * 0.72,
            560.0,
          );
          return AlertDialog(
            title: const Text(AppStrings.switchModel),
            content: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 520,
                maxHeight: maxDialogHeight,
              ),
              child: SingleChildScrollView(
                child: SizedBox(
                  width: double.maxFinite,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        AppStrings.providerProfiles,
                        style: Theme.of(ctx).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 8),
                      Column(
                        children: [
                          for (final profile in profiles)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: profile.id == selectedProfileId
                                      ? Theme.of(ctx)
                                          .colorScheme
                                          .primary
                                          .withAlpha(18)
                                      : Theme.of(ctx).colorScheme.surface,
                                  borderRadius:
                                      BorderRadius.circular(AppRadii.s),
                                  border: Border.all(
                                    color: profile.id == selectedProfileId
                                        ? Theme.of(ctx)
                                            .colorScheme
                                            .primary
                                            .withAlpha(150)
                                        : Theme.of(ctx)
                                            .colorScheme
                                            .outline
                                            .withAlpha(45),
                                  ),
                                ),
                                child: RadioListTile<String>(
                                  isThreeLine: profile.apiKey.trim().isEmpty,
                                  value: profile.id,
                                  groupValue: selectedProfileId,
                                  onChanged: (value) {
                                    if (value == null) return;
                                    setDialogState(() {
                                      selectedProfileId = value;
                                      availableModels = [];
                                    });
                                  },
                                  title: Text(
                                    profile.displayName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                    profile.apiKey.trim().isEmpty
                                        ? '${profile.apiFormat == ProviderProfile.openaiFormat ? AppStrings.openaiCompatible : 'Anthropic'} · ${profile.effectiveModel}\n${AppStrings.apiKeyRequiredToUse}'
                                        : '${profile.apiFormat == ProviderProfile.openaiFormat ? AppStrings.openaiCompatible : 'Anthropic'} · ${profile.effectiveModel}',
                                    maxLines:
                                        profile.apiKey.trim().isEmpty ? 2 : 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  secondary: Icon(
                                    profile.apiKey.trim().isEmpty
                                        ? Icons.warning_amber_outlined
                                        : profile.apiFormat ==
                                                ProviderProfile.openaiFormat
                                            ? Icons.api
                                            : Icons.auto_awesome,
                                    color: profile.apiKey.trim().isEmpty
                                        ? Theme.of(ctx).colorScheme.error
                                        : null,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (loading)
                        const SizedBox(
                          height: 56,
                          child: Center(child: CircularProgressIndicator()),
                        )
                      else if (availableModels.isNotEmpty)
                        DropdownButtonFormField<String>(
                          value:
                              availableModels.any((m) => m == controller.text)
                                  ? controller.text
                                  : null,
                          decoration: InputDecoration(
                            labelText: AppStrings.selectModel,
                            hintText: selectedProfile().effectiveModel,
                          ),
                          isExpanded: true,
                          items: [
                            const DropdownMenuItem(
                              value: '',
                              child: Text(AppStrings.useGlobalDefault),
                            ),
                            ...availableModels.map((m) => DropdownMenuItem(
                                  value: m,
                                  child:
                                      Text(m, overflow: TextOverflow.ellipsis),
                                )),
                          ],
                          onChanged: (v) => controller.text = v ?? '',
                        )
                      else
                        TextField(
                          controller: controller,
                          decoration: InputDecoration(
                            labelText: AppStrings.modelName,
                            hintText: selectedProfile().effectiveModel,
                            helperText: AppStrings.leaveEmptyForDefault,
                          ),
                        ),
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          icon: const Icon(Icons.refresh, size: 18),
                          label: const Text(AppStrings.fetchModelsButton),
                          onPressed: () async {
                            final profile = selectedProfile();
                            if (profile.apiKey.trim().isEmpty) {
                              await redirectToProfileSettings(ctx, profile);
                              return;
                            }
                            setDialogState(() => loading = true);
                            try {
                              availableModels = await LlmService.fetchModels(
                                apiFormat: profile.apiFormat,
                                apiKey: profile.apiKey,
                                baseUrl: profile.baseUrl.trim().isEmpty
                                    ? null
                                    : profile.baseUrl,
                              );
                              if (availableModels
                                      .any(LlmService.isPresetModel) &&
                                  mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      AppStrings.modelFetchPresetNotice,
                                    ),
                                  ),
                                );
                              }
                            } catch (e) {
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      AppStrings.modelFetchFailed(
                                        _briefError(e),
                                      ),
                                    ),
                                  ),
                                );
                              }
                            }
                            setDialogState(() => loading = false);
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text(AppStrings.cancel)),
              FilledButton(
                onPressed: () async {
                  final selected = selectedProfile();
                  if (selected.apiKey.trim().isEmpty) {
                    await redirectToProfileSettings(ctx, selected);
                    return;
                  }
                  if (selected.id != prefs.activeProfileId) {
                    await provider.switchProfile(selected.id);
                  }
                  await provider.updateSessionModel(
                    model: controller.text.trim().isEmpty
                        ? null
                        : controller.text.trim(),
                  );
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                child: const Text(AppStrings.confirm),
              ),
            ],
          );
        },
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
        if (FileAttachmentService.requiresSensitiveTextConfirmation(file)) {
          if (!mounted) return;
          final warning = FileAttachmentService.sensitiveTextWarning(file) ??
              '该文件可能包含密钥或凭据。确认后才会把全文注入提示词。';
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('确认附加敏感文件？'),
              content: Text(warning),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text(AppStrings.cancel),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text(AppStrings.confirm),
                ),
              ],
            ),
          );
          if (confirmed != true) continue;
        }
        final prepared = await FileAttachmentService.prepareForMessage(file);
        if (!mounted) {
          final receipt = prepared.workspaceImportReceipt;
          if (receipt != null) {
            unawaited(
              NativeBridge.discardWorkspaceImport(receipt).catchError((_) {}),
            );
          }
          return;
        }
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
            workspaceImportReceipt: prepared.workspaceImportReceipt,
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
    final receipt = preview.workspaceImportReceipt;
    if (receipt != null &&
        _workspaceImportsBeingCommitted.contains(receipt.operationId)) {
      return;
    }
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
    final sessionId = context.read<ChatProvider>().currentSession?.id;
    if (sessionId != null) {
      context.read<ChatProvider>().saveDraft(sessionId, _inputController.text);
    }
    if (receipt != null) {
      unawaited(NativeBridge.discardWorkspaceImport(receipt).catchError((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('附件清理将在下次启动时重试。')),
        );
      }));
    }
  }

  Future<void> _discardPendingWorkspaceImports() async {
    final receipts = _pendingAttachmentPreviews
        .map((preview) => preview.workspaceImportReceipt)
        .whereType<WorkspaceImportReceipt>()
        .where(
          (receipt) =>
              !_workspaceImportsBeingCommitted.contains(receipt.operationId),
        )
        .toList(growable: false);
    for (final receipt in receipts) {
      try {
        await NativeBridge.discardWorkspaceImport(receipt);
      } catch (_) {
        // Native CLEANUP_REQUIRED evidence is retained for startup retry.
      }
    }
  }

  String _draftWithoutWorkspaceImports() {
    var draft = _inputController.text;
    for (final preview in _pendingAttachmentPreviews) {
      if (preview.workspaceImportReceipt == null) continue;
      draft = draft.replaceFirst(preview.insertedText, '');
      draft = draft.replaceFirst('${preview.inputText}\n', '');
      draft = draft.replaceFirst(preview.inputText, '');
    }
    return draft;
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
    if (!mounted) return;

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
                  decoration: const InputDecoration(
                    hintText: AppStrings.inputHint,
                    border: OutlineInputBorder(),
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
                      final selectedModelList = selectedModels.toList();
                      final selectedModelCount = selectedModelList.length;
                      final text = textController.text.trim();
                      Navigator.pop(ctx);
                      if (text.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('请输入对比内容')),
                        );
                        return;
                      }
                      debugPrint(
                        'Starting model compare with $selectedModelCount models',
                      );
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('正在对比 $selectedModelCount 个模型...'),
                          duration: const Duration(seconds: 1),
                        ),
                      );
                      _inputController.clear();
                      final provider = context.read<ChatProvider>();
                      if (provider.currentSession != null) {
                        provider.saveDraft(provider.currentSession!.id, '');
                      }
                      unawaited(
                        provider.sendCompare(text, selectedModelList),
                      );
                    }
                  : null,
              child: const Text(AppStrings.compareStart),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageQueueBar(
    ThemeData theme,
    ChatProvider provider,
    bool isRunning,
  ) {
    final queue = provider.messageQueue;
    if (queue.isEmpty) {
      _queueExpanded = false;
      return const SizedBox.shrink();
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadii.s),
        border: Border.all(color: theme.colorScheme.outline.withAlpha(45)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            label: AppStrings.messagesQueued(queue.length),
            liveRegion: true,
            button: true,
            child: InkWell(
              onTap: () => setState(() => _queueExpanded = !_queueExpanded),
              borderRadius: BorderRadius.circular(AppRadii.s),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Icon(Icons.queue,
                        size: 16, color: theme.colorScheme.primary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        AppStrings.messagesQueued(queue.length),
                        style: theme.textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Icon(
                      _queueExpanded ? Icons.expand_less : Icons.expand_more,
                      size: 20,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    if (!isRunning)
                      TextButton(
                        onPressed: provider.sendNextQueued,
                        child: const Text(AppStrings.sendQueued),
                      ),
                    IconButton(
                      tooltip: AppStrings.clearMessageQueue,
                      icon: const Icon(Icons.clear_all, size: 18),
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
                      onPressed: () => _clearQueueWithUndo(provider, queue),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_queueExpanded)
            ...queue.map(
              (message) => Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 4, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _queuedMessagePreview(message),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (message.attachments.isNotEmpty) ...[
                      const SizedBox(width: 4),
                      Icon(
                        Icons.attach_file,
                        size: 14,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      Text(
                        '${message.attachments.length}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                    IconButton(
                      icon: Icon(
                        Icons.close,
                        size: 16,
                        color: theme.colorScheme.error,
                      ),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
                      tooltip: AppStrings.removeQueuedMessage,
                      onPressed: () {
                        final undo = provider.removeQueuedMessage(message.id);
                        if (undo != null) _showQueueUndo(provider, undo);
                      },
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _clearQueueWithUndo(
    ChatProvider provider,
    List<QueuedMessage> queue,
  ) async {
    if (queue.any((message) => message.attachments.isNotEmpty)) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text(AppStrings.clearMessageQueue),
          content: const Text(AppStrings.clearQueueAttachmentsWarning),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text(AppStrings.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text(AppStrings.confirm),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    final undo = provider.clearMessageQueue();
    if (undo != null) _showQueueUndo(provider, undo);
  }

  void _showQueueUndo(
    ChatProvider provider,
    MessageQueueUndo undo, {
    String message = AppStrings.messageQueueCleared,
  }) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    final controller = messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 6),
        action: SnackBarAction(
          label: AppStrings.undo,
          onPressed: () {
            final result = provider.restoreMessageQueueWithResult(undo);
            if (!mounted) return;
            if (result.sessionMissing) {
              messenger.showSnackBar(
                const SnackBar(
                  content: Text(AppStrings.messageQueueRestoreUnavailable),
                ),
              );
              return;
            }
            final remaining = result.remainingUndo;
            if (remaining != null) {
              _showQueueUndo(
                provider,
                remaining,
                message: result.restoredCount == 0
                    ? AppStrings.messageQueueRestoreCapacityFull
                    : AppStrings.messageQueuePartiallyRestored(
                        result.restoredCount,
                        result.remainingCount,
                      ),
              );
              return;
            }
            messenger.showSnackBar(
              SnackBar(
                content: Text(
                  AppStrings.messageQueueRestored(result.restoredCount),
                ),
              ),
            );
          },
        ),
      ),
    );
    controller.closed.then((reason) {
      if (reason != SnackBarClosedReason.action) {
        provider.expireMessageQueueUndo(undo);
      }
    });
  }

  String _queuedMessagePreview(QueuedMessage message) {
    final text = message.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (text.isEmpty) return '附件消息';
    if (text.length <= 50) return text;
    return '${text.substring(0, 50)}...';
  }

  Widget _buildBackgroundTasksBar(ThemeData theme, ChatProvider provider) {
    final currentSessionId = provider.currentSession?.id;
    final otherActiveIds = provider.activeAgentSessionIds
        .where((sessionId) => sessionId != currentSessionId)
        .toList();
    if (otherActiveIds.isEmpty) {
      _backgroundTasksExpanded = false;
      return const SizedBox.shrink();
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withAlpha(40),
        borderRadius: BorderRadius.circular(AppRadii.s),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => setState(
              () => _backgroundTasksExpanded = !_backgroundTasksExpanded,
            ),
            borderRadius: BorderRadius.circular(AppRadii.s),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    Icons.play_circle_outline,
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${otherActiveIds.length} 个 AI 任务在其他会话中运行',
                      style: theme.textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: AppStrings.openAgentRunCenter,
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const AgentRunCenterScreen(),
                      ),
                    ),
                    icon: const Icon(Icons.view_list_outlined),
                  ),
                  Icon(
                    _backgroundTasksExpanded
                        ? Icons.expand_less
                        : Icons.expand_more,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (_backgroundTasksExpanded)
            ...otherActiveIds.map(
              (sessionId) {
                final status = provider.agentStatusFor(sessionId);
                return InkWell(
                  onTap: () {
                    setState(() => _backgroundTasksExpanded = false);
                    unawaited(provider.selectSession(sessionId));
                  },
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: _agentStatusColor(status, theme),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _sessionTitleFor(provider, sessionId),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurface,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _agentStatusText(status),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontSize: 11,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.chevron_right,
                          size: 16,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  String _sessionTitleFor(ChatProvider provider, String sessionId) {
    for (final session in provider.sessions) {
      if (session.id == sessionId) return session.title;
    }
    return '未命名会话';
  }

  Color _agentStatusColor(AgentStatus status, ThemeData theme) {
    return switch (status) {
      AgentStatus.thinking => theme.colorScheme.primary,
      AgentStatus.streaming => theme.colorScheme.primary,
      AgentStatus.tooling => Colors.amber,
      AgentStatus.error => theme.colorScheme.error,
      AgentStatus.idle => Colors.transparent,
    };
  }

  String _agentStatusText(AgentStatus status) {
    return switch (status) {
      AgentStatus.thinking => '思考中',
      AgentStatus.streaming => '回复中',
      AgentStatus.tooling => '执行工具',
      AgentStatus.error => '出错',
      AgentStatus.idle => '',
    };
  }

  Widget _buildInputArea(ThemeData theme) {
    return Consumer<ChatProvider>(
      builder: (_, provider, __) {
        final isRunning = provider.agentStatus != AgentStatus.idle &&
            provider.agentStatus != AgentStatus.error;
        final isRecording = _isListening || _isWhisperRecording;
        final queueFull =
            provider.messageQueue.length >= ChatProvider.maxQueuedMessages;
        final media = MediaQuery.of(context);
        final imeVisible = media.viewInsets.bottom > 0;
        final usableHeight =
            math.max(0.0, media.size.height - media.viewInsets.bottom);
        final maxInputHeight = imeVisible
            ? math.min(240.0, math.max(148.0, usableHeight * 0.52))
            : double.infinity;

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
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 640,
                  maxHeight: maxInputHeight,
                ),
                child: SingleChildScrollView(
                  physics: imeVisible
                      ? const ClampingScrollPhysics()
                      : const NeverScrollableScrollPhysics(),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildAttachmentPreviews(theme),
                      _buildExecutionContextChip(theme, provider),
                      _buildBackgroundTasksBar(theme, provider),
                      _buildMessageQueueBar(theme, provider, isRunning),
                      _buildVoiceState(theme),
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
                                foregroundColor:
                                    theme.colorScheme.onSurfaceVariant,
                              ),
                              onPressed: _showAttachOptions,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _inputController,
                              focusNode: _focusNode,
                              enabled: true,
                              maxLines: 5,
                              minLines: 1,
                              textInputAction: TextInputAction.send,
                              onSubmitted: (_) => _sendMessage(),
                              decoration: InputDecoration(
                                hintText: isRunning
                                    ? (queueFull
                                        ? AppStrings.messageQueueFullHint(
                                            provider.messageQueue.length,
                                            ChatProvider.maxQueuedMessages,
                                          )
                                        : AppStrings.queueInputHint)
                                    : AppStrings.inputHint,
                                filled: true,
                                fillColor:
                                    theme.colorScheme.surfaceContainerHighest,
                                border: OutlineInputBorder(
                                  borderRadius:
                                      BorderRadius.circular(AppRadii.xl),
                                  borderSide: BorderSide(
                                    color:
                                        theme.colorScheme.outline.withAlpha(60),
                                  ),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius:
                                      BorderRadius.circular(AppRadii.xl),
                                  borderSide: BorderSide(
                                    color:
                                        theme.colorScheme.outline.withAlpha(60),
                                  ),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius:
                                      BorderRadius.circular(AppRadii.xl),
                                  borderSide: BorderSide(
                                    color: theme.colorScheme.primary
                                        .withAlpha(180),
                                    width: 1.5,
                                  ),
                                ),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 12,
                                ),
                              ),
                            ),
                          ),
                          if (!isRunning) const SizedBox(width: 6),
                          if (!isRunning)
                            Semantics(
                              button: true,
                              liveRegion: _voiceInput.isBusy,
                              label: _isWhisperRecording
                                  ? AppStrings.voiceStopAndTranscribe
                                  : _isListening
                                      ? AppStrings.voiceStop
                                      : AppStrings.voiceStart,
                              child: GestureDetector(
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
                                        : theme.colorScheme
                                            .surfaceContainerHighest,
                                    borderRadius:
                                        BorderRadius.circular(AppRadii.s),
                                    border: Border.all(
                                      color: isRecording
                                          ? AppColors.statusRed.withAlpha(120)
                                          : theme.colorScheme.outline
                                              .withAlpha(55),
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
                            ),
                          const SizedBox(width: 6),
                          if (isRunning)
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 48,
                                  height: 48,
                                  child: IconButton.filled(
                                    onPressed: provider.cancelAgent,
                                    tooltip: AppStrings.stopResponse,
                                    icon: const Icon(Icons.stop),
                                    iconSize: 20,
                                    style: IconButton.styleFrom(
                                      backgroundColor: AppColors.statusRed,
                                      foregroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(AppRadii.xl),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                SizedBox(
                                  width: 48,
                                  height: 48,
                                  child: IconButton.filled(
                                    onPressed: queueFull ? null : _sendMessage,
                                    tooltip: AppStrings.send,
                                    icon: const Icon(Icons.send),
                                    iconSize: 20,
                                    style: IconButton.styleFrom(
                                      backgroundColor:
                                          theme.colorScheme.primary,
                                      foregroundColor:
                                          theme.colorScheme.onPrimary,
                                      disabledBackgroundColor: theme
                                          .colorScheme.surfaceContainerHighest,
                                      disabledForegroundColor:
                                          theme.colorScheme.onSurfaceVariant,
                                      shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(AppRadii.xl),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            )
                          else
                            SizedBox(
                              width: 52,
                              height: 48,
                              child: IconButton.filled(
                                onPressed: _sendMessage,
                                tooltip: AppStrings.send,
                                icon: const Icon(Icons.send),
                                iconSize: 20,
                                style: IconButton.styleFrom(
                                  backgroundColor: theme.colorScheme.primary,
                                  foregroundColor: theme.colorScheme.onPrimary,
                                  shape: RoundedRectangleBorder(
                                    borderRadius:
                                        BorderRadius.circular(AppRadii.xl),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildExecutionContextChip(
    ThemeData theme,
    ChatProvider provider,
  ) {
    final external = provider.currentSessionUsesRemoteAgent;
    return Align(
      alignment: Alignment.centerLeft,
      child: Semantics(
        button: true,
        label: provider.currentExecutionContextLabel,
        child: ActionChip(
          avatar: Icon(
            external ? Icons.public : Icons.smartphone,
            size: 18,
          ),
          label: Text(
            provider.currentExecutionContextLabel,
            overflow: TextOverflow.ellipsis,
          ),
          onPressed: () => _showExecutionContextDetails(provider),
        ),
      ),
    );
  }

  Future<void> _showExecutionContextDetails(ChatProvider provider) async {
    final external = provider.currentSessionUsesRemoteAgent;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                provider.currentExecutionContextLabel,
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(external
                  ? AppStrings.externalContextDisclosure
                  : AppStrings.localContextDisclosure),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (external)
                    FilledButton.icon(
                      onPressed: () async {
                        await provider
                            .setCurrentSessionRemoteAgentEnabled(false);
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                      icon: const Icon(Icons.smartphone),
                      label: const Text(AppStrings.useLocal),
                    ),
                  OutlinedButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      Navigator.of(context).push(
                        CupertinoPageRoute(
                          builder: (_) => const SettingsScreen(),
                        ),
                      );
                    },
                    child: Text(external
                        ? AppStrings.reauthorizeExternal
                        : AppStrings.settings),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVoiceState(ThemeData theme) {
    final phase = _voiceInput.phase;
    if (phase == VoiceInputPhase.idle) return const SizedBox.shrink();
    final label = switch (phase) {
      VoiceInputPhase.listening => AppStrings.voiceListening,
      VoiceInputPhase.stopping => AppStrings.voiceStopping,
      VoiceInputPhase.transcribing => AppStrings.transcribing,
      VoiceInputPhase.cancelled => AppStrings.voiceCancelled,
      VoiceInputPhase.error => switch (_voiceInput.errorCode) {
          'audio_permission_denied' => AppStrings.voicePermissionError,
          'native_timeout' => AppStrings.voiceTimeoutError,
          'whisper_not_configured' => AppStrings.voiceSetupError,
          'transcription_failed' => AppStrings.voiceTranscriptionError,
          _ => AppStrings.voiceError,
        },
      VoiceInputPhase.idle => '',
    };
    return Semantics(
      container: true,
      liveRegion: true,
      label: label,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: phase == VoiceInputPhase.error
              ? theme.colorScheme.errorContainer
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(AppRadii.s),
        ),
        child: Row(
          children: [
            Icon(
              phase == VoiceInputPhase.error
                  ? Icons.error_outline
                  : phase == VoiceInputPhase.cancelled
                      ? Icons.mic_off_outlined
                      : Icons.mic_none,
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(label)),
            if (_voiceInput.isBusy && _voiceStartedAt != null)
              ExcludeSemantics(
                child: Text(
                  _formatVoiceElapsed(DateTime.now().difference(
                    _voiceStartedAt!,
                  )),
                  style: theme.textTheme.labelSmall,
                ),
              ),
            if (_voiceInput.isBusy)
              TextButton(
                onPressed: () => _isWhisperRecording
                    ? _stopWhisperRecording()
                    : _cancelVoiceInput(),
                child: Text(_isWhisperRecording
                    ? AppStrings.voiceStopAndTranscribe
                    : AppStrings.voiceCancel),
              ),
            if (phase == VoiceInputPhase.error)
              TextButton(
                onPressed: () => Navigator.of(context).push(
                  CupertinoPageRoute(builder: (_) => const SettingsScreen()),
                ),
                child: const Text(AppStrings.settings),
              ),
          ],
        ),
      ),
    );
  }

  String _formatVoiceElapsed(Duration elapsed) {
    final minutes = elapsed.inMinutes.toString().padLeft(2, '0');
    final seconds = (elapsed.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

class _PendingAttachmentPreview {
  final MessageContent content;
  final String inputText;
  final String insertedText;
  final bool includeAsContentBlock;
  final WorkspaceImportReceipt? workspaceImportReceipt;

  const _PendingAttachmentPreview({
    required this.content,
    required this.inputText,
    required this.insertedText,
    required this.includeAsContentBlock,
    this.workspaceImportReceipt,
  });
}

class _EmptyStateFactRow extends StatelessWidget {
  const _EmptyStateFactRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          icon,
          size: 20,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _EmptyStatePromptRow extends StatelessWidget {
  const _EmptyStatePromptRow({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.s),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 22,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Icon(
                  Icons.north_west,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChatCommandGroup {
  const _ChatCommandGroup({
    required this.label,
    required this.actions,
  });

  final String label;
  final List<_ChatCommandAction> actions;
}

class _ChatCommandAction {
  const _ChatCommandAction({
    required this.id,
    required this.icon,
    required this.label,
    required this.description,
  });

  final String id;
  final IconData icon;
  final String label;
  final String description;
}

class _ChatCommandSurface extends StatelessWidget {
  const _ChatCommandSurface({super.key, required this.groups});

  final List<_ChatCommandGroup> groups;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visibleGroups = groups
        .where((group) => group.actions.isNotEmpty)
        .toList(growable: false);
    return Material(
      color: theme.colorScheme.surface,
      elevation: 8,
      borderRadius: const BorderRadius.vertical(
        top: Radius.circular(AppRadii.l),
      ),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '命令',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 48,
                    height: 48,
                    child: IconButton(
                      tooltip: AppStrings.close,
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                itemBuilder: (context, index) {
                  final group = visibleGroups[index];
                  return _ChatCommandSection(group: group);
                },
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemCount: visibleGroups.length,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatCommandSection extends StatelessWidget {
  const _ChatCommandSection({required this.group});

  final _ChatCommandGroup group;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: Text(
            group.label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withAlpha(90),
            borderRadius: BorderRadius.circular(AppRadii.m),
          ),
          child: Column(
            children: [
              for (var index = 0; index < group.actions.length; index++) ...[
                _ChatCommandTile(action: group.actions[index]),
                if (index != group.actions.length - 1)
                  Divider(
                    height: 1,
                    indent: 56,
                    color: theme.colorScheme.outline.withAlpha(35),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _ChatCommandTile extends StatelessWidget {
  const _ChatCommandTile({required this.action});

  final _ChatCommandAction action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: action.label,
      hint: action.description,
      child: InkWell(
        onTap: () => Navigator.pop(context, action.id),
        borderRadius: BorderRadius.circular(AppRadii.s),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(
                  action.icon,
                  size: 22,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        action.label,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        action.description,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MessageWindow {
  final List<ChatMessage> messages;
  final int startIndex;
  final int hiddenBeforeCount;

  const _MessageWindow({
    required this.messages,
    required this.startIndex,
    required this.hiddenBeforeCount,
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
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 1;
    } else if (widget.animate && _controller.value == 0) {
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
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller
        ..stop()
        ..value = 1;
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

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
