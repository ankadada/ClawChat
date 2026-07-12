import 'package:clawchat/widgets/streaming_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(StreamingText.clearCacheForTesting);

  testWidgets('protects oversized messages with collapsed tail rendering',
      (tester) async {
    var opened = false;
    final longText = [
      'HEAD_UNIQUE',
      'a' * (StreamingText.cacheMaxCharactersForTesting ~/ 3 + 10000),
      'TAIL_UNIQUE',
    ].join('\n');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(
            width: 420,
            child: StreamingText(
              text: longText,
              onOpenFullResponse: () => opened = true,
            ),
          ),
        ),
      ),
    ));

    expect(find.text('打开完整回复'), findsOneWidget);
    expect(find.textContaining('TAIL_UNIQUE'), findsOneWidget);
    expect(find.textContaining('HEAD_UNIQUE'), findsNothing);

    await tester.tap(find.text('打开完整回复'));
    await tester.pumpAndSettle();

    expect(opened, isTrue);
    expect(find.textContaining('HEAD_UNIQUE'), findsNothing);
  });
}
