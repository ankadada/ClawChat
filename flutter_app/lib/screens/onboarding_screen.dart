import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import '../constants.dart';
import '../services/llm_service.dart';
import '../services/preferences_service.dart';
import '../app.dart';
import '../l10n/app_strings.dart';
import '../widgets/setup_adaptive_region.dart';

typedef OnboardingModelFetcher = Future<List<String>> Function({
  required String apiFormat,
  required String apiKey,
  String? baseUrl,
});

final class OnboardingInitialValues {
  const OnboardingInitialValues({
    this.apiFormat = 'anthropic',
    this.apiKey = '',
    this.baseUrl = '',
    this.model = '',
  });

  final String apiFormat;
  final String apiKey;
  final String baseUrl;
  final String model;
}

final class OnboardingConfig {
  const OnboardingConfig({
    required this.apiFormat,
    required this.apiKey,
    required this.baseUrl,
    required this.model,
  });

  final String apiFormat;
  final String apiKey;
  final String baseUrl;
  final String model;
}

enum _ModelFetchResult {
  none,
  success,
  presetFallback,
  auth,
  network,
  endpoint,
  provider,
  cancelled
}

class OnboardingScreen extends StatefulWidget {
  final bool isFirstRun;
  const OnboardingScreen({
    super.key,
    this.isFirstRun = false,
    this.initialValuesLoader,
    this.modelFetcher,
    this.configSaver,
    this.onComplete,
  });

  final Future<OnboardingInitialValues> Function()? initialValuesLoader;
  final OnboardingModelFetcher? modelFetcher;
  final Future<void> Function(OnboardingConfig config)? configSaver;
  final VoidCallback? onComplete;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _prefs = PreferencesService();
  final _apiKeyController = TextEditingController();
  final _baseUrlController = TextEditingController();
  final _modelController = TextEditingController();
  String _apiFormat = 'anthropic';
  int _currentStep = 0;
  List<String> _availableModels = [];
  bool _fetchingModels = false;
  bool _manualModelInput = false;
  String? _apiKeyError;
  String? _baseUrlError;
  String? _modelError;
  _ModelFetchResult _fetchResult = _ModelFetchResult.none;
  int _fetchGeneration = 0;

  @override
  void initState() {
    super.initState();
    _initPrefs();
  }

  Future<void> _initPrefs() async {
    final values = widget.initialValuesLoader == null
        ? await _loadPreferences()
        : await widget.initialValuesLoader!();
    if (!mounted) return;
    setState(() {
      _apiFormat = values.apiFormat;
      _apiKeyController.text = values.apiKey;
      _baseUrlController.text = values.baseUrl;
      _modelController.text = values.model;
    });
  }

  Future<OnboardingInitialValues> _loadPreferences() async {
    await _prefs.init();
    return OnboardingInitialValues(
      apiFormat: _prefs.apiFormat ?? 'anthropic',
      apiKey: _prefs.apiKey ?? '',
      baseUrl: _prefs.baseUrl ?? '',
      model: _prefs.model ?? '',
    );
  }

  Future<void> _fetchModels() async {
    final apiKey = _apiKeyController.text.trim();
    if (apiKey.isEmpty) {
      setState(() => _apiKeyError = AppStrings.pleaseEnterApiKey);
      return;
    }
    if (!_validateBaseUrl()) return;

    final generation = ++_fetchGeneration;
    setState(() {
      _fetchingModels = true;
      _fetchResult = _ModelFetchResult.none;
    });
    try {
      final fetcher = widget.modelFetcher ?? LlmService.fetchModels;
      final models = await fetcher(
        apiFormat: _apiFormat,
        apiKey: apiKey,
        baseUrl: _baseUrlController.text.trim().isNotEmpty
            ? _baseUrlController.text.trim()
            : null,
      );
      if (!mounted || generation != _fetchGeneration) return;
      setState(() {
        _availableModels = models;
        _fetchingModels = false;
        _manualModelInput = models.isEmpty;
        _modelError = null;
        _fetchResult = models.isEmpty
            ? _ModelFetchResult.provider
            : models.every(LlmService.isPresetModel)
                ? _ModelFetchResult.presetFallback
                : _ModelFetchResult.success;
        if (models.isNotEmpty && _modelController.text.isEmpty) {
          _modelController.text = models.first;
        }
      });
    } catch (error) {
      if (!mounted || generation != _fetchGeneration) return;
      final result = _classifyFetchError(error);
      setState(() {
        _fetchingModels = false;
        _manualModelInput = true;
        _fetchResult = result;
        if (result == _ModelFetchResult.auth) {
          _apiKeyError = AppStrings.providerAuthFailure;
        }
        if (result == _ModelFetchResult.endpoint) {
          _baseUrlError = AppStrings.providerEndpointFailure;
        }
      });
    }
  }

  void _cancelFetch() {
    _fetchGeneration += 1;
    setState(() {
      _fetchingModels = false;
      _fetchResult = _ModelFetchResult.cancelled;
    });
  }

  _ModelFetchResult _classifyFetchError(Object error) {
    final value = error.toString().toLowerCase();
    if (value.contains('401') ||
        value.contains('403') ||
        value.contains('auth')) {
      return _ModelFetchResult.auth;
    }
    if (value.contains('timeout') ||
        value.contains('socket') ||
        value.contains('network') ||
        value.contains('connection')) {
      return _ModelFetchResult.network;
    }
    if (value.contains('url') ||
        value.contains('host') ||
        value.contains('endpoint') ||
        value.contains('scheme')) {
      return _ModelFetchResult.endpoint;
    }
    return _ModelFetchResult.provider;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stepTitles = [
      AppStrings.selectApiFormat,
      AppStrings.enterApiKey,
      AppStrings.selectModel,
    ];

    return Scaffold(
      body: SetupAdaptiveRegion(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: FocusTraversalGroup(
            policy: OrderedTraversalPolicy(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!widget.isFirstRun)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: IconButton(
                      tooltip:
                          MaterialLocalizations.of(context).backButtonTooltip,
                      onPressed: () => Navigator.maybePop(context),
                      icon: const Icon(Icons.arrow_back),
                    ),
                  ),
                Expanded(
                  child: SingleChildScrollView(
                    key: const Key('onboarding-scroll'),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildHeader(theme),
                        const SizedBox(height: 16),
                        _buildProgress(theme, stepTitles),
                        const SizedBox(height: 16),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 180),
                          child: _buildStepCard(
                            theme,
                            key: ValueKey(_currentStep),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                FocusTraversalOrder(
                  order: const NumericFocusOrder(100),
                  child: _buildFooter(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Column(
      children: [
        Image.asset('assets/ic_launcher.png', width: 64, height: 64),
        const SizedBox(height: 12),
        Text(
          AppStrings.appName,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          AppStrings.tagline,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildProgress(ThemeData theme, List<String> stepTitles) {
    return Row(
      children: [
        for (var i = 0; i < stepTitles.length; i++) ...[
          Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              height: 5,
              decoration: BoxDecoration(
                color: i <= _currentStep
                    ? theme.colorScheme.primary
                    : theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
          if (i != stepTitles.length - 1) const SizedBox(width: 8),
        ],
      ],
    );
  }

  Widget _buildStepCard(ThemeData theme, {required Key key}) {
    final title = switch (_currentStep) {
      0 => AppStrings.selectApiFormat,
      1 => AppStrings.enterApiKey,
      _ => AppStrings.selectModel,
    };
    final icon = switch (_currentStep) {
      0 => Icons.api,
      1 => Icons.vpn_key,
      _ => Icons.smart_toy,
    };

    return Container(
      key: key,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withAlpha(130),
        borderRadius: BorderRadius.circular(AppRadii.l),
        border: Border.all(color: theme.colorScheme.outline.withAlpha(45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(AppRadii.m),
                ),
                child: Icon(icon, color: theme.colorScheme.onPrimaryContainer),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          switch (_currentStep) {
            0 => _buildProviderStep(theme),
            1 => _buildApiKeyStep(theme),
            _ => _buildModelStep(theme),
          },
        ],
      ),
    );
  }

  Widget _buildProviderStep(ThemeData theme) {
    return Column(
      children: [
        _buildProviderCard(
          theme,
          value: 'anthropic',
          icon: Icons.hexagon_outlined,
          title: 'Anthropic (Claude)',
          subtitle: AppStrings.anthropicSubtitle,
        ),
        const SizedBox(height: 12),
        _buildProviderCard(
          theme,
          value: 'openai',
          icon: Icons.bubble_chart_outlined,
          title: AppStrings.openaiCompatible,
          subtitle: AppStrings.openaiCompatibleSubtitle,
        ),
      ],
    );
  }

  Widget _buildProviderCard(
    ThemeData theme, {
    required String value,
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    final selected = _apiFormat == value;
    return Semantics(
      button: true,
      selected: selected,
      label: title,
      child: InkWell(
        onTap: () => setState(() {
          _apiFormat = value;
          _availableModels = [];
          _manualModelInput = false;
          _fetchResult = _ModelFetchResult.none;
          _modelError = null;
        }),
        borderRadius: BorderRadius.circular(AppRadii.m),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: selected
                ? theme.colorScheme.primaryContainer.withAlpha(120)
                : theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(AppRadii.m),
            border: Border.all(
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline.withAlpha(55),
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(icon,
                  color: selected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        )),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                selected ? Icons.check_circle : Icons.radio_button_unchecked,
                color: selected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildApiKeyStep(ThemeData theme) {
    return Column(
      children: [
        TextField(
          controller: _apiKeyController,
          obscureText: true,
          textInputAction: TextInputAction.next,
          autofillHints: const [AutofillHints.password],
          onChanged: (_) {
            if (_apiKeyError != null) setState(() => _apiKeyError = null);
          },
          decoration: InputDecoration(
            labelText: 'API Key',
            hintText: _apiFormat == 'anthropic' ? 'sk-ant-...' : 'sk-...',
            helperText: AppStrings.apiKeyHelper,
            errorText: _apiKeyError,
            prefixIcon: const Icon(Icons.key),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _baseUrlController,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.done,
          onChanged: (_) {
            if (_baseUrlError != null) setState(() => _baseUrlError = null);
          },
          onSubmitted: (_) => _onStepContinue(),
          decoration: InputDecoration(
            labelText: AppStrings.baseUrlDefaultHint,
            hintText: _apiFormat == 'anthropic'
                ? 'https://api.anthropic.com'
                : 'https://api.openai.com',
            helperText: AppStrings.baseUrlHelper,
            errorText: _baseUrlError,
            prefixIcon: const Icon(Icons.link),
          ),
        ),
      ],
    );
  }

  Widget _buildModelStep(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _fetchingModels
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: CircularProgressIndicator(),
                      ),
                    )
                  : (_availableModels.isNotEmpty && !_manualModelInput)
                      ? DropdownButtonFormField<String>(
                          value: _availableModels.any(
                            (model) => model == _modelController.text,
                          )
                              ? _modelController.text
                              : null,
                          decoration: InputDecoration(
                            labelText: AppStrings.selectModel,
                            prefixIcon: const Icon(Icons.smart_toy),
                            errorText: _modelError,
                          ),
                          items: [
                            ..._availableModels.map((m) => DropdownMenuItem(
                                  value: m,
                                  child:
                                      Text(m, overflow: TextOverflow.ellipsis),
                                )),
                            const DropdownMenuItem(
                              value: '__manual__',
                              child: Text(AppStrings.manualInput),
                            ),
                          ],
                          onChanged: (v) {
                            if (v == '__manual__') {
                              setState(() => _manualModelInput = true);
                            } else if (v != null) {
                              _modelController.text = v;
                              setState(() => _modelError = null);
                            }
                          },
                        )
                      : TextField(
                          controller: _modelController,
                          textInputAction: TextInputAction.done,
                          onChanged: (_) {
                            if (_modelError != null) {
                              setState(() => _modelError = null);
                            }
                          },
                          onSubmitted: (_) => _onStepContinue(),
                          decoration: InputDecoration(
                            labelText: AppStrings.modelName,
                            hintText: AppConstants.defaultModel,
                            prefixIcon: const Icon(Icons.smart_toy),
                            errorText: _modelError,
                          ),
                        ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.tonalIcon(
              style: FilledButton.styleFrom(
                minimumSize: const Size(48, 48),
              ),
              icon: _fetchingModels
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync),
              label: Text(
                _fetchingModels
                    ? AppStrings.cancel
                    : _canRetryModelFetch
                        ? AppStrings.retry
                        : AppStrings.testConnection,
              ),
              onPressed: _fetchingModels ? _cancelFetch : _fetchModels,
            ),
            if (!_fetchingModels && _fetchResult != _ModelFetchResult.none)
              Semantics(
                liveRegion: true,
                child: Text(
                  _fetchResultMessage(),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _fetchResult == _ModelFetchResult.success
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              Text(
                _availableModels.isEmpty
                    ? AppStrings.manualModelHint
                    : AppStrings.modelsFetched(_availableModels.length),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            if (!_fetchingModels &&
                const {
                  _ModelFetchResult.auth,
                  _ModelFetchResult.network,
                  _ModelFetchResult.endpoint,
                  _ModelFetchResult.provider,
                  _ModelFetchResult.presetFallback,
                }.contains(_fetchResult)) ...[
              OutlinedButton(
                onPressed: () => setState(() => _currentStep = 1),
                child: const Text(AppStrings.editConnection),
              ),
              OutlinedButton(
                onPressed: () => setState(() => _manualModelInput = true),
                child: const Text(AppStrings.manualInput),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildFooter() {
    return Row(
      children: [
        if (_currentStep > 0)
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(48, 48),
            ),
            onPressed: () => setState(() => _currentStep--),
            icon: const Icon(Icons.arrow_back),
            label: const Text(AppStrings.previousStep),
          )
        else
          const Spacer(),
        const Spacer(),
        FilledButton.icon(
          key: const Key('onboarding-primary-action'),
          style: FilledButton.styleFrom(
            minimumSize: const Size(48, 48),
          ),
          onPressed: _onStepContinue,
          icon: Icon(_currentStep == 2 ? Icons.check : Icons.arrow_forward),
          label:
              Text(_currentStep == 2 ? AppStrings.done : AppStrings.nextStep),
        ),
      ],
    );
  }

  String _fetchResultMessage() => switch (_fetchResult) {
        _ModelFetchResult.success => AppStrings.providerModelsReady,
        _ModelFetchResult.presetFallback => AppStrings.providerPresetFallback,
        _ModelFetchResult.auth => AppStrings.providerAuthFailure,
        _ModelFetchResult.network => AppStrings.providerNetworkFailure,
        _ModelFetchResult.endpoint => AppStrings.providerEndpointFailure,
        _ModelFetchResult.provider => AppStrings.providerResponseFailure,
        _ModelFetchResult.cancelled => AppStrings.providerFetchCancelled,
        _ModelFetchResult.none => AppStrings.manualModelHint,
      };

  bool get _canRetryModelFetch => const {
        _ModelFetchResult.presetFallback,
        _ModelFetchResult.auth,
        _ModelFetchResult.network,
        _ModelFetchResult.endpoint,
        _ModelFetchResult.provider,
        _ModelFetchResult.cancelled,
      }.contains(_fetchResult);

  bool _validateBaseUrl() {
    final value = _baseUrlController.text.trim();
    if (value.isEmpty) return true;
    final uri = Uri.tryParse(value);
    final valid = uri != null &&
        const {'http', 'https'}.contains(uri.scheme) &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        uri.query.isEmpty &&
        uri.fragment.isEmpty;
    setState(() {
      _baseUrlError = valid ? null : AppStrings.invalidBaseUrl;
    });
    return valid;
  }

  Future<void> _onStepContinue() async {
    if (_currentStep == 1 && _apiKeyController.text.trim().isEmpty) {
      setState(() => _apiKeyError = AppStrings.pleaseEnterApiKey);
      return;
    }
    if (_currentStep == 1 && !_validateBaseUrl()) return;

    if (_currentStep < 2) {
      setState(() => _currentStep++);
      return;
    }

    final model = _modelController.text.trim();
    if (model.isEmpty || model == '__manual__') {
      setState(() => _modelError = AppStrings.pleaseSelectModel);
      return;
    }
    final config = OnboardingConfig(
      apiFormat: _apiFormat,
      apiKey: _apiKeyController.text.trim(),
      baseUrl: _baseUrlController.text.trim(),
      model: model,
    );
    try {
      if (widget.configSaver != null) {
        await widget.configSaver!(config);
      } else {
        final profile = _prefs.activeProfile.copyWith(
          apiFormat: config.apiFormat,
          apiKey: config.apiKey,
          baseUrl: config.baseUrl,
          model: config.model,
        );
        await _prefs.updateActiveProfile(profile);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(AppStrings.providerProfileSaveFailedSafe)),
        );
      }
      return;
    }
    if (!mounted) return;
    if (widget.onComplete != null) {
      widget.onComplete!();
      return;
    }
    Navigator.of(context).pushReplacement(
      CupertinoPageRoute(builder: (_) => const ResponsiveShell()),
    );
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _baseUrlController.dispose();
    _modelController.dispose();
    super.dispose();
  }
}
