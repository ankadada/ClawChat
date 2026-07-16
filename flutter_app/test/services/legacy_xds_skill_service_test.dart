import 'dart:convert';
import 'dart:io';

import 'package:clawchat/constants.dart';
import 'package:clawchat/services/legacy_skill_compatibility.dart';
import 'package:clawchat/services/native_bridge.dart';
import 'package:clawchat/services/skill_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(AppConstants.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const root = LegacySkillCompatibility.xdsSkillRoot;
  late String content;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    content =
        await File('test/fixtures/xds_skills_0_1_9_SKILL.md').readAsString();
    NativeBridge.setImportIdentityProbeForTesting((_) async => 'stable-file');
  });

  tearDown(() {
    NativeBridge.resetImportReadStreamForTesting();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
      'published XDS package gets only typed compatibility after fresh consent',
      () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
      if (call.method == 'runInProot') {
        final command = args['command'] as String;
        if (command.contains("find '/root/workspace/.agents/skills'")) {
          return '$root/SKILL.md';
        }
        return '';
      }
      if (call.method == 'readRootfsFileBounded' ||
          call.method == 'readRootfsFile') {
        final path = args['path'] as String;
        if (path.endsWith('/SKILL.md')) {
          return call.method == 'readRootfsFileBounded'
              ? Uint8List.fromList(utf8.encode(content))
              : content;
        }
        return null;
      }
      return null;
    });

    var skills = await SkillService.scanSkills();
    expect(skills, hasLength(1));
    expect(skills.single.id, LegacySkillCompatibility.xdsSkillId);
    expect(skills.single.version, '0.1.9');
    expect(skills.single.availabilityReason, isNull);
    expect(skills.single.enabled, isFalse);
    expect(skills.single.requiresConsent, isTrue);
    expect(
      skills.single.capabilitySnapshot.tools,
      [LegacySkillCompatibility.xdsToolName],
    );
    expect(skills.single.capabilitySnapshot.commands, isEmpty);

    final candidate =
        await SkillService.prepareConsentForInstalledSkill(skills.single);
    expect(candidate.legacy, isTrue);
    expect(candidate.version, '0.1.9');
    expect(candidate.legacyAvailabilityReason, isNull);
    await SkillService.installPreparedSkill(
      candidate,
      enabled: true,
      inspectionReviewConfirmed: true,
    );

    skills = await SkillService.scanSkills();
    expect(skills.single.consentCurrent, isTrue);
    expect(skills.single.enabled, isTrue);
    final verified =
        await SkillService.loadGrantedSkillById('legacy.xds-skills');
    expect(verified.capabilities.tools, ['xds_agent']);
    expect(verified.capabilities.commands, isEmpty);
    expect(verified.skillContent, content);
  });

  test('wrong path, name, or bytes remain unavailable', () {
    final wrongPath = SkillService.inspectPackage(
      stagingPath: '/root/workspace/.agents/skills/vendor/xds-skills',
      sourceIdentity: 'Installed locally',
      skillContent: content,
      manifestContent: null,
      installedCandidate: true,
    );
    expect(wrongPath.legacyAvailabilityReason, isNotNull);

    final wrongName = SkillService.inspectPackage(
      stagingPath: root,
      sourceIdentity: 'Installed locally',
      skillContent: content.replaceFirst('name: xds-skills', 'name: other'),
      manifestContent: null,
      installedCandidate: true,
    );
    expect(wrongName.id, 'legacy.other');
    expect(wrongName.legacyAvailabilityReason, isNotNull);

    final changed = SkillService.inspectPackage(
      stagingPath: root,
      sourceIdentity: 'Installed locally',
      skillContent: '$content\nchanged',
      manifestContent: null,
      installedCandidate: true,
    );
    expect(changed.legacyAvailabilityReason, isNotNull);
  });
}
