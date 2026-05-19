import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../l10n/app_strings.dart';
import 'artifacts_view.dart';

class CodeBlock extends StatelessWidget {
  final String code;
  final String language;
  final int maxLines;

  const CodeBlock({
    super.key,
    required this.code,
    this.language = '',
    this.maxLines = 50,
  });

  static final _highlightPattern = RegExp(
    r'("(?:[^"\\]|\\.)*"|'       // double-quoted strings
    r"'(?:[^'\\]|\\.)*'|"        // single-quoted strings
    r'`(?:[^`\\]|\\.)*`|'        // backtick strings
    r'//.*$|'                     // line comments
    r'#.*$|'                      // hash comments
    r'/\*[\s\S]*?\*/|'            // block comments
    r'\b\d+\.?\d*\b|'            // numbers
    r'\b(?:if|else|for|while|return|import|from|class|function|def|const|let|var|async|await|try|catch|finally|throw|new|this|super|static|final|void|int|String|bool|double|true|false|null|None|self|print|extends|implements|abstract|enum|switch|case|break|continue|do|in|is|as|export|default|yield|with|required)\b|' // keywords
    r'\b[a-zA-Z_]\w*(?=\s*\()'   // function calls
    r')',
    multiLine: true,
  );

  static final _keywordSet = RegExp(
    r'^(if|else|for|while|return|import|from|class|function|def|const|let|var|async|await|try|catch|finally|throw|new|this|super|static|final|void|int|String|bool|double|true|false|null|None|self|print|extends|implements|abstract|enum|switch|case|break|continue|do|in|is|as|export|default|yield|with|required)$',
  );

  static const _monoFamily = 'DejaVuSansMono';
  static const _monoFallback = [
    'monospace',
    'Noto Sans Mono',
    'Noto Sans Mono CJK SC',
    'Noto Color Emoji',
  ];

  _CodePalette _paletteFor(ThemeData theme) {
    final dark = theme.brightness == Brightness.dark;
    return _CodePalette(
      background: dark
          ? theme.colorScheme.surfaceContainerLow
          : theme.colorScheme.surfaceContainerHighest,
      headerBackground: dark
          ? theme.colorScheme.surfaceContainer
          : theme.colorScheme.surfaceContainerHigh,
      defaultColor: theme.colorScheme.onSurface,
      comment: dark ? const Color(0xFF7DD3A8) : const Color(0xFF287348),
      string: dark ? const Color(0xFFF2B8A2) : const Color(0xFF9A4D28),
      number: dark ? const Color(0xFFC4DFA6) : const Color(0xFF546F2F),
      keyword: dark ? const Color(0xFF8FC7FF) : theme.colorScheme.primary,
      function: dark ? const Color(0xFFE5D68A) : const Color(0xFF7A5C00),
    );
  }

  List<TextSpan> _highlightCode(String code, _CodePalette palette) {
    final spans = <TextSpan>[];
    final lines = code.split('\n');

    for (int i = 0; i < lines.length; i++) {
      if (i > 0) spans.add(const TextSpan(text: '\n'));
      spans.addAll(_highlightLine(lines[i], palette));
    }
    return spans;
  }

  List<TextSpan> _highlightLine(String line, _CodePalette palette) {
    final spans = <TextSpan>[];

    // Check for full-line comment
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('//') || trimmed.startsWith('#')) {
      return [TextSpan(text: line, style: TextStyle(color: palette.comment))];
    }

    int lastEnd = 0;
    for (final match in _highlightPattern.allMatches(line)) {
      if (match.start > lastEnd) {
        spans.add(TextSpan(
          text: line.substring(lastEnd, match.start),
          style: TextStyle(color: palette.defaultColor),
        ));
      }
      final text = match.group(0)!;
      TextStyle style;
      if (text.startsWith('"') || text.startsWith("'") || text.startsWith('`')) {
        style = TextStyle(color: palette.string);
      } else if (text.startsWith('//') || text.startsWith('#') || text.startsWith('/*')) {
        style = TextStyle(color: palette.comment);
      } else if (RegExp(r'^\d').hasMatch(text)) {
        style = TextStyle(color: palette.number);
      } else if (_keywordSet.hasMatch(text)) {
        style = TextStyle(color: palette.keyword);
      } else {
        style = TextStyle(color: palette.function);
      }
      spans.add(TextSpan(text: text, style: style));
      lastEnd = match.end;
    }
    if (lastEnd < line.length) {
      spans.add(TextSpan(
        text: line.substring(lastEnd),
        style: TextStyle(color: palette.defaultColor),
      ));
    }
    return spans;
  }

  bool get _isPreviewableHtml {
    if (language.toLowerCase() != 'html') return false;
    final lower = code.toLowerCase();
    return lower.contains('<html') ||
        lower.contains('<!doctype') ||
        lower.contains('<body');
  }

  void _showPreview(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.85,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (ctx, scrollController) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    AppStrings.artifactsPreview,
                    style: Theme.of(ctx).textTheme.titleMedium,
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ArtifactsView(htmlContent: code),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = _paletteFor(theme);

    final lines = code.split('\n');
    final displayCode = lines.length > maxLines
        ? '${lines.take(maxLines).join('\n')}\n\n... (${lines.length - maxLines} lines omitted)'
        : code;

    final highlightedSpans = _highlightCode(displayCode, palette);

    final showPreview = _isPreviewableHtml;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: palette.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outline.withAlpha(35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (language.isNotEmpty || code.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: palette.headerBackground,
                border: Border(
                  bottom: BorderSide(
                    color: theme.colorScheme.outline.withAlpha(30),
                  ),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  if (language.isNotEmpty)
                    Text(language, style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    )),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (showPreview)
                        IconButton(
                          tooltip: AppStrings.preview,
                          icon: Icon(Icons.visibility, size: 18,
                              color: theme.colorScheme.primary),
                          onPressed: () => _showPreview(context),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                        ),
                      IconButton(
                        tooltip: AppStrings.copy,
                        icon: Icon(Icons.copy, size: 18,
                            color: theme.colorScheme.onSurfaceVariant),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: code));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(AppStrings.copied),
                              duration: Duration(seconds: 1),
                            ),
                          );
                        },
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(12),
            child: SelectableText.rich(
              TextSpan(
                children: highlightedSpans,
                style: TextStyle(
                  fontFamily: _monoFamily,
                  fontFamilyFallback: _monoFallback,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CodePalette {
  final Color background;
  final Color headerBackground;
  final Color defaultColor;
  final Color comment;
  final Color string;
  final Color number;
  final Color keyword;
  final Color function;

  const _CodePalette({
    required this.background,
    required this.headerBackground,
    required this.defaultColor,
    required this.comment,
    required this.string,
    required this.number,
    required this.keyword,
    required this.function,
  });
}
