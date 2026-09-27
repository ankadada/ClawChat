import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants.dart';
import '../layout/foldable_layout.dart';
import '../models/background_task.dart';
import '../models/chat_models.dart';
import '../models/tool_command_lifecycle.dart';
import '../providers/chat_provider.dart';
import '../services/machine_health_probe.dart';
import '../services/native_bridge.dart';
import '../services/skill_service.dart';
import '../services/update_service.dart';
import '../services/update_transaction.dart';
import '../services/background_task_center_controller.dart';
import 'background_task_center_screen.dart';
import 'settings_screen.dart';
import 'agent_run_center_screen.dart';

enum SystemHealthKind { ready, actionNeeded, unknown }

final class SystemHealthSnapshot {
  const SystemHealthSnapshot({
    required this.runtime,
    required this.runtimeDetail,
    required this.updateState,
    required this.updatesKnown,
    required this.extensionCount,
    required this.extensionsKnown,
    this.diskUsage = const MachineDiskUsage.unknown(),
    this.dnsStatus = MachineDnsStatus.unknown,
    this.lastCommand = MachineLastCommand.none,
  });

  final SystemHealthKind runtime;
  final String runtimeDetail;
  final AppUpdateStagingState? updateState;
  final bool updatesKnown;
  final int extensionCount;
  final bool extensionsKnown;

  /// Disk used by the rootfs and its workspace. Unknown stays unknown.
  final MachineDiskUsage diskUsage;

  /// Guest `/etc/resolv.conf` status.
  final MachineDnsStatus dnsStatus;

  /// Last bash command: running / exited / unknown (plus none on a fresh run).
  final MachineLastCommand lastCommand;
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, this.loadForTesting});

  @visibleForTesting
  final Future<SystemHealthSnapshot> Function()? loadForTesting;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  late Future<SystemHealthSnapshot> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.loadForTesting?.call() ?? _load();
  }

  Future<SystemHealthSnapshot> _load() async {
    // `context.read` (listen: false) is safe in initState and lets the machine
    // tiles report the last command without a second provider dependency.
    final provider = context.read<ChatProvider>();
    SystemHealthKind runtime = SystemHealthKind.unknown;
    var runtimeDetail = '无法读取嵌入式运行时状态';
    try {
      final status = await NativeBridge.getBootstrapStatus();
      final rootfs = status['rootfsExists'] == true;
      final python = status['pythonInstalled'] == true;
      runtime = rootfs && python
          ? SystemHealthKind.ready
          : SystemHealthKind.actionNeeded;
      runtimeDetail =
          rootfs && python ? '嵌入式运行时与 Python 已就绪' : '运行时组件不完整，需要重新初始化';
    } catch (_) {
      runtime = SystemHealthKind.unknown;
    }

    AppUpdateStagingState? updateState;
    var updatesKnown = false;
    try {
      updateState = await UpdateService().loadAppUpdateState(
        AppConstants.packageName,
      );
      updatesKnown = true;
    } catch (_) {
      updateState = null;
      updatesKnown = false;
    }

    var extensionCount = 0;
    var extensionsKnown = false;
    try {
      extensionCount = (await SkillService.scanSkills()).length;
      extensionsKnown = true;
    } catch (_) {
      extensionsKnown = false;
    }

    // Machine-side checks are read-only and never start a proot command.
    var diskUsage = const MachineDiskUsage.unknown();
    var dnsStatus = MachineDnsStatus.unknown;
    var lastCommand = MachineLastCommand.none;
    try {
      final probe = MachineHealthProbe();
      diskUsage = await probe.diskUsage();
      dnsStatus = await probe.dnsStatus();
    } catch (_) {
      diskUsage = const MachineDiskUsage.unknown();
      dnsStatus = MachineDnsStatus.unknown;
    }
    try {
      lastCommand = _lastCommandFor(provider);
    } catch (_) {
      lastCommand = MachineLastCommand.none;
    }
    return SystemHealthSnapshot(
      runtime: runtime,
      runtimeDetail: runtimeDetail,
      updateState: updateState,
      updatesKnown: updatesKnown,
      extensionCount: extensionCount,
      extensionsKnown: extensionsKnown,
      diskUsage: diskUsage,
      dnsStatus: dnsStatus,
      lastCommand: lastCommand,
    );
  }

  MachineLastCommand _lastCommandFor(ChatProvider provider) {
    final interruptedRun = provider.currentInterruptedAgentRun;
    final interruptedUnknown = interruptedRun != null &&
        interruptedRun.toolAttempts.any(
          (attempt) =>
              attempt.toolName == bashToolName &&
              attempt.lifecycle == ToolAttemptLifecycle.interruptedUnknown,
        );
    return classifyLastCommand(
      messages: provider.currentSession?.messages,
      runningNow: provider.agentStatus == AgentStatus.tooling,
      interruptedUnknown: interruptedUnknown,
    );
  }

  void _retry() => setState(() {
        _future = widget.loadForTesting?.call() ?? _load();
      });

  void _openSettings(SettingsDestination destination) {
    Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => SettingsScreen(initialDestination: destination),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final media = MediaQuery.of(context);
      final fold = FoldableLayout.resolve(
        constraints.biggest,
        media.displayFeatures,
        bottomInset: media.viewInsets.bottom,
      );
      final content = FutureBuilder<SystemHealthSnapshot>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return Center(
              child: Semantics(
                liveRegion: true,
                label: '正在检查系统健康',
                child: const CircularProgressIndicator(),
              ),
            );
          }
          if (snapshot.hasError || snapshot.data == null) {
            return _errorState();
          }
          return _statusList(snapshot.data!);
        },
      );
      final primary = Scaffold(
        appBar: AppBar(
          title: const Text('系统健康'),
          actions: [
            IconButton(
              tooltip: '刷新系统健康',
              onPressed: _retry,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: content,
      );
      if (!fold.hasSeparatedRegions) return primary;
      return Scaffold(
        body: Stack(children: [
          Positioned.fromRect(
            rect: fold.auxiliary!,
            child: const _HealthAuxiliary(),
          ),
          Positioned.fromRect(rect: fold.primary, child: primary),
        ]),
      );
    });
  }

  Widget _errorState() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.help_outline, size: 44),
              const SizedBox(height: 12),
              const Text('系统状态未知'),
              const SizedBox(height: 4),
              const Text('本地检查未完成。可以安全重试。'),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _retry,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );

  Widget _statusList(SystemHealthSnapshot status) {
    final backgroundTasks =
        context.watch<BackgroundTaskCenterController?>()?.tasks ??
            const <BackgroundTaskRecord>[];
    final provider = context.watch<ChatProvider>();
    final active = provider.activeAgentSessionIds.length;
    final localStorageKind = provider.safeMode
        ? SystemHealthKind.actionNeeded
        : SystemHealthKind.ready;
    final lastCommand = provider.currentSession == null
        ? status.lastCommand
        : _lastCommandFor(provider);
    final disk = status.diskUsage;
    final update = status.updateState;
    final updateDetail = !status.updatesKnown
        ? '更新状态未知'
        : update == null
            ? '没有已验证的待处理应用更新'
            : switch (update.stage) {
                AppUpdateStage.verified => '更新已验证，等待打开系统安装器',
                AppUpdateStage.handedOff => '系统安装器已打开，等待安装结果',
                AppUpdateStage.installedObserved => '已观察到安装完成',
              };
    return ListView(
      key: const PageStorageKey('system-health-list'),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
      children: [
        _healthTile(
          title: '嵌入式运行时',
          detail: status.runtimeDetail,
          kind: status.runtime,
          action: '修复运行时',
          onAction: () => _openSettings(SettingsDestination.appearanceAbout),
        ),
        _healthTile(
          title: '执行上下文',
          detail: provider.currentExecutionContextLabel,
          kind: provider.currentSession == null
              ? SystemHealthKind.unknown
              : SystemHealthKind.ready,
          action: '管理连接',
          onAction: () => _openSettings(SettingsDestination.connections),
        ),
        _healthTile(
          title: '本地存储与恢复',
          detail: provider.safeMode
              ? '安全模式已启用；需要检查本地恢复状态'
              : '${provider.sessions.length} 个本地会话；未检测到安全模式',
          kind: localStorageKind,
          action: '数据与恢复',
          onAction: () => _openSettings(SettingsDestination.dataRecovery),
        ),
        _healthTile(
          title: '应用更新',
          detail: updateDetail,
          kind: !status.updatesKnown
              ? SystemHealthKind.unknown
              : update == null
                  ? SystemHealthKind.ready
                  : SystemHealthKind.actionNeeded,
          action: '查看更新',
          onAction: () => _openSettings(SettingsDestination.updatesExtensions),
        ),
        _healthTile(
          title: '技能与扩展',
          detail: status.extensionsKnown
              ? '${status.extensionCount} 个本地扩展'
              : '扩展状态未知',
          kind: status.extensionsKnown
              ? SystemHealthKind.ready
              : SystemHealthKind.unknown,
          action: '管理扩展',
          onAction: () => _openSettings(SettingsDestination.updatesExtensions),
        ),
        _healthTile(
          title: '后台任务',
          detail: _backgroundTaskDetail(context),
          kind: backgroundTasks.any(
            (task) =>
                task.state == BackgroundTaskState.executing ||
                task.state == BackgroundTaskState.awaitingExternalApproval ||
                task.state == BackgroundTaskState.recoveryRequired ||
                task.state == BackgroundTaskState.unknownOutcome,
          )
              ? SystemHealthKind.actionNeeded
              : SystemHealthKind.ready,
          action: '任务中心',
          onAction: () => Navigator.of(context).push(
            MaterialPageRoute(
                builder: (_) => const BackgroundTaskCenterScreen()),
          ),
        ),
        _healthTile(
          title: 'Agent 任务',
          detail: active == 0 ? '没有活动 Agent 任务' : '$active 个 Agent 任务正在运行',
          kind: active == 0
              ? SystemHealthKind.ready
              : SystemHealthKind.actionNeeded,
          action: '任务中心',
          onAction: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AgentRunCenterScreen()),
          ),
        ),
        _healthTile(
          title: '磁盘占用',
          detail: _diskDetail(disk),
          kind: _diskKind(disk),
          action: '重试检查',
          onAction: _retry,
        ),
        _healthTile(
          title: 'DNS 解析',
          detail: _dnsDetail(status.dnsStatus),
          kind: _dnsKind(status.dnsStatus),
          action: '重试检查',
          onAction: _retry,
        ),
        _healthTile(
          title: '最近命令',
          detail: lastCommand.detail,
          kind: _lastCommandKind(lastCommand),
          action: '重试检查',
          onAction: _retry,
        ),
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            '系统健康只读取本地状态，不上传遥测，也不生成健康分数。',
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }

  String _diskDetail(MachineDiskUsage disk) {
    if (!disk.known) return '无法读取 rootfs 与工作区占用';
    final used = formatHealthBytes(disk.usedBytes ?? 0);
    final workspace = disk.workspaceBytes == null
        ? null
        : formatHealthBytes(disk.workspaceBytes!);
    final free =
        disk.freeBytes == null ? null : formatHealthBytes(disk.freeBytes!);
    final parts = <String>[
      'rootfs 与工作区共 $used',
      if (workspace != null) '工作区 $workspace',
      if (free != null) '可用 $free',
    ];
    return parts.join('；');
  }

  SystemHealthKind _diskKind(MachineDiskUsage disk) {
    if (!disk.known) return SystemHealthKind.unknown;
    final free = disk.freeBytes;
    if (free == null) return SystemHealthKind.ready;
    return free < MachineHealthProbe.lowFreeSpaceBytes
        ? SystemHealthKind.actionNeeded
        : SystemHealthKind.ready;
  }

  String _dnsDetail(MachineDnsStatus status) => switch (status) {
        MachineDnsStatus.ready => 'resolv.conf 已配置可用的名称服务器',
        MachineDnsStatus.missing => '缺少可用的 resolv.conf；网络命令可能无法解析域名',
        MachineDnsStatus.unknown => '无法读取 DNS 配置状态',
      };

  SystemHealthKind _dnsKind(MachineDnsStatus status) => switch (status) {
        MachineDnsStatus.ready => SystemHealthKind.ready,
        MachineDnsStatus.missing => SystemHealthKind.actionNeeded,
        MachineDnsStatus.unknown => SystemHealthKind.unknown,
      };

  SystemHealthKind _lastCommandKind(MachineLastCommand command) =>
      switch (command) {
        MachineLastCommand.unknown => SystemHealthKind.actionNeeded,
        MachineLastCommand.none ||
        MachineLastCommand.running ||
        MachineLastCommand.exited =>
          SystemHealthKind.ready,
      };

  String _backgroundTaskDetail(BuildContext context) {
    final tasks = context.watch<BackgroundTaskCenterController?>()?.tasks ??
        const <BackgroundTaskRecord>[];
    if (tasks.isEmpty) return '没有保存的后台任务';
    final needsReview = tasks.where(
      (task) =>
          task.state == BackgroundTaskState.awaitingExternalApproval ||
          task.state == BackgroundTaskState.recoveryRequired ||
          task.state == BackgroundTaskState.unknownOutcome,
    );
    if (needsReview.isNotEmpty) return '${needsReview.length} 个任务需要检查';
    return '${tasks.length} 个本地任务';
  }

  Widget _healthTile({
    required String title,
    required String detail,
    required SystemHealthKind kind,
    required String action,
    required VoidCallback onAction,
  }) {
    final theme = Theme.of(context);
    final (icon, label, color) = switch (kind) {
      SystemHealthKind.ready => (
          Icons.check_circle_outline,
          '就绪',
          theme.colorScheme.primary
        ),
      SystemHealthKind.actionNeeded => (
          Icons.warning_amber_outlined,
          '需要处理',
          theme.colorScheme.error
        ),
      SystemHealthKind.unknown => (
          Icons.help_outline,
          '未知',
          theme.colorScheme.onSurfaceVariant
        ),
    };
    return Card.outlined(
      child: ListTile(
        minTileHeight: 88,
        leading: Icon(icon, color: color),
        title: Text(title),
        subtitle: Text('$label · $detail'),
        trailing: TextButton(
          key: ValueKey('health-action-$title'),
          onPressed: onAction,
          child: Text(action),
        ),
      ),
    );
  }
}

class _HealthAuxiliary extends StatelessWidget {
  const _HealthAuxiliary();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: const SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.health_and_safety_outlined, size: 44),
                SizedBox(height: 12),
                Text('系统健康', textAlign: TextAlign.center),
                SizedBox(height: 4),
                Text('本地、可操作、无评分', textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
