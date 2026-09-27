import 'chat_models.dart';

/// User-visible lifecycle of one bash (command) tool attempt.
///
/// This is the I3 contract: a bash attempt is shown as `started`, `running`,
/// `completed`, `cancelled`, or `interrupted-unknown`. Keep this enum small;
/// it describes the *process* outcome, not whether the command exited zero.
enum ToolCommandLifecycle {
  /// The attempt exists (proposed / approved) but has not produced a result.
  started,

  /// The attempt is executing right now.
  running,

  /// The command produced a result and the process finished.
  completed,

  /// The user (or run teardown) cancelled the command before it finished.
  cancelled,

  /// The app died mid-command. The result is unknown and is never retried.
  interruptedUnknown,
}

extension ToolCommandLifecycleCopy on ToolCommandLifecycle {
  /// A finished attempt never returns to a live state.
  bool get isTerminal =>
      this == ToolCommandLifecycle.completed ||
      this == ToolCommandLifecycle.cancelled ||
      this == ToolCommandLifecycle.interruptedUnknown;

  /// Short chip label used by the chat tool card.
  String get label => switch (this) {
        ToolCommandLifecycle.started => '已发起',
        ToolCommandLifecycle.running => '运行中',
        ToolCommandLifecycle.completed => '已完成',
        ToolCommandLifecycle.cancelled => '已取消',
        ToolCommandLifecycle.interruptedUnknown => '结果未知',
      };

  /// One-line explanation. The interrupted case always states that the
  /// command did not finish and that it is not retried silently.
  String get detail => switch (this) {
        ToolCommandLifecycle.started => '命令已发起，等待运行。',
        ToolCommandLifecycle.running => '命令正在 Alpine 中运行。',
        ToolCommandLifecycle.completed => '命令已结束。',
        ToolCommandLifecycle.cancelled => '命令已取消，不会静默重试。',
        ToolCommandLifecycle.interruptedUnknown =>
          '应用在命令结束前退出，这条命令没有完成；不会静默重试。',
      };
}

/// Tool name whose attempts use the command lifecycle.
const String bashToolName = 'bash';

/// The exact user-facing text the agent service writes when a tool attempt is
/// cancelled (`_cancelledToolResult` in `agent_service.dart`). Re-exported here
/// so the card and tests share one constant instead of matching loose prose.
const String cancelledCommandOutput = 'Tool execution cancelled';

/// True when [output] is the known cancellation result.
///
/// A cancelled attempt is a distinct lifecycle state, never "completed" and
/// never an error the user should re-run automatically.
bool looksLikeCancelledCommandOutput(String? output) {
  if (output == null) return false;
  final trimmed = output.trim();
  if (trimmed.isEmpty) return false;
  if (trimmed == cancelledCommandOutput) return true;
  // Structured results may carry status=cancelled instead of prose.
  return trimmed.contains('"status":"cancelled"') ||
      trimmed.contains('"status": "cancelled"');
}

/// Classify a single bash attempt for the chat tool card.
///
/// Only observable transcript/run state is used, so the same function also
/// serves the System Health "last command" tile.
///
/// - a result means the attempt is terminal (`cancelled` or `completed`);
/// - no result plus `interruptedUnknown` means the app died mid-command;
/// - no result plus `runningNow` is a live command;
/// - otherwise the attempt is proposed/approved and waiting (`started`).
ToolCommandLifecycle classifyBashToolAttempt({
  required bool hasResult,
  required bool runningNow,
  required bool interruptedUnknown,
  String? resultOutput,
}) {
  if (hasResult) {
    return looksLikeCancelledCommandOutput(resultOutput)
        ? ToolCommandLifecycle.cancelled
        : ToolCommandLifecycle.completed;
  }
  if (interruptedUnknown) return ToolCommandLifecycle.interruptedUnknown;
  if (runningNow) return ToolCommandLifecycle.running;
  return ToolCommandLifecycle.started;
}

/// The machine-level "last command" state surfaced by System Health.
///
/// `none` is honest about a fresh machine and is rendered as neutral, never as
/// an error. This intentionally mirrors the three states in the I3 contract
/// plus the empty case.
enum MachineLastCommand { none, running, exited, unknown }

extension MachineLastCommandCopy on MachineLastCommand {
  String get detail => switch (this) {
        MachineLastCommand.none => '本次运行还没有执行过命令',
        MachineLastCommand.running => '有一条命令正在运行',
        MachineLastCommand.exited => '上一条命令已经结束',
        MachineLastCommand.unknown => '上一条命令可能没有完成，结果未知；不会静默重试',
      };
}

/// Resolve the last command state from the current session transcript.
///
/// [runningNow] is true while the agent is executing a tool
/// (`AgentStatus.tooling`). [interruptedUnknown] is true when the session
/// carries an interrupted agent run whose bash attempt lost its outcome.
MachineLastCommand classifyLastCommand({
  required List<ChatMessage>? messages,
  required bool runningNow,
  required bool interruptedUnknown,
}) {
  if (messages == null || messages.isEmpty) return MachineLastCommand.none;
  for (var index = messages.length - 1; index >= 0; index--) {
    final message = messages[index];
    for (final content in message.content.reversed) {
      if (content is! ToolUseContent || content.name != bashToolName) continue;
      final result = _resultForToolUse(messages, index, content.id);
      final lifecycle = classifyBashToolAttempt(
        hasResult: result != null,
        runningNow: runningNow,
        interruptedUnknown: interruptedUnknown,
        resultOutput: result?.output,
      );
      return switch (lifecycle) {
        ToolCommandLifecycle.started ||
        ToolCommandLifecycle.running =>
          MachineLastCommand.running,
        ToolCommandLifecycle.completed => MachineLastCommand.exited,
        ToolCommandLifecycle.cancelled ||
        ToolCommandLifecycle.interruptedUnknown =>
          MachineLastCommand.unknown,
      };
    }
  }
  return MachineLastCommand.none;
}

/// Results for a tool call are stored on the message that immediately follows
/// the assistant message carrying the `tool_use` block.
ToolResultContent? _resultForToolUse(
  List<ChatMessage> messages,
  int messageIndex,
  String toolUseId,
) {
  final resultIndex = messageIndex + 1;
  if (resultIndex >= messages.length) return null;
  final resultMessage = messages[resultIndex];
  if (resultMessage.role != 'user') return null;
  for (final result in resultMessage.toolResults) {
    if (result.toolUseId == toolUseId) return result;
  }
  return null;
}
