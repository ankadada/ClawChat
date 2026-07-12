import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/native_bridge.dart';
import '../services/run_trace_export_service.dart';
import '../services/runtime_debug_events.dart';

class RunTraceScreen extends StatefulWidget {
  final RuntimeDebugEventService traceService;
  final RunTraceExportService exportService;

  const RunTraceScreen({
    super.key,
    required this.traceService,
    this.exportService = const RunTraceExportService(),
  });

  @override
  State<RunTraceScreen> createState() => _RunTraceScreenState();
}

class _RunTraceScreenState extends State<RunTraceScreen> {
  List<RunTraceSnapshot> get _traces =>
      widget.traceService.recentRunTraces().reversed.toList(growable: false);

  @override
  Widget build(BuildContext context) {
    final traces = _traces;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Agent 运行详情'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: () => setState(() {}),
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '导出预览',
            onPressed: traces.isEmpty ? null : () => _previewExport(traces),
            icon: const Icon(Icons.ios_share_outlined),
          ),
          IconButton(
            tooltip: '清空',
            onPressed: traces.isEmpty ? null : _confirmClear,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
      body: traces.isEmpty
          ? const _TraceEmptyState()
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
              itemCount: traces.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final trace = traces[index];
                return _TraceListTile(
                  trace: trace,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => RunTraceDetailScreen(
                        trace: trace,
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }

  Future<void> _confirmClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空运行详情？'),
        content: const Text('这会清除当前进程内保存的全部元数据轨迹，且无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    widget.traceService.clearRunTraces();
    setState(() {});
  }

  Future<void> _previewExport(List<RunTraceSnapshot> traces) async {
    final json = widget.exportService.buildJson(traces);
    await _showExportPreview(json);
  }

  Future<void> _showExportPreview(String json) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('脱敏导出预览'),
        content: SizedBox(
          width: 640,
          height: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '仅含本地元数据，不含提示词、消息、工具参数/输出、推理、密钥或接口地址。',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(ctx).colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      json,
                      style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                          ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () async {
              Navigator.pop(ctx);
              await _shareExport(json);
            },
            icon: const Icon(Icons.share_outlined),
            label: const Text('确认分享'),
          ),
        ],
      ),
    );
  }

  Future<void> _shareExport(String json) async {
    try {
      await NativeBridge.shareText(
        text: json,
        subject: 'ClawChat Agent run trace',
      );
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: json));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('系统分享不可用，已复制脱敏内容')),
      );
    }
  }
}

class RunTraceDetailScreen extends StatelessWidget {
  final RunTraceSnapshot trace;

  const RunTraceDetailScreen({
    super.key,
    required this.trace,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('运行时间线'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          _TraceHeader(trace: trace),
          const SizedBox(height: 20),
          Text('事件', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final event in trace.events)
            _TimelineEvent(
              event: event,
              offset: event.timestamp.difference(trace.startedAt),
            ),
        ],
      ),
    );
  }
}

class _TraceListTile extends StatelessWidget {
  final RunTraceSnapshot trace;
  final VoidCallback onTap;

  const _TraceListTile({required this.trace, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(context, trace.status);
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        onTap: onTap,
        leading: Icon(_statusIcon(trace.status), color: color),
        title: Row(
          children: [
            Expanded(child: Text(_shortId(trace.traceId))),
            _StatusChip(status: trace.status),
          ],
        ),
        subtitle: Text(
          '会话 ${_shortId(trace.sessionId)} · ${_formatTime(trace.startedAt)} · ${trace.duration.inMilliseconds} ms',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }
}

class _TraceHeader extends StatelessWidget {
  final RunTraceSnapshot trace;

  const _TraceHeader({required this.trace});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    trace.traceId,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontFamily: 'monospace',
                        ),
                  ),
                ),
                _StatusChip(status: trace.status),
              ],
            ),
            const SizedBox(height: 10),
            Text('会话：${trace.sessionId}'),
            Text('开始：${_formatTime(trace.startedAt)}'),
            Text('耗时：${trace.duration.inMilliseconds} ms'),
            const SizedBox(height: 10),
            Text(
              '仅在内存中保留，应用重启后自动清除。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TimelineEvent extends StatelessWidget {
  final RunTraceEvent event;
  final Duration offset;

  const _TimelineEvent({required this.event, required this.offset});

  @override
  Widget build(BuildContext context) {
    final encoded = event.data.isEmpty ? null : jsonEncode(event.data);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 24,
            child: Column(
              children: [
                const SizedBox(height: 17),
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                Expanded(
                  child: Container(
                    width: 1,
                    color: Theme.of(context).dividerColor,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 0, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${event.sequence}. ${event.type}',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      Text(
                        '+${offset.inMilliseconds} ms',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ],
                  ),
                  if (encoded != null) ...[
                    const SizedBox(height: 4),
                    SelectableText(
                      encoded,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final RunTraceStatus status;

  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(context, status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withAlpha(26),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        _statusLabel(status),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}

class _TraceEmptyState extends StatelessWidget {
  const _TraceEmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.account_tree_outlined,
              size: 44,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text('暂无运行详情', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              '开启开发者模式后，新 Agent 运行会在这里显示。仅记录脱敏元数据。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

String _shortId(String value) {
  if (value.length <= 18) return value;
  return '${value.substring(0, 10)}…${value.substring(value.length - 5)}';
}

String _formatTime(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

String _statusLabel(RunTraceStatus status) => switch (status) {
      RunTraceStatus.inFlight => '运行中',
      RunTraceStatus.completed => '已完成',
      RunTraceStatus.failed => '失败',
      RunTraceStatus.cancelled => '已取消',
      RunTraceStatus.interrupted => '已中断',
    };

IconData _statusIcon(RunTraceStatus status) => switch (status) {
      RunTraceStatus.inFlight => Icons.sync,
      RunTraceStatus.completed => Icons.check_circle_outline,
      RunTraceStatus.failed => Icons.error_outline,
      RunTraceStatus.cancelled => Icons.cancel_outlined,
      RunTraceStatus.interrupted => Icons.pause_circle_outline,
    };

Color _statusColor(BuildContext context, RunTraceStatus status) {
  final scheme = Theme.of(context).colorScheme;
  return switch (status) {
    RunTraceStatus.inFlight => scheme.primary,
    RunTraceStatus.completed => Colors.green.shade700,
    RunTraceStatus.failed => scheme.error,
    RunTraceStatus.cancelled => scheme.onSurfaceVariant,
    RunTraceStatus.interrupted => Colors.orange.shade800,
  };
}
