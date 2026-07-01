import 'dart:convert';

class ToolArgumentPreflightResult {
  final Map<String, dynamic> arguments;
  final bool repaired;
  final Map<String, int> repairCounts;

  const ToolArgumentPreflightResult({
    required this.arguments,
    this.repaired = false,
    this.repairCounts = const {},
  });
}

class ToolArgumentPreflight {
  const ToolArgumentPreflight();

  ToolArgumentPreflightResult repair(
    Object? rawArguments,
    Map<String, dynamic> inputSchema,
  ) {
    var arguments = _mapFromRaw(rawArguments);
    final counts = <String, int>{};
    if (arguments == null && rawArguments is String) {
      final closed = _decodeWithObviousClosure(rawArguments);
      if (closed != null) {
        arguments = closed;
        _increment(counts, 'json_closure');
      }
    }
    arguments ??= const <String, dynamic>{};

    final properties = _properties(inputSchema);
    final repaired = Map<String, dynamic>.from(arguments);
    _repairFieldNames(repaired, properties, counts);
    _coerceScalarTypes(repaired, properties, counts);

    return ToolArgumentPreflightResult(
      arguments: repaired,
      repaired: counts.isNotEmpty,
      repairCounts: counts,
    );
  }

  Map<String, dynamic>? _mapFromRaw(Object? rawArguments) {
    if (rawArguments is Map) return Map<String, dynamic>.from(rawArguments);
    if (rawArguments is! String || rawArguments.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(rawArguments);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic>? _decodeWithObviousClosure(String rawArguments) {
    final trimmed = rawArguments.trim();
    if (!trimmed.startsWith('{')) return null;
    final suffix = _obviousJsonObjectSuffix(trimmed);
    if (suffix == null) return null;
    try {
      final decoded = jsonDecode('$trimmed$suffix');
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  String? _obviousJsonObjectSuffix(String value) {
    var objectDepth = 0;
    var arrayDepth = 0;
    var inString = false;
    var escaping = false;
    for (final code in value.codeUnits) {
      final char = String.fromCharCode(code);
      if (escaping) {
        escaping = false;
        continue;
      }
      if (char == '\\') {
        escaping = inString;
        continue;
      }
      if (char == '"') {
        inString = !inString;
        continue;
      }
      if (inString) continue;
      if (char == '{') objectDepth++;
      if (char == '}') objectDepth--;
      if (char == '[') arrayDepth++;
      if (char == ']') arrayDepth--;
      if (objectDepth < 0 || arrayDepth < 0) return null;
    }
    if (inString || objectDepth <= 0 || arrayDepth < 0) return null;
    final suffix = StringBuffer();
    for (var i = 0; i < arrayDepth; i++) {
      suffix.write(']');
    }
    for (var i = 0; i < objectDepth; i++) {
      suffix.write('}');
    }
    return suffix.toString();
  }

  Map<String, Map<String, dynamic>> _properties(Map<String, dynamic> schema) {
    final rawProperties = schema['properties'];
    if (rawProperties is! Map) return const {};
    return {
      for (final entry in rawProperties.entries)
        if (entry.key is String && entry.value is Map)
          entry.key as String: Map<String, dynamic>.from(entry.value as Map),
    };
  }

  void _repairFieldNames(
    Map<String, dynamic> arguments,
    Map<String, Map<String, dynamic>> properties,
    Map<String, int> counts,
  ) {
    if (properties.isEmpty) return;
    final propertyNames = properties.keys.toList();
    for (final key in List<String>.from(arguments.keys)) {
      if (properties.containsKey(key)) continue;
      final normalized = _normalizeFieldName(key);
      final matches = propertyNames
          .where((name) => _normalizeFieldName(name) == normalized)
          .toList();
      if (matches.length != 1) continue;
      final target = matches.single;
      if (arguments.containsKey(target)) continue;
      arguments[target] = arguments.remove(key);
      _increment(counts, 'field_name');
    }
  }

  void _coerceScalarTypes(
    Map<String, dynamic> arguments,
    Map<String, Map<String, dynamic>> properties,
    Map<String, int> counts,
  ) {
    for (final entry in properties.entries) {
      if (!arguments.containsKey(entry.key)) continue;
      final expectedType = entry.value['type'];
      if (expectedType is! String) continue;
      final value = arguments[entry.key];
      final coerced = _coerceValue(value, expectedType);
      if (!identical(coerced, value)) {
        arguments[entry.key] = coerced;
        _increment(counts, 'type_coercion');
      }
    }
  }

  Object? _coerceValue(Object? value, String expectedType) {
    if (value is! String) return value;
    final trimmed = value.trim();
    if (expectedType == 'boolean') {
      final lower = trimmed.toLowerCase();
      if (lower == 'true') return true;
      if (lower == 'false') return false;
      return value;
    }
    if (expectedType == 'integer') {
      if (!RegExp(r'^-?\d+$').hasMatch(trimmed)) return value;
      return int.tryParse(trimmed) ?? value;
    }
    if (expectedType == 'number') {
      if (!RegExp(r'^-?(?:\d+\.?\d*|\.\d+)$').hasMatch(trimmed)) return value;
      return double.tryParse(trimmed) ?? value;
    }
    return value;
  }

  String _normalizeFieldName(String value) {
    return value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  void _increment(Map<String, int> counts, String type) {
    counts[type] = (counts[type] ?? 0) + 1;
  }
}
