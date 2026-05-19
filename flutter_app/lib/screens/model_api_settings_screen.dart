import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart' show AppRadii;
import '../constants.dart';
import '../l10n/app_strings.dart';
import '../services/llm_service.dart';
import '../services/preferences_service.dart';

class ModelApiSettingsScreen extends StatefulWidget {
  const ModelApiSettingsScreen({super.key});

  @override
  State<ModelApiSettingsScreen> createState() => _ModelApiSettingsScreenState();
}

class _ModelApiSettingsScreenState extends State<ModelApiSettingsScreen> {
  final _prefs = PreferencesService();
  final _apiKeyController = TextEditingController();
  final _baseUrlController = TextEditingController();
  final _modelController = TextEditingController();

  String _apiFormat = 'anthropic';
  bool _loading = true;
  List<String> _availableModels = [];
  bool _fetchingModels = false;
  bool _manualModelInput = false;
  int _thinkingLevel = 0;
  int _contextLength = 100000;
  double _temperature = 0.7;
  bool _autoCompact = true;
  Timer? _saveDebounce;
  Timer? _savedIndicatorTimer;
  bool _hasPendingSave = false;
  bool _showSaved = false;

  static const _validContextLengths = [50000, 100000, 200000];
  static const _thinkingBudgets = [0, 4096, 10000, 20000, 32000];
  static const _thinkingLabels = [
    AppStrings.thinkingOff,
    AppStrings.thinkingLow,
    AppStrings.thinkingMedium,
    AppStrings.thinkingHigh,
    AppStrings.thinkingMax,
  ];

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    await _prefs.init();
    if (!mounted) return;
    final budget = _prefs.thinkingBudget;
    final contextLength = _prefs.contextLength;
    setState(() {
      _apiKeyController.text = _prefs.apiKey ?? '';
      _baseUrlController.text = _prefs.baseUrl ?? '';
      _modelController.text = _prefs.model ?? AppConstants.defaultModel;
      _apiFormat = _prefs.apiFormat ?? 'anthropic';
      _thinkingLevel = _thinkingBudgets.indexOf(budget);
      if (_thinkingLevel < 0) _thinkingLevel = 0;
      _contextLength = _validContextLengths.contains(contextLength)
          ? contextLength
          : 100000;
      _temperature = _prefs.temperature;
      _autoCompact = _prefs.autoCompact;
      _loading = false;
    });
  }

  void _scheduleSave() {
    _hasPendingSave = true;
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 500), _flushSave);
  }

  void _flushSave({bool showIndicator = true}) {
    if (!_hasPendingSave) return;
    _saveDebounce?.cancel();
    _saveDebounce = null;
    _hasPendingSave = false;

    _prefs.apiKey = _apiKeyController.text.trim().isNotEmpty
        ? _apiKeyController.text.trim()
        : null;
    _prefs.baseUrl = _baseUrlController.text.trim().isNotEmpty
        ? _baseUrlController.text.trim()
        : null;
    _prefs.model = _modelController.text.trim().isNotEmpty
        ? _modelController.text.trim()
        : null;
    _prefs.apiFormat = _apiFormat;
    _prefs.thinkingBudget = _thinkingBudgets[_thinkingLevel];
    _prefs.contextLength = _contextLength;
    _prefs.temperature = _temperature;
    _prefs.autoCompact = _autoCompact;

    if (!showIndicator || !mounted) return;
    setState(() => _showSaved = true);
    _savedIndicatorTimer?.cancel();
    _savedIndicatorTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _showSaved = false);
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
      final showingPresets = models.any(LlmService.isPresetModel);
      setState(() {
        _availableModels = models;
        _fetchingModels = false;
        _manualModelInput = models.isEmpty;
        if (models.isNotEmpty && _modelController.text.isEmpty) {
          _modelController.text = LlmService.modelIdFromDisplay(models.first);
          _scheduleSave();
        }
      });
      if (showingPresets) {
        _showModelFetchNotice(AppStrings.modelFetchPresetNotice);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _fetchingModels = false;
        _manualModelInput = true;
      });
      _showModelFetchNotice(AppStrings.modelFetchFailed(_briefError(e)));
    }
  }

  void _showModelFetchNotice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  String _briefError(Object error) {
    final text = error.toString().replaceFirst('Exception: ', '');
    return text.length > 160 ? '${text.substring(0, 160)}...' : text;
  }

  Widget _settingsGroup(ThemeData theme, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withAlpha(120),
          borderRadius: BorderRadius.circular(AppRadii.m),
          border: Border.all(color: theme.colorScheme.outline.withAlpha(45)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text(AppStrings.settingsModelApi),
        actions: [
          Center(
            child: AnimatedOpacity(
              opacity: _showSaved ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Text(
                  AppStrings.saved,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: 4),
              children: [
                _settingsGroup(theme, [
                  ListTile(
                    title: const Text(AppStrings.apiFormat),
                    subtitle: Text(_apiFormat == 'anthropic'
                        ? 'Anthropic'
                        : AppStrings.openaiCompatible),
                    trailing: DropdownButton<String>(
                      value: _apiFormat,
                      items: const [
                        DropdownMenuItem(value: 'anthropic', child: Text('Anthropic')),
                        DropdownMenuItem(value: 'openai', child: Text(AppStrings.openaiCompatible)),
                      ],
                      onChanged: (v) {
                        if (v == null) return;
                        setState(() {
                          _apiFormat = v;
                          _availableModels = [];
                          _manualModelInput = false;
                        });
                        _scheduleSave();
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: TextField(
                      controller: _apiKeyController,
                      obscureText: true,
                      onChanged: (_) => _scheduleSave(),
                      decoration: InputDecoration(
                        labelText: 'API Key',
                        hintText: _apiFormat == 'anthropic' ? 'sk-ant-...' : 'sk-...',
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: TextField(
                      controller: _baseUrlController,
                      onChanged: (_) => _scheduleSave(),
                      decoration: InputDecoration(
                        labelText: AppStrings.baseUrlOptional,
                        hintText: _apiFormat == 'anthropic'
                            ? 'https://api.anthropic.com'
                            : 'https://api.openai.com',
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: _fetchingModels
                              ? const Center(child: Padding(
                                  padding: EdgeInsets.all(16),
                                  child: CircularProgressIndicator(),
                                ))
                              : (_availableModels.isNotEmpty && !_manualModelInput)
                                  ? DropdownButtonFormField<String>(
                                      value: _availableModels.any((m) =>
                                              LlmService.modelIdFromDisplay(m) ==
                                              _modelController.text)
                                          ? _modelController.text
                                          : null,
                                      decoration: const InputDecoration(
                                        labelText: AppStrings.selectModel,
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
                                          _scheduleSave();
                                        }
                                      },
                                    )
                                  : TextField(
                                      controller: _modelController,
                                      onChanged: (_) => _scheduleSave(),
                                      decoration: InputDecoration(
                                        labelText: AppStrings.model,
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
                  ),
                ]),
                _settingsGroup(theme, [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${AppStrings.thinkingIntensity}: ${_thinkingLabels[_thinkingLevel]}'),
                        Slider(
                          value: _thinkingLevel.toDouble(),
                          min: 0,
                          max: 4,
                          divisions: 4,
                          label: _thinkingLabels[_thinkingLevel],
                          onChanged: (v) {
                            setState(() => _thinkingLevel = v.round());
                            _scheduleSave();
                          },
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(AppStrings.contextLength),
                        const SizedBox(height: 8),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: SegmentedButton<int>(
                            segments: const [
                              ButtonSegment(value: 50000, label: Text(AppStrings.chars50k)),
                              ButtonSegment(value: 100000, label: Text(AppStrings.chars100k)),
                              ButtonSegment(value: 200000, label: Text(AppStrings.chars200k)),
                            ],
                            selected: {_contextLength},
                            onSelectionChanged: (v) {
                              HapticFeedback.lightImpact();
                              setState(() => _contextLength = v.first);
                              _scheduleSave();
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${AppStrings.temperature}: ${_temperature.toStringAsFixed(1)}'),
                        Row(
                          children: [
                            const Text(AppStrings.temperatureLow, style: TextStyle(fontSize: 12)),
                            Expanded(
                              child: Slider(
                                value: _temperature,
                                min: 0.0,
                                max: 1.0,
                                divisions: 10,
                                label: _temperature.toStringAsFixed(1),
                                onChanged: (v) {
                                  setState(() => _temperature = v);
                                  _scheduleSave();
                                },
                              ),
                            ),
                            const Text(AppStrings.temperatureHigh, style: TextStyle(fontSize: 12)),
                          ],
                        ),
                      ],
                    ),
                  ),
                  SwitchListTile(
                    title: const Text(AppStrings.autoCompact),
                    subtitle: const Text(AppStrings.autoCompactSubtitle),
                    value: _autoCompact,
                    onChanged: (v) {
                      HapticFeedback.lightImpact();
                      setState(() => _autoCompact = v);
                      _scheduleSave();
                    },
                  ),
                ]),
              ],
            ),
    );
  }

  @override
  void dispose() {
    _flushSave(showIndicator: false);
    _saveDebounce?.cancel();
    _savedIndicatorTimer?.cancel();
    _apiKeyController.dispose();
    _baseUrlController.dispose();
    _modelController.dispose();
    super.dispose();
  }
}
