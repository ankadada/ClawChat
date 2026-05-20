import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app.dart';
import '../models/chat_models.dart';
import '../providers/chat_provider.dart';
import '../services/native_bridge.dart';
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
  Timer? _searchDebounce;
  int _searchGeneration = 0;
  bool _searching = false;
  List<SessionSearchResult> _searchResults = [];
  String? _selectedFolder; // null = show all

  @override
  void dispose() {
    _searchDebounce?.cancel();
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

    final text = buffer.toString();
    try {
      await NativeBridge.shareText(text: text, subject: fullSession.title);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(AppStrings.shareSheetOpened)),
      );
    } catch (e) {
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${AppStrings.shareFailed}: $e')),
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

  void _setSearchQuery(String value) {
    final query = value.trim();
    _searchDebounce?.cancel();
    _searchGeneration += 1;

    if (query.isEmpty) {
      setState(() {
        _searchQuery = '';
        _searching = false;
        _searchResults = [];
      });
      return;
    }

    final generation = _searchGeneration;
    setState(() {
      _searchQuery = query;
      _searching = true;
    });

    _searchDebounce = Timer(const Duration(milliseconds: 220), () async {
      final storage = SessionStorage();
      await storage.init();
      final results = await storage.searchSessions(query);
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _searchResults = results;
        _searching = false;
      });
    });
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
        final searchMatches = {
          for (final result in _searchResults) result.summary.id: result,
        };
        var filteredSessions = _searchQuery.isEmpty
            ? sessions.toList()
            : _searchResults.map((result) => result.summary).toList();
        if (_selectedFolder != null) {
          if (_selectedFolder == '__none__') {
            filteredSessions = filteredSessions.where((s) => s.folder == null || s.folder!.isEmpty).toList();
          } else {
            filteredSessions = filteredSessions.where((s) => s.folder == _selectedFolder).toList();
          }
        }

        final dateGroups = _buildDateGroups(filteredSessions);

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
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
                            _setSearchQuery('');
                          },
                        )
                      : null,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadii.xl)),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                ),
                onChanged: _setSearchQuery,
              ),
            ),
            if (_searching)
              const LinearProgressIndicator(minHeight: 2),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Row(
                children: [
                  Text(
                    _searching
                        ? AppStrings.searching
                        : '${filteredSessions.length}/${sessions.length}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  if (_selectedFolder != null)
                    Text(
                      _selectedFolder == '__none__'
                          ? AppStrings.noFolder
                          : _selectedFolder!,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                ],
              ),
            ),
            if (sortedFolders.isNotEmpty)
              SizedBox(
                height: 48,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: FilterChip(
                        label: Text(AppStrings.allConversations),
                        selected: _selectedFolder == null,
                        showCheckmark: false,
                        selectedColor: theme.colorScheme.primaryContainer,
                        labelStyle: TextStyle(
                          color: _selectedFolder == null
                              ? theme.colorScheme.onPrimaryContainer
                              : null,
                          fontWeight: _selectedFolder == null ? FontWeight.w700 : null,
                        ),
                        onSelected: (_) => setState(() => _selectedFolder = null),
                      ),
                    ),
                    ...sortedFolders.map((f) => Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: FilterChip(
                        label: Text(f),
                        selected: _selectedFolder == f,
                        showCheckmark: false,
                        selectedColor: theme.colorScheme.primaryContainer,
                        labelStyle: TextStyle(
                          color: _selectedFolder == f
                              ? theme.colorScheme.onPrimaryContainer
                              : null,
                          fontWeight: _selectedFolder == f ? FontWeight.w700 : null,
                        ),
                        onSelected: (_) => setState(() =>
                          _selectedFolder = _selectedFolder == f ? null : f),
                      ),
                    )),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: FilterChip(
                        label: Text(AppStrings.noFolder),
                        selected: _selectedFolder == '__none__',
                        showCheckmark: false,
                        selectedColor: theme.colorScheme.primaryContainer,
                        labelStyle: TextStyle(
                          color: _selectedFolder == '__none__'
                              ? theme.colorScheme.onPrimaryContainer
                              : null,
                          fontWeight: _selectedFolder == '__none__' ? FontWeight.w700 : null,
                        ),
                        onSelected: (_) => setState(() =>
                          _selectedFolder = _selectedFolder == '__none__' ? null : '__none__'),
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: _searching && filteredSessions.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : filteredSessions.isEmpty
                  ? Center(
                      child: Text(AppStrings.noChats,
                          style: theme.textTheme.bodyLarge?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                    )
                  : CustomScrollView(
                      slivers: [
                        for (final group in dateGroups) ...[
                          SliverPersistentHeader(
                            pinned: true,
                            delegate: _DateHeaderDelegate(
                              label: group.label,
                              theme: theme,
                            ),
                          ),
                          SliverList(
                            delegate: SliverChildBuilderDelegate(
                              (context, index) {
                                final session = group.sessions[index];
                                final isSelected =
                                    session.id == provider.currentSession?.id;
                                return _buildSessionTile(
                                  context,
                                  theme,
                                  provider,
                                  session,
                                  isSelected,
                                  searchMatches[session.id],
                                );
                              },
                              childCount: group.sessions.length,
                            ),
                          ),
                        ],
                      ],
                    ),
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

  List<_DateGroup> _buildDateGroups(List<SessionSummary> sessions) {
    final grouped = <String, List<SessionSummary>>{
      AppStrings.today: [],
      AppStrings.yesterday: [],
      AppStrings.past7Days: [],
      AppStrings.earlier: [],
    };
    for (final session in sessions) {
      grouped[_dateGroupLabel(session.updatedAt)]!.add(session);
    }
    return grouped.entries
        .where((entry) => entry.value.isNotEmpty)
        .map((entry) => _DateGroup(entry.key, entry.value))
        .toList();
  }

  String _dateGroupLabel(DateTime updatedAt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final date = DateTime(updatedAt.year, updatedAt.month, updatedAt.day);
    final days = today.difference(date).inDays;
    if (days <= 0) return AppStrings.today;
    if (days == 1) return AppStrings.yesterday;
    if (days < 7) return AppStrings.past7Days;
    return AppStrings.earlier;
  }

  Widget _buildSessionTile(
    BuildContext context,
    ThemeData theme,
    ChatProvider provider,
    SessionSummary session,
    bool isSelected,
    SessionSearchResult? searchResult,
  ) {
    return Dismissible(
      key: Key(session.id),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) async {
        return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text(AppStrings.deleteChat),
            content: Text(AppStrings.deleteChatConfirm(session.title)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text(AppStrings.cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text(AppStrings.delete),
              ),
            ],
          ),
        );
      },
      onDismissed: (_) {
        HapticFeedback.lightImpact();
        provider.deleteSession(session.id);
      },
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        color: theme.colorScheme.error,
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: isSelected
              ? theme.colorScheme.primaryContainer.withAlpha(170)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadii.l),
          border: isSelected
              ? Border.all(color: theme.colorScheme.primary.withAlpha(90))
              : null,
        ),
        child: ListTile(
          contentPadding: const EdgeInsets.only(left: 12, right: 4),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.l),
          ),
          title: Text(
            session.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
            ),
          ),
          subtitle: _SessionMeta(
            session: session,
            timeLabel: _formatTime(session.updatedAt),
            matchPreview: searchResult?.matchPreview,
          ),
          leading: Icon(
            Icons.chat_bubble_outline,
            color: isSelected
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant,
          ),
          trailing: PopupMenuButton<String>(
            tooltip: AppStrings.more,
            icon: const Icon(Icons.more_vert, size: 20),
            onSelected: (value) async {
              switch (value) {
                case 'export':
                  _exportSession(session);
                  break;
                case 'rename':
                  _renameSession(context, session, provider);
                  break;
                case 'move':
                  _showMoveToFolderDialog(context, session, provider);
                  break;
                case 'delete':
                  await _confirmDeleteSession(context, session, provider);
                  break;
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'export',
                child: Text(AppStrings.exportChat),
              ),
              PopupMenuItem(
                value: 'rename',
                child: Text(AppStrings.renameSession),
              ),
              PopupMenuItem(
                value: 'move',
                child: Text(AppStrings.moveToFolder),
              ),
              PopupMenuItem(
                value: 'delete',
                child: Text(AppStrings.deleteChat),
              ),
            ],
          ),
          selected: isSelected,
          onTap: () {
            provider.selectSession(session.id);
            if (!widget.embedded) {
              Navigator.of(context).pop();
            }
          },
          onLongPress: () {
            HapticFeedback.lightImpact();
            _showSessionOptions(context, session, provider);
          },
        ),
      ),
    );
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
              leading: const Icon(Icons.share),
              title: const Text(AppStrings.exportChat),
              onTap: () {
                Navigator.pop(ctx);
                _exportSession(session);
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
              onTap: () async {
                Navigator.pop(ctx);
                await _confirmDeleteSession(context, session, provider);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDeleteSession(
    BuildContext context,
    SessionSummary session,
    ChatProvider provider,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(AppStrings.deleteChat),
        content: Text(AppStrings.deleteChatConfirm(session.title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(AppStrings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text(AppStrings.delete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    HapticFeedback.lightImpact();
    await provider.deleteSession(session.id);
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
    if (diff.inHours < 24) return AppStrings.hoursAgo(diff.inHours);

    final today = DateTime(now.year, now.month, now.day);
    final date = DateTime(dt.year, dt.month, dt.day);
    final days = today.difference(date).inDays;
    if (days == 1) return AppStrings.yesterday;
    return '${dt.month}/${dt.day}';
  }
}

class _DateGroup {
  final String label;
  final List<SessionSummary> sessions;

  const _DateGroup(this.label, this.sessions);
}

class _DateHeaderDelegate extends SliverPersistentHeaderDelegate {
  final String label;
  final ThemeData theme;

  const _DateHeaderDelegate({
    required this.label,
    required this.theme,
  });

  @override
  double get minExtent => 34;

  @override
  double get maxExtent => 34;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outline.withAlpha(35)),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 6),
        child: Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _DateHeaderDelegate oldDelegate) {
    return label != oldDelegate.label ||
        theme.brightness != oldDelegate.theme.brightness ||
        theme.colorScheme.primary != oldDelegate.theme.colorScheme.primary ||
        theme.scaffoldBackgroundColor != oldDelegate.theme.scaffoldBackgroundColor;
  }
}

class _SessionMeta extends StatefulWidget {
  final SessionSummary session;
  final String timeLabel;
  final String? matchPreview;

  const _SessionMeta({
    required this.session,
    required this.timeLabel,
    this.matchPreview,
  });

  @override
  State<_SessionMeta> createState() => _SessionMetaState();
}

class _SessionMetaState extends State<_SessionMeta> {
  static final SessionStorage _storage = SessionStorage();

  String? _preview;
  String? _model;

  @override
  void initState() {
    super.initState();
    _loadMeta();
  }

  @override
  void didUpdateWidget(covariant _SessionMeta oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session.id != widget.session.id ||
        oldWidget.session.updatedAt != widget.session.updatedAt) {
      _preview = null;
      _model = null;
      _loadMeta();
    }
  }

  Future<void> _loadMeta() async {
    final sessionId = widget.session.id;
    await _storage.init();
    final meta = await _storage.getSessionPreview(sessionId);
    if (!mounted || widget.session.id != sessionId) return;

    setState(() {
      final preview = meta?.preview;
      _preview = preview == null ? null : _compactPreview(preview);
      _model = meta?.modelOverride;
    });
  }

  static String _compactPreview(String text) {
    final compact = text.replaceAll(RegExp(r'\s+'), ' ');
    return compact.length > 96 ? '${compact.substring(0, 96)}...' : compact;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final folder = widget.session.folder;
    final preview = widget.matchPreview ?? _preview;
    final isSearchMatch = widget.matchPreview != null;

    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (preview != null && preview.isNotEmpty)
            Row(
              children: [
                if (isSearchMatch) ...[
                  Icon(
                    Icons.manage_search,
                    size: 13,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 4),
                ],
                Expanded(
                  child: Text(
                    preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: isSearchMatch
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              _metaBadge(context, widget.timeLabel),
              if (folder != null && folder.isNotEmpty)
                _metaBadge(context, folder, icon: Icons.folder_outlined),
              if (_model != null && _model!.isNotEmpty)
                _metaBadge(context, _model!, icon: Icons.smart_toy_outlined),
            ],
          ),
        ],
      ),
    );
  }

  Widget _metaBadge(BuildContext context, String label, {IconData? icon}) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withAlpha(170),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 3),
          ],
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
