import 'package:clawchat/widgets/tool_call_card.dart';
import 'package:clawchat/l10n/app_strings.dart';
import 'package:clawchat/models/chat_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders web search sources from tool output', (tester) async {
    ToolCallCard.clearExpansionState();

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ToolCallCard(
          toolUse: ToolUseContent(
            id: 'tool-1',
            name: 'web_search',
            input: const {'query': 'flutter'},
          ),
          toolOutput: '''
Flutter Result
https://flutter.dev.
''',
        ),
      ),
    ));

    await tester.tap(find.text('flutter'));
    await tester.pumpAndSettle();

    expect(find.text(AppStrings.searchSources), findsOneWidget);
    expect(find.text('Flutter Result'), findsWidgets);
  });

  group('web search source helpers', () {
    test('validates launchable schemes', () {
      expect(isLaunchableSearchSource(Uri.parse('http://example.com')), isTrue);
      expect(isLaunchableSearchSource(Uri.parse('https://example.com/path')), isTrue);
      expect(isLaunchableSearchSource(Uri.parse('https:///missing-host')), isFalse);

      for (final url in [
        'javascript:alert(1)',
        'file:///tmp/source.txt',
        'data:text/plain,hello',
        'clawchat://source',
        'mailto:test@example.com',
      ]) {
        expect(isLaunchableSearchSource(Uri.parse(url)), isFalse);
      }
    });

    test('strips trailing punctuation and extracts title', () {
      final sources = parseSearchSources('''
Example Result
https://example.com/path,
''');

      expect(sources, hasLength(1));
      expect(sources.single.uri.toString(), 'https://example.com/path');
      expect(sources.single.label, 'Example Result');
    });

    test('dedupes URLs and caps source chips at eight', () {
      final sources = parseSearchSources('''
First
https://example.com/1

---
Duplicate
https://example.com/1

---
Second
https://example.com/2

---
Third
https://example.com/3

---
Fourth
https://example.com/4

---
Fifth
https://example.com/5

---
Sixth
https://example.com/6

---
Seventh
https://example.com/7

---
Eighth
https://example.com/8

---
Ninth
https://example.com/9
''');

      expect(sources, hasLength(8));
      expect(sources.map((source) => source.uri.toString()).toSet(), hasLength(8));
      expect(sources.map((source) => source.uri.toString()), isNot(contains('https://example.com/9')));
    });
  });
}
