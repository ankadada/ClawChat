class ChatContextUtils {
  static int charCount(Map<String, dynamic> msg) {
    final content = msg['content'];
    if (content is String) return content.length;
    if (content is List) {
      var count = 0;
      for (final item in content) {
        if (item is Map) {
          count += (item['text'] as String?)?.length ?? 0;
          count += (item['content'] as String?)?.length ?? 0;
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
      return content.any((item) => item is Map && item['type'] == 'tool_result');
    }
    return false;
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
