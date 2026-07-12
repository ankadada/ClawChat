import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final service =
      File('lib/services/remote_agent_connector.dart').readAsStringSync();
  final model =
      File('lib/models/remote_agent_connector.dart').readAsStringSync();

  test('production connector has one non-bypassable pinned transport policy',
      () {
    expect(service, isNot(contains('HttpClient(')));
    expect(service, isNot(contains('IOClient(')));
    expect(service, isNot(contains('Dio(')));
    expect(service, isNot(contains('forTesting')));
    expect(service, isNot(contains('required http.Client')));
    expect(service, isNot(contains('beforeCommit')));
    expect(service, contains('required AppWebFetchClient client'));
    expect(service, contains('final AppWebFetchClient _client'));
    expect(service, isNot(contains('_client.close(')));
    expect(service, isNot(contains('_isPrivateAddress')));
    expect(service, isNot(contains('_isDisallowedHost')));
    expect(service, contains('_RemoteAgentCancellationLifecycle.unused'));
    expect(service, contains('_RemoteAgentCancellationLifecycle.claimed'));
    expect(service, contains('_RemoteAgentCancellationLifecycle.retired'));
    final connectorStart = service.indexOf(
      'final class CozeOpenApiRemoteAgentConnector',
    );
    final sendStart = service.indexOf(
      'Stream<RemoteAgentEvent> send(',
      connectorStart,
    );
    final claim = service.indexOf('operationCancellation._claim()', sendStart);
    final timer = service.indexOf('Timer(totalDeadline', sendStart);
    final resolver = service.indexOf('_credentialResolver.resolve(', sendStart);
    final firstAwait = service.indexOf('await ', sendStart);
    expect(claim, greaterThan(sendStart));
    expect(timer, greaterThan(claim));
    expect(resolver, greaterThan(claim));
    expect(firstAwait, greaterThan(claim));
    expect(
        service.indexOf('claim.retire()', firstAwait), greaterThan(firstAwait));
  });

  test('connector has terminal-only commit and no background/cloud behavior',
      () {
    expect(service, isNot(contains('RemoteAgentTextDelta')));
    expect(service, contains('enum _SseState'));
    expect(service, contains('_SseState.accumulating'));
    expect(service, contains('_SseState.messageCompleted'));
    expect(service, contains('_SseState.streamTerminal'));
    expect(service, contains('final output = StringBuffer()'));
    expect(RegExp(r'sanitizeText\(').allMatches(service), hasLength(1));
    expect(service, contains('lineBytes.length > maxSseLineBytes'));
    expect(service, isNot(contains('pending.sublist')));
    expect(service, isNot(contains('pending.indexOf')));
    final gate = service.indexOf('await Future<void>.delayed(Duration.zero)');
    final deadline =
        service.indexOf('if (operationCancellation.isDeadlineExpired)', gate);
    final cancellation =
        service.indexOf('if (operationCancellation.isCancelled)', deadline);
    final commit = service.indexOf('yield RemoteAgentComplete', cancellation);
    expect(gate, greaterThan(0));
    expect(deadline, greaterThan(gate));
    expect(cancellation, greaterThan(deadline));
    expect(commit, greaterThan(cancellation));
    for (final forbidden in [
      'cloudSync',
      'backgroundUpload',
      'telemetry',
      'Timer.periodic',
      'auto_save_history\': true',
    ]) {
      expect(service, isNot(contains(forbidden)), reason: forbidden);
    }
    expect(service, contains("'auto_save_history': false"));
  });

  test('persisted consent uses SHA-256 and exact schemas', () {
    expect(model, contains('sha256.convert'));
    expect(model, isNot(contains('0x811c9dc5')));
    expect(service, contains('sha256.convert'));
    expect(service, isNot(contains('0x811c9dc5')));
    expect(model, contains('_requireExactKeys'));
    expect(model, contains('RemoteAgentCredentialReference'));
  });
}
