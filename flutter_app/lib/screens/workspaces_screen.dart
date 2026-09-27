import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../models/workspace.dart';
import '../providers/chat_provider.dart';

/// Local workspace management.
///
/// A workspace is the named scope new sessions, the file browser and shared
/// saves default to. Switching one only changes that default: sessions keep
/// the workspace they were created in and resolve through the same fallback
/// that existed before this screen (a missing id uses the active workspace).
/// The workspace directory and its files are never touched here.
class WorkspacesScreen extends StatelessWidget {
  const WorkspacesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text(AppStrings.workspacesTitle),
        actions: [
          IconButton(
            tooltip: AppStrings.workspaceCreate,
            onPressed: () => unawaited(_createWorkspace(context)),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => unawaited(_createWorkspace(context)),
        icon: const Icon(Icons.create_new_folder_outlined),
        label: const Text(AppStrings.workspaceCreate),
      ),
      body: Consumer<ChatProvider>(
        builder: (context, provider, __) {
          final workspaces = provider.workspaces.isEmpty
              ? <WorkspaceMetadata>[provider.activeWorkspace]
              : provider.workspaces;
          final activeId = provider.activeWorkspace.id;
          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                child: Text(
                  AppStrings.workspacesDescription,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              for (final workspace in workspaces)
                _workspaceTile(
                  context,
                  provider,
                  workspace,
                  isActive: workspace.id == activeId,
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _workspaceTile(
    BuildContext context,
    ChatProvider provider,
    WorkspaceMetadata workspace, {
    required bool isActive,
  }) {
    final theme = Theme.of(context);
    final subtitle = [
      if (isActive) AppStrings.workspaceActive,
      AppStrings.workspacePathLabel(workspace.rootPath),
    ].join(' · ');
    return Card.outlined(
      child: ListTile(
        key: ValueKey('workspace-row-${workspace.id}'),
        leading: Icon(
          isActive ? Icons.check_circle : Icons.workspaces_outline,
          color: isActive ? theme.colorScheme.primary : null,
        ),
        title: Text(
          workspace.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          subtitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        onTap: isActive
            ? null
            : () => unawaited(_switchTo(context, provider, workspace)),
        trailing: PopupMenuButton<_WorkspaceAction>(
          tooltip: AppStrings.more,
          onSelected: (action) =>
              unawaited(_handleAction(context, provider, workspace, action)),
          itemBuilder: (_) => [
            if (!isActive)
              const PopupMenuItem(
                value: _WorkspaceAction.switchTo,
                child: Text(AppStrings.workspaceSwitch),
              ),
            const PopupMenuItem(
              value: _WorkspaceAction.rename,
              child: Text(AppStrings.workspaceRename),
            ),
            if (!workspace.isDefault)
              const PopupMenuItem(
                value: _WorkspaceAction.delete,
                child: Text(AppStrings.workspaceDelete),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleAction(
    BuildContext context,
    ChatProvider provider,
    WorkspaceMetadata workspace,
    _WorkspaceAction action,
  ) async {
    switch (action) {
      case _WorkspaceAction.switchTo:
        await _switchTo(context, provider, workspace);
        return;
      case _WorkspaceAction.rename:
        await _renameWorkspace(context, provider, workspace);
        return;
      case _WorkspaceAction.delete:
        await _deleteWorkspace(context, provider, workspace);
        return;
    }
  }

  Future<void> _switchTo(
    BuildContext context,
    ChatProvider provider,
    WorkspaceMetadata workspace,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    await provider.setActiveWorkspace(workspace.id);
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          '已切换到「${workspace.name}」；新会话默认使用它，已有会话保留自己的归属。',
        ),
      ),
    );
  }

  Future<void> _createWorkspace(BuildContext context) async {
    final provider = context.read<ChatProvider>();
    final name = await _promptWorkspaceName(
      context,
      title: AppStrings.workspaceCreate,
      confirmLabel: AppStrings.workspaceCreate,
    );
    if (name == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final created = await provider.createWorkspace(name: name);
      messenger?.showSnackBar(
        SnackBar(
          content: Text('已创建「${created.name}」并切换为当前工作区'),
        ),
      );
    } catch (_) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('创建失败：本地工作区没有变化')),
      );
    }
  }

  Future<void> _renameWorkspace(
    BuildContext context,
    ChatProvider provider,
    WorkspaceMetadata workspace,
  ) async {
    final name = await _promptWorkspaceName(
      context,
      title: AppStrings.workspaceRename,
      confirmLabel: AppStrings.save,
      initial: workspace.name,
    );
    if (name == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final renamed = await provider.renameWorkspace(workspace.id, name);
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          renamed == null ? '重命名失败：没有找到这个工作区' : '已重命名为「${renamed.name}」',
        ),
      ),
    );
  }

  Future<void> _deleteWorkspace(
    BuildContext context,
    ChatProvider provider,
    WorkspaceMetadata workspace,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text(AppStrings.workspaceDelete),
        content: Text(
          '将删除工作区「${workspace.name}」。它的会话保留原记录，并回退到当前工作区解析；'
          '工作区目录和其中的文件不会被删除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text(AppStrings.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text(AppStrings.workspaceDelete),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final deleted = await provider.deleteWorkspace(workspace.id);
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          deleted ? '已删除工作区「${workspace.name}」' : '删除失败：默认工作区不可删除，或本地记录没有变化',
        ),
      ),
    );
  }

  Future<String?> _promptWorkspaceName(
    BuildContext context, {
    required String title,
    required String confirmLabel,
    String initial = '',
  }) {
    // A full-height route instead of a dialog or sheet: a plain Scaffold gives
    // the platform-standard behaviour of shrinking the body above the IME, so
    // the field (top of the page) and the confirm button stay visible,
    // tappable and in the semantics tree on every device. Dialogs and sheets
    // both ended up clipped or zero-height on ColorOS landscape + IME.
    return Navigator.of(context).push<String>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _WorkspaceNamePage(
          title: title,
          confirmLabel: confirmLabel,
          initial: initial,
        ),
      ),
    );
  }

  static String? _validatedName(String value) {
    final name = WorkspaceMetadata.validateName(value);
    if (name == null || name.isEmpty) return null;
    return name;
  }
}

/// Name prompt for create/rename, as a full-height editor route.
///
/// The field sits at the top of the body and the confirm action right below
/// it, so the standard Scaffold resize above the IME keeps both on screen.
/// The controller lives with this page and is disposed with the route.
class _WorkspaceNamePage extends StatefulWidget {
  const _WorkspaceNamePage({
    required this.title,
    required this.confirmLabel,
    this.initial = '',
  });

  final String title;
  final String confirmLabel;
  final String initial;

  @override
  State<_WorkspaceNamePage> createState() => _WorkspaceNamePageState();
}

class _WorkspaceNamePageState extends State<_WorkspaceNamePage> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = WorkspacesScreen._validatedName(_controller.text);
    if (name == null) {
      setState(() => _error = AppStrings.workspaceNameRequired);
      return;
    }
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    // The app bar slot grows with the label: a fixed 56dp leading clipped the
    // cancel label at large text scales, so the painted text no longer matched
    // the tappable box. The button fills the whole slot, which keeps a real
    // 48dp+ target on narrow phones and makes the visible label part of it.
    final cancelWidth = math.max(
      56.0,
      MediaQuery.textScalerOf(context).scale(14) * 2 + 24,
    );
    return Scaffold(
      // The editor keeps the full body height: the field lives at the very
      // top, so the IME only ever covers the empty space below it. Letting
      // the body shrink above a 240dp keyboard on a 360dp-tall window left
      // the field with ~10dp of visible height.
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        leadingWidth: cancelWidth,
        leading: TextButton(
          key: const ValueKey('workspace-name-cancel'),
          style: TextButton.styleFrom(
            minimumSize: Size(cancelWidth, kToolbarHeight),
            padding: EdgeInsets.zero,
            tapTargetSize: MaterialTapTargetSize.padded,
          ),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text(
            AppStrings.cancel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ),
        title: Text(
          widget.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          // The confirm action lives in the app bar: on a 360dp-tall
          // landscape window a 240dp IME leaves less than one row of body
          // height, so a body button would sit under the keyboard. The
          // app bar is never covered by the IME, and the label keeps its
          // intrinsic width instead of being squeezed.
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              key: const ValueKey('workspace-name-confirm'),
              onPressed: _submit,
              child: Text(widget.confirmLabel),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // A fixed-height box, never a share of the remaining space:
              // the field is a real 56dp RenderBox even on an 800x360
              // window with a tall IME, where a space-distributed field
              // collapsed to its 10dp bottom border.
              SizedBox(
                height: 56,
                child: TextField(
                  key: const ValueKey('workspace-name-field'),
                  controller: _controller,
                  autofocus: true,
                  textAlignVertical: TextAlignVertical.center,
                  textInputAction: TextInputAction.done,
                  inputFormatters: [
                    LengthLimitingTextInputFormatter(
                      WorkspaceMetadata.maxNameLength,
                    ),
                  ],
                  decoration: InputDecoration(
                    labelText: AppStrings.workspaceNameLabel,
                    errorText: _error,
                  ),
                  onSubmitted: (_) => _submit(),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '输入名称后点右上角按钮确认；也可以按回车。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _WorkspaceAction { switchTo, rename, delete }
