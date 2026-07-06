import 'package:clawchat/l10n/app_strings.dart';
import 'package:clawchat/widgets/reasoning_text_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('auto-collapses long reasoning and expands on demand',
      (tester) async {
    final longReasoning =
        'prefix-hidden\n${List.filled(5000, 'step').join('\n')}\ntail-visible';

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ReasoningTextPanel(text: longReasoning),
      ),
    ));

    expect(find.text(AppStrings.reasoningPanelExpand), findsOneWidget);
    expect(find.text(AppStrings.reasoningPanelCollapse), findsNothing);
    expect(find.textContaining('tail-visible'), findsOneWidget);
    expect(find.textContaining('prefix-hidden'), findsNothing);

    await tester.tap(find.text(AppStrings.reasoningPanelExpand));
    await tester.pumpAndSettle();

    expect(find.text(AppStrings.reasoningPanelCollapse), findsOneWidget);
    expect(find.textContaining(AppStrings.reasoningPanelShowingRecent),
        findsOneWidget);
  });

  testWidgets('streaming preview uses total length without rendering all text',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: ReasoningTextPanel(
          text: 'recent reasoning',
          totalLength: 50000,
          isStreaming: true,
        ),
      ),
    ));

    expect(find.text(AppStrings.reasoningPanelStreaming), findsOneWidget);
    expect(
        find.text(AppStrings.reasoningPanelCharacters(50000)), findsOneWidget);
    expect(find.textContaining('recent reasoning'), findsOneWidget);
    expect(find.textContaining(AppStrings.reasoningPanelShowingRecent),
        findsOneWidget);
  });
}
