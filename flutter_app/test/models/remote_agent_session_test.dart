import 'package:clawchat/models/chat_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('remote connector opt-in round-trips per session and defaults local',
      () {
    final local = ChatSession(id: 'local_session');
    final remote = ChatSession(
      id: 'remote_session',
      remoteAgentConnectorId: 'primary_remote',
    );

    expect(ChatSession.fromJson(local.toJson()).remoteAgentConnectorId, isNull);
    expect(
      ChatSession.fromJson(remote.toJson()).remoteAgentConnectorId,
      'primary_remote',
    );
    expect(
      remote.copyWith(clearRemoteAgentConnector: true).remoteAgentConnectorId,
      isNull,
    );
  });
}
