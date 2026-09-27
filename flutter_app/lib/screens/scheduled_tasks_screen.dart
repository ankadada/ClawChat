import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../models/background_task.dart';
import '../models/scheduled_task.dart';
import '../services/background_task_store.dart';
import '../services/scheduled_task_service.dart';

/// Local schedule management for already-created background tasks.
///
/// This screen never executes anything. A due plan [materializes] into the
/// existing task center, where the user still confirms the actual run.
class ScheduledTasksScreen extends StatefulWidget {
  const ScheduledTasksScreen({
    super.key,
    this.service,
    this.availableTasks = const [],
    this.taskStore,
    this.onOpenTaskCenter,
  });

  /// Injectable for tests; defaults to the local preferences-backed service.
  final ScheduledTaskService? service;

  /// Background tasks the user may attach a plan to. Empty means the screen
  /// loads them from [taskStore] instead, so the settings entry can create a
  /// plan without going through the task center first.
  final List<BackgroundTaskRecord> availableTasks;

  /// Where the selectable tasks come from when none are injected; defaults to
  /// the same protected store the task center uses. Reading it never
  /// schedules or executes anything.
  final BackgroundTaskStore? taskStore;

  /// Where a due plan can be confirmed. Null hides the shortcut; the task
  /// center is still reachable from settings.
  final VoidCallback? onOpenTaskCenter;

  @override
  State<ScheduledTasksScreen> createState() => _ScheduledTasksScreenState();
}

class _ScheduledTasksScreenState extends State<ScheduledTasksScreen> {
  late final ScheduledTaskService _service =
      widget.service ?? ScheduledTaskService();
  List<ScheduledTaskRecord> _plans = const [];
  List<BackgroundTaskRecord> _availableTasks = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _availableTasks = widget.availableTasks;
    _reload();
  }

  Future<void> _refreshAvailableTasks() async {
    final tasks = await _loadStoreTasks();
    if (!mounted) return;
    setState(() => _availableTasks = tasks);
  }

  /// Reads the tasks the user already created and approved. A missing plugin
  /// or an unreadable store keeps the screen usable with an empty list.
  Future<List<BackgroundTaskRecord>> _loadStoreTasks() async {
    try {
      final store = widget.taskStore ?? SecureBackgroundTaskStore();
      return await store.readAll();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _reload() async {
    if (mounted) setState(() => _loading = true);
    try {
      final plans = await _service.list();
      if (!mounted) return;
      setState(() {
        _plans = plans;
        _loading = false;
        _error = null;
      });
      if (widget.availableTasks.isEmpty) {
        // Non-blocking: the plan list renders immediately and the selectable
        // tasks arrive as soon as the protected store answers.
        unawaited(_refreshAvailableTasks());
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '无法读取本地计划';
      });
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _pause(ScheduledTaskRecord plan) async {
    try {
      await _service.pause(plan.scheduleId);
    } catch (_) {
      _showMessage('暂停失败：本地计划没有变化');
      return;
    }
    await _reload();
  }

  Future<void> _resume(ScheduledTaskRecord plan) async {
    final now = DateTime.now().toUtc();
    try {
      if (plan.isFinished) {
        if (plan.cadence == ScheduledTaskCadence.once) {
          // A consumed one-shot plan needs a new explicit time; never resurrect
          // it silently.
          final next = await _pickTime('为这个一次性计划选择新的执行时间');
          if (next == null) return;
          await _service.resume(plan.scheduleId, nextRunAt: next);
        } else {
          // The service advances one interval from the base time.
          await _service.resume(plan.scheduleId, nextRunAt: now);
        }
      } else {
        await _service.resume(plan.scheduleId);
      }
    } catch (_) {
      _showMessage('继续失败：本地计划没有变化');
      return;
    }
    await _reload();
  }

  Future<void> _delete(ScheduledTaskRecord plan) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('删除计划'),
        content: Text(
          '将删除「${plan.taskId}」这条本地计划；已创建的后台任务与其中的数据不受影响。'
          '删除后无法恢复，需要时可以重新创建。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text(AppStrings.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogCtx).colorScheme.error,
              foregroundColor: Theme.of(dialogCtx).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _service.delete(plan.scheduleId);
    } catch (_) {
      _showMessage('删除失败：本地计划没有变化');
      return;
    }
    await _reload();
    _showMessage('已删除计划：${plan.taskId}');
  }

  Future<DateTime?> _pickTime(String title) async {
    final now = DateTime.now().toUtc();
    final choice = await showDialog<Duration>(
      context: context,
      builder: (dialogCtx) => SimpleDialog(
        title: Text(title),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogCtx, const Duration(hours: 1)),
            child: const Text('1 小时后'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogCtx, const Duration(hours: 3)),
            child: const Text('3 小时后'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogCtx, const Duration(days: 1)),
            child: const Text('明天这个时候'),
          ),
        ],
      ),
    );
    return choice == null ? null : now.add(choice);
  }

  Future<void> _create() async {
    if (_availableTasks.isEmpty) {
      final openTaskCenter = widget.onOpenTaskCenter;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('请先在任务中心创建并批准一个本地任务'),
          action: openTaskCenter == null
              ? null
              : SnackBarAction(
                  label: '去任务中心',
                  onPressed: openTaskCenter,
                ),
        ),
      );
      return;
    }
    final created = await showDialog<bool>(
      context: context,
      builder: (_) => _CreatePlanDialog(
        service: _service,
        tasks: _availableTasks,
        existingPlanTaskIds: _plans.map((plan) => plan.taskId).toSet(),
      ),
    );
    if (created != true) return;
    await _reload();
    _showMessage('已创建计划；到期后需要你在任务中心再次确认');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now().toUtc();
    return Scaffold(
      appBar: AppBar(
        title: const Text('计划执行'),
        actions: [
          IconButton(
            tooltip: '刷新计划',
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.schedule_outlined),
        label: const Text('新建计划'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline, size: 32),
                        const SizedBox(height: 8),
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: _reload,
                          child: const Text(AppStrings.retry),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                      child: Text(
                        '到期后只在任务中心提示“待确认”，需要你再次确认才会执行；'
                        '不会自动发送、不会在后台调用模型，也不会绕过审批。',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.hintColor),
                      ),
                    ),
                    if (_plans.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          children: [
                            const Icon(Icons.schedule_outlined, size: 32),
                            const SizedBox(height: 8),
                            const Text('暂无计划'),
                            const SizedBox(height: 4),
                            Text(
                              _availableTasks.isEmpty
                                  ? '先在任务中心创建并批准一个本地任务，再回到这里安排时间。'
                                  : '点右下角“新建计划”安排时间；到期后仍需要你在任务中心确认才会执行。',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodySmall,
                            ),
                            if (_availableTasks.isEmpty &&
                                widget.onOpenTaskCenter != null) ...[
                              const SizedBox(height: 8),
                              TextButton.icon(
                                onPressed: widget.onOpenTaskCenter,
                                icon: const Icon(
                                  Icons.task_alt_outlined,
                                  size: 18,
                                ),
                                label: const Text('去任务中心创建并批准任务'),
                              ),
                            ],
                          ],
                        ),
                      )
                    else
                      ..._plans.map((plan) => Card.outlined(
                            child: ExpansionTile(
                              leading: Icon(
                                plan.paused
                                    ? Icons.pause_circle_outline
                                    : plan.isFinished
                                        ? Icons.check_circle_outline
                                        : Icons.schedule_outlined,
                              ),
                              title: Text(plan.taskId),
                              subtitle: Text(
                                [
                                  plan.kind,
                                  plan.cadence == ScheduledTaskCadence.interval
                                      ? '每 ${plan.intervalMinutes} 分钟'
                                      : '仅一次',
                                  plan.nextRunSummary(now),
                                  plan.lastOutcomeSummary,
                                ].join(' · '),
                              ),
                              childrenPadding:
                                  const EdgeInsets.fromLTRB(16, 0, 16, 12),
                              children: [
                                if (plan.history.isEmpty)
                                  const Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text('还没有执行记录'),
                                  )
                                else
                                  ...plan.history.map(
                                    (run) => ListTile(
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                      leading: Icon(
                                        run.succeeded
                                            ? Icons.check_circle_outline
                                            : Icons.error_outline,
                                        size: 18,
                                      ),
                                      title: Text(run.backgroundTaskId),
                                      subtitle: Text(
                                        '${run.state} · ${run.startedAt.toLocal()}',
                                      ),
                                    ),
                                  ),
                                const Divider(height: 8),
                                if (plan.isDue(DateTime.now().toUtc()) &&
                                    widget.onOpenTaskCenter != null)
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: TextButton.icon(
                                      icon: const Icon(Icons.task_alt_outlined,
                                          size: 18),
                                      label: const Text('在任务中心确认执行'),
                                      onPressed: widget.onOpenTaskCenter,
                                    ),
                                  ),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: Wrap(
                                    spacing: 4,
                                    children: [
                                      if (!plan.paused && !plan.isFinished)
                                        TextButton(
                                          onPressed: () => _pause(plan),
                                          child: const Text('暂停'),
                                        ),
                                      if (plan.paused || plan.isFinished)
                                        TextButton(
                                          onPressed: () => _resume(plan),
                                          child: const Text('继续'),
                                        ),
                                      TextButton(
                                        onPressed: () => _delete(plan),
                                        child: const Text('删除'),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          )),
                  ],
                ),
    );
  }
}

class _CreatePlanDialog extends StatefulWidget {
  const _CreatePlanDialog({
    required this.service,
    required this.tasks,
    required this.existingPlanTaskIds,
  });

  final ScheduledTaskService service;
  final List<BackgroundTaskRecord> tasks;
  final Set<String> existingPlanTaskIds;

  @override
  State<_CreatePlanDialog> createState() => _CreatePlanDialogState();
}

class _CreatePlanDialogState extends State<_CreatePlanDialog> {
  BackgroundTaskRecord? _task;
  ScheduledTaskCadence _cadence = ScheduledTaskCadence.once;
  int _intervalMinutes = 60;
  bool _confirmed = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final selectable = widget.tasks
        .where((task) => !widget.existingPlanTaskIds.contains(task.taskId))
        .toList();
    return AlertDialog(
      title: const Text('新建本地计划'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('计划只记录下次时间；执行仍走任务中心的人工确认与审批策略。'),
            const SizedBox(height: 12),
            DropdownButtonFormField<BackgroundTaskRecord>(
              value: _task,
              decoration: const InputDecoration(labelText: '关联的本地任务'),
              items: [
                for (final task in selectable)
                  DropdownMenuItem(
                    value: task,
                    child: Text('${task.taskId} · ${task.taskKind}'),
                  ),
              ],
              onChanged: (value) => setState(() => _task = value),
            ),
            const SizedBox(height: 12),
            SegmentedButton<ScheduledTaskCadence>(
              segments: const [
                ButtonSegment(
                  value: ScheduledTaskCadence.once,
                  label: Text('仅一次'),
                ),
                ButtonSegment(
                  value: ScheduledTaskCadence.interval,
                  label: Text('按间隔重复'),
                ),
              ],
              selected: {_cadence},
              onSelectionChanged: (selection) =>
                  setState(() => _cadence = selection.first),
            ),
            if (_cadence == ScheduledTaskCadence.interval) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                value: _intervalMinutes,
                decoration: const InputDecoration(labelText: '间隔'),
                items: const [
                  DropdownMenuItem(value: 15, child: Text('每 15 分钟')),
                  DropdownMenuItem(value: 30, child: Text('每 30 分钟')),
                  DropdownMenuItem(value: 60, child: Text('每小时')),
                  DropdownMenuItem(value: 360, child: Text('每 6 小时')),
                  DropdownMenuItem(value: 1440, child: Text('每天')),
                ],
                onChanged: (value) =>
                    setState(() => _intervalMinutes = value ?? 60),
              ),
            ],
            const SizedBox(height: 12),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _confirmed,
              onChanged: (value) => setState(() => _confirmed = value ?? false),
              title: const Text('我确认：到期后需要我再次确认才会执行'),
              subtitle: const Text('不会自动发送、不会在后台调用模型。'),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text(AppStrings.cancel),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text(AppStrings.confirm),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    final task = _task;
    if (task == null) {
      setState(() => _error = '请选择要关联的本地任务');
      return;
    }
    if (!_confirmed) {
      setState(() => _error = '请先确认计划不会自动执行');
      return;
    }
    try {
      await widget.service.create(
        taskId: task.taskId,
        kind: task.taskKind,
        cadence: _cadence,
        firstRunAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
        intervalMinutes:
            _cadence == ScheduledTaskCadence.interval ? _intervalMinutes : 60,
      );
    } on ScheduledTaskFormatException {
      if (mounted) setState(() => _error = '无法创建计划：本地记录已满或参数无效');
      return;
    }
    if (mounted) Navigator.pop(context, true);
  }
}
