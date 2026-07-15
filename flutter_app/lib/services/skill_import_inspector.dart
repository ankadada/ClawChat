import 'dart:convert';

import '../models/extension_manifest.dart';
import 'strict_json_decoder.dart';

enum ImportInspectionVerdict {
  accepted,
  rejected,
  needsReview;

  String get wireName => switch (this) {
        accepted => 'accepted',
        rejected => 'rejected',
        needsReview => 'needs_review',
      };
}

/// Count-only capability metadata shown before consent.
///
/// Values and imported prose are intentionally excluded so this object remains
/// safe to render or include in metadata-only diagnostics.
final class ImportCapabilitySummary {
  const ImportCapabilitySummary({
    required this.toolCount,
    required this.commandCount,
    required this.networkDomainCount,
    required this.filesystemScopeCount,
    required this.androidCapabilityCount,
    required this.secretNameCount,
    required this.runtimeCount,
    required this.subprocessRequired,
  });

  static const empty = ImportCapabilitySummary(
    toolCount: 0,
    commandCount: 0,
    networkDomainCount: 0,
    filesystemScopeCount: 0,
    androidCapabilityCount: 0,
    secretNameCount: 0,
    runtimeCount: 0,
    subprocessRequired: false,
  );

  final int toolCount;
  final int commandCount;
  final int networkDomainCount;
  final int filesystemScopeCount;
  final int androidCapabilityCount;
  final int secretNameCount;
  final int runtimeCount;
  final bool subprocessRequired;

  bool get hasDeclarations =>
      toolCount != 0 ||
      commandCount != 0 ||
      networkDomainCount != 0 ||
      filesystemScopeCount != 0 ||
      androidCapabilityCount != 0 ||
      secretNameCount != 0 ||
      runtimeCount != 0 ||
      subprocessRequired;

  String get displayText =>
      'tools=$toolCount, commands=$commandCount, networkDomains=$networkDomainCount, '
      'filesystemScopes=$filesystemScopeCount, androidCapabilities=$androidCapabilityCount, '
      'secretNames=$secretNameCount, runtimes=$runtimeCount, '
      'subprocessRequired=$subprocessRequired';

  factory ImportCapabilitySummary.fromManifest(ExtensionManifest manifest) {
    final capabilities = manifest.capabilities;
    return ImportCapabilitySummary(
      toolCount: capabilities.tools.length,
      commandCount: capabilities.commands.length,
      networkDomainCount: capabilities.networkDomains.length,
      filesystemScopeCount: capabilities.filesystem.read.length +
          capabilities.filesystem.write.length,
      androidCapabilityCount: capabilities.android.intents.length +
          capabilities.android.permissions.length,
      secretNameCount: capabilities.secrets.length,
      runtimeCount: capabilities.subprocess.runtimes.length,
      subprocessRequired: capabilities.subprocess.required,
    );
  }
}

/// Non-authorizing result of bounded, inert import inspection.
///
/// This type has no conversion to [VerifiedSkillUse], no policy hook, and no
/// executable callbacks. It contains only fixed rule IDs and count metadata.
final class ImportInspectionResult {
  ImportInspectionResult._({
    required this.verdict,
    required List<String> ruleIds,
    required this.summary,
    required this.capabilities,
  }) : ruleIds = List.unmodifiable(ruleIds) {
    if (this.ruleIds.length > SkillImportInspector.maxRuleIds ||
        summary.length > SkillImportInspector.maxSummaryCharacters) {
      throw StateError('Import inspection result exceeded fixed bounds.');
    }
  }

  final ImportInspectionVerdict verdict;
  final List<String> ruleIds;
  final String summary;
  final ImportCapabilitySummary capabilities;

  bool get isAccepted => verdict == ImportInspectionVerdict.accepted;
  bool get isRejected => verdict == ImportInspectionVerdict.rejected;
  bool get needsReview => verdict == ImportInspectionVerdict.needsReview;
}

/// Internal parse material plus the public, non-authorizing inspection result.
/// Callers must use only [result] for UI/diagnostics and independently retain
/// the existing consent, digest, capability-policy, and per-call tool gates.
final class InspectedSkillPackage {
  const InspectedSkillPackage({
    required this.result,
    this.skillContent,
    this.manifest,
  });

  final ImportInspectionResult result;
  final String? skillContent;
  final ExtensionManifest? manifest;
}

final class SkillImportRejectedException extends FormatException {
  SkillImportRejectedException(this.result)
      : super('Skill import rejected: ${result.ruleIds.join(',')}.');

  final ImportInspectionResult result;

  @override
  String toString() => message;
}

/// Pure, bounded device-import inspector.
///
/// Imported bytes are decoded and scanned as inert data only. This class does
/// not import NativeBridge, HTTP, model, tool-registry, or policy services and
/// cannot execute any archive-provided content.
final class SkillImportInspector {
  const SkillImportInspector._();

  static const maxSkillBytes = 1024 * 1024;
  static const maxManifestBytes = 256 * 1024;
  static const maxRuleIds = 16;
  static const maxSummaryCharacters = 1024;

  static final _destructiveCommand = RegExp(
    r'(?:\brm\s+-rf\b|\bmkfs(?:\.[a-z0-9]+)?\b|\bdd\s+if=|:\(\)\s*\{|\bshutdown\b|\breboot\b)',
    caseSensitive: false,
  );
  static final _policyBypass = RegExp(
    r'(?:ignore\s+(?:all\s+)?safety|bypass\s+(?:approval|policy)|disable\s+(?:tool\s+)?policy|exfiltrat(?:e|ion)|steal\s+(?:a\s+)?secret)',
    caseSensitive: false,
  );
  static final _shellInstruction = RegExp(
    r'(?:\b(?:run|execute|invoke)\s+(?:sudo|bash|sh|zsh|python|node|powershell|cmd|git)\b|```\s*(?:bash|sh|zsh|python|javascript|js|powershell)\b)',
    caseSensitive: false,
  );
  static final _networkReference = RegExp(
    r'(?:https?://|\b[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+\b)',
    caseSensitive: false,
  );
  static final _secretReference = RegExp(
    r'\b[A-Z][A-Z0-9_]{2,63}(?:TOKEN|SECRET|PASSWORD|API_KEY|PRIVATE_KEY)\b|\b(?:TOKEN|SECRET|PASSWORD|API_KEY|PRIVATE_KEY)\b',
  );
  static final _absolutePath = RegExp(
    r'(?<![A-Za-z0-9])/(?:etc|root|home|data|sdcard|storage|system|vendor|proc|sys|dev)(?:/|\b)',
  );
  static final _responseContract = RegExp(
    r'\b(?:reply|respond|output|return)\b[^\n]{0,40}\b(?:json|xml|yaml|schema|format)\b',
    caseSensitive: false,
  );

  static InspectedSkillPackage inspect({
    required List<int> skillBytes,
    required List<int>? manifestBytes,
  }) {
    final rejected = <String>{};
    final review = <String>{};
    String? skillContent;
    ExtensionManifest? manifest;

    if (skillBytes.length > maxSkillBytes) {
      rejected.add('skill_too_large');
    } else {
      try {
        if (skillBytes.length >= 3 &&
            skillBytes[0] == 0xef &&
            skillBytes[1] == 0xbb &&
            skillBytes[2] == 0xbf) {
          throw const FormatException('bom');
        }
        skillContent = utf8.decode(skillBytes, allowMalformed: false);
        if (skillContent.trim().isEmpty) rejected.add('skill_empty');
      } on FormatException {
        rejected.add('skill_utf8_invalid');
      }
    }

    var capabilities = ImportCapabilitySummary.empty;
    if (manifestBytes == null) {
      review.add('manifest_absent');
    } else if (manifestBytes.length > maxManifestBytes) {
      rejected.add('manifest_too_large');
    } else {
      try {
        final decoded = const StrictJsonDecoder(
          maxUtf8Bytes: maxManifestBytes,
        ).decodeBytes(manifestBytes);
        if (decoded is! Map<String, Object?>) {
          throw const FormatException('manifest root');
        }
        manifest = ExtensionManifest.fromJson(
          Map<String, dynamic>.from(decoded),
        );
        if (manifest.failsIntegrityClosed) {
          rejected.add('manifest_integrity_invalid');
        }
        capabilities = ImportCapabilitySummary.fromManifest(manifest);
        if (capabilities.hasDeclarations) {
          review.add('capability_review_required');
        }
      } on StrictJsonDecodeException {
        rejected.add('manifest_json_invalid');
      } on FormatException {
        rejected.add('manifest_invalid');
      } catch (_) {
        rejected.add('manifest_invalid');
      }
    }

    if (skillContent != null) {
      if (_destructiveCommand.hasMatch(skillContent)) {
        rejected.add('content_destructive_command');
      }
      if (_policyBypass.hasMatch(skillContent)) {
        rejected.add('content_policy_bypass');
      }
      if (_shellInstruction.hasMatch(skillContent)) {
        review.add('content_shell_instruction');
      }
      if (_networkReference.hasMatch(skillContent)) {
        review.add('content_network_reference');
      }
      if (_secretReference.hasMatch(skillContent)) {
        review.add('content_secret_reference');
      }
      if (_absolutePath.hasMatch(skillContent)) {
        review.add('content_absolute_path');
      }
      if (_responseContract.hasMatch(skillContent)) {
        review.add('content_response_contract');
      }
    }

    final verdict = rejected.isNotEmpty
        ? ImportInspectionVerdict.rejected
        : review.isNotEmpty
            ? ImportInspectionVerdict.needsReview
            : ImportInspectionVerdict.accepted;
    final rules = <String>[...rejected, ...review]..sort();
    final boundedRules = rules.take(maxRuleIds).toList(growable: false);
    final summary = switch (verdict) {
      ImportInspectionVerdict.accepted =>
        'No fixed structural, manifest, capability, or content rule requires review.',
      ImportInspectionVerdict.needsReview =>
        'Local inert inspection found declarations or fixed content patterns that require explicit review.',
      ImportInspectionVerdict.rejected =>
        'Local inert inspection rejected the package because a fixed safety rule failed.',
    };
    return InspectedSkillPackage(
      result: ImportInspectionResult._(
        verdict: verdict,
        ruleIds: boundedRules,
        summary: summary,
        capabilities: capabilities,
      ),
      skillContent: skillContent,
      manifest: manifest,
    );
  }
}
