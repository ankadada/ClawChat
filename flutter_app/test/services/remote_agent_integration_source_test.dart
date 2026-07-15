import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('production connector is root-wired to pinned web fetch transport', () {
    final app = File('lib/app.dart').readAsStringSync();
    expect(app, contains('client: widget.httpRegistry.webFetchClient'));
    expect(app, contains('credentialResolver: configuration'));
    expect(app, contains('_remoteAgentRuntime.attach('));
    expect(app, isNot(contains('AppWebFetchClient.forTesting')));
  });

  test('remote metadata remains outside config and diagnostics exports', () {
    final configExport =
        File('lib/services/config_export_service.dart').readAsStringSync();
    final diagnostics =
        File('lib/services/diagnostics_export_service.dart').readAsStringSync();
    for (final source in [configExport, diagnostics]) {
      expect(source, isNot(contains('remoteAgentConnector')));
      expect(source, isNot(contains('credential_reference')));
      expect(source, isNot(contains('remote_agent_connector_config')));
    }
  });

  test('version authority has no stale runtime literal', () {
    expect(
        File('pubspec.yaml').readAsStringSync(), contains('version: 2.6.1+11'));
    expect(
      File('lib/constants.dart').readAsStringSync(),
      contains("version = '2.6.1'"),
    );
    for (final path in [
      'lib/constants.dart',
      'lib/services/app_http.dart',
      'lib/services/config_export_service.dart',
      'lib/services/diagnostics_export_service.dart',
    ]) {
      expect(File(path).readAsStringSync(), isNot(contains('2.4.0')),
          reason: path);
    }
  });

  test('direct Gradle invocation derives version only from pubspec', () {
    final gradle = File('android/app/build.gradle').readAsStringSync();
    expect(gradle, contains('rootProject.file("../pubspec.yaml")'));
    expect(
        gradle, contains('def flutterVersionName = pubspecVersion.group(1)'));
    expect(
        gradle, contains('def flutterVersionCode = pubspecVersion.group(2)'));
    expect(gradle, isNot(contains('getProperty("flutter.versionName")')));
    expect(gradle, isNot(contains('getProperty("flutter.versionCode")')));
  });

  test('android round icon has adaptive and pre-v26 fallbacks', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(
      manifest,
      contains('android:roundIcon="@mipmap/ic_launcher_round"'),
    );
    expect(
      File('android/app/src/main/res/mipmap-anydpi-v26/ic_launcher_round.xml')
          .existsSync(),
      isTrue,
    );
    for (final density in ['mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi']) {
      expect(
        File('android/app/src/main/res/mipmap-$density/ic_launcher_round.png')
            .existsSync(),
        isTrue,
        reason: density,
      );
    }
  });
}
