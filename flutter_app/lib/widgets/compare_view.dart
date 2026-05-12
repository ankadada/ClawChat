import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../providers/chat_provider.dart';
import '../widgets/streaming_text.dart';
import '../l10n/app_strings.dart';

class CompareView extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

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
                Icon(Icons.compare_arrows, size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 6),
                Text(
                  AppStrings.compareMode,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                  ),
                ),
                if (isComparing) ...[
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
                if (onDismiss != null)
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: onDismiss,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          // Results as horizontally scrollable pages
          SizedBox(
            height: 350,
            child: results.isEmpty
                ? Center(
                    child: Text(
                      AppStrings.comparing,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : PageView.builder(
                    itemCount: results.length,
                    itemBuilder: (context, index) {
                      final r = results[index];
                      return _CompareCard(result: r, index: index, total: results.length);
                    },
                  ),
          ),
        ],
      ),
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
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
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
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: result.text));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text(AppStrings.copied), duration: Duration(seconds: 1)),
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
