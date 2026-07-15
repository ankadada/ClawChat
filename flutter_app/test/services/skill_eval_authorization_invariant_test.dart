import 'dart:convert';

import 'package:clawchat/models/extension_manifest.dart';
import 'package:clawchat/services/skill_capability_policy.dart';
import 'package:clawchat/services/skill_import_inspector.dart';
import 'package:clawchat/services/skill_service.dart';
import 'package:clawchat/services/tools/tool_policy.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _manifest() => {
      'schemaVersion': 1,
      'id': 'com.example.eval-pass',
      'name': 'Eval Pass',
      'description': 'Non-authorizing fixture.',
      'model': {
        'name': 'eval_pass',
        'description': 'Non-authorizing fixture.',
      },
      'version': '1.0.0',
      'source': {'type': 'local'},
      'integrity': <String, dynamic>{},
      'author': 'Example',
      'license': 'MIT',
      'capabilities': {
        'tools': <String>[],
        'commands': <String>[],
        'networkDomains': <String>[],
        'filesystem': {'read': <String>[], 'write': <String>[]},
        'android': {'intents': <String>[], 'permissions': <String>[]},
        'secrets': <String>[],
        'subprocess': {'required': false, 'runtimes': <String>[]},
        'riskTier': 'low',
        'updatePolicy': 'manual',
      },
    };

ToolApprovalRequest _request(
  String tool, {
  required String operationId,
  ToolRisk risk = ToolRisk.dangerous,
  Map<String, dynamic> arguments = const {},
}) =>
    ToolApprovalRequest(
      toolName: tool,
      arguments: arguments,
      risk: risk,
      operationId: operationId,
      runAttemptId: 'run-v2.6-invariant',
    );

VerifiedSkillUse _emptyGrantedSkill() => VerifiedSkillUse(
      id: 'com.example.eval-pass',
      name: 'Eval Pass',
      path: '/root/workspace/skills/com.example.eval-pass/SKILL.md',
      skillContent: '# Eval Pass',
      capabilities: const ExtensionCapabilitySnapshot(
        tools: [],
        commands: [],
        networkDomains: [],
        filesystemRead: [],
        filesystemWrite: [],
        androidIntents: [],
        androidPermissions: [],
        secretNames: [],
        runtimes: [],
        subprocessRequired: false,
        riskTier: 'low',
        updatePolicy: 'manual',
      ),
      manifestDigest: 'a' * 64,
      contentDigest: 'b' * 64,
      trustDigest: 'c' * 64,
      legacy: false,
    );

void main() {
  test('eval and import PASS never authorize hard-deny Ask Auto or recovery',
      () async {
    final inspection = SkillImportInspector.inspect(
      skillBytes: utf8.encode('# Eval Pass'),
      manifestBytes: utf8.encode(jsonEncode(_manifest())),
    ).result;
    expect(inspection.verdict, ImportInspectionVerdict.accepted);

    var hardDenyApprovalCalls = 0;
    final hardDeny = ToolPolicy(
      deniedToolNames: const {'phone_intent'},
      approvalRequiredFor: const {},
      onApprovalRequired: (_) {
        hardDenyApprovalCalls += 1;
        return true;
      },
    );
    expect(
      await hardDeny.approve(_request(
        'phone_intent',
        operationId: 'hard-deny-after-pass',
      )),
      isFalse,
    );
    expect(hardDenyApprovalCalls, 0);

    final askOperationIds = <String>[];
    final ask = ToolPolicy(
      onApprovalRequired: (request) {
        askOperationIds.add(request.operationId);
        return true;
      },
    );
    expect(
      await ask.approve(_request(
        'web_fetch',
        operationId: 'ask-after-pass',
        risk: ToolRisk.moderate,
        arguments: const {'url': 'https://example.com'},
      )),
      isTrue,
    );
    expect(askOperationIds, ['ask-after-pass']);

    final auto = ToolPolicy(
      approvalRequiredFor: const {},
      onApprovalRequired: (_) => throw StateError('Auto must not ask.'),
    );
    expect(
      await auto.approve(_request(
        'web_fetch',
        operationId: 'auto-eligible-after-pass',
        risk: ToolRisk.moderate,
        arguments: const {'url': 'https://example.com'},
      )),
      isTrue,
    );

    final skillPolicy = SkillCapabilityPolicy()..activate(_emptyGrantedSkill());
    final autoWithSkillBoundary = ToolPolicy(
      approvalRequiredFor: const {},
      additionalDenyCheck: skillPolicy.denyFor,
    );
    expect(
      await autoWithSkillBoundary.approve(_request(
        'web_fetch',
        operationId: 'auto-skill-deny-after-pass',
        risk: ToolRisk.moderate,
        arguments: const {'url': 'https://example.com'},
      )),
      isFalse,
    );

    expect(
      await ask.approve(_request(
        'web_fetch',
        operationId: 'recovery-fresh-authorization',
        risk: ToolRisk.moderate,
        arguments: const {'url': 'https://example.com'},
      )),
      isTrue,
    );
    expect(
      askOperationIds,
      ['ask-after-pass', 'recovery-fresh-authorization'],
    );

    final failedRecovery = SkillCapabilityPolicy()
      ..markHistoricalRestoreFailed();
    final recoveryAuto = ToolPolicy(
      approvalRequiredFor: const {},
      additionalDenyCheck: failedRecovery.denyFor,
    );
    expect(
      await recoveryAuto.approve(_request(
        'web_fetch',
        operationId: 'recovery-stale-denied',
        risk: ToolRisk.moderate,
        arguments: const {'url': 'https://example.com'},
      )),
      isFalse,
    );
  });
}
