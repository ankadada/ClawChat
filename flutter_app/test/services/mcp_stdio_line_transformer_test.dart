import 'dart:async';
import 'dart:convert';

import 'package:clawchat/services/mcp_stdio_line_transformer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const limit = 64;

  Future<List<String>> collect(
    List<List<int>> chunks, {
    int maxLineBytes = limit,
    String streamName = 'stdout',
  }) {
    return Stream<List<int>>.fromIterable(chunks)
        .transform(
          BoundedUtf8LineTransformer(
            maxLineBytes: maxLineBytes,
            streamName: streamName,
          ),
        )
        .toList();
  }

  Future<Object?> firstError(
    List<List<int>> chunks, {
    required int maxLineBytes,
  }) async {
    try {
      await Stream<List<int>>.fromIterable(chunks)
          .transform(BoundedUtf8LineTransformer(maxLineBytes: maxLineBytes))
          .toList();
      return null;
    } catch (error) {
      return error;
    }
  }

  group('BoundedUtf8LineTransformer', () {
    test('splits exactly like LineSplitter for the terminators MCP uses',
        () async {
      for (final input in [
        'a\nb',
        'a\n',
        'a\n\n',
        'a\r\nb',
        'a\rb',
        '\n',
        '',
        'a\r',
        '{"jsonrpc":"2.0","id":1}\n{"jsonrpc":"2.0","id":2}',
      ]) {
        final expected = const LineSplitter().convert(input);
        final actual = await collect([utf8.encode(input)]);
        expect(actual, expected, reason: jsonEncode(input));
      }
    });

    test('a terminator split across chunks matches the same bytes together',
        () async {
      final actual = await collect([
        utf8.encode('first\r'),
        utf8.encode('\nsecond\n'),
      ]);

      expect(actual, ['first', 'second']);
    });

    test('multi-byte characters split across chunks decode once', () async {
      final bytes = utf8.encode('中文行\n');
      final actual = await collect([
        bytes.sublist(0, 4),
        bytes.sublist(4),
      ]);

      expect(actual, ['中文行']);
    });

    test('a long line without any newline fails instead of buffering it',
        () async {
      // 4 MiB with no terminator: decoder + LineSplitter would hold all of it
      // before emitting anything, so the cap has to fail mid-line.
      final chunks = List<List<int>>.generate(
        4,
        (_) => List<int>.filled(1024 * 1024, 0x61),
      );

      final error = await firstError(chunks, maxLineBytes: 1024 * 1024);

      expect(error, isA<McpLineTooLongException>());
      final failure = error! as McpLineTooLongException;
      expect(failure.limitBytes, 1024 * 1024);
      expect(failure.streamName, 'stdout');
    });

    test('an unterminated over-limit tail fails even after whole lines',
        () async {
      final seen = <String>[];
      Object? failure;
      final done = Completer<void>();
      Stream<List<int>>.fromIterable([
        utf8.encode('ok\n'),
        utf8.encode('y' * (limit + 1)),
      ])
          .transform(const BoundedUtf8LineTransformer(maxLineBytes: limit))
          .listen(
            seen.add,
            onError: (Object error) => failure = error,
            onDone: () {
              if (!done.isCompleted) done.complete();
            },
          );

      await done.future;

      // The good line is delivered; the oversized one is refused whole, never
      // delivered as a truncated prefix.
      expect(seen, ['ok']);
      expect(failure, isA<McpLineTooLongException>());
    });

    test('the cap counts one line, not the whole stream', () async {
      final line = 'x' * 32;
      final actual = await collect([
        utf8.encode('$line\n$line\n$line\n'),
      ]);

      expect(actual, [line, line, line]);
    });

    test('an unterminated final line is emitted when the stream closes',
        () async {
      final actual = await collect([
        utf8.encode('{"id":1}'),
      ]);

      expect(actual, ['{"id":1}']);
    });

    test('a failure ignores everything that arrives after it', () async {
      final seen = <String>[];
      final failures = <Object>[];
      final done = Completer<void>();
      final controller = StreamController<List<int>>();

      controller.stream
          .transform(const BoundedUtf8LineTransformer(maxLineBytes: limit))
          .listen(
        seen.add,
        onError: failures.add,
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
      );

      controller.add(utf8.encode('z' * (limit + 1)));
      await done.future;
      controller.add(utf8.encode('after\n'));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(seen, isEmpty);
      expect(failures.single, isA<McpLineTooLongException>());
      await controller.close();
    });
  });
}
