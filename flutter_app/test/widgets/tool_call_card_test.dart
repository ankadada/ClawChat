import 'dart:convert';
import 'package:clawchat/widgets/tool_call_card.dart';
import 'package:clawchat/l10n/app_strings.dart';
import 'package:clawchat/models/chat_models.dart';
import 'package:clawchat/constants.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  testWidgets('shows a permission Fix button only for permission_required',
      (tester) async {
    ToolCallCard.clearExpansionState();

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ToolCallCard(
          toolUse: ToolUseContent(
            id: 'phone-denied',
            name: 'phone_read',
            input: const {'action': 'listSms'},
          ),
          toolOutput: '{"ok":false,"error":"permission_required",'
              '"permission":"READ_SMS","fix":"打开 系统设置"}',
        ),
      ),
    ));

    expect(find.text(AppStrings.openPermissionSettings), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is FilledButton && widget.onPressed != null,
      ),
      findsOneWidget,
    );

    // A missing native handler must not crash the run.
    await tester.tap(find.text(AppStrings.openPermissionSettings));
    await tester.pump();

    ToolCallCard.clearExpansionState();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ToolCallCard(
          toolUse: ToolUseContent(
            id: 'phone-ok',
            name: 'phone_read',
            input: const {'action': 'listSms'},
          ),
          toolOutput: '{"ok":true,"messages":[]}',
        ),
      ),
    ));

    expect(find.text(AppStrings.openPermissionSettings), findsNothing);
    expect(
      find.byWidgetPredicate((widget) => widget is FilledButton),
      findsNothing,
    );
  });

  testWidgets('a readable workspace image renders with Image.memory, a missing '
      'path keeps its label', (tester) async {
    ToolCallCard.clearExpansionState();
    const channel = MethodChannel(AppConstants.channelName);
    // A real 1x1 PNG, so Image.memory can actually decode it.
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8AARAAE/AP/'
      'CoKpBwAAAABJRU5ErkJggg==',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'readRootfsFileBytes') {
        final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
        return args['path'] == 'root/workspace/shot.png' ? png : null;
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ToolCallCard(
          toolUse: ToolUseContent(
            id: 'image-1',
            name: 'bash',
            input: const {'command': 'screenshot'},
          ),
          toolOutput: 'saved /root/workspace/shot.png\n'
              'missing /root/workspace/gone.png',
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // The readable path rendered as an image; the missing path kept its label.
    expect(find.byType(Image), findsOneWidget);
    expect(find.byIcon(Icons.image_outlined), findsOneWidget);
  });
}
