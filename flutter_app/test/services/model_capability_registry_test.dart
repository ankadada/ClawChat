import 'package:clawchat/models/model_capabilities.dart';
import 'package:clawchat/services/model_capability_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const registry = CapabilityRegistry.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    registry.clearRuntimeOverridesForTesting();
  });

  test('resolves Anthropic native capabilities', () {
    final profile = registry.resolve(
      apiFormat: ApiFormat.anthropic,
      baseUrl: 'https://api.anthropic.com',
      model: 'claude-sonnet-4-20250514',
    );

    expect(profile.modelId, 'claude-sonnet-4-20250514');
    expect(profile.provider.kind, ProviderKind.anthropicNative);
    expect(profile.provider.systemPromptMode, SystemPromptMode.topLevel);
    expect(profile.capabilities.supportsImages, isTrue);
    expect(profile.capabilities.supportsTools, isTrue);
    expect(profile.capabilities.supportsSystemPrompt, isTrue);
    expect(profile.capabilities.supportsStreamingUsage, isTrue);
    expect(profile.capabilities.streamingUsageMode,
        StreamingUsageMode.nativeEvents);
    expect(profile.capabilities.tokenLimitParameter,
        TokenLimitParameter.maxTokens);
    expect(profile.capabilities.maxContextTokens, 200000);
  });

  test(
      'OpenAI native reasoning family uses completion tokens without '
      'temperature or request-side reasoning_content', () {
    final profile = registry.resolve(
      apiFormat: ApiFormat.openai,
      baseUrl: 'https://api.openai.com',
      model: 'gpt-5.5',
    );

    expect(profile.provider.kind, ProviderKind.openaiNative);
    expect(profile.capabilities.tokenLimitParameter,
        TokenLimitParameter.maxCompletionTokens);
    expect(profile.capabilities.acceptsTemperature, isFalse);
    expect(profile.capabilities.supportsReasoningContent, isFalse);
    expect(profile.capabilities.supportsStreamingUsage, isTrue);
    expect(profile.capabilities.streamingUsageMode,
        StreamingUsageMode.openAIStreamOptions);
  });

  test(
      'DeepSeek and bare R1 support request-side reasoning_content and '
      'disable images', () {
    final deepSeek = registry.resolve(
      apiFormat: ApiFormat.openai,
      baseUrl: 'https://api.deepseek.com',
      model: 'deepseek-reasoner',
    );
    final r1 = registry.resolve(
      apiFormat: ApiFormat.openai,
      baseUrl: 'https://example.com/v1',
      model: 'r1',
    );

    for (final profile in [deepSeek, r1]) {
      expect(profile.capabilities.supportsReasoningContent, isTrue);
      expect(profile.capabilities.supportsImages, isFalse);
      expect(profile.capabilities.tokenLimitParameter,
          TokenLimitParameter.maxCompletionTokens);
    }
  });

  test('reasoning_content runtime overrides are scoped by endpoint and model',
      () {
    const firstBaseUrl = 'https://proxy.example.com/v1';
    const secondBaseUrl = 'https://other.example.com/v1';

    expect(
      registry
          .resolve(
            apiFormat: ApiFormat.openai,
            baseUrl: firstBaseUrl,
            model: 'gpt-test',
          )
          .capabilities
          .supportsReasoningContent,
      isFalse,
    );

    registry.markRequiresReasoningContent(
      apiFormat: ApiFormat.openai,
      baseUrl: firstBaseUrl,
      modelId: 'gpt-test',
    );

    expect(
      registry
          .resolve(
            apiFormat: ApiFormat.openai,
            baseUrl: firstBaseUrl,
            model: 'gpt-test',
          )
          .capabilities
          .supportsReasoningContent,
      isTrue,
    );
    expect(
      registry
          .resolve(
            apiFormat: ApiFormat.openai,
            baseUrl: firstBaseUrl,
            model: 'other-model',
          )
          .capabilities
          .supportsReasoningContent,
      isFalse,
    );
    expect(
      registry
          .resolve(
            apiFormat: ApiFormat.openai,
            baseUrl: secondBaseUrl,
            model: 'gpt-test',
          )
          .capabilities
          .supportsReasoningContent,
      isFalse,
    );

    registry.markDisablesReasoningContent(
      apiFormat: ApiFormat.openai,
      baseUrl: firstBaseUrl,
      modelId: 'gpt-test',
    );

    expect(
      registry
          .resolve(
            apiFormat: ApiFormat.openai,
            baseUrl: firstBaseUrl,
            model: 'gpt-test',
          )
          .capabilities
          .supportsReasoningContent,
      isFalse,
    );
  });

  test('coder and codex model families disable images', () {
    final coder = registry.resolve(
      apiFormat: ApiFormat.openai,
      baseUrl: 'https://example.com/v1',
      model: 'qwen-coder',
    );
    final codex = registry.resolve(
      apiFormat: ApiFormat.openai,
      baseUrl: 'https://example.com/v1',
      model: 'codex/gpt-5.5',
    );

    expect(coder.capabilities.supportsImages, isFalse);
    expect(codex.capabilities.supportsImages, isFalse);
  });

  test('custom model ids remain distinct from similarly named base models', () {
    final codex = registry.resolve(
      apiFormat: ApiFormat.openai,
      baseUrl: 'https://example.com/v1',
      model: 'codex/gpt-5.5',
    );
    final openAI = registry.resolve(
      apiFormat: ApiFormat.openai,
      baseUrl: 'https://example.com/v1',
      model: 'gpt-5.5',
    );

    expect(codex.modelId, 'codex/gpt-5.5');
    expect(openAI.modelId, 'gpt-5.5');
    expect(codex.capabilities.supportsImages, isFalse);
    expect(openAI.capabilities.supportsImages, isTrue);
  });

  test('capability override applies after model defaults', () {
    final profile = registry.resolve(
      apiFormat: ApiFormat.openai,
      baseUrl: 'https://example.com/v1',
      model: 'codex/gpt-5.5',
      override: const CapabilityOverride(
        supportsImages: true,
        supportsTools: false,
        supportsReasoningContent: true,
        maxContextTokens: 123456,
      ),
    );

    expect(profile.override?.supportsImages, isTrue);
    expect(profile.capabilities.supportsImages, isTrue);
    expect(profile.capabilities.supportsTools, isFalse);
    expect(profile.capabilities.supportsReasoningContent, isTrue);
    expect(profile.capabilities.maxContextTokens, 123456);
  });

  test('OpenRouter Groq and LiteLLM preserve max_completion_tokens default',
      () {
    final openRouter = registry.resolve(
      apiFormat: ApiFormat.openai,
      baseUrl: 'https://openrouter.ai/api/v1',
      model: 'gpt-test',
    );
    final groq = registry.resolve(
      apiFormat: ApiFormat.openai,
      baseUrl: 'https://api.groq.com/openai/v1',
      model: 'gpt-test',
    );
    final liteLlm = registry.resolve(
      apiFormat: ApiFormat.openai,
      baseUrl: 'https://proxy.example.com/litellm/v1',
      model: 'gpt-test',
    );

    expect(openRouter.provider.kind, ProviderKind.openRouter);
    expect(groq.provider.kind, ProviderKind.groq);
    expect(liteLlm.provider.kind, ProviderKind.liteLlm);
    for (final profile in [openRouter, groq, liteLlm]) {
      expect(profile.capabilities.tokenLimitParameter,
          TokenLimitParameter.maxCompletionTokens);
    }
  });

  test('stream usage unsupported runtime fallback disables stream_options',
      () async {
    const baseUrl = 'https://proxy.example.com/v1';
    final before = registry.resolve(
      apiFormat: ApiFormat.openai,
      baseUrl: baseUrl,
      model: 'gpt-test',
    );

    expect(await registry.supportsOpenAIStreamUsage(before), isTrue);

    await registry.markOpenAIStreamUsageUnsupported(baseUrl);
    final after = registry.resolve(
      apiFormat: ApiFormat.openai,
      baseUrl: baseUrl,
      model: 'gpt-test',
    );

    expect(after.capabilities.supportsStreamingUsage, isFalse);
    expect(after.capabilities.streamingUsageMode, StreamingUsageMode.none);
    expect(await registry.supportsOpenAIStreamUsage(after), isFalse);
  });
}
