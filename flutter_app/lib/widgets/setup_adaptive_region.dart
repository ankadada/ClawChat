import 'package:flutter/material.dart';

import '../layout/foldable_layout.dart';

@visibleForTesting
Rect setupRegionForLayout(FoldableLayout layout) {
  final primary = layout.primary;
  if (primary.width > 0 && primary.height > 0) return primary;
  return layout.auxiliary ?? primary;
}

/// Projects setup content into the same unobstructed region model used by the
/// app shell. Setup keeps the shared primary-region choice stable and only
/// falls back when that region has no usable area.
class SetupAdaptiveRegion extends StatelessWidget {
  const SetupAdaptiveRegion({
    super.key,
    required this.child,
    this.maxContentWidth = 720,
  });

  final Widget child;
  final double maxContentWidth;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final layout = FoldableLayout.resolve(
          size,
          media.displayFeatures,
          bottomInset: media.viewInsets.bottom,
        );
        final region = setupRegionForLayout(layout);
        return Stack(
          children: [
            Positioned.fromRect(
              rect: region,
              child: SafeArea(
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxContentWidth),
                    child: child,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
