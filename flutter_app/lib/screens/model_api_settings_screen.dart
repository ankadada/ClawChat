import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app.dart' show AppRadii;
import '../constants.dart';
import '../l10n/app_strings.dart';
import '../services/capability_summary.dart';
import '../models/provider_profile.dart';
import '../providers/chat_provider.dart';
import '../services/fallback_model_selection.dart';
import '../services/llm_service.dart';
import '../services/preferences_service.dart';

class ModelApiSettingsScreen extends StatefulWidget {
  final String? initialProfileId;
  final ModelListFetcher? modelFetcher;

  const ModelApiSettingsScreen({
    super.key,
    this.initialProfileId,
    this.modelFetcher,
  });

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
  int _contextTokenBudget = AppConstants.defaultContextTokenBudget;
  double _temperature = AppConstants.defaultTemperature;
  bool _autoCompact = true;
  Timer? _saveDebounce;
  Timer? _savedIndicatorTimer;
  bool _hasPendingSave = false;
  bool _showSaved = false;

  static const _validContextTokenBudgets = [32768, 65536, 200000];
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
      final contextTokenBudget = _prefs.contextTokenBudget;
      _contextTokenBudget =
          _validContextTokenBudgets.contains(contextTokenBudget)
              ? contextTokenBudget
              : AppConstants.defaultContextTokenBudget;
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

  ProviderProfile _draftProfileForSummary() {
    final profile = _editingProfile ?? ProviderProfile.defaults();
    return profile.copyWith(
      apiFormat: _apiFormat,
      baseUrl: _baseUrlController.text.trim(),
      model: _modelController.text.trim(),
    );
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
    _prefs.contextTokenBudget = _contextTokenBudget;
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

  Future<void> _addFallbackTarget() async {
    final profile = _editingProfile;
    if (profile == null) return;
    final candidates = _profiles.where((p) => p.id != profile.id).toList();
    if (candidates.isEmpty) {
      _showModelFetchNotice(AppStrings.noFallbackProfilesAvailable);
      return;
    }
    final target = await _showFallbackTargetDialog(candidates: candidates);
    if (target == null) return;
    _replaceEditingFallbackTargets([
      ...profile.fallbackTargets,
      target,
    ]);
  }

  Future<void> _editFallbackTarget(int index) async {
    final profile = _editingProfile;
    if (profile == null ||
        index < 0 ||
        index >= profile.fallbackTargets.length) {
      return;
    }
    final candidates = _profiles.where((p) => p.id != profile.id).toList();
    if (candidates.isEmpty) {
      _showModelFetchNotice(AppStrings.noFallbackProfilesAvailable);
      return;
    }
    final target = await _showFallbackTargetDialog(
      candidates: candidates,
      initial: profile.fallbackTargets[index],
    );
    if (target == null) return;
    final next = [...profile.fallbackTargets];
    next[index] = target;
    _replaceEditingFallbackTargets(next);
  }

  Future<ModelFallbackTarget?> _showFallbackTargetDialog({
    required List<ProviderProfile> candidates,
    ModelFallbackTarget? initial,
  }) async {
    return showDialog<ModelFallbackTarget>(
      context: context,
      builder: (ctx) => _FallbackTargetDialog(
        candidates: candidates,
        initial: initial,
        modelFetcher: widget.modelFetcher ?? LlmService.fetchModels,
      ),
    );
  }

  void _replaceEditingFallbackTargets(List<ModelFallbackTarget> targets) {
    final editingId = _editingProfileId;
    final index = _profiles.indexWhere((profile) => profile.id == editingId);
    if (index < 0) return;
    setState(() {
      _profiles[index] = _profiles[index].copyWith(
        fallbackTargets: _sanitizeFallbackTargetsForProfile(
          _profiles[index],
          targets,
        ),
      );
    });
    _scheduleSave();
  }

  List<ModelFallbackTarget> _sanitizeFallbackTargetsForProfile(
    ProviderProfile profile,
    List<ModelFallbackTarget> targets,
  ) {
    final ids = _profiles.map((p) => p.id).toSet();
    final seen = <String>{};
    final sanitized = <ModelFallbackTarget>[];
    for (final target in targets) {
      final targetId = target.targetProfileId.trim();
      if (targetId.isEmpty ||
          targetId == profile.id ||
          !ids.contains(targetId)) {
        continue;
      }
      final modelOverride = target.modelOverride.trim();
      final key = '$targetId\n$modelOverride';
      if (!seen.add(key)) continue;
      sanitized.add(target.copyWith(
        targetProfileId: targetId,
        modelOverride: modelOverride,
      ));
    }
    return sanitized;
  }

  void _toggleAllFallbackTargets(bool enabled) {
    final profile = _editingProfile;
    if (profile == null || profile.fallbackTargets.isEmpty) return;
    _replaceEditingFallbackTargets(
      profile.fallbackTargets
          .map((target) => target.copyWith(enabled: enabled))
          .toList(),
    );
  }

  void _toggleFallbackTarget(int index, bool enabled) {
    final profile = _editingProfile;
    if (profile == null ||
        index < 0 ||
        index >= profile.fallbackTargets.length) {
      return;
    }
    final next = [...profile.fallbackTargets];
    next[index] = next[index].copyWith(enabled: enabled);
    _replaceEditingFallbackTargets(next);
  }

  void _moveFallbackTarget(int index, int delta) {
    final profile = _editingProfile;
    if (profile == null) return;
    final targetIndex = index + delta;
    if (index < 0 ||
        index >= profile.fallbackTargets.length ||
        targetIndex < 0 ||
        targetIndex >= profile.fallbackTargets.length) {
      return;
    }
    final next = [...profile.fallbackTargets];
    final item = next.removeAt(index);
    next.insert(targetIndex, item);
    _replaceEditingFallbackTargets(next);
  }

  void _removeFallbackTarget(int index) {
    final profile = _editingProfile;
    if (profile == null ||
        index < 0 ||
        index >= profile.fallbackTargets.length) {
      return;
    }
    final next = [...profile.fallbackTargets]..removeAt(index);
    _replaceEditingFallbackTargets(next);
  }

  Future<void> _fetchModels() async {
    final apiKey = _apiKeyController.text.trim();
    if (apiKey.isEmpty) {
      _showModelFetchNotice(AppStrings.apiKeyRequiredToUse);
      return;
    }

    setState(() => _fetchingModels = true);
    try {
      final models = await (widget.modelFetcher ?? LlmService.fetchModels)(
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
    final capabilitySummary = CapabilitySummary.resolve(profile);

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
                  ? '${capabilitySummary.detailLabel}\n${AppStrings.apiKeyRequiredToUse}'
                  : capabilitySummary.detailLabel,
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
          onChanged: (_) {
            setState(() {});
            _scheduleSave();
          },
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
                              setState(() {
                                _modelController.text = v;
                              });
                              _scheduleSave();
                            }
                          },
                        )
                      : TextField(
                          controller: _modelController,
                          onChanged: (_) {
                            setState(() {});
                            _scheduleSave();
                          },
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
      _capabilitySummaryPanel(
          theme,
          CapabilitySummary.resolve(
            _draftProfileForSummary(),
          )),
    ]);
  }

  Widget _fallbackSettings(ThemeData theme) {
    final profile = _editingProfile;
    if (profile == null) return const SizedBox.shrink();

    final targets = profile.fallbackTargets;
    final hasEnabledTargets = targets.any((target) => target.enabled);
    return _settingsGroup(theme, [
      _groupHeader(
        theme,
        AppStrings.modelFallback,
        trailing: TextButton.icon(
          onPressed: () => unawaited(_addFallbackTarget()),
          icon: const Icon(Icons.add),
          label: const Text(AppStrings.addFallbackTarget),
        ),
      ),
      SwitchListTile(
        title: const Text(AppStrings.modelFallbackEnabled),
        subtitle: Text(targets.isEmpty
            ? AppStrings.modelFallbackDisabled
            : AppStrings.modelFallbackSubtitle),
        value: targets.isNotEmpty && hasEnabledTargets,
        onChanged: targets.isEmpty ? null : _toggleAllFallbackTargets,
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Text(
          AppStrings.modelFallbackPrivacyNotice,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      if (targets.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Text(
            AppStrings.modelFallbackDisabled,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        )
      else
        for (var i = 0; i < targets.length; i++)
          _fallbackTargetTile(theme, targets[i], i, targets.length),
    ]);
  }

  Widget _fallbackTargetTile(
    ThemeData theme,
    ModelFallbackTarget target,
    int index,
    int count,
  ) {
    ProviderProfile? targetProfile;
    for (final profile in _profiles) {
      if (profile.id == target.targetProfileId) {
        targetProfile = profile;
        break;
      }
    }
    if (targetProfile == null) return const SizedBox.shrink();
    final model = target.effectiveModelFor(targetProfile);
    final summary = CapabilitySummary.resolve(
      targetProfile.copyWith(model: model),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(AppRadii.s),
          border: Border.all(color: theme.colorScheme.outline.withAlpha(40)),
        ),
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: target.enabled
                ? theme.colorScheme.primary.withAlpha(20)
                : theme.colorScheme.surfaceContainerHighest,
            foregroundColor: target.enabled
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant,
            child: Text('${index + 1}'),
          ),
          title: Text(
            targetProfile.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: Text(
            '$model\n${summary.detailLabel}',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          isThreeLine: true,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Switch(
                value: target.enabled,
                onChanged: (value) => _toggleFallbackTarget(index, value),
              ),
              PopupMenuButton<String>(
                tooltip: AppStrings.editFallbackTarget,
                onSelected: (value) {
                  switch (value) {
                    case 'edit':
                      unawaited(_editFallbackTarget(index));
                    case 'up':
                      _moveFallbackTarget(index, -1);
                    case 'down':
                      _moveFallbackTarget(index, 1);
                    case 'remove':
                      _removeFallbackTarget(index);
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'edit',
                    child: Text(AppStrings.editFallbackTarget),
                  ),
                  PopupMenuItem(
                    value: 'up',
                    enabled: index > 0,
                    child: const Text(AppStrings.moveFallbackTargetUp),
                  ),
                  PopupMenuItem(
                    value: 'down',
                    enabled: index < count - 1,
                    child: const Text(AppStrings.moveFallbackTargetDown),
                  ),
                  const PopupMenuItem(
                    value: 'remove',
                    child: Text(AppStrings.removeFallbackTarget),
                  ),
                ],
              ),
            ],
          ),
          onTap: () => unawaited(_editFallbackTarget(index)),
        ),
      ),
    );
  }

  Widget _capabilitySummaryPanel(ThemeData theme, CapabilitySummary summary) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(AppRadii.s),
          border: Border.all(color: theme.colorScheme.outline.withAlpha(45)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                summary.detailLabel,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: summary.chips
                    .map((label) => Chip(
                          label: Text(label),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ))
                    .toList(),
              ),
            ],
          ),
        ),
      ),
    );
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
            const Text(AppStrings.contextTokenBudget),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SegmentedButton<int>(
                segments: const [
                  ButtonSegment(
                    value: 32768,
                    label: Text(AppStrings.tokens32k),
                  ),
                  ButtonSegment(
                    value: 65536,
                    label: Text(AppStrings.tokens64k),
                  ),
                  ButtonSegment(
                    value: 200000,
                    label: Text(AppStrings.tokens200k),
                  ),
                ],
                selected: {_contextTokenBudget},
                onSelectionChanged: (v) {
                  HapticFeedback.lightImpact();
                  setState(() => _contextTokenBudget = v.first);
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
                _fallbackSettings(theme),
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

class _FallbackTargetDialog extends StatefulWidget {
  final List<ProviderProfile> candidates;
  final ModelFallbackTarget? initial;
  final ModelListFetcher modelFetcher;

  const _FallbackTargetDialog({
    required this.candidates,
    this.initial,
    required this.modelFetcher,
  });

  @override
  State<_FallbackTargetDialog> createState() => _FallbackTargetDialogState();
}

class _FallbackTargetDialogState extends State<_FallbackTargetDialog> {
  late String _selectedProfileId;
  late TextEditingController _customModelController;
  late bool _enabled;
  var _knownModels = <String>[];
  var _selectedModel = const FallbackModelSelection.targetDefault();
  var _fetchingModels = false;
  var _modelFetchGeneration = 0;

  ProviderProfile get _selectedProfile {
    return widget.candidates.firstWhere(
      (profile) => profile.id == _selectedProfileId,
      orElse: () => widget.candidates.first,
    );
  }

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _selectedProfileId = widget.candidates.any(
      (profile) => profile.id == initial?.targetProfileId,
    )
        ? initial!.targetProfileId
        : widget.candidates.first.id;
    _customModelController = TextEditingController(
      text: initial?.modelOverride.trim() ?? '',
    );
    _enabled = initial?.enabled ?? true;
    _selectedModel = FallbackModelSelection.selectedValueForOverride(
      modelOverride: _customModelController.text,
      knownModels: _knownModels,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_fetchTargetModels(silent: true));
    });
  }

  @override
  void dispose() {
    _customModelController.dispose();
    super.dispose();
  }

  Future<void> _fetchTargetModels({bool silent = false}) async {
    final profile = _selectedProfile;
    final profileId = profile.id;
    final requestGeneration = ++_modelFetchGeneration;
    final apiKey = profile.apiKey.trim();
    if (apiKey.isEmpty &&
        profile.apiFormat != ProviderProfile.anthropicFormat) {
      if (!silent) _showNotice(AppStrings.apiKeyRequiredToUse);
      setState(() {
        _knownModels = const [];
        _fetchingModels = false;
        _syncSelectionWithKnownModels();
      });
      return;
    }

    setState(() => _fetchingModels = true);
    try {
      final models = await widget.modelFetcher(
        apiFormat: profile.apiFormat,
        apiKey: apiKey,
        baseUrl:
            profile.baseUrl.trim().isNotEmpty ? profile.baseUrl.trim() : null,
      );
      if (!_isCurrentModelFetch(requestGeneration, profileId)) return;
      setState(() {
        _knownModels = FallbackModelSelection.normalizeKnownModels(models);
        _fetchingModels = false;
        _syncSelectionWithKnownModels();
      });
      if (!silent && models.any(LlmService.isPresetModel)) {
        _showNotice(AppStrings.modelFetchPresetNotice);
      }
    } catch (e) {
      if (!_isCurrentModelFetch(requestGeneration, profileId)) return;
      setState(() {
        _knownModels = const [];
        _fetchingModels = false;
        _syncSelectionWithKnownModels();
      });
      if (!silent) _showNotice(AppStrings.modelFetchFailed(_briefError(e)));
    }
  }

  bool _isCurrentModelFetch(int requestGeneration, String profileId) {
    return mounted &&
        requestGeneration == _modelFetchGeneration &&
        _selectedProfileId == profileId;
  }

  void _syncSelectionWithKnownModels() {
    if (_selectedModel.kind == FallbackModelSelectionKind.custom) {
      final customModel = _customModelController.text.trim();
      if (_knownModels.contains(customModel)) {
        _selectedModel = FallbackModelSelection.known(customModel);
      }
      return;
    }
    _selectedModel = FallbackModelSelection.selectedValueForOverride(
      modelOverride: _customModelController.text,
      knownModels: _knownModels,
    );
  }

  void _selectProfile(String profileId) {
    setState(() {
      _selectedProfileId = profileId;
      _knownModels = const [];
      _customModelController.clear();
      _selectedModel = const FallbackModelSelection.targetDefault();
    });
    unawaited(_fetchTargetModels(silent: true));
  }

  void _selectModel(FallbackModelSelection value) {
    setState(() {
      _selectedModel = value;
      switch (value.kind) {
        case FallbackModelSelectionKind.targetDefault:
          _customModelController.clear();
        case FallbackModelSelectionKind.known:
          _customModelController.text = value.modelId!;
        case FallbackModelSelectionKind.custom:
          if (_knownModels.contains(_customModelController.text.trim())) {
            _customModelController.clear();
          }
      }
    });
  }

  FallbackModelSelection get _dropdownSelection {
    if (_selectedModel.kind != FallbackModelSelectionKind.known ||
        _knownModels.contains(_selectedModel.modelId)) {
      return _selectedModel;
    }
    return const FallbackModelSelection.custom();
  }

  void _save() {
    Navigator.pop(
      context,
      ModelFallbackTarget(
        targetProfileId: _selectedProfileId,
        modelOverride: FallbackModelSelection.modelOverrideForSelection(
          selection: _dropdownSelection,
          customModel: _customModelController.text,
        ),
        enabled: _enabled,
      ),
    );
  }

  void _showNotice(String message) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  String _briefError(Object error) {
    final text = error.toString().replaceFirst('Exception: ', '');
    return text.length > 160 ? '${text.substring(0, 160)}...' : text;
  }

  @override
  Widget build(BuildContext context) {
    final selectedProfile = _selectedProfile;
    final dropdownSelection = _dropdownSelection;
    final showCustomField =
        dropdownSelection.kind == FallbackModelSelectionKind.custom;

    return AlertDialog(
      title: Text(
        widget.initial == null
            ? AppStrings.addFallbackTarget
            : AppStrings.editFallbackTarget,
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              key: const ValueKey('fallback_target_profile_selector'),
              value: _selectedProfileId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: AppStrings.fallbackTargetProfile,
              ),
              items: [
                for (final profile in widget.candidates)
                  DropdownMenuItem(
                    value: profile.id,
                    child: Text(
                      profile.displayName,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (value) {
                if (value != null) _selectProfile(value);
              },
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: DropdownButtonFormField<FallbackModelSelection>(
                    key: const ValueKey('fallback_model_selector'),
                    value: dropdownSelection,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: AppStrings.fallbackModelSelection,
                      helperText: AppStrings.fallbackModelSelectHelper,
                    ),
                    items: [
                      DropdownMenuItem(
                        value: const FallbackModelSelection.targetDefault(),
                        child: Text(
                          '${AppStrings.fallbackUseTargetDefault}: '
                          '${selectedProfile.effectiveModel}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      for (final model in _knownModels)
                        DropdownMenuItem(
                          value: FallbackModelSelection.known(model),
                          child: Text(
                            model,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      const DropdownMenuItem(
                        value: FallbackModelSelection.custom(),
                        child: Text(AppStrings.fallbackCustomModel),
                      ),
                    ],
                    onChanged: (value) {
                      if (value != null) _selectModel(value);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: AppStrings.fetchModelsButton,
                  onPressed: _fetchingModels
                      ? null
                      : () => unawaited(_fetchTargetModels()),
                  icon: _fetchingModels
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                ),
              ],
            ),
            if (_knownModels.isEmpty && !_fetchingModels)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    AppStrings.fallbackNoModelCatalog,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ),
              ),
            if (showCustomField) ...[
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('fallback_custom_model_input'),
                controller: _customModelController,
                decoration: const InputDecoration(
                  labelText: AppStrings.fallbackCustomModelLabel,
                  helperText: AppStrings.manualModelHint,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text(AppStrings.cancel),
        ),
        FilledButton(
          key: const ValueKey('fallback_target_save'),
          onPressed: _save,
          child: const Text(AppStrings.save),
        ),
      ],
    );
  }
}
