class PromptCacheSettings {
  static bool _anthropicPromptCacheEnabled = true;

  static bool get anthropicPromptCacheEnabled => _anthropicPromptCacheEnabled;

  static void setAnthropicPromptCacheEnabledForProcess(bool value) {
    _anthropicPromptCacheEnabled = value;
  }
}
