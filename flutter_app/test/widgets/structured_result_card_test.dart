import 'dart:async';

import 'package:clawchat/models/structured_result.dart';
import 'package:clawchat/widgets/structured_result_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders the four fixed blocks in document order at 320dp',
      (tester) async {
    await _pumpCard(
      tester,
      document: _fourBlockDocument(),
      size: const Size(320, 640),
      textScale: 2,
    );

    final notice = find.text('Imported safely');
    final details = find.text('Details');
    final checks = find.text('Checks');
    final actions = find.text('Actions');
    expect(notice, findsOneWidget);
    expect(details, findsOneWidget);
    expect(checks, findsOneWidget);
    expect(actions, findsOneWidget);
    expect(
      tester.getTopLeft(notice).dy,
      lessThan(tester.getTopLeft(details).dy),
    );
    expect(
      tester.getTopLeft(details).dy,
      lessThan(tester.getTopLeft(checks).dy),
    );
    expect(
      tester.getTopLeft(checks).dy,
      lessThan(tester.getTopLeft(actions).dy),
    );
    expect(
      tester.getSize(find.byType(StructuredResultCard)).width,
      lessThanOrEqualTo(320),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid structured data has no actionable control',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await _pumpCard(
      tester,
      document: _fourBlockDocument(),
      isInvalid: true,
    );

    expect(find.text('Structured result unavailable'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Structured result unavailable: invalid data'),
      findsOneWidget,
    );
    expect(find.byType(OutlinedButton), findsNothing);
    expect(find.text('Save to local memory'), findsNothing);
    semantics.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets('action exposes receipt and in-flight semantics without retrying',
      (tester) async {
    final completion = Completer<void>();
    var calls = 0;
    final document = _actionDocument();
    final semantics = tester.ensureSemantics();

    await _pumpCard(
      tester,
      document: document,
      onAction: (_) {
        calls++;
        return completion.future;
      },
    );

    final action = find.widgetWithText(OutlinedButton, 'Save to local memory');
    expect(action, findsOneWidget);
    expect(tester.widget<OutlinedButton>(action).onPressed, isNotNull);
    await tester.tap(action);
    await tester.pump();

    expect(calls, 1);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Action in progress'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(action).onPressed, isNull);
    expect(
      find.bySemanticsLabel(
        'Save to local memory. Action in progress.',
      ),
      findsOneWidget,
    );

    completion.complete();
    await tester.pump();
    expect(tester.widget<OutlinedButton>(action).onPressed, isNotNull);

    await _pumpCard(
      tester,
      document: document,
      receipts: [_savedReceipt(document.resultId)],
    );

    expect(find.text('Action receipt saved'), findsOneWidget);
    expect(find.text('Saved to local memory.'), findsOneWidget);
    expect(find.text('Action handling is unavailable in this session.'),
        findsOneWidget);
    expect(tester.widget<OutlinedButton>(action).onPressed, isNull);
    expect(
      find.bySemanticsLabel(
        'Save to local memory. Action receipt saved. Saved to local memory. '
        'Action handling is unavailable in this session',
      ),
      findsOneWidget,
    );
    semantics.dispose();
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpCard(
  WidgetTester tester, {
  required StructuredResultDocument document,
  bool isInvalid = false,
  List<StructuredActionReceipt> receipts = const [],
  StructuredResultActionHandler? onAction,
  Size size = const Size(480, 800),
  double textScale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(useMaterial3: true),
      builder: (context, child) => MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          child: StructuredResultCard(
            document: document,
            isInvalid: isInvalid,
            receipts: receipts,
            onAction: onAction,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

StructuredResultDocument _fourBlockDocument() => const StructuredResultDocument(
      schemaVersion: 1,
      resultId: '00000000-0000-4000-8000-000000000001',
      blocks: [
        StructuredNoticeBlock(
          level: StructuredNoticeLevel.info,
          text: 'Imported safely',
        ),
        StructuredKeyValueBlock(
          items: [
            StructuredKeyValueItem(
              key: 'Skill',
              value: 'Weather tools remain local and require consent.',
            ),
          ],
        ),
        StructuredItemListBlock(
          title: 'Checks',
          items: ['Manifest v1'],
        ),
        StructuredActionListBlock(
          actions: [
            StructuredResultAction(
              actionId: 'save-1',
              label: 'Save to local memory',
              kind: 'save_to_memory',
              payload: {'fact': 'Only local, consented data may be saved.'},
            ),
          ],
        ),
      ],
    );

StructuredResultDocument _actionDocument() => const StructuredResultDocument(
      schemaVersion: 1,
      resultId: '00000000-0000-4000-8000-000000000002',
      blocks: [
        StructuredActionListBlock(
          actions: [
            StructuredResultAction(
              actionId: 'save-1',
              label: 'Save to local memory',
              kind: 'save_to_memory',
              payload: {'fact': 'Only local, consented data may be saved.'},
            ),
          ],
        ),
      ],
    );

StructuredActionReceipt _savedReceipt(String resultId) =>
    StructuredActionReceipt(
      schemaVersion: 1,
      receiptId: '00000000-0000-4000-8000-000000000003',
      operationId: '00000000-0000-4000-8000-000000000004',
      sourceKind: 'structured_result',
      resultId: resultId,
      actionId: 'save-1',
      actionKind: 'save_to_memory',
      toolName: 'memory_write',
      canonicalInputDigest:
          '0000000000000000000000000000000000000000000000000000000000000000',
      createdAt: DateTime.utc(2026, 7, 15),
      updatedAt: DateTime.utc(2026, 7, 15, 0, 0, 1),
      hardDeny: 'allowed',
      skillDeny: 'allowed',
      approval: 'approved',
      state: 'resultPersisted',
      outcome: 'success',
      outcomeKnown: true,
      safeSummary: 'Saved to local memory.',
    );
