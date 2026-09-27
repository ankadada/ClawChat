import 'package:clawchat/widgets/pasted_text_blocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PastedTextBlocks', () {
    test('treats only >800 characters or >20 lines as a long paste', () {
      expect(PastedTextBlocks.isLongPaste('x' * 800), isFalse);
      expect(PastedTextBlocks.isLongPaste('x' * 801), isTrue);
      expect(PastedTextBlocks.isLongPaste(List.filled(20, 'x').join('\n')),
          isFalse);
      expect(PastedTextBlocks.isLongPaste(List.filled(21, 'x').join('\n')),
          isTrue);
    });

    test('expands tokens back to the full text in order', () {
      final blocks = PastedTextBlocks();
      final first = blocks.add('first paste');
      final second = blocks.add('second paste');

      final expanded = blocks.expand(
        'before [Pasted#$first] middle [Pasted#$second] after',
      );

      expect(expanded, 'before first paste middle second paste after');
    });

    test('removal and retain keep only referenced blocks', () {
      final blocks = PastedTextBlocks();
      final first = blocks.add('a');
      final second = blocks.add('b');
      expect(PastedTextBlocks.referencedIds('[Pasted#$first]'), [first]);

      blocks.retainReferenced('[Pasted#$second]');
      expect(blocks.ids, [second]);
      expect(blocks.expand('[Pasted#$first]'), '[Pasted#$first]');

      blocks.remove(second);
      expect(blocks.isEmpty, isTrue);
    });
  });

  group('composer paste', () {
    late String clipboard;

    setUp(() {
      clipboard = '';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') {
          return clipboard.isEmpty ? null : <String, dynamic>{'text': clipboard};
        }
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    Future<void> pumpComposer(WidgetTester tester) async {
      final blocks = PastedTextBlocks();
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      addTearDown(blocks.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                PastedTextChipRow(
                  blocks: blocks,
                  onRemove: (id) {
                    controller.text = controller.text
                        .replaceAll(PastedTextBlocks.tokenFor(id), '');
                    blocks.remove(id);
                  },
                ),
                ComposerFieldMarker(
                  child: ComposerPasteShortcuts(
                    onPaste: () async {
                      final data = await Clipboard.getData(Clipboard.kTextPlain);
                      final pasted = data?.text ?? '';
                      if (pasted.isEmpty) return;
                      if (!PastedTextBlocks.isLongPaste(pasted)) {
                        controller.text += pasted;
                        return;
                      }
                      final id = blocks.add(pasted);
                      controller.text += PastedTextBlocks.tokenFor(id);
                    },
                    child: TextField(controller: controller),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.byType(TextField));
      await tester.pump();
    }

    Future<void> pressPaste(WidgetTester tester) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
    }

    testWidgets('a long paste becomes a chip and keeps the composer short',
        (tester) async {
      final long = 'x' * (PastedTextBlocks.maxCharacters + 1);
      clipboard = long;
      await pumpComposer(tester);

      await pressPaste(tester);

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, '[Pasted#1]');
      expect(find.widgetWithText(ActionChip, '[Pasted#1]'), findsOneWidget);
      expect(field.controller!.text.length, lessThan(20));
    });

    testWidgets('tapping the chip shows the full text and removes it',
        (tester) async {
      final long = 'y' * (PastedTextBlocks.maxCharacters + 1);
      clipboard = long;
      await pumpComposer(tester);
      await pressPaste(tester);

      await tester.tap(find.widgetWithText(ActionChip, '[Pasted#1]'));
      await tester.pumpAndSettle();

      expect(find.text(long), findsOneWidget);
      expect(find.text('已粘贴文本 [Pasted#1]'), findsOneWidget);
      expect(find.text('已粘贴文本'), findsNothing);

      await tester.tap(find.text('移除'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(ActionChip, '[Pasted#1]'), findsNothing);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, isEmpty);
    });

    testWidgets('a short paste stays inline', (tester) async {
      clipboard = 'short paste';
      await pumpComposer(tester);

      await pressPaste(tester);

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, 'short paste');
      expect(find.byType(ActionChip), findsNothing);
    });
  });
}
