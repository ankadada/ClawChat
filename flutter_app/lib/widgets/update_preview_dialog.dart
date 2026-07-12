import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../services/update_service.dart';

final class UpdatePreviewDialog extends StatelessWidget {
  const UpdatePreviewDialog.extension({
    super.key,
    required ExtensionUpdatePlan plan,
  })  : _extensionPlan = plan,
        _appPlan = null;

  const UpdatePreviewDialog.app({
    super.key,
    required AppUpdatePlan plan,
  })  : _appPlan = plan,
        _extensionPlan = null;

  final ExtensionUpdatePlan? _extensionPlan;
  final AppUpdatePlan? _appPlan;

  @override
  Widget build(BuildContext context) {
    final extension = _extensionPlan;
    final check = extension?.check ?? _appPlan!.check;
    final metadata = check.metadata;
    final diff = extension?.capabilityDiff;
    return AlertDialog(
      title: Text(extension == null
          ? 'Verified Android app update'
          : 'Review extension update'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Source: ${check.sourceIdentity}'),
              Text('Target: ${metadata.targetId}'),
              Text('Version: ${check.currentVersion} → ${metadata.version}'),
              Text('Revision: ${metadata.revision}'),
              Text('Size: ${metadata.artifactSize} bytes'),
              Text('SHA-256: ${_short(metadata.artifactSha256)}'),
              Text('Signing key: ${_short(metadata.keyId)}'),
              Text('Signature: ${metadata.signatureAlgorithm} verified'),
              if (extension != null) ...[
                const SizedBox(height: 12),
                Text('Declared risk: ${extension.candidate.riskTier}'),
                const Text(
                  'Capability changes',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                if (diff == null || diff.isEmpty)
                  const Text('No capability changes')
                else ...[
                  ...diff.added.map((value) => Text('+ $value')),
                  ...diff.removed.map((value) => Text('- $value')),
                ],
                const SizedBox(height: 12),
                const Text(
                  'Applying keeps a local backup. It does not approve any '
                  'individual tool call.',
                ),
              ] else ...[
                const SizedBox(height: 12),
                const Text(
                  'Continue only hands this verified APK to Android’s system '
                  'installer. ClawChat cannot silently install it.',
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text(AppStrings.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(extension == null
              ? 'Open system installer'
              : 'Apply with backup'),
        ),
      ],
    );
  }

  static String _short(String value) =>
      '${value.substring(0, 12)}…${value.substring(value.length - 8)}';
}
