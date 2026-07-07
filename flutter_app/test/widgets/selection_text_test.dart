import 'package:clawchat/models/chat_models.dart';
import 'package:clawchat/widgets/tool_call_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('tool call card exposes plain Text under SelectionArea',
      (tester) async {
    ToolCallCard.clearExpansionState();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectionArea(
            child: ToolCallCard(
              toolUse: ToolUseContent(
                id: 'tool-selection',
                name: 'bash',
                input: const {'command': 'echo hello'},
              ),
              toolOutput: 'hello\nworld',
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('echo hello'));
    await tester.pumpAndSettle();

    expect(find.text('hello\nworld'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ToolCallCard),
        matching: find.byType(SelectableText),
      ),
      findsNothing,
    );
  });
}
