import 'package:clawchat/services/bundled_legacy_skill_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('has the exact nine legacy stable IDs and unique asset identities', () {
    const entries = BundledLegacySkillCatalog.entries;

    expect(entries, hasLength(9));
    expect(
      entries.map((entry) => entry.legacyStableId).toList(),
      const [
        'legacy.code-review',
        'legacy.file-manager',
        'legacy.github',
        'legacy.gws-calendar',
        'legacy.gws-drive',
        'legacy.gws-gmail',
        'legacy.system-info',
        'legacy.translator',
        'legacy.web-search',
      ],
    );
    expect(
      entries.map((entry) => entry.assetDirectory).toSet(),
      hasLength(entries.length),
    );
    expect(
      entries.map((entry) => entry.legacyStableId).toSet(),
      hasLength(entries.length),
    );
  });

  test('all current entries are bounded, unavailable, and reasoned', () {
    for (final entry in BundledLegacySkillCatalog.entries) {
      expect(entry.isInstallable, isFalse);
      expect(entry.reason, isNotEmpty);
      expect(
        entry.reason.length,
        lessThanOrEqualTo(BundledLegacySkillCatalog.maxUserVisibleReasonLength),
      );
      expect(entry.inventoryDisposition, 'disabled');
    }
  });

  test('reserves stable IDs and legacy name aliases without prefix matching',
      () {
    expect(
      BundledLegacySkillCatalog.entryForInstalledSkill(
        id: 'legacy.github',
        name: 'github',
        legacy: true,
      )?.reason,
      BundledLegacySkillCatalog.legacyUnavailableReason,
    );
    expect(
      BundledLegacySkillCatalog.entryForInstalledSkill(
        id: 'legacy.github-helper',
        name: 'github-helper',
        legacy: true,
      ),
      isNull,
    );
    expect(
      BundledLegacySkillCatalog.entryForInstalledSkill(
        id: 'com.example.github',
        name: 'github',
        legacy: false,
      ),
      isNull,
    );
    expect(
      BundledLegacySkillCatalog.entryForInstalledSkill(
        id: 'com.example.renamed',
        name: 'renamed',
        legacy: false,
        installedAssetDirectory: 'github',
      )?.legacyStableId,
      'legacy.github',
    );
  });
}
