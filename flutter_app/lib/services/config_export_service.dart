import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as encrypt_lib;

import '../constants.dart';
import '../models/mcp_server_config.dart';
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
      'promptProfiles':
          prefs.promptProfiles.map((profile) => profile.toJson()).toList(),
      'envVars': prefs.envVars,
      'mcpServers': prefs.mcpServers.map((server) => server.toJson()).toList(),
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
      var promptProfileCount = -1;
      var envVarCount = -1;
      var mcpServerCount = -1;
      if (!isEncrypted && secrets != null) {
        final profiles = secrets['providerProfiles'] as List?;
        final promptProfiles = secrets['promptProfiles'] as List?;
        final envVars = secrets['envVars'] as Map?;
        final mcpServers = secrets['mcpServers'] as List?;
        profileCount = profiles?.length ?? 0;
        promptProfileCount = promptProfiles?.length ?? 0;
        envVarCount = envVars?.length ?? 0;
        mcpServerCount = mcpServers?.length ?? 0;
      }

      return ConfigImportPreview(
        version: version,
        exportedAt: exportedAt != null ? DateTime.tryParse(exportedAt) : null,
        isEncrypted: isEncrypted,
        profileCount: profileCount,
        promptProfileCount: promptProfileCount,
        envVarCount: envVarCount,
        mcpServerCount: mcpServerCount,
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
    final parsed = _parseImportPayload(jsonStr, password: password);

    final prefs = PreferencesService();
    await prefs.init();

    var profilesImported = 0;
    var profilesSkipped = 0;
    var promptProfilesImported = 0;
    var promptProfilesSkipped = 0;
    var envVarsImported = 0;
    var mcpServersImported = 0;
    var mcpServersSkipped = 0;
    var settingsApplied = false;

    if (parsed.settings != null) {
      prefs.importAllSettings(parsed.settings!);
      settingsApplied = true;
    }

    final secrets = parsed.secrets;
    if (secrets != null) {
      if (secrets.providerProfiles != null) {
        final result = await prefs.importProfiles(
          secrets.providerProfiles!,
          conflictResolution,
        );
        profilesImported = result.imported;
        profilesSkipped = result.skipped;
      }

      if (secrets.promptProfiles != null) {
        final result = await prefs.importPromptProfiles(
          secrets.promptProfiles!,
          conflictResolution,
        );
        promptProfilesImported = result.imported;
        promptProfilesSkipped = result.skipped;
      }

      if (secrets.envVars != null) {
        final sanitizedEnvVars = secrets.envVars!;
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

      if (secrets.mcpServers != null) {
        final result = await prefs.importMcpServers(
          secrets.mcpServers!,
          conflictResolution,
        );
        mcpServersImported = result.imported;
        mcpServersSkipped = result.skipped;
      }
    }

    return ConfigImportResult(
      profilesImported: profilesImported,
      profilesSkipped: profilesSkipped,
      promptProfilesImported: promptProfilesImported,
      promptProfilesSkipped: promptProfilesSkipped,
      envVarsImported: envVarsImported,
      mcpServersImported: mcpServersImported,
      mcpServersSkipped: mcpServersSkipped,
      settingsApplied: settingsApplied,
      warnings: parsed.warnings,
    );
  }

  static _ParsedConfigImport _parseImportPayload(
    String jsonStr, {
    String? password,
  }) {
    final data = jsonDecode(jsonStr) as Map<String, dynamic>;
    final version = data['version'] as int? ?? 0;
    if (version > _currentVersion) {
      throw FormatException('配置文件版本过高（v$version），请更新 App');
    }

    final rawSettings = data['settings'];
    final settings = rawSettings is Map
        ? Map<String, dynamic>.from(rawSettings)
        : rawSettings == null
            ? null
            : <String, dynamic>{};
    final warnings = <String>[];
    final rawSecrets = data['secrets'];
    final secrets = rawSecrets is Map
        ? _parseSecrets(
            Map<String, dynamic>.from(rawSecrets),
            password: password,
            warnings: warnings,
          )
        : null;

    return _ParsedConfigImport(
      settings: settings,
      secrets: secrets,
      warnings: warnings,
    );
  }

  static _ParsedSecrets _parseSecrets(
    Map<String, dynamic> secrets, {
    required String? password,
    required List<String> warnings,
  }) {
    late final Map<String, dynamic> secretsContent;
    final encrypted = secrets['encrypted'] == true;
    if (encrypted) {
      if (password == null || password.isEmpty) {
        throw StateError('配置文件已加密，请输入密码');
      }
      final decrypted = _decryptSecrets(secrets, password);
      final decoded = jsonDecode(decrypted);
      if (decoded is! Map) {
        throw const FormatException('加密配置内容无效');
      }
      secretsContent = Map<String, dynamic>.from(decoded);
    } else {
      secretsContent = secrets;
    }

    final providerProfiles = _parseProviderProfiles(
      secretsContent['providerProfiles'],
    );

    final promptWarningCount = warnings.length;
    final promptProfiles = _parsePromptProfiles(
      secretsContent['promptProfiles'],
      warnings,
    );
    if (encrypted && warnings.length > promptWarningCount) {
      throw const FormatException('加密配置内的提示词配置无效');
    }

    final mcpWarningCount = warnings.length;
    final mcpServers = _parseMcpServers(
      secretsContent['mcpServers'],
      warnings,
    );
    if (encrypted && warnings.length > mcpWarningCount) {
      throw const FormatException('加密配置内的 MCP 服务器配置无效');
    }

    return _ParsedSecrets(
      providerProfiles: providerProfiles,
      promptProfiles: promptProfiles,
      envVars: _parseEnvVars(secretsContent['envVars']),
      mcpServers: mcpServers,
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

  static List<PromptProfile>? _parsePromptProfiles(
    Object? rawProfiles,
    List<String> warnings,
  ) {
    if (rawProfiles == null) return null;
    if (rawProfiles is! List) {
      warnings.add('已跳过无效提示词配置');
      return null;
    }

    final profiles = <PromptProfile>[];
    try {
      for (final item in rawProfiles) {
        if (item is! Map) {
          throw const FormatException('Invalid prompt profile');
        }
        profiles.add(
          PromptProfile.fromJson(Map<String, dynamic>.from(item)),
        );
      }
    } catch (_) {
      warnings.add('已跳过无效提示词配置');
      return null;
    }
    return profiles;
  }

  static List<ProviderProfile>? _parseProviderProfiles(
    Object? rawProfiles,
  ) {
    if (rawProfiles == null) return null;
    if (rawProfiles is! List) {
      throw const FormatException('模型配置无效');
    }

    final profiles = <ProviderProfile>[];
    try {
      for (final item in rawProfiles) {
        if (item is! Map) {
          throw const FormatException('Invalid provider profile');
        }
        profiles.add(
          ProviderProfile.fromJson(Map<String, dynamic>.from(item)),
        );
      }
    } catch (_) {
      throw const FormatException('模型配置无效');
    }
    return profiles;
  }

  static List<McpServerConfig>? _parseMcpServers(
    Object? rawServers,
    List<String> warnings,
  ) {
    if (rawServers == null) return null;
    if (rawServers is! List) {
      warnings.add('已跳过无效 MCP 服务器配置');
      return null;
    }

    final servers = <McpServerConfig>[];
    try {
      for (final item in rawServers) {
        if (item is! Map) {
          throw const FormatException('Invalid MCP server config');
        }
        servers.add(
          McpServerConfig.fromJson(Map<String, dynamic>.from(item)),
        );
      }
    } catch (_) {
      warnings.add('已跳过无效 MCP 服务器配置');
      return null;
    }
    return servers;
  }

  static Map<String, String>? _parseEnvVars(Object? rawEnvVars) {
    if (rawEnvVars == null) return null;
    if (rawEnvVars is! Map) return const {};
    return rawEnvVars.map<String, String>(
      (key, value) => MapEntry(key.toString(), value?.toString() ?? ''),
    );
  }
}

class _ParsedConfigImport {
  final Map<String, dynamic>? settings;
  final _ParsedSecrets? secrets;
  final List<String> warnings;

  const _ParsedConfigImport({
    required this.settings,
    required this.secrets,
    required this.warnings,
  });
}

class _ParsedSecrets {
  final List<ProviderProfile>? providerProfiles;
  final List<PromptProfile>? promptProfiles;
  final Map<String, String>? envVars;
  final List<McpServerConfig>? mcpServers;

  const _ParsedSecrets({
    required this.providerProfiles,
    required this.promptProfiles,
    required this.envVars,
    required this.mcpServers,
  });
}

class ConfigImportResult {
  final int profilesImported;
  final int profilesSkipped;
  final int promptProfilesImported;
  final int promptProfilesSkipped;
  final int envVarsImported;
  final int mcpServersImported;
  final int mcpServersSkipped;
  final bool settingsApplied;
  final List<String> warnings;

  ConfigImportResult({
    required this.profilesImported,
    required this.profilesSkipped,
    this.promptProfilesImported = 0,
    this.promptProfilesSkipped = 0,
    required this.envVarsImported,
    this.mcpServersImported = 0,
    this.mcpServersSkipped = 0,
    required this.settingsApplied,
    required this.warnings,
  });
}

class ConfigImportPreview {
  final int version;
  final DateTime? exportedAt;
  final bool isEncrypted;
  final int profileCount;
  final int promptProfileCount;
  final int envVarCount;
  final int mcpServerCount;
  final bool hasSettings;

  ConfigImportPreview({
    required this.version,
    this.exportedAt,
    required this.isEncrypted,
    required this.profileCount,
    this.promptProfileCount = -1,
    required this.envVarCount,
    this.mcpServerCount = -1,
    required this.hasSettings,
  });
}
