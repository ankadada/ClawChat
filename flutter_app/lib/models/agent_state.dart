import 'dart:async';

import 'package:uuid/uuid.dart';

import '../models/chat_models.dart';
import '../services/agent_service.dart';
import '../services/llm_service.dart';

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

  bool isSending = false;
  AgentService? agent;
  AgentStatus status = AgentStatus.idle;
  String streamingText = '';
  String? errorMessage;
  StringBuffer streamBuffer = StringBuffer();
  StreamSubscription<AgentEvent>? agentSubscription;
  Completer<void>? agentCompleter;
  Timer? streamThrottle;
  LlmService? cachedLlm;
  LlmConfig? cachedLlmConfig;
  bool agentServiceActive = false;
  String? agentServiceText;
  int agentServiceGeneration = 0;
  bool agentCompletionFinalizing = false;
  bool partialAgentResponseSaved = false;
  int initialApiMsgCount = 0;
  final Set<String> sessionApprovedTools = {};
  final List<QueuedMessage> messageQueue = [];
  bool wasCancelled = false;
  List<String>? pendingAlternatives;
  bool agentOverlayPermissionRequestStarted = false;

  AgentState(this.sessionId);

  void dispose() {
    streamThrottle?.cancel();
    agentSubscription?.cancel();
    if (agentCompleter != null && !agentCompleter!.isCompleted) {
      agentCompleter!.complete();
    }
    cachedLlm?.dispose();
  }
}
