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
        File('pubspec.yaml').readAsStringSync(), contains('version: 2.5.2+8'));
    expect(
      File('lib/constants.dart').readAsStringSync(),
      contains("version = '2.5.2'"),
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
}
