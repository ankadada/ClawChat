import 'package:clawchat/services/bundled_legacy_skill_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ships six bundled presets with unique asset identities', () {
    const entries = BundledLegacySkillCatalog.entries;

    expect(entries, hasLength(6));
    expect(
      entries.map((entry) => entry.legacyStableId).toList(),
      const [
        'legacy.file-manager',
        'legacy.gws-calendar',
        'legacy.gws-drive',
        'legacy.gws-gmail',
        'legacy.system-info',
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

  test('shipped presets are bounded, installable, reasoned, and consent-gated',
      () {
    for (final entry in BundledLegacySkillCatalog.entries) {
      expect(entry.isInstallable, isTrue);
      expect(entry.isBlocked, isFalse);
      expect(entry.reason, isNotEmpty);
      expect(
        entry.reason.length,
        lessThanOrEqualTo(BundledLegacySkillCatalog.maxUserVisibleReasonLength),
      );
      expect(entry.inventoryDisposition, 'disabled');
    }
  });

  test('the three Google presets carry the Google API token copy', () {
    for (final directory
        in BundledLegacySkillCatalog.googleApiPresetDirectories) {
      final entry = BundledLegacySkillCatalog.entryForIdentity(name: directory);
      expect(entry, isNull, reason: '$directory is consent-gated, not blocked');
      final shipped = BundledLegacySkillCatalog.entries
          .firstWhere((item) => item.assetDirectory == directory);
      expect(shipped.reason, contains('GOOGLE_ACCESS_TOKEN'));
      expect(shipped.reason, contains('No in-app OAuth'));
    }
  });

  test('left-over presets stay blocked and are not installable', () {
    const removed = BundledLegacySkillCatalog.removedEntries;
    expect(removed, hasLength(3));
    for (final entry in removed) {
      expect(entry.isInstallable, isFalse);
      expect(entry.isBlocked, isTrue);
      expect(entry.inventoryDisposition, 'removed');
      expect(
        entry.reason.length,
        lessThanOrEqualTo(BundledLegacySkillCatalog.maxUserVisibleReasonLength),
      );
    }
  });

  test('reserves removed stable IDs and legacy name aliases without prefixing',
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
    for (final entry in BundledLegacySkillCatalog.entries) {
      expect(
        BundledLegacySkillCatalog.entryForInstalledSkill(
          id: entry.legacyStableId,
          name: entry.assetDirectory,
          legacy: true,
        ),
        isNull,
        reason: 'shipped preset ${entry.assetDirectory} is consent-gated',
      );
    }
  });
}
