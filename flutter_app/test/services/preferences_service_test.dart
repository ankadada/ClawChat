import 'dart:convert';

import 'package:clawchat/constants.dart';
import 'package:clawchat/models/model_capabilities.dart';
import 'package:clawchat/models/provider_profile.dart';
import 'package:clawchat/services/preferences_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late Map<String, String> secureStorage;
  late bool failWrites;

  setUp(() {
    secureStorage = {};
    failWrites = false;
    PreferencesService.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
      final key = args['key']?.toString();
      switch (call.method) {
        case 'read':
          return key == null ? null : secureStorage[key];
        case 'write':
          if (failWrites) {
            throw PlatformException(
              code: 'write_failed',
              message: 'secure storage write failed',
            );
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

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
    PreferencesService.resetForTesting();
  });

  test('migrates legacy single API config into first provider profile',
      () async {
    SharedPreferences.setMockInitialValues({
      'api_key': 'sk-legacy',
      'api_format': ProviderProfile.openaiFormat,
      'base_url': 'https://api.example.com',
      'model': 'gpt-test',
      'max_tokens': 1234,
      'thinking_budget': 4096,
      'temperature': 0.2,
    });

    final service = PreferencesService();
    await service.init();

    expect(service.profiles, hasLength(1));
    final profile = service.profiles.single;
    expect(profile.apiKey, 'sk-legacy');
    expect(profile.apiFormat, ProviderProfile.openaiFormat);
    expect(profile.baseUrl, 'https://api.example.com');
    expect(profile.model, 'gpt-test');
    expect(profile.maxTokens, 1234);
    expect(profile.thinkingBudget, 4096);
    expect(profile.temperature, 0.2);
    expect(service.activeProfileId, profile.id);
    expect(service.apiKey, 'sk-legacy');
    expect(service.baseUrl, 'https://api.example.com');
    expect(service.model, 'gpt-test');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('api_key'), isNull);
    expect(prefs.getString('api_format'), isNull);
    expect(prefs.getString('base_url'), isNull);
    expect(prefs.getString('model'), isNull);
    expect(prefs.getInt('max_tokens'), isNull);
    expect(prefs.getInt('thinking_budget'), isNull);
    expect(prefs.getDouble('temperature'), isNull);
    expect(secureStorage.containsKey('api_key'), isFalse);
    expect(secureStorage.containsKey('provider_profiles'), isTrue);
  });

  test('creates a default provider profile during init when none exists',
      () async {
    SharedPreferences.setMockInitialValues({});

    final service = PreferencesService();
    await service.init();

    expect(service.profiles, hasLength(1));
    expect(service.activeProfileId, service.profiles.single.id);
    expect(secureStorage.containsKey('provider_profiles'), isTrue);
  });

  test('tool approval policy defaults to session first and normalizes values',
      () async {
    SharedPreferences.setMockInitialValues({});

    final service = PreferencesService();
    await service.init();

    expect(
      service.toolApprovalPolicy,
      PreferencesService.toolApprovalSessionFirst,
    );

    service.toolApprovalPolicy = PreferencesService.toolApprovalAlways;
    expect(service.toolApprovalPolicy, PreferencesService.toolApprovalAlways);

    service.toolApprovalPolicy = PreferencesService.toolApprovalAuto;
    expect(service.toolApprovalPolicy, PreferencesService.toolApprovalAuto);

    service.toolApprovalPolicy = 'unexpected';
    expect(
      service.toolApprovalPolicy,
      PreferencesService.toolApprovalSessionFirst,
    );
  });

  test('persists and imports tool safety settings', () async {
    SharedPreferences.setMockInitialValues({});

    final service = PreferencesService();
    await service.init();

    service.deniedToolNames = {' bash ', 'read_file', ''};
    service.bashCommandDenyPatterns = [' rm\\s+-rf ', ' secret-project ', ''];

    expect(service.deniedToolNames, {'bash', 'read_file'});
    expect(service.bashCommandDenyPatterns, [
      r'rm\s+-rf',
      'secret-project',
    ]);

    final exported = service.exportAllSettings();
    expect(exported['deniedToolNames'], ['bash', 'read_file']);
    expect(exported['bashCommandDenyPatterns'], [
      r'rm\s+-rf',
      'secret-project',
    ]);

    PreferencesService.resetForTesting();
    final secondService = PreferencesService();
    await secondService.init();
    expect(secondService.deniedToolNames, {'bash', 'read_file'});
    expect(secondService.bashCommandDenyPatterns, [
      r'rm\s+-rf',
      'secret-project',
    ]);

    secondService.importAllSettings({
      'deniedToolNames': ['write_file', ' bash ', ''],
      'bashCommandDenyPatterns': ['curl .*token', ''],
    });
    expect(secondService.deniedToolNames, {'bash', 'write_file'});
    expect(secondService.bashCommandDenyPatterns, ['curl .*token']);
  });

  test('stores MCP server configs in secure storage', () async {
    SharedPreferences.setMockInitialValues({});

    final service = PreferencesService();
    await service.init();

    final server = await service.saveMcpServer(
      displayName: 'Local Files',
      enabled: true,
      command: 'npx',
      args: ['-y', '@modelcontextprotocol/server-filesystem'],
      env: {'MCP_TOKEN': 'token-placeholder-value', 'bad-name': 'ignored'},
    );

    expect(service.mcpServers, hasLength(1));
    expect(service.mcpServers.single.id, server.id);
    expect(service.mcpServers.single.env, {
      'MCP_TOKEN': 'token-placeholder-value',
    });

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('mcp_servers'), isNull);
    expect(secureStorage['mcp_servers'], contains('token-placeholder-value'));

    PreferencesService.resetForTesting();
    final secondService = PreferencesService();
    await secondService.init();
    expect(secondService.mcpServers.single.displayName, 'Local Files');
    expect(secondService.mcpServers.single.command, 'npx');
    expect(secondService.mcpServers.single.env['MCP_TOKEN'],
        'token-placeholder-value');
  });

  test('saves updates and deletes prompt profiles', () async {
    SharedPreferences.setMockInitialValues({});

    final service = PreferencesService();
    await service.init();

    final created = await service.savePromptProfile(
      name: 'Coder',
      systemPrompt: 'You are a precise coding assistant.',
    );

    expect(service.promptProfiles, hasLength(1));
    expect(service.promptProfiles.single.id, created.id);
    expect(service.promptProfiles.single.name, 'Coder');
    expect(
      service.promptProfiles.single.systemPrompt,
      'You are a precise coding assistant.',
    );

    final updated = await service.savePromptProfile(
      id: created.id,
      name: 'Reviewer',
      systemPrompt: 'Review code for regressions.',
    );

    expect(updated.id, created.id);
    expect(service.promptProfiles, hasLength(1));
    expect(service.promptProfiles.single.name, 'Reviewer');
    expect(service.promptProfiles.single.systemPrompt,
        'Review code for regressions.');

    await service.deletePromptProfile(created.id);
    expect(service.promptProfiles, isEmpty);
  });

  test('foldable view preferences default and clamp persisted values',
      () async {
    SharedPreferences.setMockInitialValues({});

    final service = PreferencesService();
    await service.init();

    expect(
      service.dualPaneSidebarWidth,
      PreferencesService.defaultDualPaneSidebarWidth,
    );
    expect(service.terminalFontSize, isNull);

    service.dualPaneSidebarWidth = 480;
    expect(service.dualPaneSidebarWidth, 480);

    service.dualPaneSidebarWidth = 120;
    expect(service.dualPaneSidebarWidth, 200);

    service.terminalFontSize = 16;
    expect(service.terminalFontSize, 16);

    service.terminalFontSize = 24;
    expect(service.terminalFontSize, 18);

    service.terminalFontSize = null;
    expect(service.terminalFontSize, isNull);
  });

  test('migrates legacy context length into token budget on first read',
      () async {
    SharedPreferences.setMockInitialValues({
      'context_length': 100000,
    });

    final service = PreferencesService();
    await service.init();

    expect(service.contextTokenBudget, 32768);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('context_token_budget'), 32768);
  });

  test('normalizes stored context token budget to valid presets', () async {
    Future<void> expectNormalized(int stored, int expected) async {
      SharedPreferences.setMockInitialValues({
        'context_token_budget': stored,
      });
      PreferencesService.resetForTesting();

      final service = PreferencesService();
      await service.init();

      expect(service.contextTokenBudget, expected);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('context_token_budget'), expected);
    }

    await expectNormalized(4096, 32768);
    await expectNormalized(33333, 32768);
    await expectNormalized(100000, 65536);
  });

  test('context token budget migration is idempotent after normalization',
      () async {
    SharedPreferences.setMockInitialValues({
      'context_length': 100000,
    });

    final service = PreferencesService();
    await service.init();
    expect(service.contextTokenBudget, 32768);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('context_token_budget'), 32768);

    PreferencesService.resetForTesting();
    final secondService = PreferencesService();
    await secondService.init();
    expect(secondService.contextTokenBudget, 32768);
    expect(prefs.getInt('context_token_budget'), 32768);
  });

  test('import settings prefers explicit context token budget', () async {
    SharedPreferences.setMockInitialValues({});

    final service = PreferencesService();
    await service.init();

    service.importAllSettings({
      'contextLength': 200000,
      'contextTokenBudget': 32768,
    });

    expect(service.contextTokenBudget, 32768);
  });

  test('import settings normalizes context token budget values', () async {
    SharedPreferences.setMockInitialValues({});

    final service = PreferencesService();
    await service.init();

    service.importAllSettings({
      'contextTokenBudget': 100000,
    });

    expect(service.contextTokenBudget, 65536);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('context_token_budget'), 65536);
  });

  test('delegates API getters and setters to the active profile', () async {
    final first = ProviderProfile.defaults(name: 'First').copyWith(
      id: 'first',
      apiKey: 'sk-first',
      model: 'claude-first',
    );
    final second = ProviderProfile.defaults(name: 'Second').copyWith(
      id: 'second',
      apiFormat: ProviderProfile.openaiFormat,
      apiKey: 'sk-second',
      baseUrl: 'https://api.second.example',
      model: 'gpt-second',
      maxTokens: 4096,
      temperature: 0.4,
    );
    secureStorage['provider_profiles'] = jsonEncode([
      first.toJson(),
      second.toJson(),
    ]);
    SharedPreferences.setMockInitialValues({
      'active_provider_profile_id': 'first',
    });

    final service = PreferencesService();
    await service.init();

    expect(service.apiKey, 'sk-first');
    expect(service.model, 'claude-first');

    service.activeProfileId = 'second';
    expect(service.apiFormat, ProviderProfile.openaiFormat);
    expect(service.apiKey, 'sk-second');
    expect(service.baseUrl, 'https://api.second.example');
    expect(service.model, 'gpt-second');
    expect(service.maxTokens, 4096);
    expect(service.temperature, 0.4);

    service.apiKey = 'sk-updated';
    service.model = null;

    final updated = service.profiles.firstWhere((p) => p.id == 'second');
    expect(updated.apiKey, 'sk-updated');
    expect(updated.model, isEmpty);
    expect(service.model, isNull);
    expect(service.activeProfile.effectiveModel, AppConstants.defaultModel);
  });

  test('provider profiles preserve capability overrides in storage', () async {
    final profile = ProviderProfile.defaults(name: 'Override').copyWith(
      id: 'override',
      apiFormat: ProviderProfile.openaiFormat,
      model: 'codex/gpt-5.5',
      capabilityOverride: const CapabilityOverride(
        supportsImages: true,
        supportsTools: false,
        supportsReasoningContent: true,
        maxContextTokens: 123456,
      ),
    );
    secureStorage['provider_profiles'] = jsonEncode([profile.toJson()]);
    SharedPreferences.setMockInitialValues({
      'active_provider_profile_id': 'override',
    });

    final service = PreferencesService();
    await service.init();

    expect(service.activeProfile.model, 'codex/gpt-5.5');
    expect(
        service.activeProfile.capabilityOverride, profile.capabilityOverride);

    await service.setProfiles(service.profiles);
    final stored = jsonDecode(secureStorage['provider_profiles']!) as List;
    final storedProfile = ProviderProfile.fromJson(
      Map<String, dynamic>.from(stored.single as Map),
    );

    expect(storedProfile.model, 'codex/gpt-5.5');
    expect(storedProfile.capabilityOverride, profile.capabilityOverride);
  });

  test('provider profile fallback targets round trip JSON and copyWith',
      () async {
    final profile = ProviderProfile.defaults(name: 'Primary').copyWith(
      id: 'primary',
      fallbackTargets: const [
        ModelFallbackTarget(
          targetProfileId: 'backup',
          modelOverride: 'backup-model',
          enabled: false,
        ),
      ],
    );

    final copied = profile.copyWith(name: 'Renamed');
    final decoded = ProviderProfile.fromJson(profile.toJson());
    final legacy = ProviderProfile.fromJson({
      'id': 'legacy',
      'name': 'Legacy',
      'apiFormat': ProviderProfile.anthropicFormat,
      'apiKey': '',
      'baseUrl': '',
      'model': AppConstants.defaultModel,
      'maxTokens': AppConstants.defaultMaxTokens,
      'thinkingBudget': 0,
      'temperature': AppConstants.defaultTemperature,
    });

    expect(copied.fallbackTargets.single.targetProfileId, 'backup');
    expect(decoded.fallbackTargets, hasLength(1));
    expect(decoded.fallbackTargets.single.modelOverride, 'backup-model');
    expect(decoded.fallbackTargets.single.enabled, isFalse);
    expect(legacy.fallbackTargets, isEmpty);
    expect(
      () => ProviderProfile.fromJson({
        ...profile.toJson(),
        'fallbackTargets': [
          {'modelOverride': 'missing target id'},
        ],
      }),
      throwsFormatException,
    );
  });

  test('provider profiles preserve fallback targets in secure storage',
      () async {
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
    secureStorage['provider_profiles'] = jsonEncode([
      primary.toJson(),
      backup.toJson(),
    ]);
    SharedPreferences.setMockInitialValues({
      'active_provider_profile_id': 'primary',
    });

    final service = PreferencesService();
    await service.init();

    expect(service.activeProfile.fallbackTargets, hasLength(1));
    expect(
        service.activeProfile.fallbackTargets.single.targetProfileId, 'backup');
    expect(
        service.activeProfile.fallbackTargets.single.effectiveModelFor(backup),
        'backup-model');

    await service.setProfiles(service.profiles);
    final stored = jsonDecode(secureStorage['provider_profiles']!) as List;
    final storedPrimary = ProviderProfile.fromJson(
      Map<String, dynamic>.from(stored.first as Map),
    );
    expect(storedPrimary.fallbackTargets.single.targetProfileId, 'backup');
    expect(storedPrimary.fallbackTargets.single.modelOverride, 'backup-model');
  });

  test('setProfiles removes fallback targets that cannot be used', () async {
    SharedPreferences.setMockInitialValues({});

    final service = PreferencesService();
    await service.init();
    final primary = ProviderProfile.defaults(name: 'Primary').copyWith(
      id: 'primary',
      fallbackTargets: const [
        ModelFallbackTarget(targetProfileId: 'primary'),
        ModelFallbackTarget(targetProfileId: 'missing'),
        ModelFallbackTarget(targetProfileId: 'backup'),
      ],
    );
    final backup = ProviderProfile.defaults(name: 'Backup').copyWith(
      id: 'backup',
    );

    await service.setProfiles([primary, backup]);

    final sanitized = service.profiles.firstWhere((p) => p.id == 'primary');
    expect(sanitized.fallbackTargets, hasLength(1));
    expect(sanitized.fallbackTargets.single.targetProfileId, 'backup');
  });

  test('model groups persist and sanitize profile references', () async {
    SharedPreferences.setMockInitialValues({});

    final service = PreferencesService();
    await service.init();
    final primary = ProviderProfile.defaults(name: 'Primary').copyWith(
      id: 'primary',
    );
    final backup = ProviderProfile.defaults(name: 'Backup').copyWith(
      id: 'backup',
    );
    await service.setProfiles([primary, backup]);
    await service.setModelGroups([
      ModelGroup(
        id: 'group',
        name: '  Coding Group  ',
        primaryProfileId: 'primary',
        fallbackTargets: const [
          ModelFallbackTarget(targetProfileId: 'primary'),
          ModelFallbackTarget(targetProfileId: 'missing'),
          ModelFallbackTarget(targetProfileId: 'backup'),
          ModelFallbackTarget(targetProfileId: 'backup'),
        ],
      ),
      ModelGroup(
        id: 'missing-primary',
        name: 'Missing',
        primaryProfileId: 'missing',
      ),
    ]);
    await service.setActiveModelGroupId('group');

    final group = service.modelGroups.single;
    expect(group.id, 'group');
    expect(group.displayName, 'Coding Group');
    expect(group.primaryProfileId, 'primary');
    expect(group.fallbackTargets, hasLength(1));
    expect(group.fallbackTargets.single.targetProfileId, 'backup');
    expect(service.activeModelGroupId, 'group');

    PreferencesService.resetForTesting();
    final reloaded = PreferencesService();
    await reloaded.init();

    expect(reloaded.modelGroups, hasLength(1));
    expect(reloaded.modelGroups.single.id, 'group');
    expect(reloaded.activeModelGroupId, 'group');
  });

  test('setProfiles drops model groups with removed primary profiles',
      () async {
    SharedPreferences.setMockInitialValues({});

    final service = PreferencesService();
    await service.init();
    final primary = ProviderProfile.defaults(name: 'Primary').copyWith(
      id: 'primary',
    );
    final backup = ProviderProfile.defaults(name: 'Backup').copyWith(
      id: 'backup',
    );
    await service.setProfiles([primary, backup]);
    await service.setModelGroups([
      ModelGroup(
        id: 'group',
        name: 'Group',
        primaryProfileId: 'primary',
        fallbackTargets: const [
          ModelFallbackTarget(targetProfileId: 'backup'),
        ],
      ),
    ]);
    await service.setActiveModelGroupId('group');

    await service.setProfiles([backup]);

    expect(service.modelGroups, isEmpty);
    expect(service.activeModelGroupId, isNull);
  });

  test('setProfiles propagates write failures and reverts in-memory state',
      () async {
    final first = ProviderProfile.defaults(name: 'First').copyWith(
      id: 'first',
      apiKey: 'sk-first',
    );
    final second = ProviderProfile.defaults(name: 'Second').copyWith(
      id: 'second',
      apiKey: 'sk-second',
    );
    secureStorage['provider_profiles'] = jsonEncode([
      first.toJson(),
      second.toJson(),
    ]);
    SharedPreferences.setMockInitialValues({
      'active_provider_profile_id': 'first',
    });

    final service = PreferencesService();
    await service.init();

    failWrites = true;
    await expectLater(
      service.setProfiles([
        second.copyWith(name: 'Only second'),
      ]),
      throwsA(isA<PlatformException>()),
    );

    expect(service.profiles.map((p) => p.name), ['First', 'Second']);
    expect(service.activeProfileId, 'first');
    expect(service.apiKey, 'sk-first');
  });
}
