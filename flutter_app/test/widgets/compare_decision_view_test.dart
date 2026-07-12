import 'dart:ui';

import 'package:clawchat/layout/foldable_layout.dart';
import 'package:clawchat/providers/chat_provider.dart';
import 'package:clawchat/widgets/compare_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('labels position and exposes explicit use action',
      (tester) async {
    int? selected;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          child: CompareView(
            results: const [
              CompareResult.complete(
                model: 'model-a',
                text: 'answer-a',
                tokens: 10,
              ),
              CompareResult.complete(model: 'model-b', text: 'answer-b'),
            ],
            onUse: (index) => selected = index,
          ),
        ),
      ),
    ));

    expect(find.textContaining('1/2'), findsOneWidget);
    expect(find.text('用于对话'), findsOneWidget);
    await tester.tap(find.text('用于对话'));
    expect(selected, 0);
  });

  testWidgets('failed and loading results act independently', (tester) async {
    String? cancelled;
    String? retried;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          child: CompareView(
            results: const [
              CompareResult.loading(model: 'model-a'),
              CompareResult.error(
                model: 'model-b',
                errorCode: 'provider_failure',
              ),
            ],
            onCancel: (model) => cancelled = model,
            onRetry: (model) => retried = model,
          ),
        ),
      ),
    ));
    await tester.tap(find.text('仅取消此结果'));
    expect(cancelled, 'model-a');
    await tester.drag(find.byType(PageView), const Offset(-500, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('仅重试此结果'));
    expect(retried, 'model-b');
  });

  testWidgets('compact 200 percent text remains usable', (tester) async {
    tester.view.physicalSize = const Size(640, 1400);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(2)),
        child: Scaffold(
          body: CompareView(
            results: [CompareResult.complete(model: 'model-a', text: 'answer')],
          ),
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(find.text('model-a'), findsOneWidget);
  });

  testWidgets('book and tabletop panes avoid folds without action dispatch',
      (tester) async {
    var selectedCount = 0;
    const results = [
      CompareResult.complete(model: 'model-a', text: 'answer-a'),
      CompareResult.complete(model: 'model-b', text: 'answer-b'),
    ];
    for (final feature in const [
      DisplayFeature(
        bounds: Rect.fromLTWH(400, 0, 20, 600),
        type: DisplayFeatureType.hinge,
        state: DisplayFeatureState.postureFlat,
      ),
      DisplayFeature(
        bounds: Rect.fromLTWH(400, 0, 0, 600),
        type: DisplayFeatureType.fold,
        state: DisplayFeatureState.postureHalfOpened,
      ),
      DisplayFeature(
        bounds: Rect.fromLTWH(0, 300, 600, 20),
        type: DisplayFeatureType.fold,
        state: DisplayFeatureState.postureHalfOpened,
      ),
      DisplayFeature(
        bounds: Rect.fromLTWH(0, 300, 600, 0),
        type: DisplayFeatureType.fold,
        state: DisplayFeatureState.postureHalfOpened,
      ),
    ]) {
      final size = feature.bounds.width >= 700
          ? const Size(800, 600)
          : feature.bounds.height >= 500
              ? const Size(800, 600)
              : const Size(600, 800);
      await _pumpFoldedCompare(
        tester,
        size: size,
        feature: feature,
        results: results,
        onUse: (_) => selectedCount++,
      );
      final layout = FoldableLayout.resolve(size, [feature]);
      final compareRect = tester.getRect(find.byType(CompareView));
      expect(compareRect.left, greaterThanOrEqualTo(layout.primary.left));
      expect(compareRect.top, greaterThanOrEqualTo(layout.primary.top));
      expect(compareRect.right, lessThanOrEqualTo(layout.primary.right));
      expect(compareRect.bottom, lessThanOrEqualTo(layout.primary.bottom));
      expect(compareRect.overlaps(layout.occlusion!), isFalse);
      expect(tester.takeException(), isNull);
    }
    expect(selectedCount, 0);
  });

  testWidgets('page selection survives compact grid fold transitions',
      (tester) async {
    int? selected;
    const results = [
      CompareResult.complete(model: 'model-a', text: 'answer-a'),
      CompareResult.complete(model: 'model-b', text: 'answer-b'),
    ];
    await _pumpFlatCompare(
      tester,
      size: const Size(400, 650),
      results: results,
      onUse: (index) => selected = index,
    );
    await tester.drag(find.byType(PageView), const Offset(-380, 0));
    await tester.pumpAndSettle();

    await _pumpFlatCompare(
      tester,
      size: const Size(900, 650),
      results: results,
      onUse: (index) => selected = index,
    );
    expect(find.byType(GridView), findsOneWidget);
    expect(selected, isNull);

    await _pumpFoldedCompare(
      tester,
      size: const Size(800, 600),
      feature: const DisplayFeature(
        bounds: Rect.fromLTWH(400, 0, 0, 600),
        type: DisplayFeatureType.fold,
        state: DisplayFeatureState.postureHalfOpened,
      ),
      results: results,
      onUse: (index) => selected = index,
    );
    await tester.tap(find.text('用于对话').last);
    expect(selected, 1);
  });
}

Future<void> _pumpFlatCompare(
  WidgetTester tester, {
  required Size size,
  required List<CompareResult> results,
  required ValueChanged<int> onUse,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Stack(children: [
        Positioned.fromRect(
          rect: Offset.zero & size,
          child: CompareView(
            key: const ValueKey('posture-compare'),
            results: results,
            maxPanelHeight: size.height - 180,
            onUse: onUse,
          ),
        ),
      ]),
    ),
  ));
  await tester.pumpAndSettle();
}

Future<void> _pumpFoldedCompare(
  WidgetTester tester, {
  required Size size,
  required DisplayFeature feature,
  required List<CompareResult> results,
  required ValueChanged<int> onUse,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final layout = FoldableLayout.resolve(size, [feature]);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Stack(children: [
        Positioned.fromRect(
          rect: layout.primary,
          child: CompareView(
            key: const ValueKey('posture-compare'),
            results: results,
            maxPanelHeight: (layout.primary.height - 180).clamp(120, 500),
            onUse: onUse,
          ),
        ),
      ]),
    ),
  ));
  await tester.pumpAndSettle();
}
