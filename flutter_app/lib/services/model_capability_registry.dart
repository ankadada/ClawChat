import 'package:shared_preferences/shared_preferences.dart';

import '../models/model_capabilities.dart';

class CapabilityRegistry {
  static const instance = CapabilityRegistry();
  static const streamUsageUnsupportedHostsPrefsKey =
      'stream_usage_unsupported_hosts';
  static const _presetModelSuffix = ' (preset)';
  static const _maxTokenLimitOverrides = 50;

  static final Set<String> _streamUsageUnsupportedHosts = {};
  static final Map<String, TokenLimitParameter> _tokenLimitOverrides = {};
  static final Set<String> _requiresReasoningContent = {};
  static final Set<String> _disablesReasoningContent = {};

  const CapabilityRegistry();

  ResolvedModelProfile resolve({
    required ApiFormat apiFormat,
    required String baseUrl,
    required String model,
  }) {
    final modelId = modelIdFromDisplay(model);
    final provider = _providerCapabilities(apiFormat, baseUrl);
    final providerKey = _providerKey(apiFormat, baseUrl);
    final compatibilityKey = _compatibilityKey(
      apiFormat: apiFormat,
      baseUrl: baseUrl,
      modelId: modelId,
    );

    var capabilities = _modelCapabilities(
      provider: provider,
      baseUrl: baseUrl,
      modelId: modelId,
    );

    final tokenOverride = _tokenLimitOverrides[compatibilityKey];
    if (tokenOverride != null) {
      capabilities = capabilities.copyWith(tokenLimitParameter: tokenOverride);
    }
    if (_disablesReasoningContent.contains(compatibilityKey)) {
      capabilities = capabilities.copyWith(supportsReasoningContent: false);
    } else if (_requiresReasoningContent.contains(compatibilityKey)) {
      capabilities = capabilities.copyWith(supportsReasoningContent: true);
    }
    if (capabilities.streamingUsageMode ==
            StreamingUsageMode.openAIStreamOptions &&
        _streamUsageUnsupportedHosts
            .contains(_normalizedBaseUrlHost(baseUrl))) {
      capabilities = capabilities.copyWith(
        streamingUsageMode: StreamingUsageMode.none,
        supportsStreamingUsage: false,
      );
    }

    return ResolvedModelProfile(
      modelId: modelId,
      providerKey: providerKey,
      provider: provider,
      capabilities: capabilities,
    );
  }

  Future<bool> supportsOpenAIStreamUsage(
    ResolvedModelProfile profile,
  ) async {
    if (profile.capabilities.streamingUsageMode !=
        StreamingUsageMode.openAIStreamOptions) {
      return false;
    }
    await _loadStreamUsageUnsupportedHosts();
    final host = _hostFromProviderKey(profile.providerKey);
    return host.isEmpty || !_streamUsageUnsupportedHosts.contains(host);
  }

  Future<void> markOpenAIStreamUsageUnsupported(String baseUrl) async {
    final host = _normalizedBaseUrlHost(baseUrl);
    if (host.isEmpty) return;
    _streamUsageUnsupportedHosts.add(host);
    try {
      final prefs = await SharedPreferences.getInstance();
      final unsupported =
          prefs.getStringList(streamUsageUnsupportedHostsPrefsKey) ?? const [];
      if (unsupported.contains(host)) return;
      await prefs.setStringList(
        streamUsageUnsupportedHostsPrefsKey,
        [...unsupported, host],
      );
    } catch (_) {
      // SharedPreferences may be unavailable in pure Dart tests. The in-memory
      // fallback still prevents repeat failures in the current process.
    }
  }

  void markTokenLimitParameterOverride({
    required ApiFormat apiFormat,
    required String baseUrl,
    required String modelId,
    required TokenLimitParameter parameter,
  }) {
    _tokenLimitOverrides[_compatibilityKey(
      apiFormat: apiFormat,
      baseUrl: baseUrl,
      modelId: modelIdFromDisplay(modelId),
    )] = parameter;
    _pruneTokenLimitOverrides();
  }

  void markRequiresReasoningContent({
    required ApiFormat apiFormat,
    required String baseUrl,
    required String modelId,
  }) {
    final key = _compatibilityKey(
      apiFormat: apiFormat,
      baseUrl: baseUrl,
      modelId: modelIdFromDisplay(modelId),
    );
    _disablesReasoningContent.remove(key);
    _requiresReasoningContent.add(key);
  }

  void markDisablesReasoningContent({
    required ApiFormat apiFormat,
    required String baseUrl,
    required String modelId,
  }) {
    final key = _compatibilityKey(
      apiFormat: apiFormat,
      baseUrl: baseUrl,
      modelId: modelIdFromDisplay(modelId),
    );
    _requiresReasoningContent.remove(key);
    _disablesReasoningContent.add(key);
  }

  void clearTokenLimitOverrides() {
    _tokenLimitOverrides.clear();
  }

  void clearReasoningContentOverrides() {
    _requiresReasoningContent.clear();
    _disablesReasoningContent.clear();
  }

  void clearRuntimeOverridesForTesting() {
    _streamUsageUnsupportedHosts.clear();
    _tokenLimitOverrides.clear();
    _requiresReasoningContent.clear();
    _disablesReasoningContent.clear();
  }

  void clearStreamUsageUnsupportedHostsForTesting() {
    _streamUsageUnsupportedHosts.clear();
  }

  static String modelIdFromDisplay(String model) {
    return model.endsWith(_presetModelSuffix)
        ? model.substring(0, model.length - _presetModelSuffix.length)
        : model;
  }

  static bool isReasoningModelId(String model) {
    final m = modelIdFromDisplay(model).toLowerCase();
    return m.startsWith('o1') ||
        m.startsWith('o3') ||
        m.startsWith('o4') ||
        m.contains('gpt-5') ||
        m.contains('deepseek-reasoner') ||
        m.contains('deepseek-r1') ||
        m.contains('reasoner') ||
        RegExp(r'(^|[/:._-])r1($|[/:._-])').hasMatch(m) ||
        m.contains('reasoning');
  }

  ProviderCapabilities _providerCapabilities(
    ApiFormat apiFormat,
    String baseUrl,
  ) {
    if (apiFormat == ApiFormat.anthropic) {
      return const ProviderCapabilities(
        apiFormat: ApiFormat.anthropic,
        kind: ProviderKind.anthropicNative,
        systemPromptMode: SystemPromptMode.topLevel,
        defaultTokenLimitParameter: TokenLimitParameter.maxTokens,
        streamingUsageMode: StreamingUsageMode.nativeEvents,
      );
    }

    final lowerBaseUrl = baseUrl.toLowerCase();
    if (lowerBaseUrl.contains('anthropic') || lowerBaseUrl.contains('claude')) {
      return const ProviderCapabilities(
        apiFormat: ApiFormat.openai,
        kind: ProviderKind.anthropicCompatible,
        systemPromptMode: SystemPromptMode.systemMessage,
        defaultTokenLimitParameter: TokenLimitParameter.maxCompletionTokens,
        streamingUsageMode: StreamingUsageMode.openAIStreamOptions,
      );
    }
    if (lowerBaseUrl.contains('openai.com')) {
      return const ProviderCapabilities(
        apiFormat: ApiFormat.openai,
        kind: ProviderKind.openaiNative,
        systemPromptMode: SystemPromptMode.systemMessage,
        defaultTokenLimitParameter: TokenLimitParameter.maxCompletionTokens,
        streamingUsageMode: StreamingUsageMode.openAIStreamOptions,
      );
    }
    if (lowerBaseUrl.contains('openrouter')) {
      return const ProviderCapabilities(
        apiFormat: ApiFormat.openai,
        kind: ProviderKind.openRouter,
        systemPromptMode: SystemPromptMode.systemMessage,
        defaultTokenLimitParameter: TokenLimitParameter.maxCompletionTokens,
        streamingUsageMode: StreamingUsageMode.openAIStreamOptions,
      );
    }
    if (lowerBaseUrl.contains('groq.com')) {
      return const ProviderCapabilities(
        apiFormat: ApiFormat.openai,
        kind: ProviderKind.groq,
        systemPromptMode: SystemPromptMode.systemMessage,
        defaultTokenLimitParameter: TokenLimitParameter.maxCompletionTokens,
        streamingUsageMode: StreamingUsageMode.openAIStreamOptions,
      );
    }
    if (lowerBaseUrl.contains('litellm')) {
      return const ProviderCapabilities(
        apiFormat: ApiFormat.openai,
        kind: ProviderKind.liteLlm,
        systemPromptMode: SystemPromptMode.systemMessage,
        defaultTokenLimitParameter: TokenLimitParameter.maxCompletionTokens,
        streamingUsageMode: StreamingUsageMode.openAIStreamOptions,
      );
    }
    return const ProviderCapabilities(
      apiFormat: ApiFormat.openai,
      kind: ProviderKind.genericOpenAICompatible,
      systemPromptMode: SystemPromptMode.systemMessage,
      defaultTokenLimitParameter: TokenLimitParameter.maxTokens,
      streamingUsageMode: StreamingUsageMode.openAIStreamOptions,
    );
  }

  ModelCapabilities _modelCapabilities({
    required ProviderCapabilities provider,
    required String baseUrl,
    required String modelId,
  }) {
    final reasoningModel = isReasoningModelId(modelId);
    final streamingUsageMode = provider.streamingUsageMode;
    return ModelCapabilities(
      supportsImages: _supportsImages(modelId),
      supportsTools: provider.defaultSupportsTools,
      supportsReasoningContent: _supportsRequestReasoningContent(
        provider: provider,
        baseUrl: baseUrl,
        modelId: modelId,
      ),
      // P8a is conservative: cache_control remains stripped by the provider
      // transform until a later phase adds a narrow provider-safe whitelist.
      supportsPromptCache: false,
      supportsSystemPrompt: provider.systemPromptMode != SystemPromptMode.none,
      supportsStreamingUsage: streamingUsageMode != StreamingUsageMode.none,
      acceptsTemperature: !reasoningModel,
      supportsThinkingBudget: provider.kind == ProviderKind.anthropicNative ||
          provider.kind == ProviderKind.anthropicCompatible,
      tokenLimitParameter: reasoningModel
          ? TokenLimitParameter.maxCompletionTokens
          : provider.defaultTokenLimitParameter,
      streamingUsageMode: streamingUsageMode,
      maxContextTokens: _maxContextTokensForModel(modelId),
    );
  }

  bool _supportsImages(String modelId) {
    final model = modelId.toLowerCase();
    if (model == 'deepseek-reasoner' ||
        model == 'deepseek-r1' ||
        model == 'r1' ||
        model.startsWith('r1-') ||
        model.contains('deepseek-r1') ||
        model.contains('deepseek-reasoner') ||
        model.contains('coder') ||
        model.contains('codex')) {
      return false;
    }
    return true;
  }

  bool _supportsRequestReasoningContent({
    required ProviderCapabilities provider,
    required String baseUrl,
    required String modelId,
  }) {
    if (provider.apiFormat != ApiFormat.openai) return false;
    if (baseUrl.toLowerCase().contains('openai.com')) return false;
    if (provider.kind == ProviderKind.anthropicCompatible) return false;

    final model = modelId.toLowerCase();
    final isKnownDeepSeekReasoning =
        model == 'deepseek-reasoner' || model == 'deepseek-r1';
    final isDeepSeekReasoningFamily = model.contains('deepseek') &&
        (model.contains('reasoner') ||
            RegExp(r'(^|[/:._-])r1($|[/:._-])').hasMatch(model));
    final isBareR1 = model == 'r1' || model.startsWith('r1-');
    return isKnownDeepSeekReasoning || isDeepSeekReasoningFamily || isBareR1;
  }

  int? _maxContextTokensForModel(String modelId) {
    final model = modelId.toLowerCase();
    if (model.contains('200k') || model.startsWith('claude-')) return 200000;
    if (model.contains('128k')) return 128000;
    if (model.contains('64k')) return 65536;
    if (model.contains('32k')) return 32768;
    if (model.contains('16k')) return 16384;
    if (model.contains('8k')) return 8192;
    return null;
  }

  Future<void> _loadStreamUsageUnsupportedHosts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final unsupported =
          prefs.getStringList(streamUsageUnsupportedHostsPrefsKey) ?? const [];
      _streamUsageUnsupportedHosts.addAll(unsupported);
    } catch (_) {
      // SharedPreferences may be unavailable in pure Dart tests.
    }
  }

  static String _compatibilityKey({
    required ApiFormat apiFormat,
    required String baseUrl,
    required String modelId,
  }) {
    return '${apiFormat.name}|${baseUrl.trim().replaceFirst(RegExp(r'/+$'), '')}|$modelId';
  }

  static String _providerKey(ApiFormat apiFormat, String baseUrl) {
    return '${apiFormat.name}|${_normalizedBaseUrlHost(baseUrl)}';
  }

  static String _hostFromProviderKey(String providerKey) {
    final parts = providerKey.split('|');
    return parts.length > 1 ? parts[1] : '';
  }

  static String _normalizedBaseUrlHost(String baseUrl) {
    final uri = Uri.tryParse(baseUrl.trim());
    final host = uri?.host;
    if (host != null && host.isNotEmpty) return host.toLowerCase();
    return '';
  }

  static void _pruneTokenLimitOverrides() {
    if (_tokenLimitOverrides.length <= _maxTokenLimitOverrides) return;
    final removeCount = _tokenLimitOverrides.length ~/ 2;
    final keysToRemove = _tokenLimitOverrides.keys.take(removeCount).toList();
    for (final key in keysToRemove) {
      _tokenLimitOverrides.remove(key);
    }
  }
}
