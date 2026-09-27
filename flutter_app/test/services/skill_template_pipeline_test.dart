import 'dart:convert';

import 'package:clawchat/constants.dart';
import 'package:clawchat/models/extension_manifest.dart';
import 'package:clawchat/models/skill_template.dart';
import 'package:clawchat/services/native_bridge.dart';
import 'package:clawchat/services/skill_capability_policy.dart';
import 'package:clawchat/services/skill_service.dart';
import 'package:clawchat/services/skill_template_catalog.dart';
import 'package:clawchat/services/skill_template_service.dart';
import 'package:clawchat/services/tools/tool_policy.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// End-to-end path for a local workflow template:
/// install (controlled manifest) → scan/load → consent/grant → capability policy.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(AppConstants.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Map<String, String> rootfsFiles;
  late SkillTemplateService templateService;
  const template = SkillTemplateCatalog.dailyWorkSummary;
  final directory = '${SkillService.skillsDirectory}/${template.stableSkillId}';
  String bridge(String path) => path.startsWith('/') ? path.substring(1) : path;
  String readFile(String path) => rootfsFiles[bridge(path)] ?? '';
  void writeFile(String path, String content) =>
      rootfsFiles[bridge(path)] = content;

  setUp(() {
    rootfsFiles = {};
    templateService = SkillTemplateService();
    SharedPreferences.setMockInitialValues({});
    NativeBridge.setImportIdentityProbeForTesting((_) async => 'stable-file');
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
      switch (call.method) {
        case 'runInProot':
          final command = args['command']?.toString() ?? '';
          if (command.contains("find '${SkillService.skillsDirectory}'") ||
              command.contains('find "${SkillService.skillsDirectory}"')) {
            return rootfsFiles.containsKey(bridge('$directory/SKILL.md'))
                ? '$directory/SKILL.md'
                : '';
          }
          return '';
        case 'readRootfsFile':
        case 'readRootfsFileBounded':
          final value = rootfsFiles[args['path']?.toString() ?? ''];
          if (value == null) return null;
          return call.method == 'readRootfsFileBounded'
              ? Uint8List.fromList(utf8.encode(value))
              : value;
        case 'createRootfsDirectory':
          return true;
        case 'writeRootfsFile':
          rootfsFiles[args['path']?.toString() ?? ''] =
              args['content']?.toString() ?? '';
          return true;
        case 'deleteRootfsFile':
          return rootfsFiles.remove(args['path']?.toString() ?? '') != null;
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('a template enables from its own files when the guest scan is blind',
      () async {
    // Device case: the guest find returns nothing (runtime unavailable), so
    // the generic scan cannot list the installed package.
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
      switch (call.method) {
        case 'runInProot':
          return '';
        case 'readRootfsFile':
        case 'readRootfsFileBounded':
          final value = rootfsFiles[args['path']?.toString() ?? ''];
          if (value == null) return null;
          return call.method == 'readRootfsFileBounded'
              ? Uint8List.fromList(utf8.encode(value))
              : value;
        case 'createRootfsDirectory':
          return true;
        case 'writeRootfsFile':
          rootfsFiles[args['path']?.toString() ?? ''] =
              args['content']?.toString() ?? '';
          return true;
        case 'deleteRootfsFile':
          return rootfsFiles.remove(args['path']?.toString() ?? '') != null;
      }
      return null;
    });

    final install = await templateService.install(template);
    expect(install.succeeded, isTrue);

    final installedStatus = await SkillTemplateService().status(template);
    expect(installedStatus.installed, isTrue);
    expect(installedStatus.enabled, isFalse);

    // Consent is built from the template's own manifest and body; the scan is
    // not what decides whether the package exists.
    final candidate = await templateService.installedCandidate(template);
    expect(candidate, isNotNull);
    expect(candidate!.id, template.stableSkillId);
    expect(candidate.installedCandidate, isTrue);

    // Consent → grant → enable through the unchanged install path.
    await SkillService.installPreparedSkill(
      candidate,
      enabled: true,
      inspectionReviewConfirmed: true,
    );

    expect(
      await SkillService.isSkillStoredEnabled(template.stableSkillId),
      isTrue,
    );
    final enabledStatus = await SkillTemplateService().status(template);
    expect(enabledStatus.installed, isTrue);
    expect(enabledStatus.enabled, isTrue);
  });

  test('install reports the real state after a refresh', () async {
    final install = await templateService.install(template);
    expect(install.succeeded, isTrue);

    // A fresh service instance is what the settings screen builds on a
    // refresh: the installed package must be found, installed and still
    // disabled by default.
    final refreshed = SkillTemplateService();
    final status = await refreshed.status(template);
    expect(status.installed, isTrue);
    expect(status.enabled, isFalse);
    expect(refreshed.isInstallable(template), isTrue);
  });

  test('install fails closed when the skills directory cannot be created',
      () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
      switch (call.method) {
        case 'createRootfsDirectory':
          // The device case that used to be hidden: <workspace>/skills/<id>
          // does not exist and the broker refuses to create it.
          return false;
        case 'writeRootfsFile':
          rootfsFiles[args['path']?.toString() ?? ''] =
              args['content']?.toString() ?? '';
          return true;
        case 'readRootfsFile':
        case 'readRootfsFileBounded':
          return null;
        case 'runInProot':
          return '';
      }
      return null;
    });

    final install = await templateService.install(template);
    expect(install.succeeded, isFalse);
    expect(install.reasonCode, 'template_install_failed');
    // The broker's refusal is not reported as a written package.
    expect(rootfsFiles, isEmpty);
    final status = await templateService.status(template);
    expect(status.installed, isFalse);
    expect(status.enabled, isFalse);
  });

  test('a refused write is not reported as an install', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'createRootfsDirectory':
          return true;
        case 'writeRootfsFile':
          // The descriptor-relative writer refused (for example a path that
          // changed under it): the install must fail, not claim success.
          return false;
        case 'readRootfsFile':
        case 'readRootfsFileBounded':
          return null;
        case 'runInProot':
          return '';
      }
      return null;
    });

    final install = await templateService.install(template);
    expect(install.succeeded, isFalse);
    expect(rootfsFiles, isEmpty);
  });

  test('install → scan → consent/grant → load → capability policy', () async {
    final install = await templateService.install(template);
    expect(install.succeeded, isTrue);
    expect(install.enabled, isFalse);

    // 1. The installed package carries the controlled manifest.
    final manifest = ExtensionManifest.parse(readFile('$directory/skill.json'));
    expect(manifest.id, template.stableSkillId);
    expect(manifest.integrityStatus, IntegrityStatus.verifiedDigest);

    // 2. The normal skill scan sees a manifested skill with exactly the
    // declared capabilities, not a legacy skill with none.
    var skills = await SkillService.scanSkills();
    expect(skills, hasLength(1));
    var skill = skills.single;
    expect(skill.id, template.stableSkillId);
    expect(skill.valid, isTrue);
    expect(skill.legacy, isFalse);
    expect(skill.isUnavailable, isFalse);
    expect(
      skill.capabilitySnapshot.tools.toSet(),
      {'read_file', 'write_file', 'memory_get'},
    );
    expect(skill.capabilitySnapshot.deniedFilesystemWrite, ['/root/workspace']);
    expect(skill.requiresConsent, isTrue);
    expect(skill.enabled, isFalse);
    expect(SkillService.buildSkillIndex(skills), isEmpty);

    // 3. Enabling without the existing consent flow is refused.
    final ungranted = await templateService.setEnabled(template, true);
    expect(ungranted.succeeded, isFalse);
    expect(ungranted.reasonCode, SkillTemplateService.consentRequiredReason);

    // 4. Consent through the existing installed-skill flow records the grant.
    final candidate = await SkillService.prepareConsentForInstalledSkill(skill);
    await SkillService.installPreparedSkill(
      candidate,
      enabled: true,
      inspectionReviewConfirmed: true,
    );

    final enabled = await templateService.setEnabled(template, true);
    expect(enabled.succeeded, isTrue);

    skills = await SkillService.scanSkills();
    skill = skills.single;
    expect(skill.consentCurrent, isTrue);
    expect(skill.enabled, isTrue);
    expect(
        SkillService.buildSkillIndex(skills), contains(template.stableSkillId));

    // 5. Use-time load re-verifies the manifest and the grant digests.
    final verified =
        await SkillService.loadGrantedSkillById(template.stableSkillId);
    expect(verified.id, template.stableSkillId);
    expect(verified.legacy, isFalse);
    expect(
      verified.capabilities.tools.toSet(),
      {'read_file', 'write_file', 'memory_get'},
    );

    // 6. The capability policy enforces the manifest declaration.
    final policy = SkillCapabilityPolicy(
      loader: SkillService.loadGrantedSkillById,
    );
    final activation = await policy.prepareSkillActivation(
      _request('load_skill', {'id': template.stableSkillId}),
    );
    expect(activation, isNotNull);
    policy.activate(activation!);

    // A declared tool stays allowed by the skill boundary.
    expect(policy.denyFor(_request('memory_get')), isNull);
    // An undeclared tool is denied, not silently allowed.
    expect(policy.denyFor(_request('bash'))?.ruleId, 'skill_tool_undeclared');
    // Filesystem work stays an explicit runtime denial.
    expect(
      policy
          .denyFor(_request('read_file', {'path': 'workspace/notes.md'}))
          ?.ruleId,
      'skill_filesystem_unenforceable',
    );
  });

  test('a widened manifest is rejected instead of widening the grant',
      () async {
    await templateService.install(template);
    final manifestJson =
        jsonDecode(readFile('$directory/skill.json')) as Map<String, dynamic>;
    (manifestJson['capabilities'] as Map<String, dynamic>)['tools'] = <String>[
      'read_file',
      'write_file',
      'memory_get',
      'bash'
    ];
    writeFile('$directory/skill.json', jsonEncode(manifestJson));

    final skills = await SkillService.scanSkills();
    expect(skills.single.valid, isFalse);
    expect(skills.single.enabled, isFalse);
    expect(skills.single.validationError, isNotNull);
    await expectLater(
      SkillService.loadGrantedSkillById(template.stableSkillId),
      throwsA(isA<StateError>()),
    );
  });

  test('a body change after consent requires consent again', () async {
    await templateService.install(template);
    var skill = (await SkillService.scanSkills()).single;
    await SkillService.installPreparedSkill(
      await SkillService.prepareConsentForInstalledSkill(skill),
      enabled: true,
      inspectionReviewConfirmed: true,
    );
    expect(
        (await templateService.setEnabled(template, true)).succeeded, isTrue);

    writeFile('$directory/SKILL.md',
        '${readFile('$directory/SKILL.md')}\n额外的本地说明。\n');

    final afterChange = (await SkillService.scanSkills()).single;
    expect(afterChange.valid, isTrue);
    expect(afterChange.enabled, isFalse);
    expect(afterChange.requiresConsent, isTrue);
    await expectLater(
      SkillService.loadGrantedSkillById(template.stableSkillId),
      throwsA(isA<StateError>()),
    );
    final enable = await templateService.setEnabled(template, true);
    expect(enable.succeeded, isFalse);
    expect(enable.reasonCode, SkillTemplateService.consentRequiredReason);
  });

  test('reinstall invalidates the previous grant and stays disabled', () async {
    await templateService.install(template);
    final skill = (await SkillService.scanSkills()).single;
    await SkillService.installPreparedSkill(
      await SkillService.prepareConsentForInstalledSkill(skill),
      enabled: true,
      inspectionReviewConfirmed: true,
    );
    expect((await SkillService.scanSkills()).single.enabled, isTrue);

    final reinstall = await templateService.install(SkillTemplate(
      id: template.id,
      stableSkillId: template.stableSkillId,
      name: template.name,
      summary: template.summary,
      version: template.version + 1,
      capabilities: template.capabilities,
      networkAccess: template.networkAccess,
      sensitiveData: template.sensitiveData,
      body: '# 每日工作总结\n\n版本 2 的本地模板。\n',
    ));

    expect(reinstall.succeeded, isTrue);
    expect(reinstall.rollbackAvailable, isTrue);
    final afterReinstall = (await SkillService.scanSkills()).single;
    expect(afterReinstall.valid, isTrue);
    expect(afterReinstall.enabled, isFalse);
    expect(afterReinstall.consentCurrent, isFalse);
    expect(afterReinstall.version, '1.${template.version + 1}.0');
  });
}

ToolApprovalRequest _request(String tool,
        [Map<String, dynamic> arguments = const {}]) =>
    ToolApprovalRequest(
      toolName: tool,
      arguments: arguments,
      risk: ToolRisk.safe,
      operationId: 'op-$tool',
    );
