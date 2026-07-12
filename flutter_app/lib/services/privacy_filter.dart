import 'dart:convert';
import 'dart:math' as math;

class PrivacyFilter {
  /// Masks any configured environment variable values found in [text].
  ///
  /// This is best-effort defense-in-depth for logs/tool output, not a security
  /// boundary. Encoded, wrapped, or transformed values may still need upstream
  /// controls such as command policy, confirmation gates, and sandboxing.
  static String maskEnvVarValues(String text, Map<String, String> envVars) {
    if (envVars.isEmpty) return text;
    var result = text;
    final sortedEntries = envVars.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    for (final entry in sortedEntries) {
      final value = entry.value;
      if (!isDistinctiveSecret(value)) continue;
      for (final variant in _encodedVariants(value)) {
        result = result.replaceAll(variant, _maskValue(variant));
      }
    }
    return result;
  }

  static String _maskValue(String value) {
    return '*' * value.length.clamp(8, 128).toInt();
  }

  /// Whether a value is distinctive enough for safe unstructured matching.
  ///
  /// Short/common values are intentionally excluded: replacing every `x`,
  /// `true`, or `password` occurrence would corrupt unrelated user content.
  /// Purpose-specific secret fields must still be redacted structurally.
  static bool isDistinctiveSecret(String value) {
    if (value.length < 8) return false;
    final frequencies = <int, int>{};
    for (final codeUnit in value.codeUnits) {
      frequencies.update(codeUnit, (count) => count + 1, ifAbsent: () => 1);
    }
    var entropyPerCharacter = 0.0;
    for (final count in frequencies.values) {
      final probability = count / value.length;
      entropyPerCharacter -= probability * _log2(probability);
    }
    return entropyPerCharacter * value.length >= 32;
  }

  static double _log2(double value) =>
      value == 1 ? 0 : math.log(value) / math.ln2;

  static List<String> _encodedVariants(String value) {
    final variants = <String>{value};
    if (value.length >= 8) {
      for (final source in [value, '$value\n']) {
        final bytes = utf8.encode(source);
        final base64Value = base64Encode(bytes);
        variants
          ..add(base64Value)
          ..add(base64Url.encode(bytes));
        final hexValue =
            bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
        variants
          ..add(hexValue)
          ..add(hexValue.toUpperCase())
          ..add(_groupHex(hexValue, 2))
          ..add(_groupHex(hexValue, 4));
      }
    }
    return variants.toList()..sort((a, b) => b.length.compareTo(a.length));
  }

  static String _groupHex(String hex, int bytesPerGroup) {
    final charsPerGroup = bytesPerGroup * 2;
    final chunks = <String>[];
    for (var i = 0; i < hex.length; i += charsPerGroup) {
      final end = (i + charsPerGroup).clamp(0, hex.length).toInt();
      chunks.add(hex.substring(i, end));
    }
    return chunks.join(' ');
  }
}
