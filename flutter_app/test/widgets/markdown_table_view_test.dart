import 'package:clawchat/widgets/markdown_table_view.dart';
import 'package:clawchat/widgets/streaming_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpStreamingText(
    WidgetTester tester,
    String text, {
    bool isStreaming = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: SizedBox(
            width: 360,
            child: StreamingText(
              text: text,
              isStreaming: isStreaming,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  MarkdownTableView renderedTable(WidgetTester tester) {
    return tester.widget<MarkdownTableView>(find.byType(MarkdownTableView));
  }

  group('StreamingText markdown tables', () {
    testWidgets('valid GFM table renders a MarkdownTableView', (tester) async {
      await pumpStreamingText(
        tester,
        '| Name | Age |\n'
        '| --- | --- |\n'
        '| Ada | 36 |\n',
      );

      expect(find.byType(MarkdownTableView), findsOneWidget);
      final table = renderedTable(tester);
      expect(table.headers, ['Name', 'Age']);
      expect(table.rows, [
        ['Ada', '36'],
      ]);
      expect(find.text('Ada'), findsOneWidget);
      expect(find.textContaining('┌'), findsNothing);
    });

    testWidgets('pipe text without delimiter is not rendered as a table',
        (tester) async {
      await pumpStreamingText(
        tester,
        '| Name | Age |\n'
        '| Ada | 36 |\n',
      );

      expect(find.byType(MarkdownTableView), findsNothing);
    });

    testWidgets('alignment markers are parsed correctly', (tester) async {
      await pumpStreamingText(
        tester,
        '| Left | Center | Right |\n'
        '| :--- | :---: | ---: |\n'
        '| a | b | c |\n',
      );

      final table = renderedTable(tester);
      expect(table.alignments, [
        MarkdownTableColumnAlignment.left,
        MarkdownTableColumnAlignment.center,
        MarkdownTableColumnAlignment.right,
      ]);
      expect(tester.widget<Text>(find.text('Left')).textAlign, TextAlign.left);
      expect(
        tester.widget<Text>(find.text('Center')).textAlign,
        TextAlign.center,
      );
      expect(
        tester.widget<Text>(find.text('Right')).textAlign,
        TextAlign.right,
      );
    });

    testWidgets('empty cells are preserved', (tester) async {
      await pumpStreamingText(
        tester,
        '| A | B | C |\n'
        '| --- | --- | --- |\n'
        '| 1 | | 3 |\n',
      );

      expect(renderedTable(tester).rows.single, ['1', '', '3']);
    });

    testWidgets('rows with fewer columns than headers are padded',
        (tester) async {
      await pumpStreamingText(
        tester,
        '| A | B | C |\n'
        '| --- | --- | --- |\n'
        '| 1 | 2 |\n',
      );

      expect(renderedTable(tester).rows.single, ['1', '2', '']);
    });

    testWidgets('rows with more columns than headers are truncated',
        (tester) async {
      await pumpStreamingText(
        tester,
        '| A | B |\n'
        '| --- | --- |\n'
        '| 1 | 2 | 3 |\n',
      );

      expect(renderedTable(tester).rows.single, ['1', '2']);
      expect(find.text('3'), findsNothing);
    });

    testWidgets('single-column table renders', (tester) async {
      await pumpStreamingText(
        tester,
        '| Only |\n'
        '| --- |\n'
        '| value |\n',
      );

      final table = renderedTable(tester);
      expect(table.headers, ['Only']);
      expect(table.rows, [
        ['value'],
      ]);
    });

    testWidgets('table with only headers renders with no data rows',
        (tester) async {
      await pumpStreamingText(
        tester,
        '| A | B |\n'
        '| --- | --- |\n',
      );

      final table = renderedTable(tester);
      expect(table.headers, ['A', 'B']);
      expect(table.rows, isEmpty);
    });

    testWidgets('streaming text waits for delimiter before rendering table',
        (tester) async {
      await pumpStreamingText(
        tester,
        '| A | B |\n',
        isStreaming: true,
      );

      expect(find.byType(MarkdownTableView), findsNothing);

      await pumpStreamingText(
        tester,
        '| A | B |\n'
        '| --- | --- |\n',
        isStreaming: true,
      );

      expect(find.byType(MarkdownTableView), findsOneWidget);
    });
  });
}
