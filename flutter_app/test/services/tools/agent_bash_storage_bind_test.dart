import 'package:clawchat/constants.dart';
import 'package:clawchat/services/tools/bash_tool.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression guard for the I3 workspace boundary:
/// agent bash must never bind shared Android storage (`/storage`, `/sdcard`).
///
/// The native flag builder is covered separately in
/// `flutter_app/android/app/src/test/kotlin/com/anka/clawbot/AgentBashStorageBindTest.kt`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(AppConstants.channelName);
  final tool = BashTool();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'runInProot') return 'ok';
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<Map<String, Object?>> runAndCapture(String command) async {
    MethodCall? runCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'runInProot') {
        runCall = call;
        return 'ok';
      }
      return null;
    });

    final output = await tool.executeWithContext(
      {'command': command, 'timeout': 30},
      sessionId: 'storage-bind-session',
    );
    expect(output.trim(), 'ok');
    expect(runCall, isNotNull, reason: 'runInProot must be invoked');
    return Map<String, Object?>.from(runCall!.arguments as Map);
  }

  test('agent bash never requests a shared-storage bind', () async {
    final arguments = await runAndCapture('ls /storage/emulated/0');
    expect(arguments['mountStorage'], isFalse);
  });

  test('a command naming /sdcard still does not gain a storage bind', () async {
    final arguments = await runAndCapture('cat /sdcard/notes.txt');
    expect(arguments['mountStorage'], isFalse);
  });

  test('an unexpected input cannot turn the storage bind on', () async {
    MethodCall? runCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'runInProot') {
        runCall = call;
        return 'ok';
      }
      return null;
    });

    final output = await tool.executeWithContext(
      const {
        'command': 'echo ok',
        'mount_storage': true,
        'mountStorage': true,
        'storage': true,
      },
      sessionId: 'storage-bind-session',
    );
    expect(output.trim(), 'ok');
    final arguments = Map<String, Object?>.from(runCall!.arguments as Map);
    expect(arguments['mountStorage'], isFalse);
  });

  test('the bash schema exposes no storage-mount toggle', () {
    final properties = tool.inputSchema['properties'] as Map;
    expect(properties.keys, isNot(contains('mount_storage')));
    expect(properties.keys, isNot(contains('mountStorage')));
    expect(properties.keys, isNot(contains('storage')));
  });

  test('the bash description states shared storage is not mounted', () {
    expect(tool.description.toLowerCase(), contains('not mounted'));
  });
}
