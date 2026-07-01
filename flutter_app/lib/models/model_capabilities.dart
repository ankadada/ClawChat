enum ApiFormat { anthropic, openai }

enum ProviderKind {
  anthropicNative,
  openaiNative,
  anthropicCompatible,
  openRouter,
  groq,
  liteLlm,
  genericOpenAICompatible,
}

enum TokenLimitParameter {
  maxTokens,
  maxCompletionTokens,
}

extension TokenLimitParameterRequestKey on TokenLimitParameter {
  String get requestKey {
    return switch (this) {
      TokenLimitParameter.maxTokens => 'max_tokens',
      TokenLimitParameter.maxCompletionTokens => 'max_completion_tokens',
    };
  }
}

enum SystemPromptMode {
  topLevel,
  systemMessage,
  none,
}

enum StreamingUsageMode {
  none,
  nativeEvents,
  openAIStreamOptions,
}

class ProviderCapabilities {
  final ApiFormat apiFormat;
  final ProviderKind kind;
  final SystemPromptMode systemPromptMode;
  final TokenLimitParameter defaultTokenLimitParameter;
  final StreamingUsageMode streamingUsageMode;
  final bool defaultSupportsTools;
  final bool defaultSupportsImages;
  final bool defaultSupportsPromptCache;

  const ProviderCapabilities({
    required this.apiFormat,
    required this.kind,
    required this.systemPromptMode,
    required this.defaultTokenLimitParameter,
    required this.streamingUsageMode,
    this.defaultSupportsTools = true,
    this.defaultSupportsImages = true,
    this.defaultSupportsPromptCache = false,
  });
}

class ModelCapabilities {
  final bool supportsImages;
  final bool supportsTools;
  final bool supportsReasoningContent;
  final bool supportsPromptCache;
  final bool supportsSystemPrompt;
  final bool supportsStreamingUsage;
  final bool acceptsTemperature;
  final bool supportsThinkingBudget;
  final TokenLimitParameter tokenLimitParameter;
  final StreamingUsageMode streamingUsageMode;
  final int? maxContextTokens;
  final int? defaultOutputReserveTokens;

  const ModelCapabilities({
    this.supportsImages = true,
    this.supportsTools = true,
    this.supportsReasoningContent = false,
    this.supportsPromptCache = false,
    this.supportsSystemPrompt = true,
    this.supportsStreamingUsage = false,
    this.acceptsTemperature = true,
    this.supportsThinkingBudget = false,
    this.tokenLimitParameter = TokenLimitParameter.maxTokens,
    this.streamingUsageMode = StreamingUsageMode.none,
    this.maxContextTokens,
    this.defaultOutputReserveTokens,
  });

  ModelCapabilities copyWith({
    bool? supportsImages,
    bool? supportsTools,
    bool? supportsReasoningContent,
    bool? supportsPromptCache,
    bool? supportsSystemPrompt,
    bool? supportsStreamingUsage,
    bool? acceptsTemperature,
    bool? supportsThinkingBudget,
    TokenLimitParameter? tokenLimitParameter,
    StreamingUsageMode? streamingUsageMode,
    int? maxContextTokens,
    int? defaultOutputReserveTokens,
  }) {
    return ModelCapabilities(
      supportsImages: supportsImages ?? this.supportsImages,
      supportsTools: supportsTools ?? this.supportsTools,
      supportsReasoningContent:
          supportsReasoningContent ?? this.supportsReasoningContent,
      supportsPromptCache: supportsPromptCache ?? this.supportsPromptCache,
      supportsSystemPrompt: supportsSystemPrompt ?? this.supportsSystemPrompt,
      supportsStreamingUsage:
          supportsStreamingUsage ?? this.supportsStreamingUsage,
      acceptsTemperature: acceptsTemperature ?? this.acceptsTemperature,
      supportsThinkingBudget:
          supportsThinkingBudget ?? this.supportsThinkingBudget,
      tokenLimitParameter: tokenLimitParameter ?? this.tokenLimitParameter,
      streamingUsageMode: streamingUsageMode ?? this.streamingUsageMode,
      maxContextTokens: maxContextTokens ?? this.maxContextTokens,
      defaultOutputReserveTokens:
          defaultOutputReserveTokens ?? this.defaultOutputReserveTokens,
    );
  }
}

class ResolvedModelProfile {
  final String modelId;
  final String providerKey;
  final ProviderCapabilities provider;
  final ModelCapabilities capabilities;
  final CapabilityOverride? override;

  const ResolvedModelProfile({
    required this.modelId,
    required this.providerKey,
    required this.provider,
    required this.capabilities,
    this.override,
  });
}

class CapabilityOverride {
  final bool? supportsImages;
  final bool? supportsTools;
  final bool? supportsReasoningContent;
  final int? maxContextTokens;

  const CapabilityOverride({
    this.supportsImages,
    this.supportsTools,
    this.supportsReasoningContent,
    this.maxContextTokens,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CapabilityOverride &&
          supportsImages == other.supportsImages &&
          supportsTools == other.supportsTools &&
          supportsReasoningContent == other.supportsReasoningContent &&
          maxContextTokens == other.maxContextTokens;

  @override
  int get hashCode => Object.hash(
        supportsImages,
        supportsTools,
        supportsReasoningContent,
        maxContextTokens,
      );

  bool get isEmpty =>
      supportsImages == null &&
      supportsTools == null &&
      supportsReasoningContent == null &&
      maxContextTokens == null;

  ModelCapabilities applyTo(ModelCapabilities capabilities) {
    return capabilities.copyWith(
      supportsImages: supportsImages,
      supportsTools: supportsTools,
      supportsReasoningContent: supportsReasoningContent,
      maxContextTokens: maxContextTokens,
    );
  }

  Map<String, dynamic> toJson() => {
        if (supportsImages != null) 'supportsImages': supportsImages,
        if (supportsTools != null) 'supportsTools': supportsTools,
        if (supportsReasoningContent != null)
          'supportsReasoningContent': supportsReasoningContent,
        if (maxContextTokens != null) 'maxContextTokens': maxContextTokens,
      };

  factory CapabilityOverride.fromJson(Map<String, dynamic> json) {
    return CapabilityOverride(
      supportsImages: json['supportsImages'] is bool
          ? json['supportsImages'] as bool
          : null,
      supportsTools:
          json['supportsTools'] is bool ? json['supportsTools'] as bool : null,
      supportsReasoningContent: json['supportsReasoningContent'] is bool
          ? json['supportsReasoningContent'] as bool
          : null,
      maxContextTokens: _positiveIntOrNull(json['maxContextTokens']),
    );
  }

  static int? _positiveIntOrNull(Object? value) {
    final parsed = value is int
        ? value
        : value is num
            ? value.round()
            : int.tryParse(value?.toString() ?? '');
    if (parsed == null || parsed <= 0) return null;
    return parsed;
  }
}
