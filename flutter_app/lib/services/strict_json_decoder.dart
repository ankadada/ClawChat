import 'dart:convert';

/// Bounded reason codes for [StrictJsonDecodeException].
///
/// The decoder intentionally does not retain input text in its errors. Callers
/// can expose these codes in metadata-only diagnostics without logging the JSON
/// payload that failed to parse.
enum StrictJsonErrorCode {
  byteOrderMark,
  invalidUtf8,
  invalidUnicode,
  inputTooLarge,
  invalidSyntax,
  duplicateKey,
  trailingData,
  nonFiniteNumber,
  nestingTooDeep,
}

/// A strict JSON decoding failure with a stable, payload-free reason code.
final class StrictJsonDecodeException extends FormatException {
  StrictJsonDecodeException(this.code, [int? offset])
      : super('Strict JSON decode failed: ${code.reasonCode}', null, offset);

  final StrictJsonErrorCode code;

  String get reasonCode => code.reasonCode;

  @override
  String toString() => 'StrictJsonDecodeException($reasonCode)';
}

extension on StrictJsonErrorCode {
  String get reasonCode => switch (this) {
        StrictJsonErrorCode.byteOrderMark => 'byte_order_mark',
        StrictJsonErrorCode.invalidUtf8 => 'invalid_utf8',
        StrictJsonErrorCode.invalidUnicode => 'invalid_unicode',
        StrictJsonErrorCode.inputTooLarge => 'input_too_large',
        StrictJsonErrorCode.invalidSyntax => 'invalid_syntax',
        StrictJsonErrorCode.duplicateKey => 'duplicate_key',
        StrictJsonErrorCode.trailingData => 'trailing_data',
        StrictJsonErrorCode.nonFiniteNumber => 'non_finite_number',
        StrictJsonErrorCode.nestingTooDeep => 'nesting_too_deep',
      };
}

/// Strict JSON decoder for security-significant, UTF-8 JSON inputs.
///
/// Unlike [jsonDecode], this decoder retains enough parse state to reject
/// duplicate object keys at every nesting level. It also validates raw bytes as
/// UTF-8 before parsing and validates Dart strings for unpaired UTF-16
/// surrogates before they are encoded for size checking.
final class StrictJsonDecoder {
  const StrictJsonDecoder({
    this.maxUtf8Bytes = defaultMaxUtf8Bytes,
    this.maxNestingDepth = defaultMaxNestingDepth,
  })  : assert(maxUtf8Bytes > 0),
        assert(maxNestingDepth > 0);

  static const int defaultMaxUtf8Bytes = 1024 * 1024;
  static const int defaultMaxNestingDepth = 128;

  final int maxUtf8Bytes;
  final int maxNestingDepth;

  Object? decodeBytes(List<int> bytes) {
    if (bytes.length > maxUtf8Bytes) {
      throw StrictJsonDecodeException(StrictJsonErrorCode.inputTooLarge);
    }
    if (bytes.any((byte) => byte < 0 || byte > 0xff)) {
      throw StrictJsonDecodeException(StrictJsonErrorCode.invalidUtf8);
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xef &&
        bytes[1] == 0xbb &&
        bytes[2] == 0xbf) {
      throw StrictJsonDecodeException(StrictJsonErrorCode.byteOrderMark);
    }

    late final String source;
    try {
      source = utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      throw StrictJsonDecodeException(StrictJsonErrorCode.invalidUtf8);
    }
    return _decodeValidatedString(source, knownUtf8ByteLength: bytes.length);
  }

  Object? decodeString(String source) {
    _validateUnicodeScalars(source);
    final byteLength = utf8.encode(source).length;
    return _decodeValidatedString(source, knownUtf8ByteLength: byteLength);
  }

  Object? _decodeValidatedString(
    String source, {
    required int knownUtf8ByteLength,
  }) {
    if (knownUtf8ByteLength > maxUtf8Bytes) {
      throw StrictJsonDecodeException(StrictJsonErrorCode.inputTooLarge);
    }
    return _StrictJsonParser(source, maxNestingDepth).parse();
  }

  static void _validateUnicodeScalars(String value) {
    for (var index = 0; index < value.length; index += 1) {
      final codeUnit = value.codeUnitAt(index);
      if (_isHighSurrogate(codeUnit)) {
        if (index + 1 >= value.length ||
            !_isLowSurrogate(value.codeUnitAt(index + 1))) {
          throw StrictJsonDecodeException(
            StrictJsonErrorCode.invalidUnicode,
            index,
          );
        }
        index += 1;
      } else if (_isLowSurrogate(codeUnit)) {
        throw StrictJsonDecodeException(
          StrictJsonErrorCode.invalidUnicode,
          index,
        );
      }
    }
  }
}

final class _StrictJsonParser {
  _StrictJsonParser(this.source, this.maxNestingDepth);

  final String source;
  final int maxNestingDepth;
  var _offset = 0;

  Object? parse() {
    _skipWhitespace();
    if (_isAtEnd) _fail(StrictJsonErrorCode.invalidSyntax);
    final value = _parseValue(0);
    _skipWhitespace();
    if (!_isAtEnd) _fail(StrictJsonErrorCode.trailingData);
    return value;
  }

  Object? _parseValue(int depth) {
    if (depth > maxNestingDepth) {
      _fail(StrictJsonErrorCode.nestingTooDeep);
    }
    if (_isAtEnd) _fail(StrictJsonErrorCode.invalidSyntax);

    return switch (_peekCodeUnit()) {
      0x7b => _parseObject(depth + 1),
      0x5b => _parseArray(depth + 1),
      0x22 => _parseString(),
      0x74 => _parseLiteral('true', true),
      0x66 => _parseLiteral('false', false),
      0x6e => _parseLiteral('null', null),
      0x2d || >= 0x30 && <= 0x39 => _parseNumber(),
      _ => _fail(StrictJsonErrorCode.invalidSyntax),
    };
  }

  Map<String, Object?> _parseObject(int depth) {
    if (depth > maxNestingDepth) {
      _fail(StrictJsonErrorCode.nestingTooDeep);
    }
    _expectCodeUnit(0x7b);
    _skipWhitespace();
    final result = <String, Object?>{};
    final keys = <String>{};
    if (_tryConsumeCodeUnit(0x7d)) return result;

    while (true) {
      _skipWhitespace();
      if (_isAtEnd || _peekCodeUnit() != 0x22) {
        _fail(StrictJsonErrorCode.invalidSyntax);
      }
      final key = _parseString();
      if (!keys.add(key)) _fail(StrictJsonErrorCode.duplicateKey);
      _skipWhitespace();
      _expectCodeUnit(0x3a);
      _skipWhitespace();
      result[key] = _parseValue(depth);
      _skipWhitespace();
      if (_tryConsumeCodeUnit(0x7d)) return result;
      _expectCodeUnit(0x2c);
      _skipWhitespace();
    }
  }

  List<Object?> _parseArray(int depth) {
    if (depth > maxNestingDepth) {
      _fail(StrictJsonErrorCode.nestingTooDeep);
    }
    _expectCodeUnit(0x5b);
    _skipWhitespace();
    final result = <Object?>[];
    if (_tryConsumeCodeUnit(0x5d)) return result;

    while (true) {
      result.add(_parseValue(depth));
      _skipWhitespace();
      if (_tryConsumeCodeUnit(0x5d)) return result;
      _expectCodeUnit(0x2c);
      _skipWhitespace();
    }
  }

  String _parseString() {
    _expectCodeUnit(0x22);
    final buffer = StringBuffer();
    while (!_isAtEnd) {
      final codeUnit = _readCodeUnit();
      if (codeUnit == 0x22) return buffer.toString();
      if (codeUnit == 0x5c) {
        _parseEscapeInto(buffer);
        continue;
      }
      if (codeUnit <= 0x1f) _fail(StrictJsonErrorCode.invalidSyntax);
      buffer.writeCharCode(codeUnit);
    }
    _fail(StrictJsonErrorCode.invalidSyntax);
  }

  void _parseEscapeInto(StringBuffer buffer) {
    if (_isAtEnd) _fail(StrictJsonErrorCode.invalidSyntax);
    final escape = _readCodeUnit();
    switch (escape) {
      case 0x22:
        buffer.writeCharCode(0x22);
        return;
      case 0x5c:
        buffer.writeCharCode(0x5c);
        return;
      case 0x2f:
        buffer.writeCharCode(0x2f);
        return;
      case 0x62:
        buffer.writeCharCode(0x08);
        return;
      case 0x66:
        buffer.writeCharCode(0x0c);
        return;
      case 0x6e:
        buffer.writeCharCode(0x0a);
        return;
      case 0x72:
        buffer.writeCharCode(0x0d);
        return;
      case 0x74:
        buffer.writeCharCode(0x09);
        return;
      case 0x75:
        _parseUnicodeEscapeInto(buffer);
        return;
      default:
        _fail(StrictJsonErrorCode.invalidSyntax);
    }
  }

  void _parseUnicodeEscapeInto(StringBuffer buffer) {
    final first = _readHexCodeUnit();
    if (_isHighSurrogate(first)) {
      if (_remainingCodeUnits < 6 ||
          _peekCodeUnit() != 0x5c ||
          source.codeUnitAt(_offset + 1) != 0x75) {
        _fail(StrictJsonErrorCode.invalidUnicode);
      }
      _offset += 2;
      final second = _readHexCodeUnit();
      if (!_isLowSurrogate(second)) {
        _fail(StrictJsonErrorCode.invalidUnicode);
      }
      buffer.write(String.fromCharCodes([first, second]));
      return;
    }
    if (_isLowSurrogate(first)) _fail(StrictJsonErrorCode.invalidUnicode);
    buffer.writeCharCode(first);
  }

  int _readHexCodeUnit() {
    if (_remainingCodeUnits < 4) _fail(StrictJsonErrorCode.invalidSyntax);
    var value = 0;
    for (var count = 0; count < 4; count += 1) {
      final codeUnit = _readCodeUnit();
      final digit = switch (codeUnit) {
        >= 0x30 && <= 0x39 => codeUnit - 0x30,
        >= 0x41 && <= 0x46 => codeUnit - 0x41 + 10,
        >= 0x61 && <= 0x66 => codeUnit - 0x61 + 10,
        _ => -1,
      };
      if (digit < 0) _fail(StrictJsonErrorCode.invalidSyntax);
      value = (value * 16) + digit;
    }
    return value;
  }

  Object _parseNumber() {
    final start = _offset;
    _tryConsumeCodeUnit(0x2d);
    if (_isAtEnd) _fail(StrictJsonErrorCode.invalidSyntax);

    if (_tryConsumeCodeUnit(0x30)) {
      if (!_isAtEnd && _isDigit(_peekCodeUnit())) {
        _fail(StrictJsonErrorCode.invalidSyntax);
      }
    } else {
      if (_isAtEnd || !_isNonZeroDigit(_peekCodeUnit())) {
        _fail(StrictJsonErrorCode.invalidSyntax);
      }
      _offset += 1;
      while (!_isAtEnd && _isDigit(_peekCodeUnit())) {
        _offset += 1;
      }
    }

    var isFractional = false;
    if (_tryConsumeCodeUnit(0x2e)) {
      isFractional = true;
      if (_isAtEnd || !_isDigit(_peekCodeUnit())) {
        _fail(StrictJsonErrorCode.invalidSyntax);
      }
      while (!_isAtEnd && _isDigit(_peekCodeUnit())) {
        _offset += 1;
      }
    }

    if (!_isAtEnd && (_peekCodeUnit() == 0x65 || _peekCodeUnit() == 0x45)) {
      isFractional = true;
      _offset += 1;
      if (!_isAtEnd && (_peekCodeUnit() == 0x2b || _peekCodeUnit() == 0x2d)) {
        _offset += 1;
      }
      if (_isAtEnd || !_isDigit(_peekCodeUnit())) {
        _fail(StrictJsonErrorCode.invalidSyntax);
      }
      while (!_isAtEnd && _isDigit(_peekCodeUnit())) {
        _offset += 1;
      }
    }

    final number = source.substring(start, _offset);
    if (!isFractional) {
      try {
        return int.parse(number);
      } on FormatException {
        _fail(StrictJsonErrorCode.nonFiniteNumber);
      }
    }
    late final double parsed;
    try {
      parsed = double.parse(number);
    } on FormatException {
      _fail(StrictJsonErrorCode.nonFiniteNumber);
    }
    if (!parsed.isFinite) _fail(StrictJsonErrorCode.nonFiniteNumber);
    return parsed;
  }

  Object? _parseLiteral(String literal, Object? value) {
    for (var index = 0; index < literal.length; index += 1) {
      if (_isAtEnd || _readCodeUnit() != literal.codeUnitAt(index)) {
        _fail(StrictJsonErrorCode.invalidSyntax);
      }
    }
    return value;
  }

  void _skipWhitespace() {
    while (!_isAtEnd) {
      final codeUnit = _peekCodeUnit();
      if (codeUnit != 0x20 &&
          codeUnit != 0x09 &&
          codeUnit != 0x0a &&
          codeUnit != 0x0d) {
        return;
      }
      _offset += 1;
    }
  }

  bool _tryConsumeCodeUnit(int expected) {
    if (_isAtEnd || _peekCodeUnit() != expected) return false;
    _offset += 1;
    return true;
  }

  void _expectCodeUnit(int expected) {
    if (!_tryConsumeCodeUnit(expected)) {
      _fail(StrictJsonErrorCode.invalidSyntax);
    }
  }

  int _readCodeUnit() {
    if (_isAtEnd) _fail(StrictJsonErrorCode.invalidSyntax);
    final codeUnit = source.codeUnitAt(_offset);
    _offset += 1;
    return codeUnit;
  }

  int _peekCodeUnit() => source.codeUnitAt(_offset);

  bool get _isAtEnd => _offset >= source.length;
  int get _remainingCodeUnits => source.length - _offset;

  Never _fail(StrictJsonErrorCode code) {
    throw StrictJsonDecodeException(code, _offset);
  }
}

bool _isHighSurrogate(int codeUnit) => codeUnit >= 0xd800 && codeUnit <= 0xdbff;

bool _isLowSurrogate(int codeUnit) => codeUnit >= 0xdc00 && codeUnit <= 0xdfff;

bool _isDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;

bool _isNonZeroDigit(int codeUnit) => codeUnit >= 0x31 && codeUnit <= 0x39;
