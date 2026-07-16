import 'package:clawchat/models/extension_manifest.dart';
import 'package:clawchat/services/legacy_skill_compatibility.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only the published XDS identity, path, and content digest match', () {
    final match = LegacySkillCompatibility.resolve(
      stagingPath: LegacySkillCompatibility.xdsSkillRoot,
      id: LegacySkillCompatibility.xdsSkillId,
      name: LegacySkillCompatibility.xdsSkillName,
      contentDigest: LegacySkillCompatibility.xdsSkillContentSha256,
    );
    expect(match, isNotNull);
    expect(match!.version, '0.1.9');
    expect(match.capabilities.tools, [LegacySkillCompatibility.xdsToolName]);
    expect(match.capabilities.commands, isEmpty);
    expect(match.capabilities.secretNames, [
      LegacySkillCompatibility.xdsTokenName,
    ]);

    expect(
      LegacySkillCompatibility.resolve(
        stagingPath: '/root/workspace/skills/xds-skills',
        id: LegacySkillCompatibility.xdsSkillId,
        name: LegacySkillCompatibility.xdsSkillName,
        contentDigest: LegacySkillCompatibility.xdsSkillContentSha256,
      ),
      isNull,
    );
    expect(
      LegacySkillCompatibility.resolve(
        stagingPath: LegacySkillCompatibility.xdsSkillRoot,
        id: 'legacy.other',
        name: LegacySkillCompatibility.xdsSkillName,
        contentDigest: LegacySkillCompatibility.xdsSkillContentSha256,
      ),
      isNull,
    );
    expect(
      LegacySkillCompatibility.resolve(
        stagingPath: LegacySkillCompatibility.xdsSkillRoot,
        id: LegacySkillCompatibility.xdsSkillId,
        name: LegacySkillCompatibility.xdsSkillName,
        contentDigest: List.filled(64, '0').join(),
      ),
      isNull,
    );
  });

  test('compatibility capabilities cannot be replaced by bash or Python', () {
    expect(
      LegacySkillCompatibility.isSupported(
        stagingPath: LegacySkillCompatibility.xdsSkillRoot,
        id: LegacySkillCompatibility.xdsSkillId,
        name: LegacySkillCompatibility.xdsSkillName,
        version: LegacySkillCompatibility.xdsSkillVersion,
        contentDigest: LegacySkillCompatibility.xdsSkillContentSha256,
        capabilities: LegacySkillCompatibility.xdsCapabilities,
      ),
      isTrue,
    );
    expect(
      LegacySkillCompatibility.isSupported(
        stagingPath: LegacySkillCompatibility.xdsSkillRoot,
        id: LegacySkillCompatibility.xdsSkillId,
        name: LegacySkillCompatibility.xdsSkillName,
        version: LegacySkillCompatibility.xdsSkillVersion,
        contentDigest: LegacySkillCompatibility.xdsSkillContentSha256,
        capabilities: const ExtensionCapabilitySnapshot(
          tools: ['bash'],
          commands: ['python3'],
          networkDomains: [],
          filesystemRead: [],
          filesystemWrite: [],
          androidIntents: [],
          androidPermissions: [],
          secretNames: [],
          runtimes: ['python3'],
          subprocessRequired: true,
          riskTier: 'critical',
          updatePolicy: 'disabled',
        ),
      ),
      isFalse,
    );
  });
}
