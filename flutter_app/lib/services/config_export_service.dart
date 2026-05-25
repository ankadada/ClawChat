import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as encrypt_lib;

import '../constants.dart';
import '../models/provider_profile.dart';
import 'preferences_service.dart';

class ConfigExportService {
  static const int _currentVersion = 1;
  static const int _pbkdf2Iterations = 100000;

  static Future<String> exportConfig({String? password}) async {
    final prefs = PreferencesService();
    await prefs.init();

    final settings = prefs.exportAllSettings();
    final secretsContent = {
      'providerProfiles': prefs.profiles.map((p) => p.toJson()).toList(),
      'envVars': prefs.envVars,
    };

    final Map<String, dynamic> secrets;
    if (password != null && password.isNotEmpty) {
      secrets = _encryptSecrets(jsonEncode(secretsContent), password);
    } else {
      secrets = {
        'encrypted': false,
        ...secretsContent,
      };
    }

    final export = {
      'version': _currentVersion,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'appVersion': AppConstants.version,
      'settings': settings,
      'secrets': secrets,
    };

    return const JsonEncoder.withIndent('  ').convert(export);
  }

  static ConfigImportPreview previewImport(String jsonStr) {
    try {
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      final version = data['version'] as int? ?? 0;
      final exportedAt = data['exportedAt'] as String?;
      final secrets = data['secrets'] as Map<String, dynamic>?;
      final isEncrypted = secrets?['encrypted'] == true;

      var profileCount = -1;
      var envVarCount = -1;
      if (!isEncrypted && secrets != null) {
        final profiles = secrets['providerProfiles'] as List?;
        final envVars = secrets['envVars'] as Map?;
        profileCount = profiles?.length ?? 0;
        envVarCount = envVars?.length ?? 0;
      }

      return ConfigImportPreview(
        version: version,
        exportedAt: exportedAt != null ? DateTime.tryParse(exportedAt) : null,
        isEncrypted: isEncrypted,
        profileCount: profileCount,
        envVarCount: envVarCount,
        hasSettings: data.containsKey('settings'),
      );
    } catch (e) {
      throw FormatException('无效的配置文件格式: $e');
    }
  }

  static Future<ConfigImportResult> importConfig(
    String jsonStr, {
    String? password,
    ConflictResolution conflictResolution = ConflictResolution.merge,
  }) async {
    final data = jsonDecode(jsonStr) as Map<String, dynamic>;
    final version = data['version'] as int? ?? 0;
    if (version > _currentVersion) {
      throw FormatException('配置文件版本过高（v$version），请更新 App');
    }

    final prefs = PreferencesService();
    await prefs.init();

    final warnings = <String>[];
    var profilesImported = 0;
    var profilesSkipped = 0;
    var envVarsImported = 0;
    var settingsApplied = false;

    final settings = data['settings'] as Map<String, dynamic>?;
    if (settings != null) {
      prefs.importAllSettings(settings);
      settingsApplied = true;
    }

    final secrets = data['secrets'] as Map<String, dynamic>?;
    if (secrets != null) {
      late final Map<String, dynamic> secretsContent;
      if (secrets['encrypted'] == true) {
        if (password == null || password.isEmpty) {
          throw StateError('配置文件已加密，请输入密码');
        }
        final decrypted = _decryptSecrets(secrets, password);
        secretsContent = jsonDecode(decrypted) as Map<String, dynamic>;
      } else {
        secretsContent = secrets;
      }

      final profilesJson = secretsContent['providerProfiles'] as List?;
      if (profilesJson != null) {
        final importedProfiles = profilesJson
            .whereType<Map>()
            .map((item) => ProviderProfile.fromJson(
                  Map<String, dynamic>.from(item),
                ))
            .toList();
        final result = await prefs.importProfiles(
          importedProfiles,
          conflictResolution,
        );
        profilesImported = result.imported;
        profilesSkipped = result.skipped;
      }

      final importedEnvVars = secretsContent['envVars'] as Map?;
      if (importedEnvVars != null) {
        final sanitizedEnvVars = importedEnvVars.map<String, String>(
          (key, value) => MapEntry(key.toString(), value?.toString() ?? ''),
        );
        final currentEnvVars = Map<String, String>.from(prefs.envVars);
        switch (conflictResolution) {
          case ConflictResolution.replace:
            currentEnvVars
              ..clear()
              ..addAll(sanitizedEnvVars);
            envVarsImported = sanitizedEnvVars.length;
          case ConflictResolution.merge:
          case ConflictResolution.skip:
            for (final entry in sanitizedEnvVars.entries) {
              if (!currentEnvVars.containsKey(entry.key)) {
                currentEnvVars[entry.key] = entry.value;
                envVarsImported++;
              }
            }
        }
        prefs.envVars = currentEnvVars;
      }
    }

    return ConfigImportResult(
      profilesImported: profilesImported,
      profilesSkipped: profilesSkipped,
      envVarsImported: envVarsImported,
      settingsApplied: settingsApplied,
      warnings: warnings,
    );
  }

  static Map<String, dynamic> _encryptSecrets(
    String plaintext,
    String password,
  ) {
    final salt = encrypt_lib.SecureRandom(16).bytes;
    final key = _deriveKey(password, salt);
    final iv = encrypt_lib.IV.fromSecureRandom(12);
    final encrypter = encrypt_lib.Encrypter(
      encrypt_lib.AES(
        encrypt_lib.Key(key),
        mode: encrypt_lib.AESMode.gcm,
      ),
    );
    final encrypted = encrypter.encrypt(plaintext, iv: iv);
    return {
      'encrypted': true,
      'algorithm': 'aes-256-gcm',
      'kdf': 'pbkdf2-sha256',
      'iterations': _pbkdf2Iterations,
      'salt': base64Encode(salt),
      'iv': iv.base64,
      'data': encrypted.base64,
    };
  }

  static String _decryptSecrets(
    Map<String, dynamic> envelope,
    String password,
  ) {
    final salt = base64Decode(envelope['salt'] as String);
    final iv = encrypt_lib.IV.fromBase64(envelope['iv'] as String);
    final data = encrypt_lib.Encrypted.fromBase64(envelope['data'] as String);
    final iterations = envelope['iterations'] as int? ?? _pbkdf2Iterations;
    final key = _deriveKey(password, salt, iterations: iterations);
    final encrypter = encrypt_lib.Encrypter(
      encrypt_lib.AES(
        encrypt_lib.Key(key),
        mode: encrypt_lib.AESMode.gcm,
      ),
    );
    try {
      return encrypter.decrypt(data, iv: iv);
    } catch (_) {
      throw StateError('密码错误或文件已损坏');
    }
  }

  static Uint8List _deriveKey(
    String password,
    List<int> salt, {
    int? iterations,
  }) {
    final rounds = iterations ?? _pbkdf2Iterations;
    final passwordBytes = utf8.encode(password);
    var block =
        Hmac(sha256, passwordBytes).convert([...salt, 0, 0, 0, 1]).bytes;
    final result = Uint8List.fromList(block);
    for (var i = 1; i < rounds; i++) {
      block = Hmac(sha256, passwordBytes).convert(block).bytes;
      for (var j = 0; j < result.length; j++) {
        result[j] ^= block[j];
      }
    }
    return result;
  }
}

class ConfigImportResult {
  final int profilesImported;
  final int profilesSkipped;
  final int envVarsImported;
  final bool settingsApplied;
  final List<String> warnings;

  ConfigImportResult({
    required this.profilesImported,
    required this.profilesSkipped,
    required this.envVarsImported,
    required this.settingsApplied,
    required this.warnings,
  });
}

class ConfigImportPreview {
  final int version;
  final DateTime? exportedAt;
  final bool isEncrypted;
  final int profileCount;
  final int envVarCount;
  final bool hasSettings;

  ConfigImportPreview({
    required this.version,
    this.exportedAt,
    required this.isEncrypted,
    required this.profileCount,
    required this.envVarCount,
    required this.hasSettings,
  });
}
