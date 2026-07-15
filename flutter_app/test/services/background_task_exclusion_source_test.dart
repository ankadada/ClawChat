import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('v2.8 background task scheduler exclusions', () {
    test(
        'production dependencies and manifest add no scheduler or boot receiver',
        () {
      final root = _flutterRoot();
      final pubspec = File('${root.path}/pubspec.yaml').readAsStringSync();
      final manifest =
          File('${root.path}/android/app/src/main/AndroidManifest.xml')
              .readAsStringSync();

      expect(pubspec, isNot(contains('workmanager:')));
      expect(pubspec, isNot(contains('android_alarm_manager')));
      expect(manifest, isNot(contains('<receiver')));
      expect(manifest, isNot(contains('android.intent.action.BOOT_COMPLETED')));
    });

    test('task coordinator has no timer isolate scheduler or automatic retry',
        () {
      final source = _read('lib/services/background_task_coordinator.dart');

      for (final forbidden in const [
        'Timer(',
        'Isolate.',
        'schedule(',
        'retry(',
        'WorkManager',
        'AlarmManager',
      ]) {
        expect(source, isNot(contains(forbidden)));
      }
      expect(source, contains('reconcileOnStartup'));
      expect(source, contains('never starts, retries, or requeues'));
      expect(source, contains('unknownOutcome'));
    });

    test(
        'native foreground service is owner-scoped helper without task storage',
        () {
      final service = _read(
        'android/app/src/main/kotlin/com/anka/clawbot/AgentTaskService.kt',
      );
      final bridge = _read('lib/services/native_bridge.dart');
      final activity = _read(
        'android/app/src/main/kotlin/com/anka/clawbot/MainActivity.kt',
      );

      expect(service, contains('OWNER_KIND_BACKGROUND_TASK'));
      expect(service, contains('activeBackgroundTaskLeases'));
      expect(service, contains('startBackgroundTaskLeaseAndAwaitReady'));
      expect(service, contains('BackgroundTaskLeaseStartRequest'));
      expect(service, contains('onBackgroundTaskLeaseInterrupted'));
      expect(service,
          contains('removeBackgroundTaskLease(executionOwnerId, sessionId)'));
      expect(service, isNot(contains('BackgroundTaskStore')));
      expect(service, isNot(contains('WorkManager')));
      expect(service, isNot(contains('AlarmManager')));
      expect(service, contains('no payload/preview is ever retained here'));
      expect(bridge, contains('startBackgroundTaskLease'));
      expect(bridge, contains('stopBackgroundTaskLease'));
      expect(bridge, contains('executionOwnerId'));
      expect(bridge, contains('ownerKind'));
      expect(activity, contains('"startBackgroundTaskLease"'));
      expect(activity, contains('"stopBackgroundTaskLease"'));
      expect(
        activity,
        contains('result.success(established)'),
      );
      expect(
        activity,
        contains(
            'result.success(\n                                AgentTaskService.updateBackgroundTaskLease'),
      );
    });

    test('native task lease bridge cannot carry task preview or payload', () {
      final source =
          _read('lib/services/background_task_foreground_lease.dart');

      expect(source, contains('never receives task payload'));
      expect(source, isNot(contains('previewText')));
      expect(source, isNot(contains('localPayload')));
      expect(source, isNot(contains('execute(')));
    });

    test('production definitions stay finite and foreground-user driven', () {
      final definitions =
          _read('lib/services/background_task_definitions.dart');
      final center =
          _read('lib/services/background_task_center_controller.dart');

      expect(definitions, contains('rememberFactKind'));
      expect(definitions, contains('shareTextKind'));
      expect(definitions, contains('finite, app-owned v2.8 registry'));
      expect(definitions, isNot(contains('ToolRegistry')));
      expect(definitions, isNot(contains('runInProot')));
      expect(center, contains('reconcileAtStartup'));
      for (final forbidden in const [
        'Timer(',
        'Isolate.',
        'schedule(',
        'retry(',
        'WorkManager',
        'AlarmManager',
      ]) {
        expect(center, isNot(contains(forbidden)));
      }
    });
  });
}

Directory _flutterRoot() {
  final current = Directory.current;
  if (File('${current.path}/pubspec.yaml').existsSync()) return current;
  final candidate = Directory('${current.path}/flutter_app');
  if (File('${candidate.path}/pubspec.yaml').existsSync()) return candidate;
  throw StateError('Flutter project root was not found.');
}

String _read(String relativePath) =>
    File('${_flutterRoot().path}/$relativePath').readAsStringSync();
