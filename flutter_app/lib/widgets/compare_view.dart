import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../providers/chat_provider.dart';
import '../widgets/streaming_text.dart';
import '../l10n/app_strings.dart';

class CompareView extends StatefulWidget {
  final List<CompareResult> results;
  final bool isComparing;
  final VoidCallback? onDismiss;

  const CompareView({
    super.key,
    required this.results,
    this.isComparing = false,
    this.onDismiss,
  });

  @override
  State<CompareView> createState() => _CompareViewState();
}

class _CompareViewState extends State<CompareView> {
  final _pageController = PageController();
  int _pageIndex = 0;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screenHeight = MediaQuery.of(context).size.height;
    final panelHeight = screenHeight < 760 ? 420.0 : 500.0;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
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
                    icon: const Icon(Icons.close, size: 18),
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
                  return _WideCompareResults(
                    results: widget.results,
                    panelHeight: panelHeight,
                  );
                }
                return PageView.builder(
                  controller: _pageController,
                  itemCount: widget.results.length,
                  onPageChanged: (index) => setState(() => _pageIndex = index),
                  itemBuilder: (context, index) {
                    final r = widget.results[index];
                    return _CompareCard(
                      result: r,
                      index: index,
                      total: widget.results.length,
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
  }
}

class _WideCompareResults extends StatelessWidget {
  final List<CompareResult> results;
  final double panelHeight;

  const _WideCompareResults({
    required this.results,
    required this.panelHeight,
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

  const _CompareCard({
    required this.result,
    required this.index,
    required this.total,
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
            children: [
              Icon(Icons.smart_toy, size: 16, color: theme.colorScheme.primary),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  result.model,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '${index + 1}/$total',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 4),
              if (result.tokens != null)
                Text(
                  '${result.tokens} tokens',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              IconButton(
                icon: const Icon(Icons.copy, size: 16),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
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
          Expanded(
            child: SingleChildScrollView(
              child: StreamingText(text: result.text),
            ),
          ),
        ],
      ),
    );
  }
}
