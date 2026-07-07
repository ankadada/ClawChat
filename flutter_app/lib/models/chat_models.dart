import 'package:uuid/uuid.dart';

class ContextSummary {
  final int version;
  final String text;
  final int coveredMessageCount;
  final String coveredDigest;
  final int sourceEstimatedTokens;
  final int summaryEstimatedTokens;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? model;
  final String? apiFormat;

  const ContextSummary({
    required this.version,
    required this.text,
    required this.coveredMessageCount,
    required this.coveredDigest,
    required this.sourceEstimatedTokens,
    required this.summaryEstimatedTokens,
    required this.createdAt,
    required this.updatedAt,
    this.model,
    this.apiFormat,
  });

  Map<String, dynamic> toJson() => {
        'version': version,
        'text': text,
        'coveredMessageCount': coveredMessageCount,
        'coveredDigest': coveredDigest,
        'sourceEstimatedTokens': sourceEstimatedTokens,
        'summaryEstimatedTokens': summaryEstimatedTokens,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        if (model != null) 'model': model,
        if (apiFormat != null) 'apiFormat': apiFormat,
      };

  factory ContextSummary.fromJson(Map<String, dynamic> json) {
    return ContextSummary(
      version: json['version'] as int? ?? 1,
      text: json['text'] as String? ?? '',
      coveredMessageCount: json['coveredMessageCount'] as int? ?? 0,
      coveredDigest: json['coveredDigest'] as String? ?? '',
      sourceEstimatedTokens: json['sourceEstimatedTokens'] as int? ?? 0,
      summaryEstimatedTokens: json['summaryEstimatedTokens'] as int? ?? 0,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
      model: json['model'] as String?,
      apiFormat: json['apiFormat'] as String?,
    );
  }
}

class AgentRunRecoveryMarker {
  final DateTime startedAt;

  const AgentRunRecoveryMarker({
    required this.startedAt,
  });

  Map<String, dynamic> toJson() => {
        'startedAt': startedAt.toIso8601String(),
      };

  factory AgentRunRecoveryMarker.fromJson(Map<String, dynamic> json) {
    return AgentRunRecoveryMarker(
      startedAt: DateTime.tryParse(json['startedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

class ChatSession {
  static final _validIdPattern = RegExp(r'^[a-zA-Z0-9_-]+$');

  final String id;
  String title;
  final DateTime createdAt;
  DateTime updatedAt;
  final List<ChatMessage> messages;
  String? modelOverride; // null = use global default
  String? baseUrlOverride; // null = use global default
  String? apiFormatOverride; // null = use global default
  String? systemPrompt; // null = use global default
  String? folder; // null = ungrouped
  String? modelGroupId; // null = use active provider profile
  ContextSummary? contextSummary;
  AgentRunRecoveryMarker? inFlightAgentRun;

  ChatSession({
    required this.id,
    this.title = '新对话',
    DateTime? createdAt,
    DateTime? updatedAt,
    List<ChatMessage>? messages,
    this.modelOverride,
    this.baseUrlOverride,
    this.apiFormatOverride,
    this.systemPrompt,
    this.folder,
    this.modelGroupId,
    this.contextSummary,
    this.inFlightAgentRun,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now(),
        messages = messages ?? [];

  void autoTitle() {
    final firstUserMsg = messages.where((m) => m.role == 'user').firstOrNull;
    if (firstUserMsg != null) {
      final text = firstUserMsg.textContent;
      if (text.isNotEmpty) {
        title = text.length > 50 ? '${text.substring(0, 50)}...' : text;
      }
    }
  }

  List<Map<String, dynamic>> toApiMessages() {
    return messages
        .where((m) => !m.isSystemNotice && !m.hasAssistantError)
        .map((m) => m.toApiJson())
        .toList();
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'messages': messages.map((m) => m.toJson()).toList(),
        if (modelOverride != null) 'modelOverride': modelOverride,
        if (baseUrlOverride != null) 'baseUrlOverride': baseUrlOverride,
        if (apiFormatOverride != null) 'apiFormatOverride': apiFormatOverride,
        if (systemPrompt != null) 'systemPrompt': systemPrompt,
        if (folder != null) 'folder': folder,
        if (modelGroupId != null) 'modelGroupId': modelGroupId,
        if (contextSummary != null) 'contextSummary': contextSummary!.toJson(),
        if (inFlightAgentRun != null)
          'inFlightAgentRun': inFlightAgentRun!.toJson(),
      };

  factory ChatSession.fromJson(Map<String, dynamic> json) {
    final rawSummary = json['contextSummary'];
    final rawInFlightAgentRun = json['inFlightAgentRun'];
    return ChatSession(
      id: _sanitizeId(json['id']?.toString()),
      title: json['title'] as String? ?? '新对话',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
      messages: (json['messages'] as List)
          .map((m) => ChatMessage.fromJson(m))
          .toList(),
      modelOverride: json['modelOverride'] as String?,
      baseUrlOverride: json['baseUrlOverride'] as String?,
      apiFormatOverride: json['apiFormatOverride'] as String?,
      systemPrompt: json['systemPrompt'] as String?,
      folder: json['folder'] as String?,
      modelGroupId: json['modelGroupId'] as String?,
      contextSummary: rawSummary is Map
          ? ContextSummary.fromJson(Map<String, dynamic>.from(rawSummary))
          : null,
      inFlightAgentRun: rawInFlightAgentRun is Map
          ? AgentRunRecoveryMarker.fromJson(
              Map<String, dynamic>.from(rawInFlightAgentRun),
            )
          : null,
    );
  }

  static String _sanitizeId(String? id) {
    if (id != null && _validIdPattern.hasMatch(id)) return id;
    return const Uuid().v4();
  }

  ChatSession copyWith({
    String? id,
    String? title,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<ChatMessage>? messages,
    String? modelOverride,
    String? baseUrlOverride,
    String? apiFormatOverride,
    String? systemPrompt,
    String? folder,
    String? modelGroupId,
    ContextSummary? contextSummary,
    AgentRunRecoveryMarker? inFlightAgentRun,
    bool clearFolder = false,
    bool clearModelGroup = false,
    bool clearContextSummary = false,
    bool clearInFlightAgentRun = false,
  }) {
    return ChatSession(
      id: id ?? this.id,
      title: title ?? this.title,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      messages: messages ?? this.messages,
      modelOverride: modelOverride ?? this.modelOverride,
      baseUrlOverride: baseUrlOverride ?? this.baseUrlOverride,
      apiFormatOverride: apiFormatOverride ?? this.apiFormatOverride,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      folder: clearFolder ? null : (folder ?? this.folder),
      modelGroupId:
          clearModelGroup ? null : (modelGroupId ?? this.modelGroupId),
      contextSummary:
          clearContextSummary ? null : (contextSummary ?? this.contextSummary),
      inFlightAgentRun: clearInFlightAgentRun
          ? null
          : (inFlightAgentRun ?? this.inFlightAgentRun),
    );
  }
}

class ChatMessage {
  final String role;
  List<MessageContent> content;
  final DateTime timestamp;
  int? inputTokens;
  int? outputTokens;
  int? cacheReadInputTokens;
  int? cacheCreationInputTokens;
  bool inputTokensIncludeCache;
  final List<String>? alternatives; // previous generation texts
  int activeAlternative; // -1 = current content, 0+ = index into alternatives
  final bool isSystemNotice;
  final AssistantErrorMetadata? assistantError;

  ChatMessage({
    required this.role,
    required this.content,
    DateTime? timestamp,
    this.inputTokens,
    this.outputTokens,
    this.cacheReadInputTokens,
    this.cacheCreationInputTokens,
    this.inputTokensIncludeCache = false,
    this.alternatives,
    this.activeAlternative = -1,
    this.isSystemNotice = false,
    this.assistantError,
  }) : timestamp = timestamp ?? DateTime.now();

  factory ChatMessage.assistantError({
    required AssistantErrorMetadata error,
    DateTime? timestamp,
  }) {
    return ChatMessage(
      role: 'assistant',
      content: const [],
      timestamp: timestamp,
      assistantError: error,
    );
  }

  /// Total number of versions (current + alternatives).
  int get totalVersions => 1 + (alternatives?.length ?? 0);

  /// Which version is currently showing (1-based for display).
  /// Current content is the latest (totalVersions), alternatives are 1..N.
  int get displayIndex {
    if (activeAlternative == -1) return totalVersions;
    return activeAlternative + 1;
  }

  /// Create a copy with current text pushed into alternatives and new content set.
  ChatMessage withNewAlternative(List<MessageContent> newContent) {
    final alts = List<String>.from(alternatives ?? []);
    // Push the canonical latest text into alternatives.
    alts.add(latestTextContent);
    return ChatMessage(
      role: role,
      content: newContent,
      timestamp: DateTime.now(),
      alternatives: alts,
      activeAlternative: -1,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      cacheReadInputTokens: cacheReadInputTokens,
      cacheCreationInputTokens: cacheCreationInputTokens,
      inputTokensIncludeCache: inputTokensIncludeCache,
    );
  }

  factory ChatMessage.user(String text) {
    return ChatMessage.userContent([TextContent(text)]);
  }

  factory ChatMessage.systemNotice(String text) {
    return ChatMessage(
      role: 'system',
      content: [TextContent(text)],
      isSystemNotice: true,
    );
  }

  factory ChatMessage.userContent(List<MessageContent> content) {
    return ChatMessage(
      role: 'user',
      content: content,
    );
  }

  factory ChatMessage.assistant(List<Map<String, dynamic>> contentBlocks) {
    final content = contentBlocks.map((block) {
      switch (block['type']) {
        case 'text':
          return TextContent(
            block['text'] as String,
            reasoningContent: block['reasoning_content'] as String?,
          );
        case 'image':
          return _imageContentFromMap(block);
        case 'tool_use':
          return ToolUseContent(
            id: block['id'] as String,
            name: block['name'] as String,
            input: Map<String, dynamic>.from(block['input'] ?? {}),
          );
        default:
          return TextContent(block.toString());
      }
    }).toList();
    return ChatMessage(
        role: 'assistant', content: content.cast<MessageContent>());
  }

  factory ChatMessage.toolResults(List<Map<String, dynamic>> results) {
    final content =
        results.map((r) => ToolResultContent.fromToolResultJson(r)).toList();
    return ChatMessage(role: 'user', content: content.cast<MessageContent>());
  }

  String get textContent {
    if (isViewingAlternative) {
      return alternatives![activeAlternative];
    }
    return latestTextContent;
  }

  String get latestTextContent => _contentText;

  bool get isViewingAlternative {
    final alts = alternatives;
    return alts != null &&
        activeAlternative >= 0 &&
        activeAlternative < alts.length;
  }

  String get _contentText {
    return content.whereType<TextContent>().map((c) => c.text).join('\n');
  }

  List<ToolUseContent> get toolUses =>
      content.whereType<ToolUseContent>().toList();
  List<ToolResultContent> get toolResults =>
      content.whereType<ToolResultContent>().toList();

  bool get hasAssistantError => role == 'assistant' && assistantError != null;

  Map<String, dynamic> toApiJson() {
    if (isViewingAlternative) {
      return {
        'role': role,
        'content': textContent,
      };
    }
    if (content.length == 1 && content[0] is TextContent) {
      final textContent = content[0] as TextContent;
      return {
        'role': role,
        'content': textContent.text,
        if (role == 'assistant' &&
            textContent.reasoningContent?.isNotEmpty == true)
          'reasoning_content': textContent.reasoningContent,
      };
    }
    final reasoningContent = role == 'assistant'
        ? content
            .whereType<TextContent>()
            .map((c) => c.reasoningContent ?? '')
            .where((reasoning) => reasoning.isNotEmpty)
            .join('\n')
        : '';
    final apiJson = {
      'role': role,
      'content': content.map((c) => c.toApiJson()).toList(),
    };
    if (reasoningContent.isNotEmpty) {
      apiJson['reasoning_content'] = reasoningContent;
    }
    return apiJson;
  }

  Map<String, dynamic> toJson() => {
        'role': role,
        'timestamp': timestamp.toIso8601String(),
        'content': content.map((c) => c.toJson()).toList(),
        if (inputTokens != null) 'inputTokens': inputTokens,
        if (outputTokens != null) 'outputTokens': outputTokens,
        if (cacheReadInputTokens != null)
          'cacheReadInputTokens': cacheReadInputTokens,
        if (cacheCreationInputTokens != null)
          'cacheCreationInputTokens': cacheCreationInputTokens,
        if (inputTokensIncludeCache) 'inputTokensIncludeCache': true,
        if (alternatives != null && alternatives!.isNotEmpty)
          'alternatives': alternatives,
        if (activeAlternative != -1) 'activeAlternative': activeAlternative,
        if (isSystemNotice) 'isSystemNotice': true,
        if (assistantError != null) 'assistant_error': assistantError!.toJson(),
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final rawContent = json['content'];
    final List<MessageContent> content;
    if (rawContent is String) {
      content = [
        TextContent(
          rawContent,
          reasoningContent: json['reasoning_content'] as String?,
        ),
      ];
    } else {
      final contentList = rawContent as List;
      content = contentList
          .map((c) {
            final type = c['type'] as String;
            switch (type) {
              case 'text':
                return TextContent(
                  c['text'] as String,
                  reasoningContent: c['reasoning_content'] as String?,
                );
              case 'image':
                return _imageContentFromMap(c);
              case 'tool_use':
                return ToolUseContent(
                  id: c['id'] as String,
                  name: c['name'] as String,
                  input: Map<String, dynamic>.from(c['input'] ?? {}),
                );
              case 'tool_result':
                return ToolResultContent.fromToolResultJson(c);
              default:
                return TextContent(c.toString());
            }
          })
          .cast<MessageContent>()
          .toList();
    }
    final altsList = json['alternatives'] as List?;
    final rawAssistantError = json['assistant_error'];
    return ChatMessage(
      role: json['role'] as String,
      content: content,
      timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ??
          DateTime.now(),
      inputTokens: json['inputTokens'] as int?,
      outputTokens: json['outputTokens'] as int?,
      cacheReadInputTokens: json['cacheReadInputTokens'] as int?,
      cacheCreationInputTokens: json['cacheCreationInputTokens'] as int?,
      inputTokensIncludeCache:
          json['inputTokensIncludeCache'] as bool? ?? false,
      alternatives: altsList?.map((e) => e as String).toList(),
      activeAlternative: json['activeAlternative'] as int? ?? -1,
      isSystemNotice: json['isSystemNotice'] as bool? ?? false,
      assistantError: rawAssistantError is Map
          ? AssistantErrorMetadata.fromJson(
              Map<String, dynamic>.from(rawAssistantError),
            )
          : null,
    );
  }

  static ImageContent _imageContentFromMap(Map<dynamic, dynamic> block) {
    final source = block['source'];
    final sourceMap = source is Map ? source : const <String, dynamic>{};
    return ImageContent(
      data: (sourceMap['data'] ?? block['data'] ?? '') as String,
      mediaType: (sourceMap['media_type'] ?? block['media_type'] ?? 'image/png')
          as String,
      filename: block['filename'] as String?,
    );
  }
}

class AssistantErrorMetadata {
  static const int currentVersion = 1;

  final String message;
  final String code;
  final bool canRetry;
  final String? source;
  final String? fallbackReasonCode;
  final String? fallbackReasonLabel;

  const AssistantErrorMetadata({
    required this.message,
    required this.code,
    required this.canRetry,
    this.source,
    this.fallbackReasonCode,
    this.fallbackReasonLabel,
  });

  Map<String, dynamic> toJson() => {
        'version': currentVersion,
        'message': message,
        'code': code,
        'can_retry': canRetry,
        if (source?.isNotEmpty == true) 'source': source,
        if (fallbackReasonCode?.isNotEmpty == true)
          'fallback_reason_code': fallbackReasonCode,
        if (fallbackReasonLabel?.isNotEmpty == true)
          'fallback_reason_label': fallbackReasonLabel,
      };

  factory AssistantErrorMetadata.fromJson(Map<String, dynamic> json) {
    return AssistantErrorMetadata(
      message: _safeText(json['message'], fallback: '模型请求失败'),
      code: _safeCode(json['code'], fallback: 'provider_error'),
      canRetry: json['can_retry'] as bool? ?? false,
      source: _optionalSafeText(json['source']),
      fallbackReasonCode: _optionalSafeCode(json['fallback_reason_code']),
      fallbackReasonLabel: _optionalSafeText(json['fallback_reason_label']),
    );
  }

  static String _safeText(Object? value, {required String fallback}) {
    final text = value?.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text == null || text.isEmpty) return fallback;
    const maxRunes = 280;
    final runes = text.runes.toList(growable: false);
    if (runes.length <= maxRunes) return text;
    return '${String.fromCharCodes(runes.take(maxRunes))}...';
  }

  static String? _optionalSafeText(Object? value) {
    final text = _safeText(value, fallback: '');
    return text.isEmpty ? null : text;
  }

  static String _safeCode(Object? value, {required String fallback}) {
    final raw = value?.toString().trim() ?? '';
    final safe = raw.replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');
    return safe.isEmpty ? fallback : safe;
  }

  static String? _optionalSafeCode(Object? value) {
    final code = _safeCode(value, fallback: '');
    return code.isEmpty ? null : code;
  }
}

sealed class MessageContent {
  Map<String, dynamic> toApiJson();
  Map<String, dynamic> toJson();
}

class TextContent extends MessageContent {
  final String text;
  final String? reasoningContent;

  TextContent(this.text, {this.reasoningContent});

  @override
  Map<String, dynamic> toApiJson() => {'type': 'text', 'text': text};

  @override
  Map<String, dynamic> toJson() => {
        'type': 'text',
        'text': text,
        if (reasoningContent?.isNotEmpty == true)
          'reasoning_content': reasoningContent,
      };
}

class ImageContent extends MessageContent {
  final String data;
  final String mediaType;
  final String? filename;

  ImageContent({
    required this.data,
    required this.mediaType,
    this.filename,
  });

  @override
  Map<String, dynamic> toApiJson() => {
        'type': 'image',
        'source': {
          'type': 'base64',
          'media_type': mediaType,
          'data': data,
        },
      };

  @override
  Map<String, dynamic> toJson() => {
        ...toApiJson(),
        if (filename != null) 'filename': filename,
      };
}

class ToolUseContent extends MessageContent {
  final String id;
  final String name;
  final Map<String, dynamic> input;
  String? output;
  bool isExecuting;
  bool isError;

  ToolUseContent({
    required this.id,
    required this.name,
    required this.input,
    this.output,
    this.isExecuting = false,
    this.isError = false,
  });

  @override
  Map<String, dynamic> toApiJson() => {
        'type': 'tool_use',
        'id': id,
        'name': name,
        'input': input,
      };

  @override
  Map<String, dynamic> toJson() => {
        'type': 'tool_use',
        'id': id,
        'name': name,
        'input': input,
        'output': output,
        'is_error': isError,
      };
}

class ToolResultContent extends MessageContent {
  final String toolUseId;
  final ToolResultPayload payload;
  final bool isError;

  ToolResultContent({
    required this.toolUseId,
    String? output,
    String? forLlm,
    String? summary,
    Map<String, dynamic>? metadata,
    ToolResultPayload? payload,
    this.isError = false,
  }) : payload = payload ??
            ToolResultPayload(
              forUser: output ?? '',
              forLlm: forLlm,
              summary: summary,
              metadata: metadata ?? const {},
            );

  factory ToolResultContent.fromToolResultJson(Map<dynamic, dynamic> json) {
    return ToolResultContent(
      toolUseId: json['tool_use_id']?.toString() ?? '',
      output: ToolResultPayload.stringifyContent(
        json['output'] ?? json['content'] ?? '',
      ),
      forLlm: json.containsKey('for_llm')
          ? ToolResultPayload.stringifyContent(json['for_llm'])
          : null,
      summary: json['summary']?.toString(),
      metadata: ToolResultPayload.metadataFromJson(json['metadata']),
      isError: json['is_error'] as bool? ?? false,
    );
  }

  String get output => payload.forUser;
  String get llmOutput => payload.forLlm ?? payload.forUser;
  String? get forLlm => payload.forLlm;
  String? get summary => payload.summary;
  Map<String, dynamic> get metadata => payload.metadata;

  @override
  Map<String, dynamic> toApiJson() => {
        'type': 'tool_result',
        'tool_use_id': toolUseId,
        'content': llmOutput,
        if (isError) 'is_error': true,
      };

  @override
  Map<String, dynamic> toJson() => {
        'type': 'tool_result',
        'tool_use_id': toolUseId,
        'output': output,
        if (payload.forLlm != null) 'for_llm': payload.forLlm,
        if (payload.summary != null) 'summary': payload.summary,
        if (payload.metadata.isNotEmpty) 'metadata': payload.metadata,
        'is_error': isError,
      };
}

class ToolResultPayload {
  final String forUser;
  final String? forLlm;
  final String? summary;
  final Map<String, dynamic> metadata;

  const ToolResultPayload({
    required this.forUser,
    this.forLlm,
    this.summary,
    this.metadata = const {},
  });

  ToolResultPayload copyWith({
    String? forUser,
    String? forLlm,
    String? summary,
    Map<String, dynamic>? metadata,
    bool clearForLlm = false,
    bool clearSummary = false,
  }) {
    return ToolResultPayload(
      forUser: forUser ?? this.forUser,
      forLlm: clearForLlm ? null : (forLlm ?? this.forLlm),
      summary: clearSummary ? null : (summary ?? this.summary),
      metadata: metadata ?? this.metadata,
    );
  }

  String get llmOutput => forLlm ?? forUser;

  static Map<String, dynamic> metadataFromJson(Object? value) {
    if (value is! Map) return const {};
    return {
      for (final entry in value.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };
  }

  static String stringifyContent(Object? value) {
    if (value == null) return '';
    if (value is String) return value;
    if (value is Iterable) return value.map((e) => e.toString()).join('\n');
    return value.toString();
  }
}
