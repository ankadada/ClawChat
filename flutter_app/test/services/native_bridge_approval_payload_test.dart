import 'package:clawchat/constants.dart';
import 'package:clawchat/services/native_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(AppConstants.channelName);
  late List<Map<String, Object?>> calls;

  setUp(() {
    calls = <Map<String, Object?>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add({
        'method': call.method,
        'arguments': Map<String, Object?>.from(call.arguments as Map? ?? {}),
      });
      if (call.method == 'showToolApprovalNotification') return true;
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('background approval payload carries the exact web URL', () async {
    final shown = await NativeBridge.showToolApprovalNotification(
      sessionId: 'session-1',
      sessionTitle: 'Title',
      approvalId: 'op-1',
      toolName: 'web_fetch',
      risk: 'moderate',
      detail: 'https://evil.example/path?q=1',
    );

    expect(shown, true);
    final payload = calls.single['arguments'] as Map<String, Object?>;
    expect(payload['detail'], 'https://evil.example/path?q=1');
    expect(payload['toolName'], 'web_fetch');
  });

  test('a request without an exact destination omits the detail field',
      () async {
    await NativeBridge.showToolApprovalNotification(
      sessionId: 'session-1',
      sessionTitle: 'Title',
      approvalId: 'op-2',
      toolName: 'bash',
      risk: 'dangerous',
    );

    final payload = calls.single['arguments'] as Map<String, Object?>;
    expect(payload.containsKey('detail'), false);
  });
}
