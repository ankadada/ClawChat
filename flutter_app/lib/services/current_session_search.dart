import '../models/chat_models.dart';
import 'llm_content_sanitizer.dart';

class CurrentSessionSearchResult {
  final int messageIndex;
  final String role;
  final String preview;

  const CurrentSessionSearchResult({
    required this.messageIndex,
    required this.role,
    required this.preview,
  });
}

class CurrentSessionSearch {
  const CurrentSessionSearch();

  static const _maxIndexedToolSummaryChars = 240;

  List<CurrentSessionSearchResult> search(
    List<ChatMessage> messages,
    String query, {
    int previewRadius = 48,
  }) {
    final normalizedQuery = query.trim().toLowerCase();
    if (normalizedQuery.isEmpty) return const [];

    final results = <CurrentSessionSearchResult>[];
    for (var i = 0; i < messages.length; i++) {
      final message = messages[i];
      if (message.isSystemNotice) continue;
      final searchableText = _messageSearchText(message);
      final matchIndex = searchableText.toLowerCase().indexOf(normalizedQuery);
      if (matchIndex < 0) continue;
      results.add(CurrentSessionSearchResult(
        messageIndex: i,
        role: message.role,
        preview: _preview(searchableText, matchIndex, query.length,
            radius: previewRadius),
      ));
    }
    return results;
  }

  static String _messageSearchText(ChatMessage message) {
    if (message.isViewingAlternative) return message.textContent;

    final parts = <String>[];
    final assistantError = message.assistantError;
    if (assistantError != null) {
      parts.add(assistantError.message);
      parts.add(assistantError.code);
    }
    for (final content in message.content) {
      switch (content) {
        case TextContent(:final text):
          parts.add(text);
        case ToolUseContent(:final name):
          parts.add(_safeToolText(name));
        case ToolResultContent(:final summary):
          if (summary?.isNotEmpty == true) {
            parts.add(_safeToolText(summary!));
          }
        case ImageContent(:final filename, :final mediaType):
          parts.add(_safeToolText(filename ?? mediaType));
        case StructuredResultContent(:final projection):
          parts.add(_safeToolText(projection));
      }
    }
    return parts.where((part) => part.trim().isNotEmpty).join('\n');
  }

  static String _safeToolText(String text) {
    final sanitized = const LlmContentSanitizer().sanitizeText(text).text;
    if (sanitized.length <= _maxIndexedToolSummaryChars) return sanitized;
    return '${sanitized.substring(0, _maxIndexedToolSummaryChars)}...';
  }

  static String _preview(
    String text,
    int matchIndex,
    int matchLength, {
    required int radius,
  }) {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) return '';
    final clampedMatch = matchIndex.clamp(0, normalized.length).toInt();
    final start = (clampedMatch - radius).clamp(0, normalized.length).toInt();
    final end = (clampedMatch + matchLength + radius)
        .clamp(start, normalized.length)
        .toInt();
    final prefix = start > 0 ? '...' : '';
    final suffix = end < normalized.length ? '...' : '';
    return '$prefix${normalized.substring(start, end)}$suffix';
  }
}
