import 'dart:convert';

import 'package:clawchat/models/provider_profile.dart';
import 'package:clawchat/services/config_export_service.dart';
import 'package:clawchat/services/preferences_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late Map<String, String> secureStorage;

  setUp(() {
    secureStorage = {};
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

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
    PreferencesService.resetForTesting();
  });

  Future<PreferencesService> initPrefs() async {
    final prefs = PreferencesService();
    await prefs.init();
    return prefs;
  }

  void resetDevice() {
    secureStorage.clear();
    SharedPreferences.setMockInitialValues({});
    PreferencesService.resetForTesting();
  }

  test('default unencrypted export redacts secrets', () async {
    final prefs = await initPrefs();
    await prefs.setProfiles([
      ProviderProfile.defaults(name: 'Primary').copyWith(
        id: 'primary',
        apiKey: 'primary-key',
      ),
    ]);
    prefs.envVars = {'TOKEN': 'env-token'};
    await prefs.saveMcpServer(
      displayName: 'Local MCP',
      enabled: true,
      command: 'node',
      env: {'MCP_TOKEN': 'mcp-token'},
    );

    final exported = await ConfigExportService.exportConfig();
    final data = jsonDecode(exported) as Map<String, dynamic>;
    final secrets = data['secrets'] as Map<String, dynamic>;

    expect(secrets['encrypted'], isFalse);
    expect(secrets['redacted'], isTrue);
    expect(exported, isNot(contains('primary-key')));
    expect(exported, isNot(contains('env-token')));
    expect(exported, isNot(contains('mcp-token')));
    expect(exported, contains('********'));
  });

  test('explicit plaintext export includes secrets after caller confirmation',
      () async {
    final prefs = await initPrefs();
    await prefs.setProfiles([
      ProviderProfile.defaults(name: 'Primary').copyWith(
        id: 'primary',
        apiKey: 'primary-key',
      ),
    ]);
    prefs.envVars = {'TOKEN': 'env-token'};

    final exported = await ConfigExportService.exportConfig(
      includePlaintextSecrets: true,
    );

    expect(exported, contains('primary-key'));
    expect(exported, contains('env-token'));
  });

  test('encrypted export and import restores prompt profiles', () async {
    final prefs = await initPrefs();
    await prefs.savePromptProfile(
      name: 'Ops',
      systemPrompt: 'private migration prompt',
    );
    await prefs.savePromptProfile(
      name: 'Code',
      systemPrompt: 'review private code',
    );

    final exported = await ConfigExportService.exportConfig(
      password: 'backup-password',
    );
    final exportData = jsonDecode(exported) as Map<String, dynamic>;
    final secrets = exportData['secrets'] as Map<String, dynamic>;
    expect(secrets['encrypted'], isTrue);
    expect(exported, isNot(contains('private migration prompt')));
    expect(exported, isNot(contains('review private code')));

    resetDevice();
    final result = await ConfigExportService.importConfig(
      exported,
      password: 'backup-password',
      conflictResolution: ConflictResolution.replace,
    );

    final importedPrefs = await initPrefs();
    final restored = importedPrefs.promptProfiles;
    expect(result.promptProfilesImported, 2);
    expect(result.promptProfilesSkipped, 0);
    expect(
        restored.map((profile) => profile.name), containsAll(['Ops', 'Code']));
    expect(
      restored.map((profile) => profile.systemPrompt),
      containsAll(['private migration prompt', 'review private code']),
    );
  });

  test(
      'encrypted export and import preserves MCP servers without plaintext env',
      () async {
    final prefs = await initPrefs();
    await prefs.saveMcpServer(
      displayName: 'Local MCP',
      enabled: true,
      command: 'node',
      args: ['server.js'],
      env: {'MCP_TOKEN': 'mcp-token-placeholder'},
    );

    final exported = await ConfigExportService.exportConfig(
      password: 'backup-password',
    );
    final preview = ConfigExportService.previewImport(exported);
    expect(preview.isEncrypted, isTrue);
    expect(preview.mcpServerCount, -1);
    expect(exported, isNot(contains('mcp-token-placeholder')));
    expect(exported, isNot(contains('Local MCP')));

    resetDevice();
    final result = await ConfigExportService.importConfig(
      exported,
      password: 'backup-password',
      conflictResolution: ConflictResolution.replace,
    );

    final importedPrefs = await initPrefs();
    expect(result.mcpServersImported, 1);
    expect(importedPrefs.mcpServers, hasLength(1));
    expect(importedPrefs.mcpServers.single.displayName, 'Local MCP');
    expect(importedPrefs.mcpServers.single.env['MCP_TOKEN'],
        'mcp-token-placeholder');
  });

  test('encrypted export and import preserves provider fallback targets',
      () async {
    final prefs = await initPrefs();
    final primary = ProviderProfile.defaults(name: 'Primary').copyWith(
      id: 'primary',
      apiKey: 'primary-key',
      model: 'primary-model',
      fallbackTargets: const [
        ModelFallbackTarget(
          targetProfileId: 'backup',
          modelOverride: 'backup-model',
        ),
      ],
    );
    final backup = ProviderProfile.defaults(name: 'Backup').copyWith(
      id: 'backup',
      apiFormat: ProviderProfile.openaiFormat,
      apiKey: 'backup-key',
      model: 'backup-default-model',
    );
    await prefs.setProfiles([primary, backup]);
    await prefs.setActiveProfileId('primary');

    final exported = await ConfigExportService.exportConfig(
      password: 'backup-password',
    );
    expect(exported, isNot(contains('primary-key')));
    expect(exported, isNot(contains('backup-key')));
    expect(exported, isNot(contains('backup-model')));

    resetDevice();
    final result = await ConfigExportService.importConfig(
      exported,
      password: 'backup-password',
      conflictResolution: ConflictResolution.replace,
    );

    final importedPrefs = await initPrefs();
    final importedPrimary =
        importedPrefs.profiles.firstWhere((profile) => profile.id == 'primary');
    expect(result.profilesImported, 2);
    expect(importedPrefs.activeProfileId, 'primary');
    expect(importedPrimary.fallbackTargets, hasLength(1));
    expect(importedPrimary.fallbackTargets.single.targetProfileId, 'backup');
    expect(
        importedPrimary.fallbackTargets.single.modelOverride, 'backup-model');
  });

  test('encrypted export and import preserves model groups after profiles',
      () async {
    final prefs = await initPrefs();
    final active = ProviderProfile.defaults(name: 'Active').copyWith(
      id: 'active',
      apiKey: 'active-key',
      model: 'active-model',
    );
    final primary = ProviderProfile.defaults(name: 'Primary').copyWith(
      id: 'primary',
      apiKey: 'primary-key',
      model: 'primary-model',
    );
    final backup = ProviderProfile.defaults(name: 'Backup').copyWith(
      id: 'backup',
      apiKey: 'backup-key',
      model: 'backup-model',
    );
    await prefs.setProfiles([active, primary, backup]);
    await prefs.setActiveProfileId('active');
    await prefs.setModelGroups([
      ModelGroup(
        id: 'group',
        name: 'Coding Group',
        primaryProfileId: 'primary',
        fallbackTargets: const [
          ModelFallbackTarget(
            targetProfileId: 'backup',
            modelOverride: 'backup-override',
          ),
        ],
      ),
    ]);
    await prefs.setActiveModelGroupId('group');

    final exported = await ConfigExportService.exportConfig(
      password: 'backup-password',
    );
    expect(exported, isNot(contains('active-key')));
    expect(exported, isNot(contains('primary-key')));
    expect(exported, isNot(contains('backup-key')));

    resetDevice();
    await ConfigExportService.importConfig(
      exported,
      password: 'backup-password',
      conflictResolution: ConflictResolution.replace,
    );

    final importedPrefs = await initPrefs();
    expect(importedPrefs.activeProfileId, 'active');
    expect(importedPrefs.modelGroups, hasLength(1));
    final importedGroup = importedPrefs.modelGroups.single;
    expect(importedGroup.id, 'group');
    expect(importedGroup.primaryProfileId, 'primary');
    expect(importedGroup.fallbackTargets, hasLength(1));
    expect(importedGroup.fallbackTargets.single.targetProfileId, 'backup');
    expect(
      importedGroup.fallbackTargets.single.modelOverride,
      'backup-override',
    );
    expect(importedPrefs.activeModelGroupId, 'group');
  });

  test('failed encrypted import leaves existing config untouched', () async {
    final prefs = await initPrefs();
    prefs.systemPrompt = 'keep system prompt';
    prefs.themeMode = 'dark';
    prefs.deniedToolNames = {'bash'};
    prefs.bashCommandDenyPatterns = ['blocked-command'];
    prefs.envVars = {'KEEP_ENV': 'keep-value'};
    final promptProfile = await prefs.savePromptProfile(
      name: 'Keep Prompt',
      systemPrompt: 'keep prompt profile',
    );
    final mcpServer = await prefs.saveMcpServer(
      displayName: 'Keep MCP',
      enabled: true,
      command: 'node',
      env: {'KEEP_TOKEN': 'keep-token'},
    );

    final exported = await ConfigExportService.exportConfig(
      password: 'correct-password',
    );
    final importData = jsonDecode(exported) as Map<String, dynamic>;
    importData['settings'] = {
      'systemPrompt': 'mutated system prompt',
      'themeMode': 'light',
      'deniedToolNames': ['write_file'],
      'bashCommandDenyPatterns': ['mutated-command'],
    };

    await expectLater(
      ConfigExportService.importConfig(
        jsonEncode(importData),
        password: 'wrong-password',
        conflictResolution: ConflictResolution.replace,
      ),
      throwsA(anything),
    );

    final corruptData =
        jsonDecode(jsonEncode(importData)) as Map<String, dynamic>;
    final corruptSecrets =
        Map<String, dynamic>.from(corruptData['secrets'] as Map);
    corruptSecrets['data'] = 'not valid encrypted payload';
    corruptData['secrets'] = corruptSecrets;
    await expectLater(
      ConfigExportService.importConfig(
        jsonEncode(corruptData),
        password: 'correct-password',
        conflictResolution: ConflictResolution.replace,
      ),
      throwsA(anything),
    );

    expect(prefs.systemPrompt, 'keep system prompt');
    expect(prefs.themeMode, 'dark');
    expect(prefs.deniedToolNames, {'bash'});
    expect(prefs.bashCommandDenyPatterns, ['blocked-command']);
    expect(prefs.envVars, {'KEEP_ENV': 'keep-value'});
    expect(prefs.promptProfiles.single.id, promptProfile.id);
    expect(prefs.promptProfiles.single.systemPrompt, 'keep prompt profile');
    expect(prefs.mcpServers.single.id, mcpServer.id);
    expect(prefs.mcpServers.single.env, {'KEEP_TOKEN': 'keep-token'});
  });

  test('plaintext malformed fallback payload leaves config untouched',
      () async {
    final prefs = await initPrefs();
    prefs.systemPrompt = 'keep system prompt';
    prefs.themeMode = 'dark';
    prefs.deniedToolNames = {'bash'};
    prefs.bashCommandDenyPatterns = ['blocked-command'];
    prefs.envVars = {'KEEP_ENV': 'keep-value'};
    final existing = ProviderProfile.defaults(name: 'Existing').copyWith(
      id: 'existing',
      apiKey: 'existing-key',
      model: 'existing-model',
    );
    await prefs.setProfiles([existing]);
    final malformedExport = jsonEncode({
      'version': 1,
      'exportedAt': DateTime.utc(2026).toIso8601String(),
      'settings': {
        'systemPrompt': 'mutated system prompt',
        'themeMode': 'light',
        'deniedToolNames': ['write_file'],
        'bashCommandDenyPatterns': ['mutated-command'],
      },
      'secrets': {
        'encrypted': false,
        'providerProfiles': [
          {
            'id': 'incoming',
            'name': 'Incoming',
            'apiFormat': ProviderProfile.anthropicFormat,
            'apiKey': 'incoming-key',
            'baseUrl': '',
            'model': 'incoming-model',
            'maxTokens': 8192,
            'thinkingBudget': 0,
            'temperature': 0.7,
            'fallbackTargets': [
              {'modelOverride': 'missing target id'},
            ],
          },
        ],
        'envVars': {'MUTATED_ENV': 'mutated-value'},
      },
    });

    await expectLater(
      ConfigExportService.importConfig(
        malformedExport,
        conflictResolution: ConflictResolution.replace,
      ),
      throwsA(isA<FormatException>()),
    );

    expect(prefs.systemPrompt, 'keep system prompt');
    expect(prefs.themeMode, 'dark');
    expect(prefs.deniedToolNames, {'bash'});
    expect(prefs.bashCommandDenyPatterns, ['blocked-command']);
    expect(prefs.envVars, {'KEEP_ENV': 'keep-value'});
    expect(prefs.profiles, hasLength(1));
    expect(prefs.profiles.single.id, 'existing');
    expect(prefs.profiles.single.apiKey, 'existing-key');
    expect(prefs.profiles.single.model, 'existing-model');
  });

  test('plaintext malformed model groups leave config untouched', () async {
    final prefs = await initPrefs();
    prefs.systemPrompt = 'keep system prompt';
    prefs.themeMode = 'dark';
    prefs.envVars = {'KEEP_ENV': 'keep-value'};
    final primary = ProviderProfile.defaults(name: 'Primary').copyWith(
      id: 'primary',
      apiKey: 'primary-key',
      model: 'primary-model',
    );
    final backup = ProviderProfile.defaults(name: 'Backup').copyWith(
      id: 'backup',
      apiKey: 'backup-key',
      model: 'backup-model',
    );
    await prefs.setProfiles([primary, backup]);
    await prefs.setActiveProfileId('primary');
    await prefs.setModelGroups([
      ModelGroup(
        id: 'keep-group',
        name: 'Keep Group',
        primaryProfileId: 'primary',
        fallbackTargets: const [
          ModelFallbackTarget(targetProfileId: 'backup'),
        ],
      ),
    ]);
    await prefs.setActiveModelGroupId('keep-group');

    final malformedExport = jsonEncode({
      'version': 1,
      'exportedAt': DateTime.utc(2026).toIso8601String(),
      'settings': {
        'systemPrompt': 'mutated system prompt',
        'themeMode': 'light',
        'activeModelGroupId': 'mutated-group',
        'modelGroups': [
          {'id': 'mutated-group'},
        ],
      },
      'secrets': {
        'encrypted': false,
        'providerProfiles': [
          ProviderProfile.defaults(name: 'Incoming')
              .copyWith(
                id: 'incoming',
                apiKey: 'incoming-key',
                model: 'incoming-model',
              )
              .toJson(),
        ],
        'envVars': {'MUTATED_ENV': 'mutated-value'},
      },
    });

    await expectLater(
      ConfigExportService.importConfig(
        malformedExport,
        conflictResolution: ConflictResolution.replace,
      ),
      throwsA(isA<FormatException>()),
    );

    expect(prefs.systemPrompt, 'keep system prompt');
    expect(prefs.themeMode, 'dark');
    expect(prefs.envVars, {'KEEP_ENV': 'keep-value'});
    expect(prefs.profiles.map((profile) => profile.id), ['primary', 'backup']);
    expect(prefs.modelGroups, hasLength(1));
    expect(prefs.modelGroups.single.id, 'keep-group');
    expect(prefs.activeModelGroupId, 'keep-group');
  });

  test('encrypted malformed model groups leave config untouched', () async {
    var prefs = await initPrefs();
    final incoming = ProviderProfile.defaults(name: 'Incoming').copyWith(
      id: 'incoming',
      apiKey: 'incoming-key',
      model: 'incoming-model',
    );
    await prefs.setProfiles([incoming]);
    prefs.systemPrompt = 'incoming system prompt';
    prefs.envVars = {'INCOMING_ENV': 'incoming-value'};

    final encryptedExport = await ConfigExportService.exportConfig(
      password: 'backup-password',
    );

    resetDevice();
    prefs = await initPrefs();
    prefs.systemPrompt = 'keep system prompt';
    prefs.themeMode = 'dark';
    prefs.envVars = {'KEEP_ENV': 'keep-value'};
    final primary = ProviderProfile.defaults(name: 'Primary').copyWith(
      id: 'primary',
      apiKey: 'primary-key',
      model: 'primary-model',
    );
    final backup = ProviderProfile.defaults(name: 'Backup').copyWith(
      id: 'backup',
      apiKey: 'backup-key',
      model: 'backup-model',
    );
    await prefs.setProfiles([primary, backup]);
    await prefs.setActiveProfileId('primary');
    await prefs.setModelGroups([
      ModelGroup(
        id: 'keep-group',
        name: 'Keep Group',
        primaryProfileId: 'primary',
        fallbackTargets: const [
          ModelFallbackTarget(targetProfileId: 'backup'),
        ],
      ),
    ]);
    await prefs.setActiveModelGroupId('keep-group');

    final importData = jsonDecode(encryptedExport) as Map<String, dynamic>;
    importData['settings'] = {
      'systemPrompt': 'mutated system prompt',
      'themeMode': 'light',
      'activeModelGroupId': 'mutated-group',
      'modelGroups': ['not-a-model-group'],
    };

    await expectLater(
      ConfigExportService.importConfig(
        jsonEncode(importData),
        password: 'backup-password',
        conflictResolution: ConflictResolution.replace,
      ),
      throwsA(isA<FormatException>()),
    );

    expect(prefs.systemPrompt, 'keep system prompt');
    expect(prefs.themeMode, 'dark');
    expect(prefs.envVars, {'KEEP_ENV': 'keep-value'});
    expect(prefs.profiles.map((profile) => profile.id), ['primary', 'backup']);
    expect(prefs.modelGroups, hasLength(1));
    expect(prefs.modelGroups.single.id, 'keep-group');
    expect(prefs.activeModelGroupId, 'keep-group');
  });

  test('MCP import normalizes env keys', () async {
    final payload = jsonEncode({
      'version': 1,
      'exportedAt': DateTime.utc(2026).toIso8601String(),
      'settings': {},
      'secrets': {
        'encrypted': false,
        'providerProfiles': [],
        'envVars': {},
        'mcpServers': [
          {
            'id': 'server-1',
            'displayName': 'Imported MCP',
            'enabled': true,
            'command': 'node',
            'env': {
              'GOOD_TOKEN': 'kept',
              'bad-name': 'dropped',
              ' ALSO_GOOD ': 'trimmed',
              '': 'dropped',
            },
          },
        ],
      },
    });

    final result = await ConfigExportService.importConfig(
      payload,
      conflictResolution: ConflictResolution.replace,
    );

    final prefs = await initPrefs();
    expect(result.mcpServersImported, 1);
    expect(prefs.mcpServers.single.env, {
      'GOOD_TOKEN': 'kept',
      'ALSO_GOOD': 'trimmed',
    });
  });

  test('old export without prompt profiles leaves existing profiles intact',
      () async {
    final prefs = await initPrefs();
    final existing = await prefs.savePromptProfile(
      name: 'Keep',
      systemPrompt: 'keep this prompt',
    );
    final oldExport = jsonEncode({
      'version': 1,
      'exportedAt': DateTime.utc(2026).toIso8601String(),
      'settings': {
        'systemPrompt': 'imported system prompt',
      },
      'secrets': {
        'encrypted': false,
        'providerProfiles': [],
        'envVars': {},
      },
    });

    final preview = ConfigExportService.previewImport(oldExport);
    final result = await ConfigExportService.importConfig(
      oldExport,
      conflictResolution: ConflictResolution.replace,
    );

    final profiles = prefs.promptProfiles;
    expect(preview.promptProfileCount, 0);
    expect(result.promptProfilesImported, 0);
    expect(result.promptProfilesSkipped, 0);
    expect(profiles, hasLength(1));
    expect(profiles.single.id, existing.id);
    expect(profiles.single.systemPrompt, 'keep this prompt');
    expect(prefs.systemPrompt, 'imported system prompt');
  });

  test('malformed prompt profile data does not replace existing profiles',
      () async {
    final prefs = await initPrefs();
    final existing = await prefs.savePromptProfile(
      name: 'Keep',
      systemPrompt: 'keep this prompt',
    );
    final malformedExport = jsonEncode({
      'version': 1,
      'exportedAt': DateTime.utc(2026).toIso8601String(),
      'settings': {},
      'secrets': {
        'encrypted': false,
        'providerProfiles': [],
        'promptProfiles': [
          {
            'id': 'broken',
            'name': 'Missing prompt',
          },
        ],
        'envVars': {},
      },
    });

    final result = await ConfigExportService.importConfig(
      malformedExport,
      conflictResolution: ConflictResolution.replace,
    );

    final profiles = prefs.promptProfiles;
    expect(result.promptProfilesImported, 0);
    expect(result.promptProfilesSkipped, 0);
    expect(result.warnings, isNotEmpty);
    expect(profiles, hasLength(1));
    expect(profiles.single.id, existing.id);
    expect(profiles.single.systemPrompt, 'keep this prompt');
  });
}
