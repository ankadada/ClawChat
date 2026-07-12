import '../models/extension_manifest.dart';
import 'skill_service.dart';
import 'tools/tool_policy.dart';

typedef GrantedSkillLoader = Future<VerifiedSkillUse> Function(String id);

class SkillCapabilityViolation implements Exception {
  final String ruleId;
  final String message;

  const SkillCapabilityViolation(this.ruleId, this.message);

  @override
  String toString() => message;
}

/// Per-agent-run, fail-closed capability context.
///
/// The first verified load_skill activation binds this run to that exact grant. The
/// policy then remains an additional boundary in front of the global
/// [ToolPolicy]; it never turns a global denial or approval prompt into an
/// allow.
class SkillCapabilityPolicy {
  final GrantedSkillLoader _loader;
  final Map<String, String> fixedToolDomains;
  VerifiedSkillUse? _activeSkill;
  bool _historicalRestoreFailed = false;

  SkillCapabilityPolicy({
    GrantedSkillLoader? loader,
    this.fixedToolDomains = const {
      'web_search': 'html.duckduckgo.com',
    },
  }) : _loader = loader ?? SkillService.loadGrantedSkillById;

  VerifiedSkillUse? get activeSkill => _activeSkill;

  Future<VerifiedSkillUse?> prepareSkillActivation(
    ToolApprovalRequest request,
  ) async {
    if (request.toolName != 'load_skill') return null;
    final id = request.arguments['id'];
    if (id is! String || id.isEmpty) {
      throw const SkillCapabilityViolation(
        'skill_id_invalid',
        'Skill activation requires a valid stable ID.',
      );
    }
    final verified = await _loader(id);
    final active = _activeSkill;
    if (active != null && active.id != verified.id) {
      throw const SkillCapabilityViolation(
        'skill_context_switch',
        'A run already bound to one skill cannot switch skill capability context.',
      );
    }
    if (active != null && active.trustDigest != verified.trustDigest) {
      throw const SkillCapabilityViolation(
        'skill_grant_changed',
        'The active skill changed and requires consent again.',
      );
    }
    return verified;
  }

  void activate(VerifiedSkillUse verified) {
    final active = _activeSkill;
    if (active != null &&
        (active.id != verified.id ||
            active.trustDigest != verified.trustDigest)) {
      throw const SkillCapabilityViolation(
        'skill_context_changed',
        'Skill capability context changed during the run.',
      );
    }
    _activeSkill = verified;
    _historicalRestoreFailed = false;
  }

  void markHistoricalRestoreFailed() {
    _activeSkill = null;
    _historicalRestoreFailed = true;
  }

  Future<VerifiedSkillUse> restoreGrantedSkill(
    String id, {
    String? expectedTrustDigest,
  }) async {
    final verified = await _loader(id);
    if (expectedTrustDigest != null &&
        expectedTrustDigest != verified.trustDigest) {
      throw const SkillCapabilityViolation(
        'skill_history_stale',
        'Historical skill grant is stale.',
      );
    }
    activate(verified);
    return verified;
  }

  ToolDenyDecision? denyFor(ToolApprovalRequest request) {
    final active = _activeSkill;
    if (request.toolName == 'load_skill') return null;
    if (_referencesSkillStorage(request.arguments)) {
      return _deny(
        'skill_entrypoint_bypass',
        'Installed skill files may only be loaded through verified load_skill activation.',
      );
    }
    if (_historicalRestoreFailed) {
      return _deny(
        'skill_history_stale',
        'Historical skill consent is stale; reactivate the skill before tools can run.',
      );
    }
    if (active == null) return null;

    final capabilities = active.capabilities;
    if (!capabilities.tools.contains(request.toolName)) {
      return _deny(
        'skill_tool_undeclared',
        'Skill ${active.id} did not declare tool ${request.toolName}.',
      );
    }

    return switch (request.toolName) {
      'read_file' || 'write_file' => _deny(
          'skill_filesystem_unenforceable',
          'Skill-scoped filesystem access is disabled because the current '
              'native bridge cannot guarantee race-free confinement against '
              'concurrent proot filesystem mutation.',
        ),
      'web_fetch' => _checkUrl(
          request.arguments['url'],
          capabilities.networkDomains,
        ),
      'web_search' || 'generate_image' => _checkFixedNetworkTool(
          request.toolName,
          capabilities.networkDomains,
          capabilities.secretNames,
        ),
      'set_env_var' => _checkSecretName(
          request.arguments['name'],
          capabilities.secretNames,
        ),
      'phone_intent' => _checkAndroid(
          request.arguments['action'],
          request.arguments['params'],
          capabilities,
        ),
      'bash' => _checkBash(request.arguments, capabilities),
      _ when request.toolName.startsWith('mcp_') => _deny(
          'skill_mcp_unenforceable',
          'MCP tools are unavailable inside a skill capability context in P0.',
        ),
      _ => null,
    };
  }

  ToolDenyDecision? _checkUrl(dynamic rawUrl, List<String> domains) {
    if (rawUrl is! String) {
      return _deny('skill_network_invalid', 'Skill network URL is invalid.');
    }
    final uri = Uri.tryParse(rawUrl);
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme.toLowerCase()) ||
        uri.host.isEmpty ||
        !_domainAllowed(uri.host, domains)) {
      return _deny(
        'skill_network_domain',
        'Skill did not declare this network domain.',
      );
    }
    return null;
  }

  ToolDenyDecision? _checkFixedNetworkTool(
    String toolName,
    List<String> domains,
    List<String> secrets,
  ) {
    final domain = fixedToolDomains[toolName];
    if (domain == null || !_domainAllowed(domain, domains)) {
      return _deny(
        'skill_network_domain',
        'Skill did not declare the configured domain for $toolName.',
      );
    }
    if (toolName == 'generate_image' && !secrets.contains('OPENAI_API_KEY')) {
      return _deny(
        'skill_secret_undeclared',
        'Skill did not declare OPENAI_API_KEY for image generation.',
      );
    }
    return null;
  }

  ToolDenyDecision? _checkSecretName(dynamic rawName, List<String> secrets) {
    if (rawName is! String || !secrets.contains(rawName.toUpperCase())) {
      return _deny(
        'skill_secret_undeclared',
        'Skill did not declare this secret name.',
      );
    }
    return null;
  }

  ToolDenyDecision? _checkAndroid(
    dynamic rawAction,
    dynamic rawParams,
    ExtensionCapabilitySnapshot capabilities,
  ) {
    if (rawAction is! String || rawAction.isEmpty) {
      return _deny('skill_android_invalid', 'Skill Android action is invalid.');
    }
    final requirement = _androidRequirements[rawAction];
    if (requirement == null) {
      return _deny(
        'skill_android_unsupported',
        'Skill Android action has no enforceable declaration mapping.',
      );
    }
    final declared = requirement.permission
        ? capabilities.androidPermissions
        : capabilities.androidIntents;
    if (!declared.contains(requirement.name)) {
      return _deny(
        'skill_android_undeclared',
        'Skill did not declare the Android capability for $rawAction.',
      );
    }
    if (rawAction == 'openWeb') {
      final params = rawParams is Map ? rawParams : const {};
      return _checkUrl(params['url'], capabilities.networkDomains);
    }
    return null;
  }

  ToolDenyDecision? _checkBash(
    Map<String, dynamic> arguments,
    ExtensionCapabilitySnapshot capabilities,
  ) {
    if (!capabilities.subprocessRequired) {
      return _deny(
        'skill_subprocess_undeclared',
        'Skill did not declare subprocess use.',
      );
    }
    final command = arguments['command'];
    if (command is! String ||
        command.trim().isEmpty ||
        command.length > 10000) {
      return _deny('skill_command_invalid', 'Skill command is invalid.');
    }
    if (RegExp(r'[\n\r`;&|<>*?\[\]{}]|\$\(').hasMatch(command)) {
      return _deny(
        'skill_shell_syntax',
        'Compound, redirected, expanded, or wildcard shell syntax is not allowed for skills.',
      );
    }
    final tokens = command.trim().split(RegExp(r'\s+'));
    final executable = tokens.first;
    if (!capabilities.commands.contains(executable)) {
      return _deny(
        'skill_command_undeclared',
        'Skill did not declare command $executable.',
      );
    }
    if (!_p0AllowedCommands.contains(executable)) {
      return _deny(
        'skill_command_unenforceable',
        'Command $executable cannot be safely capability-confined in P0.',
      );
    }

    if (tokens.skip(1).any((token) => token.contains(r'$'))) {
      return _deny(
        'skill_secret_bash_forbidden',
        'Secrets are unavailable to Bash and subprocess tools.',
      );
    }
    return null;
  }

  static ToolDenyDecision _deny(String id, String message) => ToolDenyDecision(
        ruleType: 'skill_capability',
        ruleId: id,
        message: message,
      );

  static bool _domainAllowed(String domain, List<String> scopes) {
    final normalized = domain.toLowerCase();
    return scopes.any((scope) {
      final allowed = scope.toLowerCase();
      if (allowed.startsWith('*.')) {
        final suffix = allowed.substring(1);
        return normalized.endsWith(suffix) && normalized != suffix.substring(1);
      }
      return normalized == allowed;
    });
  }

  static bool _referencesSkillStorage(dynamic value) {
    if (value is String) {
      final normalized = value.replaceAll('\\', '/').toLowerCase();
      return normalized.contains('/root/workspace/skills/') ||
          normalized.contains('skills/') && normalized.contains('skill.md');
    }
    if (value is Map) return value.values.any(_referencesSkillStorage);
    if (value is Iterable) return value.any(_referencesSkillStorage);
    return false;
  }

  static const _p0AllowedCommands = {
    'echo',
    'pwd',
    'whoami',
    'uname',
  };

  static const _androidRequirements = <String, _AndroidRequirement>{
    'setAlarm': _AndroidRequirement('android.intent.action.SET_ALARM'),
    'openWeb': _AndroidRequirement('android.intent.action.VIEW'),
    'dialPad': _AndroidRequirement('android.intent.action.DIAL'),
    'share': _AndroidRequirement('android.intent.action.SEND'),
    'mapsNavigate': _AndroidRequirement('android.intent.action.VIEW'),
    'composeEmail': _AndroidRequirement('android.intent.action.SENDTO'),
    'openCamera': _AndroidRequirement('android.media.action.IMAGE_CAPTURE'),
    'addCalendarEventIntent':
        _AndroidRequirement('android.intent.action.INSERT'),
    'insertCalendarEvent': _AndroidRequirement(
      'android.permission.WRITE_CALENDAR',
      permission: true,
    ),
    'listCalendarEvents': _AndroidRequirement(
      'android.permission.READ_CALENDAR',
      permission: true,
    ),
    'listContacts': _AndroidRequirement(
      'android.permission.READ_CONTACTS',
      permission: true,
    ),
    'callPhone': _AndroidRequirement(
      'android.permission.CALL_PHONE',
      permission: true,
    ),
    'sendSms': _AndroidRequirement(
      'android.permission.SEND_SMS',
      permission: true,
    ),
  };
}

class _AndroidRequirement {
  final String name;
  final bool permission;

  const _AndroidRequirement(this.name, {this.permission = false});
}
