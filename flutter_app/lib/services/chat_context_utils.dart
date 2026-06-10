class ChatContextUtils {
  static const unsafeMetadataKeys = {
    'cache_control',
    'encrypted',
    'thinking',
    'signature',
    'redacted_thinking',
  };

  static const _allowedContentTypes = {
    'text',
    'image',
    'tool_use',
    'tool_result',
  };

  static int charCount(Map<String, dynamic> msg) {
    final reasoningCount = (msg['reasoning_content'] as String?)?.length ?? 0;
    final content = msg['content'];
    if (content is String) return content.length + reasoningCount;
    if (content is List) {
      var count = reasoningCount;
      for (final item in content) {
        if (item is Map) {
          count += (item['text'] as String?)?.length ?? 0;
          count += (item['content'] as String?)?.length ?? 0;
          count += (item['reasoning_content'] as String?)?.length ?? 0;
          final source = item['source'];
          if (source is Map) {
            count += (source['data'] as String?)?.length ?? 0;
          }
        }
      }
      return count;
    }
    return 0;
  }

  static bool hasToolUseContent(Map<String, dynamic> msg) {
    final content = msg['content'];
    if (content is List) {
      return content.any((item) => item is Map && item['type'] == 'tool_use');
    }
    return false;
  }

  static bool hasToolResultContent(Map<String, dynamic> msg) {
    final content = msg['content'];
    if (content is List) {
      return content
          .any((item) => item is Map && item['type'] == 'tool_result');
    }
    return false;
  }

  static List<Map<String, dynamic>> sanitizeMessages(
    List<Map<String, dynamic>> messages,
  ) {
    final sanitized = <Map<String, dynamic>>[];
    for (final msg in messages) {
      final clean = _sanitizeMessage(msg);
      if (clean != null) sanitized.add(clean);
    }
    return _dropUnpairedToolMessages(sanitized);
  }

  static Map<String, dynamic>? _sanitizeMessage(Map<String, dynamic> msg) {
    final role = msg['role'];
    final content = msg['content'];
    final clean = <String, dynamic>{};
    if (role is String) clean['role'] = role;

    if (content is String) {
      clean['content'] = content;
    } else if (content is List) {
      final blocks = <Map<String, dynamic>>[];
      for (final block in content) {
        final cleanBlock = _sanitizeContentBlock(block);
        if (cleanBlock != null) blocks.add(cleanBlock);
      }
      if (blocks.isEmpty) return null;
      clean['content'] = blocks;
    } else {
      return null;
    }

    // Recovery sanitization intentionally strips top-level reasoning_content.
    // OpenAI-compatible reasoning history is handled by LlmService when needed.
    return clean;
  }

  static Map<String, dynamic>? _sanitizeContentBlock(Object? block) {
    if (block is! Map) return null;
    final type = block['type'];
    if (type == 'thinking' || !_allowedContentTypes.contains(type)) {
      return null;
    }
    final clean = <String, dynamic>{};
    for (final entry in block.entries) {
      final key = entry.key;
      if (key is! String || _isUnsafeMetadataKey(key)) continue;
      clean[key] = _sanitizeValue(entry.value);
    }
    clean['type'] = type;
    return clean;
  }

  static dynamic _sanitizeValue(Object? value) {
    if (value is Map) {
      final clean = <String, dynamic>{};
      for (final entry in value.entries) {
        final key = entry.key;
        if (key is! String || _isUnsafeMetadataKey(key)) continue;
        clean[key] = _sanitizeValue(entry.value);
      }
      return clean;
    }
    if (value is List) {
      return value.map(_sanitizeValue).toList();
    }
    return value;
  }

  static bool _isUnsafeMetadataKey(String key) {
    return unsafeMetadataKeys.contains(key);
  }

  static List<Map<String, dynamic>> _dropUnpairedToolMessages(
    List<Map<String, dynamic>> messages,
  ) {
    final toolUseIds = <String>{};
    final toolResultIds = <String>{};
    for (final msg in messages) {
      final content = msg['content'];
      if (content is! List) continue;
      for (final block in content) {
        if (block is! Map) continue;
        if (block['type'] == 'tool_use' && block['id'] is String) {
          toolUseIds.add(block['id'] as String);
        } else if (block['type'] == 'tool_result' &&
            block['tool_use_id'] is String) {
          toolResultIds.add(block['tool_use_id'] as String);
        }
      }
    }

    final pairedIds = toolUseIds.intersection(toolResultIds);
    final result = <Map<String, dynamic>>[];
    for (final msg in messages) {
      final content = msg['content'];
      if (content is! List) {
        result.add(msg);
        continue;
      }
      final blocks = <Map<String, dynamic>>[];
      for (final block in content) {
        if (block is! Map) continue;
        final type = block['type'];
        if (type == 'tool_use') {
          final id = block['id'];
          if (id is String && pairedIds.contains(id)) {
            blocks.add(Map<String, dynamic>.from(block));
          }
        } else if (type == 'tool_result') {
          final id = block['tool_use_id'];
          if (id is String && pairedIds.contains(id)) {
            blocks.add(Map<String, dynamic>.from(block));
          }
        } else {
          blocks.add(Map<String, dynamic>.from(block));
        }
      }
      if (blocks.isEmpty) continue;
      result.add({
        ...msg,
        'content': blocks,
      });
    }
    return result;
  }

  static List<Map<String, dynamic>> truncateToFit(
    List<Map<String, dynamic>> messages, {
    required int maxChars,
    bool autoCompact = true,
  }) {
    final result = List<Map<String, dynamic>>.from(messages);
    var totalChars = 0;
    for (final msg in result) {
      totalChars += charCount(msg);
    }
    if (!autoCompact) return result;

    while (result.length > 2 && totalChars > maxChars) {
      final front = result[0];
      if (hasToolUseContent(front) &&
          result.length > 2 &&
          hasToolResultContent(result[1])) {
        totalChars -= charCount(result.removeAt(0));
        if (result.isNotEmpty) {
          totalChars -= charCount(result.removeAt(0));
        }
      } else if (hasToolResultContent(front)) {
        totalChars -= charCount(result.removeAt(0));
      } else {
        totalChars -= charCount(result.removeAt(0));
      }
    }
    return result;
  }
}
