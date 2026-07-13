import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('foreground service keeps explicit approval actions and wake lock', () {
    final service = File(
      'android/app/src/main/kotlin/com/anka/clawbot/AgentTaskService.kt',
    ).readAsStringSync();
    final state = File(
      'android/app/src/main/kotlin/com/anka/clawbot/ToolApprovalNotificationState.kt',
    ).readAsStringSync();
    expect(service, contains('startForeground(state.notificationId'));
    expect(service, contains('.setOngoing(ongoing)'));
    expect(service, contains('PARTIAL_WAKE_LOCK'));
    expect(service, contains('ACTION_TOOL_APPROVAL_DECISION'));
    expect(service, contains('"拒绝", denyPendingIntent'));
    expect(service, contains('"允许一次", approvePendingIntent'));
    expect(service, contains('onToolApprovalDecision'));
    expect(service, contains('APPROVAL_DELIVERY_TIMEOUT_MS'));
    expect(service, contains('attachCallbackChannel'));
    expect(service, contains('detachCallbackChannel'));
    expect(state, contains('clawchat-approval'));
    expect(service, contains('FLAG_CANCEL_CURRENT'));
    expect(service, contains('areNotificationsEnabled'));
    expect(service, contains('IMPORTANCE_NONE'));
    expect(service, contains('if (intent == null)'));
    expect(service, contains('return START_NOT_STICKY'));
    expect(service, isNot(contains('autoApprove')));
  });

  test('manifest declares auditable special-use foreground service', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(manifest, contains('android.permission.FOREGROUND_SERVICE'));
    expect(
      manifest,
      contains('android.permission.FOREGROUND_SERVICE_SPECIAL_USE'),
    );
    expect(manifest, contains('android:name=".AgentTaskService"'));
    expect(manifest, contains('android:foregroundServiceType="specialUse"'));
    expect(manifest, contains('AI agent tasks alive'));
  });

  test('FlutterEngine owns and retires the exact callback generation', () {
    final activity = File(
      'android/app/src/main/kotlin/com/anka/clawbot/MainActivity.kt',
    ).readAsStringSync();
    expect(activity, contains('AgentTaskService.attachCallbackChannel'));
    expect(activity, contains('override fun cleanUpFlutterEngine'));
    expect(activity, contains('AgentTaskService.detachCallbackChannel'));
    expect(activity, contains('IdentityHashMap<FlutterEngine'));
    expect(activity, contains('agentCallbackOwners.remove(flutterEngine)'));
  });
}
