import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import '../constants.dart';
import '../models/setup_state.dart';
import '../services/bootstrap_service.dart';
import '../widgets/progress_step.dart';
import 'onboarding_screen.dart';
import '../l10n/app_strings.dart';

class SetupWizardScreen extends StatefulWidget {
  const SetupWizardScreen({super.key});

  @override
  State<SetupWizardScreen> createState() => _SetupWizardScreenState();
}

class _SetupWizardScreenState extends State<SetupWizardScreen> {
  bool _started = false;
  SetupState _state = const SetupState();
  final _bootstrap = BootstrapService();

  Future<void> _runSetup() async {
    setState(() {
      _started = true;
      _state = SetupState(step: SetupStep.checkingStatus, message: AppStrings.startingInit);
    });

    try {
      await _bootstrap.runFullSetup(
        onProgress: (state) {
          if (mounted) setState(() => _state = state);
        },
      );
    } catch (e) {
      if (mounted) {
        setState(() => _state = SetupState(
          step: SetupStep.error,
          message: 'Setup failed: $e',
          error: e.toString(),
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 32),
              Image.asset('assets/ic_launcher.png', width: 64, height: 64),
              const SizedBox(height: 16),
              Text(
                AppStrings.initClawChat,
                style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                _started
                    ? AppStrings.initializingMessage
                    : AppStrings.downloadMessage,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 32),
              _buildProgressSummary(_state, theme),
              const SizedBox(height: 16),
              Expanded(child: _buildSteps(_state, theme)),
              if (_state.hasError) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline, color: theme.colorScheme.error),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _state.error ?? AppStrings.unknownError,
                          style: TextStyle(color: theme.colorScheme.onErrorContainer),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
              if (_state.isComplete)
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () => Navigator.of(context).pushReplacement(
                      CupertinoPageRoute(builder: (_) => const OnboardingScreen(isFirstRun: true)),
                    ),
                    icon: const Icon(Icons.arrow_forward),
                    label: const Text(AppStrings.configureApiKey),
                  ),
                )
              else if (!_started || _state.hasError)
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _state.step == SetupStep.installingPackages &&
                        !_state.isComplete && !_state.hasError
                        ? null
                        : _runSetup,
                    icon: const Icon(Icons.download),
                    label: Text(_started ? AppStrings.retry : AppStrings.startSetup),
                  ),
                ),
              const SizedBox(height: 16),
              Center(
                child: Text(
                  'ClawChat v${AppConstants.version}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSteps(SetupState state, ThemeData theme) {
    final steps = [
      (1, AppStrings.downloadRootfs, SetupStep.downloadingRootfs),
      (2, AppStrings.extractRootfs, SetupStep.extractingRootfs),
      (3, AppStrings.installPackages, SetupStep.installingPackages),
    ];

    return ListView(
      children: [
        for (final (num, label, step) in steps)
          ProgressStep(
            stepNumber: num,
            label: state.step == step ? state.message : label,
            isActive: state.step == step,
            // Relies on SetupStep enum declaration order matching step sequence
            isComplete: state.stepNumber > step.index || state.isComplete,
            hasError: state.hasError && state.step == step,
            progress: state.step == step ? state.progress : null,
          ),
        if (state.isComplete)
          const ProgressStep(
            stepNumber: 4,
            label: AppStrings.initComplete,
            isComplete: true,
          ),
      ],
    );
  }

  Widget _buildProgressSummary(SetupState state, ThemeData theme) {
    final progress = _overallProgress(state);
    final currentOperation = state.message.isNotEmpty
        ? state.message
        : (_started ? state.stepLabel : AppStrings.startingInit);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withAlpha(120),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outline.withAlpha(45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                state.isComplete ? Icons.check_circle : Icons.downloading,
                color: state.isComplete
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  state.isComplete ? AppStrings.initComplete : AppStrings.currentOperation,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '${(progress * 100).round()}%',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          LinearProgressIndicator(
            value: progress,
            minHeight: 6,
            borderRadius: BorderRadius.circular(999),
          ),
          const SizedBox(height: 10),
          Text(
            currentOperation,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  double _overallProgress(SetupState state) {
    if (!_started) return 0.0;
    if (state.isComplete) return 1.0;
    final stepBase = (state.stepNumber - 1).clamp(0, 2).toDouble();
    final stepProgress = state.progress > 0
        ? state.progress.clamp(0.0, 1.0).toDouble()
        : 0.0;
    return ((stepBase + stepProgress) / 3).clamp(0.0, 1.0).toDouble();
  }
}
