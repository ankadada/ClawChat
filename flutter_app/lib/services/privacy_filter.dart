import 'dart:convert';

class PrivacyFilter {
  /// Masks any configured environment variable values found in [text].
  static String maskEnvVarValues(String text, Map<String, String> envVars) {
    if (envVars.isEmpty) return text;
    var result = text;
    final sortedEntries = envVars.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    for (final entry in sortedEntries) {
      final value = entry.value;
      if (value.isEmpty) continue;
      for (final variant in _encodedVariants(value)) {
        result = result.replaceAll(variant, _maskValue(variant));
      }
    }
    return result;
  }

  static String _maskValue(String value) {
    return '*' * value.length.clamp(8, 128).toInt();
  }

  static List<String> _encodedVariants(String value) {
    final variants = <String>{value};
    if (value.length >= 8) {
      for (final source in [value, '$value\n']) {
        final bytes = utf8.encode(source);
        final base64Value = base64Encode(bytes);
        variants.add(base64Value);
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
