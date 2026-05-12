class ChatSession {
  final String id;
  String title;
  final DateTime createdAt;
  DateTime updatedAt;
  final List<ChatMessage> messages;
  String? modelOverride;      // null = use global default
  String? baseUrlOverride;    // null = use global default
  String? apiFormatOverride;  // null = use global default

  ChatSession({
    required this.id,
    this.title = '新对话',
    DateTime? createdAt,
    DateTime? updatedAt,
    List<ChatMessage>? messages,
    this.modelOverride,
    this.baseUrlOverride,
    this.apiFormatOverride,
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
    return messages.map((m) => m.toApiJson()).toList();
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
  };

  factory ChatSession.fromJson(Map<String, dynamic> json) {
    return ChatSession(
      id: json['id'] as String,
      title: json['title'] as String? ?? '新对话',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ?? DateTime.now(),
      messages: (json['messages'] as List)
          .map((m) => ChatMessage.fromJson(m))
          .toList(),
      modelOverride: json['modelOverride'] as String?,
      baseUrlOverride: json['baseUrlOverride'] as String?,
      apiFormatOverride: json['apiFormatOverride'] as String?,
    );
  }
}

class ChatMessage {
  final String role;
  final List<MessageContent> content;
  final DateTime timestamp;

  ChatMessage({
    required this.role,
    required this.content,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  factory ChatMessage.user(String text) {
    return ChatMessage(
      role: 'user',
      content: [TextContent(text)],
    );
  }

  factory ChatMessage.assistant(List<Map<String, dynamic>> contentBlocks) {
    final content = contentBlocks.map((block) {
      switch (block['type']) {
        case 'text':
          return TextContent(block['text'] as String);
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
    return ChatMessage(role: 'assistant', content: content.cast<MessageContent>());
  }

  factory ChatMessage.toolResults(List<Map<String, dynamic>> results) {
    final content = results.map((r) => ToolResultContent(
      toolUseId: r['tool_use_id'] as String,
      output: r['content'] as String,
      isError: r['is_error'] as bool? ?? false,
    )).toList();
    return ChatMessage(role: 'user', content: content.cast<MessageContent>());
  }

  String get textContent {
    return content.whereType<TextContent>().map((c) => c.text).join('\n');
  }

  List<ToolUseContent> get toolUses => content.whereType<ToolUseContent>().toList();
  List<ToolResultContent> get toolResults => content.whereType<ToolResultContent>().toList();

  Map<String, dynamic> toApiJson() {
    if (content.length == 1 && content[0] is TextContent) {
      return {'role': role, 'content': (content[0] as TextContent).text};
    }
    return {
      'role': role,
      'content': content.map((c) => c.toApiJson()).toList(),
    };
  }

  Map<String, dynamic> toJson() => {
    'role': role,
    'timestamp': timestamp.toIso8601String(),
    'content': content.map((c) => c.toJson()).toList(),
  };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final contentList = json['content'] as List;
    final content = contentList.map((c) {
      final type = c['type'] as String;
      switch (type) {
        case 'text':
          return TextContent(c['text'] as String);
        case 'tool_use':
          return ToolUseContent(
            id: c['id'] as String,
            name: c['name'] as String,
            input: Map<String, dynamic>.from(c['input'] ?? {}),
          );
        case 'tool_result':
          return ToolResultContent(
            toolUseId: c['tool_use_id'] as String,
            output: c['output'] as String,
            isError: c['is_error'] as bool? ?? false,
          );
        default:
          return TextContent(c.toString());
      }
    }).toList();
    return ChatMessage(
      role: json['role'] as String,
      content: content.cast<MessageContent>(),
      timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ?? DateTime.now(),
    );
  }
}

sealed class MessageContent {
  Map<String, dynamic> toApiJson();
  Map<String, dynamic> toJson();
}

class TextContent extends MessageContent {
  final String text;
  TextContent(this.text);

  @override
  Map<String, dynamic> toApiJson() => {'type': 'text', 'text': text};

  @override
  Map<String, dynamic> toJson() => {'type': 'text', 'text': text};
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
  final String output;
  final bool isError;

  ToolResultContent({
    required this.toolUseId,
    required this.output,
    this.isError = false,
  });

  @override
  Map<String, dynamic> toApiJson() => {
    'type': 'tool_result',
    'tool_use_id': toolUseId,
    'content': output,
    if (isError) 'is_error': true,
  };

  @override
  Map<String, dynamic> toJson() => {
    'type': 'tool_result',
    'tool_use_id': toolUseId,
    'output': output,
    'is_error': isError,
  };
}
