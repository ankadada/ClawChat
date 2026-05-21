class PrivacyFilter {
  /// Masks any configured environment variable values found in [text].
  static String maskEnvVarValues(String text, Map<String, String> envVars) {
    if (envVars.isEmpty) return text;
    var result = text;
    final sortedEntries = envVars.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    for (final entry in sortedEntries) {
      final value = entry.value;
      if (value.length < 3) continue;
      result = result.replaceAll(value, _maskValue(value));
    }
    return result;
  }

  static String _maskValue(String value) {
    if (value.length >= 8) {
      return '${value.substring(0, 3)}********${value.substring(value.length - 4)}';
    }
    return '********';
  }
}
