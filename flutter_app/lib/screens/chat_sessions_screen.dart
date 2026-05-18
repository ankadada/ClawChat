import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/chat_models.dart';
import '../providers/chat_provider.dart';
import '../services/session_storage.dart';
import '../l10n/app_strings.dart';

class ChatSessionsScreen extends StatefulWidget {
  final bool embedded;
  const ChatSessionsScreen({super.key, this.embedded = false});

  @override
  State<ChatSessionsScreen> createState() => _ChatSessionsScreenState();
}

class _ChatSessionsScreenState extends State<ChatSessionsScreen> {
  final _searchController = TextEditingController();
  String _searchQuery = '';
  String? _selectedFolder; // null = show all
  final Set<String> _collapsedFolders = {};

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _exportSession(SessionSummary session) async {
    final storage = SessionStorage();
    await storage.init();
    final fullSession = await storage.getSession(session.id);
    if (fullSession == null) return;

    final buffer = StringBuffer();
    buffer.writeln('# ${fullSession.title}');
    buffer.writeln(
        '> Exported from ClawChat on ${DateTime.now().toString().substring(0, 16)}');
    buffer.writeln('');

    for (final msg in fullSession.messages) {
      final role = msg.role == 'user' ? '**User**' : '**AI**';
      buffer.writeln('$role:');
      buffer.write(_messageContentToMarkdown(msg));
      buffer.writeln('');
    }

    await Clipboard.setData(ClipboardData(text: buffer.toString()));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(AppStrings.exportedToClipboard)),
      );
    }
  }

  String _messageContentToMarkdown(ChatMessage message) {
    final buffer = StringBuffer();
    for (final content in message.content) {
      switch (content) {
        case TextContent(:final text):
          if (text.isNotEmpty) buffer.writeln(text);
        case ImageContent(:final filename, :final mediaType):
          buffer.writeln('[Image: ${filename ?? mediaType}]');
        case ToolUseContent(:final name, :final input):
          buffer.writeln('**Tool call**: `$name`');
          buffer.writeln('```json');
          buffer.writeln(const JsonEncoder.withIndent('  ').convert(input));
          buffer.writeln('```');
        case ToolResultContent(:final output):
          buffer.writeln('**Tool result**:');
          buffer.writeln('```');
          buffer.writeln(_truncateToolOutput(output));
          buffer.writeln('```');
      }
    }
    return buffer.toString();
  }

  String _truncateToolOutput(String output) {
    if (output.length <= 2000) return output;
    return '${output.substring(0, 2000)}\n\n[tool output truncated]';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final body = Consumer<ChatProvider>(
      builder: (_, provider, __) {
        final sessions = provider.sessions;

        if (sessions.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.forum_outlined,
                    size: 48, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(height: 16),
                Text(AppStrings.noChats,
                    style: theme.textTheme.bodyLarge
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          );
        }

        // Collect unique folders
        final folders = <String>{};
        for (final s in sessions) {
          if (s.folder != null && s.folder!.isNotEmpty) {
            folders.add(s.folder!);
          }
        }
        final sortedFolders = folders.toList()..sort();

        // Apply search and folder filter
        var filteredSessions = sessions.toList();
        if (_searchQuery.isNotEmpty) {
          filteredSessions = filteredSessions
              .where((s) => s.title.toLowerCase().contains(_searchQuery))
              .toList();
        }
        if (_selectedFolder != null) {
          if (_selectedFolder == '__none__') {
            filteredSessions = filteredSessions.where((s) => s.folder == null || s.folder!.isEmpty).toList();
          } else {
            filteredSessions = filteredSessions.where((s) => s.folder == _selectedFolder).toList();
          }
        }

        // Group by folder
        final grouped = <String?, List<SessionSummary>>{};
        for (final s in filteredSessions) {
          final key = (s.folder != null && s.folder!.isNotEmpty) ? s.folder : null;
          grouped.putIfAbsent(key, () => []).add(s);
        }

        // Build ordered keys: null (ungrouped) first, then sorted folder names
        final groupKeys = <String?>[];
        if (grouped.containsKey(null)) groupKeys.add(null);
        for (final f in sortedFolders) {
          if (grouped.containsKey(f)) groupKeys.add(f);
        }

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: AppStrings.searchConversations,
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _searchQuery = '');
                          },
                        )
                      : null,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(25)),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16),
                  isDense: true,
                ),
                onChanged: (v) =>
                    setState(() => _searchQuery = v.toLowerCase()),
              ),
            ),
            if (sortedFolders.isNotEmpty)
              SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: FilterChip(
                        label: Text(AppStrings.allConversations),
                        selected: _selectedFolder == null,
                        onSelected: (_) => setState(() => _selectedFolder = null),
                      ),
                    ),
                    ...sortedFolders.map((f) => Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: FilterChip(
                        label: Text(f),
                        selected: _selectedFolder == f,
                        onSelected: (_) => setState(() =>
                          _selectedFolder = _selectedFolder == f ? null : f),
                      ),
                    )),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: FilterChip(
                        label: Text(AppStrings.noFolder),
                        selected: _selectedFolder == '__none__',
                        onSelected: (_) => setState(() =>
                          _selectedFolder = _selectedFolder == '__none__' ? null : '__none__'),
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: filteredSessions.isEmpty
                  ? Center(
                      child: Text(AppStrings.noChats,
                          style: theme.textTheme.bodyLarge?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                    )
                  : Builder(builder: (context) {
                      final items = _buildListItems(groupKeys, grouped);
                      return ListView.builder(
                      itemCount: items.length,
                      itemBuilder: (context, index) {
                        final item = items[index];
                        if (item is _FolderHeaderItem) {
                          final isCollapsed = _collapsedFolders.contains(item.folderName);
                          return ListTile(
                            dense: true,
                            leading: Icon(
                              isCollapsed ? Icons.folder : Icons.folder_open,
                              color: theme.colorScheme.primary,
                              size: 20,
                            ),
                            title: Text(
                              item.folderName,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: theme.colorScheme.primary,
                                fontSize: 13,
                              ),
                            ),
                            trailing: Icon(
                              isCollapsed ? Icons.expand_more : Icons.expand_less,
                              size: 20,
                            ),
                            onTap: () {
                              setState(() {
                                if (isCollapsed) {
                                  _collapsedFolders.remove(item.folderName);
                                } else {
                                  _collapsedFolders.add(item.folderName);
                                }
                              });
                            },
                          );
                        }
                        final sessionItem = item as _SessionItem;
                        final session = sessionItem.session;
                        final isSelected =
                            session.id == provider.currentSession?.id;

                        return Dismissible(
                          key: Key(session.id),
                          direction: DismissDirection.endToStart,
                          confirmDismiss: (_) async {
                            return await showDialog<bool>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: const Text(AppStrings.deleteChat),
                                content: Text(AppStrings.deleteChatConfirm(
                                    session.title)),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(ctx, false),
                                    child: const Text(AppStrings.cancel),
                                  ),
                                  FilledButton(
                                    onPressed: () =>
                                        Navigator.pop(ctx, true),
                                    child: const Text(AppStrings.delete),
                                  ),
                                ],
                              ),
                            );
                          },
                          onDismissed: (_) =>
                              provider.deleteSession(session.id),
                          background: Container(
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 16),
                            color: theme.colorScheme.error,
                            child: const Icon(Icons.delete,
                                color: Colors.white),
                          ),
                          child: ListTile(
                            title: Text(
                              session.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              _formatTime(session.updatedAt),
                              style: theme.textTheme.bodySmall,
                            ),
                            leading: Icon(
                              Icons.chat_bubble_outline,
                              color: isSelected
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.share, size: 20),
                              tooltip: AppStrings.exportChat,
                              onPressed: () => _exportSession(session),
                            ),
                            selected: isSelected,
                            onTap: () {
                              provider.selectSession(session.id);
                              if (!widget.embedded) {
                                Navigator.of(context).pop();
                              }
                            },
                            onLongPress: () => _showSessionOptions(context, session, provider),
                          ),
                        );
                      },
                    );
                    }),
            ),
          ],
        );
      },
    );

    if (widget.embedded) {
      return Column(
        children: [
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      AppStrings.chatHistory,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_sweep),
                    tooltip: AppStrings.clearAllSessions,
                    onPressed: () => _confirmClearAll(context),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add),
                    tooltip: AppStrings.newChat,
                    onPressed: () {
                      context.read<ChatProvider>().createSession();
                    },
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(child: body),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text(AppStrings.chatHistory),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            tooltip: AppStrings.clearAllSessions,
            onPressed: () => _confirmClearAll(context),
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: AppStrings.newChat,
            onPressed: () {
              context.read<ChatProvider>().createSession();
              Navigator.of(context).pop();
            },
          ),
        ],
      ),
      body: body,
    );
  }

  List<Object> _buildListItems(List<String?> groupKeys, Map<String?, List<SessionSummary>> grouped) {
    final items = <Object>[];
    for (final key in groupKeys) {
      if (key != null) {
        items.add(_FolderHeaderItem(key));
        if (!_collapsedFolders.contains(key)) {
          for (final s in grouped[key]!) {
            items.add(_SessionItem(s));
          }
        }
      } else {
        for (final s in grouped[key]!) {
          items.add(_SessionItem(s));
        }
      }
    }
    return items;
  }

  void _showSessionOptions(BuildContext context, SessionSummary session, ChatProvider provider) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text(AppStrings.renameSession),
              onTap: () {
                Navigator.pop(ctx);
                _renameSession(context, session, provider);
              },
            ),
            ListTile(
              leading: const Icon(Icons.folder),
              title: const Text(AppStrings.moveToFolder),
              onTap: () {
                Navigator.pop(ctx);
                _showMoveToFolderDialog(context, session, provider);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete),
              title: const Text(AppStrings.deleteChat),
              onTap: () {
                Navigator.pop(ctx);
                provider.deleteSession(session.id);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showMoveToFolderDialog(BuildContext context, SessionSummary session, ChatProvider provider) async {
    // Collect existing folders
    final folders = <String>{};
    for (final s in provider.sessions) {
      if (s.folder != null && s.folder!.isNotEmpty) {
        folders.add(s.folder!);
      }
    }
    final sortedFolders = folders.toList()..sort();

    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(AppStrings.moveToFolder),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.clear),
              title: const Text(AppStrings.noFolder),
              onTap: () => Navigator.pop(ctx, '__remove__'),
            ),
            ...sortedFolders.map((f) => ListTile(
              leading: const Icon(Icons.folder),
              title: Text(f),
              selected: session.folder == f,
              onTap: () => Navigator.pop(ctx, f),
            )),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.create_new_folder),
              title: const Text(AppStrings.newFolder),
              onTap: () async {
                Navigator.pop(ctx, '__new__');
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(AppStrings.cancel),
          ),
        ],
      ),
    );

    if (result == null) return;

    if (result == '__remove__') {
      await provider.moveToFolder(session.id, null);
    } else if (result == '__new__') {
      final controller = TextEditingController();
      final folderName = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text(AppStrings.newFolder),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: AppStrings.folderName,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text(AppStrings.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text(AppStrings.confirm),
            ),
          ],
        ),
      );
      if (folderName != null && folderName.isNotEmpty) {
        await provider.moveToFolder(session.id, folderName);
      }
    } else {
      await provider.moveToFolder(session.id, result);
    }
  }

  Future<void> _renameSession(BuildContext context, SessionSummary session, ChatProvider provider) async {
    final controller = TextEditingController(text: session.title);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(AppStrings.renameSession),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: AppStrings.sessionTitle),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text(AppStrings.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text(AppStrings.confirm)),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      provider.renameSession(session.id, result);
    }
  }

  Future<void> _confirmClearAll(BuildContext context) async {
    final provider = context.read<ChatProvider>();
    if (provider.sessions.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(AppStrings.clearAllSessions),
        content: const Text(AppStrings.clearAllConfirm),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text(AppStrings.cancel)),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(AppStrings.delete),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await provider.clearAllSessions();
    }
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return AppStrings.justNow;
    if (diff.inHours < 1) return AppStrings.minutesAgo(diff.inMinutes);
    if (diff.inDays < 1) return AppStrings.hoursAgo(diff.inHours);
    if (diff.inDays < 7) return AppStrings.daysAgo(diff.inDays);
    return '${dt.month}/${dt.day}';
  }
}

class _FolderHeaderItem {
  final String folderName;
  _FolderHeaderItem(this.folderName);
}

class _SessionItem {
  final SessionSummary session;
  _SessionItem(this.session);
}
