import 'dart:ui';

enum FoldablePosture { flat, book, tabletop }

final class FoldableLayout {
  const FoldableLayout({
    required this.posture,
    required this.primary,
    this.auxiliary,
    this.occlusion,
  });

  final FoldablePosture posture;
  final Rect primary;
  final Rect? auxiliary;
  final Rect? occlusion;

  bool get hasSeparatedRegions => auxiliary != null;

  static FoldableLayout resolve(
    Size size,
    List<DisplayFeature> features, {
    double bottomInset = 0,
  }) {
    final window = Offset.zero & size;
    DisplayFeature? separating;
    for (final feature in features) {
      final bounds = feature.bounds;
      final intersectsWindow = bounds.right >= 0 &&
          bounds.bottom >= 0 &&
          bounds.left <= size.width &&
          bounds.top <= size.height &&
          (bounds.width > 0 || bounds.height > 0);
      if (intersectsWindow &&
          (feature.type == DisplayFeatureType.hinge ||
              feature.state == DisplayFeatureState.postureHalfOpened)) {
        separating = feature;
        break;
      }
    }
    if (separating == null) {
      return FoldableLayout(posture: FoldablePosture.flat, primary: window);
    }
    final hinge = separating.bounds.intersect(window);
    if (hinge.height >= hinge.width) {
      return FoldableLayout(
        posture: FoldablePosture.book,
        auxiliary: Rect.fromLTRB(0, 0, hinge.left, size.height),
        primary: Rect.fromLTRB(hinge.right, 0, size.width, size.height),
        occlusion: hinge,
      );
    }
    final top = Rect.fromLTRB(0, 0, size.width, hinge.top);
    final bottom = Rect.fromLTRB(
      0,
      hinge.bottom,
      size.width,
      (size.height - bottomInset).clamp(hinge.bottom, size.height),
    );
    final bottomUsable = bottom.height;
    final primaryIsBottom =
        bottomUsable >= top.height * 0.72 && bottomUsable >= 240;
    return FoldableLayout(
      posture: FoldablePosture.tabletop,
      auxiliary: primaryIsBottom ? top : bottom,
      primary: primaryIsBottom ? bottom : top,
      occlusion: hinge,
    );
  }
}
