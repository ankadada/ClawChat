import 'dart:convert';
import 'dart:io';
import 'package:clawchat/constants.dart';
import 'package:clawchat/services/legacy_skill_compatibility.dart';
import 'package:clawchat/services/native_bridge.dart';
import 'package:clawchat/services/skill_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _xdsManifest() => {
      'schemaVersion': 1,
      'id': 'com.example.xds',
      'name': 'XDS adapter',
      'description': 'Typed XDS adapter test manifest.',
      'model': {
        'name': 'xds_adapter',
        'description': 'Use the typed XDS adapter.',
      },
      'version': '1.0.0',
      'source': {'type': 'local'},
      'integrity': <String, dynamic>{},
      'author': 'Example',
      'license': 'MIT',
      'capabilities': {
        'tools': [LegacySkillCompatibility.xdsToolName],
        'commands': <String>[],
        'networkDomains': [LegacySkillCompatibility.xdsDomain],
        'filesystem': {'read': <String>[], 'write': <String>[]},
        'android': {'intents': <String>[], 'permissions': <String>[]},
        'secrets': [LegacySkillCompatibility.xdsTokenName],
        'subprocess': {'required': false, 'runtimes': <String>[]},
        'riskTier': 'critical',
        'updatePolicy': 'manual',
      },
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(AppConstants.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const root = '/root/workspace/.agents/skills/xds-skills';
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

  test('legacy XDS package can be consented but receives no capabilities',
      () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
      if (call.method == 'runInProot') {
        final command = args['command'] as String;
        if (command.contains("find '/root/workspace/.agents/skills'")) {
          return '$root/SKILL.md';
        }
        if (command.contains('echo SKILL_INSTALL_OK')) {
          return 'SKILL_INSTALL_OK';
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

    final skills = await SkillService.scanSkills();
    expect(skills, hasLength(1));
    expect(skills.single.id, 'legacy.xds-skills');
    expect(skills.single.version, 'legacy');
    expect(skills.single.availabilityReason, isNull);
    expect(skills.single.capabilitySnapshot.tools, isEmpty);
    expect(skills.single.enabled, isFalse);
    expect(skills.single.requiresConsent, isTrue);

    final candidate =
        await SkillService.prepareConsentForInstalledSkill(skills.single);
    await SkillService.installPreparedSkill(
      candidate,
      enabled: true,
      inspectionReviewConfirmed: true,
    );
    final verified =
        await SkillService.loadGrantedSkillById('legacy.xds-skills');
    expect(verified.capabilities.tools, isEmpty);
  });

  test('formal manifest can explicitly declare the typed XDS adapter', () {
    final candidate = SkillService.inspectPackage(
      stagingPath: '/root/workspace/skills/com.example.xds',
      sourceIdentity: 'Installed locally',
      skillContent: '---\nname: xds-adapter\n---\nUse XDS.',
      manifestContent: jsonEncode(_xdsManifest()),
      installedCandidate: true,
    );

    expect(candidate.legacy, isFalse);
    expect(candidate.capabilitySnapshot.tools,
        [LegacySkillCompatibility.xdsToolName]);
    expect(candidate.capabilitySnapshot.networkDomains,
        [LegacySkillCompatibility.xdsDomain]);
    expect(candidate.capabilitySnapshot.secretNames,
        [LegacySkillCompatibility.xdsTokenName]);
  });
}
