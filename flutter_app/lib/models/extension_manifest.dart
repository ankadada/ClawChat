import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Schema-versioned trust declaration for a locally installed skill/extension.
///
/// Manifests are stored as `skill.json` next to `SKILL.md`. The parser is
/// intentionally strict: a typo in a security-sensitive field must not turn
/// into an undeclared capability.
class ExtensionManifest {
  static const currentSchemaVersion = 1;

  final int schemaVersion;
  final String id;
  final String name;
  final String description;
  final ModelFacingIdentity model;
  final String version;
  final ExtensionSource source;
  final ExtensionIntegrity integrity;
  final String author;
  final String license;
  final ExtensionCapabilities capabilities;

  const ExtensionManifest({
    required this.schemaVersion,
    required this.id,
    required this.name,
    required this.description,
    required this.model,
    required this.version,
    required this.source,
    required this.integrity,
    required this.author,
    required this.license,
    required this.capabilities,
  });

  factory ExtensionManifest.parse(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const FormatException('Manifest must be a JSON object.');
    }
    return ExtensionManifest.fromJson(Map<String, dynamic>.from(decoded));
  }

  factory ExtensionManifest.fromJson(Map<String, dynamic> json) {
    _rejectUnknown(
        json,
        const {
          'schemaVersion',
          'id',
          'name',
          'description',
          'model',
          'version',
          'source',
          'integrity',
          'author',
          'license',
          'capabilities',
        },
        'manifest');

    final schemaVersion = _requiredInt(json, 'schemaVersion', 'manifest');
    if (schemaVersion != currentSchemaVersion) {
      throw FormatException(
        'Unsupported manifest schemaVersion: $schemaVersion.',
      );
    }

    final id = _requiredString(json, 'id', 'manifest', max: 128).toLowerCase();
    if (!_extensionId.hasMatch(id)) {
      throw const FormatException('Manifest id is invalid.');
    }
    final version = _requiredString(json, 'version', 'manifest', max: 64);
    if (!_semanticVersion.hasMatch(version)) {
      throw const FormatException('Manifest version must be semantic.');
    }

    return ExtensionManifest(
      schemaVersion: schemaVersion,
      id: id,
      name: _requiredString(json, 'name', 'manifest', max: 120),
      description: _requiredString(json, 'description', 'manifest', max: 1000),
      model: ModelFacingIdentity.fromJson(
        _requiredMap(json, 'model', 'manifest'),
      ),
      version: version,
      source: ExtensionSource.fromJson(
        _requiredMap(json, 'source', 'manifest'),
      ),
      integrity: ExtensionIntegrity.fromJson(
        _requiredMap(json, 'integrity', 'manifest'),
      ),
      author: _requiredString(json, 'author', 'manifest', max: 200),
      license: _requiredString(json, 'license', 'manifest', max: 80),
      capabilities: ExtensionCapabilities.fromJson(
        _requiredMap(json, 'capabilities', 'manifest'),
      ),
    );
  }

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'id': id,
        'name': name,
        'description': description,
        'model': model.toJson(),
        'version': version,
        'source': source.toJson(),
        'integrity': integrity.toJson(),
        'author': author,
        'license': license,
        'capabilities': capabilities.toJson(),
      };

  /// Digest publishers place in `integrity.digest`.
  ///
  /// Attestation values are excluded to avoid a circular digest. All values
  /// are normalized before canonical JSON is produced.
  String get canonicalDigest {
    final json = toJson();
    json['integrity'] = <String, dynamic>{};
    return sha256.convert(utf8.encode(_canonicalJson(json))).toString();
  }

  /// Digest of the complete normalized manifest, persisted with consent.
  String get grantDigest =>
      sha256.convert(utf8.encode(_canonicalJson(toJson()))).toString();

  IntegrityStatus get integrityStatus {
    if (integrity.algorithm == null && integrity.digest == null) {
      return integrity.signature == null
          ? IntegrityStatus.notProvided
          : IntegrityStatus.signatureUnverified;
    }
    if (integrity.algorithm != 'sha256' || integrity.digest == null) {
      return IntegrityStatus.unsupported;
    }
    if (integrity.digest != canonicalDigest) return IntegrityStatus.mismatch;
    return integrity.signature == null
        ? IntegrityStatus.verifiedDigest
        : IntegrityStatus.digestVerifiedSignatureUnverified;
  }

  bool get failsIntegrityClosed =>
      integrityStatus == IntegrityStatus.mismatch ||
      integrityStatus == IntegrityStatus.unsupported;
}

class ModelFacingIdentity {
  final String name;
  final String description;

  const ModelFacingIdentity({required this.name, required this.description});

  factory ModelFacingIdentity.fromJson(Map<String, dynamic> json) {
    _rejectUnknown(json, const {'name', 'description'}, 'model');
    final name = _requiredString(json, 'name', 'model', max: 80);
    if (!_capabilityName.hasMatch(name)) {
      throw const FormatException('model.name is invalid.');
    }
    return ModelFacingIdentity(
      name: name,
      description: _requiredString(json, 'description', 'model', max: 500),
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
      };
}

class ExtensionSource {
  final String type;
  final String? url;

  const ExtensionSource({required this.type, this.url});

  factory ExtensionSource.fromJson(Map<String, dynamic> json) {
    _rejectUnknown(json, const {'type', 'url'}, 'source');
    final type = _requiredString(json, 'type', 'source', max: 16).toLowerCase();
    if (!const {'local', 'url', 'bundled'}.contains(type)) {
      throw const FormatException('Manifest source.type is invalid.');
    }
    final rawUrl = _optionalString(json, 'url', 'source', max: 2048);
    if (type == 'url' && rawUrl == null) {
      throw const FormatException('URL source requires source.url.');
    }
    if (type != 'url' && rawUrl != null) {
      throw const FormatException('Only URL source may declare source.url.');
    }
    String? normalizedUrl;
    if (rawUrl != null) {
      final uri = Uri.tryParse(rawUrl);
      if (uri == null ||
          !uri.hasScheme ||
          !const {'https', 'http'}.contains(uri.scheme.toLowerCase()) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment) {
        throw const FormatException(
          'Manifest source.url must be a credential-free HTTP(S) URL.',
        );
      }
      normalizedUrl = uri
          .replace(
              scheme: uri.scheme.toLowerCase(), host: uri.host.toLowerCase())
          .toString();
    }
    return ExtensionSource(type: type, url: normalizedUrl);
  }

  Map<String, dynamic> toJson() => {
        'type': type,
        if (url != null) 'url': url,
      };
}

class ExtensionIntegrity {
  final String? algorithm;
  final String? digest;
  final String? signature;
  final String? keyId;

  const ExtensionIntegrity({
    this.algorithm,
    this.digest,
    this.signature,
    this.keyId,
  });

  factory ExtensionIntegrity.fromJson(Map<String, dynamic> json) {
    _rejectUnknown(
      json,
      const {'algorithm', 'digest', 'signature', 'keyId'},
      'integrity',
    );
    final algorithm =
        _optionalString(json, 'algorithm', 'integrity', max: 24)?.toLowerCase();
    final digest =
        _optionalString(json, 'digest', 'integrity', max: 128)?.toLowerCase();
    final signature =
        _optionalString(json, 'signature', 'integrity', max: 4096);
    final keyId = _optionalString(json, 'keyId', 'integrity', max: 256);
    if ((algorithm == null) != (digest == null)) {
      throw const FormatException(
        'integrity.algorithm and integrity.digest must be declared together.',
      );
    }
    if (algorithm == 'sha256' && !_sha256.hasMatch(digest!)) {
      throw const FormatException('integrity.digest is not a SHA-256 digest.');
    }
    if (signature != null && keyId == null) {
      throw const FormatException('Signed metadata requires integrity.keyId.');
    }
    return ExtensionIntegrity(
      algorithm: algorithm,
      digest: digest,
      signature: signature,
      keyId: keyId,
    );
  }

  Map<String, dynamic> toJson() => {
        if (algorithm != null) 'algorithm': algorithm,
        if (digest != null) 'digest': digest,
        if (signature != null) 'signature': signature,
        if (keyId != null) 'keyId': keyId,
      };
}

class ExtensionCapabilities {
  final List<String> tools;
  final List<String> commands;
  final List<String> networkDomains;
  final FilesystemCapabilities filesystem;
  final AndroidCapabilities android;
  final List<String> secrets;
  final SubprocessCapabilities subprocess;
  final String riskTier;
  final String updatePolicy;

  const ExtensionCapabilities({
    required this.tools,
    required this.commands,
    required this.networkDomains,
    required this.filesystem,
    required this.android,
    required this.secrets,
    required this.subprocess,
    required this.riskTier,
    required this.updatePolicy,
  });

  factory ExtensionCapabilities.fromJson(Map<String, dynamic> json) {
    _rejectUnknown(
        json,
        const {
          'tools',
          'commands',
          'networkDomains',
          'filesystem',
          'android',
          'secrets',
          'subprocess',
          'riskTier',
          'updatePolicy',
        },
        'capabilities');
    final risk = _requiredString(json, 'riskTier', 'capabilities', max: 16)
        .toLowerCase();
    if (!const {'low', 'moderate', 'high', 'critical'}.contains(risk)) {
      throw const FormatException('capabilities.riskTier is invalid.');
    }
    final update = _requiredString(
      json,
      'updatePolicy',
      'capabilities',
      max: 24,
    ).toLowerCase();
    if (!const {'manual', 'disabled'}.contains(update)) {
      throw const FormatException('capabilities.updatePolicy is invalid.');
    }
    return ExtensionCapabilities(
      tools: _normalizedNames(json, 'tools', 'capabilities', _capabilityName),
      commands:
          _normalizedNames(json, 'commands', 'capabilities', _commandName),
      networkDomains: _normalizedDomains(json, 'networkDomains'),
      filesystem: FilesystemCapabilities.fromJson(
        _requiredMap(json, 'filesystem', 'capabilities'),
      ),
      android: AndroidCapabilities.fromJson(
        _requiredMap(json, 'android', 'capabilities'),
      ),
      secrets: _normalizedNames(
        json,
        'secrets',
        'capabilities',
        _secretName,
        uppercase: true,
      ),
      subprocess: SubprocessCapabilities.fromJson(
        _requiredMap(json, 'subprocess', 'capabilities'),
      ),
      riskTier: risk,
      updatePolicy: update,
    );
  }

  Map<String, dynamic> toJson() => {
        'tools': tools,
        'commands': commands,
        'networkDomains': networkDomains,
        'filesystem': filesystem.toJson(),
        'android': android.toJson(),
        'secrets': secrets,
        'subprocess': subprocess.toJson(),
        'riskTier': riskTier,
        'updatePolicy': updatePolicy,
      };

  ExtensionCapabilitySnapshot get snapshot => ExtensionCapabilitySnapshot(
        tools: tools,
        commands: commands,
        networkDomains: networkDomains,
        // Android's current pathname/proot bridge cannot enforce these scopes
        // race-free. Keep them visible as denied declarations, never grants.
        filesystemRead: const [],
        filesystemWrite: const [],
        deniedFilesystemRead: filesystem.read,
        deniedFilesystemWrite: filesystem.write,
        androidIntents: android.intents,
        androidPermissions: android.permissions,
        secretNames: secrets,
        runtimes: subprocess.runtimes,
        subprocessRequired: subprocess.required,
        riskTier: riskTier,
        updatePolicy: updatePolicy,
      );
}

class FilesystemCapabilities {
  final List<String> read;
  final List<String> write;

  const FilesystemCapabilities({required this.read, required this.write});

  factory FilesystemCapabilities.fromJson(Map<String, dynamic> json) {
    _rejectUnknown(json, const {'read', 'write'}, 'filesystem');
    return FilesystemCapabilities(
      read: _normalizedPaths(json, 'read', 'filesystem'),
      write: _normalizedPaths(json, 'write', 'filesystem'),
    );
  }

  Map<String, dynamic> toJson() => {'read': read, 'write': write};
}

class AndroidCapabilities {
  final List<String> intents;
  final List<String> permissions;

  const AndroidCapabilities({required this.intents, required this.permissions});

  factory AndroidCapabilities.fromJson(Map<String, dynamic> json) {
    _rejectUnknown(json, const {'intents', 'permissions'}, 'android');
    return AndroidCapabilities(
      intents: _normalizedNames(json, 'intents', 'android', _androidName),
      permissions:
          _normalizedNames(json, 'permissions', 'android', _androidName),
    );
  }

  Map<String, dynamic> toJson() => {
        'intents': intents,
        'permissions': permissions,
      };
}

class SubprocessCapabilities {
  final bool required;
  final List<String> runtimes;

  const SubprocessCapabilities({
    required this.required,
    required this.runtimes,
  });

  factory SubprocessCapabilities.fromJson(Map<String, dynamic> json) {
    _rejectUnknown(json, const {'required', 'runtimes'}, 'subprocess');
    final required = json['required'];
    if (required is! bool) {
      throw const FormatException('subprocess.required must be a boolean.');
    }
    final runtimes =
        _normalizedNames(json, 'runtimes', 'subprocess', _commandName);
    if (!required && runtimes.isNotEmpty) {
      throw const FormatException(
        'subprocess.runtimes requires subprocess.required=true.',
      );
    }
    return SubprocessCapabilities(required: required, runtimes: runtimes);
  }

  Map<String, dynamic> toJson() => {
        'required': required,
        'runtimes': runtimes,
      };
}

class ExtensionCapabilitySnapshot {
  final List<String> tools;
  final List<String> commands;
  final List<String> networkDomains;
  final List<String> filesystemRead;
  final List<String> filesystemWrite;
  final List<String> deniedFilesystemRead;
  final List<String> deniedFilesystemWrite;
  final List<String> androidIntents;
  final List<String> androidPermissions;
  final List<String> secretNames;
  final List<String> runtimes;
  final bool subprocessRequired;
  final String riskTier;
  final String updatePolicy;

  const ExtensionCapabilitySnapshot({
    required this.tools,
    required this.commands,
    required this.networkDomains,
    required this.filesystemRead,
    required this.filesystemWrite,
    this.deniedFilesystemRead = const [],
    this.deniedFilesystemWrite = const [],
    required this.androidIntents,
    required this.androidPermissions,
    required this.secretNames,
    required this.runtimes,
    required this.subprocessRequired,
    required this.riskTier,
    required this.updatePolicy,
  });

  factory ExtensionCapabilitySnapshot.legacy() =>
      const ExtensionCapabilitySnapshot(
        tools: [],
        commands: [],
        networkDomains: [],
        filesystemRead: [],
        filesystemWrite: [],
        deniedFilesystemRead: [],
        deniedFilesystemWrite: [],
        androidIntents: [],
        androidPermissions: [],
        secretNames: [],
        runtimes: [],
        subprocessRequired: false,
        riskTier: 'unknown',
        updatePolicy: 'disabled',
      );

  factory ExtensionCapabilitySnapshot.fromJson(Map<String, dynamic> json) {
    _rejectUnknown(
        json,
        const {
          'tools',
          'commands',
          'networkDomains',
          'filesystemRead',
          'filesystemWrite',
          'deniedFilesystemRead',
          'deniedFilesystemWrite',
          'androidIntents',
          'androidPermissions',
          'secretNames',
          'runtimes',
          'subprocessRequired',
          'riskTier',
          'updatePolicy',
        },
        'capability snapshot');
    List<String> values(String key) =>
        _stringList(json, key, 'capability snapshot', maxItems: 128);
    final subprocessRequired = json['subprocessRequired'];
    if (subprocessRequired is! bool) {
      throw const FormatException(
        'capability snapshot subprocessRequired must be a boolean.',
      );
    }
    final storedRead = values('filesystemRead');
    final storedWrite = values('filesystemWrite');
    final hasRuntimeDenials = json.containsKey('deniedFilesystemRead') ||
        json.containsKey('deniedFilesystemWrite');
    return ExtensionCapabilitySnapshot(
      tools: values('tools'),
      commands: values('commands'),
      networkDomains: values('networkDomains'),
      // Legacy grants used these fields as if they were usable. Migrate them
      // into explicit runtime denials instead of silently preserving access.
      filesystemRead: hasRuntimeDenials ? storedRead : const [],
      filesystemWrite: hasRuntimeDenials ? storedWrite : const [],
      deniedFilesystemRead:
          hasRuntimeDenials ? values('deniedFilesystemRead') : storedRead,
      deniedFilesystemWrite:
          hasRuntimeDenials ? values('deniedFilesystemWrite') : storedWrite,
      androidIntents: values('androidIntents'),
      androidPermissions: values('androidPermissions'),
      secretNames: values('secretNames'),
      runtimes: values('runtimes'),
      subprocessRequired: subprocessRequired,
      riskTier: _requiredString(
        json,
        'riskTier',
        'capability snapshot',
        max: 16,
      ),
      updatePolicy: _requiredString(
        json,
        'updatePolicy',
        'capability snapshot',
        max: 24,
      ),
    );
  }

  Map<String, dynamic> toJson() => {
        'tools': tools,
        'commands': commands,
        'networkDomains': networkDomains,
        'filesystemRead': filesystemRead,
        'filesystemWrite': filesystemWrite,
        'deniedFilesystemRead': deniedFilesystemRead,
        'deniedFilesystemWrite': deniedFilesystemWrite,
        'androidIntents': androidIntents,
        'androidPermissions': androidPermissions,
        'secretNames': secretNames,
        'runtimes': runtimes,
        'subprocessRequired': subprocessRequired,
        'riskTier': riskTier,
        'updatePolicy': updatePolicy,
      };

  String get computedRiskTier {
    if (subprocessRequired ||
        commands.isNotEmpty ||
        filesystemWrite.isNotEmpty ||
        deniedFilesystemWrite.isNotEmpty ||
        secretNames.isNotEmpty ||
        androidIntents.isNotEmpty ||
        androidPermissions.isNotEmpty ||
        tools.any((tool) =>
            tool == 'bash' ||
            tool == 'write_file' ||
            tool == 'set_env_var' ||
            tool == 'phone_intent' ||
            tool.startsWith('mcp_'))) {
      return 'critical';
    }
    if (networkDomains.isNotEmpty ||
        tools.any((tool) =>
            tool == 'web_fetch' ||
            tool == 'web_search' ||
            tool == 'generate_image')) {
      return 'high';
    }
    if (filesystemRead.isNotEmpty ||
        deniedFilesystemRead.isNotEmpty ||
        tools.isNotEmpty) {
      return 'moderate';
    }
    return 'low';
  }

  String get effectiveRiskTier {
    if (riskTier == 'unknown') return 'critical';
    return _riskRank(riskTier) >= _riskRank(computedRiskTier)
        ? riskTier
        : computedRiskTier;
  }

  List<String> get summaryLines {
    final lines = <String>[
      'Declared risk: $riskTier',
      'Computed risk floor: $computedRiskTier',
      'Effective risk: $effectiveRiskTier',
      'Updates: $updatePolicy',
    ];
    void add(String label, List<String> values) {
      if (values.isNotEmpty) lines.add('$label: ${values.join(', ')}');
    }

    add('Tools', tools);
    add('Commands', commands);
    add('Network', networkDomains);
    add('Filesystem read granted', filesystemRead);
    add('Filesystem write granted', filesystemWrite);
    add(
      'Filesystem read unsupported/denied on Android',
      deniedFilesystemRead,
    );
    add(
      'Filesystem write unsupported/denied on Android',
      deniedFilesystemWrite,
    );
    add('Android intents', androidIntents);
    add('Android permissions', androidPermissions);
    add('Secret names', secretNames);
    if (subprocessRequired) {
      lines.add(
        runtimes.isEmpty
            ? 'Subprocess/runtime: required (undeclared runtime)'
            : 'Subprocess/runtime: ${runtimes.join(', ')}',
      );
    }
    return lines;
  }

  CapabilityDiff diff(ExtensionCapabilitySnapshot previous) {
    final added = <String>[];
    final removed = <String>[];
    void compare(String label, List<String> before, List<String> after) {
      added.addAll(after.toSet().difference(before.toSet()).map(
            (value) => '$label: $value',
          ));
      removed.addAll(before.toSet().difference(after.toSet()).map(
            (value) => '$label: $value',
          ));
    }

    compare('Tool', previous.tools, tools);
    compare('Command', previous.commands, commands);
    compare('Network', previous.networkDomains, networkDomains);
    compare(
      'Filesystem read grant',
      previous.filesystemRead,
      filesystemRead,
    );
    compare(
      'Filesystem write grant',
      previous.filesystemWrite,
      filesystemWrite,
    );
    compare(
      'Filesystem read denied',
      previous.deniedFilesystemRead,
      deniedFilesystemRead,
    );
    compare(
      'Filesystem write denied',
      previous.deniedFilesystemWrite,
      deniedFilesystemWrite,
    );
    compare('Android intent', previous.androidIntents, androidIntents);
    compare(
      'Android permission',
      previous.androidPermissions,
      androidPermissions,
    );
    compare('Secret name', previous.secretNames, secretNames);
    compare('Runtime', previous.runtimes, runtimes);
    if (subprocessRequired != previous.subprocessRequired) {
      (subprocessRequired ? added : removed).add('Subprocess required');
    }
    if (riskTier != previous.riskTier) {
      removed.add('Declared risk: ${previous.riskTier}');
      added.add('Declared risk: $riskTier');
    }
    if (effectiveRiskTier != previous.effectiveRiskTier) {
      removed.add('Effective risk: ${previous.effectiveRiskTier}');
      added.add('Effective risk: $effectiveRiskTier');
    }
    if (updatePolicy != previous.updatePolicy) {
      removed.add('Update policy: ${previous.updatePolicy}');
      added.add('Update policy: $updatePolicy');
    }
    added.sort();
    removed.sort();
    return CapabilityDiff(added: added, removed: removed);
  }

  bool get hasUnsupportedFilesystemCapabilities =>
      deniedFilesystemRead.isNotEmpty || deniedFilesystemWrite.isNotEmpty;
}

int _riskRank(String risk) => switch (risk) {
      'low' => 0,
      'moderate' => 1,
      'high' => 2,
      'critical' || 'unknown' => 3,
      _ => 3,
    };

class CapabilityDiff {
  final List<String> added;
  final List<String> removed;

  const CapabilityDiff({required this.added, required this.removed});

  bool get isEmpty => added.isEmpty && removed.isEmpty;
}

enum IntegrityStatus {
  notProvided,
  verifiedDigest,
  signatureUnverified,
  digestVerifiedSignatureUnverified,
  mismatch,
  unsupported,
}

final _extensionId = RegExp(
  r'^[a-z0-9](?:[a-z0-9._-]{0,126}[a-z0-9])?$',
);
final _semanticVersion = RegExp(
  r'^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$',
);
final _sha256 = RegExp(r'^[a-f0-9]{64}$');
final _capabilityName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$');
final _commandName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$');
final _secretName = RegExp(r'^[A-Z][A-Z0-9_]{0,127}$');
final _androidName = RegExp(r'^[A-Za-z][A-Za-z0-9_.-]{0,255}$');
final _domain = RegExp(
  r'^(?:\*\.)?(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$',
);

void _rejectUnknown(
  Map<String, dynamic> json,
  Set<String> allowed,
  String context,
) {
  final unknown = json.keys.where((key) => !allowed.contains(key)).toList()
    ..sort();
  if (unknown.isNotEmpty) {
    throw FormatException(
      'Unknown $context field(s): ${unknown.join(', ')}.',
    );
  }
}

Map<String, dynamic> _requiredMap(
  Map<String, dynamic> json,
  String key,
  String context,
) {
  final value = json[key];
  if (value is! Map) {
    throw FormatException('$context.$key must be an object.');
  }
  return Map<String, dynamic>.from(value);
}

int _requiredInt(Map<String, dynamic> json, String key, String context) {
  final value = json[key];
  if (value is! int) throw FormatException('$context.$key must be an integer.');
  return value;
}

String _requiredString(
  Map<String, dynamic> json,
  String key,
  String context, {
  required int max,
}) {
  final value = json[key];
  if (value is! String) {
    throw FormatException('$context.$key must be a string.');
  }
  final normalized = value.trim();
  if (normalized.isEmpty ||
      normalized.length > max ||
      _hasControl(normalized)) {
    throw FormatException('$context.$key is empty, too long, or unsafe.');
  }
  return normalized;
}

String? _optionalString(
  Map<String, dynamic> json,
  String key,
  String context, {
  required int max,
}) {
  if (!json.containsKey(key) || json[key] == null) return null;
  return _requiredString(json, key, context, max: max);
}

List<String> _stringList(
  Map<String, dynamic> json,
  String key,
  String context, {
  int maxItems = 64,
}) {
  final value = json[key];
  if (value is! List || value.length > maxItems) {
    throw FormatException('$context.$key must be a bounded list.');
  }
  final result = <String>[];
  for (final item in value) {
    if (item is! String || item.trim().isEmpty || item.length > 2048) {
      throw FormatException('$context.$key contains an invalid value.');
    }
    result.add(item.trim());
  }
  return result;
}

List<String> _normalizedNames(
  Map<String, dynamic> json,
  String key,
  String context,
  RegExp pattern, {
  bool uppercase = false,
}) {
  final values = _stringList(json, key, context);
  final normalized = values
      .map((value) {
        final item = uppercase ? value.toUpperCase() : value;
        if (!pattern.hasMatch(item)) {
          throw FormatException('$context.$key contains an invalid value.');
        }
        return item;
      })
      .toSet()
      .toList()
    ..sort();
  if (normalized.length != values.length) {
    throw FormatException('$context.$key contains duplicate values.');
  }
  return normalized;
}

List<String> _normalizedDomains(Map<String, dynamic> json, String key) {
  final values = _stringList(json, key, 'capabilities');
  final normalized = values
      .map((value) {
        var domain = value.toLowerCase();
        if (domain.endsWith('.')) {
          domain = domain.substring(0, domain.length - 1);
        }
        if (!_domain.hasMatch(domain)) {
          throw const FormatException(
            'capabilities.networkDomains contains an invalid domain.',
          );
        }
        return domain;
      })
      .toSet()
      .toList()
    ..sort();
  if (normalized.length != values.length) {
    throw const FormatException(
      'capabilities.networkDomains contains duplicate values.',
    );
  }
  return normalized;
}

List<String> _normalizedPaths(
  Map<String, dynamic> json,
  String key,
  String context,
) {
  final values = _stringList(json, key, context);
  final normalized = values
      .map((value) {
        if (!value.startsWith('/') || value.contains('\\')) {
          throw FormatException(
              '$context.$key must contain absolute POSIX paths.');
        }
        final segments = <String>[];
        for (final segment in value.split('/')) {
          if (segment.isEmpty || segment == '.') continue;
          if (segment == '..' || _hasControl(segment)) {
            throw FormatException('$context.$key contains an unsafe path.');
          }
          segments.add(segment);
        }
        return segments.isEmpty ? '/' : '/${segments.join('/')}';
      })
      .toSet()
      .toList()
    ..sort();
  if (normalized.length != values.length) {
    throw FormatException('$context.$key contains duplicate paths.');
  }
  return normalized;
}

bool _hasControl(String value) =>
    value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f);

String _canonicalJson(dynamic value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return '{${keys.map((key) => '${jsonEncode(key)}:${_canonicalJson(value[key])}').join(',')}}';
  }
  if (value is List) {
    return '[${value.map(_canonicalJson).join(',')}]';
  }
  return jsonEncode(value);
}
