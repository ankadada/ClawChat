import 'package:clawchat/services/stream_flush_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('batches token deltas until max delay', () async {
    final scheduler = StreamFlushScheduler(
      maxDelay: const Duration(milliseconds: 30),
    );
    addTearDown(scheduler.cancel);
    var flushes = 0;

    scheduler.schedule(delta: 'a', flush: () => flushes++);
    scheduler.schedule(delta: 'b', flush: () => flushes++);

    expect(flushes, 0);
    await Future<void>.delayed(const Duration(milliseconds: 15));
    expect(flushes, 0);

    await Future<void>.delayed(const Duration(milliseconds: 25));
    expect(flushes, 1);
    expect(scheduler.isScheduled, isFalse);
  });

  test('flushes newline deltas immediately', () async {
    final scheduler = StreamFlushScheduler(
      maxDelay: const Duration(milliseconds: 30),
    );
    addTearDown(scheduler.cancel);
    var flushes = 0;

    scheduler.schedule(delta: 'partial', flush: () => flushes++);
    scheduler.schedule(delta: '\n', flush: () => flushes++);

    expect(flushes, 1);
    expect(scheduler.isScheduled, isFalse);

    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(flushes, 1);
  });

  test('can batch newline-heavy reasoning deltas', () async {
    final scheduler = StreamFlushScheduler(
      maxDelay: const Duration(milliseconds: 30),
    );
    addTearDown(scheduler.cancel);
    var flushes = 0;

    scheduler.schedule(
      delta: 'line one\n',
      flushOnBoundary: false,
      flush: () => flushes++,
    );
    scheduler.schedule(
      delta: 'line two\n',
      flushOnBoundary: false,
      flush: () => flushes++,
    );

    expect(flushes, 0);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(flushes, 1);
  });
}
