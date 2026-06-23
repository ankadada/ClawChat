class RuntimeDebugEvent {
  final DateTime timestamp;
  final String type;
  final String sessionId;
  final Map<String, Object?> data;

  RuntimeDebugEvent({
    DateTime? timestamp,
    required this.type,
    required this.sessionId,
    Map<String, Object?> data = const {},
  })  : timestamp = timestamp ?? DateTime.now(),
        data = RuntimeDebugEventService.sanitizeData(data);
}

class RuntimeDebugEventService {
  static const defaultCapacity = 500;
  static const maxStringLength = 200;

  static const _sensitiveKeyFragments = {
    'api_key',
    'apikey',
    'authorization',
    'bearer',
    'password',
    'passwd',
    'secret',
    'base64',
    'image_data',
    'data_url',
  };

  static const _sensitiveExactKeys = {
    'auth',
    'authorization',
    'api_key',
    'apikey',
    'api_token',
    'token',
    'access_token',
    'refresh_token',
    'id_token',
    'bearer',
    'bearer_token',
    'password',
    'passwd',
    'secret',
    'base64',
    'data',
  };

  final int capacity;
  final List<RuntimeDebugEvent> _events = [];

  RuntimeDebugEventService({this.capacity = defaultCapacity});

  void record(RuntimeDebugEvent event) {
    try {
      if (capacity <= 0) return;
      _events.add(event);
      while (_events.length > capacity) {
        _events.removeAt(0);
      }
    } catch (_) {
      // Debug events must never affect production behavior.
    }
  }

  List<RuntimeDebugEvent> recent({String? sessionId, int limit = 100}) {
    final safeLimit = limit < 0 ? 0 : limit;
    final filtered = sessionId == null
        ? _events
        : _events.where((event) => event.sessionId == sessionId);
    final list = filtered.toList(growable: false);
    if (list.length <= safeLimit) return list;
    return list.sublist(list.length - safeLimit);
  }

  void clear({String? sessionId}) {
    if (sessionId == null) {
      _events.clear();
      return;
    }
    _events.removeWhere((event) => event.sessionId == sessionId);
  }

  static Map<String, Object?> sanitizeData(Map<String, Object?> data) {
    return data.map((key, value) {
      if (_isSensitiveKey(key)) {
        return MapEntry(key, '[redacted]');
      }
      return MapEntry(key, _sanitizeValue(value));
    });
  }

  static bool _isSensitiveKey(String key) {
    final normalized = key.toLowerCase().replaceAll('-', '_');
    return _sensitiveExactKeys.contains(normalized) ||
        _sensitiveKeyFragments.any(normalized.contains);
  }

  static Object? _sanitizeValue(Object? value) {
    if (value == null || value is num || value is bool) return value;
    if (value is DateTime) return value.toIso8601String();
    if (value is Enum) return value.name;
    if (value is String) return _truncateString(value);
    if (value is Iterable) {
      return value.take(20).map((item) => _sanitizeValue(item)).toList();
    }
    if (value is Map) {
      return value.map((key, nestedValue) {
        final stringKey = key.toString();
        if (_isSensitiveKey(stringKey)) {
          return MapEntry(stringKey, '[redacted]');
        }
        return MapEntry(stringKey, _sanitizeValue(nestedValue));
      });
    }
    return _truncateString(value.toString());
  }

  static String _truncateString(String value) {
    if (value.length <= maxStringLength) return value;
    return '${value.substring(0, maxStringLength)}...';
  }
}
