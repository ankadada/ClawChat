import 'package:flutter/material.dart';

import '../app.dart' show AppRadii;
import '../models/structured_result.dart';

typedef StructuredResultActionHandler = Future<void> Function(
  StructuredResultAction action,
);

/// Renders only the fixed structured-result schema. It has no model-provided
/// callbacks or executable payload handling: an app-owned coordinator supplies
/// [onAction] and owns operation allocation plus persisted receipts.
class StructuredResultCard extends StatefulWidget {
  const StructuredResultCard({
    super.key,
    required this.document,
    required this.isInvalid,
    this.receipts = const [],
    this.onAction,
    this.actionUnavailableReason,
    this.maxHeight,
  });

  final StructuredResultDocument document;
  final bool isInvalid;
  final List<StructuredActionReceipt> receipts;
  final StructuredResultActionHandler? onAction;
  final String? actionUnavailableReason;
  final double? maxHeight;

  @override
  State<StructuredResultCard> createState() => _StructuredResultCardState();
}

class _StructuredResultCardState extends State<StructuredResultCard> {
  final Set<String> _inFlightActionIds = <String>{};

  StructuredActionReceipt? _latestReceipt(String actionId) {
    StructuredActionReceipt? latest;
    for (final receipt in widget.receipts) {
      if (receipt.resultId != widget.document.resultId ||
          receipt.actionId != actionId) {
        continue;
      }
      if (latest == null ||
          receipt.updatedAt.isAfter(latest.updatedAt) ||
          (receipt.updatedAt.isAtSameMomentAs(latest.updatedAt) &&
              receipt.operationId.compareTo(latest.operationId) > 0)) {
        latest = receipt;
      }
    }
    return latest;
  }

  Future<void> _runAction(StructuredResultAction action) async {
    final handler = widget.onAction;
    if (handler == null || _inFlightActionIds.contains(action.actionId)) {
      return;
    }
    setState(() => _inFlightActionIds.add(action.actionId));
    try {
      await handler(action);
    } finally {
      if (mounted) {
        setState(() => _inFlightActionIds.remove(action.actionId));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (widget.isInvalid) return _buildInvalid(theme);

    final blocks = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final block in widget.document.blocks) ...[
          _buildBlock(theme, block),
          if (block != widget.document.blocks.last) const SizedBox(height: 12),
        ],
      ],
    );
    final content = widget.maxHeight == null
        ? Padding(
            padding: const EdgeInsets.all(12),
            child: blocks,
          )
        : ConstrainedBox(
            constraints: BoxConstraints(maxHeight: widget.maxHeight!),
            child: ListView(
              shrinkWrap: true,
              primary: false,
              padding: const EdgeInsets.all(12),
              children: [blocks],
            ),
          );

    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: 'Structured result',
      child: Card.outlined(
        margin: const EdgeInsets.symmetric(vertical: 4),
        clipBehavior: Clip.antiAlias,
        child: content,
      ),
    );
  }

  Widget _buildInvalid(ThemeData theme) => Semantics(
        container: true,
        label: 'Structured result unavailable: invalid data',
        child: ExcludeSemantics(
          child: Card.outlined(
            margin: const EdgeInsets.symmetric(vertical: 4),
            color: theme.colorScheme.errorContainer.withAlpha(100),
            child: const ListTile(
              leading: Icon(Icons.error_outline),
              title: Text('Structured result unavailable'),
              subtitle: Text('This result could not be displayed safely.'),
            ),
          ),
        ),
      );

  Widget _buildBlock(ThemeData theme, StructuredResultBlock block) {
    switch (block) {
      case StructuredNoticeBlock(:final level, :final text):
        final color = switch (level) {
          StructuredNoticeLevel.info => theme.colorScheme.primary,
          StructuredNoticeLevel.warning => theme.colorScheme.tertiary,
          StructuredNoticeLevel.error => theme.colorScheme.error,
        };
        final icon = switch (level) {
          StructuredNoticeLevel.info => Icons.info_outline,
          StructuredNoticeLevel.warning => Icons.warning_amber_outlined,
          StructuredNoticeLevel.error => Icons.error_outline,
        };
        return Semantics(
          label: '${level.name} notice: ${StructuredText.display(text)}',
          child: ExcludeSemantics(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: color.withAlpha(24),
                borderRadius: BorderRadius.circular(AppRadii.s),
                border: Border.all(color: color.withAlpha(96)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, size: 20, color: color),
                    const SizedBox(width: 8),
                    Expanded(child: Text(StructuredText.display(text))),
                  ],
                ),
              ),
            ),
          ),
        );
      case StructuredKeyValueBlock(:final items):
        return Semantics(
          container: true,
          explicitChildNodes: true,
          label: 'Details',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(
                child: Text('Details', style: theme.textTheme.labelLarge),
              ),
              const SizedBox(height: 6),
              for (final item in items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _KeyValueRow(item: item),
                ),
            ],
          ),
        );
      case StructuredItemListBlock(:final title, :final items):
        return Semantics(
          container: true,
          explicitChildNodes: true,
          label: title == null ? 'Items' : StructuredText.display(title),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(
                child: Text(
                  title == null ? 'Items' : StructuredText.display(title),
                  style: theme.textTheme.labelLarge,
                ),
              ),
              const SizedBox(height: 6),
              for (final item in items)
                Semantics(
                  label: StructuredText.display(item),
                  child: ExcludeSemantics(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: Icon(Icons.circle, size: 6),
                          ),
                          const SizedBox(width: 10),
                          Expanded(child: Text(StructuredText.display(item))),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      case StructuredActionListBlock(:final actions):
        return Semantics(
          container: true,
          explicitChildNodes: true,
          label: 'Actions',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(
                child: Text('Actions', style: theme.textTheme.labelLarge),
              ),
              const SizedBox(height: 6),
              for (final action in actions) _buildAction(theme, action),
            ],
          ),
        );
    }
  }

  Widget _buildAction(ThemeData theme, StructuredResultAction action) {
    final inFlight = _inFlightActionIds.contains(action.actionId);
    final receipt = _latestReceipt(action.actionId);
    final enabled = widget.onAction != null && !inFlight;
    final safeSummary =
        receipt == null ? null : StructuredText.display(receipt.safeSummary);
    final stateLabel = _receiptLabel(
      receipt,
      inFlight,
      actionAvailable: widget.onAction != null,
    );
    final semanticLabel = [
      _sentence(StructuredText.display(action.label)),
      _sentence(stateLabel),
      if (safeSummary?.isNotEmpty == true) safeSummary!,
      if (widget.onAction == null &&
          (widget.actionUnavailableReason?.isNotEmpty == true ||
              receipt != null))
        widget.actionUnavailableReason ??
            'Action handling is unavailable in this session',
    ].join(' ');

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        container: true,
        button: true,
        enabled: enabled,
        label: semanticLabel,
        onTap: enabled ? () => _runAction(action) : null,
        child: ExcludeSemantics(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    alignment: Alignment.centerLeft,
                  ),
                  onPressed: enabled ? () => _runAction(action) : null,
                  child: Row(
                    children: [
                      inFlight
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.playlist_add_check_outlined),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(StructuredText.display(action.label)),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                stateLabel,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (safeSummary?.isNotEmpty == true)
                Text(
                  safeSummary!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              if (widget.onAction == null &&
                  (widget.actionUnavailableReason?.isNotEmpty == true ||
                      receipt != null))
                Text(
                  widget.actionUnavailableReason ??
                      'Action handling is unavailable in this session.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _receiptLabel(
    StructuredActionReceipt? receipt,
    bool inFlight, {
    required bool actionAvailable,
  }) {
    if (inFlight) return 'Action in progress';
    if (receipt == null) {
      return actionAvailable
          ? 'Ready for explicit action'
          : widget.actionUnavailableReason ??
              'Action handling is unavailable in this session.';
    }
    return switch (receipt.state) {
      'proposed' => 'Action proposed',
      'approvalPending' => 'Waiting for approval',
      'approvedNotStarted' => 'Approved, not started',
      'started' => 'Action started',
      'completed' => 'Action completed; saving receipt',
      'failed' => 'Action did not complete',
      'interruptedUnknown' => 'Action outcome is unknown',
      'resultPersisted' => receipt.outcomeKnown
          ? 'Action receipt saved'
          : 'Action receipt saved with unknown outcome',
      _ => 'Action receipt is unavailable',
    };
  }

  String _sentence(String value) {
    if (value.endsWith('.') || value.endsWith('!') || value.endsWith('?')) {
      return value;
    }
    return '$value.';
  }
}

class _KeyValueRow extends StatelessWidget {
  const _KeyValueRow({required this.item});

  final StructuredKeyValueItem item;

  @override
  Widget build(BuildContext context) => Semantics(
        label:
            '${StructuredText.display(item.key)}: ${StructuredText.display(item.value)}',
        child: ExcludeSemantics(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                StructuredText.display(item.key),
                style: Theme.of(context).textTheme.labelMedium,
              ),
              const SizedBox(height: 2),
              SelectableText(StructuredText.display(item.value)),
            ],
          ),
        ),
      );
}
