import 'dart:convert';
import 'dart:math' as math;

import '../models/chat_models.dart';
import 'chat_context_utils.dart';
import 'llm_content_sanitizer.dart';
import 'llm_service.dart';

class ContextSummaryRequest {
  final List<Map<String, dynamic>> messages;
  final ContextSummary? existingSummary;
  final LlmConfig llmConfig;
  final int summaryBudget;
  final String coveredDigest;
  final int coveredMessageCount;
  final int sourceEstimatedTokens;
  final TokenEstimator estimator;
  final int? maxInputTokens;

  const ContextSummaryRequest({
    required this.messages,
    required this.llmConfig,
    required this.summaryBudget,
    required this.coveredDigest,
    required this.coveredMessageCount,
    required this.sourceEstimatedTokens,
    required this.estimator,
    this.maxInputTokens,
    this.existingSummary,
  });
}

class ContextSummaryService {
  // Version 2 invalidates summaries produced before skill history was
  // projected to a fixed non-instructional marker.
  static const version = 2;
  static const _maxToolResultChars = 1200;
  static const _maxToolInputChars = 800;
  static const _maxExtractiveChars = 2400;

  final LlmService Function(LlmConfig config) _llmFactory;

  const ContextSummaryService({
    LlmService Function(LlmConfig config)? llmFactory,
  }) : _llmFactory = llmFactory ?? LlmService.new;

  Future<ContextSummary> generateSummary(
    ContextSummaryRequest request,
  ) async {
    final config = LlmConfig(
      format: request.llmConfig.format,
      apiKey: request.llmConfig.apiKey,
      model: request.llmConfig.model,
      baseUrl: request.llmConfig.baseUrl,
      maxTokens: request.summaryBudget,
      thinkingBudget: 0,
      temperature: 0.2,
    );
    final llm = _llmFactory(config);
    try {
      final prompt = _buildSummaryUserPromptWithinBudget(request);
      final response = await llm.chat(
        system: _summarySystemPrompt,
        messages: [
          {
            'role': 'user',
            'content': prompt,
          },
        ],
        tools: const [],
      );
      final text = response.content
          .where((block) => block.type == 'text')
          .map((block) => block.text ?? '')
          .join('\n')
          .trim();
      if (text.isEmpty) {
        throw StateError('Context summary response was empty.');
      }
      final sanitizedText = _sanitizeText(text);
      final fittedText = _fitSummaryTextToBudget(
        sanitizedText,
        request.estimator,
        request.summaryBudget,
      );
      if (fittedText == null) {
        return extractiveFallback(request);
      }
      return _buildSummary(request, fittedText);
    } finally {
      llm.dispose();
    }
  }

  ContextSummary extractiveFallback(ContextSummaryRequest request) {
    final text = extractiveFallbackText(
      request.messages,
      request.existingSummary,
    );
    final fittedText = _fitSummaryTextToBudget(
          text,
          request.estimator,
          request.summaryBudget,
        ) ??
        '## Context\nSummary unavailable.';
    return _buildSummary(
      request,
      fittedText,
    );
  }

  String buildSummaryUserPrompt({
    required List<Map<String, dynamic>> messages,
    ContextSummary? existingSummary,
  }) {
    final buffer = StringBuffer();
    if (existingSummary != null && existingSummary.text.trim().isNotEmpty) {
      buffer.writeln('Existing rolling summary:');
      buffer.writeln(_sanitizeText(existingSummary.text.trim()));
      buffer.writeln();
      buffer.writeln('New earlier conversation to merge into the summary:');
    } else {
      buffer.writeln('Earlier conversation to summarize:');
    }
    buffer.writeln(jsonEncode(safeProjectMessages(messages)));
    return buffer.toString();
  }

  String extractiveFallbackText(
    List<Map<String, dynamic>> messages,
    ContextSummary? existingSummary,
  ) {
    final lines = <String>[];
    final existing = existingSummary?.text.trim();
    if (existing != null && existing.isNotEmpty) {
      lines.add('## Existing Summary');
      lines.add(_truncate(_sanitizeText(existing), _maxExtractiveChars));
    }
    final userLines = <String>[];
    final assistantLines = <String>[];
    final toolLines = <String>[];
    final fileLines = <String>{}.toList();

    for (final message in messages) {
      final role = message['role'];
      final text = _sanitizeText(_messageText(message));
      final paths = _filePathPattern
          .allMatches(text)
          .map((match) => match.group(0))
          .whereType<String>();
      for (final path in paths) {
        if (!fileLines.contains(path)) fileLines.add(path);
      }
      if (role == 'user' && text.trim().isNotEmpty) {
        userLines.add('- ${_truncate(text.trim(), 260)}');
      } else if (role == 'assistant' && text.trim().isNotEmpty) {
        assistantLines.add('- ${_truncate(text.trim(), 260)}');
      }
      for (final tool in _toolDescriptions(message)) {
        toolLines.add('- $tool');
      }
    }

    lines.add('## Goal');
    lines.add(
        userLines.isEmpty ? '- Not available.' : userLines.take(4).join('\n'));
    lines.add('## Work Completed');
    lines.add(assistantLines.isEmpty
        ? '- Not available.'
        : assistantLines.take(4).join('\n'));
    lines.add('## Relevant Files / Artifacts');
    lines.add(
        fileLines.isEmpty ? '- None captured.' : fileLines.take(12).join('\n'));
    lines.add('## Tool Activity / Warnings');
    lines.add(
        toolLines.isEmpty ? '- None captured.' : toolLines.take(8).join('\n'));
    return _truncate(lines.join('\n\n'), _maxExtractiveChars);
  }

  static List<Map<String, dynamic>> safeProjectMessages(
    List<Map<String, dynamic>> messages,
  ) {
    return _safeProjectMessages(messages);
  }

  static List<Map<String, dynamic>> _safeProjectMessages(
    List<Map<String, dynamic>> messages, {
    int? maxTextChars,
  }) {
    final projected = <Map<String, dynamic>>[];
    for (final message in messages) {
      final role = message['role'];
      if (role is! String) continue;
      final content = message['content'];
      final clean = <String, dynamic>{'role': role};
      if (content is String) {
        clean['content'] = _truncatePlainText(content, maxTextChars);
      } else if (content is List) {
        final blocks = <Map<String, dynamic>>[];
        for (final block in content) {
          final projectedBlock = _safeProjectBlock(
            block,
            maxTextChars: maxTextChars,
          );
          if (projectedBlock != null) blocks.add(projectedBlock);
        }
        if (blocks.isEmpty) continue;
        clean['content'] = blocks;
      } else {
        continue;
      }
      projected.add(clean);
    }
    return projected;
  }

  ContextSummary _buildSummary(ContextSummaryRequest request, String text) {
    final now = DateTime.now();
    final sanitizedText = _sanitizeText(text).trim();
    return ContextSummary(
      version: version,
      text: sanitizedText,
      coveredMessageCount: request.coveredMessageCount,
      coveredDigest: request.coveredDigest,
      sourceEstimatedTokens: request.sourceEstimatedTokens,
      summaryEstimatedTokens: request.estimator.estimateText(sanitizedText),
      createdAt: request.existingSummary?.createdAt ?? now,
      updatedAt: now,
      model: LlmService.modelIdFromDisplay(request.llmConfig.model),
      apiFormat: request.llmConfig.format.name,
    );
  }

  String _buildSummaryUserPromptWithinBudget(ContextSummaryRequest request) {
    final maxInputTokens = request.maxInputTokens;
    final promptBudget = maxInputTokens == null
        ? null
        : math.max(
            1,
            maxInputTokens -
                request.estimator.estimateText(_summarySystemPrompt),
          );
    if (promptBudget == null) {
      return buildSummaryUserPrompt(
        messages: request.messages,
        existingSummary: request.existingSummary,
      );
    }

    var messages = List<Map<String, dynamic>>.from(request.messages);
    var prompt = buildSummaryUserPrompt(
      messages: messages,
      existingSummary: request.existingSummary,
    );
    while (messages.length > 1 &&
        request.estimator.estimateText(prompt) > promptBudget) {
      messages = messages.sublist(1);
      prompt = buildSummaryUserPrompt(
        messages: messages,
        existingSummary: request.existingSummary,
      );
    }
    var maxTextChars = 4000;
    while (request.estimator.estimateText(prompt) > promptBudget &&
        maxTextChars >= 256) {
      prompt = _buildSummaryUserPromptFromProjection(
        projectedMessages: _safeProjectMessages(
          messages,
          maxTextChars: maxTextChars,
        ),
        existingSummary: request.existingSummary,
      );
      maxTextChars ~/= 2;
    }
    if (request.estimator.estimateText(prompt) > promptBudget) {
      prompt = _fitTextToTokenBudget(
        prompt,
        request.estimator,
        promptBudget,
      );
    }
    return prompt;
  }

  String _buildSummaryUserPromptFromProjection({
    required List<Map<String, dynamic>> projectedMessages,
    required ContextSummary? existingSummary,
  }) {
    final buffer = StringBuffer();
    if (existingSummary != null && existingSummary.text.trim().isNotEmpty) {
      buffer.writeln('Existing rolling summary:');
      buffer.writeln(_sanitizeText(existingSummary.text.trim()));
      buffer.writeln();
      buffer.writeln('New earlier conversation to merge into the summary:');
    } else {
      buffer.writeln('Earlier conversation to summarize:');
    }
    buffer.writeln(jsonEncode(projectedMessages));
    return buffer.toString();
  }

  static String? _fitSummaryTextToBudget(
    String text,
    TokenEstimator estimator,
    int summaryBudget,
  ) {
    final trimmed = text.trim();
    if (trimmed.isEmpty || summaryBudget <= 0) return null;
    if (estimator.estimateText(trimmed) <= summaryBudget) return trimmed;

    final sections = trimmed.split(RegExp(r'\n(?=##\s+)'));
    for (var count = sections.length - 1; count >= 1; count--) {
      final candidate = sections.take(count).join('\n').trim();
      if (candidate.isNotEmpty &&
          estimator.estimateText(candidate) <= summaryBudget) {
        return candidate;
      }
    }

    final paragraphs = trimmed.split(RegExp(r'\n\s*\n'));
    for (var count = paragraphs.length - 1; count >= 1; count--) {
      final candidate = paragraphs.take(count).join('\n\n').trim();
      if (candidate.isNotEmpty &&
          estimator.estimateText(candidate) <= summaryBudget) {
        return candidate;
      }
    }

    var lo = 0;
    var hi = trimmed.length;
    while (lo + 1 < hi) {
      final mid = (lo + hi) ~/ 2;
      final candidate = trimmed.substring(0, mid).trimRight();
      if (candidate.isNotEmpty &&
          estimator.estimateText(candidate) <= summaryBudget) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final candidate = trimmed.substring(0, lo).trimRight();
    return candidate.isEmpty ? null : candidate;
  }

  static Map<String, dynamic>? _safeProjectBlock(
    Object? block, {
    int? maxTextChars,
  }) {
    if (block is! Map) return null;
    final type = block['type'];
    switch (type) {
      case 'text':
        final text = block['text'];
        if (text is! String || text.trim().isEmpty) return null;
        return {
          'type': 'text',
          'text': _truncatePlainText(_sanitizeText(text), maxTextChars),
        };
      case 'image':
        return {
          'type': 'image',
          'filename': block['filename'] ?? '[image attachment]',
          'media_type': _imageMediaType(block),
        };
      case 'tool_use':
        final input =
            _sanitizeObject(_removeUnsafeMetadata(block['input'] ?? {}));
        return {
          'type': 'tool_use',
          'name': block['name']?.toString() ?? 'unknown_tool',
          'input': _truncate(jsonEncode(input), _maxToolInputChars),
        };
      case 'tool_result':
        final content = block['summary'] ??
            block['for_llm'] ??
            block['content'] ??
            block['output'] ??
            '';
        return {
          'type': 'tool_result',
          'tool_use_id': block['tool_use_id']?.toString() ?? '',
          'content':
              _truncate(_sanitizeText(content.toString()), _maxToolResultChars),
          if (block['is_error'] == true) 'is_error': true,
        };
      default:
        return null;
    }
  }

  static String _truncatePlainText(String text, int? maxTextChars) {
    final sanitized = _sanitizeText(text);
    if (maxTextChars == null || sanitized.length <= maxTextChars) {
      return sanitized;
    }
    return _truncate(sanitized, maxTextChars);
  }

  static String _fitTextToTokenBudget(
    String text,
    TokenEstimator estimator,
    int tokenBudget,
  ) {
    final trimmed = text.trim();
    if (trimmed.isEmpty || tokenBudget <= 0) return '';
    if (estimator.estimateText(trimmed) <= tokenBudget) return trimmed;
    var lo = 0;
    var hi = trimmed.length;
    while (lo + 1 < hi) {
      final mid = (lo + hi) ~/ 2;
      final candidate = trimmed.substring(0, mid).trimRight();
      if (candidate.isNotEmpty &&
          estimator.estimateText(candidate) <= tokenBudget) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return trimmed.substring(0, lo).trimRight();
  }

  static dynamic _removeUnsafeMetadata(Object? value) {
    if (value is Map) {
      final clean = <String, dynamic>{};
      for (final entry in value.entries) {
        final key = entry.key;
        if (key is! String ||
            ChatContextUtils.unsafeMetadataKeys.contains(key)) {
          continue;
        }
        clean[key] = _removeUnsafeMetadata(entry.value);
      }
      return clean;
    }
    if (value is List) {
      return value.map(_removeUnsafeMetadata).toList();
    }
    return value;
  }

  static String _imageMediaType(Map<dynamic, dynamic> block) {
    final source = block['source'];
    if (source is Map && source['media_type'] is String) {
      return source['media_type'] as String;
    }
    return block['media_type']?.toString() ?? 'image';
  }

  static String _messageText(Map<String, dynamic> message) {
    final content = message['content'];
    if (content is String) return _sanitizeText(content);
    if (content is List) {
      return content
          .whereType<Map>()
          .map((block) {
            final type = block['type'];
            if (type == 'text') return block['text']?.toString() ?? '';
            if (type == 'tool_result') {
              return block['summary']?.toString() ??
                  block['for_llm']?.toString() ??
                  block['content']?.toString() ??
                  block['output']?.toString() ??
                  '';
            }
            if (type == 'tool_use') {
              return '${block['name'] ?? 'tool'} ${block['input'] ?? ''}';
            }
            if (type == 'image') {
              return block['filename']?.toString() ?? '[image attachment]';
            }
            return '';
          })
          .where((text) => text.isNotEmpty)
          .join('\n');
    }
    return '';
  }

  static List<String> _toolDescriptions(Map<String, dynamic> message) {
    final content = message['content'];
    if (content is! List) return const [];
    final descriptions = <String>[];
    for (final block in content.whereType<Map>()) {
      if (block['type'] == 'tool_use') {
        final inputPreview = _truncate(
          _sanitizeText(jsonEncode(_sanitizeObject(block['input'] ?? {}))),
          180,
        );
        descriptions.add(
          'Tool ${block['name'] ?? 'unknown'} called with $inputPreview',
        );
      } else if (block['type'] == 'tool_result') {
        final content = block['summary'] ??
            block['for_llm'] ??
            block['content'] ??
            block['output'] ??
            '';
        final preview = _truncate(_sanitizeText(content.toString()), 180);
        final status = block['is_error'] == true ? '(error)' : '';
        descriptions.add(
          'Tool result $status: $preview',
        );
      }
    }
    return descriptions;
  }

  static String _sanitizeText(String text) {
    return const LlmContentSanitizer().sanitizeText(text).text;
  }

  static Object? _sanitizeObject(Object? value) {
    return const LlmContentSanitizer().sanitizeObject(value).value;
  }

  static String _truncate(String text, int maxChars) {
    if (text.length <= maxChars) return text;
    return '${text.substring(0, maxChars)}\n... (truncated)';
  }

  static final _filePathPattern =
      RegExp(r'((?:[A-Za-z]:)?[/\\][^\s:]+|[\w.-]+/[\w./-]+)');

  static const _summarySystemPrompt = '''
You are compacting earlier conversation history for the same assistant.
Output a concise structured summary. Do not invent facts. Preserve user intent,
constraints, decisions, important discoveries, unresolved tasks, errors, and
relevant files/artifacts. If recent exact messages conflict with this summary,
the recent exact messages win.

Use this structure:
## Goal
## User Instructions
## Decisions and Preferences
## Important Context / Discoveries
## Work Completed
## Open Threads / Next Steps
## Relevant Files / Artifacts
## Warnings / Failed Attempts
''';
}
