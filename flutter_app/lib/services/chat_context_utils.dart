import 'dart:convert';
import 'dart:math' as math;

class TokenEstimator {
  final double calibrationMultiplier;

  const TokenEstimator({
    this.calibrationMultiplier = 1.0,
  });

  int estimateMessages(List<Map<String, dynamic>> messages) {
    return _applyCalibration(_rawEstimateMessages(messages));
  }

  int estimateMessage(Map<String, dynamic> message) {
    return _applyCalibration(_rawEstimateMessage(message));
  }

  int estimateText(String text) {
    return _applyCalibration(_rawEstimateText(text));
  }

  int estimateBlock(Map<String, dynamic> block) {
    return _applyCalibration(_rawEstimateBlock(block));
  }

  int estimateImage(Map<String, dynamic> imageBlock) {
    return _applyCalibration(_rawEstimateImage(imageBlock));
  }

  int estimateToolDefinitions(List<Map<String, dynamic>> tools) {
    if (tools.isEmpty) return 0;
    return _applyCalibration(_estimateJson(tools));
  }

  TokenEstimatorDiagnostics diagnoseMessages(
    List<Map<String, dynamic>> messages,
  ) {
    var rawTotalTokens = 0;
    var rawTextTokens = 0;
    var rawImageTokens = 0;
    var rawToolTokens = 0;
    var rawLargestBlockTokens = 0;

    for (final message in messages) {
      rawTotalTokens += _messageOverhead;
      rawTextTokens += _messageOverhead;
      final role = message['role'];
      if (role is String) {
        final tokens = _rawEstimateText(role);
        rawTotalTokens += tokens;
        rawTextTokens += tokens;
      }
      final reasoningContent = message['reasoning_content'];
      if (reasoningContent is String) {
        final tokens = _rawEstimateText(reasoningContent);
        rawTotalTokens += tokens;
        rawTextTokens += tokens;
      }

      final content = message['content'];
      if (content is String) {
        final tokens = _rawEstimateText(content);
        rawTotalTokens += tokens;
        rawTextTokens += tokens;
      } else if (content is List) {
        for (final item in content) {
          if (item is Map) {
            final block = Map<String, dynamic>.from(item);
            final tokens = _rawEstimateBlock(block);
            rawTotalTokens += tokens;
            rawLargestBlockTokens = math.max(rawLargestBlockTokens, tokens);
            switch (block['type']) {
              case 'image':
                rawImageTokens += tokens;
                break;
              case 'tool_use':
              case 'tool_result':
                rawToolTokens += tokens;
                break;
              default:
                rawTextTokens += tokens;
            }
          } else if (item is String) {
            final tokens = _rawEstimateText(item);
            rawTotalTokens += tokens;
            rawTextTokens += tokens;
          }
        }
      }
    }

    return TokenEstimatorDiagnostics(
      totalTokens: _applyCalibration(rawTotalTokens),
      textTokens: _applyCalibration(rawTextTokens),
      imageTokens: _applyCalibration(rawImageTokens),
      toolTokens: _applyCalibration(rawToolTokens),
      largestBlockTokens: _applyCalibration(rawLargestBlockTokens),
    );
  }

  int _rawEstimateMessages(List<Map<String, dynamic>> messages) {
    var total = 0;
    for (final message in messages) {
      total += _rawEstimateMessage(message);
    }
    return total;
  }

  int _rawEstimateMessage(Map<String, dynamic> message) {
    var total = _messageOverhead;
    final role = message['role'];
    if (role is String) total += _rawEstimateText(role);
    final reasoningContent = message['reasoning_content'];
    if (reasoningContent is String) {
      total += _rawEstimateText(reasoningContent);
    }

    final content = message['content'];
    if (content is String) {
      total += _rawEstimateText(content);
    } else if (content is List) {
      for (final item in content) {
        if (item is Map) {
          total += _rawEstimateBlock(Map<String, dynamic>.from(item));
        } else if (item is String) {
          total += _rawEstimateText(item);
        }
      }
    }
    return total;
  }

  int _rawEstimateText(String text) {
    if (text.isEmpty) return 0;
    var cjk = 0;
    var ascii = 0;
    var other = 0;
    for (final rune in text.runes) {
      if (_isCjk(rune)) {
        cjk++;
      } else if (rune <= 0x7f) {
        ascii++;
      } else {
        other++;
      }
    }
    final estimate = cjk * 1.3 + ascii * 0.35 + other;
    return math.max(1, estimate.ceil());
  }

  int _rawEstimateBlock(Map<String, dynamic> block) {
    final type = block['type'];
    switch (type) {
      case 'text':
        final text = block['text'];
        final reasoning = block['reasoning_content'];
        return _blockOverhead +
            (text is String ? _rawEstimateText(text) : 0) +
            (reasoning is String ? _rawEstimateText(reasoning) : 0);
      case 'image':
        return _rawEstimateImage(block);
      case 'tool_use':
      case 'tool_result':
        return _blockOverhead + _estimateJson(block);
      default:
        return _blockOverhead + _estimateJson(block);
    }
  }

  int _rawEstimateImage(Map<String, dynamic> imageBlock) {
    final width = _intValue(imageBlock['width']);
    final height = _intValue(imageBlock['height']);
    final source = imageBlock['source'];
    final sourceMap =
        source is Map ? Map<String, dynamic>.from(source) : const {};
    final nestedWidth = _intValue(sourceMap['width']);
    final nestedHeight = _intValue(sourceMap['height']);
    final effectiveWidth = width ?? nestedWidth;
    final effectiveHeight = height ?? nestedHeight;
    if (effectiveWidth != null &&
        effectiveHeight != null &&
        effectiveWidth > 0 &&
        effectiveHeight > 0) {
      final resized = _resizedAnthropicImageSize(
        effectiveWidth,
        effectiveHeight,
      );
      return _countAnthropicImageTokens(resized.width, resized.height) +
          _blockOverhead;
    }
    return 1500;
  }

  int _estimateJson(Object? value) {
    try {
      return _rawEstimateText(jsonEncode(value)) + 8;
    } catch (_) {
      return _rawEstimateText(value.toString()) + 8;
    }
  }

  ({int width, int height}) _resizedAnthropicImageSize(
    int width,
    int height,
  ) {
    bool fits(int w, int h) {
      return (w / 28).ceil() * 28 <= _anthropicMaxImageEdge &&
          (h / 28).ceil() * 28 <= _anthropicMaxImageEdge &&
          _countAnthropicImageTokens(w, h) <= _anthropicMaxImageTokens;
    }

    if (fits(width, height)) return (width: width, height: height);
    if (height > width) {
      final resized = _resizedAnthropicImageSize(height, width);
      return (width: resized.height, height: resized.width);
    }

    final aspectRatio = width / height;
    var lo = 1;
    var hi = width;
    while (lo + 1 < hi) {
      final mid = (lo + hi) ~/ 2;
      final candidateHeight = math.max((mid / aspectRatio).round(), 1);
      if (fits(mid, candidateHeight)) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return (
      width: lo,
      height: math.max((lo / aspectRatio).round(), 1),
    );
  }

  static int _countAnthropicImageTokens(int width, int height) {
    return (width / 28).ceil() * (height / 28).ceil();
  }

  int _applyCalibration(int tokens) {
    if (tokens <= 0) return 0;
    final multiplier = calibrationMultiplier.clamp(0.25, 4.0).toDouble();
    return math.max(1, (tokens * multiplier).ceil());
  }

  static bool _isCjk(int rune) {
    return (rune >= 0x4e00 && rune <= 0x9fff) ||
        (rune >= 0x3400 && rune <= 0x4dbf) ||
        (rune >= 0x20000 && rune <= 0x2a6df) ||
        (rune >= 0x2a700 && rune <= 0x2b73f) ||
        (rune >= 0x2b740 && rune <= 0x2b81f) ||
        (rune >= 0x2b820 && rune <= 0x2ceaf) ||
        (rune >= 0xf900 && rune <= 0xfaff) ||
        (rune >= 0x3040 && rune <= 0x30ff) ||
        (rune >= 0xac00 && rune <= 0xd7af);
  }

  static int? _intValue(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static const _messageOverhead = 4;
  static const _blockOverhead = 3;
  static const _anthropicMaxImageEdge = 1568;
  static const _anthropicMaxImageTokens = 1568;
}

class TokenEstimatorDiagnostics {
  final int totalTokens;
  final int textTokens;
  final int imageTokens;
  final int toolTokens;
  final int largestBlockTokens;

  const TokenEstimatorDiagnostics({
    required this.totalTokens,
    required this.textTokens,
    required this.imageTokens,
    required this.toolTokens,
    required this.largestBlockTokens,
  });
}

class ContextTruncationResult {
  final List<Map<String, dynamic>> messages;
  final int estimatedTokens;
  final int droppedMessageCount;
  final int droppedBlockCount;
  final bool wasTruncated;
  final int maxTokens;
  final int originalEstimatedTokens;
  final bool overBudgetAfterTruncation;

  const ContextTruncationResult({
    required this.messages,
    required this.estimatedTokens,
    required this.droppedMessageCount,
    required this.droppedBlockCount,
    required this.wasTruncated,
    required this.maxTokens,
    required this.originalEstimatedTokens,
    required this.overBudgetAfterTruncation,
  });
}

class _ToolCleanupResult {
  final List<Map<String, dynamic>> messages;
  final int droppedMessageCount;
  final int droppedBlockCount;

  const _ToolCleanupResult({
    required this.messages,
    required this.droppedMessageCount,
    required this.droppedBlockCount,
  });
}

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

  @Deprecated('Use TokenEstimator.estimateMessage for context budgeting.')
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

  static bool _hasMatchingToolPair(
    Map<String, dynamic> toolUseMessage,
    Map<String, dynamic> toolResultMessage,
  ) {
    return _toolUseIds(toolUseMessage)
        .intersection(_toolResultIds(toolResultMessage))
        .isNotEmpty;
  }

  static Set<String> _toolUseIds(Map<String, dynamic> msg) {
    final ids = <String>{};
    final content = msg['content'];
    if (content is! List) return ids;
    for (final block in content) {
      if (block is Map && block['type'] == 'tool_use') {
        final id = block['id'];
        if (id is String) ids.add(id);
      }
    }
    return ids;
  }

  static Set<String> _toolResultIds(Map<String, dynamic> msg) {
    final ids = <String>{};
    final content = msg['content'];
    if (content is! List) return ids;
    for (final block in content) {
      if (block is Map && block['type'] == 'tool_result') {
        final id = block['tool_use_id'];
        if (id is String) ids.add(id);
      }
    }
    return ids;
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
    return _dropUnpairedToolMessagesWithStats(messages).messages;
  }

  static _ToolCleanupResult _dropUnpairedToolMessagesWithStats(
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
    var droppedMessageCount = 0;
    var droppedBlockCount = 0;
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
          } else {
            droppedBlockCount++;
          }
        } else if (type == 'tool_result') {
          final id = block['tool_use_id'];
          if (id is String && pairedIds.contains(id)) {
            blocks.add(Map<String, dynamic>.from(block));
          } else {
            droppedBlockCount++;
          }
        } else {
          blocks.add(Map<String, dynamic>.from(block));
        }
      }
      if (blocks.isEmpty) {
        droppedMessageCount++;
        continue;
      }
      result.add({
        ...msg,
        'content': blocks,
      });
    }
    return _ToolCleanupResult(
      messages: result,
      droppedMessageCount: droppedMessageCount,
      droppedBlockCount: droppedBlockCount,
    );
  }

  /// Truncates messages to fit the token budget.
  ///
  /// [preserveLastMessages] is the minimum number of recent messages to keep
  /// when possible. Tool pair integrity is stricter than this hint, so orphan
  /// tool_use/tool_result cleanup can leave fewer messages than requested.
  static ContextTruncationResult truncateToFit(
    List<Map<String, dynamic>> messages, {
    required int maxTokens,
    required TokenEstimator estimator,
    bool autoCompact = true,
    int preserveLastMessages = 2,
  }) {
    final result = List<Map<String, dynamic>>.from(messages);
    final originalEstimatedTokens = estimator.estimateMessages(result);
    var totalTokens = originalEstimatedTokens;
    if (!autoCompact) {
      return ContextTruncationResult(
        messages: result,
        estimatedTokens: totalTokens,
        droppedMessageCount: 0,
        droppedBlockCount: 0,
        wasTruncated: false,
        maxTokens: maxTokens,
        originalEstimatedTokens: originalEstimatedTokens,
        overBudgetAfterTruncation: totalTokens > maxTokens,
      );
    }

    final minMessagesToPreserve = math.max(0, preserveLastMessages);
    var droppedMessageCount = 0;
    while (result.length > minMessagesToPreserve && totalTokens > maxTokens) {
      final front = result[0];
      if (hasToolUseContent(front) &&
          result.length > 1 &&
          result.length > minMessagesToPreserve &&
          _hasMatchingToolPair(front, result[1])) {
        result.removeAt(0);
        droppedMessageCount++;
        if (result.isNotEmpty) {
          result.removeAt(0);
          droppedMessageCount++;
        }
      } else if (hasToolResultContent(front)) {
        result.removeAt(0);
        droppedMessageCount++;
      } else {
        result.removeAt(0);
        droppedMessageCount++;
      }
      totalTokens = estimator.estimateMessages(result);
    }
    final cleanup = _dropUnpairedToolMessagesWithStats(result);
    final cleanedResult = cleanup.messages;
    totalTokens = estimator.estimateMessages(cleanedResult);
    return ContextTruncationResult(
      messages: cleanedResult,
      estimatedTokens: totalTokens,
      droppedMessageCount: droppedMessageCount + cleanup.droppedMessageCount,
      droppedBlockCount: cleanup.droppedBlockCount,
      wasTruncated: droppedMessageCount > 0 || cleanup.droppedBlockCount > 0,
      maxTokens: maxTokens,
      originalEstimatedTokens: originalEstimatedTokens,
      overBudgetAfterTruncation: totalTokens > maxTokens,
    );
  }
}
