import 'package:clawchat/models/agent_run_center.dart';
import 'package:clawchat/models/agent_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('maps the authoritative agent phases without content fields', () {
    expect(
      AgentRunCenterItem.phaseForStatus(AgentStatus.thinking),
      AgentRunCenterPhase.thinking,
    );
    expect(
      AgentRunCenterItem.phaseForStatus(AgentStatus.streaming),
      AgentRunCenterPhase.streaming,
    );
    expect(
      AgentRunCenterItem.phaseForStatus(AgentStatus.tooling),
      AgentRunCenterPhase.tooling,
    );
    expect(
      AgentRunCenterItem.phaseForStatus(AgentStatus.error),
      AgentRunCenterPhase.recoverableFailure,
    );
  });

  test('run center item is metadata only and has no serialization contract',
      () {
    const item = AgentRunCenterItem(
      sessionId: 'session-1',
      sessionTitle: 'Session',
      phase: AgentRunCenterPhase.waitingApproval,
      context: AgentRunCenterContext.local,
      waitingApproval: true,
    );
    expect(item.isActive, isTrue);
    expect(item.toString(), isNot(contains('prompt')));
    expect(item.toString(), isNot(contains('payload')));
  });
}
