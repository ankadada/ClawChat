import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../constants.dart';
import '../models/mcp_server_config.dart';
import '../models/provider_profile.dart';

enum ConflictResolution { merge, replace, skip }

class PromptProfile {
  final String id;
  final String name;
  final String systemPrompt;
  final DateTime createdAt;
  final DateTime updatedAt;

  const PromptProfile({
    required this.id,
    required this.name,
    required this.systemPrompt,
    required this.createdAt,
    required this.updatedAt,
  });

  PromptProfile copyWith({
    String? id,
    String? name,
    String? systemPrompt,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return PromptProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'systemPrompt': systemPrompt,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory PromptProfile.fromJson(Map<String, dynamic> json) {
    final now = DateTime.now();
    final id = json['id']?.toString().trim();
    final name = json['name']?.toString().trim();
    final systemPrompt = json['systemPrompt']?.toString();
    if (id == null ||
        id.isEmpty ||
        name == null ||
        name.isEmpty ||
        systemPrompt == null ||
        systemPrompt.trim().isEmpty) {
      throw const FormatException('Invalid prompt profile');
    }
    return PromptProfile(
      id: id,
      name: name,
      systemPrompt: systemPrompt,
      createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '') ?? now,
      updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? '') ?? now,
    );
  }
}

class PreferencesService {
  static const _keyApiKey = 'api_key';
  static const _keyApiFormat = 'api_format';
  static const _keyBaseUrl = 'base_url';
  static const _keyModel = 'model';
  static const _keyMaxTokens = 'max_tokens';
  static const _keySystemPrompt = 'system_prompt';
  static const _keyThinkingBudget = 'thinking_budget';
  static const _keyContextLength = 'context_length';
  static const _keyContextTokenBudget = 'context_token_budget';
  static const _keyAutoCompact = 'auto_compact';
  static const _keyTemperature = 'temperature';
  static const _keyEnvVars = 'env_vars';
  static const _keyDarkMode = 'dark_mode';
  static const _keyFontSize = 'font_size';
  static const _keyNotifyOnComplete = 'notify_on_complete';
  static const _keyPrivacyMode = 'privacy_mode';
  static const _keyAgentMaxIterations = 'agent_max_iterations';
  static const _keyMaxConcurrentAgents = 'max_concurrent_agents';
  static const _keyAllowPhoneCall = 'allow_phone_call';
  static const _keyAllowSms = 'allow_sms';
  static const _keyToolApprovalPolicy = 'tool_approval_policy';
  static const _keyDeniedToolNames = 'denied_tool_names';
  static const _keyBashCommandDenyPatterns = 'bash_command_deny_patterns';
  static const _keyDualPaneSidebarWidth = 'dual_pane_sidebar_width';
  static const _keyTerminalFontSize = 'terminal_font_size';
  static const _keyWhisperModel = 'whisper_model';
  static const _keyTtsModel = 'tts_model';
  static const _keyProviderProfiles = 'provider_profiles';
  static const _keyActiveProfileId = 'active_provider_profile_id';
  static const _keyPromptProfiles = 'prompt_profiles';
  static const _keyMcpServers = 'mcp_servers';

  static const toolApprovalAlways = 'always';
  static const toolApprovalSessionFirst = 'session_first';
  static const toolApprovalAuto = 'auto';
  static const defaultToolApprovalPolicy = toolApprovalSessionFirst;
  static const defaultDualPaneSidebarWidth = 280.0;
  static const int defaultAgentMaxIterations = 25;
  static const int maxAgentMaxIterations = 99;
  static const int defaultMaxConcurrentAgents = 3;
  static const int maxMaxConcurrentAgents = 5;
  static const _validContextTokenBudgets = [32768, 65536, 200000];

  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static PreferencesService? _instance;
  Map<String, String> _cachedEnvVars = {};
  List<ProviderProfile> _cachedProfiles = [];
  List<McpServerConfig> _cachedMcpServers = [];
  String? _cachedActiveProfileId;

  late SharedPreferences _prefs;
  bool _initialized = false;

  factory PreferencesService() {
    return _instance ??= PreferencesService._();
  }

  PreferencesService._();

  @visibleForTesting
  static void resetForTesting() {
    _instance = null;
  }

  Future<void> init() async {
    if (_initialized) return;
    _prefs = await SharedPreferences.getInstance();
    await _migrateApiKeyToSecureStorage();
    await _migrateEnvVarsToSecureStorage();
    await _loadProviderProfiles();
    _cachedEnvVars =
        _decodeEnvVars(await _secureStorage.read(key: _keyEnvVars));
    await _loadMcpServers();
    _initialized = true;
  }

  /// Migrates API key from plaintext SharedPreferences to secure storage.
  /// Also handles legacy base64-encoded keys from older versions.
  Future<void> _migrateApiKeyToSecureStorage() async {
    final oldKey = _prefs.getString(_keyApiKey);
    if (oldKey == null) return;

    // Handle legacy base64 encoding
    String plainKey = oldKey;
    try {
      final decoded = utf8.decode(base64Decode(oldKey));
      if (decoded.isNotEmpty && decoded != oldKey) {
        plainKey = decoded;
      }
    } catch (_) {
      // Already plaintext or corrupted — use as-is.
    }

    // Move to secure storage and remove from SharedPreferences
    await _secureStorage.write(key: _keyApiKey, value: plainKey);
    await _prefs.remove(_keyApiKey);
  }

  Future<void> _migrateEnvVarsToSecureStorage() async {
    final oldVars = _prefs.getString(_keyEnvVars);
    if (oldVars == null) return;

    try {
      final existing = await _secureStorage.read(key: _keyEnvVars);
      if (existing == null) {
        final decoded = _decodeEnvVars(oldVars);
        if (decoded.isNotEmpty) {
          await _secureStorage.write(
            key: _keyEnvVars,
            value: jsonEncode(decoded),
          );
        } else {
          await _secureStorage.delete(key: _keyEnvVars);
        }
      }
      await _prefs.remove(_keyEnvVars);
    } catch (e) {
      debugPrint('Failed to migrate environment variables: $e');
    }
  }

  Future<void> _loadProviderProfiles() async {
    final storedProfiles = await _secureStorage.read(key: _keyProviderProfiles);
    if (storedProfiles != null && storedProfiles.isNotEmpty) {
      try {
        final decoded = jsonDecode(storedProfiles);
        if (decoded is List) {
          _cachedProfiles = decoded
              .whereType<Map>()
              .map((item) => ProviderProfile.fromJson(
                    Map<String, dynamic>.from(item),
                  ))
              .toList();
        }
      } catch (e) {
        debugPrint('Failed to read provider profiles: $e');
      }
    }

    if (_cachedProfiles.isEmpty) {
      await _migrateLegacyProviderProfile();
    } else {
      _cachedActiveProfileId = _prefs.getString(_keyActiveProfileId);
      await _ensureValidActiveProfile();
      await _deleteLegacyApiConfig();
    }

    await _ensureAtLeastOneProfile();
    await _sanitizeCachedProviderFallbacks();
  }

  Future<void> _migrateLegacyProviderProfile() async {
    final legacyApiKey = await _secureStorage.read(key: _keyApiKey);
    final legacyApiFormat = _prefs.getString(_keyApiFormat);
    final legacyBaseUrl = _prefs.getString(_keyBaseUrl);
    final legacyModel = _prefs.getString(_keyModel);
    final legacyMaxTokens = _prefs.getInt(_keyMaxTokens);
    final legacyThinkingBudget = _prefs.getInt(_keyThinkingBudget);
    final legacyTemperature = _prefs.getDouble(_keyTemperature);

    final hasLegacyConfig = [
          legacyApiKey,
          legacyApiFormat,
          legacyBaseUrl,
          legacyModel,
        ].any((value) => value != null && value.isNotEmpty) ||
        legacyMaxTokens != null ||
        legacyThinkingBudget != null ||
        legacyTemperature != null;

    if (!hasLegacyConfig) return;

    final profile = ProviderProfile.defaults().copyWith(
      apiKey: legacyApiKey ?? '',
      apiFormat: legacyApiFormat,
      baseUrl: legacyBaseUrl ?? '',
      model: legacyModel,
      maxTokens: legacyMaxTokens,
      thinkingBudget: legacyThinkingBudget,
      temperature: legacyTemperature,
    );
    _cachedProfiles = [profile];
    _cachedActiveProfileId = profile.id;
    await _prefs.setString(_keyActiveProfileId, profile.id);
    await _persistProfilesNow();
    await _deleteLegacyApiConfig();
  }

  Future<void> _deleteLegacyApiConfig() async {
    await _secureStorage.delete(key: _keyApiKey);
    await _prefs.remove(_keyApiKey);
    await _prefs.remove(_keyApiFormat);
    await _prefs.remove(_keyBaseUrl);
    await _prefs.remove(_keyModel);
    await _prefs.remove(_keyMaxTokens);
    await _prefs.remove(_keyThinkingBudget);
    await _prefs.remove(_keyTemperature);
  }

  Future<void> _ensureValidActiveProfile() async {
    if (_cachedProfiles.isEmpty) return;
    final hasActive =
        _cachedProfiles.any((p) => p.id == _cachedActiveProfileId);
    if (hasActive) return;
    _cachedActiveProfileId = _cachedProfiles.first.id;
    await _prefs.setString(_keyActiveProfileId, _cachedActiveProfileId!);
  }

  Future<void> _ensureAtLeastOneProfile() async {
    if (_cachedProfiles.isEmpty) {
      _cachedProfiles = [ProviderProfile.defaults()];
      _cachedActiveProfileId = _cachedProfiles.first.id;
      await _prefs.setString(_keyActiveProfileId, _cachedActiveProfileId!);
      await _persistProfiles();
      return;
    }
    await _ensureValidActiveProfile();
  }

  Future<void> _sanitizeCachedProviderFallbacks() async {
    final before = jsonEncode(_cachedProfiles.map((p) => p.toJson()).toList());
    _cachedProfiles = _sanitizeProviderFallbacks(_cachedProfiles);
    final after = jsonEncode(_cachedProfiles.map((p) => p.toJson()).toList());
    if (before != after) {
      await _persistProfiles();
    }
  }

  int _activeProfileIndex() {
    if (_cachedProfiles.isEmpty) return -1;
    final index =
        _cachedProfiles.indexWhere((p) => p.id == _cachedActiveProfileId);
    if (index >= 0) return index;
    return 0;
  }

  ProviderProfile get _activeProfile {
    final index = _activeProfileIndex();
    if (index < 0) {
      throw StateError('PreferencesService has no provider profiles');
    }
    return _cachedProfiles[index];
  }

  void _replaceActiveProfile(ProviderProfile profile) {
    final previousProfiles = _copyProfiles(_cachedProfiles);
    final previousActiveProfileId = _cachedActiveProfileId;
    final index = _activeProfileIndex();
    if (index < 0) {
      throw StateError('PreferencesService has no provider profiles');
    }
    _cachedProfiles[index] = profile;
    _cachedProfiles = _sanitizeProviderFallbacks(_cachedProfiles);
    _persistProfilesAfterSyncMutation(
      previousProfiles,
      previousActiveProfileId,
    );
  }

  Future<void> _persistProfilesNow() {
    return _secureStorage.write(
      key: _keyProviderProfiles,
      value: jsonEncode(_cachedProfiles.map((p) => p.toJson()).toList()),
    );
  }

  Future<void> _persistProfiles() async {
    try {
      await _persistProfilesNow();
    } catch (e) {
      debugPrint('Failed to persist provider profiles: $e');
      rethrow;
    }
  }

  void _persistProfilesAfterSyncMutation(
    List<ProviderProfile> previousProfiles,
    String? previousActiveProfileId,
  ) {
    unawaited(_persistProfiles().catchError((Object e) {
      _cachedProfiles = previousProfiles;
      _cachedActiveProfileId = previousActiveProfileId;
      debugPrint('Reverted provider profiles after persist failure: $e');
    }));
  }

  List<ProviderProfile> _copyProfiles(List<ProviderProfile> profiles) {
    return profiles.map((p) => p.copyWith()).toList();
  }

  List<ProviderProfile> _sanitizeProviderFallbacks(
    List<ProviderProfile> profiles,
  ) {
    if (profiles.isEmpty) return [ProviderProfile.defaults()];
    final copied = profiles.map((p) => p.copyWith()).toList();
    final ids = copied.map((profile) => profile.id).toSet();
    return copied.map((profile) {
      final seen = <String>{};
      final targets = <ModelFallbackTarget>[];
      for (final target in profile.fallbackTargets) {
        final targetId = target.targetProfileId.trim();
        if (targetId.isEmpty ||
            targetId == profile.id ||
            !ids.contains(targetId)) {
          continue;
        }
        final modelOverride = target.modelOverride.trim();
        final key = '$targetId\n$modelOverride';
        if (!seen.add(key)) continue;
        targets.add(target.copyWith(
          targetProfileId: targetId,
          modelOverride: modelOverride,
        ));
      }
      return profile.copyWith(fallbackTargets: targets);
    }).toList(growable: false);
  }

  List<ProviderProfile> get profiles {
    return _cachedProfiles.map((p) => p.copyWith()).toList();
  }

  set profiles(List<ProviderProfile> value) {
    unawaited(setProfiles(value).catchError((Object e) {
      debugPrint('Failed to set provider profiles: $e');
    }));
  }

  Future<void> setProfiles(List<ProviderProfile> value) async {
    final previousProfiles = _copyProfiles(_cachedProfiles);
    final previousActiveProfileId = _cachedActiveProfileId;

    _cachedProfiles = _sanitizeProviderFallbacks(value);
    if (!_cachedProfiles.any((p) => p.id == _cachedActiveProfileId)) {
      _cachedActiveProfileId = _cachedProfiles.first.id;
    }

    try {
      await _persistProfiles();
      await _prefs.setString(_keyActiveProfileId, _cachedActiveProfileId!);
    } catch (e) {
      _cachedProfiles = previousProfiles;
      _cachedActiveProfileId = previousActiveProfileId;
      debugPrint('Reverted provider profiles after setProfiles failure: $e');
      rethrow;
    }
  }

  String? get activeProfileId {
    return _cachedActiveProfileId;
  }

  set activeProfileId(String? value) {
    unawaited(setActiveProfileId(value).catchError((Object e) {
      debugPrint('Failed to set active provider profile: $e');
    }));
  }

  Future<void> setActiveProfileId(String? value) async {
    final previousProfiles = _copyProfiles(_cachedProfiles);
    final previousActiveProfileId = _cachedActiveProfileId;

    if (value != null && _cachedProfiles.any((p) => p.id == value)) {
      _cachedActiveProfileId = value;
    } else if (_cachedProfiles.isNotEmpty) {
      _cachedActiveProfileId = _cachedProfiles.first.id;
    } else {
      _cachedProfiles = [ProviderProfile.defaults()];
      _cachedActiveProfileId = _cachedProfiles.first.id;
    }

    try {
      if (_cachedProfiles.length != previousProfiles.length ||
          previousProfiles.isEmpty) {
        await _persistProfiles();
      }
      if (_cachedActiveProfileId != null) {
        await _prefs.setString(_keyActiveProfileId, _cachedActiveProfileId!);
      } else {
        await _prefs.remove(_keyActiveProfileId);
      }
    } catch (e) {
      _cachedProfiles = previousProfiles;
      _cachedActiveProfileId = previousActiveProfileId;
      debugPrint('Reverted active provider profile after persist failure: $e');
      rethrow;
    }
  }

  ProviderProfile get activeProfile => _activeProfile.copyWith();

  Future<void> updateActiveProfile(ProviderProfile profile) async {
    final previousProfiles = _copyProfiles(_cachedProfiles);
    final previousActiveProfileId = _cachedActiveProfileId;
    final index = _activeProfileIndex();
    if (index < 0) {
      throw StateError('PreferencesService has no provider profiles');
    }
    _cachedProfiles[index] = profile.copyWith(id: _cachedProfiles[index].id);
    _cachedProfiles = _sanitizeProviderFallbacks(_cachedProfiles);

    try {
      await _persistProfiles();
    } catch (e) {
      _cachedProfiles = previousProfiles;
      _cachedActiveProfileId = previousActiveProfileId;
      debugPrint('Reverted active provider profile after update failure: $e');
      rethrow;
    }
  }

  String? get apiKey {
    final value = _activeProfile.apiKey.trim();
    return value.isEmpty ? null : value;
  }

  set apiKey(String? v) {
    _replaceActiveProfile(_activeProfile.copyWith(apiKey: v ?? ''));
  }

  String? get apiFormat => _activeProfile.apiFormat;
  set apiFormat(String? v) => _replaceActiveProfile(
      _activeProfile.copyWith(apiFormat: v ?? 'anthropic'));

  String? get baseUrl {
    final value = _activeProfile.baseUrl.trim();
    return value.isEmpty ? null : value;
  }

  set baseUrl(String? v) => _replaceActiveProfile(
        _activeProfile.copyWith(baseUrl: v ?? ''),
      );

  String? get model {
    final value = _activeProfile.model.trim();
    return value.isEmpty ? null : value;
  }

  set model(String? v) => _replaceActiveProfile(
        _activeProfile.copyWith(model: v ?? ''),
      );

  int? get maxTokens => _activeProfile.maxTokens;
  set maxTokens(int? v) => _replaceActiveProfile(
        _activeProfile.copyWith(maxTokens: v),
      );

  String? get systemPrompt => _prefs.getString(_keySystemPrompt);
  set systemPrompt(String? v) => v != null
      ? _prefs.setString(_keySystemPrompt, v)
      : _prefs.remove(_keySystemPrompt);

  List<PromptProfile> get promptProfiles {
    final raw = _prefs.getString(_keyPromptProfiles);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final profiles = decoded
          .whereType<Map>()
          .map((item) => PromptProfile.fromJson(
                Map<String, dynamic>.from(item),
              ))
          .toList();
      profiles.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return profiles;
    } catch (_) {
      return const [];
    }
  }

  Future<PromptProfile> savePromptProfile({
    String? id,
    required String name,
    required String systemPrompt,
  }) async {
    final trimmedName = name.trim();
    final trimmedPrompt = systemPrompt.trim();
    if (trimmedName.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Prompt profile name is empty');
    }
    if (trimmedPrompt.isEmpty) {
      throw ArgumentError.value(
        systemPrompt,
        'systemPrompt',
        'Prompt profile prompt is empty',
      );
    }

    final existing = promptProfiles;
    final now = DateTime.now();
    final existingIndex =
        id == null ? -1 : existing.indexWhere((profile) => profile.id == id);
    final profile = existingIndex >= 0
        ? existing[existingIndex].copyWith(
            name: trimmedName,
            systemPrompt: trimmedPrompt,
            updatedAt: now,
          )
        : PromptProfile(
            id: id?.trim().isNotEmpty == true ? id!.trim() : const Uuid().v4(),
            name: trimmedName,
            systemPrompt: trimmedPrompt,
            createdAt: now,
            updatedAt: now,
          );
    final next = List<PromptProfile>.from(existing);
    if (existingIndex >= 0) {
      next[existingIndex] = profile;
    } else {
      next.insert(0, profile);
    }
    await _savePromptProfiles(next);
    return profile;
  }

  Future<void> deletePromptProfile(String id) async {
    final next = promptProfiles.where((profile) => profile.id != id).toList();
    await _savePromptProfiles(next);
  }

  Future<({int imported, int skipped})> importPromptProfiles(
    List<PromptProfile> importedProfiles,
    ConflictResolution resolution,
  ) async {
    final existing = promptProfiles;
    final existingIds = existing.map((profile) => profile.id).toSet();
    final seenImportedIds = <String>{};
    var imported = 0;
    var skipped = 0;

    switch (resolution) {
      case ConflictResolution.replace:
        final next = <PromptProfile>[];
        for (final profile in importedProfiles) {
          if (!seenImportedIds.add(profile.id)) {
            skipped++;
            continue;
          }
          next.add(profile);
          imported++;
        }
        await _savePromptProfiles(next);
      case ConflictResolution.merge:
      case ConflictResolution.skip:
        final merged = List<PromptProfile>.from(existing);
        for (final profile in importedProfiles) {
          if (!seenImportedIds.add(profile.id) ||
              existingIds.contains(profile.id)) {
            skipped++;
            continue;
          }
          merged.add(profile);
          imported++;
        }
        await _savePromptProfiles(merged);
    }

    return (imported: imported, skipped: skipped);
  }

  Future<void> _savePromptProfiles(List<PromptProfile> profiles) {
    return _prefs.setString(
      _keyPromptProfiles,
      jsonEncode(profiles.map((profile) => profile.toJson()).toList()),
    );
  }

  List<McpServerConfig> get mcpServers => List.unmodifiable(_cachedMcpServers);

  Future<McpServerConfig> saveMcpServer({
    String? id,
    required String displayName,
    required bool enabled,
    required String command,
    List<String> args = const [],
    Map<String, String> env = const {},
  }) async {
    final trimmedName = displayName.trim();
    final trimmedCommand = command.trim();
    if (trimmedName.isEmpty) {
      throw ArgumentError.value(
        displayName,
        'displayName',
        'MCP server name is empty',
      );
    }
    if (trimmedCommand.isEmpty) {
      throw ArgumentError.value(
        command,
        'command',
        'MCP server command is empty',
      );
    }

    final existing = mcpServers;
    final nextId =
        id?.trim().isNotEmpty == true ? id!.trim() : const Uuid().v4();
    final index = existing.indexWhere((server) => server.id == nextId);
    final config = McpServerConfig(
      id: nextId,
      displayName: trimmedName,
      enabled: enabled,
      command: trimmedCommand,
      args: args
          .map((arg) => arg.trim())
          .where((arg) => arg.isNotEmpty)
          .toList(growable: false),
      env: _normalizeMcpEnv(env),
    );
    final next = List<McpServerConfig>.from(existing);
    if (index >= 0) {
      next[index] = config;
    } else {
      next.add(config);
    }
    await setMcpServers(next);
    return config;
  }

  Future<void> deleteMcpServer(String id) async {
    await setMcpServers(
      _cachedMcpServers.where((server) => server.id != id).toList(),
    );
  }

  Future<void> setMcpServers(List<McpServerConfig> servers) async {
    _cachedMcpServers = List.unmodifiable(servers);
    await _persistMcpServers();
  }

  Future<({int imported, int skipped})> importMcpServers(
    List<McpServerConfig> importedServers,
    ConflictResolution resolution,
  ) async {
    final existing = mcpServers;
    final existingIds = existing.map((server) => server.id).toSet();
    final seenImportedIds = <String>{};
    var imported = 0;
    var skipped = 0;

    switch (resolution) {
      case ConflictResolution.replace:
        final next = <McpServerConfig>[];
        for (final server in importedServers) {
          if (!seenImportedIds.add(server.id)) {
            skipped++;
            continue;
          }
          next.add(server);
          imported++;
        }
        await setMcpServers(next);
      case ConflictResolution.merge:
      case ConflictResolution.skip:
        final merged = List<McpServerConfig>.from(existing);
        for (final server in importedServers) {
          if (!seenImportedIds.add(server.id) ||
              existingIds.contains(server.id)) {
            skipped++;
            continue;
          }
          merged.add(server);
          imported++;
        }
        await setMcpServers(merged);
    }
    return (imported: imported, skipped: skipped);
  }

  Future<void> _loadMcpServers() async {
    final raw = await _secureStorage.read(key: _keyMcpServers);
    if (raw == null || raw.isEmpty) {
      _cachedMcpServers = [];
      return;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        _cachedMcpServers = [];
        return;
      }
      _cachedMcpServers = decoded
          .whereType<Map>()
          .map((item) => McpServerConfig.fromJson(
                Map<String, dynamic>.from(item),
              ))
          .toList(growable: false);
    } catch (_) {
      debugPrint('Failed to read MCP server configs');
      _cachedMcpServers = [];
    }
  }

  Future<void> _persistMcpServers() async {
    if (_cachedMcpServers.isEmpty) {
      await _secureStorage.delete(key: _keyMcpServers);
      return;
    }
    await _secureStorage.write(
      key: _keyMcpServers,
      value: jsonEncode(
        _cachedMcpServers.map((server) => server.toJson()).toList(),
      ),
    );
  }

  Map<String, String> _normalizeMcpEnv(Map<String, String> env) {
    return McpServerConfig.normalizeEnv(env);
  }

  int get thinkingBudget => _activeProfile.thinkingBudget;
  set thinkingBudget(int v) => _replaceActiveProfile(
        _activeProfile.copyWith(thinkingBudget: v),
      );

  int get contextLength => _prefs.getInt(_keyContextLength) ?? 100000;
  set contextLength(int v) => _prefs.setInt(_keyContextLength, v);

  int get contextTokenBudget {
    final stored = _prefs.getInt(_keyContextTokenBudget);
    if (stored != null) {
      final normalized = _normalizeContextTokenBudget(stored);
      if (normalized != stored) {
        _prefs.setInt(_keyContextTokenBudget, normalized);
      }
      return normalized;
    }
    final legacy = _prefs.getInt(_keyContextLength);
    if (legacy == null) return AppConstants.defaultContextTokenBudget;
    final migrated = _normalizeContextTokenBudget(legacy ~/ 3);
    _prefs.setInt(_keyContextTokenBudget, migrated);
    return migrated;
  }

  set contextTokenBudget(int v) =>
      _prefs.setInt(_keyContextTokenBudget, _normalizeContextTokenBudget(v));

  static int _normalizeContextTokenBudget(int value) {
    var nearest = _validContextTokenBudgets.first;
    var nearestDistance = (value - nearest).abs();
    for (final budget in _validContextTokenBudgets.skip(1)) {
      final distance = (value - budget).abs();
      if (distance < nearestDistance) {
        nearest = budget;
        nearestDistance = distance;
      }
    }
    return nearest;
  }

  bool get autoCompact => _prefs.getBool(_keyAutoCompact) ?? true;
  set autoCompact(bool v) => _prefs.setBool(_keyAutoCompact, v);

  double get temperature => _activeProfile.temperature;
  set temperature(double v) => _replaceActiveProfile(
        _activeProfile.copyWith(temperature: v),
      );

  Map<String, String> get envVars {
    return Map<String, String>.from(_cachedEnvVars);
  }

  set envVars(Map<String, String> vars) {
    _cachedEnvVars = Map<String, String>.from(vars);
    if (_initialized) {
      _prefs.remove(_keyEnvVars).catchError((e) {
        debugPrint('Failed to remove plaintext environment variables: $e');
        return false;
      });
    }
    if (_cachedEnvVars.isEmpty) {
      _secureStorage.delete(key: _keyEnvVars).catchError((e) {
        debugPrint('Failed to delete environment variables: $e');
      });
    } else {
      _secureStorage
          .write(
        key: _keyEnvVars,
        value: jsonEncode(_cachedEnvVars),
      )
          .catchError((e) {
        debugPrint('Failed to persist environment variables: $e');
      });
    }
  }

  Map<String, String> _decodeEnvVars(String? json) {
    if (json == null || json.isEmpty) return {};
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map) return {};
      return decoded.map<String, String>(
        (key, value) => MapEntry(key.toString(), value?.toString() ?? ''),
      );
    } catch (_) {
      return {};
    }
  }

  // 'system' | 'light' | 'dark'
  String get themeMode => _prefs.getString(_keyDarkMode) ?? 'system';
  set themeMode(String v) => _prefs.setString(_keyDarkMode, v);

  // 0.8 = small, 1.0 = default, 1.2 = large, 1.4 = extra large
  double get fontScale => _prefs.getDouble(_keyFontSize) ?? 1.0;
  set fontScale(double v) => _prefs.setDouble(_keyFontSize, v);

  bool get notifyOnComplete => _prefs.getBool(_keyNotifyOnComplete) ?? true;
  set notifyOnComplete(bool v) => _prefs.setBool(_keyNotifyOnComplete, v);

  bool get privacyMode => _prefs.getBool(_keyPrivacyMode) ?? true;
  set privacyMode(bool v) => _prefs.setBool(_keyPrivacyMode, v);

  int get agentMaxIterations =>
      (_prefs.getInt(_keyAgentMaxIterations) ?? defaultAgentMaxIterations)
          .clamp(1, maxAgentMaxIterations)
          .toInt();
  set agentMaxIterations(int v) => _prefs.setInt(
        _keyAgentMaxIterations,
        v.clamp(1, maxAgentMaxIterations).toInt(),
      );

  int get maxConcurrentAgents =>
      (_prefs.getInt(_keyMaxConcurrentAgents) ?? defaultMaxConcurrentAgents)
          .clamp(1, maxMaxConcurrentAgents)
          .toInt();
  set maxConcurrentAgents(int v) => _prefs.setInt(
        _keyMaxConcurrentAgents,
        v.clamp(1, maxMaxConcurrentAgents).toInt(),
      );

  bool get allowPhoneCall =>
      _initialized ? (_prefs.getBool(_keyAllowPhoneCall) ?? false) : false;
  set allowPhoneCall(bool v) => _prefs.setBool(_keyAllowPhoneCall, v);

  bool get allowSms =>
      _initialized ? (_prefs.getBool(_keyAllowSms) ?? false) : false;
  set allowSms(bool v) => _prefs.setBool(_keyAllowSms, v);

  String get toolApprovalPolicy {
    return normalizeToolApprovalPolicy(
        _prefs.getString(_keyToolApprovalPolicy));
  }

  set toolApprovalPolicy(String v) {
    _prefs.setString(_keyToolApprovalPolicy, normalizeToolApprovalPolicy(v));
  }

  Set<String> get deniedToolNames {
    final values = _prefs.getStringList(_keyDeniedToolNames) ?? const [];
    return values
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet();
  }

  set deniedToolNames(Set<String> values) {
    final normalized = values
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    _prefs.setStringList(_keyDeniedToolNames, normalized);
  }

  List<String> get bashCommandDenyPatterns {
    final values =
        _prefs.getStringList(_keyBashCommandDenyPatterns) ?? const [];
    return values
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
  }

  set bashCommandDenyPatterns(List<String> values) {
    _prefs.setStringList(
      _keyBashCommandDenyPatterns,
      values
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toList(growable: false),
    );
  }

  static String normalizeToolApprovalPolicy(String? value) {
    return switch (value) {
      toolApprovalAlways => toolApprovalAlways,
      toolApprovalAuto => toolApprovalAuto,
      toolApprovalSessionFirst => toolApprovalSessionFirst,
      _ => defaultToolApprovalPolicy,
    };
  }

  double get dualPaneSidebarWidth {
    final value = _prefs.getDouble(_keyDualPaneSidebarWidth);
    if (value == null || !value.isFinite) return defaultDualPaneSidebarWidth;
    return value.clamp(200.0, 2000.0).toDouble();
  }

  set dualPaneSidebarWidth(double value) {
    if (!value.isFinite) return;
    _prefs.setDouble(
      _keyDualPaneSidebarWidth,
      value.clamp(200.0, 2000.0).toDouble(),
    );
  }

  double? get terminalFontSize {
    final value = _prefs.getDouble(_keyTerminalFontSize);
    if (value == null || !value.isFinite) return null;
    return value.clamp(12.0, 18.0).toDouble();
  }

  set terminalFontSize(double? value) {
    if (value == null || !value.isFinite) {
      _prefs.remove(_keyTerminalFontSize);
      return;
    }
    _prefs.setDouble(
      _keyTerminalFontSize,
      value.clamp(12.0, 18.0).toDouble(),
    );
  }

  String? get whisperModel =>
      _initialized ? _prefs.getString(_keyWhisperModel) : null;
  set whisperModel(String? v) {
    if (v != null && v.isNotEmpty) {
      _prefs.setString(_keyWhisperModel, v);
    } else {
      _prefs.remove(_keyWhisperModel);
    }
  }

  String? get ttsModel => _initialized ? _prefs.getString(_keyTtsModel) : null;
  set ttsModel(String? v) {
    if (v != null && v.isNotEmpty) {
      _prefs.setString(_keyTtsModel, v);
    } else {
      _prefs.remove(_keyTtsModel);
    }
  }

  Map<String, dynamic> exportAllSettings() {
    return {
      'activeProfileId': activeProfileId,
      'systemPrompt': _prefs.getString(_keySystemPrompt),
      'themeMode': themeMode,
      'fontScale': fontScale,
      'contextLength': contextLength,
      'contextTokenBudget': contextTokenBudget,
      'autoCompact': autoCompact,
      'agentMaxIterations': agentMaxIterations,
      'maxConcurrentAgents': maxConcurrentAgents,
      'toolApprovalPolicy': toolApprovalPolicy,
      'notifyOnComplete': notifyOnComplete,
      'privacyMode': privacyMode,
      'allowPhoneCall': allowPhoneCall,
      'allowSms': allowSms,
      'deniedToolNames': deniedToolNames.toList()..sort(),
      'bashCommandDenyPatterns': bashCommandDenyPatterns,
      'whisperModel': _prefs.getString(_keyWhisperModel),
      'ttsModel': _prefs.getString(_keyTtsModel),
      'temperature': temperature,
    };
  }

  void importAllSettings(Map<String, dynamic> settings) {
    if (settings.containsKey('systemPrompt')) {
      final value = settings['systemPrompt'];
      if (value is String) {
        systemPrompt = value;
      } else if (value == null) {
        systemPrompt = null;
      }
    }
    if (settings['themeMode'] is String) {
      themeMode = settings['themeMode'] as String;
    }
    final importedFontScale = _finiteDouble(settings['fontScale']);
    if (importedFontScale != null) fontScale = importedFontScale;

    final importedContextTokenBudget =
        _intValue(settings['contextTokenBudget']);
    if (importedContextTokenBudget != null) {
      contextTokenBudget = importedContextTokenBudget;
    } else {
      final importedContextLength = _intValue(settings['contextLength']);
      if (importedContextLength != null) {
        contextLength = importedContextLength;
        contextTokenBudget = importedContextLength ~/ 3;
      }
    }

    if (settings['autoCompact'] is bool) {
      autoCompact = settings['autoCompact'] as bool;
    }
    final importedAgentMaxIterations =
        _intValue(settings['agentMaxIterations']);
    if (importedAgentMaxIterations != null) {
      agentMaxIterations = importedAgentMaxIterations;
    }
    final importedMaxConcurrentAgents =
        _intValue(settings['maxConcurrentAgents']);
    if (importedMaxConcurrentAgents != null) {
      maxConcurrentAgents = importedMaxConcurrentAgents;
    }
    if (settings['toolApprovalPolicy'] is String) {
      toolApprovalPolicy = settings['toolApprovalPolicy'] as String;
    }
    if (settings['notifyOnComplete'] is bool) {
      notifyOnComplete = settings['notifyOnComplete'] as bool;
    }
    if (settings['privacyMode'] is bool) {
      privacyMode = settings['privacyMode'] as bool;
    }
    if (settings['allowPhoneCall'] is bool) {
      allowPhoneCall = settings['allowPhoneCall'] as bool;
    }
    if (settings['allowSms'] is bool) {
      allowSms = settings['allowSms'] as bool;
    }
    final importedDeniedToolNames = _stringList(settings['deniedToolNames']);
    if (importedDeniedToolNames != null) {
      deniedToolNames = importedDeniedToolNames.toSet();
    }
    final importedBashDenyPatterns =
        _stringList(settings['bashCommandDenyPatterns']);
    if (importedBashDenyPatterns != null) {
      bashCommandDenyPatterns = importedBashDenyPatterns;
    }
    if (settings.containsKey('whisperModel')) {
      final value = settings['whisperModel'];
      if (value is String) {
        whisperModel = value;
      } else if (value == null) {
        whisperModel = null;
      }
    }
    if (settings.containsKey('ttsModel')) {
      final value = settings['ttsModel'];
      if (value is String) {
        ttsModel = value;
      } else if (value == null) {
        ttsModel = null;
      }
    }
    final importedTemperature = _finiteDouble(settings['temperature']);
    if (importedTemperature != null) temperature = importedTemperature;
  }

  Future<({int imported, int skipped})> importProfiles(
    List<ProviderProfile> importedProfiles,
    ConflictResolution resolution,
  ) async {
    final existing = profiles;
    final existingIds = existing.map((p) => p.id).toSet();
    var imported = 0;
    var skipped = 0;

    switch (resolution) {
      case ConflictResolution.replace:
        final seenIds = <String>{};
        final next = <ProviderProfile>[];
        for (final profile in importedProfiles) {
          if (!seenIds.add(profile.id)) {
            skipped++;
            continue;
          }
          next.add(profile);
          imported++;
        }
        await setProfiles(next);
      case ConflictResolution.merge:
      case ConflictResolution.skip:
        final merged = List<ProviderProfile>.from(existing);
        final seenImportedIds = <String>{};
        for (final profile in importedProfiles) {
          if (!seenImportedIds.add(profile.id) ||
              existingIds.contains(profile.id)) {
            skipped++;
          } else {
            merged.add(profile);
            imported++;
          }
        }
        await setProfiles(merged);
    }

    return (imported: imported, skipped: skipped);
  }

  int? _intValue(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '');
  }

  double? _finiteDouble(Object? value) {
    final parsed = value is num
        ? value.toDouble()
        : double.tryParse(value?.toString() ?? '');
    if (parsed == null || !parsed.isFinite) return null;
    return parsed;
  }

  List<String>? _stringList(Object? value) {
    if (value is! List) return null;
    return value
        .map((item) => item?.toString().trim() ?? '')
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }
}
