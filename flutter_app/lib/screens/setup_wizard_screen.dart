import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../constants.dart';
import '../l10n/app_strings.dart';
import '../models/setup_state.dart';
import '../services/bootstrap_service.dart';
import '../widgets/progress_step.dart';
import '../widgets/setup_adaptive_region.dart';
import 'onboarding_screen.dart';

typedef BootstrapRunner = Future<void> Function(
  void Function(SetupState state) onProgress,
);

class SetupWizardScreen extends StatefulWidget {
  const SetupWizardScreen({
    super.key,
    this.bootstrap,
    this.preflightLoader,
    this.setupRunner,
    this.onContinue,
  });

  final BootstrapService? bootstrap;
  final Future<BootstrapPreflight> Function()? preflightLoader;
  final BootstrapRunner? setupRunner;
  final VoidCallback? onContinue;

  @override
  State<SetupWizardScreen> createState() => _SetupWizardScreenState();
}

class _SetupWizardScreenState extends State<SetupWizardScreen> {
  late final BootstrapService _bootstrap;
  bool _started = false;
  bool _running = false;
  bool _preflightLoading = true;
  BootstrapPreflight? _preflight;
  String? _preflightError;
  SetupState _state = const SetupState();

  @override
  void initState() {
    super.initState();
    _bootstrap = widget.bootstrap ?? BootstrapService();
    _loadPreflight();
  }

  Future<void> _loadPreflight() async {
    if (!_preflightLoading) {
      setState(() {
        _preflightLoading = true;
        _preflightError = null;
      });
    }
    try {
      final result = await (widget.preflightLoader ?? _bootstrap.preflight)();
      if (!mounted) return;
      setState(() {
        _preflight = result;
        _preflightLoading = false;
        if (result.bootstrapComplete) {
          _started = true;
          _state = const SetupState(
            step: SetupStep.complete,
            progress: 1,
            message: AppStrings.initComplete,
          );
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _preflightLoading = false;
        _preflightError = AppStrings.bootstrapPreflightUnavailable;
      });
    }
  }

  Future<void> _runSetup() async {
    if (_running || _preflight?.canStart != true) return;
    setState(() {
      _started = true;
      _running = true;
      _state = const SetupState(
        step: SetupStep.checkingStatus,
        message: AppStrings.startingInit,
      );
    });

    final runner = widget.setupRunner ??
        (onProgress) => _bootstrap.runFullSetup(onProgress: onProgress);
    try {
      await runner((state) {
        if (mounted) setState(() => _state = state);
      });
    } catch (_) {
      if (mounted) {
        setState(() => _state = const SetupState(
              step: SetupStep.error,
              error: AppStrings.bootstrapSetupFailed,
            ));
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  void _continue() {
    if (widget.onContinue != null) {
      widget.onContinue!();
      return;
    }
    Navigator.of(context).pushReplacement(
      CupertinoPageRoute(
        builder: (_) => const OnboardingScreen(isFirstRun: true),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SetupAdaptiveRegion(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: FocusTraversalGroup(
            policy: OrderedTraversalPolicy(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    key: const Key('setup-scroll'),
                    child: _started
                        ? _buildProgressContent(theme)
                        : _buildPrelude(theme),
                  ),
                ),
                const SizedBox(height: 12),
                FocusTraversalOrder(
                  order: const NumericFocusOrder(100),
                  child: _buildPrimaryAction(),
                ),
                const SizedBox(height: 8),
                Text(
                  'ClawChat v${AppConstants.version}',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPrelude(ThemeData theme) {
    return Semantics(
      namesRoute: true,
      label: AppStrings.setupPreludeTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Image.asset('assets/ic_launcher.png', width: 56, height: 56),
          const SizedBox(height: 12),
          Text(
            AppStrings.setupPreludeTitle,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          const Text(AppStrings.setupPreludeSubtitle),
          const SizedBox(height: 16),
          _promise(theme, Icons.lock_outline, AppStrings.setupPromiseLocal),
          _promise(theme, Icons.key_outlined, AppStrings.setupPromiseByok),
          _promise(theme, Icons.terminal, AppStrings.setupPromiseTools),
          _promise(
            theme,
            Icons.hub_outlined,
            AppStrings.setupPromiseConnector,
          ),
          const SizedBox(height: 16),
          _buildDownloadPreflight(theme),
        ],
      ),
    );
  }

  Widget _promise(ThemeData theme, IconData icon, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 22, color: theme.colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(child: Text(text)),
          ],
        ),
      );

  Widget _buildDownloadPreflight(ThemeData theme) {
    final preflight = _preflight;
    return Semantics(
      container: true,
      label: AppStrings.bootstrapPreflightTitle,
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                AppStrings.bootstrapPreflightTitle,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              const Text(AppStrings.bootstrapDownloadDetails),
              const SizedBox(height: 10),
              if (_preflightLoading)
                const Row(
                  children: [
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 10),
                    Expanded(child: Text(AppStrings.bootstrapCheckingDevice)),
                  ],
                )
              else if (_preflightError != null)
                _statusRow(
                  theme,
                  Icons.error_outline,
                  _preflightError!,
                  error: true,
                )
              else if (preflight != null) ...[
                _statusRow(
                  theme,
                  preflight.hasEnoughStorage
                      ? Icons.check_circle_outline
                      : Icons.error_outline,
                  preflight.availableBytes == null
                      ? AppStrings.bootstrapStorageUnknown
                      : AppStrings.bootstrapStorageAvailable(
                          preflight.availableBytes!,
                        ),
                  error: !preflight.hasEnoughStorage,
                ),
                _statusRow(
                  theme,
                  preflight.networkConnected == false
                      ? Icons.wifi_off
                      : Icons.wifi,
                  preflight.networkConnected == false
                      ? AppStrings.bootstrapNetworkUnavailable
                      : preflight.networkValidated == true
                          ? AppStrings.bootstrapNetworkReady
                          : AppStrings.bootstrapNetworkRequired,
                  error: preflight.networkConnected == false,
                ),
                if (preflight.cachedArchiveBytes > 0)
                  _statusRow(
                    theme,
                    Icons.inventory_2_outlined,
                    AppStrings.bootstrapCacheFound,
                  ),
                if (preflight.rootfsPresent && !preflight.bootstrapComplete)
                  _statusRow(
                    theme,
                    Icons.build_circle_outlined,
                    AppStrings.bootstrapPartialEnvironmentFound,
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusRow(
    ThemeData theme,
    IconData icon,
    String label, {
    bool error = false,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              icon,
              size: 20,
              color:
                  error ? theme.colorScheme.error : theme.colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(label)),
          ],
        ),
      );

  Widget _buildProgressContent(ThemeData theme) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppStrings.initClawChat,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            AppStrings.initializingMessage,
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          _buildProgressSummary(_state, theme),
          const SizedBox(height: 16),
          _buildSteps(_state),
          if (_state.hasError) ...[
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Text(
                switch (_state.failureCategory) {
                  SetupFailureCategory.network =>
                    AppStrings.bootstrapNetworkFailure,
                  SetupFailureCategory.storage =>
                    AppStrings.bootstrapStorageFailure,
                  SetupFailureCategory.integrity =>
                    AppStrings.bootstrapIntegrityFailure,
                  _ => AppStrings.bootstrapSetupFailed,
                },
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          ],
        ],
      );

  Widget _buildPrimaryAction() {
    final complete = _state.isComplete;
    final retryPreflight = !_started && _preflightError != null;
    final enabled = complete ||
        retryPreflight ||
        (!_running && !_preflightLoading && _preflight?.canStart == true) ||
        (_state.hasError && !_running);
    return Semantics(
      button: true,
      enabled: enabled,
      child: FilledButton.icon(
        key: const Key('setup-primary-action'),
        style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
        onPressed: !enabled
            ? null
            : complete
                ? _continue
                : retryPreflight
                    ? _loadPreflight
                    : _runSetup,
        icon: Icon(
          complete
              ? Icons.arrow_forward
              : retryPreflight || _state.hasError
                  ? Icons.refresh
                  : Icons.download,
        ),
        label: Text(
          complete
              ? AppStrings.configureApiKey
              : retryPreflight || _state.hasError
                  ? AppStrings.retry
                  : AppStrings.startSetup,
        ),
      ),
    );
  }

  Widget _buildSteps(SetupState state) {
    final steps = [
      (1, AppStrings.downloadRootfs, SetupStep.downloadingRootfs),
      (2, AppStrings.extractRootfs, SetupStep.extractingRootfs),
      (3, AppStrings.installPackages, SetupStep.installingPackages),
    ];
    return Column(
      children: [
        for (final (num, label, step) in steps)
          ProgressStep(
            stepNumber: num,
            label: state.step == step ? state.message : label,
            isActive: state.step == step,
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
    return Semantics(
      liveRegion: true,
      value: '${(progress * 100).round()}%',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LinearProgressIndicator(value: progress, minHeight: 6),
          const SizedBox(height: 8),
          Text(state.message.isEmpty ? state.stepLabel : state.message),
        ],
      ),
    );
  }

  double _overallProgress(SetupState state) {
    if (!_started) return 0;
    if (state.isComplete) return 1;
    final base = (state.stepNumber - 1).clamp(0, 2).toDouble();
    return ((base + state.progress.clamp(0, 1)) / 3).clamp(0, 1);
  }
}
