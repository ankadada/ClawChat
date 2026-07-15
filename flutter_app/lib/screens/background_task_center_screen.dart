import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../layout/foldable_layout.dart';
import '../models/background_task.dart';
import '../services/background_task_center_controller.dart';
import '../services/background_task_definitions.dart';
import '../services/background_task_policy_adapter.dart';

/// A local-only maintenance surface for durable task records.
///
/// The screen exposes only coordinator-owned, foreground user actions. It
/// never retries/requeues a recovered record, and it never renders raw task
/// payload, recipient, target, or external response content.
class BackgroundTaskCenterScreen extends StatefulWidget {
  const BackgroundTaskCenterScreen({super.key, this.controller});

  @visibleForTesting
  final BackgroundTaskCenterController? controller;

  @override
  State<BackgroundTaskCenterScreen> createState() =>
      _BackgroundTaskCenterScreenState();
}

class _BackgroundTaskCenterScreenState
    extends State<BackgroundTaskCenterScreen> {
  BackgroundTaskCenterController? _controller;
  String? _selectedTaskId;

  BackgroundTaskCenterController get controller => _controller!;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller ??=
        widget.controller ?? context.read<BackgroundTaskCenterController>();
  }

  Future<void> _openNewTask() => _showCreateSheet(context, controller);

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final media = MediaQuery.of(context);
          final fold = FoldableLayout.resolve(
            constraints.biggest,
            media.displayFeatures,
            bottomInset: media.viewInsets.bottom,
          );
          final selected = controller.tasks
              .where((task) => task.taskId == _selectedTaskId)
              .firstOrNull;
          final separated = fold.posture == FoldablePosture.book ||
              (fold.posture == FoldablePosture.flat &&
                  constraints.maxWidth >= 720);
          final list = _TaskList(
            tasks: controller.tasks,
            safeError: controller.safeError,
            selectedTaskId: _selectedTaskId,
            onRefresh: controller.refresh,
            onNewTask: _openNewTask,
            onSelected: (task) {
              setState(() => _selectedTaskId = task.taskId);
              if (!separated) {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => _BackgroundTaskDetailScreen(
                      controller: controller,
                      initialTask: task,
                    ),
                  ),
                );
              }
            },
          );
          final listScaffold = Scaffold(
            appBar: AppBar(
              title: const Text('本地任务中心'),
              actions: [
                IconButton(
                  tooltip: '刷新本地任务',
                  onPressed: controller.refresh,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            body: list,
          );
          if (!separated) {
            if (!fold.hasSeparatedRegions) return listScaffold;
            return Scaffold(
              body: Stack(
                children: [
                  Positioned.fromRect(rect: fold.primary, child: listScaffold),
                ],
              ),
            );
          }
          final detail = _TaskDetailPane(
            controller: controller,
            task: selected,
            onNewTask: _openNewTask,
          );
          if (fold.hasSeparatedRegions) {
            return Scaffold(
              body: Stack(
                children: [
                  Positioned.fromRect(rect: fold.primary, child: listScaffold),
                  Positioned.fromRect(rect: fold.auxiliary!, child: detail),
                ],
              ),
            );
          }
          return Scaffold(
            appBar: AppBar(title: const Text('本地任务中心')),
            body: Row(
              children: [
                SizedBox(width: 340, child: list),
                const VerticalDivider(width: 1),
                Expanded(child: detail),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _TaskList extends StatelessWidget {
  const _TaskList({
    required this.tasks,
    required this.safeError,
    required this.selectedTaskId,
    required this.onRefresh,
    required this.onNewTask,
    required this.onSelected,
  });

  final List<BackgroundTaskRecord> tasks;
  final String? safeError;
  final String? selectedTaskId;
  final VoidCallback onRefresh;
  final Future<void> Function() onNewTask;
  final ValueChanged<BackgroundTaskRecord> onSelected;

  @override
  Widget build(BuildContext context) {
    if (tasks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.task_alt_outlined, size: 44),
              const SizedBox(height: 12),
              const Text('没有本地任务记录'),
              const SizedBox(height: 4),
              const Text(
                '这里仅显示这台设备上的任务状态；不会自动继续或发送。',
                textAlign: TextAlign.center,
              ),
              if (safeError != null) ...[
                const SizedBox(height: 12),
                Text(safeError!, textAlign: TextAlign.center),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: onRefresh,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重试读取'),
                ),
              ],
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const Key('task-center-new-task'),
                onPressed: () => unawaited(onNewTask()),
                icon: const Icon(Icons.add_task_outlined),
                label: const Text('前往新建任务'),
              ),
            ],
          ),
        ),
      );
    }
    return ListView.builder(
      key: const PageStorageKey('background-task-center-list'),
      padding: const EdgeInsets.all(12),
      itemCount: tasks.length + 2,
      itemBuilder: (context, index) {
        if (index == 0) {
          return const Padding(
            padding: EdgeInsets.fromLTRB(8, 4, 8, 12),
            child: Text('本机状态汇总：不显示任务内容、目标、收件人或外部响应。'),
          );
        }
        if (index == 1) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: OutlinedButton.icon(
              key: const Key('task-center-new-task'),
              onPressed: () => unawaited(onNewTask()),
              icon: const Icon(Icons.add_task_outlined),
              label: const Text('前往新建任务'),
            ),
          );
        }
        final task = tasks[index - 2];
        final kind = controllerKindLabel(task.taskKind);
        final status = _taskStatus(context, task.state);
        return Card.outlined(
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            key: Key('task-center-record-${task.taskId}'),
            selected: task.taskId == selectedTaskId,
            minTileHeight: 72,
            leading: Icon(status.icon, color: status.color),
            title: Text(kind),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(status.label),
                const SizedBox(height: 2),
                Text(_safePreviewLine(task), maxLines: 2),
              ],
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => onSelected(task),
          ),
        );
      },
    );
  }
}

class _BackgroundTaskDetailScreen extends StatelessWidget {
  const _BackgroundTaskDetailScreen({
    required this.controller,
    required this.initialTask,
  });

  final BackgroundTaskCenterController controller;
  final BackgroundTaskRecord initialTask;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final task = controller.tasks
                .where((candidate) => candidate.taskId == initialTask.taskId)
                .firstOrNull ??
            initialTask;
        return LayoutBuilder(
          builder: (context, constraints) {
            final media = MediaQuery.of(context);
            final fold = FoldableLayout.resolve(
              constraints.biggest,
              media.displayFeatures,
              bottomInset: media.viewInsets.bottom,
            );
            final scaffold = Scaffold(
              appBar: AppBar(title: const Text('任务检查')),
              body: _TaskDetailPane(
                controller: controller,
                task: task,
                onNewTask: () => _showCreateSheet(context, controller),
              ),
            );
            if (!fold.hasSeparatedRegions) return scaffold;
            return Scaffold(
              body: Stack(
                children: [
                  Positioned.fromRect(rect: fold.primary, child: scaffold),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _TaskDetailPane extends StatelessWidget {
  const _TaskDetailPane({
    required this.controller,
    required this.task,
    required this.onNewTask,
  });

  final BackgroundTaskCenterController controller;
  final BackgroundTaskRecord? task;
  final Future<void> Function() onNewTask;

  @override
  Widget build(BuildContext context) {
    final task = this.task;
    if (task == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('选择一项本地任务以检查安全状态。'),
        ),
      );
    }
    final status = _taskStatus(context, task.state);
    final restricted = _isRestricted(task.state);
    final pendingApproval = controller.pendingApprovalFor(task);
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        child: ListView(
          key: Key('task-center-detail-${task.taskId}'),
          padding: const EdgeInsets.all(20),
          children: [
            Icon(status.icon, size: 40, color: status.color),
            const SizedBox(height: 12),
            Text(
              controllerKindLabel(task.taskKind),
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(status.label),
            const SizedBox(height: 20),
            _DetailSection(
              title: '预览摘要',
              child: _PreviewDetail(task: task),
            ),
            const SizedBox(height: 16),
            _DetailSection(
              title: '恢复状态',
              child: _RecoveryDetail(task: task),
            ),
            if (pendingApproval != null) ...[
              const SizedBox(height: 16),
              _TaskApprovalRequest(
                controller: controller,
                prompt: pendingApproval,
              ),
            ],
            if (restricted) ...[
              const SizedBox(height: 16),
              const Text('为保护本地状态，此记录不能在这里继续、重试或执行。'),
            ],
            const SizedBox(height: 20),
            if (!restricted) ...[
              _TaskExecutionControls(
                controller: controller,
                task: task,
                onApprovePlan: () => _approvePlan(context, task),
              ),
              const SizedBox(height: 8),
            ],
            OutlinedButton.icon(
              key: const Key('task-center-inspect'),
              onPressed: () => _showInspection(context, task),
              icon: const Icon(Icons.fact_check_outlined),
              label: const Text('检查已保存预览'),
            ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              key: const Key('task-center-discard'),
              onPressed: (task.state == BackgroundTaskState.unknownOutcome ||
                      task.state == BackgroundTaskState.recoveryRequired)
                  ? () => unawaited(_discard(context, task))
                  : null,
              icon: const Icon(Icons.delete_outline),
              label: const Text('弃置本地任务'),
            ),
            if (task.state == BackgroundTaskState.invalid) ...[
              const SizedBox(height: 8),
              Text(
                '无效记录只能检查或创建新任务；它不会继续。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 8),
            FilledButton.icon(
              key: const Key('task-center-new-task'),
              onPressed: () => unawaited(onNewTask()),
              icon: const Icon(Icons.add_task_outlined),
              label: const Text('前往新建任务'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _discard(BuildContext context, BackgroundTaskRecord task) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('弃置本地任务？'),
        content: const Text('这只会弃置本机恢复记录，不会继续、重试或发送任务。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('弃置'),
          ),
        ],
      ),
    );
    if (!context.mounted || confirmed != true) return;
    await controller.discardAfterRecovery(task);
  }

  Future<void> _approvePlan(
    BuildContext context,
    BackgroundTaskRecord task,
  ) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('批准本地计划？'),
        content: const Text('已保存的预览会成为本次任务的固定计划。此操作不会立即执行或发送。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('批准计划'),
          ),
        ],
      ),
    );
    if (!context.mounted || approved != true) return;
    await controller.approvePlan(task);
  }

  void _showInspection(BuildContext context, BackgroundTaskRecord task) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('已保存的本地预览'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SingleChildScrollView(child: Text(_inspectionText(task))),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
}

class _TaskExecutionControls extends StatelessWidget {
  const _TaskExecutionControls({
    required this.controller,
    required this.task,
    required this.onApprovePlan,
  });

  final BackgroundTaskCenterController controller;
  final BackgroundTaskRecord task;
  final Future<void> Function() onApprovePlan;

  @override
  Widget build(BuildContext context) {
    final blocked =
        controller.isBusy(task.taskId) || controller.hasPendingApproval;
    return switch (task.state) {
      BackgroundTaskState.previewReady => FilledButton.icon(
          key: const Key('task-center-approve-plan'),
          onPressed: blocked ? null : () => unawaited(onApprovePlan()),
          icon: const Icon(Icons.verified_user_outlined),
          label: const Text('批准本地计划'),
        ),
      BackgroundTaskState.localApproved => FilledButton.icon(
          key: const Key('task-center-dispatch'),
          onPressed:
              blocked ? null : () => unawaited(controller.dispatch(task)),
          icon: const Icon(Icons.play_arrow_outlined),
          label: const Text('按当前策略开始'),
        ),
      BackgroundTaskState.awaitingExternalApproval => FilledButton.icon(
          key: const Key('task-center-confirm-external'),
          onPressed: blocked
              ? null
              : () => unawaited(controller.confirmExternalSend(task)),
          icon: const Icon(Icons.send_outlined),
          label: const Text('显示即时外发确认'),
        ),
      BackgroundTaskState.approvedNotStarted ||
      BackgroundTaskState.executing =>
        const Text('此记录正在受控执行或等待恢复检查；不会在此重新启动。'),
      _ => const SizedBox.shrink(),
    };
  }
}

class _TaskApprovalRequest extends StatelessWidget {
  const _TaskApprovalRequest({
    required this.controller,
    required this.prompt,
  });

  final BackgroundTaskCenterController controller;
  final BackgroundTaskApprovalPrompt prompt;

  @override
  Widget build(BuildContext context) {
    final external = prompt.kind == BackgroundTaskApprovalKind.externalSend;
    return _DetailSection(
      title: external ? '即时外发确认' : '当前执行批准',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            external ? '此操作可能向外部应用发送内容。请确认本次外发。' : '当前策略要求确认本次本地执行。',
          ),
          const SizedBox(height: 8),
          Text(
            '安全目标：${prompt.safeTargetSummary}',
            key: Key('task-center-approval-target-${prompt.task.taskId}'),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                key: const Key('task-center-deny-operation'),
                onPressed: () => controller.resolvePendingApproval(
                  taskId: prompt.task.taskId,
                  sessionId: prompt.task.sessionId,
                  operationId: prompt.operationId,
                  previewDigest: prompt.task.previewDigest!,
                  safeTargetSummary: prompt.safeTargetSummary,
                  approved: false,
                ),
                child: const Text('拒绝本次操作'),
              ),
              FilledButton(
                key: const Key('task-center-approve-operation'),
                onPressed: () => controller.resolvePendingApproval(
                  taskId: prompt.task.taskId,
                  sessionId: prompt.task.sessionId,
                  operationId: prompt.operationId,
                  previewDigest: prompt.task.previewDigest!,
                  safeTargetSummary: prompt.safeTargetSummary,
                  approved: true,
                ),
                child: Text(external ? '确认外发' : '批准本次操作'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PreviewDetail extends StatelessWidget {
  const _PreviewDetail({required this.task});

  final BackgroundTaskRecord task;

  @override
  Widget build(BuildContext context) {
    final preview = task.preview;
    if (preview == null) {
      return const Text('没有可显示的本地预览；此任务不会从这里启动。');
    }
    final unknownCount = preview.unknowns.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_sanitizePreview(preview.safeSummary)),
        const SizedBox(height: 8),
        Text('影响类别：${_sanitizePreview(preview.sideEffectSummary)}'),
        if (unknownCount > 0) ...[
          const SizedBox(height: 8),
          Text('有 $unknownCount 项本地未知信息，需要在恢复时重新检查。'),
        ],
        const SizedBox(height: 8),
        const Text('不显示任务内容、目标、收件人或外部响应。'),
      ],
    );
  }
}

class _RecoveryDetail extends StatelessWidget {
  const _RecoveryDetail({required this.task});

  final BackgroundTaskRecord task;

  @override
  Widget build(BuildContext context) {
    final reason = _safeRecoveryReason(task.recoveryReason);
    if (reason == null) return const Text('尚未产生需要恢复的本地状态。');
    return Text(reason);
  }
}

class _DetailSection extends StatelessWidget {
  const _DetailSection({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Card.outlined(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              child,
            ],
          ),
        ),
      );
}

Future<void> _showCreateSheet(
  BuildContext context,
  BackgroundTaskCenterController controller,
) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _CreateBackgroundTaskSheet(controller: controller),
  );
}

class _CreateBackgroundTaskSheet extends StatefulWidget {
  const _CreateBackgroundTaskSheet({required this.controller});

  final BackgroundTaskCenterController controller;

  @override
  State<_CreateBackgroundTaskSheet> createState() =>
      _CreateBackgroundTaskSheetState();
}

class _CreateBackgroundTaskSheetState
    extends State<_CreateBackgroundTaskSheet> {
  late RegisteredBackgroundTaskKind _selected;
  final _text = TextEditingController();
  final _subject = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    _selected = widget.controller.registeredKinds.first;
  }

  @override
  void dispose() {
    _text.dispose();
    _subject.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('新建本地任务', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text('只创建本地预览；不会执行、发送或请求外部批准。'),
            const SizedBox(height: 16),
            for (final kind in widget.controller.registeredKinds)
              RadioListTile<String>(
                value: kind.kind,
                groupValue: _selected.kind,
                contentPadding: EdgeInsets.zero,
                title: Text(kind.label),
                subtitle: Text(kind.description),
                onChanged: (value) {
                  if (value == null) return;
                  setState(() {
                    _selected = widget.controller.kindFor(value)!;
                    _error = null;
                  });
                },
              ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('task-center-new-task-input'),
              controller: _text,
              minLines: 3,
              maxLines: 6,
              maxLength: 2000,
              decoration: InputDecoration(
                labelText: _selected.inputLabel,
                alignLabelWithHint: true,
              ),
            ),
            if (_selected.subjectLabel != null) ...[
              const SizedBox(height: 8),
              TextField(
                key: const Key('task-center-new-task-subject'),
                controller: _subject,
                maxLength: 120,
                decoration: InputDecoration(labelText: _selected.subjectLabel),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const Key('task-center-create-preview'),
                onPressed: () async {
                  if (_text.text.trim().isEmpty) {
                    setState(() => _error = '请先填写任务内容。');
                    return;
                  }
                  final created = await widget.controller.createPreview(
                    kind: _selected.kind,
                    text: _text.text,
                    subject:
                        _selected.subjectLabel == null ? null : _subject.text,
                  );
                  if (created != null && context.mounted) {
                    Navigator.of(context).pop();
                  }
                },
                icon: const Icon(Icons.visibility_outlined),
                label: const Text('创建本地预览'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

bool _isRestricted(BackgroundTaskState state) =>
    state == BackgroundTaskState.invalid ||
    state == BackgroundTaskState.recoveryRequired ||
    state == BackgroundTaskState.unknownOutcome;

String controllerKindLabel(String kind) => switch (kind) {
      BackgroundTaskProductionDefinitions.rememberFactKind => '保存本地记忆',
      BackgroundTaskProductionDefinitions.shareTextKind => '通过系统分享文本',
      _ => '不受支持的本地任务',
    };

final class _TaskStatus {
  const _TaskStatus(this.label, this.icon, this.color);

  final String label;
  final IconData icon;
  final Color color;
}

_TaskStatus _taskStatus(BuildContext context, BackgroundTaskState state) {
  final colors = Theme.of(context).colorScheme;
  return switch (state) {
    BackgroundTaskState.draft =>
      _TaskStatus('正在准备预览', Icons.edit_outlined, colors.primary),
    BackgroundTaskState.previewReady =>
      _TaskStatus('预览已就绪', Icons.visibility_outlined, colors.primary),
    BackgroundTaskState.localApproved =>
      _TaskStatus('已批准本地计划', Icons.verified_user_outlined, colors.primary),
    BackgroundTaskState.awaitingExternalApproval =>
      _TaskStatus('等待外部确认', Icons.approval_outlined, colors.tertiary),
    BackgroundTaskState.approvedNotStarted =>
      _TaskStatus('已批准，尚未开始', Icons.pause_circle_outline, colors.primary),
    BackgroundTaskState.executing =>
      _TaskStatus('正在执行', Icons.pending_outlined, colors.primary),
    BackgroundTaskState.succeeded =>
      _TaskStatus('已完成', Icons.check_circle_outline, colors.primary),
    BackgroundTaskState.failed =>
      _TaskStatus('失败', Icons.error_outline, colors.error),
    BackgroundTaskState.denied =>
      _TaskStatus('已拒绝', Icons.block_outlined, colors.error),
    BackgroundTaskState.cancelled =>
      _TaskStatus('已弃置', Icons.cancel_outlined, colors.onSurfaceVariant),
    BackgroundTaskState.unknownOutcome =>
      _TaskStatus('结果未知，需要检查', Icons.help_outline, colors.error),
    BackgroundTaskState.recoveryRequired =>
      _TaskStatus('需要恢复检查', Icons.history_toggle_off, colors.tertiary),
    BackgroundTaskState.invalid =>
      _TaskStatus('本地数据无效', Icons.warning_amber_outlined, colors.error),
  };
}

String _safePreviewLine(BackgroundTaskRecord task) =>
    _sanitizePreview(task.preview?.safeSummary);

String _inspectionText(BackgroundTaskRecord task) {
  final rows = <String>[
    '状态：${_taskStatusText(task.state)}',
    '本地预览：${_sanitizePreview(task.preview?.safeSummary)}',
  ];
  rows.add('本页面不显示任务内容、目标、收件人或外部响应。');
  return rows.join('\n\n');
}

String _taskStatusText(BackgroundTaskState state) => switch (state) {
      BackgroundTaskState.draft => '正在准备预览',
      BackgroundTaskState.previewReady => '预览已就绪',
      BackgroundTaskState.localApproved => '已批准本地计划',
      BackgroundTaskState.awaitingExternalApproval => '等待外部确认',
      BackgroundTaskState.approvedNotStarted => '已批准，尚未开始',
      BackgroundTaskState.executing => '正在执行',
      BackgroundTaskState.succeeded => '已完成',
      BackgroundTaskState.failed => '失败',
      BackgroundTaskState.denied => '已拒绝',
      BackgroundTaskState.cancelled => '已弃置',
      BackgroundTaskState.unknownOutcome => '结果未知，需要检查',
      BackgroundTaskState.recoveryRequired => '需要恢复检查',
      BackgroundTaskState.invalid => '本地数据无效',
    };

String _sanitizePreview(String? summary) {
  if (summary == null || summary.trim().isEmpty) return '没有可显示的本地预览。';
  var value = summary.replaceAll(RegExp(r'\s+'), ' ').trim();
  value = value.replaceAll(
    RegExp(r'https?://[^\s]+', caseSensitive: false),
    '[已隐藏地址]',
  );
  value = value.replaceAll(
    RegExp(r'\b[^\s@]+@[^\s@]+\.[^\s@]+\b'),
    '[已隐藏收件人]',
  );
  value = value.replaceAll(
    RegExp(r'\+?\d[\d\s().-]{6,}\d'),
    '[已隐藏号码]',
  );
  value = value.replaceAll(
    RegExp(
      r'\b(?:token|secret|password|api[_-]?key|authorization|bearer)\s*[:=]\s*[^\s,;]+',
      caseSensitive: false,
    ),
    '[已隐藏敏感值]',
  );
  if (value.length > 240) return '${value.substring(0, 237)}...';
  return value;
}

String? _safeRecoveryReason(String? reason) => switch (reason) {
      null => null,
      'process_loss_after_started' => '应用中断后无法确认任务结果。',
      'process_loss_before_execution' => '应用中断前未证明任务已开始。',
      'foreground_lease_interrupted' => '前台执行状态已中断。',
      'execution_outcome_unknown' => '本机无法确认任务结果。',
      'execution_exception_unknown' => '本机无法确认任务是否完成。',
      'task_kind_unregistered' => '任务类型无法验证。',
      'task_preflight_denied' => '当前安全检查未通过。',
      _ => '本地恢复信息需要检查。',
    };
