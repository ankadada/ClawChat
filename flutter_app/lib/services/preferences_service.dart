import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/provider_profile.dart';

enum ConflictResolution { merge, replace, skip }

class PreferencesService {
  static const _keyApiKey = 'api_key';
  static const _keyApiFormat = 'api_format';
  static const _keyBaseUrl = 'base_url';
  static const _keyModel = 'model';
  static const _keyMaxTokens = 'max_tokens';
  static const _keySystemPrompt = 'system_prompt';
  static const _keyThinkingBudget = 'thinking_budget';
  static const _keyContextLength = 'context_length';
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
  static const _keyDualPaneSidebarWidth = 'dual_pane_sidebar_width';
  static const _keyTerminalFontSize = 'terminal_font_size';
  static const _keyWhisperModel = 'whisper_model';
  static const _keyTtsModel = 'tts_model';
  static const _keyProviderProfiles = 'provider_profiles';
  static const _keyActiveProfileId = 'active_provider_profile_id';

  static const toolApprovalAlways = 'always';
  static const toolApprovalSessionFirst = 'session_first';
  static const toolApprovalAuto = 'auto';
  static const defaultToolApprovalPolicy = toolApprovalSessionFirst;
  static const defaultDualPaneSidebarWidth = 280.0;
  static const int defaultAgentMaxIterations = 25;
  static const int maxAgentMaxIterations = 99;
  static const int defaultMaxConcurrentAgents = 3;
  static const int maxMaxConcurrentAgents = 5;

  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static PreferencesService? _instance;
  Map<String, String> _cachedEnvVars = {};
  List<ProviderProfile> _cachedProfiles = [];
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

    _cachedProfiles = value.isEmpty
        ? [ProviderProfile.defaults()]
        : value.map((p) => p.copyWith()).toList();
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

  int get thinkingBudget => _activeProfile.thinkingBudget;
  set thinkingBudget(int v) => _replaceActiveProfile(
        _activeProfile.copyWith(thinkingBudget: v),
      );

  int get contextLength => _prefs.getInt(_keyContextLength) ?? 100000;
  set contextLength(int v) => _prefs.setInt(_keyContextLength, v);

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
      'autoCompact': autoCompact,
      'agentMaxIterations': agentMaxIterations,
      'maxConcurrentAgents': maxConcurrentAgents,
      'toolApprovalPolicy': toolApprovalPolicy,
      'notifyOnComplete': notifyOnComplete,
      'privacyMode': privacyMode,
      'allowPhoneCall': allowPhoneCall,
      'allowSms': allowSms,
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

    final importedContextLength = _intValue(settings['contextLength']);
    if (importedContextLength != null) contextLength = importedContextLength;

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
        await setProfiles(importedProfiles);
        imported = importedProfiles.length;
      case ConflictResolution.merge:
      case ConflictResolution.skip:
        final merged = List<ProviderProfile>.from(existing);
        for (final profile in importedProfiles) {
          if (existingIds.contains(profile.id)) {
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
}
