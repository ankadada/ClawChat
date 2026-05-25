class AppConstants {
  static const String appName = 'ClawChat';
  static const String version = '2.3.0';
  static const String packageName = 'com.anka.clawbot';

  static final ansiEscape = RegExp(r'\x1b\[[0-9;]*[a-zA-Z]');

  static const String authorName = 'ClawChat Team';
  static const String githubUrl = 'https://github.com/ankadada/ClawChat';
  static const String license = 'GPL-3.0';

  // ── Alpine minirootfs URL ──────────────────────────────────────
  static const String alpineVersion = '3.21.3';
  static const String alpineBaseUrl =
      'https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/';

  static const String rootfsArm64 =
      '${alpineBaseUrl}aarch64/alpine-minirootfs-$alpineVersion-aarch64.tar.gz';
  static const String rootfsArmhf =
      '${alpineBaseUrl}armv7/alpine-minirootfs-$alpineVersion-armv7.tar.gz';
  static const String rootfsAmd64 =
      '${alpineBaseUrl}x86_64/alpine-minirootfs-$alpineVersion-x86_64.tar.gz';

  // ── MethodChannel ──────────────────────────────────────────────
  static const String channelName = 'com.anka.clawbot/native';

  // ── Agent 默认配置 ─────────────────────────────────────────────
  static const String defaultModel = 'claude-sonnet-4-20250514';
  static const int defaultMaxTokens = 8192;
  static const int defaultContextLength = 100000;
  static const double defaultTemperature = 0.7;
  static const String defaultSystemPrompt =
      'You are a helpful AI assistant with access to tools. '
      'You run inside an Alpine Linux environment on an Android device. '
      'You can execute shell commands, read/write files, and fetch web pages.';

  static String getRootfsUrl(String arch) {
    switch (arch) {
      case 'aarch64':
        return rootfsArm64;
      case 'arm':
        return rootfsArmhf;
      case 'x86_64':
        return rootfsAmd64;
      default:
        return rootfsArm64;
    }
  }
}
