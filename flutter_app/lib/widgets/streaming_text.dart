import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:url_launcher/url_launcher.dart';

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
}

class _StreamingTextState extends State<StreamingText> {
  List<InlineSpan>? _cachedSpans;
  String? _cachedText;
  int _lastParseEnd = 0;
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
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
    final spans = _getOrParseSpans(widget.text, theme);

    return SelectableText.rich(
      TextSpan(children: spans),
      style: theme.textTheme.bodyMedium,
    );
  }

  List<InlineSpan> _getOrParseSpans(String text, ThemeData theme) {
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

    if (_cachedSpans != null && _cachedText == parseText) {
      final result = List<InlineSpan>.from(_cachedSpans!);
      if (trailing.isNotEmpty) {
        result.add(TextSpan(text: trailing));
      }
      if (widget.isStreaming) {
        result.add(TextSpan(
          text: '▌',
          style: TextStyle(color: theme.colorScheme.primary),
        ));
      }
      return result;
    }

    final isNewAppend = _cachedText != null &&
        parseText.length > _cachedText!.length &&
        parseText.startsWith(_cachedText!);

    if (isNewAppend && _cachedSpans != null) {
      final newSpans = List<InlineSpan>.from(_cachedSpans!);
      _appendParsedSpans(parseText, theme, newSpans, _lastParseEnd);
      _cachedSpans = newSpans;
      _cachedText = parseText;
      final result = List<InlineSpan>.from(newSpans);
      if (trailing.isNotEmpty) {
        result.add(TextSpan(text: trailing));
      }
      if (widget.isStreaming) {
        result.add(TextSpan(
          text: '▌',
          style: TextStyle(color: theme.colorScheme.primary),
        ));
      }
      return result;
    }

    _disposeRecognizers();
    final spans = _parseFullText(parseText, theme);
    _cachedSpans = spans;
    _cachedText = parseText;
    final result = List<InlineSpan>.from(spans);
    if (trailing.isNotEmpty) {
      result.add(TextSpan(text: trailing));
    }
    if (widget.isStreaming) {
      result.add(TextSpan(
        text: '▌',
        style: TextStyle(color: theme.colorScheme.primary),
      ));
    }
    return result;
  }

  static final _codeBlockRegex = RegExp(r'```(\w*)\n([\s\S]*?)```');
  static final _tableRegex = RegExp(
    r'(?:^|\n)((?:\|[^\n]*\|\n){2,})',
    multiLine: true,
  );
  static final _inlineCodeRegex = RegExp(r'`([^`]+)`');
  static final _boldRegex = RegExp(r'\*\*(.+?)\*\*');
  static final _headingRegex = RegExp(r'^(#{1,3})\s+(.+)$', multiLine: true);
  static final _bulletRegex = RegExp(r'^[-*]\s+(.+)$', multiLine: true);
  static final _hrRegex = RegExp(r'^---+$', multiLine: true);
  static final _blockquoteRegex = RegExp(r'^>\s*(.+)$', multiLine: true);
  static final _linkRegex = RegExp(r'\[([^\]]+)\]\(([^)]+)\)');

  List<InlineSpan> _parseFullText(String text, ThemeData theme) {
    final spans = <InlineSpan>[];
    _lastParseEnd = 0;
    _appendParsedSpans(text, theme, spans, 0);
    return spans;
  }

  void _appendParsedSpans(
      String text, ThemeData theme, List<InlineSpan> spans, int from) {
    final allMatches = <_MatchInfo>[];

    for (final match in _codeBlockRegex.allMatches(text, from)) {
      allMatches.add(_MatchInfo(match.start, match.end, 'codeblock', match));
    }
    for (final match in _tableRegex.allMatches(text, from)) {
      if (!allMatches.any((m) => match.start >= m.start && match.end <= m.end)) {
        allMatches.add(_MatchInfo(match.start, match.end, 'table', match));
      }
    }
    for (final match in _inlineCodeRegex.allMatches(text, from)) {
      if (!allMatches.any((m) => match.start >= m.start && match.end <= m.end)) {
        allMatches.add(_MatchInfo(match.start, match.end, 'inline', match));
      }
    }
    for (final match in _boldRegex.allMatches(text, from)) {
      if (!allMatches.any((m) => match.start >= m.start && match.end <= m.end)) {
        allMatches.add(_MatchInfo(match.start, match.end, 'bold', match));
      }
    }
    for (final match in _headingRegex.allMatches(text, from)) {
      if (!allMatches.any((m) => match.start >= m.start && match.end <= m.end)) {
        allMatches.add(_MatchInfo(match.start, match.end, 'heading', match));
      }
    }
    for (final match in _bulletRegex.allMatches(text, from)) {
      if (!allMatches.any((m) => match.start >= m.start && match.end <= m.end)) {
        allMatches.add(_MatchInfo(match.start, match.end, 'bullet', match));
      }
    }
    for (final match in _hrRegex.allMatches(text, from)) {
      if (!allMatches.any((m) => match.start >= m.start && match.end <= m.end)) {
        allMatches.add(_MatchInfo(match.start, match.end, 'hr', match));
      }
    }
    for (final match in _blockquoteRegex.allMatches(text, from)) {
      if (!allMatches.any((m) => match.start >= m.start && match.end <= m.end)) {
        allMatches.add(_MatchInfo(match.start, match.end, 'blockquote', match));
      }
    }
    for (final match in _linkRegex.allMatches(text, from)) {
      if (!allMatches.any((m) => match.start >= m.start && match.end <= m.end)) {
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
          spans.add(TextSpan(
            text: info.match.group(2),
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ));
        case 'table':
          final tableText = info.match.group(1)!;
          final rows = tableText.trim().split('\n')
              .where((r) => r.trim().isNotEmpty && !RegExp(r'^\|[\s\-:|\s]+\|$').hasMatch(r))
              .toList();

          if (rows.isNotEmpty) {
            // Parse all rows into cell lists and compute column widths
            final parsedRows = <List<String>>[];
            for (final row in rows) {
              final cells = row.split('|')
                  .where((c) => c.isNotEmpty || parsedRows.isEmpty)
                  .toList();
              // Trim leading/trailing empty entries from split
              final trimmed = <String>[];
              for (int j = 0; j < cells.length; j++) {
                final cell = cells[j].trim();
                if (j == 0 && cell.isEmpty) continue;
                if (j == cells.length - 1 && cell.isEmpty) continue;
                trimmed.add(cell);
              }
              parsedRows.add(trimmed);
            }

            // Compute max width per column
            final colCount = parsedRows.fold<int>(0, (m, r) => r.length > m ? r.length : m);
            final colWidths = List<int>.filled(colCount, 0);
            for (final row in parsedRows) {
              for (int c = 0; c < row.length && c < colCount; c++) {
                if (row[c].length > colWidths[c]) colWidths[c] = row[c].length;
              }
            }

            final formatted = StringBuffer();
            for (int i = 0; i < parsedRows.length; i++) {
              final cells = parsedRows[i];
              final paddedCells = <String>[];
              for (int c = 0; c < colCount; c++) {
                final val = c < cells.length ? cells[c] : '';
                paddedCells.add(val.padRight(colWidths[c]));
              }
              final line = paddedCells.join('  │  ');
              if (i == 0) {
                formatted.writeln('┌ $line ┐');
                final separator = colWidths.map((w) => '─' * (w + 2)).join('┼');
                formatted.writeln('├$separator┤');
              } else {
                formatted.writeln('│ $line │');
              }
            }

            spans.add(TextSpan(
              text: formatted.toString(),
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                color: theme.colorScheme.onSurface,
              ),
            ));
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
          final fontSize = level == 1 ? 20.0 : level == 2 ? 17.0 : 15.0;
          spans.add(TextSpan(
            text: '${info.match.group(2)}\n',
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurface,
            ),
          ));
        case 'bullet':
          spans.add(TextSpan(
            text: '  •  ${info.match.group(1)}\n',
            style: theme.textTheme.bodyMedium,
          ));
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

  @override
  void didUpdateWidget(StreamingText oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only invalidate cache when text is completely different (not append)
    // Incremental parsing handles appends without cache invalidation
    if (oldWidget.text != widget.text &&
        !widget.text.startsWith(oldWidget.text)) {
      _disposeRecognizers();
      _cachedSpans = null;
      _cachedText = null;
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
