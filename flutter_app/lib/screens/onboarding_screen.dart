import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import '../constants.dart';
import '../services/llm_service.dart';
import '../services/preferences_service.dart';
import '../app.dart';
import '../l10n/app_strings.dart';

class OnboardingScreen extends StatefulWidget {
  final bool isFirstRun;
  const OnboardingScreen({super.key, this.isFirstRun = false});

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
  bool _showApiKeyError = false;

  @override
  void initState() {
    super.initState();
    _initPrefs();
  }

  Future<void> _initPrefs() async {
    await _prefs.init();
    _loadExistingSettings();
  }

  void _loadExistingSettings() {
    if (!mounted) return;
    setState(() {
      _apiFormat = _prefs.apiFormat ?? 'anthropic';
      _apiKeyController.text = _prefs.apiKey ?? '';
      _baseUrlController.text = _prefs.baseUrl ?? '';
      _modelController.text = _prefs.model ?? '';
    });
  }

  Future<void> _fetchModels() async {
    final apiKey = _apiKeyController.text.trim();
    if (apiKey.isEmpty) return;

    setState(() => _fetchingModels = true);
    try {
      final models = await LlmService.fetchModels(
        apiFormat: _apiFormat,
        apiKey: apiKey,
        baseUrl: _baseUrlController.text.trim().isNotEmpty
            ? _baseUrlController.text.trim()
            : null,
      );
      if (!mounted) return;
      setState(() {
        _availableModels = models;
        _fetchingModels = false;
        _manualModelInput = models.isEmpty;
        if (models.isNotEmpty && _modelController.text.isEmpty) {
          _modelController.text = LlmService.modelIdFromDisplay(models.first);
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _fetchingModels = false;
        _manualModelInput = true;
      });
    }
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
      appBar: AppBar(
        title: const Text(AppStrings.welcomeTitle),
        automaticallyImplyLeading: !widget.isFirstRun,
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight - 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildHeader(theme),
                    const SizedBox(height: 24),
                    _buildProgress(theme, stepTitles),
                    const SizedBox(height: 24),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      child: _buildStepCard(theme, key: ValueKey(_currentStep)),
                    ),
                    const SizedBox(height: 20),
                    _buildFooter(),
                  ],
                ),
              ),
            );
          },
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
    return InkWell(
      onTap: () => setState(() {
        _apiFormat = value;
        _availableModels = [];
        _manualModelInput = false;
      }),
      borderRadius: BorderRadius.circular(AppRadii.m),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
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
            Icon(icon, color: selected
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleSmall?.copyWith(
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
    );
  }

  Widget _buildApiKeyStep(ThemeData theme) {
    return Column(
      children: [
        TextField(
          controller: _apiKeyController,
          obscureText: true,
          onChanged: (_) {
            if (_showApiKeyError) setState(() => _showApiKeyError = false);
          },
          decoration: InputDecoration(
            labelText: 'API Key',
            hintText: _apiFormat == 'anthropic' ? 'sk-ant-...' : 'sk-...',
            helperText: AppStrings.apiKeyHelper,
            errorText: _showApiKeyError && _apiKeyController.text.trim().isEmpty
                ? AppStrings.pleaseEnterApiKey
                : null,
            prefixIcon: const Icon(Icons.key),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _baseUrlController,
          decoration: InputDecoration(
            labelText: AppStrings.baseUrlDefaultHint,
            hintText: _apiFormat == 'anthropic'
                ? 'https://api.anthropic.com'
                : 'https://api.openai.com',
            helperText: AppStrings.baseUrlHelper,
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
                          value: _availableModels.any((model) =>
                                  LlmService.modelIdFromDisplay(model) ==
                                  _modelController.text)
                              ? _modelController.text
                              : null,
                          decoration: const InputDecoration(
                            labelText: AppStrings.selectModel,
                            prefixIcon: Icon(Icons.smart_toy),
                          ),
                          items: [
                            ..._availableModels.map((m) => DropdownMenuItem(
                                  value: LlmService.modelIdFromDisplay(m),
                                  child: Text(m, overflow: TextOverflow.ellipsis),
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
                            }
                          },
                        )
                      : TextField(
                          controller: _modelController,
                          decoration: InputDecoration(
                            labelText: AppStrings.modelName,
                            hintText: AppConstants.defaultModel,
                            prefixIcon: const Icon(Icons.smart_toy),
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
              icon: _fetchingModels
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync),
              label: Text(_fetchingModels
                  ? AppStrings.fetchingModels
                  : AppStrings.testConnection),
              onPressed: _fetchingModels ? null : _fetchModels,
            ),
            Text(
              _availableModels.isEmpty
                  ? AppStrings.manualModelHint
                  : AppStrings.modelsFetched(_availableModels.length),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
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
            onPressed: () => setState(() => _currentStep--),
            icon: const Icon(Icons.arrow_back),
            label: const Text(AppStrings.previousStep),
          )
        else
          const Spacer(),
        const Spacer(),
        FilledButton.icon(
          onPressed: _onStepContinue,
          icon: Icon(_currentStep == 2 ? Icons.check : Icons.arrow_forward),
          label: Text(_currentStep == 2 ? AppStrings.done : AppStrings.nextStep),
        ),
      ],
    );
  }

  Future<void> _onStepContinue() async {
    if (_currentStep == 1 && _apiKeyController.text.trim().isEmpty) {
      setState(() => _showApiKeyError = true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(AppStrings.pleaseEnterApiKey)),
        );
      }
      return;
    }

    if (_currentStep < 2) {
      setState(() => _currentStep++);
      return;
    }

    final profile = _prefs.activeProfile.copyWith(
      apiFormat: _apiFormat,
      apiKey: _apiKeyController.text.trim(),
      baseUrl: _baseUrlController.text.trim(),
      model: _modelController.text.trim().isNotEmpty
          ? LlmService.modelIdFromDisplay(_modelController.text.trim())
          : '',
    );
    try {
      await _prefs.updateActiveProfile(profile);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppStrings.providerProfileSaveFailed('$e'))),
        );
      }
      return;
    }
    _prefs.setupComplete = true;
    _prefs.isFirstRun = false;

    if (!mounted) return;
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
