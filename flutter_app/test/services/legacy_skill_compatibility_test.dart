import 'package:clawchat/models/extension_manifest.dart';
import 'package:clawchat/services/legacy_skill_compatibility.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('XDS constants describe the typed adapter without granting it', () {
    expect(LegacySkillCompatibility.xdsToolName, 'xds_agent');
    expect(LegacySkillCompatibility.xdsDomain, 'ai-xds.tapdb.net');
    expect(LegacySkillCompatibility.xdsTokenName, 'XDS_AGENT_TOKEN');
  });

  test('legacy compatibility has no implicit capability grant', () {
    final legacy = ExtensionCapabilitySnapshot.legacy();
    expect(legacy.tools, isEmpty);
    expect(legacy.networkDomains, isEmpty);
    expect(legacy.secretNames, isEmpty);
  });
}
