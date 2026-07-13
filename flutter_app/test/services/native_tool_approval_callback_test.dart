import 'dart:async';

import 'package:clawchat/constants.dart';
import 'package:clawchat/services/native_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('native approval action delivers exact identity and decision once',
      () async {
    var calls = 0;
    NativeBridge.setToolApprovalDecisionHandler(({
      required sessionId,
      required approvalId,
      required approved,
    }) async {
      calls += 1;
      expect(sessionId, 'session-a');
      expect(approvalId, 'operation-a');
      expect(approved, isTrue);
      return true;
    });
    addTearDown(() => NativeBridge.setToolApprovalDecisionHandler(null));

    const codec = StandardMethodCodec();
    final response = Completer<ByteData?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      '${AppConstants.channelName}/agent_callbacks',
      codec.encodeMethodCall(const MethodCall(
        'onToolApprovalDecision',
        {
          'sessionId': 'session-a',
          'approvalId': 'operation-a',
          'approved': true,
        },
      )),
      response.complete,
    );

    final payload = await response.future;
    expect(payload, isNotNull);
    expect(codec.decodeEnvelope(payload!), isTrue);
    expect(calls, 1);
  });
}
