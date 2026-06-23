class SanitizedText {
  final String text;
  final SensitiveDataStats stats;

  const SanitizedText({
    required this.text,
    required this.stats,
  });
}

class SanitizedObject {
  final Object? value;
  final SensitiveDataStats stats;

  const SanitizedObject({
    required this.value,
    required this.stats,
  });
}

class SensitiveDataStats {
  final Map<String, int> countByType;

  const SensitiveDataStats([this.countByType = const {}]);

  int get totalCount => countByType.values.fold(0, (sum, count) => sum + count);
  bool get hasRedactions => totalCount > 0;

  SensitiveDataStats merge(SensitiveDataStats other) {
    if (!hasRedactions) return other;
    if (!other.hasRedactions) return this;
    final merged = <String, int>{...countByType};
    for (final entry in other.countByType.entries) {
      merged[entry.key] = (merged[entry.key] ?? 0) + entry.value;
    }
    return SensitiveDataStats(Map.unmodifiable(merged));
  }

  Map<String, int> toJson() => Map<String, int>.from(countByType);
}

class LlmContentSanitizer {
  static const redactedValue = '[redacted]';
  static final RegExp _keyValuePattern = RegExp(
    r'''\b([A-Za-z_][A-Za-z0-9_.-]*)\b(\s*[:=]\s*)(["']?)([^\s"',;)}\]]+)''',
    caseSensitive: false,
  );
  static final RegExp _jsonQuotedKeyValuePattern = RegExp(
    r'''(["'])([^"']+)\1(\s*:\s*)(["'])(.*?)\4''',
    caseSensitive: false,
  );
  static final RegExp _cliArgPattern = RegExp(
    r'''(--[A-Za-z0-9_-]+\b(?:\s+|=))(["']?)([^\s"']+)''',
    caseSensitive: false,
  );
  static final RegExp _authorizationPattern = RegExp(
    r'''\b(authorization\s*[:=]\s*)(["']?)(bearer|basic)\s+([A-Za-z0-9._~+/\-]+=*)''',
    caseSensitive: false,
  );
  static final RegExp _bareBearerPattern = RegExp(
    r'''\b(bearer)\s+([A-Za-z0-9._~+/\-]{16,}=*)''',
    caseSensitive: false,
  );
  static final RegExp _pemPrivateKeyPattern = RegExp(
    r'-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----',
  );
  static final RegExp _openAiKeyPattern = RegExp(
    r'\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\b',
  );
  static final RegExp _anthropicKeyPattern = RegExp(
    r'\bsk-ant-[A-Za-z0-9_-]{20,}\b',
  );
  static final RegExp _githubKeyPattern = RegExp(
    r'\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{20,}\b|\bgithub_pat_[A-Za-z0-9_]{20,}\b',
  );
  static final RegExp _googleKeyPattern = RegExp(r'\bAIza[0-9A-Za-z_-]{35}\b');
  static final RegExp _awsAccessKeyPattern =
      RegExp(r'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b');
  static final RegExp _sensitiveQueryPattern = RegExp(
    r'''([?&;](?:api[_-]?key|api[_-]?token|access[_-]?token|'''
    r'''refresh[_-]?token|id[_-]?token|client[_-]?secret|password|passwd|'''
    r'''token|secret)=)([^&#\s]+)''',
    caseSensitive: false,
  );

  const LlmContentSanitizer();

  SanitizedText sanitizeText(String text) {
    if (text.isEmpty || !_mightContainSensitiveData(text)) {
      return SanitizedText(text: text, stats: const SensitiveDataStats());
    }
    final builder = SensitiveDataStatsBuilder();
    var result = text;

    result = _replaceAll(result, _pemPrivateKeyPattern, builder, 'private_key');
    result = result.replaceAllMapped(_authorizationPattern, (match) {
      final type = match.group(3)!.toLowerCase() == 'basic'
          ? 'authorization'
          : 'bearer_token';
      builder.increment(type);
      return '${match.group(1)!}${match.group(2)!}[redacted: $type]';
    });
    result = result.replaceAllMapped(_bareBearerPattern, (match) {
      builder.increment('bearer_token');
      return '${match.group(1)!} [redacted: bearer_token]';
    });
    result = result.replaceAllMapped(_jsonQuotedKeyValuePattern, (match) {
      final key = match.group(2)!;
      final type = _typeForKey(key);
      if (type == null) return match.group(0)!;
      if (_isAlreadyRedacted(match.group(5)!)) return match.group(0)!;
      builder.increment(type);
      return '${match.group(1)!}$key${match.group(1)!}'
          '${match.group(3)!}${match.group(4)!}[redacted: $type]'
          '${match.group(4)!}';
    });
    result = result.replaceAllMapped(_keyValuePattern, (match) {
      final key = match.group(1)!;
      final type = _typeForKey(key);
      if (type == null) return match.group(0)!;
      if (_isAlreadyRedacted(match.group(4)!)) return match.group(0)!;
      builder.increment(type);
      final quote = match.group(3)!;
      return '$key${match.group(2)!}$quote[redacted: $type]'
          '${quote.isEmpty ? '' : quote}';
    });
    result = result.replaceAllMapped(_cliArgPattern, (match) {
      final type = _typeForKey(match.group(1)!);
      if (type == null) return match.group(0)!;
      if (_isAlreadyRedacted(match.group(3)!)) return match.group(0)!;
      builder.increment(type);
      final quote = match.group(2)!;
      return '${match.group(1)!}$quote[redacted: $type]'
          '${quote.isEmpty ? '' : quote}';
    });
    result = result.replaceAllMapped(_sensitiveQueryPattern, (match) {
      final type = _typeForKey(match.group(1)!);
      if (type == null) return match.group(0)!;
      if (_isAlreadyRedacted(match.group(2)!)) return match.group(0)!;
      builder.increment(type);
      return '${match.group(1)!}[redacted: $type]';
    });
    result = _replaceAll(result, _anthropicKeyPattern, builder, 'api_key');
    result = _replaceAll(result, _openAiKeyPattern, builder, 'api_key');
    result = _replaceAll(result, _githubKeyPattern, builder, 'token');
    result = _replaceAll(result, _googleKeyPattern, builder, 'api_key');
    result = _replaceAll(result, _awsAccessKeyPattern, builder, 'aws_key');

    return SanitizedText(text: result, stats: builder.build());
  }

  SanitizedObject sanitizeObject(Object? value) {
    final builder = SensitiveDataStatsBuilder();
    final sanitized = _sanitizeObject(value, builder);
    return SanitizedObject(value: sanitized, stats: builder.build());
  }

  Object? _sanitizeObject(Object? value, SensitiveDataStatsBuilder builder) {
    if (value is String) {
      final sanitized = sanitizeText(value);
      builder.add(sanitized.stats);
      return sanitized.text;
    }
    if (value is Iterable) {
      return value.map((item) => _sanitizeObject(item, builder)).toList();
    }
    if (value is Map) {
      final result = <String, dynamic>{};
      for (final entry in value.entries) {
        final key = entry.key.toString();
        final type = sensitiveTypeForKey(key);
        if (type != null) {
          builder.increment(type);
          result[key] = '[redacted: $type]';
        } else {
          result[key] = _sanitizeObject(entry.value, builder);
        }
      }
      return result;
    }
    return value;
  }

  static String? sensitiveTypeForKey(String key) {
    final normalized = key
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    bool hasPart(String part) {
      final parts = normalized.split('_').where((p) => p.isNotEmpty);
      return parts.contains(part);
    }

    if (normalized == 'authorization' ||
        normalized == 'auth' ||
        normalized.endsWith('_authorization')) {
      return 'authorization';
    }
    if (normalized == 'apikey' ||
        normalized.contains('api_key') ||
        normalized.contains('api_token')) {
      return 'api_key';
    }
    if (normalized == 'password' ||
        normalized == 'passwd' ||
        normalized.endsWith('_password') ||
        normalized.endsWith('_passwd') ||
        normalized.contains('_password_') ||
        normalized.contains('_passwd_')) {
      return 'password';
    }
    if (normalized.contains('private_key')) return 'private_key';
    if (normalized.contains('secret_access_key') ||
        normalized == 'secret' ||
        normalized.endsWith('_secret') ||
        normalized.contains('_secret_') ||
        normalized == 'client_secret') {
      return 'secret';
    }
    if (normalized == 'bearer' ||
        normalized == 'bearer_token' ||
        normalized.endsWith('_bearer_token')) {
      return 'bearer_token';
    }
    if (normalized == 'token' ||
        normalized.endsWith('_token') ||
        normalized.contains('_token_') ||
        normalized == 'id_token' ||
        normalized == 'access_token' ||
        normalized == 'refresh_token' ||
        hasPart('token')) {
      return 'token';
    }
    return null;
  }

  static bool isSensitiveKey(String key) => sensitiveTypeForKey(key) != null;

  static String _replaceAll(
    String text,
    RegExp pattern,
    SensitiveDataStatsBuilder builder,
    String type,
  ) {
    return text.replaceAllMapped(pattern, (match) {
      builder.increment(type);
      return '[redacted: $type]';
    });
  }

  static bool _mightContainSensitiveData(String text) {
    final lower = text.toLowerCase();
    return lower.contains('key') ||
        lower.contains('token') ||
        lower.contains('secret') ||
        lower.contains('password') ||
        lower.contains('passwd') ||
        lower.contains('authorization') ||
        lower.contains('bearer') ||
        lower.contains('basic') ||
        lower.contains('akia') ||
        lower.contains('asia') ||
        lower.contains('sk-') ||
        lower.contains('ghp_') ||
        lower.contains('gho_') ||
        lower.contains('ghu_') ||
        lower.contains('ghs_') ||
        lower.contains('ghr_') ||
        lower.contains('github_pat_') ||
        text.contains('AIza') ||
        text.contains('PRIVATE KEY');
  }

  static bool _isAlreadyRedacted(String value) {
    final normalized = value.toLowerCase();
    return normalized.startsWith('[redacted') ||
        normalized.startsWith('%5bredacted');
  }

  static String? _typeForKey(String key) {
    return sensitiveTypeForKey(key);
  }
}

class SensitiveDataStatsBuilder {
  final Map<String, int> _counts = {};

  void increment(String type) {
    _counts[type] = (_counts[type] ?? 0) + 1;
  }

  void add(SensitiveDataStats stats) {
    for (final entry in stats.countByType.entries) {
      _counts[entry.key] = (_counts[entry.key] ?? 0) + entry.value;
    }
  }

  SensitiveDataStats build() {
    if (_counts.isEmpty) return const SensitiveDataStats();
    return SensitiveDataStats(Map.unmodifiable(_counts));
  }
}
