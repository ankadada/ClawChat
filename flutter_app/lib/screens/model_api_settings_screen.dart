import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app.dart' show AppRadii;
import '../constants.dart';
import '../l10n/app_strings.dart';
import '../models/provider_profile.dart';
import '../providers/chat_provider.dart';
import '../services/llm_service.dart';
import '../services/preferences_service.dart';

class ModelApiSettingsScreen extends StatefulWidget {
  final String? initialProfileId;

  const ModelApiSettingsScreen({super.key, this.initialProfileId});

  @override
  State<ModelApiSettingsScreen> createState() => _ModelApiSettingsScreenState();
}

class _ModelApiSettingsScreenState extends State<ModelApiSettingsScreen> {
  final _prefs = PreferencesService();
  final _nameController = TextEditingController();
  final _apiKeyController = TextEditingController();
  final _baseUrlController = TextEditingController();
  final _modelController = TextEditingController();

  List<ProviderProfile> _profiles = [];
  String? _activeProfileId;
  String? _editingProfileId;
  String _apiFormat = ProviderProfile.anthropicFormat;
  bool _loading = true;
  List<String> _availableModels = [];
  bool _fetchingModels = false;
  bool _manualModelInput = false;
  int _thinkingLevel = 0;
  int _contextLength = AppConstants.defaultContextLength;
  double _temperature = AppConstants.defaultTemperature;
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
    final profiles = _prefs.profiles;
    final activeProfileId = _prefs.activeProfileId ?? profiles.first.id;
    final initialProfileId = widget.initialProfileId;
    final editingProfileId =
        profiles.any((profile) => profile.id == initialProfileId)
            ? initialProfileId
            : activeProfileId;
    final editingProfile = profiles.firstWhere(
      (profile) => profile.id == editingProfileId,
      orElse: () => profiles.first,
    );
    setState(() {
      _profiles = profiles;
      _activeProfileId = activeProfileId;
      _editingProfileId = editingProfile.id;
      _loadProfileIntoForm(editingProfile);
      final contextLength = _prefs.contextLength;
      _contextLength = _validContextLengths.contains(contextLength)
          ? contextLength
          : AppConstants.defaultContextLength;
      _autoCompact = _prefs.autoCompact;
      _loading = false;
    });
  }

  ProviderProfile? get _editingProfile {
    final id = _editingProfileId;
    if (id == null) return null;
    for (final profile in _profiles) {
      if (profile.id == id) return profile;
    }
    return null;
  }

  ProviderProfile _profileById(String id) {
    return _profiles.firstWhere(
      (profile) => profile.id == id,
      orElse: () => _profiles.first,
    );
  }

  void _loadProfileIntoForm(ProviderProfile profile) {
    _nameController.text = profile.name;
    _apiKeyController.text = profile.apiKey;
    _baseUrlController.text = profile.baseUrl;
    _modelController.text = profile.effectiveModel;
    _apiFormat = profile.apiFormat;
    _thinkingLevel = _thinkingBudgets.indexOf(profile.thinkingBudget);
    if (_thinkingLevel < 0) _thinkingLevel = 0;
    _temperature = profile.temperature;
    _availableModels = [];
    _manualModelInput = false;
  }

  void _scheduleSave() {
    _hasPendingSave = true;
    _saveDebounce?.cancel();
    _saveDebounce = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(_flushSave()),
    );
  }

  Future<bool> _flushSave({
    bool showIndicator = true,
    bool showErrors = true,
  }) async {
    if (!_hasPendingSave) return true;
    _saveDebounce?.cancel();
    _saveDebounce = null;
    _hasPendingSave = false;

    final editingId = _editingProfileId;
    final index = _profiles.indexWhere((profile) => profile.id == editingId);
    if (index >= 0) {
      _profiles[index] = _profiles[index].copyWith(
        name: _nameController.text.trim(),
        apiKey: _apiKeyController.text.trim(),
        baseUrl: _baseUrlController.text.trim(),
        model: _modelController.text.trim(),
        apiFormat: _apiFormat,
        thinkingBudget: _thinkingBudgets[_thinkingLevel],
        temperature: _temperature,
      );
      try {
        await _prefs.setProfiles(_profiles);
        await _prefs.setActiveProfileId(_activeProfileId);
      } catch (e) {
        if (showErrors) _showProfileSaveError(e);
        await _loadSettings();
        return false;
      }
    }
    _prefs.contextLength = _contextLength;
    _prefs.autoCompact = _autoCompact;

    if (!showIndicator || !mounted) return true;
    setState(() => _showSaved = true);
    _savedIndicatorTimer?.cancel();
    _savedIndicatorTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _showSaved = false);
    });
    return true;
  }

  void _showProfileSaveError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          AppStrings.providerProfileSaveFailed(_briefError(error)),
        ),
      ),
    );
  }

  Future<void> _editProfile(
    ProviderProfile profile, {
    bool makeActive = false,
  }) async {
    final chatProvider = context.read<ChatProvider>();
    if (!await _flushSave(showIndicator: false)) return;
    HapticFeedback.selectionClick();
    final freshProfile = _profileById(profile.id);
    if (makeActive) {
      if (freshProfile.apiKey.trim().isEmpty) {
        if (!mounted) return;
        setState(() {
          _editingProfileId = freshProfile.id;
          _loadProfileIntoForm(freshProfile);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:
                Text(AppStrings.profileNeedsApiKey(freshProfile.displayName)),
          ),
        );
        return;
      }
      try {
        await chatProvider.switchProfile(freshProfile.id);
      } catch (e) {
        _showProfileSaveError(e);
        return;
      }
      if (!mounted) return;
    }
    setState(() {
      if (makeActive) {
        _activeProfileId = freshProfile.id;
      }
      _editingProfileId = freshProfile.id;
      _loadProfileIntoForm(freshProfile);
    });
  }

  Future<void> _addProfile() async {
    if (!await _flushSave(showIndicator: false)) return;
    HapticFeedback.lightImpact();
    final profile =
        ProviderProfile.defaults(name: AppStrings.newProviderProfile);
    setState(() {
      _profiles = [..._profiles, profile];
      _editingProfileId = profile.id;
      _loadProfileIntoForm(profile);
    });
    try {
      await _prefs.setProfiles(_profiles);
    } catch (e) {
      _showProfileSaveError(e);
      await _loadSettings();
    }
  }

  Future<bool> _confirmDeleteProfile(ProviderProfile profile) async {
    if (_profiles.length <= 1) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(AppStrings.cannotDeleteLastProfile)),
        );
      }
      return false;
    }

    final isActive = profile.id == _activeProfileId;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          isActive
              ? AppStrings.deleteActiveProfileTitle
              : AppStrings.deleteProviderProfileTitle,
        ),
        content: Text(
          isActive
              ? AppStrings.deleteActiveProfileConfirm(profile.displayName)
              : AppStrings.deleteProviderProfileConfirm(profile.displayName),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(AppStrings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(AppStrings.delete),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _deleteProfile(ProviderProfile profile) async {
    final chatProvider = context.read<ChatProvider>();
    if (!await _flushSave(showIndicator: false)) return;
    final remaining = _profiles.where((p) => p.id != profile.id).toList();
    if (remaining.isEmpty) return;
    final newActiveId =
        _activeProfileId == profile.id ? remaining.first.id : _activeProfileId;
    final newEditingId =
        _editingProfileId == profile.id ? newActiveId : _editingProfileId;
    final editingProfile = remaining.firstWhere(
      (p) => p.id == newEditingId,
      orElse: () => remaining.first,
    );

    setState(() {
      _profiles = remaining;
      _activeProfileId = newActiveId;
      _editingProfileId = editingProfile.id;
      _loadProfileIntoForm(editingProfile);
    });
    try {
      await _prefs.setProfiles(_profiles);
      if (_activeProfileId != null) {
        await chatProvider.switchProfile(_activeProfileId!);
      }
    } catch (e) {
      _showProfileSaveError(e);
      await _loadSettings();
    }
  }

  Future<void> _fetchModels() async {
    final apiKey = _apiKeyController.text.trim();
    if (apiKey.isEmpty) {
      _showModelFetchNotice(AppStrings.apiKeyRequiredToUse);
      return;
    }

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
          _modelController.text = models.first;
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

  Widget _groupHeader(
    ThemeData theme,
    String title, {
    Widget? trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (trailing != null) trailing,
        ],
      ),
    );
  }

  Widget _profileList(ThemeData theme) {
    return _settingsGroup(theme, [
      _groupHeader(
        theme,
        AppStrings.providerProfiles,
        trailing: IconButton(
          icon: const Icon(Icons.add),
          tooltip: AppStrings.addProviderProfile,
          onPressed: () => unawaited(_addProfile()),
        ),
      ),
      ..._profiles.map((profile) => _profileTile(theme, profile)),
    ]);
  }

  Widget _profileTile(ThemeData theme, ProviderProfile profile) {
    final isActive = profile.id == _activeProfileId;
    final isEditing = profile.id == _editingProfileId;
    final needsApiKey = profile.apiKey.trim().isEmpty;
    final formatLabel = profile.apiFormat == ProviderProfile.openaiFormat
        ? AppStrings.openaiCompatible
        : 'Anthropic';

    return Dismissible(
      key: ValueKey(profile.id),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) async {
        if (!await _confirmDeleteProfile(profile)) return false;
        await _deleteProfile(profile);
        return false;
      },
      background: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: theme.colorScheme.error,
          borderRadius: BorderRadius.circular(AppRadii.s),
        ),
        child: Icon(Icons.delete, color: theme.colorScheme.onError),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: isEditing
                ? theme.colorScheme.primary.withAlpha(18)
                : theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(AppRadii.s),
            border: Border.all(
              color: isActive
                  ? theme.colorScheme.primary.withAlpha(160)
                  : theme.colorScheme.outline.withAlpha(40),
            ),
          ),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: theme.colorScheme.primary.withAlpha(20),
              foregroundColor: theme.colorScheme.primary,
              child: Icon(
                profile.apiFormat == ProviderProfile.openaiFormat
                    ? Icons.api
                    : Icons.auto_awesome,
              ),
            ),
            title: Row(
              children: [
                Expanded(
                  child: Text(
                    profile.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                if (isActive)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Icon(
                      Icons.check_circle,
                      size: 18,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                if (needsApiKey)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Tooltip(
                      message: AppStrings.apiKeyRequiredToUse,
                      child: Icon(
                        Icons.warning_amber_outlined,
                        size: 18,
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
            subtitle: Text(
              needsApiKey
                  ? '$formatLabel · ${profile.effectiveModel}\n${AppStrings.apiKeyRequiredToUse}'
                  : '$formatLabel · ${profile.effectiveModel}',
              maxLines: needsApiKey ? 2 : 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: AppStrings.editProviderProfile,
              onPressed: () => unawaited(_editProfile(profile)),
            ),
            onTap: () => unawaited(_editProfile(profile, makeActive: true)),
          ),
        ),
      ),
    );
  }

  Widget _profileForm(ThemeData theme) {
    final profile = _editingProfile;
    if (profile == null) return const SizedBox.shrink();

    return _settingsGroup(theme, [
      _groupHeader(theme, AppStrings.providerProfileDetails),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: TextField(
          controller: _nameController,
          onChanged: (_) => _scheduleSave(),
          decoration: const InputDecoration(
            labelText: AppStrings.providerProfileName,
          ),
        ),
      ),
      ListTile(
        title: const Text(AppStrings.apiFormat),
        subtitle: Text(_apiFormat == ProviderProfile.anthropicFormat
            ? 'Anthropic'
            : AppStrings.openaiCompatible),
        trailing: DropdownButton<String>(
          value: _apiFormat,
          items: const [
            DropdownMenuItem(
              value: ProviderProfile.anthropicFormat,
              child: Text('Anthropic'),
            ),
            DropdownMenuItem(
              value: ProviderProfile.openaiFormat,
              child: Text(AppStrings.openaiCompatible),
            ),
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
          decoration: InputDecoration(
            labelText: 'API Key',
            hintText: _apiFormat == ProviderProfile.anthropicFormat
                ? 'sk-ant-...'
                : 'sk-...',
            errorText: _apiKeyController.text.trim().isEmpty
                ? AppStrings.apiKeyRequiredToUse
                : null,
          ),
          onChanged: (_) {
            setState(() {});
            _scheduleSave();
          },
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: TextField(
          controller: _baseUrlController,
          onChanged: (_) => _scheduleSave(),
          decoration: InputDecoration(
            labelText: AppStrings.baseUrlOptional,
            hintText: _apiFormat == ProviderProfile.anthropicFormat
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
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: CircularProgressIndicator(),
                      ),
                    )
                  : (_availableModels.isNotEmpty && !_manualModelInput)
                      ? DropdownButtonFormField<String>(
                          value: _availableModels.any(
                            (m) => m == _modelController.text,
                          )
                              ? _modelController.text
                              : null,
                          decoration: const InputDecoration(
                            labelText: AppStrings.selectModel,
                          ),
                          items: [
                            ..._availableModels.map(
                              (m) => DropdownMenuItem(
                                value: m,
                                child: Text(
                                  m,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
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
                          decoration: const InputDecoration(
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
    ]);
  }

  Widget _advancedSettings(ThemeData theme) {
    return _settingsGroup(theme, [
      _groupHeader(theme, AppStrings.advancedModelSettings),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${AppStrings.thinkingIntensity}: '
                '${_thinkingLabels[_thinkingLevel]}'),
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
            const Text(AppStrings.contextLength),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 50000, label: Text(AppStrings.chars50k)),
                  ButtonSegment(
                    value: 100000,
                    label: Text(AppStrings.chars100k),
                  ),
                  ButtonSegment(
                    value: 200000,
                    label: Text(AppStrings.chars200k),
                  ),
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
            Text('${AppStrings.temperature}: '
                '${_temperature.toStringAsFixed(1)}'),
            Row(
              children: [
                const Text(
                  AppStrings.temperatureLow,
                  style: TextStyle(fontSize: 12),
                ),
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
                const Text(
                  AppStrings.temperatureHigh,
                  style: TextStyle(fontSize: 12),
                ),
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
    ]);
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
                _profileList(theme),
                _profileForm(theme),
                _advancedSettings(theme),
              ],
            ),
    );
  }

  @override
  void dispose() {
    unawaited(_flushSave(showIndicator: false, showErrors: false));
    _saveDebounce?.cancel();
    _savedIndicatorTimer?.cancel();
    _nameController.dispose();
    _apiKeyController.dispose();
    _baseUrlController.dispose();
    _modelController.dispose();
    super.dispose();
  }
}
