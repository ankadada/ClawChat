import 'package:clawchat/widgets/app_hardware_shortcuts.dart';
import 'package:clawchat/widgets/pasted_text_blocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late int newChatCount;
  late int searchCount;

  setUp(() {
    newChatCount = 0;
    searchCount = 0;
  });

  tearDown(() {
    AppShortcutTargets.resetForTesting();
  });

  Future<void> pumpShell(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => AppHardwareShortcuts(
          onNewChat: () => newChatCount++,
          onFocusSessionSearch: () => searchCount++,
          child: child!,
        ),
        home: Scaffold(
          body: Column(
            children: [
              // The composer: it may keep Ctrl/Cmd+N.
              const ComposerFieldMarker(
                child: TextField(key: Key('composer')),
              ),
              const SizedBox(height: 12),
              Center(
                child: TextButton(
                  key: const Key('open-dialog'),
                  onPressed: () => showDialog<void>(
                    context: tester.element(find.byType(TextButton)),
                    builder: (_) => const AlertDialog(
                      title: Text('dialog'),
                      content: TextField(key: Key('dialog-field')),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> pressWithControl(
    WidgetTester tester,
    LogicalKeyboardKey key,
  ) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  testWidgets('Ctrl+N creates a new chat and Ctrl+F opens session search',
      (tester) async {
    await pumpShell(tester);

    await pressWithControl(tester, LogicalKeyboardKey.keyN);
    expect(newChatCount, 1);

    await pressWithControl(tester, LogicalKeyboardKey.keyF);
    expect(searchCount, 1);
  });

  testWidgets('the composer keeps Ctrl+N', (tester) async {
    await pumpShell(tester);

    await tester.tap(find.byKey(const Key('composer')));
    await tester.pumpAndSettle();

    expect(AppHardwareShortcuts.isBlockedByEditableFocus(), isFalse);

    await pressWithControl(tester, LogicalKeyboardKey.keyN);
    expect(newChatCount, 1);
  });

  testWidgets('another focused text field does not lose the keys to the shell',
      (tester) async {
    await pumpShell(tester);

    await tester.tap(find.byKey(const Key('open-dialog')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('dialog-field')));
    await tester.pumpAndSettle();

    await pressWithControl(tester, LogicalKeyboardKey.keyN);
    await pressWithControl(tester, LogicalKeyboardKey.keyF);

    expect(newChatCount, 0);
    expect(searchCount, 0);
    // The shell sees a non-composer editable field and stands down; the dialog
    // field keeps focus because the keys were not consumed.
    expect(AppHardwareShortcuts.isBlockedByEditableFocus(), isTrue);
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<TextField>()
          ?.key,
      const Key('dialog-field'),
    );
  });
}
