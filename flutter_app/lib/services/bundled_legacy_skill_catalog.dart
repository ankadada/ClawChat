/// App-owned runtime disposition for the legacy skills shipped in assets.
///
/// This deliberately contains metadata only. It neither reads assets nor
/// grants authority; callers use it to fail closed before a legacy preset can
/// become available through preferences, trust records, or a constructed UI
/// model.
enum BundledLegacySkillDisposition { disabled, removed }

final class BundledLegacySkillCatalogEntry {
  const BundledLegacySkillCatalogEntry({
    required this.assetDirectory,
    required this.legacyStableId,
    required this.disposition,
    required this.reason,
  });

  final String assetDirectory;
  final String legacyStableId;
  final BundledLegacySkillDisposition disposition;
  final String reason;

  /// Inventory uses snake-case strings while the app keeps a typed runtime
  /// disposition. Keeping the conversion here avoids a second nine-entry map.
  String get inventoryDisposition => switch (disposition) {
        BundledLegacySkillDisposition.disabled => 'disabled',
        BundledLegacySkillDisposition.removed => 'removed',
      };

  bool get isInstallable => switch (disposition) {
        BundledLegacySkillDisposition.disabled => false,
        BundledLegacySkillDisposition.removed => false,
      };

  bool matchesIdentity({String? id, String? name}) =>
      id == legacyStableId || name == assetDirectory;
}

abstract final class BundledLegacySkillCatalog {
  static const maxUserVisibleReasonLength = 160;
  static const legacyUnavailableReason =
      'Legacy preset requires runtime policy remediation before availability.';

  static const entries = <BundledLegacySkillCatalogEntry>[
    BundledLegacySkillCatalogEntry(
      assetDirectory: 'code-review',
      legacyStableId: 'legacy.code-review',
      disposition: BundledLegacySkillDisposition.disabled,
      reason: legacyUnavailableReason,
    ),
    BundledLegacySkillCatalogEntry(
      assetDirectory: 'file-manager',
      legacyStableId: 'legacy.file-manager',
      disposition: BundledLegacySkillDisposition.disabled,
      reason: legacyUnavailableReason,
    ),
    BundledLegacySkillCatalogEntry(
      assetDirectory: 'github',
      legacyStableId: 'legacy.github',
      disposition: BundledLegacySkillDisposition.disabled,
      reason: legacyUnavailableReason,
    ),
    BundledLegacySkillCatalogEntry(
      assetDirectory: 'gws-calendar',
      legacyStableId: 'legacy.gws-calendar',
      disposition: BundledLegacySkillDisposition.disabled,
      reason: legacyUnavailableReason,
    ),
    BundledLegacySkillCatalogEntry(
      assetDirectory: 'gws-drive',
      legacyStableId: 'legacy.gws-drive',
      disposition: BundledLegacySkillDisposition.disabled,
      reason: legacyUnavailableReason,
    ),
    BundledLegacySkillCatalogEntry(
      assetDirectory: 'gws-gmail',
      legacyStableId: 'legacy.gws-gmail',
      disposition: BundledLegacySkillDisposition.disabled,
      reason: legacyUnavailableReason,
    ),
    BundledLegacySkillCatalogEntry(
      assetDirectory: 'system-info',
      legacyStableId: 'legacy.system-info',
      disposition: BundledLegacySkillDisposition.disabled,
      reason: legacyUnavailableReason,
    ),
    BundledLegacySkillCatalogEntry(
      assetDirectory: 'translator',
      legacyStableId: 'legacy.translator',
      disposition: BundledLegacySkillDisposition.disabled,
      reason: legacyUnavailableReason,
    ),
    BundledLegacySkillCatalogEntry(
      assetDirectory: 'web-search',
      legacyStableId: 'legacy.web-search',
      disposition: BundledLegacySkillDisposition.disabled,
      reason: legacyUnavailableReason,
    ),
  ];

  static BundledLegacySkillCatalogEntry? entryForIdentity({
    String? id,
    String? name,
  }) {
    for (final entry in entries) {
      if (entry.matchesIdentity(id: id, name: name)) return entry;
    }
    return null;
  }

  /// A scanned or constructed skill can share an asset-directory display name
  /// without being a bundled legacy preset. Stable legacy IDs are always
  /// reserved; name matching is reserved for legacy packages only.
  static BundledLegacySkillCatalogEntry? entryForInstalledSkill({
    required String id,
    required String name,
    required bool legacy,
    String? installedAssetDirectory,
  }) {
    if (installedAssetDirectory != null) {
      final byDirectory = entryForIdentity(name: installedAssetDirectory);
      if (byDirectory != null) return byDirectory;
    }
    final byId = entryForIdentity(id: id);
    if (byId != null) return byId;
    return legacy ? entryForIdentity(name: name) : null;
  }
}
