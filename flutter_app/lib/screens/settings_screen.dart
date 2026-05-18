import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import '../app.dart' show themeNotifier, fontScaleNotifier;
import '../constants.dart';
import '../services/llm_service.dart';
import '../services/memory_service.dart';
import '../services/native_bridge.dart';
import '../services/preferences_service.dart';
import '../services/session_storage.dart';
import '../services/skill_service.dart';
import 'setup_wizard_screen.dart';
import '../l10n/app_strings.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _prefs = PreferencesService();
  final _apiKeyController = TextEditingController();
  final _baseUrlController = TextEditingController();
  final _modelController = TextEditingController();
  final _whisperModelController = TextEditingController();
  final _ttsModelController = TextEditingController();
  String _apiFormat = 'anthropic';
  bool _loading = true;
  String _arch = '';
  Map<String, dynamic> _status = {};
  List<String> _availableModels = [];
  bool _fetchingModels = false;
  bool _manualModelInput = false;
  int _thinkingLevel = 0;
  int _contextLength = 100000;
  double _temperature = 0.7;
  bool _autoCompact = true;
  List<SkillInfo> _skills = [];
  bool _loadingSkills = false;
  Map<String, String> _envVars = {};
  String _themeMode = 'system';
  double _fontScale = 1.0;
  bool _notifyOnComplete = true;
  bool _allowPhoneCall = false;
  bool _allowSms = false;
  List<String> _memories = [];
  bool _loadingMemories = false;

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
    try {
      await _prefs.init();
      _apiKeyController.text = _prefs.apiKey ?? '';
      _baseUrlController.text = _prefs.baseUrl ?? '';
      _modelController.text = _prefs.model ?? AppConstants.defaultModel;
      _apiFormat = _prefs.apiFormat ?? 'anthropic';
      _themeMode = _prefs.themeMode;
      _fontScale = _prefs.fontScale;
      _notifyOnComplete = _prefs.notifyOnComplete;
      _allowPhoneCall = _prefs.allowPhoneCall;
      _allowSms = _prefs.allowSms;
      _whisperModelController.text = _prefs.whisperModel ?? '';
      _ttsModelController.text = _prefs.ttsModel ?? '';

      final budget = _prefs.thinkingBudget;
      _thinkingLevel = _thinkingBudgets.indexOf(budget);
      if (_thinkingLevel < 0) _thinkingLevel = 0;

      _contextLength = _prefs.contextLength;
      _temperature = _prefs.temperature;
      _autoCompact = _prefs.autoCompact;
      _envVars = Map.from(_prefs.envVars);

      try {
        final arch = await NativeBridge.getArch();
        final status = await NativeBridge.getBootstrapStatus();
        if (!mounted) return;
        setState(() {
          _arch = arch;
          _status = status;
          _loading = false;
        });
      } catch (e) {
        if (!mounted) return;
        setState(() => _loading = false);
      }

      _loadSkills();
      _loadMemories();
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.loadSettingsFailed('$e'))),
      );
    }
  }

  void _saveSettings() {
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
    _prefs.envVars = _envVars;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text(AppStrings.settingsSaved)),
    );
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
          _modelController.text = models.first;
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

  Future<void> _loadSkills() async {
    setState(() => _loadingSkills = true);
    _skills = await SkillService.scanSkills();
    if (mounted) setState(() => _loadingSkills = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text(AppStrings.settings)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Row(
                    children: [
                      Text(AppStrings.theme, style: TextStyle(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.bold,
                      )),
                      const Spacer(),
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(value: 'system', icon: Icon(Icons.settings_brightness), label: Text(AppStrings.themeSystem)),
                          ButtonSegment(value: 'light', icon: Icon(Icons.light_mode), label: Text(AppStrings.themeLight)),
                          ButtonSegment(value: 'dark', icon: Icon(Icons.dark_mode), label: Text(AppStrings.themeDark)),
                        ],
                        selected: {_themeMode},
                        onSelectionChanged: (v) {
                          setState(() => _themeMode = v.first);
                          _prefs.themeMode = _themeMode;
                          themeNotifier.value = switch (_themeMode) {
                            'light' => ThemeMode.light,
                            'dark' => ThemeMode.dark,
                            _ => ThemeMode.system,
                          };
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
                      Text('${AppStrings.fontSize}: ${(_fontScale * 100).round()}%'),
                      Slider(
                        value: _fontScale,
                        min: 0.8,
                        max: 1.4,
                        divisions: 6,
                        label: '${(_fontScale * 100).round()}%',
                        onChanged: (v) {
                          setState(() => _fontScale = v);
                          _prefs.fontScale = v;
                          fontScaleNotifier.value = v;
                        },
                      ),
                    ],
                  ),
                ),

                SwitchListTile(
                  title: const Text(AppStrings.notifyOnComplete),
                  subtitle: const Text(AppStrings.notifyOnCompleteSubtitle),
                  value: _notifyOnComplete,
                  onChanged: (v) {
                    setState(() => _notifyOnComplete = v);
                    _prefs.notifyOnComplete = v;
                  },
                ),

                const Divider(),
                _sectionHeader(theme, AppStrings.voiceRecognition),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    AppStrings.voiceRecognitionDesc,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextField(
                    controller: _whisperModelController,
                    decoration: const InputDecoration(
                      labelText: AppStrings.whisperModelLabel,
                      hintText: 'whisper-1',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (v) => _prefs.whisperModel = v.trim(),
                  ),
                ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextField(
                    controller: _ttsModelController,
                    decoration: const InputDecoration(
                      labelText: AppStrings.ttsModelLabel,
                      hintText: 'tts-1',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (v) => _prefs.ttsModel = v.trim(),
                  ),
                ),
                const SizedBox(height: 12),

                const Divider(),
                _sectionHeader(theme, AppStrings.phoneIntegration),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    AppStrings.phoneIntegrationDesc,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                  ),
                ),
                SwitchListTile(
                  title: const Text(AppStrings.allowCall),
                  subtitle: const Text(AppStrings.allowCallSubtitle),
                  value: _allowPhoneCall,
                  onChanged: (v) {
                    setState(() => _allowPhoneCall = v);
                    _prefs.allowPhoneCall = v;
                  },
                ),
                SwitchListTile(
                  title: const Text(AppStrings.allowSms),
                  subtitle: const Text(AppStrings.allowSmsSubtitle),
                  value: _allowSms,
                  onChanged: (v) {
                    setState(() => _allowSms = v);
                    _prefs.allowSms = v;
                  },
                ),

                const Divider(),
                _sectionHeader(theme, AppStrings.apiConfig),

                ListTile(
                  title: const Text(AppStrings.apiFormat),
                  subtitle: Text(_apiFormat == 'anthropic' ? 'Anthropic' : AppStrings.openaiCompatible),
                  trailing: DropdownButton<String>(
                    value: _apiFormat,
                    items: const [
                      DropdownMenuItem(value: 'anthropic', child: Text('Anthropic')),
                      DropdownMenuItem(value: 'openai', child: Text(AppStrings.openaiCompatible)),
                    ],
                    onChanged: (v) => setState(() {
                      _apiFormat = v!;
                      _availableModels = [];
                      _manualModelInput = false;
                    }),
                  ),
                ),

                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: TextField(
                    controller: _apiKeyController,
                    obscureText: true,
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
                                    value: _availableModels.contains(_modelController.text)
                                        ? _modelController.text
                                        : null,
                                    decoration: const InputDecoration(
                                      labelText: AppStrings.selectModel,
                                    ),
                                    items: [
                                      ..._availableModels.map((m) => DropdownMenuItem(
                                        value: m,
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
                          _prefs.thinkingBudget = _thinkingBudgets[_thinkingLevel];
                        },
                      ),
                    ],
                  ),
                ),

                ListTile(
                  title: const Text(AppStrings.contextLength),
                  trailing: DropdownButton<int>(
                    value: _contextLength,
                    items: const [
                      DropdownMenuItem(value: 50000, child: Text(AppStrings.chars50k)),
                      DropdownMenuItem(value: 100000, child: Text(AppStrings.chars100k)),
                      DropdownMenuItem(value: 200000, child: Text(AppStrings.chars200k)),
                    ],
                    onChanged: (v) {
                      setState(() => _contextLength = v!);
                      _prefs.contextLength = _contextLength;
                    },
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
                                _prefs.temperature = _temperature;
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
                    setState(() => _autoCompact = v);
                    _prefs.autoCompact = v;  // persist immediately
                  },
                ),

                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: FilledButton(
                    onPressed: _saveSettings,
                    child: const Text(AppStrings.saveSettings),
                  ),
                ),

                const SizedBox(height: 24),
                const Divider(),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(AppStrings.skills, style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.bold,
                          )),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              TextButton.icon(
                                icon: const Icon(Icons.download, size: 18),
                                label: const Text(AppStrings.installPresets),
                                onPressed: _installPresetSkills,
                              ),
                              IconButton(
                                icon: const Icon(Icons.add),
                                tooltip: AppStrings.importSkill,
                                onPressed: _showImportSkillDialog,
                              ),
                              IconButton(
                                icon: const Icon(Icons.folder_open),
                                tooltip: AppStrings.importLocalSkill,
                                onPressed: _showLocalImportDialog,
                              ),
                              IconButton(
                                icon: const Icon(Icons.refresh),
                                onPressed: _loadSkills,
                              ),
                            ],
                          ),
                        ],
                      ),
                      if (_loadingSkills)
                        const Center(child: Padding(
                          padding: EdgeInsets.all(16),
                          child: CircularProgressIndicator(),
                        ))
                      else if (_skills.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Text(AppStrings.noSkillsFound),
                        )
                      else
                        ..._skills.map((skill) => SwitchListTile(
                          title: Text(skill.name),
                          subtitle: Text(skill.description, maxLines: 2, overflow: TextOverflow.ellipsis),
                          value: skill.enabled,
                          onChanged: (v) async {
                            setState(() => skill.enabled = v);
                            await SkillService.setSkillEnabled(skill.name, v);
                          },
                        )),
                    ],
                  ),
                ),

                const Divider(),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(AppStrings.envVars, style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.bold,
                          )),
                          IconButton(
                            icon: const Icon(Icons.add),
                            onPressed: _addEnvVar,
                          ),
                        ],
                      ),
                      if (_envVars.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Text(AppStrings.noEnvVars, style: TextStyle(color: Colors.grey)),
                        )
                      else
                        ..._envVars.entries.map((e) => ListTile(
                          title: Text(e.key),
                          subtitle: Text('••••••'),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () {
                              setState(() { _envVars.remove(e.key); });
                              _prefs.envVars = _envVars;
                            },
                          ),
                        )),
                    ],
                  ),
                ),

                const Divider(),
                _sectionHeader(theme, AppStrings.dataManagement),
                ListTile(
                  title: const Text(AppStrings.exportAll),
                  leading: const Icon(Icons.upload_file),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _exportAllConversations,
                ),
                ListTile(
                  title: const Text(AppStrings.importConversations),
                  leading: const Icon(Icons.download),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _importConversations,
                ),

                const Divider(),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(AppStrings.memoryManagement, style: TextStyle(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.bold,
                          )),
                          IconButton(
                            icon: const Icon(Icons.add),
                            tooltip: AppStrings.addMemory,
                            onPressed: _addMemory,
                          ),
                        ],
                      ),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          AppStrings.memoryDesc,
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                        ),
                      ),
                      if (_loadingMemories)
                        const Center(child: Padding(
                          padding: EdgeInsets.all(16),
                          child: CircularProgressIndicator(),
                        ))
                      else if (_memories.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Text(AppStrings.noMemories, style: TextStyle(color: Colors.grey)),
                        )
                      else
                        ..._memories.asMap().entries.map((entry) => ListTile(
                          title: Text(entry.value),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _removeMemory(entry.key),
                          ),
                        )),
                    ],
                  ),
                ),

                const Divider(),
                _sectionHeader(theme, AppStrings.systemInfo),

                ListTile(
                  title: const Text(AppStrings.architecture),
                  subtitle: Text(_arch),
                  leading: const Icon(Icons.memory),
                ),
                ListTile(
                  title: const Text('Rootfs'),
                  subtitle: Text(_status['rootfsExists'] == true ? AppStrings.installed : AppStrings.notInstalled),
                  leading: const Icon(Icons.storage),
                ),
                ListTile(
                  title: const Text('Python3'),
                  subtitle: Text(_status['pythonInstalled'] == true ? AppStrings.installed : AppStrings.notInstalled),
                  leading: const Icon(Icons.code),
                ),

                const Divider(),
                _sectionHeader(theme, AppStrings.maintenance),

                ListTile(
                  title: const Text(AppStrings.reinitialize),
                  subtitle: const Text(AppStrings.reinstallAlpine),
                  leading: const Icon(Icons.build),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).pushReplacement(
                    MaterialPageRoute(builder: (_) => const SetupWizardScreen()),
                  ),
                ),

                const Divider(),
                _sectionHeader(theme, AppStrings.about),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Text(AppStrings.appName, style: theme.textTheme.titleLarge),
                      const SizedBox(height: 4),
                      Text('v${AppConstants.version}', style: theme.textTheme.bodySmall),
                      const SizedBox(height: 8),
                      Text(AppStrings.aboutDescription,
                          style: theme.textTheme.bodySmall,
                          textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          TextButton.icon(
                            icon: const Icon(Icons.code, size: 18),
                            label: const Text('GitHub'),
                            onPressed: () => launchUrl(Uri.parse(AppConstants.githubUrl)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text('${AppStrings.license}: ${AppConstants.license}', style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      )),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Future<void> _installPresetSkills() async {
    setState(() => _loadingSkills = true);
    try {
      final count = await SkillService.installPresetSkills();
      await _loadSkills();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppStrings.presetSkillsInstalled(count))),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${AppStrings.installFailed}: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingSkills = false);
    }
  }

  Future<void> _showImportSkillDialog() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(AppStrings.importSkill),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'https://github.com/user/skill-repo.git',
            labelText: AppStrings.skillUrl,
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text(AppStrings.cancel)),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text(AppStrings.importButton),
          ),
        ],
      ),
    );
    if (url == null || url.isEmpty) return;

    setState(() => _loadingSkills = true);
    try {
      await SkillService.importSkillFromUrl(url);
      await _loadSkills();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${AppStrings.skillsLoaded}: $url')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${AppStrings.importFailed}: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingSkills = false);
    }
  }

  Future<void> _addEnvVar() async {
    final keyController = TextEditingController();
    final valueController = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(AppStrings.addEnvVar),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: keyController,
              decoration: const InputDecoration(labelText: AppStrings.envVarName),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: valueController,
              decoration: const InputDecoration(labelText: AppStrings.envVarValue),
              obscureText: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(AppStrings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(AppStrings.confirm),
          ),
        ],
      ),
    );
    if (result == true && keyController.text.isNotEmpty) {
      setState(() {
        _envVars[keyController.text.trim()] = valueController.text;
      });
      _prefs.envVars = _envVars;
    }
  }

  Future<void> _showLocalImportDialog() async {
    final controller = TextEditingController();
    final path = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(AppStrings.importLocalSkill),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: '/sdcard/Download/my-skill.tar.gz',
            labelText: AppStrings.localFilePath,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(AppStrings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text(AppStrings.importButton),
          ),
        ],
      ),
    );
    if (path == null || path.isEmpty) return;

    setState(() => _loadingSkills = true);
    try {
      await SkillService.importSkillFromLocalPath(path);
      await _loadSkills();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(AppStrings.skillsLoaded)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${AppStrings.importFailed}: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingSkills = false);
    }
  }

  Future<void> _loadMemories() async {
    setState(() => _loadingMemories = true);
    _memories = List.from(await MemoryService.getMemories());
    if (mounted) setState(() => _loadingMemories = false);
  }

  Future<void> _exportAllConversations() async {
    try {
      final storage = SessionStorage();
      await storage.init();
      final jsonStr = await storage.exportAllAsJson();
      await Clipboard.setData(ClipboardData(text: jsonStr));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(AppStrings.exportSuccess)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${AppStrings.exportAll}: $e')),
        );
      }
    }
  }

  Future<void> _importConversations() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (result == null || result.files.isEmpty) return;
      final path = result.files.single.path;
      if (path == null) return;
      final file = File(path);
      final jsonStr = await file.readAsString();
      final storage = SessionStorage();
      await storage.init();
      final count = await storage.importFromJson(jsonStr);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppStrings.importSuccess(count))),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${AppStrings.importFailed}: $e')),
        );
      }
    }
  }

  Future<void> _addMemory() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(AppStrings.addMemory),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: AppStrings.memoryHint,
          ),
          maxLines: 3,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(AppStrings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text(AppStrings.confirm),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      await MemoryService.addMemory(result);
      await _loadMemories();
    }
  }

  Future<void> _removeMemory(int index) async {
    await MemoryService.removeMemory(index);
    await _loadMemories();
  }

  Widget _sectionHeader(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _baseUrlController.dispose();
    _modelController.dispose();
    _whisperModelController.dispose();
    _ttsModelController.dispose();
    super.dispose();
  }
}
