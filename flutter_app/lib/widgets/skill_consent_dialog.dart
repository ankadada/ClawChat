import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../models/extension_manifest.dart';
import '../services/skill_service.dart';

class SkillConsentDialog extends StatelessWidget {
  final PreparedSkillImport candidate;

  const SkillConsentDialog({
    super.key,
    required this.candidate,
  });

  @override
  Widget build(BuildContext context) {
    final diff = candidate.capabilityDiff;
    return AlertDialog(
      scrollable: true,
      title: Text(
        candidate.legacy ? 'Legacy skill warning' : 'Review skill capabilities',
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Source: ${candidate.sourceIdentity}'),
          if (candidate.manifest?.source.url != null)
            Text('Declared source: ${candidate.manifest!.source.url}')
          else if (candidate.manifest != null)
            Text('Declared source: ${candidate.manifest!.source.type}'),
          Text('Manifest ID: ${candidate.id}'),
          Text('Name: ${candidate.name}'),
          Text('Version: ${candidate.version}'),
          Text('Risk: ${candidate.riskTier}'),
          Text('Integrity: ${_integrityLabel(candidate.integrityStatus)}'),
          const SizedBox(height: 12),
          const Text(
            'Local inert import inspection',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          Text('Verdict: ${candidate.inspection.verdict.wireName}'),
          Text(candidate.inspection.summary),
          Text(
            'Rule IDs: ${candidate.inspection.ruleIds.isEmpty ? 'none' : candidate.inspection.ruleIds.join(', ')}',
          ),
          Text(
            'Capability counts: ${candidate.inspection.capabilities.displayText}',
          ),
          if (candidate.legacy) ...[
            const SizedBox(height: 12),
            const Text(
              'This skill has no manifest. Its capabilities are '
              'undeclared and treated as unknown/critical risk. It will '
              'remain unavailable until you explicitly consent.',
            ),
          ],
          if (candidate.hasUnsupportedFilesystemCapabilities) ...[
            const SizedBox(height: 12),
            const Text(
              'Filesystem access is unsupported on the current Android '
              'runtime and will be denied. Installing or enabling this '
              'skill does not grant its declared read/write scopes.',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
          const SizedBox(height: 12),
          const Text(
            'Effective capabilities and runtime denials',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          ...candidate.capabilitySnapshot.summaryLines.map(Text.new),
          if (diff != null && !diff.isEmpty) ...[
            const SizedBox(height: 12),
            const Text(
              'Changes since last consent',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            ...diff.added.map((value) => Text('+ $value')),
            ...diff.removed.map((value) => Text('- $value')),
          ],
          const SizedBox(height: 12),
          const Text(
            'Installing or enabling this skill does not approve '
            'individual tool calls. Tool safety policy still applies.',
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text(AppStrings.cancel),
        ),
        FilledButton(
          onPressed: candidate.inspection.isRejected
              ? null
              : () => Navigator.pop(context, true),
          child: Text(
            candidate.hasUnsupportedFilesystemCapabilities
                ? candidate.installedCandidate
                    ? 'Enable with filesystem denied'
                    : 'Install with filesystem denied'
                : candidate.installedCandidate
                    ? 'Enable'
                    : 'Install',
          ),
        ),
      ],
    );
  }

  static String _integrityLabel(IntegrityStatus status) => switch (status) {
        IntegrityStatus.notProvided => 'Not provided',
        IntegrityStatus.verifiedDigest => 'SHA-256 digest verified',
        IntegrityStatus.signatureUnverified => 'Signature present (unverified)',
        IntegrityStatus.digestVerifiedSignatureUnverified =>
          'SHA-256 verified; signature unverified',
        IntegrityStatus.mismatch => 'Digest mismatch',
        IntegrityStatus.unsupported => 'Unsupported integrity metadata',
      };
}
