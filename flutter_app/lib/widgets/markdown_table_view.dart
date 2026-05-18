import 'package:flutter/material.dart';

enum MarkdownTableColumnAlignment {
  left,
  center,
  right,
}

class MarkdownTableView extends StatelessWidget {
  final List<String> headers;
  final List<List<String>> rows;
  final List<MarkdownTableColumnAlignment> alignments;

  const MarkdownTableView({
    super.key,
    required this.headers,
    required this.rows,
    this.alignments = const [],
  });

  static const _borderRadius = BorderRadius.all(Radius.circular(8));
  static const _cellPadding = EdgeInsets.symmetric(
    horizontal: 10,
    vertical: 8,
  );
  static const _maxCellWidth = 220.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final columnCount = _columnCount;

    if (columnCount == 0) {
      return const SizedBox.shrink();
    }

    final mediaQuery = MediaQuery.maybeOf(context);
    final minTableWidth = (mediaQuery?.size.width ?? 360) * 0.72;
    final borderSide = BorderSide(
      color: colorScheme.outlineVariant,
      width: 0.8,
    );

    return DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        border: Border.all(color: colorScheme.outlineVariant, width: 0.8),
        borderRadius: _borderRadius,
      ),
      child: ClipRRect(
        borderRadius: _borderRadius,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: minTableWidth),
            child: Table(
              defaultColumnWidth: const IntrinsicColumnWidth(),
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              border: TableBorder(
                horizontalInside: borderSide,
                verticalInside: borderSide,
              ),
              children: [
                _buildRow(
                  context,
                  _normalizeCells(headers, columnCount),
                  colorScheme.surfaceContainerHighest,
                  isHeader: true,
                ),
                for (int i = 0; i < rows.length; i++)
                  _buildRow(
                    context,
                    _normalizeCells(rows[i], columnCount),
                    i.isEven
                        ? colorScheme.surface
                        : colorScheme.surfaceContainerLow,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  int get _columnCount {
    if (headers.isNotEmpty) {
      return headers.length;
    }

    return rows.fold<int>(
      0,
      (maxColumns, row) => row.length > maxColumns ? row.length : maxColumns,
    );
  }

  TableRow _buildRow(
    BuildContext context,
    List<String> cells,
    Color backgroundColor, {
    bool isHeader = false,
  }) {
    final theme = Theme.of(context);
    final baseStyle = isHeader
        ? theme.textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.onSurface,
          )
        : theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface,
          );

    return TableRow(
      decoration: BoxDecoration(color: backgroundColor),
      children: [
        for (int column = 0; column < cells.length; column++)
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _maxCellWidth),
            child: Padding(
              padding: _cellPadding,
              child: Text(
                cells[column],
                softWrap: true,
                textAlign: _textAlignForColumn(column),
                style: baseStyle,
              ),
            ),
          ),
      ],
    );
  }

  TextAlign _textAlignForColumn(int column) {
    final alignment = column < alignments.length
        ? alignments[column]
        : MarkdownTableColumnAlignment.left;

    return switch (alignment) {
      MarkdownTableColumnAlignment.center => TextAlign.center,
      MarkdownTableColumnAlignment.right => TextAlign.right,
      MarkdownTableColumnAlignment.left => TextAlign.left,
    };
  }

  List<String> _normalizeCells(List<String> cells, int columnCount) {
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
}
