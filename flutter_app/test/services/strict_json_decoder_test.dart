import 'dart:convert';

import 'package:clawchat/services/strict_json_decoder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('StrictJsonDecoder', () {
    test('decodes valid nested JSON without changing object order semantics',
        () {
      final value = const StrictJsonDecoder().decodeString(
        '{"root":{"items":[true,null,"ok",12.5]}}',
      );

      expect(value, {
        'root': {
          'items': [true, null, 'ok', 12.5],
        },
      });
    });

    test('rejects duplicate object keys at every nesting depth', () {
      const decoder = StrictJsonDecoder();
      for (final input in [
        '{"key":1,"key":2}',
        '{"outer":{"key":1,"key":2}}',
        '{"items":[{"key":1,"key":2}]}',
        '{"a":1,"\\u0061":2}',
      ]) {
        expect(_errorCode(() => decoder.decodeString(input)),
            StrictJsonErrorCode.duplicateKey);
      }
    });

    test('rejects malformed UTF-8 bytes without retaining payload text', () {
      const decoder = StrictJsonDecoder();
      final error = _error(() => decoder.decodeBytes([0xc3, 0x28]));

      expect(error.code, StrictJsonErrorCode.invalidUtf8);
      expect(error.toString(), isNot(contains('secret')));
      expect(
        _errorCode(() => decoder.decodeBytes([256])),
        StrictJsonErrorCode.invalidUtf8,
      );
    });

    test('rejects a UTF-8 byte order mark before decoding JSON', () {
      const decoder = StrictJsonDecoder();

      expect(
        _errorCode(
          () => decoder.decodeBytes([0xef, 0xbb, 0xbf, 0x7b, 0x7d]),
        ),
        StrictJsonErrorCode.byteOrderMark,
      );
    });

    test('rejects invalid Unicode in Dart strings and JSON escapes', () {
      const decoder = StrictJsonDecoder();
      expect(
        _errorCode(() => decoder.decodeString(String.fromCharCode(0xd800))),
        StrictJsonErrorCode.invalidUnicode,
      );
      expect(
        _errorCode(() => decoder.decodeString('"\\uD800"')),
        StrictJsonErrorCode.invalidUnicode,
      );
      expect(
        _errorCode(() => decoder.decodeString('"\\uDC00"')),
        StrictJsonErrorCode.invalidUnicode,
      );
      expect(
        decoder.decodeString('"\\uD83D\\uDE00"'),
        '😀',
      );
    });

    test('rejects oversized byte and String input', () {
      const decoder = StrictJsonDecoder(maxUtf8Bytes: 4);
      expect(
        _errorCode(() => decoder.decodeBytes(utf8.encode('{"a":1}'))),
        StrictJsonErrorCode.inputTooLarge,
      );
      expect(
        _errorCode(() => decoder.decodeString('"界界"')),
        StrictJsonErrorCode.inputTooLarge,
      );
    });

    test('rejects trailing data, malformed non-finite numbers, and bad syntax',
        () {
      const decoder = StrictJsonDecoder();
      expect(
        _errorCode(() => decoder.decodeString('{"ok":true} trailing')),
        StrictJsonErrorCode.trailingData,
      );
      expect(
        _errorCode(() => decoder.decodeString('1e309')),
        StrictJsonErrorCode.nonFiniteNumber,
      );
      expect(
        _errorCode(() => decoder.decodeString('NaN')),
        StrictJsonErrorCode.invalidSyntax,
      );
      expect(
        _errorCode(
          () => decoder.decodeString(List.filled(10000, '9').join()),
        ),
        StrictJsonErrorCode.nonFiniteNumber,
      );
    });

    test('applies the nesting limit to empty containers', () {
      const decoder = StrictJsonDecoder(maxNestingDepth: 1);

      expect(decoder.decodeString('{}'), isEmpty);
      expect(decoder.decodeString('[]'), isEmpty);
      expect(
        _errorCode(() => decoder.decodeString('{"nested":{}}')),
        StrictJsonErrorCode.nestingTooDeep,
      );
      expect(
        _errorCode(() => decoder.decodeString('[[]]')),
        StrictJsonErrorCode.nestingTooDeep,
      );
    });
  });
}

StrictJsonDecodeException _error(Object? Function() action) {
  try {
    action();
  } on StrictJsonDecodeException catch (error) {
    return error;
  }
  fail('Expected StrictJsonDecodeException');
}

StrictJsonErrorCode _errorCode(Object? Function() action) =>
    _error(action).code;
