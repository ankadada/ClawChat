class McpServerConfig {
  final String id;
  final String displayName;
  final bool enabled;
  final String command;
  final List<String> args;
  final Map<String, String> env;

  const McpServerConfig({
    required this.id,
    required this.displayName,
    required this.enabled,
    required this.command,
    this.args = const [],
    this.env = const {},
  });

  McpServerConfig copyWith({
    String? id,
    String? displayName,
    bool? enabled,
    String? command,
    List<String>? args,
    Map<String, String>? env,
  }) {
    return McpServerConfig(
      id: id ?? this.id,
      displayName: displayName ?? this.displayName,
      enabled: enabled ?? this.enabled,
      command: command ?? this.command,
      args: args ?? this.args,
      env: env ?? this.env,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'displayName': displayName,
        'enabled': enabled,
        'command': command,
        'args': args,
        'env': env,
      };

  factory McpServerConfig.fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString().trim();
    final displayName = json['displayName']?.toString().trim();
    final command = json['command']?.toString().trim();
    if (id == null ||
        id.isEmpty ||
        displayName == null ||
        displayName.isEmpty ||
        command == null ||
        command.isEmpty) {
      throw const FormatException('Invalid MCP server config');
    }

    final rawArgs = json['args'];
    final rawEnv = json['env'];
    return McpServerConfig(
      id: id,
      displayName: displayName,
      enabled: json['enabled'] != false,
      command: command,
      args: rawArgs is List
          ? rawArgs
              .map((value) => value?.toString() ?? '')
              .where((value) => value.isNotEmpty)
              .toList(growable: false)
          : const [],
      env: normalizeEnv(_envFromJson(rawEnv)),
    );
  }

  static bool isValidEnvKey(String key) {
    return RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(key);
  }

  static Map<String, String> normalizeEnv(Map<String, String> env) {
    final result = <String, String>{};
    for (final entry in env.entries) {
      final key = entry.key.trim();
      if (key.isEmpty || !isValidEnvKey(key)) continue;
      result[key] = entry.value;
    }
    return result;
  }

  static Map<String, String> _envFromJson(Object? rawEnv) {
    if (rawEnv is! Map) return const {};
    final env = rawEnv.map<String, String>(
      (key, value) => MapEntry(
        key.toString().trim(),
        value?.toString() ?? '',
      ),
    );
    env.removeWhere((key, _) => key.isEmpty);
    return env;
  }
}
