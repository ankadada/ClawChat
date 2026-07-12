import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../providers/chat_provider.dart';
import '../widgets/streaming_text.dart';
import '../l10n/app_strings.dart';
import '../screens/full_response_screen.dart';

class CompareView extends StatefulWidget {
  final List<CompareResult> results;
  final bool isComparing;
  final VoidCallback? onDismiss;
  final ValueChanged<int>? onUse;
  final ValueChanged<String>? onCancel;
  final ValueChanged<String>? onRetry;
  final double? maxPanelHeight;

  const CompareView({
    super.key,
    required this.results,
    this.isComparing = false,
    this.onDismiss,
    this.onUse,
    this.onCancel,
    this.onRetry,
    this.maxPanelHeight,
  });

  @override
  State<CompareView> createState() => _CompareViewState();
}

class _CompareViewState extends State<CompareView> {
  final _pageController = PageController();
  int _pageIndex = 0;
  bool _wasWide = false;
  bool _pageRestoreScheduled = false;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, outerConstraints) {
      if (outerConstraints.hasBoundedHeight &&
          outerConstraints.maxHeight < 320) {
        return _buildCompactDecision(context);
      }
      final theme = Theme.of(context);
      final screenHeight = MediaQuery.of(context).size.height;
      final preferredPanelHeight = screenHeight < 760 ? 420.0 : 500.0;
      final constraintMaximum = outerConstraints.hasBoundedHeight
          ? outerConstraints.maxHeight - 80
          : preferredPanelHeight;
      final requestedMaximum = widget.maxPanelHeight;
      final safeMaximum = requestedMaximum == null
          ? constraintMaximum
          : requestedMaximum < constraintMaximum
              ? requestedMaximum
              : constraintMaximum;
      final panelHeight = preferredPanelHeight.clamp(120.0, safeMaximum);

      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border.all(color: theme.colorScheme.outline.withAlpha(80)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
              child: Row(
                children: [
                  Icon(Icons.compare_arrows,
                      size: 18, color: theme.colorScheme.primary),
                  const SizedBox(width: 6),
                  Text(
                    AppStrings.compareMode,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  if (widget.isComparing) ...[
                    const SizedBox(width: 8),
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      AppStrings.comparing,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const Spacer(),
                  if (widget.onDismiss != null)
                    IconButton(
                      icon: Icon(
                        Icons.close,
                        size: 18,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      onPressed: widget.onDismiss,
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 44, minHeight: 44),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            SizedBox(
              height: panelHeight,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if (widget.results.isEmpty) {
                    return Center(
                      child: Text(
                        AppStrings.comparing,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    );
                  }
                  if (constraints.maxWidth > 700) {
                    _wasWide = true;
                    return _WideCompareResults(
                      results: widget.results,
                      panelHeight: panelHeight,
                      onUse: widget.onUse,
                      onCancel: widget.onCancel,
                      onRetry: widget.onRetry,
                    );
                  }
                  if (_wasWide) {
                    _wasWide = false;
                    _pageRestoreScheduled = true;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted) return;
                      if (_pageController.hasClients &&
                          _pageIndex < widget.results.length) {
                        _pageController.jumpToPage(_pageIndex);
                      }
                      _pageRestoreScheduled = false;
                    });
                  }
                  return PageView.builder(
                    controller: _pageController,
                    itemCount: widget.results.length,
                    onPageChanged: (index) {
                      if (_pageRestoreScheduled) return;
                      setState(() => _pageIndex = index);
                    },
                    itemBuilder: (context, index) {
                      final r = widget.results[index];
                      return _CompareCard(
                        result: r,
                        index: index,
                        total: widget.results.length,
                        onUse: widget.onUse,
                        onCancel: widget.onCancel,
                        onRetry: widget.onRetry,
                      );
                    },
                  );
                },
              ),
            ),
            if (widget.results.length > 1)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    if (constraints.maxWidth > 700) {
                      return const SizedBox(height: 6);
                    }
                    return Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(widget.results.length, (index) {
                        final selected = index == _pageIndex;
                        return AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          width: selected ? 18 : 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: selected
                                ? theme.colorScheme.primary
                                : theme.colorScheme.outline.withAlpha(100),
                            borderRadius: BorderRadius.circular(999),
                          ),
                        );
                      }),
                    );
                  },
                ),
              ),
          ],
        ),
      );
    });
  }

  Widget _buildCompactDecision(BuildContext context) {
    if (widget.results.isEmpty) return const SizedBox.shrink();
    final index = _pageIndex.clamp(0, widget.results.length - 1);
    final result = widget.results[index];
    final action = switch (result.state) {
      CompareResultState.complete => FilledButton.icon(
          onPressed: widget.onUse == null ? null : () => widget.onUse!(index),
          icon: const Icon(Icons.check_circle_outline),
          label: const Text(AppStrings.useInConversation),
        ),
      CompareResultState.loading => OutlinedButton.icon(
          onPressed: widget.onCancel == null
              ? null
              : () => widget.onCancel!(result.model),
          icon: const Icon(Icons.stop_circle_outlined),
          label: const Text(AppStrings.cancelOnlyThisResult),
        ),
      CompareResultState.error => FilledButton.tonalIcon(
          onPressed: widget.onRetry == null
              ? null
              : () => widget.onRetry!(result.model),
          icon: const Icon(Icons.refresh),
          label: const Text(AppStrings.retryOnlyThisResult),
        ),
      CompareResultState.cancelled => const SizedBox.shrink(),
    };
    return Material(
      key: const ValueKey('compact-compare-decision'),
      color: Theme.of(context).colorScheme.surface,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(8),
        child: Column(children: [
          Row(children: [
            IconButton(
              tooltip: '上一个结果',
              onPressed: index == 0
                  ? null
                  : () => setState(() => _pageIndex = index - 1),
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: Text(
                '${index + 1}/${widget.results.length} · ${result.model}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
            ),
            IconButton(
              tooltip: '下一个结果',
              onPressed: index >= widget.results.length - 1
                  ? null
                  : () => setState(() => _pageIndex = index + 1),
              icon: const Icon(Icons.chevron_right),
            ),
          ]),
          SizedBox(width: double.infinity, child: action),
        ]),
      ),
    );
  }

  @override
  void didUpdateWidget(CompareView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.results.isEmpty) {
      _pageIndex = 0;
    } else if (_pageIndex >= widget.results.length) {
      _pageIndex = widget.results.length - 1;
    }
  }
}

class _WideCompareResults extends StatelessWidget {
  final List<CompareResult> results;
  final double panelHeight;
  final ValueChanged<int>? onUse;
  final ValueChanged<String>? onCancel;
  final ValueChanged<String>? onRetry;

  const _WideCompareResults({
    required this.results,
    required this.panelHeight,
    this.onUse,
    this.onCancel,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    if (results.length == 1) {
      return Row(
        children: [
          Expanded(
            child: _CompareCard(
              result: results.first,
              index: 0,
              total: results.length,
              onUse: onUse,
              onCancel: onCancel,
              onRetry: onRetry,
            ),
          ),
        ],
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final tileWidth = (constraints.maxWidth - 8) / 2;
        final aspectRatio = tileWidth / panelHeight;
        return GridView.builder(
          padding: EdgeInsets.zero,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 0,
            mainAxisSpacing: 0,
            childAspectRatio: aspectRatio,
          ),
          itemCount: results.length,
          itemBuilder: (context, index) {
            return _CompareCard(
              result: results[index],
              index: index,
              total: results.length,
              onUse: onUse,
              onCancel: onCancel,
              onRetry: onRetry,
            );
          },
        );
      },
    );
  }
}

class _CompareCard extends StatelessWidget {
  final CompareResult result;
  final int index;
  final int total;
  final ValueChanged<int>? onUse;
  final ValueChanged<String>? onCancel;
  final ValueChanged<String>? onRetry;

  const _CompareCard({
    required this.result,
    required this.index,
    required this.total,
    this.onUse,
    this.onCancel,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  Icons.smart_toy,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      result.model,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.onSurface,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      result.tokens == null
                          ? '${index + 1}/$total'
                          : '${index + 1}/$total · ${result.tokens} tokens',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (result.state == CompareResultState.complete)
                IconButton(
                  icon: Icon(
                    Icons.copy,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 44, minHeight: 44),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: result.text));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text(AppStrings.copied),
                          duration: Duration(seconds: 1)),
                    );
                  },
                ),
            ],
          ),
          const Divider(height: 8),
          Expanded(child: _resultBody(context)),
          const SizedBox(height: 8),
          _resultActions(context),
        ],
      ),
    );
  }

  Widget _resultBody(BuildContext context) {
    final theme = Theme.of(context);
    return switch (result.state) {
      CompareResultState.loading => Center(
          child: Semantics(
            liveRegion: true,
            label: '模型结果生成中',
            child: const CircularProgressIndicator(),
          ),
        ),
      CompareResultState.error => Center(
          child: Text(
            '此模型生成失败，可以只重试这一项。',
            style: theme.textTheme.bodyMedium,
          ),
        ),
      CompareResultState.cancelled => const Center(child: Text('已取消此结果')),
      CompareResultState.complete => SingleChildScrollView(
          child: StreamingText(
            text: result.text,
            onOpenFullResponse: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => FullResponseScreen(text: result.text),
              ),
            ),
          ),
        ),
    };
  }

  Widget _resultActions(BuildContext context) {
    return switch (result.state) {
      CompareResultState.complete => SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: onUse == null ? null : () => onUse!(index),
            icon: const Icon(Icons.check_circle_outline),
            label: const Text(AppStrings.useInConversation),
          ),
        ),
      CompareResultState.loading => SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: onCancel == null ? null : () => onCancel!(result.model),
            icon: const Icon(Icons.stop_circle_outlined),
            label: const Text(AppStrings.cancelOnlyThisResult),
          ),
        ),
      CompareResultState.error => SizedBox(
          width: double.infinity,
          child: FilledButton.tonalIcon(
            onPressed: onRetry == null ? null : () => onRetry!(result.model),
            icon: const Icon(Icons.refresh),
            label: const Text(AppStrings.retryOnlyThisResult),
          ),
        ),
      CompareResultState.cancelled => const SizedBox.shrink(),
    };
  }
}
