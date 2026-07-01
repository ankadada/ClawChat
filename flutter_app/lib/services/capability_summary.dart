import '../models/model_capabilities.dart';
import '../models/provider_profile.dart';
import 'model_capability_registry.dart';

class CapabilitySummary {
  final ResolvedModelProfile resolvedProfile;

  const CapabilitySummary(this.resolvedProfile);

  factory CapabilitySummary.resolve(ProviderProfile profile) {
    final apiFormat = profile.apiFormat == ProviderProfile.openaiFormat
        ? ApiFormat.openai
        : ApiFormat.anthropic;
    final baseUrl = profile.baseUrl.trim().isNotEmpty
        ? profile.baseUrl.trim()
        : _defaultBaseUrl(apiFormat);
    return CapabilitySummary(CapabilityRegistry.instance.resolve(
      apiFormat: apiFormat,
      baseUrl: baseUrl,
      model: profile.effectiveModel,
      override: profile.capabilityOverride,
    ));
  }

  String get modelId => resolvedProfile.modelId;

  String get providerLabel {
    return switch (resolvedProfile.provider.kind) {
      ProviderKind.anthropicNative => 'Anthropic',
      ProviderKind.openaiNative => 'OpenAI',
      ProviderKind.anthropicCompatible => 'Claude-compatible',
      ProviderKind.openRouter => 'OpenRouter',
      ProviderKind.groq => 'Groq',
      ProviderKind.liteLlm => 'LiteLLM',
      ProviderKind.genericOpenAICompatible => 'OpenAI-compatible',
    };
  }

  List<String> get chips {
    final caps = resolvedProfile.capabilities;
    return [
      contextLabel,
      caps.supportsImages ? 'Images' : 'Text only',
      caps.supportsTools ? 'Tools' : 'No tools',
      caps.supportsReasoningContent || caps.supportsThinkingBudget
          ? 'Reasoning'
          : 'No reasoning',
    ];
  }

  String get contextLabel {
    final tokens = resolvedProfile.capabilities.maxContextTokens;
    if (tokens == null) return 'Context unknown';
    if (tokens >= 1000) return '${tokens ~/ 1000}K context';
    return '$tokens context';
  }

  String get detailLabel {
    final caps = resolvedProfile.capabilities;
    final features = <String>[
      providerLabel,
      'model ${resolvedProfile.modelId}',
      contextLabel,
      caps.supportsImages ? 'image input' : 'text-only',
      caps.supportsTools ? 'tool calls' : 'tool calls off',
      caps.supportsReasoningContent
          ? 'request reasoning_content'
          : caps.supportsThinkingBudget
              ? 'thinking budget'
              : 'reasoning off',
    ];
    if (resolvedProfile.override?.isEmpty == false) {
      features.add('custom override');
    }
    return features.join(' · ');
  }

  static String _defaultBaseUrl(ApiFormat apiFormat) {
    return apiFormat == ApiFormat.anthropic
        ? 'https://api.anthropic.com'
        : 'https://api.openai.com';
  }
}
