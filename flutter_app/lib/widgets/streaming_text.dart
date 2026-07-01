import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:url_launcher/url_launcher.dart';

import 'code_block.dart';
import 'markdown_table_view.dart';

class StreamingText extends StatefulWidget {
  final String text;
  final bool isStreaming;

  const StreamingText({
    super.key,
    required this.text,
    this.isStreaming = false,
  });

  @override
  State<StreamingText> createState() => _StreamingTextState();

  @visibleForTesting
  static int get cacheEntryCountForTesting =>
      _MarkdownSpanCache.instance.entryCount;

  @visibleForTesting
  static int get cacheCharacterCountForTesting =>
      _MarkdownSpanCache.instance.characterCount;

  @visibleForTesting
  static int get cacheMaxCharactersForTesting =>
      _MarkdownSpanCache.maxCharacters;

  @visibleForTesting
  static void clearCacheForTesting() {
    _MarkdownSpanCache.instance.clear();
  }
}

class _StreamingTextState extends State<StreamingText>
    with SingleTickerProviderStateMixin {
  List<InlineSpan>? _cachedSpans;
  String? _cachedText;
  double? _cachedMaxWidth;
  int _lastParseEnd = 0;
  final List<TapGestureRecognizer> _recognizers = [];
  late final AnimationController _cursorController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 780),
  );
  late final Animation<double> _cursorAnimation;

  @override
  void initState() {
    super.initState();
    _cursorAnimation = Tween<double>(begin: 0.55, end: 1).animate(
      CurvedAnimation(parent: _cursorController, curve: Curves.easeInOutSine),
    );
    _syncCursorAnimation();
  }

  @override
  void dispose() {
    _disposeRecognizers();
    _cursorController.dispose();
    super.dispose();
  }

  void _syncCursorAnimation() {
    if (widget.isStreaming) {
      _cursorController.repeat(reverse: true);
    } else {
      _cursorController.stop();
      _cursorController.value = 1;
    }
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxInlineWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width * 0.78;
        final spans =
            _getOrParseSpans(widget.text, context, theme, maxInlineWidth);

        return SelectableText.rich(
          TextSpan(children: spans),
          style: theme.textTheme.bodyMedium,
        );
      },
    );
  }

  List<InlineSpan> _getOrParseSpans(
    String text,
    BuildContext context,
    ThemeData theme,
    double maxInlineWidth,
  ) {
    // During streaming, only parse up to the last newline to avoid
    // partial markdown patterns causing visual flashes.
    // Text after the last newline is shown as plain text.
    String parseText = text;
    String trailing = '';
    if (widget.isStreaming) {
      final lastNewline = text.lastIndexOf('\n');
      if (lastNewline > 0) {
        parseText = text.substring(0, lastNewline + 1);
        trailing = text.substring(lastNewline + 1);
      }
    }

    if (_cachedSpans != null &&
        _cachedText == parseText &&
        _cachedMaxWidth == maxInlineWidth) {
      final result = List<InlineSpan>.from(_cachedSpans!);
      if (trailing.isNotEmpty) {
        result.add(TextSpan(text: trailing));
      }
      if (widget.isStreaming) {
        result.add(_cursorSpan(theme));
      }
      return result;
    }

    if (!widget.isStreaming) {
      final sharedSpans = _MarkdownSpanCache.instance.get(
        text: parseText,
        maxInlineWidth: maxInlineWidth,
        theme: theme,
      );
      if (sharedSpans != null) {
        _disposeRecognizers();
        _cachedSpans = sharedSpans;
        _cachedText = parseText;
        _cachedMaxWidth = maxInlineWidth;
        return List<InlineSpan>.from(sharedSpans);
      }
    }

    final isNewAppend = !_tableRegex.hasMatch(parseText) &&
        !parseText.contains('```') &&
        _cachedText != null &&
        _cachedMaxWidth == maxInlineWidth &&
        parseText.length > _cachedText!.length &&
        parseText.startsWith(_cachedText!);

    if (isNewAppend && _cachedSpans != null) {
      final newSpans = List<InlineSpan>.from(_cachedSpans!);
      _appendParsedSpans(
          parseText, context, theme, newSpans, _lastParseEnd, maxInlineWidth);
      _cachedSpans = newSpans;
      _cachedText = parseText;
      _cachedMaxWidth = maxInlineWidth;
      final result = List<InlineSpan>.from(newSpans);
      if (trailing.isNotEmpty) {
        result.add(TextSpan(text: trailing));
      }
      if (widget.isStreaming) {
        result.add(_cursorSpan(theme));
      }
      return result;
    }

    _disposeRecognizers();
    final spans = _parseFullText(parseText, context, theme, maxInlineWidth);
    _cachedSpans = spans;
    _cachedText = parseText;
    _cachedMaxWidth = maxInlineWidth;
    if (!widget.isStreaming && _recognizers.isEmpty) {
      _MarkdownSpanCache.instance.put(
        text: parseText,
        maxInlineWidth: maxInlineWidth,
        theme: theme,
        spans: spans,
      );
    }
    final result = List<InlineSpan>.from(spans);
    if (trailing.isNotEmpty) {
      result.add(TextSpan(text: trailing));
    }
    if (widget.isStreaming) {
      result.add(_cursorSpan(theme));
    }
    return result;
  }

  InlineSpan _cursorSpan(ThemeData theme) {
    return WidgetSpan(
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      child: RepaintBoundary(
        child: FadeTransition(
          opacity: _cursorAnimation,
          child: Text(
            '▌',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
        ),
      ),
    );
  }

  static final _codeBlockRegex = RegExp(r'```([^\n`]*)\n([\s\S]*?)```');
  static final _tableRegex = RegExp(
    r'^([^\n]*\|[^\n]*\n[ \t]*\|?[ \t]*:?-{3,}:?[ \t]*(?:\|[ \t]*:?-{3,}:?[ \t]*)*\|?[ \t]*(?:\n[^\n]*\|[^\n]*)*(?:\n|$))',
    multiLine: true,
  );
  static final _tableDelimiterCellRegex = RegExp(r'^:?-{3,}:?$');
  static final _inlineCodeRegex = RegExp(r'`([^`]+)`');
  static final _boldRegex = RegExp(r'\*\*(.+?)\*\*');
  static final _headingRegex = RegExp(r'^(#{1,3})\s+(.+)$', multiLine: true);
  static final _bulletRegex = RegExp(r'^[-*]\s+(.+)$', multiLine: true);
  static final _hrRegex = RegExp(r'^---+$', multiLine: true);
  static final _blockquoteRegex = RegExp(r'^>\s*(.+)$', multiLine: true);
  static final _linkRegex = RegExp(r'\[([^\]]+)\]\(([^)]+)\)');

  List<InlineSpan> _parseFullText(
    String text,
    BuildContext context,
    ThemeData theme,
    double maxInlineWidth,
  ) {
    final spans = <InlineSpan>[];
    _lastParseEnd = 0;
    _appendParsedSpans(text, context, theme, spans, 0, maxInlineWidth);
    return spans;
  }

  void _appendParsedSpans(
    String text,
    BuildContext context,
    ThemeData theme,
    List<InlineSpan> spans,
    int from,
    double maxInlineWidth,
  ) {
    final allMatches = <_MatchInfo>[];

    for (final match in _codeBlockRegex.allMatches(text, from)) {
      allMatches.add(_MatchInfo(match.start, match.end, 'codeblock', match));
    }
    if (widget.isStreaming) {
      final openStart = text.lastIndexOf('```');
      if (openStart >= from &&
          !allMatches.any((m) => openStart >= m.start && openStart < m.end)) {
        final beforeOpen = text.substring(0, openStart);
        final fenceCount = '```'.allMatches(beforeOpen).length;
        final openMatch = RegExp(r'^```([^\n`]*)\n([\s\S]*)$')
            .firstMatch(text.substring(openStart));
        if (fenceCount.isEven && openMatch != null) {
          allMatches
              .add(_MatchInfo(openStart, text.length, 'codeblock', openMatch));
        }
      }
    }
    for (final match in _tableRegex.allMatches(text, from)) {
      if (!allMatches
          .any((m) => match.start >= m.start && match.end <= m.end)) {
        allMatches.add(_MatchInfo(match.start, match.end, 'table', match));
      }
    }
    for (final match in _inlineCodeRegex.allMatches(text, from)) {
      if (!allMatches
          .any((m) => match.start >= m.start && match.end <= m.end)) {
        allMatches.add(_MatchInfo(match.start, match.end, 'inline', match));
      }
    }
    for (final match in _boldRegex.allMatches(text, from)) {
      if (!allMatches
          .any((m) => match.start >= m.start && match.end <= m.end)) {
        allMatches.add(_MatchInfo(match.start, match.end, 'bold', match));
      }
    }
    for (final match in _headingRegex.allMatches(text, from)) {
      if (!allMatches
          .any((m) => match.start >= m.start && match.end <= m.end)) {
        allMatches.add(_MatchInfo(match.start, match.end, 'heading', match));
      }
    }
    for (final match in _bulletRegex.allMatches(text, from)) {
      if (!allMatches
          .any((m) => match.start >= m.start && match.end <= m.end)) {
        allMatches.add(_MatchInfo(match.start, match.end, 'bullet', match));
      }
    }
    for (final match in _hrRegex.allMatches(text, from)) {
      if (!allMatches
          .any((m) => match.start >= m.start && match.end <= m.end)) {
        allMatches.add(_MatchInfo(match.start, match.end, 'hr', match));
      }
    }
    for (final match in _blockquoteRegex.allMatches(text, from)) {
      if (!allMatches
          .any((m) => match.start >= m.start && match.end <= m.end)) {
        allMatches.add(_MatchInfo(match.start, match.end, 'blockquote', match));
      }
    }
    for (final match in _linkRegex.allMatches(text, from)) {
      if (!allMatches
          .any((m) => match.start >= m.start && match.end <= m.end)) {
        allMatches.add(_MatchInfo(match.start, match.end, 'link', match));
      }
    }

    allMatches.sort((a, b) => a.start.compareTo(b.start));

    int lastEnd = from;
    for (final info in allMatches) {
      if (info.start > lastEnd) {
        spans.add(TextSpan(text: text.substring(lastEnd, info.start)));
      }

      switch (info.type) {
        case 'codeblock':
          spans.add(const TextSpan(text: '\n'));
          spans.add(WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: maxInlineWidth,
                ),
                child: CodeBlock(
                  code: info.match.group(2) ?? '',
                  language: info.match.group(1) ?? '',
                ),
              ),
            ),
          ));
          spans.add(const TextSpan(text: '\n'));
        case 'table':
          final tableText = info.match.group(1)!;
          final parsedTable = _parseMarkdownTable(tableText);

          if (parsedTable == null) {
            spans.add(TextSpan(text: tableText));
          } else {
            spans.add(const TextSpan(text: '\n'));
            spans.add(WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: maxInlineWidth,
                  ),
                  child: MarkdownTableView(
                    headers: parsedTable.headers,
                    rows: parsedTable.rows,
                    alignments: parsedTable.alignments,
                  ),
                ),
              ),
            ));
            spans.add(const TextSpan(text: '\n'));
          }
        case 'inline':
          spans.add(TextSpan(
            text: info.match.group(1),
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              color: theme.colorScheme.primary,
            ),
          ));
        case 'bold':
          spans.add(TextSpan(
            text: info.match.group(1),
            style: const TextStyle(fontWeight: FontWeight.bold),
          ));
        case 'heading':
          final level = info.match.group(1)!.length;
          final headingStyle = (level == 1
                  ? theme.textTheme.titleMedium
                  : level == 2
                      ? theme.textTheme.titleSmall
                      : theme.textTheme.bodyLarge)
              ?.copyWith(
            fontWeight: FontWeight.w700,
            color: theme.colorScheme.onSurface,
          );
          spans.add(TextSpan(
            text: '${info.match.group(2)}\n',
            style: headingStyle,
          ));
        case 'bullet':
          spans.add(WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxInlineWidth),
              child: Padding(
                padding: const EdgeInsets.only(left: 4, top: 2, bottom: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('•', style: theme.textTheme.bodyMedium),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        info.match.group(1)!,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ));
          spans.add(const TextSpan(text: '\n'));
        case 'hr':
          spans.add(TextSpan(
            text: '\n━━━━━━━━━━━━━━━━━━━━\n',
            style: TextStyle(
              color: theme.colorScheme.outline.withAlpha(100),
              fontSize: 10,
              letterSpacing: 2,
            ),
          ));
        case 'blockquote':
          spans.add(TextSpan(
            text: '  ┃ ${info.match.group(1)}\n',
            style: TextStyle(
              color: theme.colorScheme.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
          ));
        case 'link':
          final linkText = info.match.group(1)!;
          final url = info.match.group(2)!;
          final recognizer = TapGestureRecognizer()
            ..onTap = () {
              final uri = Uri.tryParse(url);
              if (uri == null ||
                  (uri.scheme != 'http' && uri.scheme != 'https')) {
                return;
              }
              launchUrl(uri);
            };
          _recognizers.add(recognizer);
          spans.add(TextSpan(
            text: linkText,
            style: TextStyle(
              color: theme.colorScheme.primary,
              decoration: TextDecoration.underline,
            ),
            recognizer: recognizer,
          ));
      }

      lastEnd = info.end;
    }

    if (lastEnd < text.length) {
      spans.add(TextSpan(text: text.substring(lastEnd)));
    }

    _lastParseEnd = text.length;
  }

  _ParsedMarkdownTable? _parseMarkdownTable(String tableText) {
    final lines = tableText
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();

    if (lines.length < 2) {
      return null;
    }

    final headers = _splitMarkdownTableRow(lines[0]);
    final delimiterCells = _splitMarkdownTableRow(lines[1]);

    if (headers.isEmpty ||
        delimiterCells.isEmpty ||
        delimiterCells.length != headers.length) {
      return null;
    }

    final alignments = <MarkdownTableColumnAlignment>[];
    for (final cell in delimiterCells) {
      final marker = cell.replaceAll(RegExp(r'\s+'), '');
      if (!_tableDelimiterCellRegex.hasMatch(marker)) {
        return null;
      }

      final isLeftAligned = marker.startsWith(':');
      final isRightAligned = marker.endsWith(':');
      if (isLeftAligned && isRightAligned) {
        alignments.add(MarkdownTableColumnAlignment.center);
      } else if (isRightAligned) {
        alignments.add(MarkdownTableColumnAlignment.right);
      } else {
        alignments.add(MarkdownTableColumnAlignment.left);
      }
    }

    final rows = <List<String>>[];
    for (final line in lines.skip(2)) {
      final cells = _splitMarkdownTableRow(line);
      rows.add(_normalizeMarkdownTableCells(cells, headers.length));
    }

    return _ParsedMarkdownTable(
      headers: headers,
      rows: rows,
      alignments: alignments,
    );
  }

  List<String> _splitMarkdownTableRow(String row) {
    var trimmed = row.trim();
    if (trimmed.startsWith('|')) {
      trimmed = trimmed.substring(1);
    }
    if (trimmed.endsWith('|')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }

    return trimmed.split('|').map((cell) => cell.trim()).toList();
  }

  List<String> _normalizeMarkdownTableCells(
    List<String> cells,
    int columnCount,
  ) {
    if (cells.length == columnCount) {
      return cells;
    }

    if (cells.length > columnCount) {
      return cells.take(columnCount).toList();
    }

    return [
      ...cells,
      for (int i = cells.length; i < columnCount; i++) '',
    ];
  }

  @override
  void didUpdateWidget(StreamingText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isStreaming != widget.isStreaming) {
      _syncCursorAnimation();
    }
    // Only invalidate cache when text is completely different (not append)
    // Incremental parsing handles appends without cache invalidation
    if (oldWidget.text != widget.text &&
        !widget.text.startsWith(oldWidget.text)) {
      _disposeRecognizers();
      _cachedSpans = null;
      _cachedText = null;
      _cachedMaxWidth = null;
    }
  }
}

class _MatchInfo {
  final int start;
  final int end;
  final String type;
  final RegExpMatch match;

  _MatchInfo(this.start, this.end, this.type, this.match);
}

class _ParsedMarkdownTable {
  final List<String> headers;
  final List<List<String>> rows;
  final List<MarkdownTableColumnAlignment> alignments;

  const _ParsedMarkdownTable({
    required this.headers,
    required this.rows,
    required this.alignments,
  });
}

class _MarkdownSpanCache {
  static final instance = _MarkdownSpanCache();
  static const int maxEntries = 160;
  static const int maxCharacters = 220000;

  final _entries = <_MarkdownSpanCacheKey, _MarkdownSpanCacheEntry>{};
  int _characterCount = 0;

  int get entryCount => _entries.length;
  int get characterCount => _characterCount;

  List<InlineSpan>? get({
    required String text,
    required double maxInlineWidth,
    required ThemeData theme,
  }) {
    final key = _MarkdownSpanCacheKey.from(
      text: text,
      maxInlineWidth: maxInlineWidth,
      theme: theme,
    );
    final entry = _entries.remove(key);
    if (entry == null) return null;
    _entries[key] = entry;
    return List<InlineSpan>.from(entry.spans);
  }

  void put({
    required String text,
    required double maxInlineWidth,
    required ThemeData theme,
    required List<InlineSpan> spans,
  }) {
    if (text.isEmpty || text.length > maxCharacters ~/ 3) return;
    final key = _MarkdownSpanCacheKey.from(
      text: text,
      maxInlineWidth: maxInlineWidth,
      theme: theme,
    );
    final previous = _entries.remove(key);
    if (previous != null) {
      _characterCount -= previous.characterCount;
    }
    _entries[key] = _MarkdownSpanCacheEntry(
      spans: List<InlineSpan>.from(spans),
      characterCount: text.length,
    );
    _characterCount += text.length;
    _evictToBudget();
  }

  void _evictToBudget() {
    while (_entries.length > maxEntries || _characterCount > maxCharacters) {
      final oldestKey = _entries.keys.first;
      final oldest = _entries.remove(oldestKey);
      if (oldest == null) break;
      _characterCount -= oldest.characterCount;
    }
  }

  void clear() {
    _entries.clear();
    _characterCount = 0;
  }
}

class _MarkdownSpanCacheKey {
  final String text;
  final int width;
  final int colorHash;
  final Brightness brightness;

  const _MarkdownSpanCacheKey({
    required this.text,
    required this.width,
    required this.colorHash,
    required this.brightness,
  });

  factory _MarkdownSpanCacheKey.from({
    required String text,
    required double maxInlineWidth,
    required ThemeData theme,
  }) {
    final colors = theme.colorScheme;
    return _MarkdownSpanCacheKey(
      text: text,
      width: maxInlineWidth.round(),
      colorHash: Object.hash(
        colors.primary,
        colors.onSurface,
        colors.onSurfaceVariant,
        colors.surfaceContainerHighest,
        colors.outline,
      ),
      brightness: theme.brightness,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is _MarkdownSpanCacheKey &&
        text == other.text &&
        width == other.width &&
        colorHash == other.colorHash &&
        brightness == other.brightness;
  }

  @override
  int get hashCode => Object.hash(text, width, colorHash, brightness);
}

class _MarkdownSpanCacheEntry {
  final List<InlineSpan> spans;
  final int characterCount;

  const _MarkdownSpanCacheEntry({
    required this.spans,
    required this.characterCount,
  });
}
