import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static PreferencesService? _instance;
  static String? _cachedApiKey;

  late SharedPreferences _prefs;

  factory PreferencesService() {
    return _instance ??= PreferencesService._();
  }

  PreferencesService._();

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    await _migrateApiKeyToSecureStorage();
    _cachedApiKey = await _secureStorage.read(key: _keyApiKey);
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

  String? get apiKey => _cachedApiKey;

  set apiKey(String? v) {
    _cachedApiKey = v;
    if (v != null) {
      _secureStorage.write(key: _keyApiKey, value: v);
    } else {
      _secureStorage.delete(key: _keyApiKey);
    }
  }

  String? get apiFormat => _prefs.getString(_keyApiFormat);
  set apiFormat(String? v) =>
      v != null ? _prefs.setString(_keyApiFormat, v) : _prefs.remove(_keyApiFormat);

  String? get baseUrl => _prefs.getString(_keyBaseUrl);
  set baseUrl(String? v) =>
      v != null ? _prefs.setString(_keyBaseUrl, v) : _prefs.remove(_keyBaseUrl);

  String? get model => _prefs.getString(_keyModel);
  set model(String? v) =>
      v != null ? _prefs.setString(_keyModel, v) : _prefs.remove(_keyModel);

  int? get maxTokens => _prefs.getInt(_keyMaxTokens);
  set maxTokens(int? v) =>
      v != null ? _prefs.setInt(_keyMaxTokens, v) : _prefs.remove(_keyMaxTokens);

  String? get systemPrompt => _prefs.getString(_keySystemPrompt);
  set systemPrompt(String? v) =>
      v != null ? _prefs.setString(_keySystemPrompt, v) : _prefs.remove(_keySystemPrompt);

  int get thinkingBudget => _prefs.getInt(_keyThinkingBudget) ?? 0;
  set thinkingBudget(int v) => _prefs.setInt(_keyThinkingBudget, v);

  int get contextLength => _prefs.getInt(_keyContextLength) ?? 100000;
  set contextLength(int v) => _prefs.setInt(_keyContextLength, v);

  bool get autoCompact => _prefs.getBool(_keyAutoCompact) ?? true;
  set autoCompact(bool v) => _prefs.setBool(_keyAutoCompact, v);

  double get temperature => _prefs.getDouble(_keyTemperature) ?? 0.7;
  set temperature(double v) => _prefs.setDouble(_keyTemperature, v);

  Map<String, String> get envVars {
    final json = _prefs.getString(_keyEnvVars);
    if (json == null) return {};
    try {
      return Map<String, String>.from(jsonDecode(json));
    } catch (_) {
      return {};
    }
  }

  set envVars(Map<String, String> vars) {
    _prefs.setString(_keyEnvVars, jsonEncode(vars));
  }

  // 'system' | 'light' | 'dark'
  String get themeMode => _prefs.getString(_keyDarkMode) ?? 'system';
  set themeMode(String v) => _prefs.setString(_keyDarkMode, v);

  // 0.8 = small, 1.0 = default, 1.2 = large, 1.4 = extra large
  double get fontScale => _prefs.getDouble(_keyFontSize) ?? 1.0;
  set fontScale(double v) => _prefs.setDouble(_keyFontSize, v);

  bool get notifyOnComplete => _prefs.getBool(_keyNotifyOnComplete) ?? true;
  set notifyOnComplete(bool v) => _prefs.setBool(_keyNotifyOnComplete, v);

  bool get allowPhoneCall => _prefs.getBool(_keyAllowPhoneCall) ?? false;
  set allowPhoneCall(bool v) => _prefs.setBool(_keyAllowPhoneCall, v);

  bool get allowSms => _prefs.getBool(_keyAllowSms) ?? false;
  set allowSms(bool v) => _prefs.setBool(_keyAllowSms, v);
}
