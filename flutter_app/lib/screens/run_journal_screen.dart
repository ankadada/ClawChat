import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../models/run_journal.dart';
import '../services/run_journal_service.dart';

/// Read-only view of the durable run journal.
///
/// The journal is diagnostics: it lists what each run did, which tool attempts
/// it reached and whether their outcome is proven. It has no resume, retry, or
/// approval action - recovery stays in the session banner / agent run center,
/// where the user confirms explicitly.
class RunJournalScreen extends StatefulWidget {
  const RunJournalScreen({super.key, this.service});

  /// Injectable for tests; defaults to the shared service.
  final RunJournalService? service;

  @override
  State<RunJournalScreen> createState() => _RunJournalScreenState();
}

class _RunJournalScreenState extends State<RunJournalScreen> {
  late final RunJournalService _service =
      widget.service ?? RunJournalService.instance;
  List<RunJournalEntry>? _runs;
  bool _writeFailed = false;
  int _reloadGeneration = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    final generation = ++_reloadGeneration;
    List<RunJournalEntry> loaded;
    try {
      loaded = await _service.recentRuns();
    } catch (_) {
      loaded = const [];
    }
    // A disposed screen, or a newer reload, must not write this result back.
    if (!mounted || generation != _reloadGeneration) return;
    setState(() {
      _runs = loaded;
      _writeFailed = _service.writeFailed;
    });
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text(AppStrings.runJournalClear),
        content: const Text(AppStrings.runJournalClearConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text(AppStrings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text(AppStrings.confirm),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    await _service.clear();
    if (!mounted) return;
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text(AppStrings.runJournal),
        actions: [
          IconButton(
            tooltip: AppStrings.runJournalClear,
            onPressed: _clear,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
          IconButton(
            tooltip: AppStrings.refresh,
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Builder(
        builder: (context) {
          final runs = _runs;
          if (runs == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                child: Text(
                  AppStrings.runJournalNoParams,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.hintColor),
                ),
              ),
              if (_writeFailed || _service.hasIncompleteRuns)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                  child: Text(
                    AppStrings.runJournalIncomplete,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.error),
                  ),
                ),
              if (runs.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: Text(AppStrings.runJournalEmpty)),
                )
              else
                for (final run in runs)
                  Card.outlined(
                    child: ExpansionTile(
                      leading: Icon(
                        _iconFor(run.state),
                        color: run.requiresConfirmation
                            ? theme.colorScheme.error
                            : null,
                      ),
                      title: Text(_labelFor(run.state)),
                      subtitle: Text(
                        [
                          _formatTime(run.startedAt),
                          '${run.toolAttempts.length} 次工具尝试',
                          if (run.endReason != null) run.endReason!,
                          if (_service.isRunIncomplete(run.runAttemptId))
                            '日志可能不完整',
                        ].join(' · '),
                      ),
                      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      children: [
                        if (run.requiresConfirmation)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              '结果未确认：不会自动重跑。请在对应会话的横幅里查看详情并手动继续。',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.error,
                              ),
                            ),
                          ),
                        if (run.toolAttempts.isEmpty)
                          const Align(
                            alignment: Alignment.centerLeft,
                            child: Text('没有工具尝试记录'),
                          )
                        else
                          for (final attempt in run.toolAttempts)
                            ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(
                                attempt.hasUnknownOutcome
                                    ? Icons.help_outline
                                    : attempt.state ==
                                            RunJournalToolState.persisted
                                        ? Icons.check_circle_outline
                                        : Icons.radio_button_unchecked,
                                size: 18,
                              ),
                              title: Text(attempt.toolName),
                              subtitle: Text(
                                '${_toolLabelFor(attempt.state)} · '
                                '${attempt.risk.name} · '
                                '${attempt.resultPersisted ? '结果已入会话' : '结果未确认'}',
                              ),
                            ),
                      ],
                    ),
                  ),
            ],
          );
        },
      ),
    );
  }

  static IconData _iconFor(RunJournalState state) => switch (state) {
        RunJournalState.running => Icons.play_circle_outline,
        RunJournalState.completed => Icons.check_circle_outline,
        RunJournalState.cancelled => Icons.cancel_outlined,
        RunJournalState.failed => Icons.error_outline,
        RunJournalState.interrupted => Icons.pause_circle_outline,
        RunJournalState.unknownOutcome => Icons.help_outline,
      };

  static String _labelFor(RunJournalState state) => switch (state) {
        RunJournalState.running => '运行中',
        RunJournalState.completed => '已完成',
        RunJournalState.cancelled => '已取消',
        RunJournalState.failed => '失败',
        RunJournalState.interrupted => '已中断',
        RunJournalState.unknownOutcome => '结果未知',
      };

  static String _toolLabelFor(RunJournalToolState state) => switch (state) {
        RunJournalToolState.proposed => '已提出',
        RunJournalToolState.approvalPending => '等待审批',
        RunJournalToolState.approved => '已批准未执行',
        RunJournalToolState.started => '已开始',
        RunJournalToolState.completed => '已完成',
        RunJournalToolState.failed => '失败',
        RunJournalToolState.interrupted => '中断（结果未知）',
        RunJournalToolState.persisted => '结果已保存',
      };

  static String _formatTime(DateTime time) {
    final local = time.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}
