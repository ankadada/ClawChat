import 'agent_state.dart';
import 'chat_models.dart';

enum AgentRunCenterPhase {
  queued,
  thinking,
  streaming,
  tooling,
  waitingApproval,
  interrupted,
  unknownOutcome,
  recoverableFailure,
}

enum AgentRunCenterContext { local, external, unknown }

/// A metadata-only projection of the existing local run/session state.
///
/// This is intentionally not persisted. ChatProvider and ChatSession remain the
/// only authorities for live and recoverable run state.
final class AgentRunCenterItem {
  const AgentRunCenterItem({
    required this.sessionId,
    required this.sessionTitle,
    required this.phase,
    required this.context,
    this.queuedCount = 0,
    this.waitingApproval = false,
    this.recoveryKind,
    this.safeExecutionDisplayName,
  });

  final String sessionId;
  final String sessionTitle;
  final AgentRunCenterPhase phase;
  final AgentRunCenterContext context;
  final int queuedCount;
  final bool waitingApproval;
  final InterruptedRunRecoveryKind? recoveryKind;
  final String? safeExecutionDisplayName;

  bool get isActive => switch (phase) {
        AgentRunCenterPhase.thinking ||
        AgentRunCenterPhase.streaming ||
        AgentRunCenterPhase.tooling ||
        AgentRunCenterPhase.waitingApproval =>
          true,
        _ => false,
      };

  static AgentRunCenterPhase phaseForStatus(AgentStatus status) =>
      switch (status) {
        AgentStatus.thinking => AgentRunCenterPhase.thinking,
        AgentStatus.streaming => AgentRunCenterPhase.streaming,
        AgentStatus.tooling => AgentRunCenterPhase.tooling,
        AgentStatus.error => AgentRunCenterPhase.recoverableFailure,
        AgentStatus.idle => AgentRunCenterPhase.queued,
      };
}
