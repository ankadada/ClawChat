import 'package:clawchat/models/extension_manifest.dart';
import 'package:clawchat/services/skill_capability_policy.dart';
import 'package:clawchat/services/legacy_skill_compatibility.dart';
import 'package:clawchat/services/skill_service.dart';
import 'package:clawchat/services/tools/tool_policy.dart';
import 'package:flutter_test/flutter_test.dart';

VerifiedSkillUse _skill(ExtensionCapabilitySnapshot capabilities) =>
    VerifiedSkillUse(
      id: 'com.example.skill',
      name: 'Example',
      path: '/root/workspace/skills/com.example.skill/SKILL.md',
      skillContent: 'malicious instructions request undeclared powers',
      capabilities: capabilities,
      manifestDigest: List.filled(64, 'a').join(),
      contentDigest: List.filled(64, 'b').join(),
      trustDigest: List.filled(64, 'c').join(),
      legacy: false,
    );

ExtensionCapabilitySnapshot _capabilities({
  List<String> tools = const [],
  List<String> commands = const [],
  List<String> network = const [],
  List<String> read = const [],
  List<String> write = const [],
  List<String> secrets = const [],
  bool subprocess = false,
  String risk = 'low',
}) =>
    ExtensionCapabilitySnapshot(
      tools: tools,
      commands: commands,
      networkDomains: network,
      filesystemRead: read,
      filesystemWrite: write,
      androidIntents: const [],
      androidPermissions: const [],
      secretNames: secrets,
      runtimes: commands,
      subprocessRequired: subprocess,
      riskTier: risk,
      updatePolicy: 'manual',
    );

ToolApprovalRequest _request(
  String tool,
  Map<String, dynamic> arguments, {
  ToolRisk risk = ToolRisk.dangerous,
}) =>
    ToolApprovalRequest(
      toolName: tool,
      arguments: arguments,
      risk: risk,
      operationId: 'test-operation',
    );

void main() {
  test('XDS requires an active declared compatibility context', () async {
    final policy = SkillCapabilityPolicy();
    final request = _request(
      LegacySkillCompatibility.xdsToolName,
      const {'operation': 'list'},
      risk: ToolRisk.dangerous,
    );
    expect(policy.denyFor(request)?.ruleId, 'xds_skill_context_required');

    policy.activate(
      _skill(LegacySkillCompatibility.xdsCapabilities),
    );
    expect(policy.denyFor(request), isNull);
    expect(
      policy
          .denyFor(_request('bash', {'command': 'python3 script.py'}))
          ?.ruleId,
      'skill_tool_undeclared',
    );

    final missingDomain = SkillCapabilityPolicy()
      ..activate(_skill(_capabilities(
        tools: const [LegacySkillCompatibility.xdsToolName],
        secrets: const [LegacySkillCompatibility.xdsTokenName],
      )));
    expect(
      missingDomain.denyFor(request)?.ruleId,
      'skill_network_domain',
    );
  });

  test(
      'skill bytes cannot bypass verified entrypoint through bash or raw files',
      () async {
    final skillPolicy = SkillCapabilityPolicy();
    final globalAuto = ToolPolicy(
      approvalRequiredFor: const {},
      additionalDenyCheck: skillPolicy.denyFor,
    );

    expect(
      await globalAuto.approve(_request('bash', {
        'command': 'cat /root/workspace/skills/com.example.skill/SKILL.md',
      })),
      isFalse,
    );
    expect(
      await globalAuto.approve(_request('bash', {
        'command': 'cat /root/workspace/.agents/skills/xds-skills/SKILL.md',
      })),
      isFalse,
    );
    expect(
      await globalAuto.approve(_request(
        'read_file',
        {'path': '/root/workspace/skills/com.example.skill/helper.txt'},
        risk: ToolRisk.moderate,
      )),
      isFalse,
    );
  });

  test('undeclared bash network and files fail closed even under global auto',
      () async {
    final skillPolicy = SkillCapabilityPolicy()
      ..activate(_skill(_capabilities()));
    final globalAuto = ToolPolicy(
      approvalRequiredFor: const {},
      additionalDenyCheck: skillPolicy.denyFor,
    );

    expect(
      await globalAuto.approve(_request('bash', {'command': 'echo stolen'})),
      isFalse,
    );
    expect(
      await globalAuto.approve(_request(
        'web_fetch',
        {'url': 'https://evil.example/data'},
        risk: ToolRisk.moderate,
      )),
      isFalse,
    );
    expect(
      await globalAuto.approve(_request(
        'read_file',
        {'path': '/root/workspace/private.txt'},
        risk: ToolRisk.moderate,
      )),
      isFalse,
    );
    expect(
      await globalAuto.approve(_request(
        'write_file',
        {'path': '/root/workspace/out.txt', 'content': 'x'},
      )),
      isFalse,
    );
  });

  test('declared constrained bash still requires and honors user approval',
      () async {
    final skillPolicy = SkillCapabilityPolicy()
      ..activate(_skill(_capabilities(
        tools: const ['bash'],
        commands: const ['echo'],
        subprocess: true,
      )));
    var approvalCalls = 0;
    final policy = ToolPolicy(
      additionalDenyCheck: skillPolicy.denyFor,
      onApprovalRequired: (_) {
        approvalCalls++;
        return true;
      },
    );
    final request = _request('bash', {'command': 'echo hello'});

    expect(policy.denyFor(request), isNull);
    expect(await policy.approve(request), isTrue);
    expect(approvalCalls, 1);
  });

  test('declared domains work but skill filesystem access stays fail closed',
      () {
    final skillPolicy = SkillCapabilityPolicy()
      ..activate(_skill(_capabilities(
        tools: const ['web_fetch', 'read_file', 'write_file'],
        network: const ['api.example.com', '*.trusted.example'],
        read: const ['/root/workspace/input'],
        write: const ['/root/workspace/output'],
      )));

    expect(
      skillPolicy.denyFor(_request(
        'web_fetch',
        {'url': 'https://api.example.com/v1'},
        risk: ToolRisk.moderate,
      )),
      isNull,
    );
    expect(
      skillPolicy.denyFor(_request(
        'web_fetch',
        {'url': 'https://attacker-api.example.com/v1'},
        risk: ToolRisk.moderate,
      )),
      isNotNull,
    );
    for (final request in [
      _request(
        'read_file',
        {'path': '/root/workspace/input/a.txt'},
        risk: ToolRisk.moderate,
      ),
      _request(
        'write_file',
        {'path': '/root/workspace/output/result.txt', 'content': 'safe'},
      ),
    ]) {
      final denial = skillPolicy.denyFor(request);
      expect(denial, isNotNull);
      expect(denial!.ruleId, 'skill_filesystem_unenforceable');
    }
  });

  test('second skill cannot spoof or replace active capability context',
      () async {
    final first = _skill(_capabilities(tools: const ['read_file']));
    final second = VerifiedSkillUse(
      id: 'com.example.other',
      name: 'Other',
      path: '/root/workspace/skills/com.example.other/SKILL.md',
      skillContent: 'other',
      capabilities: _capabilities(tools: const ['bash']),
      manifestDigest: List.filled(64, 'd').join(),
      contentDigest: List.filled(64, 'e').join(),
      trustDigest: List.filled(64, 'f').join(),
      legacy: false,
    );
    final policy = SkillCapabilityPolicy(loader: (id) async => second)
      ..activate(first);

    await expectLater(
      policy.prepareSkillActivation(_request(
        'load_skill',
        {'id': second.id},
        risk: ToolRisk.safe,
      )),
      throwsA(isA<SkillCapabilityViolation>()),
    );
  });

  test('declared secret names never authorize Bash secret expansion', () {
    final skillPolicy = SkillCapabilityPolicy()
      ..activate(_skill(_capabilities(
        tools: const ['bash'],
        commands: const ['echo'],
        secrets: const ['DECLARED_TOKEN'],
        subprocess: true,
      )));

    expect(
      skillPolicy.denyFor(_request(
        'bash',
        {'command': r'echo $DECLARED_TOKEN'},
      )),
      isNotNull,
    );
    expect(
      skillPolicy.denyFor(_request(
        'bash',
        {'command': 'printenv DECLARED_TOKEN'},
      )),
      isNotNull,
    );
  });

  test('failed historical restore blocks global-auto tools until reactivation',
      () async {
    final policy = SkillCapabilityPolicy(loader: (_) async {
      throw StateError('stale grant');
    });
    try {
      await policy.restoreGrantedSkill(
        'com.example.skill',
        expectedTrustDigest: List.filled(64, 'f').join(),
      );
    } catch (_) {
      policy.markHistoricalRestoreFailed();
    }
    final globalAuto = ToolPolicy(
      approvalRequiredFor: const {},
      additionalDenyCheck: policy.denyFor,
    );

    expect(
      await globalAuto.approve(
        _request('bash', {'command': 'echo should-not-run'}),
      ),
      isFalse,
    );
  });
}
