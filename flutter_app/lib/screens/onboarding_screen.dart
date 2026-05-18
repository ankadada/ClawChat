import 'package:flutter/material.dart';
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
    return Scaffold(
      appBar: AppBar(
        title: const Text(AppStrings.welcomeTitle),
        automaticallyImplyLeading: !widget.isFirstRun,
      ),
      body: Stepper(
        currentStep: _currentStep,
        onStepContinue: _onStepContinue,
        onStepCancel:
            _currentStep > 0 ? () => setState(() => _currentStep--) : null,
        steps: [
          Step(
            title: const Text(AppStrings.selectApiFormat),
            content: Column(
              children: [
                RadioListTile<String>(
                  title: const Text('Anthropic (Claude)'),
                  subtitle: const Text(AppStrings.anthropicSubtitle),
                  value: 'anthropic',
                  groupValue: _apiFormat,
                  onChanged: (v) => setState(() {
                    _apiFormat = v!;
                    _availableModels = [];
                    _manualModelInput = false;
                  }),
                ),
                RadioListTile<String>(
                  title: const Text(AppStrings.openaiCompatible),
                  subtitle: const Text(AppStrings.openaiCompatibleSubtitle),
                  value: 'openai',
                  groupValue: _apiFormat,
                  onChanged: (v) => setState(() {
                    _apiFormat = v!;
                    _availableModels = [];
                    _manualModelInput = false;
                  }),
                ),
              ],
            ),
          ),
          Step(
            title: const Text(AppStrings.enterApiKey),
            content: Column(
              children: [
                TextField(
                  controller: _apiKeyController,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: 'API Key',
                    hintText:
                        _apiFormat == 'anthropic' ? 'sk-ant-...' : 'sk-...',
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
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: _fetchingModels
                          ? const Center(
                              child: Padding(
                              padding: EdgeInsets.all(16),
                              child: CircularProgressIndicator(),
                            ))
                          : (_availableModels.isNotEmpty && !_manualModelInput)
                              ? DropdownButtonFormField<String>(
                                  value: _availableModels.any((model) =>
                                          LlmService.modelIdFromDisplay(
                                              model) ==
                                          _modelController.text)
                                      ? _modelController.text
                                      : null,
                                  decoration: const InputDecoration(
                                    labelText: AppStrings.selectModel,
                                  ),
                                  items: [
                                    ..._availableModels.map((m) =>
                                        DropdownMenuItem(
                                          value:
                                              LlmService.modelIdFromDisplay(m),
                                          child: Text(m,
                                              overflow: TextOverflow.ellipsis),
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
                                  ),
                                ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.refresh),
                      tooltip: AppStrings.fetchModelsButton,
                      onPressed: _fetchingModels ? null : _fetchModels,
                    ),
                  ],
                ),
              ],
            ),
          ),
          Step(
            title: const Text(AppStrings.stepComplete),
            content: const Text(AppStrings.allReadyMessage),
          ),
        ],
      ),
    );
  }

  Future<void> _onStepContinue() async {
    if (_currentStep == 1 && _apiKeyController.text.trim().isEmpty) {
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

    _prefs.apiFormat = _apiFormat;
    _prefs.apiKey = _apiKeyController.text.trim().isNotEmpty
        ? _apiKeyController.text.trim()
        : null;
    _prefs.baseUrl = _baseUrlController.text.trim().isNotEmpty
        ? _baseUrlController.text.trim()
        : null;
    _prefs.model = _modelController.text.trim().isNotEmpty
        ? LlmService.modelIdFromDisplay(_modelController.text.trim())
        : null;
    _prefs.setupComplete = true;
    _prefs.isFirstRun = false;

    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const ResponsiveShell()),
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
