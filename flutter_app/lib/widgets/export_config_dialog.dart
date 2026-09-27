import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';

/// Options chosen in [ExportConfigDialog].
class ExportConfigOptions {
  final bool encrypt;
  final String password;
  final bool includePlaintextSecrets;

  const ExportConfigOptions({
    required this.encrypt,
    required this.password,
    required this.includePlaintextSecrets,
  });
}

/// Password / plaintext choice for a config export or backup.
///
/// On a compact viewport (narrow window or large accessibility text) the
/// primary action moves into the scrollable body as a full-width button: the
/// `AlertDialog` action row would otherwise overflow and clip the button's tap
/// target to a partly off-screen strip. Both layouts expose the same semantics
/// node, so assistive technology and hit testing agree on one target.
class ExportConfigDialog extends StatefulWidget {
  const ExportConfigDialog({super.key, this.semanticsHint});

  /// Optional hint announced with the primary action.
  final String? semanticsHint;

  /// Shown when the text scale is large enough that the action row cannot hold
  /// two buttons comfortably.
  static const double compactTextScaleThreshold = 1.3;

  /// Shown when the dialog has less horizontal room than this.
  static const double compactWidthThreshold = 380;

  static bool isCompactLayout(BuildContext context) {
    final media = MediaQuery.maybeOf(context);
    if (media == null) return false;
    final scaled = media.textScaler.scale(14) / 14;
    return media.size.width < compactWidthThreshold ||
        scaled > compactTextScaleThreshold;
  }

  @override
  State<ExportConfigDialog> createState() => _ExportConfigDialogState();
}

class _ExportConfigDialogState extends State<ExportConfigDialog> {
  var _encrypt = true;
  var _includePlaintextSecrets = false;
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  void _submit() {
    final password = _passwordController.text;
    if (_encrypt) {
      if (password.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(AppStrings.passwordRequired)),
        );
        return;
      }
      if (password != _confirmController.text) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(AppStrings.passwordMismatch)),
        );
        return;
      }
    }
    Navigator.pop(
      context,
      ExportConfigOptions(
        encrypt: _encrypt,
        password: password,
        includePlaintextSecrets: !_encrypt && _includePlaintextSecrets,
      ),
    );
  }

  Widget _primaryAction({required bool fullWidth}) {
    final button = Semantics(
      label: AppStrings.exportConfig,
      hint: widget.semanticsHint,
      button: true,
      enabled: true,
      child: FilledButton(
        key: const ValueKey('export-config-primary-action'),
        onPressed: _submit,
        style: FilledButton.styleFrom(
          // A complete, unclipped target even with large text.
          minimumSize: const Size(88, 48),
          padding: const EdgeInsets.symmetric(horizontal: 20),
        ),
        child: const Text(
          AppStrings.exportConfig,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
    return fullWidth ? SizedBox(width: double.infinity, child: button) : button;
  }

  Widget _cancelAction() {
    return TextButton(
      onPressed: () => Navigator.pop(context),
      style: TextButton.styleFrom(minimumSize: const Size(88, 48)),
      child: const Text(AppStrings.cancel),
    );
  }

  @override
  Widget build(BuildContext context) {
    final compact = ExportConfigDialog.isCompactLayout(context);
    return AlertDialog(
      title: const Text(AppStrings.exportConfig),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(AppStrings.encryptSecrets),
              subtitle: const Text(AppStrings.encryptSecretsSubtitle),
              value: _encrypt,
              onChanged: (value) => setState(() {
                _encrypt = value;
                if (_encrypt) _includePlaintextSecrets = false;
              }),
            ),
            if (!_encrypt) ...[
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(AppStrings.exportConfigRedactedByDefault),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(AppStrings.exportConfigPlaintextSecrets),
                subtitle: const Text(
                  AppStrings.exportConfigPlaintextSecretsSubtitle,
                ),
                value: _includePlaintextSecrets,
                onChanged: (value) => setState(
                  () => _includePlaintextSecrets = value,
                ),
              ),
            ],
            if (_encrypt) ...[
              TextField(
                controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: AppStrings.setPassword,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _confirmController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: AppStrings.confirmPassword,
                ),
              ),
            ],
            if (compact) ...[
              const SizedBox(height: 16),
              _primaryAction(fullWidth: true),
              const SizedBox(height: 8),
              SizedBox(width: double.infinity, child: _cancelAction()),
            ],
          ],
        ),
      ),
      actions: compact
          ? const []
          : [
              _cancelAction(),
              _primaryAction(fullWidth: false),
            ],
    );
  }
}

/// Opens [ExportConfigDialog]; `null` means the user cancelled.
Future<ExportConfigOptions?> showExportConfigDialog(
  BuildContext context, {
  String? semanticsHint,
}) {
  return showDialog<ExportConfigOptions>(
    context: context,
    builder: (_) => ExportConfigDialog(semanticsHint: semanticsHint),
  );
}
