import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// v2.18 AND-4 source guards.
///
/// The notification surfaces cannot be rendered on the host (they need an
/// Android device), so the invariants that must hold for every notification are
/// pinned against the source that builds them.
void main() {
  final agentTaskService = File(
    'android/app/src/main/kotlin/com/anka/clawbot/AgentTaskService.kt',
  );
  final mainActivity = File(
    'android/app/src/main/kotlin/com/anka/clawbot/MainActivity.kt',
  );
  final notificationPrivacy = File(
    'android/app/src/main/kotlin/com/anka/clawbot/NotificationPrivacy.kt',
  );
  final terminalService = File(
    'android/app/src/main/kotlin/com/anka/clawbot/TerminalSessionService.kt',
  );

  test('every agent notification keeps the lock screen generic', () {
    for (final file in [agentTaskService, mainActivity]) {
      // The pre-Android-O fallback opens a second builder inside the `else`
      // branch; fold it so one notification is one logical chunk.
      final source = file
          .readAsStringSync()
          .replaceAll('Notification.Builder(context)', 'BuilderNoChannel(')
          .replaceAll('Notification.Builder(this)', 'BuilderNoChannel(');
      final builders = source.split('Notification.Builder(');
      // The first chunk is everything before the first builder.
      for (var index = 1; index < builders.length; index++) {
        final chunk = builders[index];
        expect(
          chunk.contains('VISIBILITY_PRIVATE'),
          isTrue,
          reason: '${file.path}: builder #$index must be lock-screen private',
        );
        expect(
          chunk.contains('setPublicVersion'),
          isTrue,
          reason: '${file.path}: builder #$index must provide a public version',
        );
      }
      expect(builders.length, greaterThan(1));
    }
  });

  test('the public copy helper only receives generic text', () {
    final source = notificationPrivacy.readAsStringSync();
    // The generic copies are static strings; no session title, preview or
    // destination may be interpolated into them.
    final privacyBlock = source.substring(
      source.indexOf('internal object NotificationPrivacy'),
      source.indexOf('internal fun buildPublicNotification'),
    );
    expect(privacyBlock, isNot(contains(r'$preview')));
    expect(privacyBlock, isNot(contains(r'$detail')));
    expect(privacyBlock, isNot(contains(r'$title')));
    expect(privacyBlock, isNot(contains('setContentIntent')));
  });

  test('the completion notification opens the session and auto-cancels', () {
    final source = agentTaskService.readAsStringSync();
    final start = source.indexOf('fun showCompletionNotification(');
    expect(start, isNot(-1));
    final block = source.substring(start, start + 2500);
    expect(block, contains('setContentIntent'));
    expect(block, contains('setAutoCancel(true)'));
    expect(block, contains('AGENT_COMPLETE_CHANNEL_ID'));
    expect(block, contains('NotificationPrivacy.completion()'));
    // An empty summary still produces a readable notification.
    expect(block, contains('点击查看回复'));
  });

  test('each session gets its own notification id and a group summary', () {
    final source = agentTaskService.readAsStringSync();
    expect(
        source, contains('private fun notificationIdFor(sessionId: String)'));
    expect(
      source,
      contains('private fun completionNotificationIdFor(sessionId: String)'),
    );
    expect(source, contains('AGENT_GROUP_KEY'));
    expect(source, contains('setGroupSummary(true)'));
    // The group summary is opened in-app, never on the lock screen copy.
    expect(source, contains('NotificationPrivacy.summary('));
  });

  test('notifications never request a do-not-disturb bypass', () {
    for (final file in [agentTaskService, mainActivity, terminalService]) {
      final source = file.readAsStringSync();
      expect(source, isNot(contains('setBypassDnd(true)')));
      expect(source, isNot(contains('setSound(')));
    }
    // DND and per-app notification state are read, not forced.
    expect(
      agentTaskService.readAsStringSync(),
      contains('areNotificationsEnabled()'),
    );
  });

  test('the terminal foreground notification carries no user content', () {
    final source = terminalService.readAsStringSync();
    expect(source, contains('VISIBILITY_PRIVATE'));
    expect(source, isNot(contains('previewText')));
    expect(source, isNot(contains('sessionTitle')));
  });
}
