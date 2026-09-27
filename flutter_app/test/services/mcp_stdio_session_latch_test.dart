import 'dart:convert';

import 'package:clawchat/services/mcp_stdio_session_latch.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('McpStdioSessionLatch', () {
    test('an event for an unknown key is dropped, not buffered', () {
      final latch = McpStdioSessionLatch();

      expect(
        latch.deliver(
          'run\u0000server',
          sessionToken: 'token-1',
          event: {'event': 'exit', 'exitCode': 0},
        ),
        isFalse,
      );
      expect(latch.bufferedCountFor('run\u0000server'), 0);
      expect(latch.expectedSessionCount, 0);
    });

    test('an expected session replays exit events that arrived first', () {
      final latch = McpStdioSessionLatch();
      const key = 'run\u0000server';
      latch.expect(key);

      latch.deliver(
        key,
        sessionToken: 'token-1',
        event: {'event': 'line', 'line': '{"id":1}'},
      );
      latch.deliver(
        key,
        sessionToken: 'token-1',
        event: {'event': 'exit', 'exitCode': 1},
      );
      expect(latch.bufferedCountFor(key), 2);
      expect(latch.isBound(key), isFalse);

      final seen = <Map<String, dynamic>>[];
      latch.bind(key, sessionToken: 'token-1', handler: seen.add);

      // Arrival order is preserved: the client sees the answer before the exit.
      expect(seen.map((event) => event['event']), ['line', 'exit']);
      expect(seen.last['exitCode'], 1);
      expect(latch.bufferedCountFor(key), 0);
      expect(latch.isExpected(key), isFalse);
    });

    test('a bound session receives events directly', () {
      final latch = McpStdioSessionLatch();
      const key = 'run\u0000server';
      final seen = <Map<String, dynamic>>[];
      latch.bind(key, sessionToken: 'token-1', handler: seen.add);

      expect(
        latch.deliver(
          key,
          sessionToken: 'token-1',
          event: {'event': 'line', 'line': 'a'},
        ),
        isTrue,
      );
      expect(seen.single['line'], 'a');
      expect(latch.bufferedCountFor(key), 0);
    });

    test('a cancelled expectation stops buffering', () {
      final latch = McpStdioSessionLatch();
      const key = 'run\u0000server';
      latch.expect(key);
      latch.cancelExpectation(key);

      expect(
        latch.deliver(
          key,
          sessionToken: 'token-1',
          event: {'event': 'exit', 'exitCode': 0},
        ),
        isFalse,
      );
      expect(latch.bufferedCountFor(key), 0);
    });

    test('cancelExpectation leaves a bound session alone', () {
      final latch = McpStdioSessionLatch();
      const key = 'run\u0000server';
      final seen = <Map<String, dynamic>>[];
      latch.bind(key, sessionToken: 'token-1', handler: seen.add);
      latch.cancelExpectation(key);

      expect(
        latch.deliver(
          key,
          sessionToken: 'token-1',
          event: {'event': 'line', 'line': 'a'},
        ),
        isTrue,
      );
      expect(seen, hasLength(1));
    });

    test('forget drops the handler and any buffered events', () {
      final latch = McpStdioSessionLatch();
      const key = 'run\u0000server';
      latch.expect(key);
      latch.deliver(
        key,
        sessionToken: 'token-1',
        event: {'event': 'line', 'line': 'a'},
      );
      final seen = <Map<String, dynamic>>[];
      latch.bind(key, sessionToken: 'token-1', handler: seen.add);
      latch.forget(key);

      expect(
        latch.deliver(
          key,
          sessionToken: 'token-1',
          event: {'event': 'exit', 'exitCode': 0},
        ),
        isFalse,
      );
      expect(seen, hasLength(1));
    });

    test('the pending buffer stays bounded and keeps the terminal event', () {
      final latch = McpStdioSessionLatch(
        maxPendingEvents: 4,
        maxPendingTextChars: 16,
      );
      const key = 'run\u0000server';
      latch.expect(key);

      for (var index = 0; index < 20; index++) {
        latch.deliver(
          key,
          sessionToken: 'token-1',
          event: {'event': 'line', 'line': 'x' * 8},
        );
      }
      latch.deliver(
        key,
        sessionToken: 'token-1',
        event: {'event': 'exit', 'exitCode': 0},
      );

      final seen = <Map<String, dynamic>>[];
      latch.bind(key, sessionToken: 'token-1', handler: seen.add);

      expect(seen.length, lessThanOrEqualTo(5));
      expect(seen.last['event'], 'exit');
      expect(jsonEncode(seen).length, lessThan(200));
    });
  });

  test('events from a previous child of the same key are dropped', () {
    final latch = McpStdioSessionLatch();
    const key = 'run\u0000server';
    latch.expect(key);

    // The old child's exit and the new child's line both arrive while the
    // start is in flight.
    latch.deliver(
      key,
      sessionToken: 'token-old',
      event: {'event': 'exit', 'exitCode': 1},
    );
    latch.deliver(
      key,
      sessionToken: 'token-new',
      event: {'event': 'line', 'line': '{"id":2}'},
    );

    final seen = <Map<String, dynamic>>[];
    latch.bind(key, sessionToken: 'token-new', handler: seen.add);

    expect(seen, hasLength(1));
    expect(seen.single['line'], '{"id":2}');
  });

  test('a stale token is not delivered to the bound session', () {
    final latch = McpStdioSessionLatch();
    const key = 'run\u0000server';
    final seen = <Map<String, dynamic>>[];
    latch.bind(key, sessionToken: 'token-new', handler: seen.add);

    expect(
      latch.deliver(
        key,
        sessionToken: 'token-old',
        event: {'event': 'exit', 'exitCode': 0},
      ),
      isFalse,
    );
    expect(
      latch.deliver(
        key,
        sessionToken: 'token-new',
        event: {'event': 'line', 'line': 'a'},
      ),
      isTrue,
    );
    expect(seen, hasLength(1));
  });
}
