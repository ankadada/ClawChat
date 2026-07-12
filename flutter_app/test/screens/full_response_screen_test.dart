import 'dart:ui';

import 'package:clawchat/screens/full_response_screen.dart';
import 'package:clawchat/widgets/streaming_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('preserves markdown surface and bounded literal search',
      (tester) async {
    const text = '# Heading\n\n```dart\nfinal value = 1;\n```\nneedle needle';
    await tester.pumpWidget(const MaterialApp(
      home: FullResponseScreen(text: text, allowShare: false),
    ));

    expect(find.text('完整回复'), findsOneWidget);
    expect(find.byType(StreamingText), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('full-response-search')),
      'needle',
    );
    await tester.pump();
    expect(find.text('1/2'), findsOneWidget);
  });

  testWidgets('search query survives orientation sized rebuild',
      (tester) async {
    tester.view.physicalSize = const Size(640, 1000);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(
      home: FullResponseScreen(text: 'stable query target', allowShare: false),
    ));
    await tester.enterText(
      find.byKey(const ValueKey('full-response-search')),
      'stable',
    );
    tester.view.physicalSize = const Size(1000, 640);
    await tester.pump();
    expect(find.text('stable'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('320dp at 200 percent text keeps search actions reachable',
      (tester) async {
    tester.view.physicalSize = const Size(640, 1400);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(2)),
        child: FullResponseScreen(text: 'target', allowShare: false),
      ),
    ));
    expect(find.byTooltip('下一个匹配'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final hingeWidth in [20.0, 0.0]) {
    testWidgets('book hinge width $hingeWidth keeps workspace unobstructed',
        (tester) async {
      const size = Size(800, 600);
      final hinge = Rect.fromLTWH(400, 0, hingeWidth, 600);
      await _pumpFoldable(
        tester,
        size: size,
        features: [
          DisplayFeature(
            bounds: hinge,
            type: hingeWidth == 0
                ? DisplayFeatureType.fold
                : DisplayFeatureType.hinge,
            state: hingeWidth == 0
                ? DisplayFeatureState.postureHalfOpened
                : DisplayFeatureState.postureFlat,
          ),
        ],
      );

      final minimumLeft = hinge.right;
      for (final finder in [
        find.byType(AppBar),
        find.byKey(const ValueKey('full-response-search')),
        find.byTooltip('复制完整回复'),
        find.byTooltip('分享完整回复'),
        find.byKey(const ValueKey('full-response-body')),
      ]) {
        final rect = tester.getRect(finder);
        expect(rect.left, greaterThanOrEqualTo(minimumLeft));
        expect(rect.right, lessThanOrEqualTo(size.width));
        expect(rect.overlaps(hinge), isFalse);
      }
    });
  }

  for (final foldHeight in [20.0, 0.0]) {
    testWidgets('tabletop fold height $foldHeight keeps sticky controls usable',
        (tester) async {
      const size = Size(600, 800);
      final fold = Rect.fromLTWH(0, 300, 600, foldHeight);
      await _pumpFoldable(
        tester,
        size: size,
        features: [
          DisplayFeature(
            bounds: fold,
            type: DisplayFeatureType.fold,
            state: DisplayFeatureState.postureHalfOpened,
          ),
        ],
      );

      for (final finder in [
        find.byType(AppBar),
        find.byKey(const ValueKey('full-response-search')),
        find.byTooltip('复制完整回复'),
        find.byTooltip('分享完整回复'),
        find.byKey(const ValueKey('full-response-body')),
      ]) {
        final rect = tester.getRect(finder);
        expect(rect.top, greaterThanOrEqualTo(fold.bottom));
        expect(rect.overlaps(fold), isFalse);
      }

      await _pumpFoldable(
        tester,
        size: size,
        features: [
          DisplayFeature(
            bounds: fold,
            type: DisplayFeatureType.fold,
            state: DisplayFeatureState.postureHalfOpened,
          ),
        ],
        bottomInset: 360,
      );
      expect(
        tester
            .getRect(find.byKey(const ValueKey('full-response-workspace')))
            .bottom,
        lessThanOrEqualTo(fold.top),
      );
    });
  }

  testWidgets('fold transition retains query match and scroll controller',
      (tester) async {
    final text = '${List.filled(120, 'line').join('\n')}\ntarget target';
    await _pumpFoldable(tester, size: const Size(800, 600), text: text);
    await tester.enterText(
      find.byKey(const ValueKey('full-response-search')),
      'target',
    );
    await tester.pump();
    await tester.tap(find.byTooltip('下一个匹配'));
    await tester.drag(
      find.byKey(const PageStorageKey('full-response-scroll')),
      const Offset(0, -240),
    );
    await tester.pumpAndSettle();
    final renderStateBefore = tester.state<FullResponseRenderSurfaceState>(
      find.byType(FullResponseRenderSurface),
    );
    final before = tester
        .state<ScrollableState>(find.descendant(
          of: find.byKey(const PageStorageKey('full-response-scroll')),
          matching: find.byType(Scrollable),
        ))
        .position
        .pixels;

    await _pumpFoldable(
      tester,
      size: const Size(800, 600),
      text: text,
      features: const [
        DisplayFeature(
          bounds: Rect.fromLTWH(400, 0, 0, 600),
          type: DisplayFeatureType.fold,
          state: DisplayFeatureState.postureHalfOpened,
        ),
      ],
    );

    expect(find.text('target'), findsOneWidget);
    expect(find.text('2/2'), findsOneWidget);
    expect(find.byType(StreamingText), findsOneWidget);
    expect(
      tester.state<FullResponseRenderSurfaceState>(
        find.byType(FullResponseRenderSurface),
      ),
      same(renderStateBefore),
    );
    final after = tester
        .state<ScrollableState>(find.descendant(
          of: find.byKey(const PageStorageKey('full-response-scroll')),
          matching: find.byType(Scrollable),
        ))
        .position
        .pixels;
    expect(after, greaterThan(0));
    expect(after, closeTo(before, 2));
  });
}

Future<void> _pumpFoldable(
  WidgetTester tester, {
  required Size size,
  String text = '# Heading\n\nbody',
  List<DisplayFeature> features = const [],
  double bottomInset = 0,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(
        size: size,
        displayFeatures: features,
        viewInsets: EdgeInsets.only(bottom: bottomInset),
      ),
      child: FullResponseScreen(
        key: const ValueKey('persistent-full-response'),
        text: text,
        allowShare: true,
      ),
    ),
  ));
  await tester.pumpAndSettle();
}
