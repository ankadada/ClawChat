/// App-owned runtime disposition for the presets shipped in `assets/skills`.
///
/// This deliberately contains metadata only. It neither reads assets nor
/// grants authority; callers use it to fail closed before a preset can become
/// available through preferences, trust records, or a constructed UI model.
///
/// I4 disposition (plan §9):
/// - `bundled` presets are shipped in the APK. They are installed **disabled**
///   and the existing legacy skill consent grant is the only unlock.
/// - `removed` presets are no longer part of the app bundle. A leftover
///   installed copy stays blocked.
enum BundledLegacySkillDisposition { bundled, removed }

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

  /// The host skill-eval inventory is the source of truth for the shipped
  /// asset set. This conversion keeps the typed runtime disposition aligned
  /// with the inventory's snake-case enum names.
  String get inventoryDisposition => switch (disposition) {
        BundledLegacySkillDisposition.bundled => 'disabled',
        BundledLegacySkillDisposition.removed => 'removed',
      };

  /// Shipped presets are installed disabled; the legacy consent grant, not
  /// this catalog, decides whether they can be enabled.
  bool get isInstallable =>
      disposition == BundledLegacySkillDisposition.bundled;

  /// Removed presets are the only identities this catalog blocks outright.
  bool get isBlocked => disposition == BundledLegacySkillDisposition.removed;

  bool matchesIdentity({String? id, String? name}) =>
      id == legacyStableId || name == assetDirectory;
}

abstract final class BundledLegacySkillCatalog {
  static const maxUserVisibleReasonLength = 160;

  static const legacyUnavailableReason =
      'No longer bundled as an in-app skill; available only as a workspace example.';

  static const googleApiPresetReason =
      'Google API preset. No in-app OAuth; supply your own GOOGLE_ACCESS_TOKEN. '
      'Disabled until legacy skill consent.';

  static const workspacePresetReason =
      'Local workspace skill. Disabled until legacy skill consent.';

  /// Shipped in the APK. Installed disabled; only the legacy consent grant
  /// unlocks them. This list must stay identical to the host skill-eval
  /// inventory's asset set.
  static const entries = <BundledLegacySkillCatalogEntry>[
    BundledLegacySkillCatalogEntry(
      assetDirectory: 'file-manager',
      legacyStableId: 'legacy.file-manager',
      disposition: BundledLegacySkillDisposition.bundled,
      reason: workspacePresetReason,
    ),
    BundledLegacySkillCatalogEntry(
      assetDirectory: 'gws-calendar',
      legacyStableId: 'legacy.gws-calendar',
      disposition: BundledLegacySkillDisposition.bundled,
      reason: googleApiPresetReason,
    ),
    BundledLegacySkillCatalogEntry(
      assetDirectory: 'gws-drive',
      legacyStableId: 'legacy.gws-drive',
      disposition: BundledLegacySkillDisposition.bundled,
      reason: googleApiPresetReason,
    ),
    BundledLegacySkillCatalogEntry(
      assetDirectory: 'gws-gmail',
      legacyStableId: 'legacy.gws-gmail',
      disposition: BundledLegacySkillDisposition.bundled,
      reason: googleApiPresetReason,
    ),
    BundledLegacySkillCatalogEntry(
      assetDirectory: 'system-info',
      legacyStableId: 'legacy.system-info',
      disposition: BundledLegacySkillDisposition.bundled,
      reason: workspacePresetReason,
    ),
    BundledLegacySkillCatalogEntry(
      assetDirectory: 'web-search',
      legacyStableId: 'legacy.web-search',
      disposition: BundledLegacySkillDisposition.bundled,
      reason: workspacePresetReason,
    ),
  ];

  /// Left-over identities from presets that left the app bundle. They are not
  /// shipped and not installable; a leftover installed copy stays blocked.
  static const removedEntries = <BundledLegacySkillCatalogEntry>[
    BundledLegacySkillCatalogEntry(
      assetDirectory: 'code-review',
      legacyStableId: 'legacy.code-review',
      disposition: BundledLegacySkillDisposition.removed,
      reason: legacyUnavailableReason,
    ),
    BundledLegacySkillCatalogEntry(
      assetDirectory: 'github',
      legacyStableId: 'legacy.github',
      disposition: BundledLegacySkillDisposition.removed,
      reason: legacyUnavailableReason,
    ),
    BundledLegacySkillCatalogEntry(
      assetDirectory: 'translator',
      legacyStableId: 'legacy.translator',
      disposition: BundledLegacySkillDisposition.removed,
      reason: legacyUnavailableReason,
    ),
  ];

  /// Google API presets need the user's own token; settings copy for them
  /// must say Google API, no in-app OAuth, and a user-supplied token.
  static const googleApiPresetDirectories = <String>{
    'gws-calendar',
    'gws-drive',
    'gws-gmail',
  };

  static BundledLegacySkillCatalogEntry? entryForIdentity({
    String? id,
    String? name,
  }) {
    for (final entry in removedEntries) {
      if (!entry.isBlocked) continue;
      if (entry.matchesIdentity(id: id, name: name)) return entry;
    }
    return null;
  }

  /// A scanned or constructed skill can share an asset-directory display name
  /// without being a bundled preset. Only removed identities stay reserved;
  /// shipped presets are consent-gated by the normal legacy grant path.
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
