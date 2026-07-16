import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../app.dart' show AppColors, AppRadii, fontScaleNotifier, themeNotifier;
import '../constants.dart';
import '../models/mcp_server_config.dart';
import '../models/update_models.dart';
import '../services/bounded_file_reader.dart';
import '../services/bundled_legacy_skill_catalog.dart';
import '../services/config_export_service.dart';
import '../services/file_attachment_service.dart';
import '../services/memory_service.dart';
import '../services/mcp_service.dart';
import '../services/native_bridge.dart';
import '../services/preferences_service.dart';
import '../services/remote_agent_boot.dart';
import '../services/session_storage.dart';
import '../services/skill_service.dart';
import '../services/tts_service.dart';
import '../services/usage_summary_service.dart';
import '../services/update_service.dart';
import '../services/update_transaction.dart';
import '../providers/chat_provider.dart';
import '../widgets/skill_consent_dialog.dart';
import '../widgets/update_preview_dialog.dart';
import 'model_api_settings_screen.dart';
import 'setup_wizard_screen.dart';
import 'run_trace_screen.dart';
import 'remote_agent_settings_screen.dart';
import 'local_data_recovery_screen.dart';
import 'background_task_center_screen.dart';
import '../l10n/app_strings.dart';
import '../layout/foldable_layout.dart';

enum SettingsDestination {
  connections,
  agentTools,
  voice,
  dataRecovery,
  updatesExtensions,
  privacy,
  developer,
  appearanceAbout,
}

enum _DiagnosticsDestination { copy, save, share }

final class SettingsDestinationInfo {
  const SettingsDestinationInfo({
    required this.destination,
    required this.label,
    required this.description,
    required this.icon,
    required this.keywords,
  });

  final SettingsDestination destination;
  final String label;
  final String description;
  final IconData icon;
  final List<String> keywords;
}

final class SettingsControlInfo {
  const SettingsControlInfo(this.destination, this.label, this.keywords);
  final SettingsDestination destination;
  final String label;
  final List<String> keywords;
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    this.prepareSkillFromUrlForTesting,
    this.skipInitialLoadForTesting = false,
    this.importFlowOnlyForTesting = false,
    this.updateService,
    this.initialDestination,
  });

  @visibleForTesting
  final Future<PreparedSkillImport> Function(
    String url,
    SkillImportCancellationToken cancellationToken,
  )? prepareSkillFromUrlForTesting;

  @visibleForTesting
  final bool skipInitialLoadForTesting;

  @visibleForTesting
  final bool importFlowOnlyForTesting;

  @visibleForTesting
  final UpdateService? updateService;
  final SettingsDestination? initialDestination;

  static const controlInventory = <SettingsControlInfo>[
    SettingsControlInfo(
        SettingsDestination.connections, '模型提供商与模型组', ['API', '模型', '密钥']),
    SettingsControlInfo(
        SettingsDestination.connections, '远程 Agent', ['外部', '连接器', '授权']),
    SettingsControlInfo(
        SettingsDestination.agentTools, '提示缓存', ['Anthropic', 'cache']),
    SettingsControlInfo(
        SettingsDestination.agentTools, '工具审批策略', ['允许一次', '会话', '自动']),
    SettingsControlInfo(
        SettingsDestination.agentTools, '工具拒绝列表', ['denylist', '始终拒绝']),
    SettingsControlInfo(
        SettingsDestination.agentTools, 'Bash 拒绝模式', ['命令', '规则']),
    SettingsControlInfo(
        SettingsDestination.agentTools, 'MCP 服务器', ['stdio', '工具']),
    SettingsControlInfo(SettingsDestination.agentTools, '完成通知', ['通知']),
    SettingsControlInfo(SettingsDestination.agentTools, 'Agent 最大轮次', ['迭代']),
    SettingsControlInfo(
        SettingsDestination.agentTools, '最大并发 Agent', ['并发', '后台任务']),
    SettingsControlInfo(
        SettingsDestination.voice, 'Whisper 模型', ['语音识别', '转写']),
    SettingsControlInfo(SettingsDestination.voice, 'TTS 模型', ['朗读']),
    SettingsControlInfo(SettingsDestination.voice, '系统语音测试', ['STT', '诊断']),
    SettingsControlInfo(SettingsDestination.voice, '电话与短信', ['拨号', 'SMS']),
    SettingsControlInfo(
        SettingsDestination.dataRecovery, '本地数据恢复', ['会话回收站', '恢复']),
    SettingsControlInfo(SettingsDestination.dataRecovery, '本地任务中心',
        ['后台任务', '恢复', '未知结果', '弃置']),
    SettingsControlInfo(
        SettingsDestination.dataRecovery, '导出与导入配置', ['备份', '迁移']),
    SettingsControlInfo(SettingsDestination.dataRecovery, '使用量摘要', ['tokens']),
    SettingsControlInfo(SettingsDestination.dataRecovery, '本地记忆', ['memory']),
    SettingsControlInfo(
        SettingsDestination.updatesExtensions, '应用更新', ['版本', '安装器']),
    SettingsControlInfo(SettingsDestination.updatesExtensions, '技能与扩展',
        ['导入', '更新', '历史', '回滚']),
    SettingsControlInfo(SettingsDestination.privacy, '隐私模式', ['privacy']),
    SettingsControlInfo(SettingsDestination.privacy, '环境变量', ['secret', '令牌']),
    SettingsControlInfo(SettingsDestination.privacy, '脱敏诊断导出', ['diagnostics']),
    SettingsControlInfo(SettingsDestination.developer, '开发者模式', ['高级']),
    SettingsControlInfo(
        SettingsDestination.developer, 'Agent 运行详情', ['trace', '时间线']),
    SettingsControlInfo(
        SettingsDestination.appearanceAbout, '主题', ['浅色', '深色', '系统']),
    SettingsControlInfo(
        SettingsDestination.appearanceAbout, '字体大小', ['文字', '缩放']),
    SettingsControlInfo(SettingsDestination.appearanceAbout, '运行时系统信息',
        ['架构', 'Rootfs', 'Python']),
    SettingsControlInfo(
        SettingsDestination.appearanceAbout, '重新初始化运行时', ['Alpine', '维护']),
    SettingsControlInfo(SettingsDestination.appearanceAbout, '隐私政策',
        ['Privacy Policy', 'GitHub', 'GPL']),
    SettingsControlInfo(SettingsDestination.appearanceAbout, '应用版本与关于',
        ['GitHub', '隐私政策', '设置向导']),
  ];
  static const extensionActionLabels = ['更新', '历史', '回滚'];

  @override
  State<SettingsScreen> createState() => _SettingsHubState();
}

class _SettingsHubState extends State<SettingsScreen> {
  static const destinations = <SettingsDestinationInfo>[
    SettingsDestinationInfo(
      destination: SettingsDestination.connections,
      label: '连接',
      description: '模型提供商、模型组与远程 Agent',
      icon: Icons.hub_outlined,
      keywords: ['API', '模型', 'provider', 'Remote Agent', '连接器'],
    ),
    SettingsDestinationInfo(
      destination: SettingsDestination.agentTools,
      label: 'Agent 与工具',
      description: '审批策略、拒绝规则、并发与 MCP',
      icon: Icons.build_circle_outlined,
      keywords: ['审批', 'denylist', '并发', 'MCP', '工具', 'Agent'],
    ),
    SettingsDestinationInfo(
      destination: SettingsDestination.voice,
      label: '语音',
      description: '识别、转写、朗读与电话集成',
      icon: Icons.record_voice_over_outlined,
      keywords: ['麦克风', 'Whisper', 'TTS', 'STT', '电话', '短信'],
    ),
    SettingsDestinationInfo(
      destination: SettingsDestination.dataRecovery,
      label: '数据与恢复',
      description: '本地数据、导入导出、记忆与恢复',
      icon: Icons.storage_outlined,
      keywords: ['备份', '恢复', '导出', '导入', '记忆', '本地数据'],
    ),
    SettingsDestinationInfo(
      destination: SettingsDestination.updatesExtensions,
      label: '更新与扩展',
      description: '应用更新、技能、扩展历史与回滚',
      icon: Icons.system_update_alt,
      keywords: ['版本', '更新', '技能', '扩展', '回滚', '历史'],
    ),
    SettingsDestinationInfo(
      destination: SettingsDestination.privacy,
      label: '隐私',
      description: '隐私模式、环境变量与本地诊断',
      icon: Icons.privacy_tip_outlined,
      keywords: ['隐私', '环境变量', '诊断', 'secret', '本地'],
    ),
    SettingsDestinationInfo(
      destination: SettingsDestination.developer,
      label: '开发者',
      description: '运行轨迹、运行时维护与高级诊断',
      icon: Icons.developer_mode_outlined,
      keywords: ['开发者', 'trace', '运行轨迹', 'runtime', '维护'],
    ),
    SettingsDestinationInfo(
      destination: SettingsDestination.appearanceAbout,
      label: '外观与关于',
      description: '主题、字号、系统信息与版本',
      icon: Icons.palette_outlined,
      keywords: ['主题', '字体', '字号', '版本', '关于', '系统信息'],
    ),
  ];

  final _searchController = TextEditingController();
  final Map<SettingsDestination, GlobalKey> _detailKeys = {};
  String _query = '';
  SettingsDestination? _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialDestination;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<SettingsDestinationInfo> get _results {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return destinations;
    return destinations.where((item) {
      final destinationMatches = <String>[
        item.label,
        item.description,
        ...item.keywords
      ].any((value) => value.toLowerCase().contains(query));
      final controlMatches = SettingsScreen.controlInventory
          .where((control) => control.destination == item.destination)
          .any((control) => <String>[control.label, ...control.keywords]
              .any((value) => value.toLowerCase().contains(query)));
      return destinationMatches || controlMatches;
    }).toList(growable: false);
  }

  void _open(SettingsDestination destination, bool embedded) {
    if (embedded) {
      setState(() => _selected = destination);
      return;
    }
    Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => SettingsDetailScreen(
          destination: destination,
          updateService: widget.updateService,
        ),
      ),
    );
  }

  Widget _index(bool embedded) => ListView(
        key: const PageStorageKey('settings-index'),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [
          TextField(
            controller: _searchController,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              labelText: '搜索设置',
              hintText: '例如：审批、更新、隐私',
            ),
            onChanged: (value) => setState(() => _query = value),
          ),
          const SizedBox(height: 12),
          if (_results.isEmpty)
            const ListTile(
              leading: Icon(Icons.search_off),
              title: Text('没有匹配的设置'),
              subtitle: Text('搜索只匹配设置名称和功能关键词。'),
            ),
          for (final item in _results)
            ListTile(
              minTileHeight: 64,
              selected: embedded && _selected == item.destination,
              leading: Icon(item.icon),
              title: Text(item.label),
              subtitle: Text(_resultSubtitle(item)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _open(item.destination, embedded),
            ),
        ],
      );

  List<String> _matchingControlLabels(SettingsDestination destination) {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return const [];
    return SettingsScreen.controlInventory
        .where((control) => control.destination == destination)
        .where((control) => <String>[control.label, ...control.keywords]
            .any((value) => value.toLowerCase().contains(query)))
        .map((control) => control.label)
        .toList(growable: false);
  }

  String _resultSubtitle(SettingsDestinationInfo item) {
    final matches = _matchingControlLabels(item.destination);
    return matches.isEmpty
        ? item.description
        : '${item.description}\n匹配：${matches.join('、')}';
  }

  Widget _detail(SettingsDestination destination) => SettingsDetailScreen(
        key: _detailKeys.putIfAbsent(destination, GlobalKey.new),
        destination: destination,
        updateService: widget.updateService,
      );

  @override
  Widget build(BuildContext context) {
    if (widget.prepareSkillFromUrlForTesting != null ||
        widget.skipInitialLoadForTesting ||
        widget.importFlowOnlyForTesting) {
      return SettingsDetailScreen(
        destination:
            widget.initialDestination ?? SettingsDestination.updatesExtensions,
        prepareSkillFromUrlForTesting: widget.prepareSkillFromUrlForTesting,
        skipInitialLoadForTesting: widget.skipInitialLoadForTesting,
        importFlowOnlyForTesting: widget.importFlowOnlyForTesting,
        updateService: widget.updateService,
      );
    }
    return LayoutBuilder(builder: (context, constraints) {
      final media = MediaQuery.of(context);
      final fold = FoldableLayout.resolve(
        constraints.biggest,
        media.displayFeatures,
        bottomInset: media.viewInsets.bottom,
      );
      final book = fold.posture == FoldablePosture.book;
      final wide = constraints.maxWidth >= 840;
      final embedded = book || wide;
      if (fold.posture == FoldablePosture.tabletop) {
        final primary = widget.initialDestination == null
            ? Scaffold(
                appBar: AppBar(title: const Text(AppStrings.settings)),
                body: _index(false),
              )
            : _detail(widget.initialDestination!);
        return Scaffold(
          body: Stack(
            children: [
              Positioned.fromRect(
                rect: fold.auxiliary!,
                child: ColoredBox(
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                ),
              ),
              Positioned.fromRect(rect: fold.primary, child: primary),
            ],
          ),
        );
      }
      if (!embedded) {
        if (widget.initialDestination != null) {
          return _detail(widget.initialDestination!);
        }
        return Scaffold(
          appBar: AppBar(title: const Text(AppStrings.settings)),
          body: _index(false),
        );
      }
      final selected = _selected ?? destinations.first.destination;
      if (book) {
        return Scaffold(
          body: Stack(children: [
            Positioned.fromRect(
              rect: fold.auxiliary!,
              child: Scaffold(
                appBar: AppBar(title: const Text(AppStrings.settings)),
                body: _index(true),
              ),
            ),
            Positioned.fromRect(rect: fold.primary, child: _detail(selected)),
          ]),
        );
      }
      return Scaffold(
        appBar: AppBar(title: const Text(AppStrings.settings)),
        body: Row(children: [
          SizedBox(width: 340, child: _index(true)),
          const VerticalDivider(width: 1),
          Expanded(child: _detail(selected)),
        ]),
      );
    });
  }
}

class SettingsDetailScreen extends StatefulWidget {
  const SettingsDetailScreen({
    super.key,
    required this.destination,
    this.prepareSkillFromUrlForTesting,
    this.skipInitialLoadForTesting = false,
    this.importFlowOnlyForTesting = false,
    this.updateService,
    this.appUpdateStateLoaderForTesting,
    this.diagnosticsReportBuilderForTesting,
    this.diagnosticsShareForTesting,
    this.diagnosticsSaveForTesting,
  });

  final SettingsDestination destination;
  final Future<PreparedSkillImport> Function(
    String url,
    SkillImportCancellationToken cancellationToken,
  )? prepareSkillFromUrlForTesting;
  final bool skipInitialLoadForTesting;
  final bool importFlowOnlyForTesting;
  final UpdateService? updateService;

  @visibleForTesting
  final Future<AppUpdateStagingState?> Function(String targetId)?
      appUpdateStateLoaderForTesting;

  @visibleForTesting
  final Future<String> Function()? diagnosticsReportBuilderForTesting;

  @visibleForTesting
  final Future<bool> Function(String report)? diagnosticsShareForTesting;

  @visibleForTesting
  final Future<bool> Function(String report)? diagnosticsSaveForTesting;

  @override
  State<SettingsDetailScreen> createState() => _SettingsDetailScreenState();
}

class _SettingsDetailScreenState extends State<SettingsDetailScreen> {
  static const _mcpHiddenEnvValue = '<hidden>';
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
  String? _loadError;
  String _arch = '';
  Map<String, dynamic> _status = {};
  List<SkillInfo> _skills = [];
  bool _loadingSkills = false;
  String? _skillsLoadError;
  SkillImportCancellationToken? _activeSkillImportCancellation;
  UpdateCancellationToken? _activeUpdateCancellation;
  late final UpdateService _updates;
  Map<String, String> _envVars = {};
  String _themeMode = 'system';
  double _fontScale = 1.0;
  bool _notifyOnComplete = true;
  int _agentMaxIterations = PreferencesService.defaultAgentMaxIterations;
  int _maxConcurrentAgents = PreferencesService.defaultMaxConcurrentAgents;
  bool _privacyMode = true;
  bool _developerMode = false;
  bool _allowPhoneCall = false;
  bool _allowSms = false;
  bool _anthropicPromptCacheEnabled = true;
  bool _memoryEnabled = true;
  String _toolApprovalPolicy = PreferencesService.defaultToolApprovalPolicy;
  Set<String> _deniedToolNames = {};
  List<String> _bashCommandDenyPatterns = [];
  List<McpServerConfig> _mcpServers = [];
  List<String> _memories = [];
  bool _loadingMemories = false;
  int _updateStateEpoch = 0;
  Future<AppUpdateStagingState?>? _appUpdateStateFuture;
  final Map<String, Future<ExtensionUpdateState?>>
      _extensionUpdateStateFutures = {};
  DateTime? _lastUpdateCheckAt;
  String? _lastUpdateResult;
  final Set<String> _expandedSections = {
    _sectionAppearance,
    _sectionVoice,
    _sectionAgentSkills,
    _sectionData,
    _sectionAbout,
    'privacy_only',
    'developer_only',
  };
  static const _toolSafetyToolNames = [
    'bash',
    'read_file',
    'write_file',
    'web_fetch',
    'web_search',
    'set_env_var',
    'memory_get',
    'memory_write',
    'memory_delete',
    'generate_image',
    'phone_intent',
  ];

  @override
  void initState() {
    super.initState();
    _updates = widget.updateService ?? UpdateService();
    if (widget.destination == SettingsDestination.updatesExtensions) {
      _appUpdateStateFuture = _readAppUpdateState();
    }
    if (widget.skipInitialLoadForTesting) {
      _loading = false;
    } else {
      _loadSettings();
    }
  }

  Future<AppUpdateStagingState?> _readAppUpdateState() =>
      widget.appUpdateStateLoaderForTesting?.call(AppConstants.packageName) ??
      _updates.loadAppUpdateState(AppConstants.packageName);

  void _retryAppUpdateState() {
    setState(() {
      _updateStateEpoch += 1;
      _appUpdateStateFuture = _readAppUpdateState();
    });
  }

  Future<ExtensionUpdateState?> _readExtensionUpdateState(String id) =>
      _extensionUpdateStateFutures.putIfAbsent(
        id,
        () => _updates.loadExtensionUpdateState(id),
      );

  void _retryExtensionUpdateState(String id) {
    setState(() {
      _extensionUpdateStateFutures.remove(id);
      _readExtensionUpdateState(id);
    });
  }

  Future<void> _refreshSkillsAndUpdateStates() async {
    _extensionUpdateStateFutures.clear();
    await _loadSkills();
  }

  Future<void> _loadSettings() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
    }
    try {
      await _prefs.init();
      _modelController.text = _prefs.model ?? AppConstants.defaultModel;
      _apiFormat = _prefs.apiFormat ?? 'anthropic';
      _themeMode = _prefs.themeMode;
      _fontScale = _prefs.fontScale;
      _notifyOnComplete = _prefs.notifyOnComplete;
      _agentMaxIterations = _prefs.agentMaxIterations;
      _maxConcurrentAgents = _prefs.maxConcurrentAgents;
      _privacyMode = _prefs.privacyMode;
      _developerMode = _prefs.developerMode;
      _allowPhoneCall = _prefs.allowPhoneCall;
      _allowSms = _prefs.allowSms;
      _anthropicPromptCacheEnabled = _prefs.anthropicPromptCacheEnabled;
      _memoryEnabled = _prefs.memoryEnabled;
      _toolApprovalPolicy = _prefs.toolApprovalPolicy;
      _deniedToolNames = _prefs.deniedToolNames;
      _bashCommandDenyPatterns = _prefs.bashCommandDenyPatterns;
      _mcpServers = _prefs.mcpServers;
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
      setState(() {
        _loading = false;
        _loadError = '无法读取本地设置';
      });
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
          color: theme.colorScheme.surfaceContainerHighest.withAlpha(80),
          borderRadius: BorderRadius.circular(AppRadii.m),
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
          color: theme.colorScheme.surfaceContainerHighest.withAlpha(75),
          borderRadius: BorderRadius.circular(AppRadii.m),
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
    setState(() {
      _loadingSkills = true;
      _skillsLoadError = null;
    });
    try {
      final skills = await SkillService.scanSkills();
      if (!mounted) return;
      setState(() {
        _skills = skills;
        _loadingSkills = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingSkills = false;
        _skillsLoadError = '无法读取本地扩展';
      });
    }
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

  String _destinationTitle(SettingsDestination destination) =>
      switch (destination) {
        SettingsDestination.connections => '连接',
        SettingsDestination.agentTools => 'Agent 与工具',
        SettingsDestination.voice => '语音',
        SettingsDestination.dataRecovery => '数据与恢复',
        SettingsDestination.updatesExtensions => '更新与扩展',
        SettingsDestination.privacy => '隐私',
        SettingsDestination.developer => '开发者',
        SettingsDestination.appearanceAbout => '外观与关于',
      };

  Widget _updatesExtensionsPanel(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.android),
                    title: Text('应用更新'),
                    subtitle: Text('当前版本 ${AppConstants.version}'),
                  ),
                  FutureBuilder<AppUpdateStagingState?>(
                    key: ValueKey('app-update-state-$_updateStateEpoch'),
                    future: _appUpdateStateFuture ??= _readAppUpdateState(),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          title: Text('正在读取本地更新状态…'),
                        );
                      }
                      if (snapshot.hasError) {
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.help_outline),
                          title: const Text('更新状态：未知'),
                          subtitle: const Text('无法读取本地更新记录。'),
                          trailing: TextButton(
                            onPressed: _retryAppUpdateState,
                            child: const Text('重试'),
                          ),
                        );
                      }
                      final state = snapshot.data;
                      final status = state == null
                          ? '尚无已验证的待处理更新'
                          : switch (state.stage) {
                              AppUpdateStage.verified => '已验证，可交给系统安装器',
                              AppUpdateStage.handedOff => '系统安装器已打开',
                              AppUpdateStage.installedObserved => '已观察到安装完成',
                            };
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          state == null
                              ? Icons.info_outline
                              : Icons.verified_outlined,
                        ),
                        title: Text(status),
                        subtitle: Text(
                          _lastUpdateCheckAt == null
                              ? '上次检查：本次运行尚未检查'
                              : '上次检查：${_lastUpdateResult ?? '已完成'}',
                        ),
                      );
                    },
                  ),
                  FilledButton.icon(
                    onPressed: _loadingSkills
                        ? null
                        : () async {
                            await _showAppUpdate();
                            if (mounted) _retryAppUpdateState();
                          },
                    icon: const Icon(Icons.system_update_alt),
                    label: const Text('检查应用更新'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.extension_outlined),
                    title: Text('技能与扩展'),
                    subtitle: Text('更新由签名预览确认；不会自动下载或安装。'),
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _showImportSkillDialog,
                        icon: const Icon(Icons.add),
                        label: const Text('导入技能'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _showLocalExtensionUpdate,
                        icon: const Icon(Icons.folder_open),
                        label: const Text('从本地更新'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _refreshSkillsAndUpdateStates,
                        icon: const Icon(Icons.refresh),
                        label: const Text('刷新'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_loadingSkills)
                    const ListTile(
                      leading: SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      title: Text('正在读取本地扩展…'),
                    )
                  else if (_skillsLoadError != null)
                    ListTile(
                      leading: const Icon(Icons.help_outline),
                      title: Text(_skillsLoadError!),
                      subtitle: const Text('本地扩展检查未完成。'),
                      trailing: TextButton(
                        onPressed: _refreshSkillsAndUpdateStates,
                        child: const Text('重试'),
                      ),
                    )
                  else if (_skills.isEmpty)
                    const ListTile(
                      leading: Icon(Icons.extension_off_outlined),
                      title: Text(AppStrings.noSkillsFound),
                      subtitle: Text('可导入本地技能，或稍后重试刷新。'),
                    )
                  else
                    for (final skill in _skills) _skillUpdateTile(theme, skill),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _skillUpdateTile(ThemeData theme, SkillInfo skill) {
    return FutureBuilder<ExtensionUpdateState?>(
      future: skill.isCliManaged
          ? Future<ExtensionUpdateState?>.value()
          : _readExtensionUpdateState(skill.id),
      builder: (context, snapshot) {
        final state = snapshot.data;
        final loading = snapshot.connectionState == ConnectionState.waiting;
        return Card.outlined(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('${skill.name} · v${skill.version}'),
                  subtitle: Text(skill.isUnavailable
                      ? skill.availabilityReason!
                      : !skill.valid
                          ? '扩展无效，操作已禁用'
                          : skill.isCliManaged
                              ? skill.requiresConsent
                                  ? skill.isLegacyCompatibility
                                      ? '由 xd-skill CLI 管理 · 需要重新授权 XDS 兼容能力'
                                      : '由 xd-skill CLI 管理 · 授权后可启用'
                                  : skill.enabled
                                      ? '由 xd-skill CLI 管理 · 已启用'
                                      : '由 xd-skill CLI 管理 · 已停用'
                              : loading
                                  ? '正在读取本地更新历史…'
                                  : snapshot.hasError
                                      ? '更新历史状态未知'
                                      : state == null
                                          ? '无本地更新历史或回滚备份'
                                          : '已更新至 v${state.version} · 可回滚'),
                  value: skill.enabled,
                  onChanged: skill.valid && !skill.isUnavailable
                      ? (value) async {
                          if (value && skill.requiresConsent) {
                            await _requestInstalledSkillConsent(skill);
                          } else {
                            setState(() => skill.enabled = value);
                            await SkillService.setSkillEnabled(
                              skill.id,
                              value,
                            );
                          }
                        }
                      : null,
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: skill.valid &&
                              !skill.isUnavailable &&
                              !skill.isCliManaged
                          ? () => _showRemoteExtensionUpdate(skill)
                          : null,
                      child: Text(SettingsScreen.extensionActionLabels[0]),
                    ),
                    OutlinedButton(
                      onPressed: skill.isUnavailable ||
                              skill.isCliManaged ||
                              loading ||
                              snapshot.hasError
                          ? null
                          : () => _showExtensionHistory(skill, state),
                      child: Text(SettingsScreen.extensionActionLabels[1]),
                    ),
                    OutlinedButton(
                      onPressed: skill.isUnavailable ||
                              skill.isCliManaged ||
                              loading ||
                              state == null
                          ? null
                          : () => _rollbackExtension(skill),
                      child: Text(SettingsScreen.extensionActionLabels[2]),
                    ),
                    if (loading)
                      const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else if (snapshot.hasError)
                      TextButton(
                        onPressed: () => _retryExtensionUpdateState(skill.id),
                        child: const Text('状态未知，重试'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _showExtensionHistory(
    SkillInfo skill,
    ExtensionUpdateState? state,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${skill.name} · 更新历史'),
        content: Text(
          state == null
              ? '没有可用的本地更新记录或回滚备份。'
              : '当前记录：v${state.version}\n修订：${state.revision}\n'
                  '本地备份：可用\n更新时间：${state.updatedAt}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(AppStrings.close),
          ),
        ],
      ),
    );
  }

  Widget _privacyPanel(ThemeData theme) => _settingsGroup(
        theme,
        'privacy_only',
        '隐私',
        [
          SwitchListTile(
            title: const Text(AppStrings.privacyMode),
            subtitle: const Text(AppStrings.privacyModeSubtitle),
            value: _privacyMode,
            onChanged: (value) {
              setState(() => _privacyMode = value);
              _prefs.privacyMode = value;
            },
          ),
          ListTile(
            leading: const Icon(Icons.password_outlined),
            title: const Text(AppStrings.envVars),
            subtitle: Text('${_envVars.length} 项；值始终隐藏'),
            trailing: const Icon(Icons.add),
            onTap: _addEnvVar,
          ),
          for (final entry in _envVars.entries)
            ListTile(
              title: Text(entry.key),
              subtitle: const Text('••••••'),
              trailing: IconButton(
                tooltip: '删除环境变量',
                onPressed: () => _deleteEnvVar(entry.key),
                icon: const Icon(Icons.delete_outline),
              ),
            ),
          ListTile(
            leading: const Icon(Icons.bug_report_outlined),
            title: const Text('导出脱敏诊断'),
            subtitle: const Text('仅包含安全事件、版本与能力摘要'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _exportDiagnostics,
          ),
        ],
      );

  Widget _developerPanel(ThemeData theme) => _settingsGroup(
        theme,
        'developer_only',
        '开发者控制',
        [
          const ListTile(
            leading: Icon(Icons.warning_amber_outlined),
            title: Text('高级功能'),
            subtitle: Text('仅在排障时启用；运行轨迹只保存在本机内存。'),
          ),
          SwitchListTile(
            title: const Text('开发者模式'),
            subtitle: const Text('启用本地 Agent 运行元数据轨迹'),
            value: _developerMode,
            onChanged: (value) {
              setState(() => _developerMode = value);
              context.read<ChatProvider>().setDeveloperMode(value);
            },
          ),
          if (_developerMode)
            ListTile(
              leading: const Icon(Icons.account_tree_outlined),
              title: const Text('Agent 运行详情'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                CupertinoPageRoute<void>(
                  builder: (_) => RunTraceScreen(
                    traceService:
                        context.read<ChatProvider>().runtimeDebugEvents,
                  ),
                ),
              ),
            ),
          ListTile(
            leading: const Icon(Icons.bug_report_outlined),
            title: const Text('导出脱敏诊断'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _exportDiagnostics,
          ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    if (widget.importFlowOnlyForTesting) {
      return Scaffold(
        appBar: AppBar(title: const Text(AppStrings.settings)),
        body: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: AppStrings.importSkill,
                onPressed: _showImportSkillDialog,
              ),
              IconButton(
                icon: const Icon(Icons.system_update_alt),
                tooltip: 'Check signed app update',
                onPressed: _showAppUpdate,
              ),
            ],
          ),
        ),
      );
    }
    final theme = Theme.of(context);
    final remoteBoot = context.watch<RemoteAgentBootController?>();
    final remoteUnavailable = remoteBoot?.isLocalOnly == true;

    return Scaffold(
      appBar: AppBar(title: Text(_destinationTitle(widget.destination))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline, size: 40),
                        const SizedBox(height: 12),
                        Text(_loadError!),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: _loadSettings,
                          icon: const Icon(Icons.refresh),
                          label: const Text('重试'),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  children: [
                    if (widget.destination ==
                        SettingsDestination.updatesExtensions)
                      _updatesExtensionsPanel(theme),
                    if (widget.destination == SettingsDestination.privacy)
                      _privacyPanel(theme),
                    if (widget.destination == SettingsDestination.developer)
                      _developerPanel(theme),
                    if (widget.destination ==
                        SettingsDestination.appearanceAbout)
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
                                      themeNotifier.value =
                                          switch (_themeMode) {
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
                    if (widget.destination == SettingsDestination.voice)
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
                                icon: const Icon(
                                    Icons.record_voice_over_outlined),
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
                    if (widget.destination == SettingsDestination.connections)
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
                        ListTile(
                          leading: const Icon(Icons.cloud_outlined),
                          title: const Text(AppStrings.remoteAgentConnector),
                          subtitle: Text(
                            remoteUnavailable
                                ? '本地安全模式已启用；远程配置证据尚未恢复。'
                                : AppStrings.remoteAgentConnectorSubtitle,
                          ),
                          trailing: remoteUnavailable
                              ? TextButton(
                                  onPressed: remoteBoot!.isAttempting
                                      ? null
                                      : remoteBoot.retry,
                                  child: Text(
                                    remoteBoot.isAttempting ? '正在重试…' : '重试恢复',
                                  ),
                                )
                              : const Icon(Icons.chevron_right),
                          onTap: remoteUnavailable
                              ? null
                              : () => Navigator.of(context).push(
                                    CupertinoPageRoute(
                                      builder: (_) =>
                                          const RemoteAgentSettingsScreen(),
                                    ),
                                  ),
                        ),
                      ]),
                    if (widget.destination == SettingsDestination.agentTools)
                      _settingsGroup(
                        theme,
                        _sectionAgentSkills,
                        AppStrings.settingsAgentSkills,
                        [
                          SwitchListTile(
                            title: const Text(AppStrings.anthropicPromptCache),
                            subtitle: const Text(
                                AppStrings.anthropicPromptCacheSubtitle),
                            value: _anthropicPromptCacheEnabled,
                            onChanged: (v) {
                              HapticFeedback.lightImpact();
                              setState(() => _anthropicPromptCacheEnabled = v);
                              _prefs.anthropicPromptCacheEnabled = v;
                            },
                          ),
                          _settingsDivider(theme),
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
                                        value: PreferencesService
                                            .toolApprovalAlways,
                                        icon: Icon(Icons.help_outline),
                                        label: Text(AppStrings
                                            .toolApprovalPolicyAlways),
                                      ),
                                      ButtonSegment(
                                        value: PreferencesService
                                            .toolApprovalSessionFirst,
                                        icon: Icon(Icons.check_circle_outline),
                                        label: Text(AppStrings
                                            .toolApprovalPolicySessionFirst),
                                      ),
                                      ButtonSegment(
                                        value:
                                            PreferencesService.toolApprovalAuto,
                                        icon: Icon(Icons.flash_on_outlined),
                                        label: Text(
                                            AppStrings.toolApprovalPolicyAuto),
                                      ),
                                    ],
                                    selected: {_toolApprovalPolicy},
                                    onSelectionChanged: (value) {
                                      HapticFeedback.lightImpact();
                                      setState(() {
                                        _toolApprovalPolicy = value.first;
                                      });
                                      _prefs.toolApprovalPolicy =
                                          _toolApprovalPolicy;
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
                                      borderRadius:
                                          BorderRadius.circular(AppRadii.s),
                                      border: Border.all(
                                        color: theme.colorScheme.error
                                            .withAlpha(90),
                                      ),
                                    ),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Icon(
                                          Icons.warning_amber_outlined,
                                          size: 18,
                                          color: theme
                                              .colorScheme.onErrorContainer,
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            AppStrings
                                                .toolApprovalPolicyAutoWarning,
                                            style: theme.textTheme.bodySmall
                                                ?.copyWith(
                                              color: theme
                                                  .colorScheme.onErrorContainer,
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
                          _settingsDivider(theme),
                          _subsectionHeader(theme, AppStrings.toolSafety),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                            child: Text(
                              AppStrings.toolAlwaysDenySubtitle,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: theme.hintColor),
                            ),
                          ),
                          ..._toolSafetyToolNames.map(
                            (toolName) => SwitchListTile(
                              title: Text(toolName),
                              value: _deniedToolNames.contains(toolName),
                              onChanged: (value) {
                                HapticFeedback.lightImpact();
                                _setToolDenied(toolName, value);
                              },
                            ),
                          ),
                          _settingsDivider(theme),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: _subsectionHeader(
                                  theme,
                                  AppStrings.bashDenyPatterns,
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: IconButton(
                                  icon: const Icon(Icons.add),
                                  tooltip: AppStrings.addBashDenyPattern,
                                  onPressed: _addBashDenyPattern,
                                ),
                              ),
                            ],
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                            child: Text(
                              AppStrings.bashDenyPatternsSubtitle,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: theme.hintColor),
                            ),
                          ),
                          if (_bashCommandDenyPatterns.isEmpty)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                              child: Text(
                                AppStrings.noBashDenyPatterns,
                                style: TextStyle(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            )
                          else
                            ..._bashCommandDenyPatterns
                                .asMap()
                                .entries
                                .map((entry) => ListTile(
                                      title: Text(entry.value),
                                      trailing: IconButton(
                                        icon: const Icon(Icons.delete_outline),
                                        onPressed: () =>
                                            _removeBashDenyPattern(entry.key),
                                      ),
                                    )),
                          _settingsDivider(theme),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              _subsectionHeader(theme, AppStrings.mcpServers),
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: IconButton(
                                  icon: const Icon(Icons.add),
                                  tooltip: AppStrings.addMcpServer,
                                  onPressed: () => _editMcpServer(),
                                ),
                              ),
                            ],
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                            child: Text(
                              AppStrings.mcpServersSubtitle,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: theme.hintColor),
                            ),
                          ),
                          if (!McpPlatformSupport.isStdioSupported)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                              child: Text(
                                AppStrings.mcpStdioUnsupportedAndroid,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.error,
                                ),
                              ),
                            ),
                          if (_mcpServers.isEmpty)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                              child: Text(
                                AppStrings.noMcpServers,
                                style: TextStyle(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            )
                          else
                            ..._mcpServers.map(
                              (server) => ListTile(
                                leading: const Icon(Icons.extension_outlined),
                                title: Text(server.displayName),
                                subtitle: Text(
                                  [
                                    server.command,
                                    if (server.args.isNotEmpty)
                                      '${server.args.length} args',
                                    if (server.env.isNotEmpty)
                                      '${server.env.length} env',
                                  ].join(' · '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.edit_outlined),
                                      tooltip: AppStrings.editMcpServer,
                                      onPressed: () => _editMcpServer(server),
                                    ),
                                    Switch(
                                      value: server.enabled,
                                      onChanged: McpPlatformSupport
                                              .isStdioSupported
                                          ? (value) async {
                                              HapticFeedback.lightImpact();
                                              await _saveMcpServer(
                                                server.copyWith(enabled: value),
                                              );
                                            }
                                          : null,
                                    ),
                                  ],
                                ),
                                onTap: () => _editMcpServer(server),
                                shape: Border(
                                  bottom: BorderSide(
                                    color: theme.dividerColor.withAlpha(60),
                                  ),
                                ),
                              ),
                            ),
                          _settingsDivider(theme),
                          SwitchListTile(
                            title: const Text(AppStrings.notifyOnComplete),
                            subtitle:
                                const Text(AppStrings.notifyOnCompleteSubtitle),
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
                                      PreferencesService.maxAgentMaxIterations -
                                          1,
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
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(AppStrings.maxConcurrentAgents(
                                  _maxConcurrentAgents,
                                )),
                                Slider(
                                  value: _maxConcurrentAgents.toDouble(),
                                  min: 1,
                                  max: PreferencesService.maxMaxConcurrentAgents
                                      .toDouble(),
                                  divisions: PreferencesService
                                          .maxMaxConcurrentAgents -
                                      1,
                                  label: '$_maxConcurrentAgents',
                                  onChanged: (v) {
                                    final next = v.round();
                                    setState(() => _maxConcurrentAgents = next);
                                    _prefs.maxConcurrentAgents = next;
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
                                    icon: const Icon(Icons.info_outline,
                                        size: 18),
                                    label: const Text(
                                      AppStrings
                                          .bundledLegacyPresetsUnavailable,
                                    ),
                                    onPressed:
                                        _showBundledLegacyPresetsUnavailable,
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
                                    onPressed: _refreshSkillsAndUpdateStates,
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
                          else if (_skillsLoadError != null)
                            ListTile(
                              leading: const Icon(Icons.help_outline),
                              title: Text(_skillsLoadError!),
                              subtitle: const Text('本地扩展检查未完成。'),
                              trailing: TextButton(
                                onPressed: _refreshSkillsAndUpdateStates,
                                child: const Text('重试'),
                              ),
                            )
                          else if (_skills.isEmpty)
                            const Padding(
                              padding: EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 16),
                              child: Text(AppStrings.noSkillsFound),
                            )
                          else
                            ..._skills.map((skill) => SwitchListTile(
                                  title: Text(
                                    '${skill.name} · ${skill.isLegacyCompatibility ? 'v${skill.version}' : skill.legacy ? 'Legacy' : 'v${skill.version}'}',
                                  ),
                                  subtitle: skill.isUnavailable
                                      ? Text(skill.availabilityReason!)
                                      : Text(
                                          [
                                            if (!skill.valid)
                                              skill.validationError ??
                                                  'Invalid or tampered manifest',
                                            if (skill.valid &&
                                                skill.requiresConsent)
                                              'Consent required before use',
                                            if (skill.isCliManaged)
                                              AppStrings.cliManagedSkill,
                                            if (skill.valid)
                                              'Risk: ${skill.riskTier}',
                                            skill.description,
                                          ].join(' · '),
                                          maxLines: 3,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                  value: skill.enabled,
                                  onChanged: skill.valid && !skill.isUnavailable
                                      ? (v) async {
                                          HapticFeedback.lightImpact();
                                          if (!v) {
                                            setState(
                                                () => skill.enabled = false);
                                            await SkillService.setSkillEnabled(
                                              skill.id,
                                              false,
                                            );
                                            return;
                                          }
                                          if (skill.requiresConsent) {
                                            await _requestInstalledSkillConsent(
                                                skill);
                                            return;
                                          }
                                          setState(() => skill.enabled = true);
                                          await SkillService.setSkillEnabled(
                                              skill.id, true);
                                        }
                                      : null,
                                )),
                        ],
                        collapsedBadges: [
                          _countBadge(
                              theme, '${AppStrings.skills} ${_skills.length}'),
                          _countBadge(
                            theme,
                            '${AppStrings.mcpServers} ${_mcpServers.length}',
                          ),
                        ],
                      ),
                    if (widget.destination == SettingsDestination.dataRecovery)
                      _settingsGroup(
                        theme,
                        _sectionData,
                        AppStrings.settingsData,
                        [
                          _subsectionHeader(theme, AppStrings.dataManagement),
                          ListTile(
                            title: const Text(AppStrings.localDataRecovery),
                            subtitle: const Text(AppStrings.localDataAuthority),
                            leading: const Icon(Icons.shield_outlined),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const LocalDataRecoveryScreen(),
                              ),
                            ),
                          ),
                          ListTile(
                            title: const Text('本地任务中心'),
                            subtitle:
                                const Text('创建、批准并按当前策略执行本机任务；不会自动继续或发送。'),
                            leading: const Icon(Icons.task_alt_outlined),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) =>
                                    const BackgroundTaskCenterScreen(),
                              ),
                            ),
                          ),
                          ListTile(
                            title: const Text(AppStrings.exportConfig),
                            subtitle:
                                const Text(AppStrings.exportConfigSubtitle),
                            leading: const Icon(Icons.upload_file),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: _exportConfig,
                          ),
                          ListTile(
                            title: const Text(AppStrings.importConfig),
                            subtitle:
                                const Text(AppStrings.importConfigSubtitle),
                            leading: const Icon(Icons.download),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: _importConfig,
                          ),
                          ListTile(
                            title: const Text(AppStrings.globalUsageSummary),
                            subtitle:
                                const Text(AppStrings.usageSummarySubtitle),
                            leading: const Icon(Icons.query_stats),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: _showGlobalUsageSummary,
                          ),
                          _settingsDivider(theme),
                          SwitchListTile(
                            title: const Text(AppStrings.memoryEnabled),
                            subtitle:
                                const Text(AppStrings.memoryEnabledSubtitle),
                            value: _memoryEnabled,
                            onChanged: (value) {
                              HapticFeedback.lightImpact();
                              setState(() => _memoryEnabled = value);
                              _prefs.memoryEnabled = value;
                            },
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              _subsectionHeader(
                                  theme, AppStrings.memoryManagement),
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
                                      color:
                                          theme.colorScheme.onSurfaceVariant)),
                            )
                          else
                            ..._memories
                                .asMap()
                                .entries
                                .map((entry) => ListTile(
                                      title: Text(entry.value),
                                      trailing: IconButton(
                                        icon: const Icon(Icons.delete_outline),
                                        onPressed: () =>
                                            _removeMemory(entry.key),
                                      ),
                                    )),
                        ],
                        collapsedBadges: [
                          _countBadge(theme,
                              '${AppStrings.memoryManagement} ${_memories.length}'),
                        ],
                      ),
                    if (widget.destination ==
                        SettingsDestination.appearanceAbout)
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
                              Wrap(
                                alignment: WrapAlignment.center,
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  TextButton.icon(
                                    icon: const Icon(Icons.code, size: 18),
                                    label: const Text('GitHub'),
                                    onPressed: () => launchUrl(
                                        Uri.parse(AppConstants.githubUrl)),
                                  ),
                                  TextButton.icon(
                                    icon: const Icon(
                                      Icons.privacy_tip_outlined,
                                      size: 18,
                                    ),
                                    label: const Text('隐私政策'),
                                    onPressed: () => launchUrl(Uri.parse(
                                        AppConstants.privacyPolicyUrl)),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                  '${AppStrings.license}: ${AppConstants.license}',
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
    _showEnvVarAgentRunningNotice();
  }

  Future<void> _editMcpServer([McpServerConfig? server]) async {
    final nameController =
        TextEditingController(text: server?.displayName ?? '');
    final commandController =
        TextEditingController(text: server?.command ?? '');
    final argsController = TextEditingController(
      text: server?.args.join('\n') ?? '',
    );
    final envController = TextEditingController(
      text: server?.env.entries
              .map((entry) => '${entry.key}=$_mcpHiddenEnvValue')
              .join('\n') ??
          '',
    );
    var enabled = server?.enabled ?? true;

    final result = await showDialog<McpServerConfig>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(
            server == null ? AppStrings.addMcpServer : AppStrings.editMcpServer,
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text(AppStrings.mcpEnabled),
                    value: enabled,
                    onChanged: (value) => setDialogState(() {
                      enabled = value;
                    }),
                  ),
                  TextField(
                    controller: nameController,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: AppStrings.mcpServerName,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: commandController,
                    decoration: const InputDecoration(
                      labelText: AppStrings.mcpCommand,
                      hintText: 'npx',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: argsController,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: AppStrings.mcpArgs,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: envController,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: AppStrings.mcpEnv,
                    ),
                  ),
                  if (server?.env.isNotEmpty == true) ...[
                    const SizedBox(height: 8),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(AppStrings.mcpEnvKeysHidden),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            if (server != null)
              TextButton(
                onPressed: () async {
                  final confirmed = await _confirmDelete(
                    AppStrings.delete,
                    AppStrings.deleteMcpServerConfirm(server.displayName),
                  );
                  if (!confirmed || !ctx.mounted) return;
                  Navigator.pop(ctx);
                  await _deleteMcpServer(server.id);
                },
                child: const Text(AppStrings.delete),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text(AppStrings.cancel),
            ),
            FilledButton(
              onPressed: () {
                final name = nameController.text.trim();
                final command = commandController.text.trim();
                if (name.isEmpty || command.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text(AppStrings.mcpInvalid)),
                  );
                  return;
                }
                Navigator.pop(
                  ctx,
                  McpServerConfig(
                    id: server?.id ?? '',
                    displayName: name,
                    enabled: enabled,
                    command: command,
                    args: _parseMcpArgs(argsController.text),
                    env: _parseMcpEnv(
                      envController.text,
                      existing: server?.env,
                    ),
                  ),
                );
              },
              child: const Text(AppStrings.save),
            ),
          ],
        ),
      ),
    ).whenComplete(() {
      nameController.dispose();
      commandController.dispose();
      argsController.dispose();
      envController.dispose();
    });
    if (result == null || !mounted) return;
    await _saveMcpServer(result);
  }

  Future<void> _saveMcpServer(McpServerConfig server) async {
    final saved = await _prefs.saveMcpServer(
      id: server.id.isEmpty ? null : server.id,
      displayName: server.displayName,
      enabled: server.enabled,
      command: server.command,
      args: server.args,
      env: server.env,
    );
    if (!mounted) return;
    setState(() {
      final index = _mcpServers.indexWhere((item) => item.id == saved.id);
      final next = List<McpServerConfig>.from(_mcpServers);
      if (index >= 0) {
        next[index] = saved;
      } else {
        next.add(saved);
      }
      _mcpServers = next;
    });
  }

  Future<void> _deleteMcpServer(String id) async {
    await _prefs.deleteMcpServer(id);
    if (!mounted) return;
    setState(() {
      _mcpServers = _mcpServers.where((server) => server.id != id).toList();
    });
  }

  List<String> _parseMcpArgs(String text) {
    return text
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
  }

  Map<String, String> _parseMcpEnv(
    String text, {
    Map<String, String>? existing,
  }) {
    final env = <String, String>{};
    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || !trimmed.contains('=')) continue;
      final index = trimmed.indexOf('=');
      final key = trimmed.substring(0, index).trim();
      final value = trimmed.substring(index + 1);
      if (key.isEmpty) continue;
      if (value == _mcpHiddenEnvValue && existing?.containsKey(key) == true) {
        env[key] = existing![key]!;
      } else {
        env[key] = value;
      }
    }
    return env;
  }

  void _setToolDenied(String toolName, bool denied) {
    setState(() {
      if (denied) {
        _deniedToolNames.add(toolName);
      } else {
        _deniedToolNames.remove(toolName);
      }
    });
    _prefs.deniedToolNames = _deniedToolNames;
  }

  Future<void> _addBashDenyPattern() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(AppStrings.addBashDenyPattern),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: AppStrings.bashDenyPatternHint,
          ),
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
    ).whenComplete(controller.dispose);
    if (result == null || result.isEmpty || !mounted) return;
    setState(() {
      _bashCommandDenyPatterns = [..._bashCommandDenyPatterns, result];
    });
    _prefs.bashCommandDenyPatterns = _bashCommandDenyPatterns;
  }

  Future<void> _removeBashDenyPattern(int index) async {
    if (index < 0 || index >= _bashCommandDenyPatterns.length) return;
    final confirmed = await _confirmDelete(
      AppStrings.delete,
      AppStrings.bashDenyPatterns,
    );
    if (!confirmed || !mounted) return;
    setState(() {
      _bashCommandDenyPatterns = [
        for (var i = 0; i < _bashCommandDenyPatterns.length; i++)
          if (i != index) _bashCommandDenyPatterns[i],
      ];
    });
    _prefs.bashCommandDenyPatterns = _bashCommandDenyPatterns;
  }

  void _showEnvVarAgentRunningNotice() {
    if (!mounted) return;
    final provider = context.read<ChatProvider>();
    if (provider.activeAgentSessionIds.isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text(AppStrings.envVarsAgentRunningNotice)),
    );
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

  Future<void> _showBundledLegacyPresetsUnavailable() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(AppStrings.bundledLegacyPresetsUnavailable),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(AppStrings.bundledLegacyPresetsUnavailableDescription),
              const SizedBox(height: 12),
              for (final preset in BundledLegacySkillCatalog.entries) ...[
                Text(preset.assetDirectory),
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(preset.reason),
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
        ],
      ),
    );
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
            hintText: AppStrings.remoteSkillArchiveHint,
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
    PreparedSkillImport? candidate;
    try {
      candidate = await _prepareRemoteSkillWithCancellation(url);
      if (!mounted) {
        await SkillService.discardPreparedImport(candidate);
        return;
      }
      setState(() => _loadingSkills = false);
      final confirmed = await _confirmSkillConsent(candidate);
      if (!confirmed) {
        await SkillService.discardPreparedImport(candidate);
        return;
      }
      if (!mounted) {
        await SkillService.discardPreparedImport(candidate);
        return;
      }
      setState(() => _loadingSkills = true);
      await SkillService.installPreparedSkill(
        candidate,
        inspectionReviewConfirmed: true,
      );
      await _loadSkills();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('${AppStrings.skillsLoaded}: ${candidate.name}')),
      );
    } catch (e) {
      if (candidate != null) {
        await SkillService.discardPreparedImport(candidate);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${AppStrings.importFailed}: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingSkills = false);
    }
  }

  Future<PreparedSkillImport> _prepareRemoteSkillWithCancellation(
    String url,
  ) async {
    final cancellationToken = SkillImportCancellationToken();
    _activeSkillImportCancellation = cancellationToken;
    final navigator = Navigator.of(context, rootNavigator: true);
    var dialogVisible = true;
    var cancelling = false;
    final dialogFuture = showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text(AppStrings.importSkill),
            content: Row(
              children: [
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 3),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    cancelling
                        ? '${AppStrings.cancelSkillImport}…'
                        : AppStrings.preparingSkillArchive,
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: cancelling
                    ? null
                    : () {
                        setDialogState(() => cancelling = true);
                        unawaited(cancellationToken.cancel());
                      },
                child: const Text(AppStrings.cancelSkillImport),
              ),
            ],
          ),
        ),
      ),
    );
    unawaited(dialogFuture.whenComplete(() => dialogVisible = false));

    try {
      final prepare = widget.prepareSkillFromUrlForTesting ??
          (String value, SkillImportCancellationToken token) =>
              SkillService.prepareSkillFromUrl(
                value,
                cancellationToken: token,
              );
      final candidate = await prepare(url, cancellationToken);
      if (cancellationToken.isCancelled) {
        await SkillService.discardPreparedImport(candidate);
        throw StateError('Skill import cancelled.');
      }
      return candidate;
    } finally {
      if (identical(_activeSkillImportCancellation, cancellationToken)) {
        _activeSkillImportCancellation = null;
      }
      await cancellationToken.dispose();
      if (dialogVisible && navigator.mounted) navigator.pop();
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
      if (!mounted) return;
      setState(() {
        _envVars[keyController.text.trim()] = valueController.text;
      });
      _prefs.envVars = _envVars;
      _showEnvVarAgentRunningNotice();
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
            const ListTile(
              leading: Icon(Icons.folder),
              title: Text(AppStrings.directory),
              subtitle: Text(AppStrings.directorySkillImportUnavailable),
              enabled: false,
            ),
          ],
        ),
      ),
    );
    if (mode == null) return;

    String? path;
    if (mode == 'archive') {
      PlatformFile? selected;
      try {
        selected = await FileAttachmentService.pickSkillArchive();
        if (selected == null) return;
        path = await FileAttachmentService.localPathFor(selected);
      } on FilePickerException catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                error.reason == 'unsupported_archive'
                    ? AppStrings.selectSkillArchive
                    : error.userMessage,
              ),
            ),
          );
        }
        return;
      }
    }
    if (path == null || path.isEmpty) return;

    setState(() => _loadingSkills = true);
    PreparedSkillImport? candidate;
    try {
      candidate = await SkillService.prepareSkillFromLocalPath(path);
      if (!mounted) {
        await SkillService.discardPreparedImport(candidate);
        return;
      }
      setState(() => _loadingSkills = false);
      final confirmed = await _confirmSkillConsent(candidate);
      if (!confirmed) {
        await SkillService.discardPreparedImport(candidate);
        return;
      }
      if (!mounted) {
        await SkillService.discardPreparedImport(candidate);
        return;
      }
      setState(() => _loadingSkills = true);
      await SkillService.installPreparedSkill(
        candidate,
        inspectionReviewConfirmed: true,
      );
      await _loadSkills();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('${AppStrings.skillsLoaded}: ${candidate.name}')),
      );
    } catch (e) {
      if (candidate != null) {
        await SkillService.discardPreparedImport(candidate);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${AppStrings.importFailed}: $e')),
        );
      }
    } finally {
      await FileAttachmentService.cleanupLocalPath(path);
      if (mounted) setState(() => _loadingSkills = false);
    }
  }

  Future<void> _requestInstalledSkillConsent(SkillInfo skill) async {
    setState(() => _loadingSkills = true);
    try {
      final candidate =
          await SkillService.prepareConsentForInstalledSkill(skill);
      if (!mounted) return;
      setState(() => _loadingSkills = false);
      if (!await _confirmSkillConsent(candidate)) return;
      await SkillService.installPreparedSkill(
        candidate,
        enabled: true,
        inspectionReviewConfirmed: true,
      );
      await _loadSkills();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${AppStrings.importFailed}: $e')),
      );
    } finally {
      if (mounted) setState(() => _loadingSkills = false);
    }
  }

  Future<bool> _confirmSkillConsent(PreparedSkillImport candidate) async {
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => SkillConsentDialog(candidate: candidate),
        ) ??
        false;
  }

  Future<void> _showRemoteExtensionUpdate(SkillInfo skill) async {
    setState(() => _loadingSkills = true);
    ExtensionUpdatePlan? plan;
    try {
      plan = await _prepareUpdateWithCancellation(
        'Checking and staging signed extension update…',
        (token) async {
          final check = await _updates.checkExtensionUpdate(
            skill,
            cancellationToken: token,
          );
          return _updates.planExtensionUpdate(
            check,
            cancellationToken: token,
          );
        },
      );
      if (!mounted) {
        await _updates.discardExtensionPlan(plan!);
        return;
      }
      setState(() => _loadingSkills = false);
      final confirmed = await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (_) => UpdatePreviewDialog.extension(plan: plan!),
          ) ??
          false;
      if (!confirmed) {
        await _updates.discardExtensionPlan(plan!);
        return;
      }
      await _updates.applyExtensionUpdate(plan!);
      _extensionUpdateStateFutures.remove(skill.id);
      plan = null;
      await _loadSkills();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Extension updated with local backup.')),
        );
      }
    } catch (error) {
      if (plan != null) await _updates.discardExtensionPlan(plan);
      _showUpdateError(error);
    } finally {
      if (mounted) setState(() => _loadingSkills = false);
    }
  }

  Future<void> _showLocalExtensionUpdate() async {
    var metadataPath = '';
    var archivePath = '';
    try {
      final metadataFiles = await FileAttachmentService.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json'],
      );
      if (metadataFiles.isEmpty) return;
      metadataPath = await FileAttachmentService.localPathFor(
        metadataFiles.single,
      );

      final archive = await FileAttachmentService.pickSkillArchive();
      if (archive == null) {
        await FileAttachmentService.cleanupLocalPath(metadataPath);
        return;
      }
      archivePath = await FileAttachmentService.localPathFor(archive);
    } on FilePickerException catch (error) {
      await FileAttachmentService.cleanupLocalPath(metadataPath);
      await FileAttachmentService.cleanupLocalPath(archivePath);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error.reason == 'unsupported_archive'
                  ? AppStrings.selectSkillArchive
                  : error.userMessage,
            ),
          ),
        );
      }
      return;
    }
    if (metadataPath.isEmpty || archivePath.isEmpty) return;

    setState(() => _loadingSkills = true);
    ExtensionUpdatePlan? plan;
    try {
      final metadataBytes = await BoundedFileReader.readBytes(
        metadataPath,
        validateBytes: (count) {
          if (count <= 0 || count > 64 * 1024) {
            throw const FormatException('Update metadata size is invalid.');
          }
        },
      );
      final metadataSource =
          const Utf8Decoder(allowMalformed: false).convert(metadataBytes);
      final parsed = SignedUpdateMetadata.parse(metadataSource);
      final installed = _skills.where((skill) => skill.id == parsed.targetId);
      if (installed.length != 1) {
        throw StateError('Signed update target is not installed.');
      }
      final skill = installed.single;
      if (skill.isCliManaged) {
        throw StateError(
          'CLI-managed skills must be updated with xd-skill.',
        );
      }
      final check = await _updates.checkLocalMetadata(
        metadataSource,
        expectedKind: UpdateArtifactKind.extension,
        expectedTargetId: skill.id,
        currentVersion: skill.version,
        sourceIdentity:
            'Local metadata: ${File(metadataPath).uri.pathSegments.last}',
      );
      plan = await _updates.planExtensionUpdate(
        check,
        localArtifactPath: archivePath,
      );
      if (!mounted) {
        await _updates.discardExtensionPlan(plan);
        return;
      }
      setState(() => _loadingSkills = false);
      final confirmed = await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (_) => UpdatePreviewDialog.extension(plan: plan!),
          ) ??
          false;
      if (!confirmed) {
        await _updates.discardExtensionPlan(plan);
        return;
      }
      await _updates.applyExtensionUpdate(plan);
      plan = null;
      _extensionUpdateStateFutures.clear();
      await _loadSkills();
    } catch (error) {
      if (plan != null) await _updates.discardExtensionPlan(plan);
      _showUpdateError(error);
    } finally {
      await FileAttachmentService.cleanupLocalPath(metadataPath);
      await FileAttachmentService.cleanupLocalPath(archivePath);
      if (mounted) setState(() => _loadingSkills = false);
    }
  }

  Future<void> _rollbackExtension(SkillInfo skill) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Rollback extension update?'),
            content: Text(
              'Restore the verified local backup for ${skill.name}? Current '
              'live files must still match the applied update.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text(AppStrings.cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Rollback'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    setState(() => _loadingSkills = true);
    try {
      await _updates.rollbackExtension(skill.id);
      _extensionUpdateStateFutures.remove(skill.id);
      await _loadSkills();
    } catch (error) {
      _showUpdateError(error);
    } finally {
      if (mounted) setState(() => _loadingSkills = false);
    }
  }

  Future<void> _showAppUpdate() async {
    var enteredUrl = '';
    final metadataUrl = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Check signed app update'),
        content: TextField(
          autofocus: true,
          keyboardType: TextInputType.url,
          onChanged: (value) => enteredUrl = value,
          decoration: const InputDecoration(
            labelText: 'HTTPS metadata URL',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text(AppStrings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              dialogContext,
              enteredUrl.trim(),
            ),
            child: const Text('Check'),
          ),
        ],
      ),
    );
    if (metadataUrl == null || metadataUrl.isEmpty) return;
    setState(() {
      _lastUpdateCheckAt = DateTime.now();
      _lastUpdateResult = '检查中';
    });
    AppUpdatePlan? plan;
    setState(() => _loadingSkills = true);
    try {
      plan = await _prepareUpdateWithCancellation(
        'Checking and downloading signed app update…',
        (token) async {
          final check = await _updates.checkAppUpdate(
            metadataUrl,
            cancellationToken: token,
          );
          return _updates.planAppUpdate(
            check,
            cancellationToken: token,
          );
        },
      );
      if (!mounted) {
        await _updates.discardAppPlan(plan!);
        return;
      }
      setState(() => _loadingSkills = false);
      final confirmed = await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (_) => UpdatePreviewDialog.app(plan: plan!),
          ) ??
          false;
      if (!confirmed) {
        await _updates.discardAppPlan(plan!);
        return;
      }
      await _updates.handoffAppUpdate(plan!);
      if (mounted) setState(() => _lastUpdateResult = '系统安装器已打开');
      plan = null;
    } catch (error) {
      if (mounted) setState(() => _lastUpdateResult = '检查未完成');
      if (plan != null) await _updates.discardAppPlan(plan);
      _showUpdateError(error);
    } finally {
      if (mounted) setState(() => _loadingSkills = false);
    }
  }

  void _showUpdateError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Secure update failed: $error')),
    );
  }

  Future<T> _prepareUpdateWithCancellation<T>(
    String label,
    Future<T> Function(UpdateCancellationToken token) operation,
  ) async {
    final token = UpdateCancellationToken();
    _activeUpdateCancellation = token;
    final navigator = Navigator.of(context, rootNavigator: true);
    var dialogVisible = true;
    final dialog = showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('Secure staged update'),
          content: Row(
            children: [
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              const SizedBox(width: 16),
              Expanded(child: Text(label)),
            ],
          ),
          actions: [
            TextButton(
              onPressed: token.cancel,
              child: const Text('Cancel update'),
            ),
          ],
        ),
      ),
    );
    unawaited(dialog.whenComplete(() => dialogVisible = false));
    try {
      return await operation(token);
    } finally {
      if (identical(_activeUpdateCancellation, token)) {
        _activeUpdateCancellation = null;
      }
      if (dialogVisible && navigator.mounted) navigator.pop();
    }
  }

  Future<void> _loadMemories() async {
    setState(() => _loadingMemories = true);
    _memories = List.from(await MemoryService.getMemories());
    if (mounted) setState(() => _loadingMemories = false);
  }

  Future<void> _exportDiagnostics() async {
    try {
      final report = await (widget.diagnosticsReportBuilderForTesting?.call() ??
          context.read<ChatProvider>().buildDiagnosticsReport());
      String? destinationError;
      while (mounted) {
        final destination = await _showDiagnosticsPreview(
          report,
          destinationError: destinationError,
        );
        if (destination == null || !mounted) return;
        destinationError = null;
        switch (destination) {
          case _DiagnosticsDestination.copy:
            await Clipboard.setData(ClipboardData(text: report));
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text(AppStrings.copied)),
            );
            return;
          case _DiagnosticsDestination.save:
            try {
              final saved = await _saveDiagnosticsReport(report);
              if (!saved || !mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text(AppStrings.saved)),
              );
              return;
            } catch (_) {
              destinationError = '保存失败，内容未复制。可重试保存或选择其他去向。';
              continue;
            }
          case _DiagnosticsDestination.share:
            try {
              final opened = await (widget.diagnosticsShareForTesting?.call(
                    report,
                  ) ??
                  NativeBridge.shareText(
                    text: report,
                    subject: 'ClawChat diagnostics',
                  ));
              if (!opened) throw StateError('share unavailable');
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text(AppStrings.shareSheetOpened)),
              );
              return;
            } catch (_) {
              destinationError = '分享未打开，内容未复制。可重试分享、保存文件或明确选择复制。';
              continue;
            }
        }
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法生成脱敏诊断预览')),
      );
    }
  }

  Future<_DiagnosticsDestination?> _showDiagnosticsPreview(
    String report, {
    String? destinationError,
  }) {
    return showDialog<_DiagnosticsDestination>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('预览脱敏诊断'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('包含：应用版本、本地能力、脱敏错误码与事件摘要。'),
                const SizedBox(height: 4),
                const Text('不包含：消息、提示词、工具载荷、端点、凭据或密钥。'),
                if (destinationError != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    destinationError,
                    style: TextStyle(
                      color: Theme.of(dialogContext).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Container(
                  constraints: const BoxConstraints(maxHeight: 220),
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(dialogContext)
                        .colorScheme
                        .surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(AppRadii.s),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(report),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text(AppStrings.close),
          ),
          TextButton.icon(
            onPressed: () => Navigator.pop(
              dialogContext,
              _DiagnosticsDestination.copy,
            ),
            icon: const Icon(Icons.copy_outlined),
            label: const Text(AppStrings.copy),
          ),
          TextButton.icon(
            onPressed: () => Navigator.pop(
              dialogContext,
              _DiagnosticsDestination.save,
            ),
            icon: const Icon(Icons.save_alt),
            label: const Text(AppStrings.saveFile),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(
              dialogContext,
              _DiagnosticsDestination.share,
            ),
            icon: const Icon(Icons.share_outlined),
            label: Text(
              destinationError == null ? AppStrings.share : '重试分享',
            ),
          ),
        ],
      ),
    );
  }

  Future<bool> _saveDiagnosticsReport(String report) async {
    final injected = widget.diagnosticsSaveForTesting;
    if (injected != null) return injected(report);
    final date = DateTime.now().toIso8601String().split('T').first;
    final path = await FilePicker.saveFile(
      dialogTitle: '保存脱敏诊断',
      fileName: 'clawchat-diagnostics-$date.txt',
      type: FileType.custom,
      allowedExtensions: const ['txt'],
      bytes: Uint8List.fromList(utf8.encode(report)),
    );
    return path != null && path.isNotEmpty;
  }

  Future<void> _showGlobalUsageSummary() async {
    try {
      final storage = SessionStorage();
      await storage.init();
      final aggregate = await storage.getUsageSummaryAggregate();
      if (!mounted) return;
      await _showUsageSummaryDialog(
        title: AppStrings.globalUsageSummary,
        subtitle: '${aggregate.sessionCount} 个会话',
        summary: aggregate.summary,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('读取用量统计失败: $e')),
      );
    }
  }

  Future<void> _showUsageSummaryDialog({
    required String title,
    required String subtitle,
    required UsageSummary summary,
  }) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              subtitle,
              style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 12),
            _usageRow(ctx, AppStrings.usageMessages,
                '${summary.messagesWithUsage}/${summary.messageCount}'),
            _usageRow(ctx, AppStrings.usageInputTokens,
                _formatTokenCount(summary.inputTokens)),
            _usageRow(ctx, AppStrings.usageOutputTokens,
                _formatTokenCount(summary.outputTokens)),
            _usageRow(ctx, AppStrings.usageTotalTokens,
                _formatTokenCount(summary.totalTokens)),
            _usageRow(
              ctx,
              AppStrings.usageCacheTokens,
              summary.hasCacheUsage
                  ? [
                      if (summary.cacheReadInputTokens != null)
                        'read ${_formatTokenCount(summary.cacheReadInputTokens!)}',
                      if (summary.cacheCreationInputTokens != null)
                        'create ${_formatTokenCount(summary.cacheCreationInputTokens!)}',
                    ].join(' · ')
                  : AppStrings.usageUnavailable,
            ),
            _usageRow(
              ctx,
              AppStrings.usageCost,
              AppStrings.usageCostUnavailable,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(AppStrings.close),
          ),
        ],
      ),
    );
  }

  Widget _usageRow(BuildContext context, String label, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  String _formatTokenCount(int value) {
    if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(2)}M';
    if (value >= 1000) return '${(value / 1000).toStringAsFixed(1)}K';
    return value.toString();
  }

  Future<void> _exportConfig() async {
    try {
      final options = await _showExportConfigDialog();
      if (options == null) return;

      if (!options.encrypt && options.includePlaintextSecrets) {
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
        includePlaintextSecrets: options.includePlaintextSecrets,
      );
      final date = DateTime.now().toIso8601String().split('T').first;
      final bytes = utf8.encode(jsonStr);
      final path = await FilePicker.saveFile(
        dialogTitle: AppStrings.exportConfig,
        fileName: 'clawchat-config-$date.json',
        type: FileType.custom,
        allowedExtensions: ['json'],
        bytes: Uint8List.fromList(bytes),
      );
      if (path == null || path.isEmpty) return;
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
    var includePlaintextSecrets = false;
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
                  onChanged: (value) => setDialogState(() {
                    encrypt = value;
                    if (encrypt) includePlaintextSecrets = false;
                  }),
                ),
                if (!encrypt) ...[
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text(AppStrings.exportConfigRedactedByDefault),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text(AppStrings.exportConfigPlaintextSecrets),
                    subtitle: const Text(
                      AppStrings.exportConfigPlaintextSecretsSubtitle,
                    ),
                    value: includePlaintextSecrets,
                    onChanged: (value) => setDialogState(
                      () => includePlaintextSecrets = value,
                    ),
                  ),
                ],
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
                    includePlaintextSecrets:
                        !encrypt && includePlaintextSecrets,
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
      final result = await FilePicker.pickFiles(
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
            mcpServers: importResult.mcpServersImported,
            mcpSkipped: importResult.mcpServersSkipped,
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
                  AppStrings.mcpServers,
                  preview.mcpServerCount >= 0
                      ? '${preview.mcpServerCount}'
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
    final activeImport = _activeSkillImportCancellation;
    _activeSkillImportCancellation = null;
    if (activeImport != null) unawaited(activeImport.dispose());
    _activeUpdateCancellation?.cancel();
    _activeUpdateCancellation = null;
    _modelController.dispose();
    _whisperModelController.dispose();
    _ttsModelController.dispose();
    super.dispose();
  }
}

class _ConfigExportOptions {
  final bool encrypt;
  final String password;
  final bool includePlaintextSecrets;

  const _ConfigExportOptions({
    required this.encrypt,
    required this.password,
    required this.includePlaintextSecrets,
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
