import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/workspace.dart';
import '../models/workspace_file.dart';
import '../services/workspace_file_service.dart';

/// Local-first file browser for one workspace.
///
/// Everything it shows comes from the scoped rootfs listing, so it can only ever
/// walk inside [WorkspaceBrowserScreen.workspace]. Deletes are file-only and ask
/// for confirmation that names the file and the workspace; a text file can be
/// restored with Undo because the preview already holds its content.
class WorkspaceBrowserScreen extends StatefulWidget {
  const WorkspaceBrowserScreen({
    super.key,
    required this.workspace,
    this.service,
  });

  final WorkspaceMetadata workspace;

  /// Injectable for tests; the production default talks to the native bridge.
  final WorkspaceFileService? service;

  @override
  State<WorkspaceBrowserScreen> createState() => _WorkspaceBrowserScreenState();
}

class _WorkspaceBrowserScreenState extends State<WorkspaceBrowserScreen> {
  late final WorkspaceFileService _service =
      widget.service ?? WorkspaceFileService(workspace: widget.workspace);
  late final String _rootPath = widget.workspace.rootPath;

  String _currentPath = '';
  WorkspaceFileListing? _listing;
  String? _error;
  bool _loading = false;

  /// Monotonic token for the newest directory read. A slower read that started
  /// earlier (a refresh, or a directory the user already left) must never
  /// replace the listing, error or loading state of the current path.
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _currentPath = _rootPath;
    _load();
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    final path = _currentPath;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final listing = await _service.list(path);
      if (!mounted || !_isCurrentLoad(generation, path)) return;
      setState(() {
        _listing = listing;
        _loading = false;
      });
    } on WorkspaceFileException catch (error) {
      if (!mounted || !_isCurrentLoad(generation, path)) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    }
  }

  /// True while [generation]/[path] still describe what the screen shows: a
  /// newer read has not started and the user has not navigated elsewhere.
  bool _isCurrentLoad(int generation, String path) =>
      generation == _loadGeneration && path == _currentPath;

  void _open(WorkspaceFileEntry entry) {
    if (entry.canOpen) {
      setState(() {
        _currentPath = entry.path;
        _listing = null;
      });
      _load();
      return;
    }
    if (entry.isSymbolicLink) {
      _showMessage('链接不会在这里打开');
      return;
    }
    _showPreview(entry);
  }

  void _goTo(String path) {
    setState(() {
      _currentPath = path;
      _listing = null;
    });
    _load();
  }

  Future<void> _showPreview(WorkspaceFileEntry entry) async {
    final preview = await _service.preview(entry);
    if (!mounted) return;
    final action = await showModalBottomSheet<_PreviewAction>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => _PreviewSheet(
        entry: entry,
        preview: preview,
        scopeLabel: widget.workspace.name,
        onCopyPath: () => _copyPath(entry),
        onSend: () => Navigator.of(sheetContext).pop(_PreviewAction.send),
        onDelete: () {
          unawaited(_confirmDeleteAbovePreview(entry, preview, sheetContext));
        },
      ),
    );
    if (!mounted) return;
    // Sending closes the browser too: the chat screen receives the reference
    // and puts it in the composer.
    if (action == _PreviewAction.send) {
      _sendToSession(entry);
    }
    if (action == _PreviewAction.delete) {
      await _deleteEntry(entry, preview);
    }
  }

  /// Confirms the deletion above the preview sheet. Only a confirmed delete
  /// closes the sheet, so cancelling returns the user to the preview they were
  /// reading instead of dropping them back at the directory listing.
  Future<void> _confirmDeleteAbovePreview(
    WorkspaceFileEntry entry,
    WorkspaceFilePreview preview,
    BuildContext sheetContext,
  ) async {
    final confirmed = await _confirmDelete(entry, preview);
    if (!confirmed) return;
    if (sheetContext.mounted) {
      Navigator.of(sheetContext).pop(_PreviewAction.delete);
    }
  }

  Future<void> _copyPath(WorkspaceFileEntry entry) async {
    await Clipboard.setData(ClipboardData(text: entry.path));
    if (!mounted) return;
    _showMessage('已复制路径：${entry.path}');
  }

  void _sendToSession(WorkspaceFileEntry entry) {
    final reference = _service.sessionReference(entry);
    Navigator.of(context).pop(reference);
  }

  Future<bool> _confirmDelete(
    WorkspaceFileEntry entry,
    WorkspaceFilePreview preview,
  ) async {
    final canUndo = _service.textForUndo(preview) != null;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除文件'),
        content: Text(
          '将删除「${entry.name}」\n'
          '位置：${_service.displayPath(entry.path)}\n'
          '工作区：${widget.workspace.name}\n\n'
          '${canUndo ? '删除后可以用撤销恢复内容。' : '删除后无法恢复。'}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _deleteEntry(
    WorkspaceFileEntry entry,
    WorkspaceFilePreview preview,
  ) async {
    try {
      await _service.delete(entry);
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      final undoText = _service.textForUndo(preview);
      _showMessage(
        '已删除 ${entry.name}',
        undo: undoText == null
            ? null
            : () async {
                try {
                  await _service.restoreText(entry.path, undoText);
                  await _load();
                } on WorkspaceFileException catch (error) {
                  if (mounted) _showMessage('撤销失败：${error.message}');
                }
              },
      );
    } on WorkspaceFileException catch (error) {
      if (!mounted) return;
      _showMessage(error.message);
    }
  }

  void _showMessage(String message, {Future<void> Function()? undo}) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          action: undo == null
              ? null
              : SnackBarAction(label: '撤销', onPressed: () => undo()),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.workspace.name),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _breadcrumb(),
            const Divider(height: 1),
            // A refresh of an already visible listing keeps the old rows on
            // screen, so it needs its own bounded progress signal.
            if (_loading && _listing != null)
              const LinearProgressIndicator(minHeight: 2),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _breadcrumb() {
    final relative = widget.workspace.relativePathOf(_currentPath) ?? '';
    final segments = relative.isEmpty ? const <String>[] : relative.split('/');
    final crumbs = <_Breadcrumb>[
      _Breadcrumb(
        label: widget.workspace.name,
        path: _rootPath,
        openable: _currentPath != _rootPath,
      ),
      for (var index = 0; index < segments.length; index++)
        _Breadcrumb(
          label: segments[index],
          path: '$_rootPath/${segments.sublist(0, index + 1).join('/')}',
          openable: index != segments.length - 1,
        ),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          for (var index = 0; index < crumbs.length; index++) ...[
            // The chevron separates crumbs; the row never starts with one.
            if (index > 0) const Icon(Icons.chevron_right, size: 18),
            TextButton(
              key: ValueKey('workspace-crumb-${crumbs[index].path}'),
              onPressed: crumbs[index].openable
                  ? () => _goTo(crumbs[index].path)
                  : null,
              child: Text(
                crumbs[index].label,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading && _listing == null) {
      return Center(
        child: Semantics(
          label: '正在读取工作区',
          child: const CircularProgressIndicator(),
        ),
      );
    }
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 32),
              const SizedBox(height: 8),
              Text('无法读取这个目录', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(error, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(onPressed: _load, child: const Text('重试')),
              TextButton(
                onPressed:
                    _currentPath == _rootPath ? null : () => _goTo(_rootPath),
                child: const Text('返回工作区根目录'),
              ),
            ],
          ),
        ),
      );
    }
    final listing = _listing;
    if (listing == null) {
      return const SizedBox.shrink();
    }
    if (listing.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.folder_open_outlined, size: 32),
              const SizedBox(height: 8),
              const Text('这个目录还是空的'),
              const SizedBox(height: 4),
              Text(
                '可以从聊天里把文件保存到工作区，或让 agent 在 ${_service.displayPath(_currentPath)} 下创建文件。',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        if (listing.truncated)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.info_outline, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '条目较多，只显示前 $listing.entries.length 个',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: ListView.builder(
            itemCount: listing.entries.length,
            itemBuilder: (context, index) {
              final entry = listing.entries[index];
              return ListTile(
                key: ValueKey('workspace-entry-${entry.path}'),
                leading: Icon(_iconFor(entry)),
                title: Text(entry.name, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  _subtitleFor(entry),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                trailing: entry.canOpen
                    ? const Icon(Icons.chevron_right)
                    : const Icon(Icons.more_horiz),
                onTap: () => _open(entry),
              );
            },
          ),
        ),
      ],
    );
  }

  IconData _iconFor(WorkspaceFileEntry entry) {
    if (entry.isSymbolicLink) return Icons.link;
    if (entry.isDirectory) return Icons.folder_outlined;
    final extension = entry.name.contains('.')
        ? entry.name.split('.').last.toLowerCase()
        : '';
    if (WorkspaceFileService.imageExtensions.contains(extension)) {
      return Icons.image_outlined;
    }
    return Icons.description_outlined;
  }

  String _subtitleFor(WorkspaceFileEntry entry) {
    if (entry.isSymbolicLink) return '链接（不跟随）';
    if (entry.isDirectory) return '文件夹';
    final size = _formatBytes(entry.sizeBytes);
    final modified = entry.modifiedAt;
    if (modified == null) return size;
    return '$size · ${_formatDate(modified)}';
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  static String _formatDate(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${value.year}-${two(value.month)}-${two(value.day)} '
        '${two(value.hour)}:${two(value.minute)}';
  }
}

enum _PreviewAction { send, delete }

class _Breadcrumb {
  const _Breadcrumb({
    required this.label,
    required this.path,
    required this.openable,
  });

  final String label;
  final String path;
  final bool openable;
}

class _PreviewSheet extends StatelessWidget {
  const _PreviewSheet({
    required this.entry,
    required this.preview,
    required this.scopeLabel,
    required this.onCopyPath,
    required this.onSend,
    required this.onDelete,
  });

  final WorkspaceFileEntry entry;
  final WorkspaceFilePreview preview;
  final String scopeLabel;
  final VoidCallback onCopyPath;
  final VoidCallback onSend;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.name, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    '$scopeLabel · ${entry.path}',
                    style: theme.textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Flexible(child: _previewBody(theme)),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '插入后仍需你确认发送；删除只影响工作区文件。',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ),
            const Divider(height: 1),
            OverflowBar(
              alignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: onCopyPath,
                  icon: const Icon(Icons.copy_all_outlined),
                  label: const Text('复制路径'),
                ),
                TextButton.icon(
                  onPressed: onSend,
                  icon: const Icon(Icons.send_outlined),
                  label: const Text('插入输入框'),
                ),
                TextButton.icon(
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('删除'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _previewBody(ThemeData theme) {
    switch (preview.kind) {
      case WorkspaceFilePreviewKind.text:
        return SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SelectableText(
            preview.text ?? '',
            style: theme.textTheme.bodyMedium,
          ),
        );
      case WorkspaceFilePreviewKind.image:
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: InteractiveViewer(
            child: Image.memory(preview.bytes!, fit: BoxFit.contain),
          ),
        );
      case WorkspaceFilePreviewKind.unsupported:
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Icon(Icons.info_outline, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text(preview.note ?? '暂不支持预览')),
            ],
          ),
        );
    }
  }
}
