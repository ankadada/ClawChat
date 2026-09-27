import 'dart:convert';
import 'dart:io';

import 'package:clawchat/models/provider_profile.dart';
import 'package:clawchat/services/preferences_service.dart';
import 'package:clawchat/services/settings_backup_mirror.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late Map<String, String> secureStorage;
  late Directory tempDir;
  var failSecureWrites = false;

  setUp(() async {
    secureStorage = {};
    failSecureWrites = false;
    tempDir = await Directory.systemTemp.createTemp('settings_mirror_');
    SharedPreferences.setMockInitialValues({});
    PreferencesService.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
      final key = args['key']?.toString();
      switch (call.method) {
        case 'read':
          return key == null ? null : secureStorage[key];
        case 'write':
          if (failSecureWrites) {
            throw PlatformException(code: 'KEYSTORE_UNAVAILABLE');
          }
          if (key != null) {
            secureStorage[key] = args['value']?.toString() ?? '';
          }
          return null;
        case 'delete':
          if (key != null) secureStorage.remove(key);
          return null;
        case 'deleteAll':
          secureStorage.clear();
          return null;
        case 'containsKey':
          return key != null && secureStorage.containsKey(key);
        case 'readAll':
          return Map<String, String>.from(secureStorage);
      }
      return null;
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
    PreferencesService.resetForTesting();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  SettingsBackupMirror mirror({PreferencesService? prefs}) =>
      SettingsBackupMirror(
        prefs: prefs,
        documentsDirectory: () async => tempDir,
      );

  File mirrorFile() => File('${tempDir.path}/${SettingsBackupMirror.fileName}');

  Future<Map<String, dynamic>> readMirror() async =>
      Map<String, dynamic>.from(
        jsonDecode(await mirrorFile().readAsString()) as Map,
      );

  test('save writes an allowlisted snapshot without credentials', () async {
    SharedPreferences.setMockInitialValues({
      'dark_mode': 'dark',
      'font_size': 1.25,
      'agent_max_iterations': 7,
      'allow_sms': true,
      'api_key': 'sk-legacy-plaintext',
      'env_vars': '{"GOOGLE_ACCESS_TOKEN":"secret-token"}',
    });
    final prefs = PreferencesService();
    await prefs.init();
    await prefs.setProfiles([
      ProviderProfile.defaults(name: 'Work').copyWith(
        id: 'profile-work',
        apiKey: 'sk-profile-secret',
        baseUrl: 'https://private.example/v1',
        model: 'claude-work',
      ),
    ]);

    await mirror(prefs: prefs).save();

    final snapshot = await readMirror();
    expect(snapshot['version'], SettingsBackupMirror.schemaVersion);
    final settings = Map<String, dynamic>.from(snapshot['settings'] as Map);
    expect(settings['themeMode'], 'dark');
    expect(settings['fontScale'], 1.25);
    expect(settings['agentMaxIterations'], 7);
    expect(settings['allowSms'], isTrue);

    // The non-secret profile identity is kept so model groups stay resolvable
    // after a restore; the credential and the endpoint are not.
    final profiles = (snapshot['providerProfiles'] as List)
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .toList();
    final work = profiles.singleWhere((entry) => entry['id'] == 'profile-work');
    expect(work['name'], 'Work');
    expect(work['model'], 'claude-work');
    expect(work.containsKey('apiKey'), isFalse);
    expect(work.containsKey('baseUrl'), isFalse);

    final raw = await mirrorFile().readAsString();
    expect(raw, isNot(contains('sk-legacy-plaintext')));
    expect(raw, isNot(contains('secret-token')));
    expect(raw, isNot(contains('sk-profile-secret')));
    expect(raw, isNot(contains('private.example')));
    expect(settings.keys, isNot(contains('apiKey')));
    expect(settings.keys, isNot(contains('api_key')));
    expect(settings.keys, isNot(contains('envVars')));
    expect(settings.keys, isNot(contains('mcpServers')));
    expect(settings.keys, isNot(contains('providerProfiles')));
  });

  test('restoreIfFresh applies an allowlisted snapshot on a fresh install',
      () async {
    await mirrorFile().writeAsString(jsonEncode({
      'version': SettingsBackupMirror.schemaVersion,
      'exportedAt': '2026-09-24T00:00:00.000Z',
      'settings': {
        'themeMode': 'dark',
        'agentMaxIterations': 42,
        'toolApprovalPolicy': PreferencesService.toolApprovalAuto,
        'allowSms': true,
        'memoryEnabled': false,
        'bashCommandDenyPatterns': ['curl'],
      },
    }));

    final prefs = PreferencesService();
    final restored = await mirror(prefs: prefs).restoreIfFresh();

    expect(restored, isTrue);
    expect(prefs.themeMode, 'dark');
    expect(prefs.agentMaxIterations, 42);
    expect(prefs.toolApprovalPolicy, PreferencesService.toolApprovalAuto);
    expect(prefs.allowSms, isTrue);
    expect(prefs.memoryEnabled, isFalse);
    expect(prefs.bashCommandDenyPatterns, ['curl']);
    expect(prefs.settingsInitialized, isTrue);
  });

  test('restoreIfFresh never overrides an already initialized install',
      () async {
    SharedPreferences.setMockInitialValues({
      'settings_initialized_v1': true,
      'dark_mode': 'light',
    });
    await mirrorFile().writeAsString(jsonEncode({
      'version': SettingsBackupMirror.schemaVersion,
      'settings': {'themeMode': 'dark', 'agentMaxIterations': 42},
    }));

    final prefs = PreferencesService();
    final restored = await mirror(prefs: prefs).restoreIfFresh();

    expect(restored, isFalse);
    expect(prefs.themeMode, 'light');
    expect(prefs.agentMaxIterations,
        PreferencesService.defaultAgentMaxIterations);
  });

  test('a missing mirror marks the install initialized without importing',
      () async {
    final prefs = PreferencesService();
    final restored = await mirror(prefs: prefs).restoreIfFresh();

    expect(restored, isFalse);
    expect(prefs.settingsInitialized, isTrue);
  });

  test('corrupt or oversized mirrors are ignored', () async {
    await mirrorFile().writeAsString('not json at all');
    final prefs = PreferencesService();
    expect(await mirror(prefs: prefs).restoreIfFresh(), isFalse);
    expect(prefs.settingsInitialized, isTrue);

    PreferencesService.resetForTesting();
    await mirrorFile().writeAsString(
      'x' * (SettingsBackupMirror.maxFileBytes + 1),
    );
    final second = PreferencesService();
    expect(await mirror(prefs: second).restoreIfFresh(), isFalse);
  });

  test('restoreIfFresh rebuilds model groups from profile metadata',
      () async {
    await mirrorFile().writeAsString(jsonEncode({
      'version': SettingsBackupMirror.schemaVersion,
      'settings': {
        'activeProfileId': 'profile-old',
        'activeModelGroupId': 'group-1',
        'modelGroups': [
          {
            'id': 'group-1',
            'name': '工作组',
            'primaryProfileId': 'profile-old',
            'fallbackTargets': [
              {'targetProfileId': 'profile-old-2', 'modelOverride': ''},
            ],
          },
        ],
      },
      'providerProfiles': [
        {
          'id': 'profile-old',
          'name': '旧主力',
          'apiFormat': 'anthropic',
          'model': 'claude-x',
          'maxTokens': 4096,
          'thinkingBudget': 0,
          'temperature': 0.5,
        },
        {'id': 'profile-old-2', 'name': '旧备用', 'apiFormat': 'openai'},
      ],
    }));

    final prefs = PreferencesService();
    final restored = await mirror(prefs: prefs).restoreIfFresh();

    expect(restored, isTrue);
    // The profile IDs are back as keyless placeholders, so the restored model
    // group survives instead of being dropped by _sanitizeModelGroups.
    expect(prefs.modelGroups, hasLength(1));
    expect(prefs.modelGroups.single.id, 'group-1');
    expect(prefs.modelGroups.single.primaryProfileId, 'profile-old');
    expect(prefs.activeModelGroupId, 'group-1');
    expect(prefs.activeProfileId, 'profile-old');

    final restoredProfile =
        prefs.profiles.singleWhere((profile) => profile.id == 'profile-old');
    expect(restoredProfile.name, '旧主力');
    expect(restoredProfile.apiKey, isEmpty);
    expect(restoredProfile.baseUrl, isEmpty);
  });

  test('a failed restore leaves the fresh marker unset and retries', () async {
    await mirrorFile().writeAsString(jsonEncode({
      'version': SettingsBackupMirror.schemaVersion,
      'settings': {'themeMode': 'dark'},
      'providerProfiles': const [],
    }));

    final prefs = PreferencesService();
    var attempts = 0;
    final failing = SettingsBackupMirror(
      prefs: prefs,
      documentsDirectory: () async => tempDir,
      restorer: (settings, profiles) async {
        attempts++;
        // The marker must stay unset while the restore is still running.
        expect(prefs.settingsInitialized, isFalse);
        if (attempts == 1) throw StateError('restore interrupted');
      },
    );

    await expectLater(failing.restoreIfFresh(), throwsStateError);
    expect(prefs.settingsInitialized, isFalse);

    // The next launch retries and only marks the restore consumed after the
    // restore future completed.
    expect(await failing.restoreIfFresh(), isTrue);
    expect(prefs.settingsInitialized, isTrue);
    expect(attempts, 2);
  });

  test('a partial restore write leaves the marker unset and retries',
      () async {
    await mirrorFile().writeAsString(jsonEncode({
      'version': SettingsBackupMirror.schemaVersion,
      'settings': {'themeMode': 'dark'},
      'providerProfiles': [
        {'id': 'profile-old', 'name': '旧主力'},
      ],
    }));

    final prefs = PreferencesService();
    await prefs.init();
    failSecureWrites = true;

    // The real restore path fails while persisting the placeholder profile,
    // which happens before any setting is applied and before the marker.
    await expectLater(
      mirror(prefs: prefs).restoreIfFresh(),
      throwsA(isA<PlatformException>()),
    );
    expect(prefs.settingsInitialized, isFalse);

    failSecureWrites = false;
    expect(await mirror(prefs: prefs).restoreIfFresh(), isTrue);
    expect(prefs.settingsInitialized, isTrue);
    expect(prefs.themeMode, 'dark');
    expect(
      prefs.profiles.any((profile) => profile.id == 'profile-old'),
      isTrue,
    );
  });

  test('the marker is written only after the restore write finished',
      () async {
    await mirrorFile().writeAsString(jsonEncode({
      'version': SettingsBackupMirror.schemaVersion,
      'settings': {'themeMode': 'dark'},
      'providerProfiles': const [],
    }));

    final prefs = PreferencesService();
    var markerDuringRestore = true;
    final mirror = SettingsBackupMirror(
      prefs: prefs,
      documentsDirectory: () async => tempDir,
      restorer: (settings, profiles) async {
        markerDuringRestore = prefs.settingsInitialized;
      },
    );

    expect(await mirror.restoreIfFresh(), isTrue);
    expect(markerDuringRestore, isFalse);
    expect(prefs.settingsInitialized, isTrue);
  });

  test('save then fresh-install restore round-trips the settings', () async {
    SharedPreferences.setMockInitialValues({
      'dark_mode': 'dark',
      'font_size': 1.3,
      'notify_on_complete': false,
      'allow_phone_call': true,
    });
    final first = PreferencesService();
    await first.init();
    await mirror(prefs: first).save();

    PreferencesService.resetForTesting();
    SharedPreferences.setMockInitialValues({});
    final second = PreferencesService();
    final restored = await mirror(prefs: second).restoreIfFresh();

    expect(restored, isTrue);
    expect(second.themeMode, 'dark');
    expect(second.fontScale, 1.3);
    expect(second.notifyOnComplete, isFalse);
    expect(second.allowPhoneCall, isTrue);
  });
}
