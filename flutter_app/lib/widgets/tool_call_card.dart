import 'dart:convert';
import 'package:flutter/material.dart';
import '../app.dart';
import '../models/chat_models.dart';
import '../services/tool_call_expansion_state.dart';
import 'code_block.dart';
import '../l10n/app_strings.dart';

class ToolCallCard extends StatefulWidget {
  final ToolUseContent toolUse;

  const ToolCallCard({super.key, required this.toolUse});

  static void clearExpansionState() => ToolCallExpansionState.clear();

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard> {
  bool get _expanded => ToolCallExpansionState.isExpanded(widget.toolUse.id);

  void _toggleExpanded() {
    setState(() {
      ToolCallExpansionState.setExpanded(widget.toolUse.id, !_expanded);
    });
  }

  IconData _getToolIcon() {
    switch (widget.toolUse.name) {
      case 'bash':
        return Icons.terminal;
      case 'read_file':
        return Icons.description;
      case 'write_file':
        return Icons.edit_document;
      case 'web_fetch':
        return Icons.language;
      default:
        return Icons.build;
    }
  }

  String _getToolLabel() {
    switch (widget.toolUse.name) {
      case 'bash':
        return widget.toolUse.input['command'] as String? ?? 'Shell';
      case 'read_file':
        return widget.toolUse.input['path'] as String? ?? AppStrings.readFile;
      case 'write_file':
        return widget.toolUse.input['path'] as String? ?? AppStrings.writeFile;
      case 'web_fetch':
        return widget.toolUse.input['url'] as String? ?? AppStrings.webRequest;
      default:
        return widget.toolUse.name;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isExecuting = widget.toolUse.isExecuting;
    final isError = widget.toolUse.isError;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isError
              ? theme.colorScheme.error.withAlpha(100)
              : theme.colorScheme.outline.withAlpha(50),
        ),
        color: theme.colorScheme.surface,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: _toggleExpanded,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(_getToolIcon(), size: 16,
                      color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _getToolLabel(),
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (isExecuting)
                    const SizedBox(
                      width: 14, height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else if (isError)
                    Icon(Icons.error_outline, size: 16,
                        color: theme.colorScheme.error)
                  else
                    Icon(Icons.check_circle_outline, size: 16,
                        color: AppColors.statusGreen),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(AppStrings.inputLabel, style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  )),
                  const SizedBox(height: 4),
                  CodeBlock(
                    code: const JsonEncoder.withIndent('  ')
                        .convert(widget.toolUse.input),
                    language: 'json',
                  ),
                  if (widget.toolUse.output != null) ...[
                    const SizedBox(height: 12),
                    Text(AppStrings.outputLabel, style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    )),
                    const SizedBox(height: 4),
                    CodeBlock(
                      code: widget.toolUse.output!,
                      language: 'text',
                      maxLines: 20,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
