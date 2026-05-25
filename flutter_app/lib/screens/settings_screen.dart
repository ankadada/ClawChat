import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import '../app.dart' show AppColors, AppRadii, fontScaleNotifier, themeNotifier;
import '../constants.dart';
import '../services/config_export_service.dart';
import '../services/memory_service.dart';
import '../services/native_bridge.dart';
import '../services/preferences_service.dart';
import '../services/session_storage.dart';
import '../services/skill_service.dart';
import '../services/tts_service.dart';
import 'model_api_settings_screen.dart';
import 'setup_wizard_screen.dart';
import '../l10n/app_strings.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _sectionAppearance = 'appearance';
  static const _sectionVoice = 'voice';
  static const _sectionAgentSkills = 'agent_skills';
  static const _sectionData = 'data';
  static const _sectionAbout = 'about';

  final _prefs = PreferencesService();
  final _modelController = TextEditingController();
  final _whisperModelController = TextEditingController();
  final _ttsModelController = TextEditingController();
  String _apiFormat = 'anthropic';
  bool _loading = true;
  String _arch = '';
  Map<String, dynamic> _status = {};
  List<SkillInfo> _skills = [];
  bool _loadingSkills = false;
  Map<String, String> _envVars = {};
  String _themeMode = 'system';
  double _fontScale = 1.0;
  bool _notifyOnComplete = true;
  int _agentMaxIterations = PreferencesService.defaultAgentMaxIterations;
  bool _privacyMode = true;
  bool _allowPhoneCall = false;
  bool _allowSms = false;
  String _toolApprovalPolicy = PreferencesService.defaultToolApprovalPolicy;
  List<String> _memories = [];
  bool _loadingMemories = false;
  final Set<String> _expandedSections = {
    _sectionAppearance,
    _sectionVoice,
    _sectionAgentSkills,
    _sectionData,
    _sectionAbout,
  };

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      await _prefs.init();
      _modelController.text = _prefs.model ?? AppConstants.defaultModel;
      _apiFormat = _prefs.apiFormat ?? 'anthropic';
      _themeMode = _prefs.themeMode;
      _fontScale = _prefs.fontScale;
      _notifyOnComplete = _prefs.notifyOnComplete;
      _agentMaxIterations = _prefs.agentMaxIterations;
      _privacyMode = _prefs.privacyMode;
      _allowPhoneCall = _prefs.allowPhoneCall;
      _allowSms = _prefs.allowSms;
      _toolApprovalPolicy = _prefs.toolApprovalPolicy;
      _whisperModelController.text = _prefs.whisperModel ?? '';
      _ttsModelController.text = _prefs.ttsModel ?? '';

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

  Widget _settingsGroup(
    ThemeData theme,
    String sectionId,
    String title,
    List<Widget> children, {
    List<Widget> collapsedBadges = const [],
  }) {
    final expanded = _expandedSections.contains(sectionId);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withAlpha(120),
          borderRadius: BorderRadius.circular(AppRadii.m),
          border: Border.all(color: theme.colorScheme.outline.withAlpha(45)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(AppRadii.s),
                onTap: () {
                  setState(() {
                    if (expanded) {
                      _expandedSections.remove(sectionId);
                    } else {
                      _expandedSections.add(sectionId);
                    }
                  });
                },
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
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
                      if (!expanded) ...collapsedBadges,
                      AnimatedRotation(
                        turns: expanded ? 0 : -0.25,
                        duration: const Duration(milliseconds: 240),
                        curve: Curves.easeOutCubic,
                        child: Icon(
                          Icons.expand_more,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              AnimatedCrossFade(
                firstChild: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 8),
                    ...children,
                  ],
                ),
                secondChild: const SizedBox(width: double.infinity),
                crossFadeState: expanded
                    ? CrossFadeState.showFirst
                    : CrossFadeState.showSecond,
                duration: const Duration(milliseconds: 240),
                firstCurve: Curves.easeOutCubic,
                secondCurve: Curves.easeOutCubic,
                sizeCurve: Curves.easeOutCubic,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _settingsNavigationGroup(ThemeData theme, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withAlpha(120),
          borderRadius: BorderRadius.circular(AppRadii.m),
          border: Border.all(color: theme.colorScheme.outline.withAlpha(45)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(children: children),
        ),
      ),
    );
  }

  Widget _countBadge(ThemeData theme, String label) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withAlpha(20),
          borderRadius: BorderRadius.circular(AppRadii.xl),
          border: Border.all(color: theme.colorScheme.primary.withAlpha(55)),
        ),
        child: Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Widget _subsectionHeader(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        title,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _settingsDivider(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Divider(color: theme.colorScheme.outline.withAlpha(45)),
    );
  }

  Future<void> _loadSkills() async {
    setState(() => _loadingSkills = true);
    _skills = await SkillService.scanSkills();
    if (mounted) setState(() => _loadingSkills = false);
  }

  String _modelApiSubtitle() {
    final format =
        _apiFormat == 'anthropic' ? 'Anthropic' : AppStrings.openaiCompatible;
    final model = _modelController.text.trim().isEmpty
        ? AppConstants.defaultModel
        : _modelController.text.trim();
    final profileName = _prefs.activeProfile.displayName;
    return '$format · $profileName · $model';
  }

  Future<void> _reloadModelApiSummary() async {
    await _prefs.init();
    if (!mounted) return;
    setState(() {
      _apiFormat = _prefs.apiFormat ?? 'anthropic';
      _modelController.text = _prefs.model ?? AppConstants.defaultModel;
    });
  }

  Future<void> _testSystemVoice() async {
    HapticFeedback.lightImpact();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(AppStrings.voiceDiagnosticRunning)),
      );
    }

    final lines = <String>[
      AppStrings.voiceDiagnosticTtsHeader,
      await TtsService().diagnoseSystemVoice(),
      '',
      AppStrings.voiceDiagnosticSttHeader,
      await _testNativeSpeechRecognition(),
    ];

    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(AppStrings.voiceDiagnosticTitle),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SingleChildScrollView(
            child: SelectableText(lines.join('\n')),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(AppStrings.confirm),
          ),
        ],
      ),
    );
  }

  Future<String> _testNativeSpeechRecognition() async {
    try {
      var hasPermission = await NativeBridge.hasAudioPermission();
      if (!hasPermission) {
        await NativeBridge.requestAudioPermission();
        await Future.delayed(const Duration(milliseconds: 500));
        hasPermission = await NativeBridge.hasAudioPermission();
      }
      if (!hasPermission) {
        return 'STT 测试: 未授予录音权限。请在系统权限设置中允许 ClawChat 使用麦克风。';
      }

      final text = await NativeBridge.startSpeechRecognition(language: 'zh-CN');
      if (text == null || text.trim().isEmpty) {
        return 'STT 测试: 未识别到文字。请确认系统语音助手或 HiVoice 可用，并已允许语音识别服务。';
      }
      return 'STT 测试: 识别成功，结果：${text.trim()}';
    } catch (e) {
      return 'STT 测试失败: $e\n建议检查系统语音助手或 HiVoice 是否启用，Android 语音识别服务是否可用。';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text(AppStrings.settings)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: 16),
              children: [
                _settingsGroup(
                  theme,
                  _sectionAppearance,
                  AppStrings.settingsAppearance,
                  [
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(AppStrings.theme,
                              style: TextStyle(
                                color: theme.colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                              )),
                          const SizedBox(height: 8),
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: SegmentedButton<String>(
                              segments: const [
                                ButtonSegment(
                                    value: 'system',
                                    icon: Icon(Icons.settings_brightness),
                                    label: Text(AppStrings.themeSystem)),
                                ButtonSegment(
                                    value: 'light',
                                    icon: Icon(Icons.light_mode),
                                    label: Text(AppStrings.themeLight)),
                                ButtonSegment(
                                    value: 'dark',
                                    icon: Icon(Icons.dark_mode),
                                    label: Text(AppStrings.themeDark)),
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
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                              '${AppStrings.fontSize}: ${(_fontScale * 100).round()}%'),
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
                  ],
                ),
                _settingsGroup(
                  theme,
                  _sectionVoice,
                  AppStrings.settingsVoice,
                  [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(
                        AppStrings.voiceRecognitionDesc,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.hintColor),
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
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _testSystemVoice,
                          icon: const Icon(Icons.record_voice_over_outlined),
                          label: const Text(AppStrings.testSystemVoice),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    _settingsDivider(theme),
                    _subsectionHeader(theme, AppStrings.phoneIntegration),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(
                        AppStrings.phoneIntegrationDesc,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.hintColor),
                      ),
                    ),
                    SwitchListTile(
                      title: const Text(AppStrings.allowCall),
                      subtitle: const Text(AppStrings.allowCallSubtitle),
                      value: _allowPhoneCall,
                      onChanged: (v) {
                        HapticFeedback.lightImpact();
                        setState(() => _allowPhoneCall = v);
                        _prefs.allowPhoneCall = v;
                      },
                    ),
                    SwitchListTile(
                      title: const Text(AppStrings.allowSms),
                      subtitle: const Text(AppStrings.allowSmsSubtitle),
                      value: _allowSms,
                      onChanged: (v) {
                        HapticFeedback.lightImpact();
                        setState(() => _allowSms = v);
                        _prefs.allowSms = v;
                      },
                    ),
                  ],
                ),
                _settingsNavigationGroup(theme, [
                  ListTile(
                    leading: const Icon(Icons.tune),
                    title: const Text(AppStrings.settingsModelApi),
                    subtitle: Text(_modelApiSubtitle()),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      await Navigator.of(context).push(
                        CupertinoPageRoute(
                          builder: (_) => const ModelApiSettingsScreen(),
                        ),
                      );
                      await _reloadModelApiSummary();
                    },
                  ),
                ]),
                _settingsGroup(
                  theme,
                  _sectionAgentSkills,
                  AppStrings.settingsAgentSkills,
                  [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            AppStrings.toolApprovalPolicy,
                            style: TextStyle(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 8),
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: SegmentedButton<String>(
                              segments: const [
                                ButtonSegment(
                                  value: PreferencesService.toolApprovalAlways,
                                  icon: Icon(Icons.help_outline),
                                  label:
                                      Text(AppStrings.toolApprovalPolicyAlways),
                                ),
                                ButtonSegment(
                                  value: PreferencesService
                                      .toolApprovalSessionFirst,
                                  icon: Icon(Icons.check_circle_outline),
                                  label: Text(AppStrings
                                      .toolApprovalPolicySessionFirst),
                                ),
                                ButtonSegment(
                                  value: PreferencesService.toolApprovalAuto,
                                  icon: Icon(Icons.flash_on_outlined),
                                  label:
                                      Text(AppStrings.toolApprovalPolicyAuto),
                                ),
                              ],
                              selected: {_toolApprovalPolicy},
                              onSelectionChanged: (value) {
                                HapticFeedback.lightImpact();
                                setState(() {
                                  _toolApprovalPolicy = value.first;
                                });
                                _prefs.toolApprovalPolicy = _toolApprovalPolicy;
                              },
                            ),
                          ),
                          if (_toolApprovalPolicy ==
                              PreferencesService.toolApprovalAuto) ...[
                            const SizedBox(height: 8),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.errorContainer
                                    .withAlpha(170),
                                borderRadius: BorderRadius.circular(AppRadii.s),
                                border: Border.all(
                                  color: theme.colorScheme.error.withAlpha(90),
                                ),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(
                                    Icons.warning_amber_outlined,
                                    size: 18,
                                    color: theme.colorScheme.onErrorContainer,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      AppStrings.toolApprovalPolicyAutoWarning,
                                      style:
                                          theme.textTheme.bodySmall?.copyWith(
                                        color:
                                            theme.colorScheme.onErrorContainer,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    SwitchListTile(
                      title: const Text(AppStrings.notifyOnComplete),
                      subtitle: const Text(AppStrings.notifyOnCompleteSubtitle),
                      value: _notifyOnComplete,
                      onChanged: (v) {
                        HapticFeedback.lightImpact();
                        setState(() => _notifyOnComplete = v);
                        _prefs.notifyOnComplete = v;
                      },
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Agent 最大轮次: $_agentMaxIterations'),
                          Slider(
                            value: _agentMaxIterations.toDouble(),
                            min: 1,
                            max: PreferencesService.maxAgentMaxIterations
                                .toDouble(),
                            divisions:
                                PreferencesService.maxAgentMaxIterations - 1,
                            label: '$_agentMaxIterations',
                            onChanged: (v) {
                              final next = v.round();
                              setState(() => _agentMaxIterations = next);
                              _prefs.agentMaxIterations = next;
                            },
                          ),
                        ],
                      ),
                    ),
                    _settingsDivider(theme),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Wrap(
                          spacing: 4,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
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
                              tooltip: AppStrings.refresh,
                              onPressed: _loadSkills,
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (_loadingSkills)
                      const Center(
                          child: Padding(
                        padding: EdgeInsets.all(16),
                        child: CircularProgressIndicator(),
                      ))
                    else if (_skills.isEmpty)
                      const Padding(
                        padding:
                            EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                        child: Text(AppStrings.noSkillsFound),
                      )
                    else
                      ..._skills.map((skill) => SwitchListTile(
                            title: Text(skill.name),
                            subtitle: Text(skill.description,
                                maxLines: 2, overflow: TextOverflow.ellipsis),
                            value: skill.enabled,
                            onChanged: (v) async {
                              HapticFeedback.lightImpact();
                              setState(() => skill.enabled = v);
                              await SkillService.setSkillEnabled(skill.name, v);
                            },
                          )),
                  ],
                  collapsedBadges: [
                    _countBadge(
                        theme, '${AppStrings.skills} ${_skills.length}'),
                  ],
                ),
                _settingsGroup(
                  theme,
                  _sectionData,
                  AppStrings.settingsData,
                  [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _subsectionHeader(theme, AppStrings.envVars),
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: IconButton(
                            icon: const Icon(Icons.add),
                            onPressed: _addEnvVar,
                          ),
                        ),
                      ],
                    ),
                    SwitchListTile(
                      title: const Text(AppStrings.privacyMode),
                      subtitle: const Text(AppStrings.privacyModeSubtitle),
                      value: _privacyMode,
                      onChanged: (v) {
                        HapticFeedback.lightImpact();
                        setState(() => _privacyMode = v);
                        _prefs.privacyMode = v;
                      },
                    ),
                    if (_envVars.isEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Text(AppStrings.noEnvVars,
                            style: TextStyle(
                                color: theme.colorScheme.onSurfaceVariant)),
                      )
                    else
                      ..._envVars.entries.map((e) => ListTile(
                            title: Text(e.key),
                            subtitle: Text('••••••'),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _deleteEnvVar(e.key),
                            ),
                          )),
                    _settingsDivider(theme),
                    _subsectionHeader(theme, AppStrings.dataManagement),
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
                    ListTile(
                      title: const Text(AppStrings.exportConfig),
                      subtitle: const Text(AppStrings.exportConfigSubtitle),
                      leading: const Icon(Icons.upload_file),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _exportConfig,
                    ),
                    ListTile(
                      title: const Text(AppStrings.importConfig),
                      subtitle: const Text(AppStrings.importConfigSubtitle),
                      leading: const Icon(Icons.download),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _importConfig,
                    ),
                    _settingsDivider(theme),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _subsectionHeader(theme, AppStrings.memoryManagement),
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: IconButton(
                            icon: const Icon(Icons.add),
                            tooltip: AppStrings.addMemory,
                            onPressed: _addMemory,
                          ),
                        ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(
                        AppStrings.memoryDesc,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.hintColor),
                      ),
                    ),
                    if (_loadingMemories)
                      const Center(
                          child: Padding(
                        padding: EdgeInsets.all(16),
                        child: CircularProgressIndicator(),
                      ))
                    else if (_memories.isEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Text(AppStrings.noMemories,
                            style: TextStyle(
                                color: theme.colorScheme.onSurfaceVariant)),
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
                  collapsedBadges: [
                    _countBadge(
                        theme, '${AppStrings.envVars} ${_envVars.length}'),
                    _countBadge(theme,
                        '${AppStrings.memoryManagement} ${_memories.length}'),
                  ],
                ),
                _settingsGroup(theme, _sectionAbout, AppStrings.about, [
                  _subsectionHeader(theme, AppStrings.systemInfo),
                  ListTile(
                    title: const Text(AppStrings.architecture),
                    subtitle: Text(_arch),
                    leading: const Icon(Icons.memory),
                  ),
                  ListTile(
                    title: const Text('Rootfs'),
                    subtitle: Text(_status['rootfsExists'] == true
                        ? AppStrings.installed
                        : AppStrings.notInstalled),
                    leading: const Icon(Icons.storage),
                  ),
                  ListTile(
                    title: const Text('Python3'),
                    subtitle: Text(_status['pythonInstalled'] == true
                        ? AppStrings.installed
                        : AppStrings.notInstalled),
                    leading: const Icon(Icons.code),
                  ),
                  _settingsDivider(theme),
                  _subsectionHeader(theme, AppStrings.maintenance),
                  ListTile(
                    title: const Text(AppStrings.reinitialize),
                    subtitle: const Text(AppStrings.reinstallAlpine),
                    leading: const Icon(Icons.build),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _confirmReinitialize,
                  ),
                  _settingsDivider(theme),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        Text(AppStrings.appName,
                            style: theme.textTheme.titleLarge),
                        const SizedBox(height: 4),
                        Text('v${AppConstants.version}',
                            style: theme.textTheme.bodySmall),
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
                              onPressed: () =>
                                  launchUrl(Uri.parse(AppConstants.githubUrl)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text('${AppStrings.license}: ${AppConstants.license}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            )),
                      ],
                    ),
                  ),
                ]),
              ],
            ),
    );
  }

  Future<bool> _confirmDelete(String title, String message) async {
    final theme = Theme.of(context);
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text(AppStrings.cancel),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                ),
                child: const Text(AppStrings.delete),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _deleteEnvVar(String name) async {
    final confirmed = await _confirmDelete(
      AppStrings.delete,
      AppStrings.deleteEnvVarConfirm(name),
    );
    if (!confirmed || !mounted) return;
    setState(() {
      _envVars.remove(name);
    });
    _prefs.envVars = _envVars;
  }

  Future<void> _confirmReinitialize() async {
    final confirmed = await _confirmDelete(
      AppStrings.reinitializeConfirmTitle,
      AppStrings.reinitializeConfirmMessage,
    );
    if (!confirmed || !mounted) return;
    Navigator.of(context).pushReplacement(
      CupertinoPageRoute(builder: (_) => const SetupWizardScreen()),
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
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text(AppStrings.cancel)),
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
              decoration:
                  const InputDecoration(labelText: AppStrings.envVarName),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: valueController,
              decoration:
                  const InputDecoration(labelText: AppStrings.envVarValue),
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
    final mode = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.archive),
              title: const Text(AppStrings.archiveSkill),
              onTap: () => Navigator.pop(ctx, 'archive'),
            ),
            ListTile(
              leading: const Icon(Icons.folder),
              title: const Text(AppStrings.directory),
              onTap: () => Navigator.pop(ctx, 'directory'),
            ),
          ],
        ),
      ),
    );
    if (mode == null) return;

    String? path;
    if (mode == 'archive') {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip', 'tgz', 'gz'],
        withData: false,
        withReadStream: false,
      );
      if (result == null || result.files.isEmpty) return;
      path = result.files.single.path;
      final lowerPath = path?.toLowerCase() ?? '';
      if (!lowerPath.endsWith('.zip') &&
          !lowerPath.endsWith('.tgz') &&
          !lowerPath.endsWith('.tar.gz')) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text(AppStrings.selectSkillArchive)),
          );
        }
        return;
      }
    } else {
      path = await FilePicker.platform.getDirectoryPath();
    }
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

  Future<void> _exportConfig() async {
    try {
      final options = await _showExportConfigDialog();
      if (options == null) return;

      if (!options.encrypt) {
        if (!mounted) return;
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text(AppStrings.exportConfigWithoutEncryption),
            content: const Text(AppStrings.exportConfigPlainWarning),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text(AppStrings.cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.statusRed,
                  foregroundColor: Colors.white,
                ),
                child: const Text(AppStrings.confirm),
              ),
            ],
          ),
        );
        if (confirmed != true) return;
      }

      final jsonStr = await ConfigExportService.exportConfig(
        password: options.encrypt ? options.password : null,
      );
      final date = DateTime.now().toIso8601String().split('T').first;
      final path = await FilePicker.platform.saveFile(
        dialogTitle: AppStrings.exportConfig,
        fileName: 'clawchat-config-$date.json',
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (path == null || path.isEmpty) return;

      await File(path).writeAsString(jsonStr);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(AppStrings.configExported)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${AppStrings.exportConfigFailed}: $e')),
        );
      }
    }
  }

  Future<_ConfigExportOptions?> _showExportConfigDialog() {
    var encrypt = true;
    final passwordController = TextEditingController();
    final confirmController = TextEditingController();
    return showDialog<_ConfigExportOptions>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text(AppStrings.exportConfig),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(AppStrings.encryptSecrets),
                  subtitle: const Text(AppStrings.encryptSecretsSubtitle),
                  value: encrypt,
                  onChanged: (value) => setDialogState(() => encrypt = value),
                ),
                if (encrypt) ...[
                  TextField(
                    controller: passwordController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: AppStrings.setPassword,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: confirmController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: AppStrings.confirmPassword,
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text(AppStrings.cancel),
            ),
            FilledButton(
              onPressed: () {
                final password = passwordController.text;
                if (encrypt) {
                  if (password.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text(AppStrings.passwordRequired)),
                    );
                    return;
                  }
                  if (password != confirmController.text) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text(AppStrings.passwordMismatch)),
                    );
                    return;
                  }
                }
                Navigator.pop(
                  ctx,
                  _ConfigExportOptions(
                    encrypt: encrypt,
                    password: password,
                  ),
                );
              },
              child: const Text(AppStrings.exportConfig),
            ),
          ],
        ),
      ),
    ).whenComplete(() {
      passwordController.dispose();
      confirmController.dispose();
    });
  }

  Future<void> _importConfig() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (result == null || result.files.isEmpty) return;
      final path = result.files.single.path;
      if (path == null) return;

      final jsonStr = await File(path).readAsString();
      final preview = ConfigExportService.previewImport(jsonStr);
      final options = await _showImportConfigDialog(preview);
      if (options == null) return;

      final importResult = await ConfigExportService.importConfig(
        jsonStr,
        password: options.password,
        conflictResolution: options.resolution,
      );
      await _prefs.init();
      await _loadSettings();
      themeNotifier.value = switch (_prefs.themeMode) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
      fontScaleNotifier.value = _prefs.fontScale;

      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text(AppStrings.importConfigComplete),
          content: Text(AppStrings.configImportSummary(
            importResult.profilesImported,
            importResult.envVarsImported,
            importResult.profilesSkipped,
          )),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text(AppStrings.confirm),
            ),
          ],
        ),
      );
    } on FormatException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('${AppStrings.invalidConfigFile}: ${e.message}')),
        );
      }
    } on StateError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${AppStrings.importConfigFailed}: $e')),
        );
      }
    }
  }

  Future<_ConfigImportOptions?> _showImportConfigDialog(
    ConfigImportPreview preview,
  ) {
    var resolution = ConflictResolution.merge;
    final passwordController = TextEditingController();
    return showDialog<_ConfigImportOptions>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text(AppStrings.importConfigPreview),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _previewLine(
                  AppStrings.configVersion,
                  'v${preview.version}',
                ),
                _previewLine(
                  AppStrings.configExportedAt,
                  preview.exportedAt?.toLocal().toString().split('.').first ??
                      AppStrings.unknown,
                ),
                _previewLine(
                  AppStrings.configEncrypted,
                  preview.isEncrypted ? AppStrings.yes : AppStrings.no,
                ),
                _previewLine(
                  AppStrings.providerProfiles,
                  preview.profileCount >= 0
                      ? '${preview.profileCount}'
                      : AppStrings.encryptedPreviewHidden,
                ),
                _previewLine(
                  AppStrings.envVars,
                  preview.envVarCount >= 0
                      ? '${preview.envVarCount}'
                      : AppStrings.encryptedPreviewHidden,
                ),
                _previewLine(
                  AppStrings.settings,
                  preview.hasSettings ? AppStrings.yes : AppStrings.no,
                ),
                if (preview.isEncrypted) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: passwordController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: AppStrings.password,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Text(
                  AppStrings.conflictResolution,
                  style: Theme.of(ctx).textTheme.titleSmall,
                ),
                RadioListTile<ConflictResolution>(
                  contentPadding: EdgeInsets.zero,
                  value: ConflictResolution.merge,
                  groupValue: resolution,
                  title: const Text(AppStrings.conflictMerge),
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() => resolution = value);
                    }
                  },
                ),
                RadioListTile<ConflictResolution>(
                  contentPadding: EdgeInsets.zero,
                  value: ConflictResolution.replace,
                  groupValue: resolution,
                  title: const Text(AppStrings.conflictReplace),
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() => resolution = value);
                    }
                  },
                ),
                RadioListTile<ConflictResolution>(
                  contentPadding: EdgeInsets.zero,
                  value: ConflictResolution.skip,
                  groupValue: resolution,
                  title: const Text(AppStrings.conflictSkip),
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() => resolution = value);
                    }
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text(AppStrings.cancel),
            ),
            FilledButton(
              onPressed: () {
                if (preview.isEncrypted && passwordController.text.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text(AppStrings.passwordRequired)),
                  );
                  return;
                }
                Navigator.pop(
                  ctx,
                  _ConfigImportOptions(
                    password: passwordController.text,
                    resolution: resolution,
                  ),
                );
              },
              child: const Text(AppStrings.importConfig),
            ),
          ],
        ),
      ),
    ).whenComplete(passwordController.dispose);
  }

  Widget _previewLine(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: TextStyle(color: Theme.of(context).hintColor),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
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
    final confirmed = await _confirmDelete(
      AppStrings.deleteMemoryTitle,
      AppStrings.deleteMemoryConfirm,
    );
    if (!confirmed) return;
    await MemoryService.removeMemory(index);
    await _loadMemories();
  }

  @override
  void dispose() {
    _modelController.dispose();
    _whisperModelController.dispose();
    _ttsModelController.dispose();
    super.dispose();
  }
}

class _ConfigExportOptions {
  final bool encrypt;
  final String password;

  const _ConfigExportOptions({
    required this.encrypt,
    required this.password,
  });
}

class _ConfigImportOptions {
  final String password;
  final ConflictResolution resolution;

  const _ConfigImportOptions({
    required this.password,
    required this.resolution,
  });
}
