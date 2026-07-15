import 'dart:io';

import 'package:clawchat/models/extension_manifest.dart';
import 'package:clawchat/services/strict_json_decoder.dart';

import 'bounded_file_reader.dart';

const int _maxInventoryBytes = 64 * 1024;
const int _maxEnabledManifestBytes = 256 * 1024;
const int _maxSkillMarkdownBytes = 1024 * 1024;
const String _expectedAssetRoot = 'assets/skills';

enum BundledSkillDisposition {
  manifestV1Enabled,
  disabled,
  removed,
}

enum BundledSkillPlanningStatus {
  readyForRelease,
  pendingRuntimeRemediation,
}

enum SkillEvalReasonCode {
  assetRootMissing,
  unsafeAssetRoot,
  unsafeInventoryFile,
  unsafeAssetEntry,
  unsafeFixtureRoot,
  unsafeFixtureEntry,
  emptyCorpus,
  inventoryDecoderError,
  inventorySchemaError,
  inventoryDuplicateEntry,
  runtimeCatalogMismatch,
  runtimeEvidenceInvalid,
  runtimeImportContractMismatch,
  runtimePolicyContractMismatch,
  assetMissingSkillMarkdown,
  inventoryMissingAssetEntry,
  inventoryExtraAssetEntry,
  skillMarkdownDigestMismatch,
  enabledSkillJsonMissing,
  enabledSkillJsonDigestMismatch,
  enabledSkillJsonDecoderError,
  enabledSkillJsonManifestInvalid,
  enabledSkillJsonIntegrityInvalid,
  fixtureMissingAsset,
  fixtureExtraAsset,
  fixtureAssetMismatch,
  corpusRootMissing,
  corpusRootUnsafe,
  corpusInventoryPathMismatch,
  corpusInventoryUnsafe,
  corpusPathMissing,
  corpusUnsafeEntry,
  schemaDigestMismatch,
  schemaInvalid,
  caseInvalid,
  caseDuplicateId,
  caseUnknownFixture,
  fixtureUnreferenced,
  fixtureCoverageMissing,
  goldenMissing,
  goldenExtra,
  goldenInvalid,
  goldenMismatch,
  caseExpectationMismatch,
  staticScanMismatch,
  enabledStaticScanRejected,
  enabledClaimToolUndeclared,
  enabledClaimUnenforceable,
  releaseBlockerRuntimeEvidenceMissing,
  releaseBlockerPendingRuntimeRemediation,
}

extension on SkillEvalReasonCode {
  String get code => switch (this) {
        SkillEvalReasonCode.assetRootMissing => 'asset_root_missing',
        SkillEvalReasonCode.unsafeAssetRoot => 'unsafe_asset_root',
        SkillEvalReasonCode.unsafeInventoryFile => 'unsafe_inventory_file',
        SkillEvalReasonCode.unsafeAssetEntry => 'unsafe_asset_entry',
        SkillEvalReasonCode.unsafeFixtureRoot => 'unsafe_fixture_root',
        SkillEvalReasonCode.unsafeFixtureEntry => 'unsafe_fixture_entry',
        SkillEvalReasonCode.emptyCorpus => 'empty_corpus',
        SkillEvalReasonCode.inventoryDecoderError => 'inventory_decoder_error',
        SkillEvalReasonCode.inventorySchemaError => 'inventory_schema_error',
        SkillEvalReasonCode.inventoryDuplicateEntry =>
          'inventory_duplicate_entry',
        SkillEvalReasonCode.runtimeCatalogMismatch =>
          'runtime_catalog_mismatch',
        SkillEvalReasonCode.runtimeEvidenceInvalid =>
          'runtime_evidence_invalid',
        SkillEvalReasonCode.runtimeImportContractMismatch =>
          'runtime_import_contract_mismatch',
        SkillEvalReasonCode.runtimePolicyContractMismatch =>
          'runtime_policy_contract_mismatch',
        SkillEvalReasonCode.assetMissingSkillMarkdown =>
          'asset_missing_skill_md',
        SkillEvalReasonCode.inventoryMissingAssetEntry =>
          'inventory_missing_asset_entry',
        SkillEvalReasonCode.inventoryExtraAssetEntry =>
          'inventory_extra_asset_entry',
        SkillEvalReasonCode.skillMarkdownDigestMismatch =>
          'skill_md_digest_mismatch',
        SkillEvalReasonCode.enabledSkillJsonMissing =>
          'enabled_skill_json_missing',
        SkillEvalReasonCode.enabledSkillJsonDigestMismatch =>
          'enabled_skill_json_digest_mismatch',
        SkillEvalReasonCode.enabledSkillJsonDecoderError =>
          'enabled_skill_json_decoder_error',
        SkillEvalReasonCode.enabledSkillJsonManifestInvalid =>
          'enabled_skill_json_manifest_invalid',
        SkillEvalReasonCode.enabledSkillJsonIntegrityInvalid =>
          'enabled_skill_json_integrity_invalid',
        SkillEvalReasonCode.fixtureMissingAsset => 'fixture_missing_asset',
        SkillEvalReasonCode.fixtureExtraAsset => 'fixture_extra_asset',
        SkillEvalReasonCode.fixtureAssetMismatch => 'fixture_asset_mismatch',
        SkillEvalReasonCode.corpusRootMissing => 'corpus_root_missing',
        SkillEvalReasonCode.corpusRootUnsafe => 'corpus_root_unsafe',
        SkillEvalReasonCode.corpusInventoryPathMismatch =>
          'corpus_inventory_path_mismatch',
        SkillEvalReasonCode.corpusInventoryUnsafe => 'corpus_inventory_unsafe',
        SkillEvalReasonCode.corpusPathMissing => 'corpus_path_missing',
        SkillEvalReasonCode.corpusUnsafeEntry => 'corpus_unsafe_entry',
        SkillEvalReasonCode.schemaDigestMismatch => 'schema_digest_mismatch',
        SkillEvalReasonCode.schemaInvalid => 'schema_invalid',
        SkillEvalReasonCode.caseInvalid => 'case_invalid',
        SkillEvalReasonCode.caseDuplicateId => 'case_duplicate_id',
        SkillEvalReasonCode.caseUnknownFixture => 'case_unknown_fixture',
        SkillEvalReasonCode.fixtureUnreferenced => 'fixture_unreferenced',
        SkillEvalReasonCode.fixtureCoverageMissing =>
          'fixture_coverage_missing',
        SkillEvalReasonCode.goldenMissing => 'golden_missing',
        SkillEvalReasonCode.goldenExtra => 'golden_extra',
        SkillEvalReasonCode.goldenInvalid => 'golden_invalid',
        SkillEvalReasonCode.goldenMismatch => 'golden_mismatch',
        SkillEvalReasonCode.caseExpectationMismatch =>
          'case_expectation_mismatch',
        SkillEvalReasonCode.staticScanMismatch => 'static_scan_mismatch',
        SkillEvalReasonCode.enabledStaticScanRejected =>
          'enabled_static_scan_rejected',
        SkillEvalReasonCode.enabledClaimToolUndeclared =>
          'enabled_claim_tool_undeclared',
        SkillEvalReasonCode.enabledClaimUnenforceable =>
          'enabled_claim_unenforceable',
        SkillEvalReasonCode.releaseBlockerRuntimeEvidenceMissing =>
          'release_blocker_runtime_evidence_missing',
        SkillEvalReasonCode.releaseBlockerPendingRuntimeRemediation =>
          'release_blocker_pending_runtime_remediation',
      };
}

/// Typed, host-owned inventory for the bundled skill corpus.
final class BundledSkillInventory {
  BundledSkillInventory({
    required this.entries,
  });

  final List<BundledSkillInventoryEntry> entries;

  static BundledSkillInventory decodeBytes(List<int> bytes) {
    final decoded = const StrictJsonDecoder(maxUtf8Bytes: _maxInventoryBytes)
        .decodeBytes(bytes);
    if (decoded is! Map<String, Object?>) {
      throw const _InventoryFormatException(
        SkillEvalReasonCode.inventorySchemaError,
      );
    }

    _requireExactKeys(decoded, {'schemaVersion', 'assetRoot', 'entries'});
    if (decoded['schemaVersion'] != 1 ||
        decoded['assetRoot'] != _expectedAssetRoot ||
        decoded['entries'] is! List<Object?>) {
      throw const _InventoryFormatException(
        SkillEvalReasonCode.inventorySchemaError,
      );
    }

    final entryNames = <String>{};
    final entries = <BundledSkillInventoryEntry>[];
    for (final value in decoded['entries']! as List<Object?>) {
      final entry = BundledSkillInventoryEntry.fromJson(value);
      if (!entryNames.add(entry.assetDirectory)) {
        throw const _InventoryFormatException(
          SkillEvalReasonCode.inventoryDuplicateEntry,
        );
      }
      entries.add(entry);
    }
    return BundledSkillInventory(entries: List.unmodifiable(entries));
  }
}

final class BundledSkillInventoryEntry {
  const BundledSkillInventoryEntry({
    required this.assetDirectory,
    required this.skillMarkdownSha256,
    required this.disposition,
    required this.planningStatus,
    this.reason,
    this.skillJsonSha256,
  });

  final String assetDirectory;
  final String skillMarkdownSha256;
  final BundledSkillDisposition disposition;
  final String? reason;
  final BundledSkillPlanningStatus planningStatus;
  final String? skillJsonSha256;

  static BundledSkillInventoryEntry fromJson(Object? value) {
    if (value is! Map<String, Object?>) {
      throw const _InventoryFormatException(
        SkillEvalReasonCode.inventorySchemaError,
      );
    }
    final disposition = _parseDisposition(value['disposition']);
    final expectsSkillJson =
        disposition == BundledSkillDisposition.manifestV1Enabled;
    final expectedKeys = {
      'assetDirectory',
      'skillMarkdownSha256',
      'disposition',
      'planningStatus',
      if (expectsSkillJson) 'skillJsonSha256',
      if (!expectsSkillJson) 'reason',
    };
    _requireExactKeys(value, expectedKeys);

    final assetDirectory = _requireString(value['assetDirectory']);
    final skillMarkdownSha256 = _requireSha256(value['skillMarkdownSha256']);
    final reason =
        expectsSkillJson ? null : _requireBoundedReason(value['reason']);
    final planningStatus = _parsePlanningStatus(value['planningStatus']);
    final skillJsonSha256 =
        expectsSkillJson ? _requireSha256(value['skillJsonSha256']) : null;
    if (!_assetDirectoryPattern.hasMatch(assetDirectory)) {
      throw const _InventoryFormatException(
        SkillEvalReasonCode.inventorySchemaError,
      );
    }
    return BundledSkillInventoryEntry(
      assetDirectory: assetDirectory,
      skillMarkdownSha256: skillMarkdownSha256,
      disposition: disposition,
      reason: reason,
      planningStatus: planningStatus,
      skillJsonSha256: skillJsonSha256,
    );
  }
}

/// Deterministic host runner. It reads only repository files; it never loads
/// imported skills, evaluates instructions, or executes any skill content.
final class SkillEvalRunner {
  const SkillEvalRunner();

  SkillEvalRunResult run({
    required Directory skillAssetsDirectory,
    required File inventoryFile,
    Directory? fixtureSkillsDirectory,
    Set<String> runtimeEvidenceReadyAssetDirectories = const {},
  }) {
    final findings = <SkillEvalFinding>[];
    final assetRootType = _physicalTypeOf(skillAssetsDirectory);
    if (assetRootType != FileSystemEntityType.directory) {
      findings.add(
        SkillEvalFinding(
          assetRootType == FileSystemEntityType.notFound
              ? SkillEvalReasonCode.assetRootMissing
              : SkillEvalReasonCode.unsafeAssetRoot,
        ),
      );
      return SkillEvalRunResult(findings);
    }
    if (!_hasPhysicalType(inventoryFile, FileSystemEntityType.file)) {
      findings.add(
        const SkillEvalFinding(SkillEvalReasonCode.unsafeInventoryFile),
      );
      return SkillEvalRunResult(findings);
    }

    final inventory = _readInventory(inventoryFile, findings);
    if (inventory == null) return SkillEvalRunResult(findings);

    final assetDirectories = _listPhysicalSkillDirectories(
      skillAssetsDirectory,
      findings,
      unsafeEntryReason: SkillEvalReasonCode.unsafeAssetEntry,
    );
    if (assetDirectories.isEmpty && inventory.entries.isEmpty) {
      findings.add(const SkillEvalFinding(SkillEvalReasonCode.emptyCorpus));
    }
    final inventoryByDirectory = {
      for (final entry in inventory.entries) entry.assetDirectory: entry,
    };

    for (final directoryName in assetDirectories) {
      final entry = inventoryByDirectory[directoryName];
      if (entry == null) {
        findings.add(
          const SkillEvalFinding(
            SkillEvalReasonCode.inventoryMissingAssetEntry,
          ),
        );
        continue;
      }
      try {
        _checkAsset(
          Directory(
              '${skillAssetsDirectory.path}${Platform.pathSeparator}$directoryName'),
          entry,
          findings,
        );
      } on BoundedFileReadException {
        findings.add(
          const SkillEvalFinding(SkillEvalReasonCode.inventoryDecoderError),
        );
      }
    }

    for (final entry in inventory.entries) {
      if (!assetDirectories.contains(entry.assetDirectory)) {
        findings.add(
          const SkillEvalFinding(
            SkillEvalReasonCode.inventoryExtraAssetEntry,
          ),
        );
      }
      if (entry.planningStatus ==
          BundledSkillPlanningStatus.pendingRuntimeRemediation) {
        findings.add(
          const SkillEvalFinding(
            SkillEvalReasonCode.releaseBlockerPendingRuntimeRemediation,
            isReleaseBlocking: true,
          ),
        );
      } else {
        if (!runtimeEvidenceReadyAssetDirectories
            .contains(entry.assetDirectory)) {
          findings.add(
            const SkillEvalFinding(
              SkillEvalReasonCode.releaseBlockerRuntimeEvidenceMissing,
              isReleaseBlocking: true,
            ),
          );
        }
      }
    }

    if (fixtureSkillsDirectory != null) {
      try {
        _checkFixtureBytes(
          skillAssetsDirectory,
          fixtureSkillsDirectory,
          assetDirectories,
          findings,
        );
      } on BoundedFileReadException {
        findings.add(
          const SkillEvalFinding(SkillEvalReasonCode.inventoryDecoderError),
        );
      }
    }
    return SkillEvalRunResult(findings);
  }

  BundledSkillInventory? _readInventory(
    File inventoryFile,
    List<SkillEvalFinding> findings,
  ) {
    try {
      return BundledSkillInventory.decodeBytes(
        HostBoundedFileReader.read(inventoryFile, _maxInventoryBytes),
      );
    } on BoundedFileReadException {
      findings.add(
        const SkillEvalFinding(SkillEvalReasonCode.inventoryDecoderError),
      );
    } on StrictJsonDecodeException {
      findings.add(
        const SkillEvalFinding(SkillEvalReasonCode.inventoryDecoderError),
      );
    } on _InventoryFormatException catch (error) {
      findings.add(SkillEvalFinding(error.reasonCode));
    } on FileSystemException {
      findings.add(
        const SkillEvalFinding(SkillEvalReasonCode.inventorySchemaError),
      );
    }
    return null;
  }

  void _checkAsset(
    Directory assetDirectory,
    BundledSkillInventoryEntry entry,
    List<SkillEvalFinding> findings,
  ) {
    if (!_hasPhysicalType(assetDirectory, FileSystemEntityType.directory)) {
      findings.add(
        const SkillEvalFinding(SkillEvalReasonCode.unsafeAssetEntry),
      );
      return;
    }
    final skillMarkdown = File(
      '${assetDirectory.path}${Platform.pathSeparator}SKILL.md',
    );
    final skillMarkdownType = _physicalTypeOf(skillMarkdown);
    if (skillMarkdownType != FileSystemEntityType.file) {
      findings.add(
        SkillEvalFinding(
          skillMarkdownType == FileSystemEntityType.notFound
              ? SkillEvalReasonCode.assetMissingSkillMarkdown
              : SkillEvalReasonCode.unsafeAssetEntry,
        ),
      );
    } else if (_sha256Hex(skillMarkdown, _maxSkillMarkdownBytes) !=
        entry.skillMarkdownSha256) {
      findings.add(
        const SkillEvalFinding(
          SkillEvalReasonCode.skillMarkdownDigestMismatch,
        ),
      );
    }

    if (entry.disposition != BundledSkillDisposition.manifestV1Enabled) {
      return;
    }
    final skillJson = File(
      '${assetDirectory.path}${Platform.pathSeparator}skill.json',
    );
    final skillJsonType = _physicalTypeOf(skillJson);
    if (skillJsonType != FileSystemEntityType.file) {
      findings.add(
        SkillEvalFinding(
          skillJsonType == FileSystemEntityType.notFound
              ? SkillEvalReasonCode.enabledSkillJsonMissing
              : SkillEvalReasonCode.unsafeAssetEntry,
        ),
      );
    } else if (_sha256Hex(skillJson, _maxEnabledManifestBytes) !=
        entry.skillJsonSha256) {
      findings.add(
        const SkillEvalFinding(
          SkillEvalReasonCode.enabledSkillJsonDigestMismatch,
        ),
      );
    } else {
      _checkEnabledManifest(skillJson, findings);
    }
  }

  void _checkEnabledManifest(
    File skillJson,
    List<SkillEvalFinding> findings,
  ) {
    if (!_hasPhysicalType(skillJson, FileSystemEntityType.file)) {
      findings.add(
        const SkillEvalFinding(SkillEvalReasonCode.unsafeAssetEntry),
      );
      return;
    }
    try {
      final decoded =
          const StrictJsonDecoder(maxUtf8Bytes: _maxEnabledManifestBytes)
              .decodeBytes(
        HostBoundedFileReader.read(skillJson, _maxEnabledManifestBytes),
      );
      if (decoded is! Map<String, Object?>) {
        findings.add(
          const SkillEvalFinding(
            SkillEvalReasonCode.enabledSkillJsonManifestInvalid,
          ),
        );
        return;
      }
      final manifest =
          ExtensionManifest.fromJson(Map<String, dynamic>.from(decoded));
      if (manifest.failsIntegrityClosed) {
        findings.add(
          const SkillEvalFinding(
            SkillEvalReasonCode.enabledSkillJsonIntegrityInvalid,
          ),
        );
      }
    } on BoundedFileReadException {
      findings.add(
        const SkillEvalFinding(
          SkillEvalReasonCode.enabledSkillJsonDecoderError,
        ),
      );
      return;
    } on StrictJsonDecodeException {
      findings.add(
        const SkillEvalFinding(
          SkillEvalReasonCode.enabledSkillJsonDecoderError,
        ),
      );
      return;
    } on FileSystemException {
      findings.add(
        const SkillEvalFinding(
          SkillEvalReasonCode.enabledSkillJsonDecoderError,
        ),
      );
      return;
    } on FormatException {
      findings.add(
        const SkillEvalFinding(
          SkillEvalReasonCode.enabledSkillJsonManifestInvalid,
        ),
      );
    }
  }

  void _checkFixtureBytes(
    Directory skillAssetsDirectory,
    Directory fixtureSkillsDirectory,
    Set<String> assetDirectories,
    List<SkillEvalFinding> findings,
  ) {
    if (!_hasPhysicalType(
      fixtureSkillsDirectory,
      FileSystemEntityType.directory,
    )) {
      findings.add(
        const SkillEvalFinding(SkillEvalReasonCode.unsafeFixtureRoot),
      );
      return;
    }
    final fixtureDirectories = _listPhysicalSkillDirectories(
      fixtureSkillsDirectory,
      findings,
      unsafeEntryReason: SkillEvalReasonCode.unsafeFixtureEntry,
    );
    for (final directoryName in assetDirectories) {
      final assetDirectory = Directory(
        '${skillAssetsDirectory.path}${Platform.pathSeparator}$directoryName',
      );
      final assetSkillMarkdown = File(
        '${skillAssetsDirectory.path}${Platform.pathSeparator}$directoryName${Platform.pathSeparator}SKILL.md',
      );
      if (!_hasPhysicalType(assetDirectory, FileSystemEntityType.directory) ||
          !_hasPhysicalType(assetSkillMarkdown, FileSystemEntityType.file)) {
        findings.add(
          const SkillEvalFinding(SkillEvalReasonCode.unsafeAssetEntry),
        );
        continue;
      }
      final fixtureDirectory = Directory(
        '${fixtureSkillsDirectory.path}${Platform.pathSeparator}$directoryName',
      );
      final fixtureDirectoryType = _physicalTypeOf(fixtureDirectory);
      if (fixtureDirectoryType != FileSystemEntityType.directory) {
        findings.add(
          SkillEvalFinding(
            fixtureDirectoryType == FileSystemEntityType.notFound
                ? SkillEvalReasonCode.fixtureMissingAsset
                : SkillEvalReasonCode.unsafeFixtureEntry,
          ),
        );
        continue;
      }
      final fixtureSkillMarkdown = File(
        '${fixtureSkillsDirectory.path}${Platform.pathSeparator}$directoryName${Platform.pathSeparator}SKILL.md',
      );
      final fixtureSkillMarkdownType = _physicalTypeOf(fixtureSkillMarkdown);
      if (fixtureSkillMarkdownType != FileSystemEntityType.file) {
        findings.add(
          SkillEvalFinding(
            fixtureSkillMarkdownType == FileSystemEntityType.notFound
                ? SkillEvalReasonCode.fixtureMissingAsset
                : SkillEvalReasonCode.unsafeFixtureEntry,
          ),
        );
      } else if (_sha256Hex(assetSkillMarkdown, _maxSkillMarkdownBytes) !=
          _sha256Hex(fixtureSkillMarkdown, _maxSkillMarkdownBytes)) {
        findings.add(
          const SkillEvalFinding(SkillEvalReasonCode.fixtureAssetMismatch),
        );
      }
    }
    for (final fixtureDirectory in fixtureDirectories) {
      if (!assetDirectories.contains(fixtureDirectory)) {
        findings.add(
          const SkillEvalFinding(SkillEvalReasonCode.fixtureExtraAsset),
        );
      }
    }
  }

  Set<String> _listPhysicalSkillDirectories(
    Directory root,
    List<SkillEvalFinding> findings, {
    required SkillEvalReasonCode unsafeEntryReason,
  }) {
    final directories = <String>{};
    for (final entity in root.listSync(followLinks: false)) {
      if (_hasPhysicalType(entity, FileSystemEntityType.directory)) {
        directories.add(_basename(entity.path));
      } else {
        findings.add(SkillEvalFinding(unsafeEntryReason));
      }
    }
    return directories;
  }
}

/// Samples an entry's own physical type immediately before a list/read/hash.
///
/// This rejects links and wrong types at the pre-read check. It does not pin a
/// descriptor or otherwise provide race-proof filesystem confinement between
/// the check and a later filesystem operation.
FileSystemEntityType _physicalTypeOf(FileSystemEntity entity) =>
    FileSystemEntity.typeSync(entity.path, followLinks: false);

bool _hasPhysicalType(
  FileSystemEntity entity,
  FileSystemEntityType requiredType,
) =>
    _physicalTypeOf(entity) == requiredType;

final class SkillEvalFinding {
  const SkillEvalFinding(
    this.reasonCode, {
    this.isReleaseBlocking = false,
  });

  final SkillEvalReasonCode reasonCode;
  final bool isReleaseBlocking;
}

final class SkillEvalRunResult {
  SkillEvalRunResult(List<SkillEvalFinding> findings)
      : _findings = List.unmodifiable(findings);

  final List<SkillEvalFinding> _findings;

  List<SkillEvalFinding> get findings => _findings;

  int get inventoryErrorCount =>
      _findings.where((finding) => !finding.isReleaseBlocking).length;
  int get releaseBlockerCount =>
      _findings.where((finding) => finding.isReleaseBlocking).length;
  bool get isPass => inventoryErrorCount == 0 && releaseBlockerCount == 0;
  bool get coverageKnown => inventoryErrorCount == 0;
  int get exitCode => isPass ? 0 : 1;

  int countFor(SkillEvalReasonCode reasonCode) =>
      _findings.where((finding) => finding.reasonCode == reasonCode).length;

  /// Metadata-only CLI summary: sorted reason codes and counts, never content.
  String toCliOutput() {
    final counts = <String, int>{};
    for (final finding in _findings) {
      counts.update(
        finding.reasonCode.code,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    final reasons = counts.keys.toList()..sort();
    final reasonSummary =
        reasons.map((reason) => '$reason=${counts[reason]}').join(' ');
    final status = isPass
        ? 'PASS'
        : coverageKnown
            ? 'PARTIAL'
            : 'FAIL';
    return 'skill_evals status=$status '
        'inventory_errors=$inventoryErrorCount '
        'release_blockers=$releaseBlockerCount '
        'reasons=${reasonSummary.isEmpty ? "none" : reasonSummary}';
  }
}

final class _InventoryFormatException implements Exception {
  const _InventoryFormatException(this.reasonCode);

  final SkillEvalReasonCode reasonCode;
}

final RegExp _assetDirectoryPattern = RegExp(r'^[a-z0-9][a-z0-9-]{0,63}$');
final RegExp _sha256Pattern = RegExp(r'^[a-f0-9]{64}$');

void _requireExactKeys(Map<String, Object?> value, Set<String> expectedKeys) {
  if (value.length != expectedKeys.length ||
      !value.keys.toSet().containsAll(expectedKeys)) {
    throw const _InventoryFormatException(
      SkillEvalReasonCode.inventorySchemaError,
    );
  }
}

String _requireString(Object? value) {
  if (value is! String) {
    throw const _InventoryFormatException(
      SkillEvalReasonCode.inventorySchemaError,
    );
  }
  return value;
}

String _requireSha256(Object? value) {
  final digest = _requireString(value);
  if (!_sha256Pattern.hasMatch(digest)) {
    throw const _InventoryFormatException(
      SkillEvalReasonCode.inventorySchemaError,
    );
  }
  return digest;
}

String _requireBoundedReason(Object? value) {
  final reason = _requireString(value);
  if (reason.isEmpty || reason.length > 160) {
    throw const _InventoryFormatException(
      SkillEvalReasonCode.inventorySchemaError,
    );
  }
  return reason;
}

BundledSkillDisposition _parseDisposition(Object? value) => switch (value) {
      'manifest_v1_enabled' => BundledSkillDisposition.manifestV1Enabled,
      'disabled' => BundledSkillDisposition.disabled,
      'removed' => BundledSkillDisposition.removed,
      _ => throw const _InventoryFormatException(
          SkillEvalReasonCode.inventorySchemaError,
        ),
    };

BundledSkillPlanningStatus _parsePlanningStatus(Object? value) =>
    switch (value) {
      'ready_for_release' => BundledSkillPlanningStatus.readyForRelease,
      'pending_runtime_remediation' =>
        BundledSkillPlanningStatus.pendingRuntimeRemediation,
      _ => throw const _InventoryFormatException(
          SkillEvalReasonCode.inventorySchemaError,
        ),
    };

String _sha256Hex(File file, int maximumBytes) =>
    HostBoundedFileReader.sha256Hex(file, maximumBytes);

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  return normalized.substring(normalized.lastIndexOf('/') + 1);
}
