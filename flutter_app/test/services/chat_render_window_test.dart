import 'package:clawchat/services/chat_render_window.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChatRenderWindow', () {
    test('renders all messages when count is within the limit', () {
      final window = ChatRenderWindow.forMessageCount(
        totalCount: 42,
        visibleLimit: 180,
      );

      expect(window.startIndex, 0);
      expect(window.endIndexExclusive, 42);
      expect(window.visibleCount, 42);
      expect(window.hiddenBeforeCount, 0);
      expect(window.hasHiddenBefore, isFalse);
    });

    test('keeps the latest bounded window and records hidden prefix', () {
      final window = ChatRenderWindow.forMessageCount(
        totalCount: 320,
        visibleLimit: 180,
      );

      expect(window.startIndex, 140);
      expect(window.endIndexExclusive, 320);
      expect(window.visibleCount, 180);
      expect(window.hiddenBeforeCount, 140);
      expect(window.hasHiddenBefore, isTrue);
    });

    test('non-positive limit falls back to all messages', () {
      final window = ChatRenderWindow.forMessageCount(
        totalCount: 12,
        visibleLimit: 0,
      );

      expect(window.startIndex, 0);
      expect(window.endIndexExclusive, 12);
      expect(window.visibleCount, 12);
      expect(window.hiddenBeforeCount, 0);
    });
  });

  group('ChatRenderWindowState', () {
    const initialWindow = 180;
    const loadOlderIncrement = 120;

    test('keeps latest initial window as a short session grows', () {
      final state = ChatRenderWindowState.initial(initialWindow);

      final shortSessionWindow = state.windowFor(179);
      expect(shortSessionWindow.startIndex, 0);
      expect(shortSessionWindow.visibleCount, 179);
      expect(shortSessionWindow.hiddenBeforeCount, 0);

      final crossedLimitWindow = state.windowFor(181);
      expect(crossedLimitWindow.startIndex, 1);
      expect(crossedLimitWindow.visibleCount, 180);
      expect(crossedLimitWindow.hiddenBeforeCount, 1);

      final longSessionWindow = state.windowFor(300);
      expect(longSessionWindow.startIndex, 120);
      expect(longSessionWindow.visibleCount, 180);
      expect(longSessionWindow.hiddenBeforeCount, 120);
    });

    test('load older increases the window by the configured increment', () {
      final state = ChatRenderWindowState.initial(initialWindow).loadOlder(
        totalCount: 500,
        increment: loadOlderIncrement,
      );

      expect(state.visibleLimit, 300);
      final window = state.windowFor(500);
      expect(window.startIndex, 200);
      expect(window.visibleCount, 300);
      expect(window.hiddenBeforeCount, 200);
    });

    test('load older is capped by the total message count', () {
      final state = ChatRenderWindowState.initial(initialWindow).loadOlder(
        totalCount: 250,
        increment: loadOlderIncrement,
      );

      expect(state.visibleLimit, 250);
      final window = state.windowFor(250);
      expect(window.startIndex, 0);
      expect(window.visibleCount, 250);
      expect(window.hiddenBeforeCount, 0);
    });

    test('appending after load older does not implicitly expand to all history',
        () {
      final state = ChatRenderWindowState.initial(initialWindow).loadOlder(
        totalCount: 500,
        increment: loadOlderIncrement,
      );

      final appendedWindow = state.windowFor(501);
      expect(state.visibleLimit, 300);
      expect(appendedWindow.startIndex, 201);
      expect(appendedWindow.visibleCount, 300);
      expect(appendedWindow.hiddenBeforeCount, 201);
    });
  });

  group('ChatScreen render window helpers', () {
    test('maps visible indexes back to original message indexes', () {
      expect(
        originalMessageIndexForVisibleIndex(
          windowStartIndex: 80,
          visibleIndex: 0,
        ),
        80,
      );
      expect(
        originalMessageIndexForVisibleIndex(
          windowStartIndex: 80,
          visibleIndex: 179,
        ),
        259,
      );
    });

    test('compensates scroll offset after older messages are prepended', () {
      final target = compensatedScrollOffsetAfterPrepend(
        previousMaxScrollExtent: 1000,
        previousOffset: 240,
        currentMinScrollExtent: 0,
        currentMaxScrollExtent: 1500,
      );

      expect(target, 740);
    });

    test('scroll compensation clamps and ignores non-growth frames', () {
      expect(
        compensatedScrollOffsetAfterPrepend(
          previousMaxScrollExtent: 1000,
          previousOffset: 900,
          currentMinScrollExtent: 0,
          currentMaxScrollExtent: 1200,
        ),
        1100,
      );
      expect(
        compensatedScrollOffsetAfterPrepend(
          previousMaxScrollExtent: 1000,
          previousOffset: 240,
          currentMinScrollExtent: 0,
          currentMaxScrollExtent: 1000,
        ),
        isNull,
      );
    });
  });
}
