import 'package:flutter/material.dart';

import '../models/chat_models.dart';
import '../models/workspace.dart';
import '../services/share_action.dart';
import '../services/shared_content.dart';

/// What the share sheet returned.
@immutable
class ShareActionSelection {
  final ShareActionKind kind;
  final String workspaceId;

  const ShareActionSelection({required this.kind, required this.workspaceId});
}

/// Preview and action chooser for content that arrived through a share Intent.
///
/// The sheet never performs the action: it returns the user's choice so the
/// caller can create the session, write the file, or send the prompt through its
/// own consent and recovery paths. Dismissing it returns null, and the caller
/// discards the prepared attachments.
Future<ShareActionSelection?> showShareActionSheet(
  BuildContext context, {
  required SharedContent content,
  required PreparedSharedContent prepared,
  required List<WorkspaceMetadata> workspaces,
  required String activeWorkspaceId,
}) {
  return showModalBottomSheet<ShareActionSelection>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => _ShareActionSheet(
      content: content,
      prepared: prepared,
      workspaces: workspaces,
      activeWorkspaceId: activeWorkspaceId,
    ),
  );
}

class _ShareActionSheet extends StatefulWidget {
  const _ShareActionSheet({
    required this.content,
    required this.prepared,
    required this.workspaces,
    required this.activeWorkspaceId,
  });

  final SharedContent content;
  final PreparedSharedContent prepared;
  final List<WorkspaceMetadata> workspaces;
  final String activeWorkspaceId;

  @override
  State<_ShareActionSheet> createState() => _ShareActionSheetState();
}

class _ShareActionSheetState extends State<_ShareActionSheet> {
  late String _workspaceId;

  @override
  void initState() {
    super.initState();
    _workspaceId = widget.workspaces.any(
      (workspace) => workspace.id == widget.activeWorkspaceId,
    )
        ? widget.activeWorkspaceId
        : (widget.workspaces.isEmpty
            ? WorkspaceMetadata.defaultWorkspaceId
            : widget.workspaces.first.id);
  }

  /// Name of the workspace the actions will use, so the sheet can say where
  /// the content is going instead of only showing a dropdown.
  String get _selectedWorkspaceName {
    for (final workspace in widget.workspaces) {
      if (workspace.id == _workspaceId) return workspace.name;
    }
    if (widget.workspaces.isNotEmpty) return widget.workspaces.first.name;
    return WorkspaceMetadata.defaultWorkspace().name;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final imageCount = widget.prepared.attachments
        .where((attachment) => attachment.content is ImageContent)
        .length;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            Text('分享内容', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            _preview(theme, imageCount),
            const SizedBox(height: 16),
            if (widget.workspaces.length > 1) ...[
              Text('工作区', style: theme.textTheme.labelLarge),
              const SizedBox(height: 4),
              DropdownButtonFormField<String>(
                value: _workspaceId,
                isExpanded: true,
                items: [
                  for (final workspace in widget.workspaces)
                    DropdownMenuItem(
                      value: workspace.id,
                      child: Text(
                        workspace.name,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => _workspaceId = value);
                },
              ),
              const SizedBox(height: 8),
            ],
            _targetLine(theme),
            const SizedBox(height: 8),
            // Consent line sits above the actions so what leaves the device is
            // readable before the user picks anything.
            Text(
              '总结和提取待办会把这段内容发送到你配置的模型；保存和草稿只在本地处理。',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            _action(
              context,
              icon: Icons.summarize_outlined,
              title: ShareActionPlanner.label(ShareActionKind.summarize),
              subtitle: '把内容发送给当前模型，先给结论再列要点',
              kind: ShareActionKind.summarize,
              sendsToModel: true,
            ),
            _action(
              context,
              icon: Icons.checklist_outlined,
              title: ShareActionPlanner.label(ShareActionKind.extractTodos),
              subtitle: '把内容发送给当前模型，提取可执行的待办',
              kind: ShareActionKind.extractTodos,
              sendsToModel: true,
            ),
            _action(
              context,
              icon: Icons.save_alt_outlined,
              title: ShareActionPlanner.label(ShareActionKind.saveToWorkspace),
              subtitle: '在本地工作区保存一份 Markdown，不发送给模型',
              kind: ShareActionKind.saveToWorkspace,
              sendsToModel: false,
            ),
            _action(
              context,
              icon: Icons.edit_note_outlined,
              title: ShareActionPlanner.label(ShareActionKind.draftOnly),
              subtitle: '只放进输入框，由你自己决定是否发送',
              kind: ShareActionKind.draftOnly,
              sendsToModel: false,
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _targetLine(ThemeData theme) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.folder_outlined,
          size: 16,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '保存到工作区「$_selectedWorkspaceName」；选择动作后会在这个工作区'
            '新建一个会话。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  Widget _preview(ThemeData theme, int imageCount) {
    final text = widget.content.text.trim();
    final excerpt = text.length > 300 ? '${text.substring(0, 300)}…' : text;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if ((widget.content.subject ?? '').trim().isNotEmpty)
            Text(
              widget.content.subject!.trim(),
              style: theme.textTheme.labelLarge,
              overflow: TextOverflow.ellipsis,
            ),
          if (excerpt.isNotEmpty)
            Text(
              excerpt,
              style: theme.textTheme.bodyMedium,
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
            ),
          if (imageCount > 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  const Icon(Icons.image_outlined, size: 16),
                  const SizedBox(width: 6),
                  Text('$imageCount 张图片', style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          for (final warning in widget.prepared.warnings.take(2))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  Icon(
                    Icons.error_outline,
                    size: 16,
                    color: theme.colorScheme.error,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      warning,
                      style: theme.textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _action(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required ShareActionKind kind,
    required bool sendsToModel,
  }) {
    final theme = Theme.of(context);
    return ListTile(
      key: ValueKey('share-action-${kind.name}'),
      minVerticalPadding: 12,
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      // The status words, not color alone, tell the user what leaves the
      // device before they pick an action.
      trailing: Text(
        sendsToModel ? '会发送到模型' : '仅本地',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      onTap: () => Navigator.of(context).pop(
        ShareActionSelection(kind: kind, workspaceId: _workspaceId),
      ),
    );
  }
}
