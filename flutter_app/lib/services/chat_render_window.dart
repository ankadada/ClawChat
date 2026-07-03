import 'dart:math' as math;

class ChatRenderWindow {
  final int startIndex;
  final int endIndexExclusive;
  final int hiddenBeforeCount;

  const ChatRenderWindow({
    required this.startIndex,
    required this.endIndexExclusive,
    required this.hiddenBeforeCount,
  });

  int get visibleCount => endIndexExclusive - startIndex;
  bool get hasHiddenBefore => hiddenBeforeCount > 0;

  factory ChatRenderWindow.forMessageCount({
    required int totalCount,
    required int visibleLimit,
  }) {
    final safeTotal = totalCount < 0 ? 0 : totalCount;
    final safeLimit = visibleLimit <= 0 ? safeTotal : visibleLimit;
    final start = safeTotal <= safeLimit ? 0 : safeTotal - safeLimit;
    return ChatRenderWindow(
      startIndex: start,
      endIndexExclusive: safeTotal,
      hiddenBeforeCount: start,
    );
  }
}

class ChatRenderWindowState {
  final int visibleLimit;

  const ChatRenderWindowState({
    required this.visibleLimit,
  });

  factory ChatRenderWindowState.initial(int initialWindow) {
    return ChatRenderWindowState(visibleLimit: initialWindow);
  }

  ChatRenderWindowState reset(int initialWindow) {
    return ChatRenderWindowState.initial(initialWindow);
  }

  ChatRenderWindowState loadOlder({
    required int totalCount,
    required int increment,
  }) {
    return ChatRenderWindowState(
      visibleLimit: math.min(
        math.max(0, totalCount),
        visibleLimit + math.max(0, increment),
      ),
    );
  }

  ChatRenderWindowState ensureIncludes({
    required int totalCount,
    required int messageIndex,
  }) {
    if (totalCount <= 0) return this;
    final safeIndex = messageIndex.clamp(0, totalCount - 1).toInt();
    final requiredLimit = totalCount - safeIndex;
    if (requiredLimit <= visibleLimit) return this;
    return ChatRenderWindowState(
      visibleLimit: math.min(totalCount, requiredLimit),
    );
  }

  ChatRenderWindow windowFor(int totalCount) {
    return ChatRenderWindow.forMessageCount(
      totalCount: totalCount,
      visibleLimit: visibleLimit,
    );
  }
}

int originalMessageIndexForVisibleIndex({
  required int windowStartIndex,
  required int visibleIndex,
}) {
  return windowStartIndex + visibleIndex;
}

double? compensatedScrollOffsetAfterPrepend({
  required double previousMaxScrollExtent,
  required double previousOffset,
  required double currentMinScrollExtent,
  required double currentMaxScrollExtent,
}) {
  final delta = currentMaxScrollExtent - previousMaxScrollExtent;
  if (delta <= 0) return null;
  return (previousOffset + delta)
      .clamp(currentMinScrollExtent, currentMaxScrollExtent)
      .toDouble();
}

double estimatedReversedListOffsetForMessageIndex({
  required ChatRenderWindow window,
  required int messageIndex,
  required double maxScrollExtent,
}) {
  if (maxScrollExtent <= 0 || window.visibleCount <= 1) return 0;
  final clampedIndex = messageIndex
      .clamp(window.startIndex, window.endIndexExclusive - 1)
      .toInt();
  final newestVisibleIndex = window.endIndexExclusive - 1;
  final distanceFromNewest = newestVisibleIndex - clampedIndex;
  final fraction = distanceFromNewest / (window.visibleCount - 1);
  return (maxScrollExtent * fraction).clamp(0, maxScrollExtent).toDouble();
}
