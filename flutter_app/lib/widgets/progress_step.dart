import 'package:flutter/material.dart';
import '../app.dart';

class ProgressStep extends StatelessWidget {
  final int stepNumber;
  final String label;
  final bool isActive;
  final bool isComplete;
  final bool hasError;
  final double? progress;

  const ProgressStep({
    super.key,
    required this.stepNumber,
    required this.label,
    this.isActive = false,
    this.isComplete = false,
    this.hasError = false,
    this.progress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Color stateColor;
    Color backgroundColor;
    Color borderColor;
    Widget circleChild;

    if (hasError) {
      stateColor = theme.colorScheme.error;
      backgroundColor = theme.colorScheme.errorContainer.withAlpha(90);
      borderColor = theme.colorScheme.error.withAlpha(150);
      circleChild = const Icon(Icons.close, color: Colors.white, size: 16);
    } else if (isComplete) {
      stateColor = AppColors.statusGreen;
      backgroundColor = AppColors.statusGreen.withAlpha(24);
      borderColor = AppColors.statusGreen.withAlpha(120);
      circleChild = const Icon(Icons.check, color: Colors.white, size: 16);
    } else if (isActive) {
      stateColor = theme.colorScheme.primary;
      backgroundColor = theme.colorScheme.primaryContainer.withAlpha(75);
      borderColor = theme.colorScheme.primary.withAlpha(140);
      // Use indeterminate (spinning) when progress is 0 so the UI doesn't
      // appear frozen during long-running steps (#83).
      final effectiveProgress = (progress != null && progress! > 0.0) ? progress : null;
      circleChild = SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: Colors.white,
          value: effectiveProgress,
        ),
      );
    } else {
      stateColor = theme.colorScheme.outline;
      backgroundColor = theme.colorScheme.surfaceContainerHighest.withAlpha(80);
      borderColor = theme.colorScheme.outline.withAlpha(45);
      circleChild = Text(
        '$stepNumber',
        style: TextStyle(
          color: theme.colorScheme.onSurfaceVariant,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(AppRadii.m),
          border: Border.all(color: borderColor),
        ),
        child: Row(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              width: isActive ? 36 : 32,
              height: isActive ? 36 : 32,
              decoration: BoxDecoration(
                color: stateColor,
                shape: BoxShape.circle,
                boxShadow: isActive
                    ? [
                        BoxShadow(
                          color: stateColor.withAlpha(55),
                          blurRadius: 16,
                          spreadRadius: 1,
                        ),
                      ]
                    : null,
              ),
              alignment: Alignment.center,
              child: circleChild,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: isActive || isComplete
                          ? FontWeight.w700
                          : FontWeight.w500,
                      color: isActive
                          ? theme.colorScheme.onSurface
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (isActive && progress != null) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: LinearProgressIndicator(
                        // Show indeterminate animation when progress is 0 (#83)
                        value: progress! > 0.0 ? progress : null,
                        minHeight: 5,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    if (progress! > 0.0)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '${(progress! * 100).toInt()}%',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              isComplete
                  ? Icons.done_all
                  : isActive
                      ? Icons.more_horiz
                      : Icons.circle_outlined,
              size: 18,
              color: stateColor,
            ),
          ],
        ),
      ),
    );
  }
}
