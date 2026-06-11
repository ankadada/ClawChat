import 'dart:convert';

enum ProviderTransformMode { normal, recovery, compare }

class ProviderTransformOptions {
  final String apiFormat;
  final String modelId;
  final Uri? baseUrl;
  final ProviderTransformMode mode;
  final bool supportsImages;
  final bool supportsReasoningContent;

  const ProviderTransformOptions({
    required this.apiFormat,
    required this.modelId,
    this.baseUrl,
    this.mode = ProviderTransformMode.normal,
    this.supportsImages = true,
    this.supportsReasoningContent = false,
  });

  bool get isAnthropic => apiFormat.toLowerCase() == 'anthropic';
  bool get isOpenAI => apiFormat.toLowerCase() == 'openai';
  bool get isRecovery => mode == ProviderTransformMode.recovery;
}

class ProviderTransformResult {
  final List<Map<String, dynamic>> messages;
  final List<String> warnings;
  final int droppedBlockCount;
  final Map<String, String> toolIdMap;

  const ProviderTransformResult({
    required this.messages,
    this.warnings = const [],
    this.droppedBlockCount = 0,
    this.toolIdMap = const {},
  });
}

class ProviderMessageTransform {
  static const unsafeMetadataKeys = {
    'cache_control',
    'encrypted',
    'thinking',
    'signature',
    'redacted_thinking',
  };

  static const allowedContentTypes = {
    'text',
    'image',
    'image_url',
    'tool_use',
    'tool_result',
  };

  const ProviderMessageTransform();

  ProviderTransformResult transformCanonical(
    List<Map<String, dynamic>> messages,
    ProviderTransformOptions options,
  ) {
    final warnings = <String>[];
    final toolIdMap = <String, String>{};
    final assignedToolIds = <String>{};
    var droppedBlockCount = 0;
    final transformed = <Map<String, dynamic>>[];

    for (final msg in messages) {
      final clean = _transformMessage(
        msg,
        options,
        warnings,
        toolIdMap,
        assignedToolIds,
      );
      if (clean == null) {
        droppedBlockCount++;
        continue;
      }
      transformed.add(clean);
    }

    final cleanup = options.isRecovery
        ? _dropUnpairedToolBlocks(transformed, warnings)
        : _warnUnpairedToolBlocks(transformed, warnings);
    droppedBlockCount += cleanup.droppedBlockCount;

    return ProviderTransformResult(
      messages: cleanup.messages,
      warnings: warnings,
      droppedBlockCount: droppedBlockCount,
      toolIdMap: toolIdMap,
    );
  }

  List<Map<String, dynamic>> toProviderPayload(
    List<Map<String, dynamic>> canonicalMessages,
    ProviderTransformOptions options,
  ) {
    final canonical = transformCanonical(canonicalMessages, options).messages;
    if (options.isAnthropic) {
      return canonical.expand(_convertMessageToAnthropic).toList();
    }
    if (options.isOpenAI) {
      return canonical
          .expand((msg) => _convertMessageToOpenAI(
                msg,
                supportsReasoningContent: options.supportsReasoningContent,
              ))
          .toList();
    }
    return canonical;
  }

  static dynamic removeUnsafeMetadata(Object? value) {
    if (value is Map) {
      final clean = <String, dynamic>{};
      for (final entry in value.entries) {
        final key = entry.key;
        if (key is! String || _isUnsafeMetadataKey(key)) continue;
        clean[key] = removeUnsafeMetadata(entry.value);
      }
      return clean;
    }
    if (value is List) {
      return value.map(removeUnsafeMetadata).toList();
    }
    return value;
  }

  Map<String, dynamic>? _transformMessage(
    Map<String, dynamic> msg,
    ProviderTransformOptions options,
    List<String> warnings,
    Map<String, String> toolIdMap,
    Set<String> assignedToolIds,
  ) {
    final role = msg['role'];
    final toolCalls = msg['tool_calls'];
    final clean = <String, dynamic>{};
    if (role is String) clean['role'] = role;

    final content = msg['content'];
    if (content is String) {
      if (content.isEmpty && toolCalls is! List) return null;
      clean['content'] = content;
    } else if (content is List) {
      final blocks = <Map<String, dynamic>>[];
      for (final item in content) {
        final block = _transformContentBlock(
          item,
          options,
          warnings,
          toolIdMap,
          assignedToolIds,
        );
        if (block == null) continue;
        blocks.add(block);
      }
      if (blocks.isEmpty && toolCalls is! List) return null;
      clean['content'] = blocks;
    } else {
      return null;
    }

    final shouldKeepReasoning = !options.isRecovery &&
        options.supportsReasoningContent &&
        role == 'assistant';
    final reasoning = msg['reasoning_content'];
    if (shouldKeepReasoning && reasoning is String) {
      clean['reasoning_content'] = reasoning;
    }

    if (toolCalls is List && !options.isRecovery) {
      final calls = toolCalls
          .map((toolCall) => _normalizeOpenAIToolCallWithScrub(
                toolCall,
                toolIdMap,
                assignedToolIds,
              ))
          .whereType<Map<String, dynamic>>()
          .toList();
      if (calls.isNotEmpty) clean['tool_calls'] = calls;
    }

    final toolCallId = msg['tool_call_id'];
    if (role == 'tool' && toolCallId != null) {
      clean['tool_call_id'] = _scrubToolId(
        toolCallId.toString(),
        toolIdMap,
        assignedToolIds,
      );
    }

    return clean;
  }

  Map<String, dynamic>? _transformContentBlock(
    Object? value,
    ProviderTransformOptions options,
    List<String> warnings,
    Map<String, String> toolIdMap,
    Set<String> assignedToolIds,
  ) {
    if (value is! Map) return null;
    final block = removeUnsafeMetadata(value);
    if (block is! Map<String, dynamic>) return null;
    final type = block['type'];
    if (type == 'thinking' || !allowedContentTypes.contains(type)) {
      return null;
    }

    if (type == 'text') {
      final text = block['text'] as String? ?? '';
      if (text.isEmpty) return null;
      final clean = <String, dynamic>{
        'type': 'text',
        'text': text,
      };
      final shouldKeepReasoning = !options.isRecovery &&
          options.supportsReasoningContent &&
          block['reasoning_content'] is String;
      if (shouldKeepReasoning) {
        clean['reasoning_content'] = block['reasoning_content'];
      }
      return clean;
    }

    if (type == 'image' || type == 'image_url') {
      if (!options.supportsImages) {
        warnings.add('image content replaced because provider lacks support');
        return {
          'type': 'text',
          'text':
              '[Attachment omitted: images are not supported by this provider]',
        };
      }
      return Map<String, dynamic>.from(block);
    }

    if (type == 'tool_use') {
      final id = block['id']?.toString();
      final name = block['name']?.toString();
      if (id == null || id.isEmpty || name == null || name.isEmpty) {
        warnings.add('dropped tool_use with missing id or name');
        return null;
      }
      return {
        ...block,
        'type': 'tool_use',
        'id': _scrubToolId(id, toolIdMap, assignedToolIds),
        'name': name,
        'input': removeUnsafeMetadata(block['input'] ?? {}),
      };
    }

    if (type == 'tool_result') {
      final id = block['tool_use_id']?.toString();
      if (id == null || id.isEmpty) {
        warnings.add('dropped tool_result with missing tool_use_id');
        return null;
      }
      return {
        ...block,
        'type': 'tool_result',
        'tool_use_id': _scrubToolId(id, toolIdMap, assignedToolIds),
      };
    }

    return null;
  }

  List<Map<String, dynamic>> _convertMessageToAnthropic(
    Map<String, dynamic> msg,
  ) {
    final role = msg['role'] as String? ?? 'user';
    if (role == 'tool') {
      final toolCallId = msg['tool_call_id']?.toString() ?? '';
      if (toolCallId.isEmpty) return const [];
      return [
        {
          'role': 'user',
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': toolCallId,
              'content': _stringContent(msg['content']),
            }
          ],
        }
      ];
    }

    final anthropicRole = role == 'assistant' ? 'assistant' : 'user';
    final content = msg['content'];
    final toolCalls = msg['tool_calls'];

    if (toolCalls is List && role == 'assistant') {
      final blocks = <Map<String, dynamic>>[];
      blocks.addAll(_anthropicContentBlocks(content));
      for (final toolCall in toolCalls) {
        final block = _openAIToolCallToAnthropic(toolCall);
        if (block != null) blocks.add(block);
      }
      if (blocks.isEmpty) return const [];
      return [
        {
          'role': 'assistant',
          'content': blocks,
        }
      ];
    }

    if (content is List) {
      final blocks = _anthropicContentBlocks(content);
      if (blocks.isEmpty) return const [];
      return [
        {
          'role': anthropicRole,
          'content': blocks,
        }
      ];
    }

    return [
      {
        'role': anthropicRole,
        'content': _stringContent(content),
      }
    ];
  }

  List<Map<String, dynamic>> _anthropicContentBlocks(Object? content) {
    if (content is String) {
      return content.isEmpty
          ? const []
          : [
              {'type': 'text', 'text': content}
            ];
    }
    if (content is! List) return const [];

    final blocks = <Map<String, dynamic>>[];
    for (final block in content) {
      final converted = _anthropicContentBlock(block);
      if (converted != null) blocks.add(converted);
    }
    return blocks;
  }

  Map<String, dynamic>? _anthropicContentBlock(Object? block) {
    if (block is! Map) return null;
    final type = block['type'];
    if (type == 'text') {
      final text = block['text'] as String? ?? '';
      if (text.isEmpty) return null;
      return {
        'type': 'text',
        'text': text,
      };
    }
    if (type == 'image') {
      return _normalizeAnthropicImageBlock(block);
    }
    if (type == 'image_url') {
      return _openAIImageBlockToAnthropic(block);
    }
    if (type == 'tool_use') {
      return {
        'type': 'tool_use',
        'id': block['id'],
        'name': block['name'],
        'input': Map<String, dynamic>.from(block['input'] as Map? ?? {}),
      };
    }
    if (type == 'tool_result') {
      return {
        'type': 'tool_result',
        'tool_use_id': block['tool_use_id'],
        'content': _stringContent(block['content'] ?? block['output']),
        if (block['is_error'] == true) 'is_error': true,
      };
    }
    return null;
  }

  Map<String, dynamic>? _normalizeAnthropicImageBlock(
    Map<dynamic, dynamic> block,
  ) {
    final source = block['source'];
    if (source is Map) {
      return {
        'type': 'image',
        'source': Map<String, dynamic>.from(source),
      };
    }
    final data = block['data'] as String?;
    if (data == null || data.isEmpty) return null;
    return {
      'type': 'image',
      'source': {
        'type': 'base64',
        'media_type': block['media_type'] as String? ?? 'image/png',
        'data': data,
      },
    };
  }

  Map<String, dynamic>? _openAIImageBlockToAnthropic(
    Map<dynamic, dynamic> block,
  ) {
    final imageUrl = block['image_url'];
    final url = imageUrl is Map ? imageUrl['url'] as String? : null;
    if (url == null || url.isEmpty) return null;

    final dataUrl = RegExp(r'^data:([^;,]+);base64,(.*)$').firstMatch(url);
    if (dataUrl != null) {
      return {
        'type': 'image',
        'source': {
          'type': 'base64',
          'media_type': dataUrl.group(1)!,
          'data': dataUrl.group(2)!,
        },
      };
    }

    return {
      'type': 'image',
      'source': {
        'type': 'url',
        'url': url,
      },
    };
  }

  Map<String, dynamic>? _openAIToolCallToAnthropic(Object? toolCall) {
    if (toolCall is! Map) return null;
    final function = toolCall['function'];
    if (function is! Map) return null;
    final id = toolCall['id']?.toString();
    final name = function['name']?.toString();
    if (id == null || id.isEmpty || name == null || name.isEmpty) return null;

    final rawArguments = function['arguments'];
    Map<String, dynamic> input = {};
    if (rawArguments is Map) {
      input = Map<String, dynamic>.from(rawArguments);
    } else if (rawArguments is String && rawArguments.isNotEmpty) {
      try {
        input = jsonDecode(rawArguments) as Map<String, dynamic>;
      } catch (_) {
        input = {};
      }
    }

    return {
      'type': 'tool_use',
      'id': id,
      'name': name,
      'input': input,
    };
  }

  List<Map<String, dynamic>> _convertMessageToOpenAI(
    Map<String, dynamic> msg, {
    required bool supportsReasoningContent,
  }) {
    final role = msg['role'] as String;
    final content = msg['content'];
    final reasoningContent =
        role == 'assistant' ? msg['reasoning_content'] as String? : null;
    final topLevelToolCalls = msg['tool_calls'] as List?;

    if (content is String) {
      final result = <String, dynamic>{
        'role': role,
        'content': content,
      };
      if (role == 'tool' && msg['tool_call_id'] != null) {
        result['tool_call_id'] = msg['tool_call_id'];
      }
      if (role == 'assistant' && supportsReasoningContent) {
        result['reasoning_content'] =
            reasoningContent?.isNotEmpty == true ? reasoningContent! : '';
      }
      if (topLevelToolCalls != null) {
        result['tool_calls'] =
            topLevelToolCalls.map(_normalizeOpenAIToolCall).toList();
      }
      return [result];
    }

    if (content is List) {
      final firstItem = content.isNotEmpty ? content[0] : null;
      if (firstItem is Map && firstItem['type'] == 'tool_result') {
        return content
            .where((item) => item is Map && item['type'] == 'tool_result')
            .map<Map<String, dynamic>>((item) {
          return {
            'role': 'tool',
            'tool_call_id': item['tool_use_id'],
            'content': item['content'] is String
                ? item['content']
                : jsonEncode(item['content']),
          };
        }).toList();
      }

      final textParts = <String>[];
      final reasoningParts = <String>[
        if (reasoningContent?.isNotEmpty == true) reasoningContent!,
      ];
      final contentParts = <Map<String, dynamic>>[];
      final toolCalls = <Map<String, dynamic>>[];
      var hasImage = false;
      for (final block in content) {
        if (block is Map) {
          if (block['type'] == 'text') {
            final text = block['text'] as String? ?? '';
            textParts.add(text);
            contentParts.add({'type': 'text', 'text': text});
            final blockReasoning = block['reasoning_content'] as String?;
            if (role == 'assistant' &&
                blockReasoning != null &&
                blockReasoning.isNotEmpty) {
              reasoningParts.add(blockReasoning);
            }
          } else if (block['type'] == 'image') {
            final imageContent = _convertImageBlockToOpenAI(block);
            if (imageContent != null) {
              hasImage = true;
              contentParts.add(imageContent);
            }
          } else if (block['type'] == 'image_url') {
            final imageUrl = block['image_url'];
            if (imageUrl is Map && imageUrl['url'] is String) {
              hasImage = true;
              contentParts.add({
                'type': 'image_url',
                'image_url': {'url': imageUrl['url'] as String},
              });
            }
          } else if (block['type'] == 'tool_use') {
            toolCalls.add({
              'id': block['id'],
              'type': 'function',
              'function': {
                'name': block['name'],
                'arguments': jsonEncode(block['input']),
              },
            });
          }
        }
      }
      if (hasImage && toolCalls.isEmpty) {
        final result = <String, dynamic>{
          'role': role,
          'content': contentParts,
        };
        final combinedReasoning = reasoningParts.join('\n');
        if (role == 'assistant' && supportsReasoningContent) {
          result['reasoning_content'] =
              combinedReasoning.isNotEmpty ? combinedReasoning : '';
        }
        if (topLevelToolCalls != null) {
          result['tool_calls'] =
              topLevelToolCalls.map(_normalizeOpenAIToolCall).toList();
        }
        return [result];
      }
      final result = <String, dynamic>{
        'role': role,
        'content': textParts.join('\n'),
      };
      final combinedReasoning = reasoningParts.join('\n');
      if (role == 'assistant' && supportsReasoningContent) {
        result['reasoning_content'] =
            combinedReasoning.isNotEmpty ? combinedReasoning : '';
      }
      if (toolCalls.isNotEmpty) result['tool_calls'] = toolCalls;
      if (toolCalls.isEmpty && topLevelToolCalls != null) {
        result['tool_calls'] =
            topLevelToolCalls.map(_normalizeOpenAIToolCall).toList();
      }
      return [result];
    }

    return [
      {'role': role, 'content': content.toString()}
    ];
  }

  Map<String, dynamic> _normalizeOpenAIToolCall(Object? toolCall) {
    if (toolCall is! Map) return {};
    final function = toolCall['function'];
    final functionMap =
        function is Map ? Map<String, dynamic>.from(function) : {};
    return {
      'id': toolCall['id'],
      'type': toolCall['type'] ?? 'function',
      'function': {
        'name': functionMap['name'],
        'arguments': functionMap['arguments'] is String
            ? functionMap['arguments']
            : jsonEncode(functionMap['arguments'] ?? {}),
      },
    };
  }

  Map<String, dynamic>? _normalizeOpenAIToolCallWithScrub(
    Object? toolCall,
    Map<String, String> toolIdMap,
    Set<String> assignedToolIds,
  ) {
    if (toolCall is! Map) return null;
    final function = toolCall['function'];
    final functionMap =
        function is Map ? Map<String, dynamic>.from(function) : {};
    final rawId = toolCall['id']?.toString();
    if (rawId == null || rawId.isEmpty) return null;
    return {
      'id': _scrubToolId(rawId, toolIdMap, assignedToolIds),
      'type': toolCall['type'] ?? 'function',
      'function': {
        'name': functionMap['name'],
        'arguments': functionMap['arguments'] is String
            ? functionMap['arguments']
            : jsonEncode(functionMap['arguments'] ?? {}),
      },
    };
  }

  Map<String, dynamic>? _convertImageBlockToOpenAI(
    Map<dynamic, dynamic> block,
  ) {
    final imageUrl = block['image_url'];
    if (imageUrl is Map && imageUrl['url'] is String) {
      return {
        'type': 'image_url',
        'image_url': {'url': imageUrl['url'] as String},
      };
    }

    final source = block['source'];
    final sourceMap = source is Map ? source : const <String, dynamic>{};
    final mediaType = (sourceMap['media_type'] ??
        block['media_type'] ??
        'image/png') as String;
    final data = (sourceMap['data'] ?? block['data']) as String?;
    if (data == null || data.isEmpty) return null;

    return {
      'type': 'image_url',
      'image_url': {
        'url': 'data:$mediaType;base64,$data',
      },
    };
  }

  _ToolCleanupResult _dropUnpairedToolBlocks(
    List<Map<String, dynamic>> messages,
    List<String> warnings,
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
            warnings.add('dropped orphan tool_use block');
          }
        } else if (type == 'tool_result') {
          final id = block['tool_use_id'];
          if (id is String && pairedIds.contains(id)) {
            blocks.add(Map<String, dynamic>.from(block));
          } else {
            droppedBlockCount++;
            warnings.add('dropped orphan tool_result block');
          }
        } else {
          blocks.add(Map<String, dynamic>.from(block));
        }
      }
      if (blocks.isEmpty) {
        droppedBlockCount++;
        continue;
      }
      result.add({
        ...msg,
        'content': blocks,
      });
    }
    return _ToolCleanupResult(
      messages: result,
      droppedBlockCount: droppedBlockCount,
    );
  }

  _ToolCleanupResult _warnUnpairedToolBlocks(
    List<Map<String, dynamic>> messages,
    List<String> warnings,
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
    final orphanUseIds = toolUseIds.difference(toolResultIds);
    final orphanResultIds = toolResultIds.difference(toolUseIds);
    if (orphanUseIds.isNotEmpty) {
      warnings.add('found orphan tool_use block');
    }
    if (orphanResultIds.isNotEmpty) {
      warnings.add('found orphan tool_result block');
    }
    return _ToolCleanupResult(
      messages: messages,
      droppedBlockCount: 0,
    );
  }

  String _scrubToolId(
    String id,
    Map<String, String> toolIdMap,
    Set<String> assignedToolIds,
  ) {
    final existing = toolIdMap[id];
    if (existing != null) return existing;
    final scrubbed = id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final base = scrubbed.isEmpty ? 'toolu_${_stableHash(id)}' : scrubbed;
    var result = base;
    if (assignedToolIds.contains(result)) {
      result = '${base}_${_stableHash(id).toRadixString(16)}';
      var suffix = 2;
      while (assignedToolIds.contains(result)) {
        result = '${base}_${_stableHash('$id#$suffix').toRadixString(16)}';
        suffix++;
      }
    }
    toolIdMap[id] = result;
    assignedToolIds.add(result);
    return result;
  }

  int _stableHash(String value) {
    var hash = 0;
    for (final codeUnit in value.codeUnits) {
      hash = (hash * 31 + codeUnit) & 0x7fffffff;
    }
    return hash;
  }

  static String _stringContent(Object? content) {
    if (content == null) return '';
    if (content is String) return content;
    return jsonEncode(content);
  }

  static bool _isUnsafeMetadataKey(String key) {
    return unsafeMetadataKeys.contains(key);
  }
}

class _ToolCleanupResult {
  final List<Map<String, dynamic>> messages;
  final int droppedBlockCount;

  const _ToolCleanupResult({
    required this.messages,
    required this.droppedBlockCount,
  });
}
