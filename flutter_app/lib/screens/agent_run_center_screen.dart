import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../layout/foldable_layout.dart';
import '../models/agent_run_center.dart';
import '../models/chat_models.dart';
import '../providers/chat_provider.dart';
import '../l10n/app_strings.dart';

class AgentRunCenterScreen extends StatefulWidget {
  const AgentRunCenterScreen({super.key});

  @override
  State<AgentRunCenterScreen> createState() => _AgentRunCenterScreenState();
}

class _AgentRunCenterScreenState extends State<AgentRunCenterScreen> {
  String? _selectedSessionId;
  Future<List<AgentRunCenterItem>>? _recoverableItems;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _recoverableItems ??=
        context.read<ChatProvider>().loadRecoverableAgentRunCenterItems();
  }

  void _reload() {
    setState(() {
      _recoverableItems =
          context.read<ChatProvider>().loadRecoverableAgentRunCenterItems();
    });
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
      final liveItems = context.watch<ChatProvider>().agentRunCenterItems;
      return FutureBuilder<List<AgentRunCenterItem>>(
        future: _recoverableItems,
        builder: (context, snapshot) {
          final bySession = <String, AgentRunCenterItem>{
            for (final item in snapshot.data ?? const <AgentRunCenterItem>[])
              item.sessionId: item,
            for (final item in liveItems) item.sessionId: item,
          };
          final items = bySession.values.toList(growable: false)
            ..sort((a, b) {
              final activeOrder = (b.isActive ? 1 : 0) - (a.isActive ? 1 : 0);
              return activeOrder != 0
                  ? activeOrder
                  : a.sessionTitle.compareTo(b.sessionTitle);
            });
          final selected = items
              .where((item) => item.sessionId == _selectedSessionId)
              .firstOrNull;
          final separated = fold.posture == FoldablePosture.book ||
              (fold.posture == FoldablePosture.flat &&
                  constraints.maxWidth >= 720);
          final list = _RunList(
            items: items,
            selectedSessionId: _selectedSessionId,
            onSelected: (item) {
              setState(() => _selectedSessionId = item.sessionId);
              if (!separated) {
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => _RunDetailScreen(item: item),
                ));
              }
            },
          );
          final scaffold = Scaffold(
            appBar: AppBar(
              title: const Text(AppStrings.agentRunCenter),
              actions: [
                IconButton(
                  tooltip: '刷新任务状态',
                  onPressed: _reload,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            body: list,
          );
          if (!separated) {
            if (!fold.hasSeparatedRegions) return scaffold;
            return Scaffold(
              body: Stack(children: [
                Positioned.fromRect(rect: fold.primary, child: scaffold),
              ]),
            );
          }
          if (fold.hasSeparatedRegions) {
            return Scaffold(
              body: Stack(children: [
                Positioned.fromRect(rect: fold.primary, child: scaffold),
                Positioned.fromRect(
                  rect: fold.auxiliary!,
                  child: _RunDetailPane(item: selected),
                ),
              ]),
            );
          }
          return Scaffold(
            appBar: AppBar(title: const Text(AppStrings.agentRunCenter)),
            body: Row(children: [
              SizedBox(width: 360, child: list),
              const VerticalDivider(width: 1),
              Expanded(child: _RunDetailPane(item: selected)),
            ]),
          );
        },
      );
    });
  }
}

class _RunList extends StatelessWidget {
  const _RunList({
    required this.items,
    required this.selectedSessionId,
    required this.onSelected,
  });

  final List<AgentRunCenterItem> items;
  final String? selectedSessionId;
  final ValueChanged<AgentRunCenterItem> onSelected;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.task_alt, size: 44),
            SizedBox(height: 12),
            Text('没有需要处理的任务'),
            SizedBox(height: 4),
            Text('这里只显示本机活动、排队、审批与可恢复状态。'),
          ]),
        ),
      );
    }
    return ListView.builder(
      key: const PageStorageKey('agent-run-center-list'),
      padding: const EdgeInsets.all(12),
      itemCount: items.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return const Padding(
            padding: EdgeInsets.fromLTRB(8, 4, 8, 12),
            child: Text('本地状态汇总，不上传遥测或任务内容。'),
          );
        }
        final item = items[index - 1];
        return Card.outlined(
          child: ListTile(
            selected: item.sessionId == selectedSessionId,
            minTileHeight: 72,
            leading: Icon(_phaseIcon(item.phase)),
            title: Text(item.sessionTitle, maxLines: 1),
            subtitle: Text(_itemSubtitle(item)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => onSelected(item),
          ),
        );
      },
    );
  }
}

class _RunDetailScreen extends StatelessWidget {
  const _RunDetailScreen({required this.item});

  final AgentRunCenterItem item;

  @override
  Widget build(BuildContext context) {
    final current = context
            .watch<ChatProvider>()
            .agentRunCenterItems
            .where(
              (candidate) => candidate.sessionId == item.sessionId,
            )
            .firstOrNull ??
        item;
    return LayoutBuilder(builder: (context, constraints) {
      final media = MediaQuery.of(context);
      final fold = FoldableLayout.resolve(
        media.size,
        media.displayFeatures,
        bottomInset: media.viewInsets.bottom,
      );
      final detail = Scaffold(
        appBar: AppBar(title: const Text('任务详情')),
        body: _RunDetailPane(item: current),
      );
      if (!fold.hasSeparatedRegions) return detail;
      return Scaffold(
        body: Stack(children: [
          Positioned.fromRect(rect: fold.primary, child: detail),
        ]),
      );
    });
  }
}

class _RunDetailPane extends StatelessWidget {
  const _RunDetailPane({required this.item});

  final AgentRunCenterItem? item;

  @override
  Widget build(BuildContext context) {
    final item = this.item;
    if (item == null) {
      return const Center(child: Text('选择一项任务查看安全操作'));
    }
    final provider = context.read<ChatProvider>();
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Icon(_phaseIcon(item.phase), size: 40),
            const SizedBox(height: 12),
            Text(item.sessionTitle,
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(_itemSubtitle(item)),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () async {
                await provider.selectSession(item.sessionId);
                if (context.mounted) {
                  Navigator.of(context).popUntil((r) => r.isFirst);
                }
              },
              icon: const Icon(Icons.chat_bubble_outline),
              label: const Text(AppStrings.openConversation),
            ),
            if (item.isActive) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () =>
                    provider.cancelAgent(sessionId: item.sessionId),
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text(AppStrings.cancelOnlyThisRun),
              ),
            ],
            if (item.waitingApproval) ...[
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                onPressed: () async {
                  await provider.selectSession(item.sessionId);
                  if (context.mounted) {
                    Navigator.of(context).popUntil((r) => r.isFirst);
                  }
                },
                icon: const Icon(Icons.approval_outlined),
                label: const Text(AppStrings.reviewApproval),
              ),
            ],
            if (item.recoveryKind != null) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => _inspectRecovery(context, item.recoveryKind!),
                icon: const Icon(Icons.fact_check_outlined),
                label: const Text('检查未知结果'),
              ),
              if (item.recoveryKind != InterruptedRunRecoveryKind.inspectOnly)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: FilledButton.tonalIcon(
                    onPressed: () async {
                      await provider.selectSession(item.sessionId);
                      await provider.continueInterruptedAgentRun();
                    },
                    icon: const Icon(Icons.play_arrow),
                    label: const Text(AppStrings.continueSafeRecovery),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  void _inspectRecovery(
    BuildContext context,
    InterruptedRunRecoveryKind kind,
  ) {
    final detail = switch (kind) {
      InterruptedRunRecoveryKind.unknownOutcome =>
        '旧工具操作结果未知，不会自动重放。若继续，将作为新操作重新评估并请求授权。',
      InterruptedRunRecoveryKind.reauthorizeAction => '旧授权已失效。继续前必须重新审查并授权。',
      InterruptedRunRecoveryKind.retryModelTurn => '只恢复模型回合；已经保存的工具结果不会重新执行。',
      InterruptedRunRecoveryKind.inspectOnly => '恢复元数据无效，已安全停止。请返回会话手动处理。',
    };
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('恢复状态'),
        content: Text(detail),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
}

IconData _phaseIcon(AgentRunCenterPhase phase) => switch (phase) {
      AgentRunCenterPhase.queued => Icons.schedule,
      AgentRunCenterPhase.thinking => Icons.psychology_outlined,
      AgentRunCenterPhase.streaming => Icons.edit_outlined,
      AgentRunCenterPhase.tooling => Icons.build_outlined,
      AgentRunCenterPhase.waitingApproval => Icons.approval_outlined,
      AgentRunCenterPhase.interrupted => Icons.history_toggle_off,
      AgentRunCenterPhase.unknownOutcome => Icons.help_outline,
      AgentRunCenterPhase.recoverableFailure => Icons.error_outline,
    };

String _itemSubtitle(AgentRunCenterItem item) {
  final phase = switch (item.phase) {
    AgentRunCenterPhase.queued => '已排队',
    AgentRunCenterPhase.thinking => '思考中',
    AgentRunCenterPhase.streaming => '生成中',
    AgentRunCenterPhase.tooling => '执行工具',
    AgentRunCenterPhase.waitingApproval => '等待你的审批',
    AgentRunCenterPhase.interrupted => '可安全恢复',
    AgentRunCenterPhase.unknownOutcome => '结果未知，需要检查',
    AgentRunCenterPhase.recoverableFailure => '失败，可返回会话恢复',
  };
  final execution = switch (item.context) {
    AgentRunCenterContext.external => '外部处理',
    AgentRunCenterContext.local => '本地执行上下文',
    AgentRunCenterContext.unknown => '执行上下文未知',
  };
  final identity = item.safeExecutionDisplayName?.trim();
  final identityLabel =
      identity == null || identity.isEmpty ? '' : ' · $identity';
  final queued = item.queuedCount == 0 ? '' : ' · ${item.queuedCount} 项排队';
  return '$phase · $execution$identityLabel$queued';
}
