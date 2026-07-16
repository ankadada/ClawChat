import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/extension_manifest.dart';

/// Narrow, app-owned compatibility grants for published legacy packages.
///
/// A match never executes package code. It only replaces an otherwise empty
/// legacy capability snapshot with a fixed typed-tool grant. Valid skill.json
/// manifests remain authoritative and bypass this compatibility layer.
final class LegacySkillCompatibility {
  const LegacySkillCompatibility._();

  static const unsupportedReason = '需要兼容升级：此 Skill 缺少受支持的权限清单。'
      '请通过 xd-skill 更新后重新授权。';

  static const xdsSkillId = 'legacy.xds-skills';
  static const xdsSkillName = 'xds-skills';
  static const xdsSkillVersion = '0.1.9';
  static const xdsSkillRoot = '/root/workspace/.agents/skills/xds-skills';
  static const xdsSkillContentSha256 =
      '9e75dd62ead4b8fde4eb9e41063a73c4997fa6c588af4c8550ca5ae1138eefd9';
  /// Published archive fingerprint retained for review/provenance. The
  /// runtime match uses the installed SKILL.md fingerprint because the CLI
  /// archive is not present after extraction.
  static const xdsArchiveSha256 =
      '6dcecd03fd3fb30efdac4048780ed900d7dd8e111fcac88ad26f98e0efe7bc18';
  static const xdsToolName = 'xds_agent';
  static const xdsDomain = 'ai-xds.tapdb.net';
  static const xdsTokenName = 'XDS_AGENT_TOKEN';

  static const xdsCapabilities = ExtensionCapabilitySnapshot(
    tools: [xdsToolName],
    commands: [],
    networkDomains: [xdsDomain],
    filesystemRead: [],
    filesystemWrite: [],
    deniedFilesystemRead: [],
    deniedFilesystemWrite: [],
    androidIntents: [],
    androidPermissions: [],
    secretNames: [xdsTokenName],
    runtimes: [],
    subprocessRequired: false,
    riskTier: 'critical',
    updatePolicy: 'disabled',
  );

  static LegacySkillCompatibilityGrant? resolve({
    required String stagingPath,
    required String id,
    required String name,
    required String contentDigest,
  }) {
    if (stagingPath != xdsSkillRoot ||
        id != xdsSkillId ||
        name != xdsSkillName ||
        contentDigest != xdsSkillContentSha256) {
      return null;
    }
    return LegacySkillCompatibilityGrant(
      version: xdsSkillVersion,
      capabilities: xdsCapabilities,
      manifestDigest: _xdsManifestDigest,
    );
  }

  static bool isSupported({
    required String stagingPath,
    required String id,
    required String name,
    required String version,
    required String contentDigest,
    required ExtensionCapabilitySnapshot capabilities,
  }) {
    final match = resolve(
      stagingPath: stagingPath,
      id: id,
      name: name,
      contentDigest: contentDigest,
    );
    return match != null &&
        version == match.version &&
        _sameCapabilities(capabilities, match.capabilities);
  }

  static String get _xdsManifestDigest => sha256
      .convert(utf8.encode(jsonEncode({
        'schemaVersion': 1,
        'kind': 'app_owned_legacy_compatibility',
        'id': xdsSkillId,
        'name': xdsSkillName,
        'version': xdsSkillVersion,
        'skillContentSha256': xdsSkillContentSha256,
        'archiveSha256': xdsArchiveSha256,
        'capabilities': xdsCapabilities.toJson(),
      })))
      .toString();

  static bool _sameCapabilities(
    ExtensionCapabilitySnapshot left,
    ExtensionCapabilitySnapshot right,
  ) =>
      jsonEncode(left.toJson()) == jsonEncode(right.toJson());
}

final class LegacySkillCompatibilityGrant {
  const LegacySkillCompatibilityGrant({
    required this.version,
    required this.capabilities,
    required this.manifestDigest,
  });

  final String version;
  final ExtensionCapabilitySnapshot capabilities;
  final String manifestDigest;
}
