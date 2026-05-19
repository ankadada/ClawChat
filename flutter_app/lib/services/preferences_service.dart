import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/provider_profile.dart';

class PreferencesService {
  static const _keyAutoStart = 'auto_start_gateway';
  static const _keySetupComplete = 'setup_complete';
  static const _keyFirstRun = 'first_run';
  static const _keyLastAppVersion = 'last_app_version';
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
  static const _keyAllowPhoneCall = 'allow_phone_call';
  static const _keyAllowSms = 'allow_sms';
  static const _keyWhisperModel = 'whisper_model';
  static const _keyTtsModel = 'tts_model';
  static const _keyProviderProfiles = 'provider_profiles';
  static const _keyActiveProfileId = 'active_provider_profile_id';

  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static PreferencesService? _instance;
  Map<String, String> _cachedEnvVars = {};
  List<ProviderProfile> _cachedProfiles = [];
  String? _cachedActiveProfileId;
  Future<void> _profileWriteChain = Future.value();

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

    if (_cachedProfiles.isEmpty) {
      _cachedProfiles = [ProviderProfile.defaults()];
      _cachedActiveProfileId = _cachedProfiles.first.id;
      await _prefs.setString(_keyActiveProfileId, _cachedActiveProfileId!);
      await _persistProfilesNow();
    }
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

  int _activeProfileIndex() {
    if (_cachedProfiles.isEmpty) {
      _cachedProfiles = [ProviderProfile.defaults()];
      _cachedActiveProfileId = _cachedProfiles.first.id;
      _persistProfiles();
    }
    final index =
        _cachedProfiles.indexWhere((p) => p.id == _cachedActiveProfileId);
    if (index >= 0) return index;
    _cachedActiveProfileId = _cachedProfiles.first.id;
    _prefs.setString(_keyActiveProfileId, _cachedActiveProfileId!);
    return 0;
  }

  ProviderProfile get _activeProfile => _cachedProfiles[_activeProfileIndex()];

  void _replaceActiveProfile(ProviderProfile profile) {
    _cachedProfiles[_activeProfileIndex()] = profile;
    _persistProfiles();
  }

  Future<void> _persistProfilesNow() {
    return _secureStorage.write(
      key: _keyProviderProfiles,
      value: jsonEncode(_cachedProfiles.map((p) => p.toJson()).toList()),
    );
  }

  void _persistProfiles() {
    final snapshot =
        jsonEncode(_cachedProfiles.map((p) => p.toJson()).toList());
    _profileWriteChain = _profileWriteChain.then((_) {
      return _secureStorage.write(key: _keyProviderProfiles, value: snapshot);
    }).catchError((e) {
      debugPrint('Failed to persist provider profiles: $e');
    });
  }

  List<ProviderProfile> get profiles {
    _activeProfileIndex();
    return _cachedProfiles.map((p) => p.copyWith()).toList();
  }

  set profiles(List<ProviderProfile> value) {
    _cachedProfiles = value.isEmpty
        ? [ProviderProfile.defaults()]
        : value.map((p) => p.copyWith()).toList();
    if (!_cachedProfiles.any((p) => p.id == _cachedActiveProfileId)) {
      _cachedActiveProfileId = _cachedProfiles.first.id;
      _prefs.setString(_keyActiveProfileId, _cachedActiveProfileId!);
    }
    _persistProfiles();
  }

  String? get activeProfileId {
    _activeProfileIndex();
    return _cachedActiveProfileId;
  }

  set activeProfileId(String? value) {
    if (value != null && _cachedProfiles.any((p) => p.id == value)) {
      _cachedActiveProfileId = value;
    } else if (_cachedProfiles.isNotEmpty) {
      _cachedActiveProfileId = _cachedProfiles.first.id;
    } else {
      _cachedProfiles = [ProviderProfile.defaults()];
      _cachedActiveProfileId = _cachedProfiles.first.id;
      _persistProfiles();
    }
    if (_cachedActiveProfileId != null) {
      _prefs.setString(_keyActiveProfileId, _cachedActiveProfileId!);
    } else {
      _prefs.remove(_keyActiveProfileId);
    }
  }

  ProviderProfile get activeProfile => _activeProfile.copyWith();

  bool get autoStartGateway => _prefs.getBool(_keyAutoStart) ?? false;
  set autoStartGateway(bool value) => _prefs.setBool(_keyAutoStart, value);

  bool get setupComplete => _prefs.getBool(_keySetupComplete) ?? false;
  set setupComplete(bool value) => _prefs.setBool(_keySetupComplete, value);

  bool get isFirstRun => _prefs.getBool(_keyFirstRun) ?? true;
  set isFirstRun(bool value) => _prefs.setBool(_keyFirstRun, value);

  String? get lastAppVersion => _prefs.getString(_keyLastAppVersion);
  set lastAppVersion(String? value) {
    if (value != null) {
      _prefs.setString(_keyLastAppVersion, value);
    } else {
      _prefs.remove(_keyLastAppVersion);
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

  bool get allowPhoneCall =>
      _initialized ? (_prefs.getBool(_keyAllowPhoneCall) ?? false) : false;
  set allowPhoneCall(bool v) => _prefs.setBool(_keyAllowPhoneCall, v);

  bool get allowSms =>
      _initialized ? (_prefs.getBool(_keyAllowSms) ?? false) : false;
  set allowSms(bool v) => _prefs.setBool(_keyAllowSms, v);

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
}
