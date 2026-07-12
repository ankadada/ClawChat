import 'dart:ui';

import 'package:clawchat/app.dart';
import 'package:clawchat/layout/foldable_layout.dart';
import 'package:flutter/widgets.dart' show TextScaler;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('app text preference composes with platform scaling', () {
    final scaler = composeAppTextScaler(
      const TextScaler.linear(1.5),
      1.2,
    );

    expect(scaler.scale(10), closeTo(18, 0.001));
  });

  test('vertical hinge produces two unobstructed book panes', () {
    final layout = FoldableLayout.resolve(
      const Size(800, 600),
      const [
        DisplayFeature(
          bounds: Rect.fromLTWH(390, 0, 20, 600),
          type: DisplayFeatureType.hinge,
          state: DisplayFeatureState.postureFlat,
        ),
      ],
    );

    expect(layout.posture, FoldablePosture.book);
    expect(layout.auxiliary, const Rect.fromLTWH(0, 0, 390, 600));
    expect(layout.primary, const Rect.fromLTWH(410, 0, 390, 600));
    expect(layout.primary.overlaps(layout.occlusion!), isFalse);
    expect(layout.auxiliary!.overlaps(layout.occlusion!), isFalse);
  });

  test('horizontal half-open fold chooses usable lower chat region', () {
    final layout = FoldableLayout.resolve(
      const Size(600, 800),
      const [
        DisplayFeature(
          bounds: Rect.fromLTWH(0, 300, 600, 20),
          type: DisplayFeatureType.fold,
          state: DisplayFeatureState.postureHalfOpened,
        ),
      ],
    );

    expect(layout.posture, FoldablePosture.tabletop);
    expect(layout.primary.top, 320);
    expect(layout.auxiliary!.bottom, 300);
  });

  test('zero-thickness fold line still separates posture regions', () {
    final layout = FoldableLayout.resolve(
      const Size(800, 600),
      const [
        DisplayFeature(
          bounds: Rect.fromLTWH(400, 0, 0, 600),
          type: DisplayFeatureType.fold,
          state: DisplayFeatureState.postureHalfOpened,
        ),
      ],
    );

    expect(layout.posture, FoldablePosture.book);
    expect(layout.auxiliary!.right, 400);
    expect(layout.primary.left, 400);
  });

  test('IME can move tabletop primary chat to unobstructed upper region', () {
    final layout = FoldableLayout.resolve(
      const Size(600, 800),
      const [
        DisplayFeature(
          bounds: Rect.fromLTWH(0, 300, 600, 20),
          type: DisplayFeatureType.fold,
          state: DisplayFeatureState.postureHalfOpened,
        ),
      ],
      bottomInset: 360,
    );

    expect(layout.primary, const Rect.fromLTWH(0, 0, 600, 300));
    expect(layout.primary.overlaps(layout.occlusion!), isFalse);
  });

  test('flat resize returns one region without artificial obstruction', () {
    final compact = FoldableLayout.resolve(const Size(320, 700), const []);
    final wide = FoldableLayout.resolve(const Size(900, 700), const []);

    expect(compact.posture, FoldablePosture.flat);
    expect(compact.primary.size, const Size(320, 700));
    expect(wide.primary.size, const Size(900, 700));
  });
}
