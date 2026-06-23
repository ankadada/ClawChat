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

  const ResolvedModelProfile({
    required this.modelId,
    required this.providerKey,
    required this.provider,
    required this.capabilities,
  });
}
