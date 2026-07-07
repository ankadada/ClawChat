import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import 'streaming_text.dart';

class ReasoningTextPanel extends StatefulWidget {
  static const int autoCollapseThreshold = 4000;
  static const int collapsedPreviewCharacters = 1600;
  static const int expandedRenderCharacters = 14000;

  final String text;
  final int? totalLength;
  final bool isStreaming;

  const ReasoningTextPanel({
    super.key,
    required this.text,
    this.totalLength,
    this.isStreaming = false,
  });

  @override
  State<ReasoningTextPanel> createState() => _ReasoningTextPanelState();
}

class _ReasoningTextPanelState extends State<ReasoningTextPanel> {
  late bool _expanded = _initialExpanded;
  bool _userToggled = false;

  bool get _initialExpanded =>
      !widget.isStreaming &&
      (widget.totalLength ?? widget.text.length) <=
          ReasoningTextPanel.autoCollapseThreshold;

  int get _totalLength => widget.totalLength ?? widget.text.length;

  @override
  void didUpdateWidget(ReasoningTextPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_userToggled) return;
    final shouldExpand = _initialExpanded;
    if (_expanded != shouldExpand) {
      _expanded = shouldExpand;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.text.isEmpty && _totalLength <= 0) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final displayText = _expanded ? _expandedText : _collapsedText;
    final showingRecentOnly = widget.text.length < _totalLength ||
        (!_expanded &&
            widget.text.length >
                ReasoningTextPanel.collapsedPreviewCharacters) ||
        (_expanded &&
            widget.text.length > ReasoningTextPanel.expandedRenderCharacters);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withAlpha(135),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outline.withAlpha(45)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.psychology_alt_outlined,
                  size: 18,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.isStreaming
                        ? AppStrings.reasoningPanelStreaming
                        : AppStrings.reasoningPanelTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: colorScheme.onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  AppStrings.reasoningPanelCharacters(_totalLength),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 4),
                TextButton(
                  onPressed: () {
                    setState(() {
                      _userToggled = true;
                      _expanded = !_expanded;
                    });
                  },
                  child: Text(_expanded
                      ? AppStrings.reasoningPanelCollapse
                      : AppStrings.reasoningPanelExpand),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_expanded)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 360),
                child: SingleChildScrollView(
                  child: StreamingText(text: displayText),
                ),
              )
            else
              Text(
                displayText,
                maxLines: 8,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  height: 1.35,
                ),
              ),
            if (showingRecentOnly) ...[
              const SizedBox(height: 8),
              Text(
                AppStrings.reasoningPanelShowingRecent,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String get _collapsedText {
    final text = widget.text;
    if (text.length <= ReasoningTextPanel.collapsedPreviewCharacters) {
      return text;
    }
    return text
        .substring(text.length - ReasoningTextPanel.collapsedPreviewCharacters);
  }

  String get _expandedText {
    final text = widget.text;
    if (text.length <= ReasoningTextPanel.expandedRenderCharacters) {
      return text;
    }
    return text
        .substring(text.length - ReasoningTextPanel.expandedRenderCharacters);
  }
}
