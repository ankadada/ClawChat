import 'dart:async';

import 'package:uuid/uuid.dart';

import '../models/chat_models.dart';
import '../services/agent_service.dart';
import '../services/llm_service.dart';
import '../services/stream_flush_scheduler.dart';

enum AgentStatus { idle, thinking, streaming, tooling, error }

class QueuedMessage {
  final String id;
  final String text;
  final List<MessageContent> attachments;
  final DateTime queuedAt;

  QueuedMessage({
    required this.text,
    this.attachments = const [],
  })  : id = const Uuid().v4(),
        queuedAt = DateTime.now();
}

class AgentState {
  final String sessionId;
  String sessionTitle = '';
  bool sessionExecutionMetadataKnown = false;
  bool isRemoteSessionExecution = false;
  String? safeExecutionDisplayName;

  bool isSending = false;
  int runGeneration = 0;
  String? activeRunAttemptId;
  AgentService? agent;
  AgentStatus status = AgentStatus.idle;
  String streamingText = '';
  String streamingReasoningText = '';
  int streamingReasoningTotalLength = 0;
  String? errorMessage;
  StringBuffer streamBuffer = StringBuffer();
  StringBuffer reasoningPreviewBuffer = StringBuffer();
  StreamSubscription<AgentEvent>? agentSubscription;
  Completer<void>? agentCompleter;
  final StreamFlushScheduler streamFlushScheduler = StreamFlushScheduler();
  final StreamFlushScheduler reasoningFlushScheduler = StreamFlushScheduler(
    maxDelay: const Duration(milliseconds: 240),
  );
  Timer? messageQueueDrainTimer;
  String? messageQueueDrainHeadId;
  int messageQueueDrainEpoch = 0;
  LlmService? cachedLlm;
  LlmConfig? cachedLlmConfig;
  bool agentServiceActive = false;
  String? agentServiceText;
  int agentServiceGeneration = 0;
  bool agentCompletionFinalizing = false;
  bool partialAgentResponseSaved = false;
  int initialApiMsgCount = 0;
  final Set<String> sessionApprovedTools = {};
  bool forceToolApprovalForRun = false;
  final List<QueuedMessage> messageQueue = [];
  bool wasCancelled = false;
  List<String>? pendingAlternatives;
  bool agentOverlayPermissionRequestStarted = false;
  bool fallbackGuardedOutputObserved = false;
  bool fallbackTextEmitted = false;
  bool fallbackToolStarted = false;
  bool fallbackMessagesPersisted = false;

  AgentState(this.sessionId);

  void dispose() {
    streamFlushScheduler.cancel();
    reasoningFlushScheduler.cancel();
    messageQueueDrainTimer?.cancel();
    messageQueueDrainTimer = null;
    messageQueueDrainHeadId = null;
    messageQueueDrainEpoch++;
    agentSubscription?.cancel();
    if (agentCompleter != null && !agentCompleter!.isCompleted) {
      agentCompleter!.complete();
    }
    cachedLlm?.dispose();
  }
}
