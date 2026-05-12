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

  List<TextSpan> _highlightCode(String code, String? language, Color defaultColor) {
    final spans = <TextSpan>[];
    final lines = code.split('\n');

    for (int i = 0; i < lines.length; i++) {
      if (i > 0) spans.add(const TextSpan(text: '\n'));
      spans.addAll(_highlightLine(lines[i], defaultColor));
    }
    return spans;
  }

  List<TextSpan> _highlightLine(String line, Color defaultColor) {
    final spans = <TextSpan>[];

    // Check for full-line comment
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('//') || trimmed.startsWith('#')) {
      return [TextSpan(text: line, style: const TextStyle(color: Color(0xFF6A9955)))];
    }

    int lastEnd = 0;
    for (final match in _highlightPattern.allMatches(line)) {
      if (match.start > lastEnd) {
        spans.add(TextSpan(
          text: line.substring(lastEnd, match.start),
          style: TextStyle(color: defaultColor),
        ));
      }
      final text = match.group(0)!;
      TextStyle style;
      if (text.startsWith('"') || text.startsWith("'") || text.startsWith('`')) {
        style = const TextStyle(color: Color(0xFFCE9178)); // strings: orange
      } else if (text.startsWith('//') || text.startsWith('#') || text.startsWith('/*')) {
        style = const TextStyle(color: Color(0xFF6A9955)); // comments: green
      } else if (RegExp(r'^\d').hasMatch(text)) {
        style = const TextStyle(color: Color(0xFFB5CEA8)); // numbers: light green
      } else if (_keywordSet.hasMatch(text)) {
        style = const TextStyle(color: Color(0xFF569CD6)); // keywords: blue
      } else {
        style = const TextStyle(color: Color(0xFFDCDCAA)); // functions: yellow
      }
      spans.add(TextSpan(text: text, style: style));
      lastEnd = match.end;
    }
    if (lastEnd < line.length) {
      spans.add(TextSpan(
        text: line.substring(lastEnd),
        style: TextStyle(color: defaultColor),
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

    final lines = code.split('\n');
    final displayCode = lines.length > maxLines
        ? '${lines.take(maxLines).join('\n')}\n\n... (${lines.length - maxLines} lines omitted)'
        : code;

    final defaultColor = theme.colorScheme.onSurface;
    final highlightedSpans = _highlightCode(displayCode, language, defaultColor);

    final showPreview = _isPreviewableHtml;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (language.isNotEmpty || code.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
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
                        SizedBox(
                          height: 48,
                          child: InkWell(
                            onTap: () => _showPreview(context),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.visibility, size: 14,
                                      color: theme.colorScheme.primary),
                                  const SizedBox(width: 4),
                                  Text(AppStrings.preview, style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.primary,
                                  )),
                                ],
                              ),
                            ),
                          ),
                        ),
                      SizedBox(
                        height: 48,
                        child: InkWell(
                          onTap: () {
                            Clipboard.setData(ClipboardData(text: code));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(AppStrings.copied),
                                duration: Duration(seconds: 1),
                              ),
                            );
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.copy, size: 14,
                                    color: theme.colorScheme.onSurfaceVariant),
                                const SizedBox(width: 4),
                                Text(AppStrings.copy, style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                )),
                              ],
                            ),
                          ),
                        ),
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
                  fontFamily: 'monospace',
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
