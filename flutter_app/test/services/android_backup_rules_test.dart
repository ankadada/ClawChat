import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins the Android backup/data-extraction scope:
///   * chat history and the allowlisted settings mirror are backed up;
///   * `FlutterSharedPreferences.xml` is never backed up, so a legacy
///     plaintext `api_key` / `env_vars` from an upgraded install cannot leak;
///   * the encrypted credential store is never backed up.
///
/// The rules are XML resources, so this test reads them directly instead of
/// pretending an Android backup run can be exercised on the host.
void main() {
  final root = _flutterRoot();

  String read(String relativePath) =>
      File('${root.path}/$relativePath').readAsStringSync();

  String stripComments(String xml) =>
      xml.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

  final manifest = read('android/app/src/main/AndroidManifest.xml');
  final backupRules =
      stripComments(read('android/app/src/main/res/xml/backup_rules.xml'));
  final extractionRules = stripComments(
    read('android/app/src/main/res/xml/data_extraction_rules.xml'),
  );

  const secureStorageFiles = [
    'FlutterSecureStorage.xml',
    'FlutterSecureKeyStore.xml',
    'com.it_nomads.fluttersecurestorage.xml',
  ];

  List<(String domain, String path)> entries(String xml, String element) {
    final pattern = RegExp(
      '<$element\\s+domain="([^"]+)"\\s+path="([^"]+)"\\s*/>',
    );
    return pattern
        .allMatches(xml)
        .map((match) => (match.group(1)!, match.group(2)!))
        .toList(growable: false);
  }

  test('manifest keeps backup enabled and points at both rule files', () {
    expect(manifest, contains('android:allowBackup="true"'));
    expect(manifest, contains('android:fullBackupContent="@xml/backup_rules"'));
    expect(
      manifest,
      contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
    );
  });

  test('backup rules keep the settings mirror and chat history', () {
    final includes = entries(backupRules, 'include');
    final excludes = entries(backupRules, 'exclude');

    expect(includes, contains(('sharedpref', '.')));
    expect(includes, contains(('file', 'app_flutter/clawchat_sessions')));
    expect(
      includes,
      contains(('file', 'app_flutter/clawchat_settings_backup.json')),
    );
    for (final file in secureStorageFiles) {
      expect(excludes, contains(('sharedpref', file)));
    }
    // A legacy plaintext api_key / env_vars can still live in the main
    // preferences file until the first launch migrates it, and a backup can
    // run before that launch. The whole file is excluded; non-secret settings
    // travel in the allowlisted mirror instead.
    expect(
      excludes,
      contains(('sharedpref', 'FlutterSharedPreferences.xml')),
    );
  });

  test('a legacy plaintext credential file can never be included', () {
    // The rules cannot filter keys, so the only safe shape is: the file that
    // held a plaintext key is excluded and the mirror is a separate file.
    final excludedPaths =
        entries(backupRules, 'exclude').map((entry) => entry.$2).toSet();
    final includedPaths =
        entries(backupRules, 'include').map((entry) => entry.$2).toSet();

    expect(excludedPaths, contains('FlutterSharedPreferences.xml'));
    expect(includedPaths, isNot(contains('FlutterSharedPreferences.xml')));
    expect(includedPaths, contains('app_flutter/clawchat_settings_backup.json'));
    // The mirror never carries a credential key, and the only profile metadata
    // it exports is the non-secret identity fields (no key, no base URL).
    final mirror = read('lib/services/settings_backup_mirror.dart');
    expect(mirror, contains('exportAllSettings()'));
    expect(mirror, contains('exportProfileMetadata()'));
    expect(mirror, isNot(contains('apiKey')));
    expect(mirror, isNot(contains('envVars')));

    final preferences = read('lib/services/preferences_service.dart');
    final metadataStart =
        preferences.indexOf('List<Map<String, dynamic>> exportProfileMetadata()');
    expect(metadataStart, greaterThan(0));
    final metadataEnd = preferences
        .indexOf('Future<int> restoreProfilePlaceholders', metadataStart);
    expect(metadataEnd, greaterThan(metadataStart));
    final metadataBody = preferences.substring(metadataStart, metadataEnd);
    expect(metadataBody, contains("'id': profile.id"));
    expect(metadataBody, isNot(contains("'apiKey'")));
    expect(metadataBody, isNot(contains("'baseUrl'")));
    expect(metadataBody, isNot(contains('capabilityOverride')));
  });

  test('data extraction rules match the legacy scope for both flows', () {
    for (final section in ['cloud-backup', 'device-transfer']) {
      final start = extractionRules.indexOf('<$section>');
      final end = extractionRules.indexOf('</$section>');
      expect(start, greaterThanOrEqualTo(0), reason: '$section missing');
      expect(end, greaterThan(start), reason: '$section missing');
      final body = extractionRules.substring(start, end);

      final includes = entries(body, 'include');
      final excludes = entries(body, 'exclude');
      expect(includes, contains(('sharedpref', '.')));
      expect(includes, contains(('file', 'app_flutter/clawchat_sessions')));
      expect(
        includes,
        contains(('file', 'app_flutter/clawchat_settings_backup.json')),
      );
      for (final file in secureStorageFiles) {
        expect(excludes, contains(('sharedpref', file)));
      }
      expect(
        excludes,
        contains(('sharedpref', 'FlutterSharedPreferences.xml')),
      );
    }
  });

  test('backup include matches the directory SessionStorage writes to', () {
    final sessionStorage = read('lib/services/session_storage.dart');
    expect(sessionStorage, contains('/clawchat_sessions'));

    final fileIncludes = entries(backupRules, 'include')
        .where((entry) => entry.$1 == 'file')
        .map((entry) => entry.$2);
    expect(fileIncludes, contains('app_flutter/clawchat_sessions'));
  });

  test('credential keys never reach the plaintext preferences file', () {
    final source = read('lib/services/preferences_service.dart');

    // These four keys hold credentials. They must go to the encrypted store,
    // never to FlutterSharedPreferences.xml, which stays excluded from backup
    // but is still the file a legacy install may have written in plaintext.
    for (final key in [
      '_keyApiKey',
      '_keyEnvVars',
      '_keyProviderProfiles',
      '_keyMcpServers',
    ]) {
      expect(
        source,
        isNot(contains('_prefs.setString($key')),
        reason: '$key must not be written to SharedPreferences',
      );
    }
    expect(source, contains('_secureStorage.write(key: _keyApiKey'));
    expect(source, contains('_secureStorage.read(key: _keyProviderProfiles)'));
    expect(source, contains('_secureStorage.read(key: _keyMcpServers)'));
  });
}

Directory _flutterRoot() {
  final current = Directory.current;
  if (File('${current.path}/pubspec.yaml').existsSync()) return current;
  final candidate = Directory('${current.path}/flutter_app');
  if (File('${candidate.path}/pubspec.yaml').existsSync()) return candidate;
  throw StateError('flutter_app root not found from ${current.path}');
}
