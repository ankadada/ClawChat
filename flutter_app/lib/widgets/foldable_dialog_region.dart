import 'package:flutter/material.dart';

import '../layout/foldable_layout.dart';

class FoldableDialogRegion extends StatelessWidget {
  const FoldableDialogRegion({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = FoldableLayout.resolve(
          Size(constraints.maxWidth, constraints.maxHeight),
          media.displayFeatures,
          bottomInset: media.viewInsets.bottom,
        );
        return Stack(
          children: [
            Positioned.fromRect(
              rect: layout.primary,
              child: SafeArea(child: Center(child: child)),
            ),
          ],
        );
      },
    );
  }
}
