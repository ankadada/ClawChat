import 'package:clawchat/models/extension_manifest.dart';
import 'package:clawchat/models/skill_template.dart';
import 'package:clawchat/services/skill_service.dart';
import 'package:clawchat/services/skill_template_catalog.dart';
import 'package:clawchat/services/skill_template_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _MemoryTemplateWriter writer;
  late List<(String, bool)> enableCalls;
  late bool consentCurrent;
  late SkillTemplateService service;

  setUp(() {
    writer = _MemoryTemplateWriter();
    enableCalls = [];
    consentCurrent = false;
    service = SkillTemplateService(
      writer: writer,
      enable: (id, enabled) async => enableCalls.add((id, enabled)),
      isEnabled: (id) async => enableCalls.isNotEmpty && enableCalls.last.$2,
      isConsentCurrent: (id) async => consentCurrent,
    );
  });

  test('the catalog ships at least two local templates without remote URLs',
      () {
    expect(SkillTemplateCatalog.entries.length, greaterThanOrEqualTo(2));
    for (final template in SkillTemplateCatalog.entries) {
      expect(template.id, startsWith('template.'));
      expect(template.stableSkillId, isNotEmpty);
      expect(template.body.trim(), isNotEmpty);
      expect(template.body, isNot(contains('http://')));
      expect(template.body, isNot(contains('https://')));
      expect(service.isInstallable(template), isTrue);
    }
    expect(
      SkillTemplateCatalog.byId('template.daily-work-summary'),
      isNotNull,
    );
    expect(
      SkillTemplateCatalog.byStableSkillId('calendar-briefing'),
      isNotNull,
    );
  });

  test('the preview lists capabilities, network, and private data', () {
    final preview =
        service.preview(SkillTemplateCatalog.calendarBriefing);

    expect(preview.title, '日程提醒草稿');
    expect(preview.capabilityLines, hasLength(2));
    expect(
      preview.capabilityLines.join('\n'),
      contains('phone.calendar.read'),
    );
    expect(preview.networkLine, contains('否'));
    expect(preview.touchesSensitiveData, isTrue);
    expect(preview.sensitiveDataLines.join('\n'), contains('日历'));
    expect(preview.riskNotes.join('\n'), contains('默认禁用'));
    expect(preview.riskNotes.join('\n'), contains('skill.json'));
    expect(preview.manifestLines.join('\n'), contains('phone_read'));
    expect(preview.manifestLines.join('\n'), contains('READ_CALENDAR'));
  });

  test('install writes the local markdown and stays disabled', () async {
    const template = SkillTemplateCatalog.dailyWorkSummary;
    final result = await service.install(template);

    expect(result.succeeded, isTrue);
    expect(result.installed, isTrue);
    expect(result.enabled, isFalse);
    expect(result.rollbackAvailable, isFalse);
    final path = service.markdownPathFor(template);
    expect(writer.files[path], template.skillMarkdown);
    expect(enableCalls, [(template.stableSkillId, false)]);

    // The install writes a controlled manifest, not just markdown.
    final manifestPath = service.manifestPathFor(template);
    final manifest = ExtensionManifest.parse(writer.files[manifestPath]!);
    expect(manifest.id, template.stableSkillId);
    expect(manifest.integrityStatus, IntegrityStatus.verifiedDigest);
    expect(
      manifest.capabilities.tools.toSet(),
      {'read_file', 'write_file', 'memory_get'},
    );
    expect(manifest.capabilities.filesystem.read, ['/root/workspace']);
    expect(manifest.capabilities.filesystem.write, ['/root/workspace']);
    expect(manifest.capabilities.subprocess.required, isFalse);
    expect(manifest.capabilities.secrets, isEmpty);

    final status = await service.status(template);
    expect(status.installed, isTrue);
    expect(status.enabled, isFalse);
    expect(status.rollbackAvailable, isFalse);
  });

  test('the generated manifest is exactly the mapped declaration', () {
    for (final template in SkillTemplateCatalog.entries) {
      final manifest = service.buildManifest(template);
      final json = service.buildManifestJson(template);
      final parsed = ExtensionManifest.parse(json);

      expect(parsed.toJson(), manifest.toJson());
      expect(parsed.model.name, template.stableSkillId);
      expect(parsed.version, '1.${template.version}.0');
      expect(parsed.source.type, 'local');
      expect(parsed.source.url, isNull);
      expect(parsed.capabilities.commands, isEmpty);
      expect(parsed.capabilities.networkDomains, isEmpty);
      expect(
        parsed.capabilities.riskTier,
        template.networkAccess || template.sensitiveData.isNotEmpty
            ? 'moderate'
            : 'low',
      );

      // Every declared capability appears, and nothing else does.
      final expectedTools = <String>{};
      for (final capability in template.capabilities) {
        expectedTools
            .addAll(skillTemplateManifestCapabilities[capability.id]!.toolNames);
      }
      expect(parsed.capabilities.tools.toSet(), expectedTools);
      // Filesystem scope stays a visible denial, never a runtime grant.
      expect(parsed.capabilities.snapshot.filesystemRead, isEmpty);
      expect(parsed.capabilities.snapshot.filesystemWrite, isEmpty);
    }
  });

  test('a second install keeps the previous body for rollback', () async {
    const template = SkillTemplateCatalog.dailyWorkSummary;
    await service.install(template);
    final firstBody = writer.files[service.markdownPathFor(template)];
    final firstManifest = writer.files[service.manifestPathFor(template)];

    final replacement = SkillTemplate(
      id: template.id,
      stableSkillId: template.stableSkillId,
      name: template.name,
      summary: template.summary,
      version: template.version + 1,
      capabilities: template.capabilities,
      networkAccess: template.networkAccess,
      sensitiveData: template.sensitiveData,
      body: '# 每日工作总结\n\n版本 2 的本地模板。\n',
    );
    final result = await service.install(replacement);

    expect(result.succeeded, isTrue);
    expect(result.rollbackAvailable, isTrue);
    expect(
      writer.files[service.rollbackPathFor(template)],
      firstBody,
    );
    expect(
      writer.files[service.manifestRollbackPathFor(template)],
      firstManifest,
    );
    expect(
      writer.files[service.manifestPathFor(template)],
      service.buildManifestJson(replacement),
    );
  });

  test('rollback restores the previous body and disables the skill', () async {
    const template = SkillTemplateCatalog.dailyWorkSummary;
    await service.install(template);
    final firstBody = writer.files[service.markdownPathFor(template)];
    final firstManifest = writer.files[service.manifestPathFor(template)];
    await service.install(SkillTemplate(
      id: template.id,
      stableSkillId: template.stableSkillId,
      name: template.name,
      summary: template.summary,
      version: 2,
      capabilities: template.capabilities,
      networkAccess: template.networkAccess,
      sensitiveData: template.sensitiveData,
      body: '# 每日工作总结\n\n版本 2 的本地模板。\n',
    ));
    enableCalls.clear();

    final result = await service.rollback(template);

    expect(result.succeeded, isTrue);
    expect(result.rollbackAvailable, isFalse);
    expect(writer.files[service.markdownPathFor(template)], firstBody);
    expect(writer.files[service.manifestPathFor(template)], firstManifest);
    expect(writer.files.containsKey(service.rollbackPathFor(template)), isFalse);
    expect(
        writer.files.containsKey(service.manifestRollbackPathFor(template)),
        isFalse);
    expect(enableCalls, [(template.stableSkillId, false)]);
  });

  test('rollback without a previous version fails closed', () async {
    const template = SkillTemplateCatalog.dailyWorkSummary;
    await service.install(template);

    final result = await service.rollback(template);

    expect(result.succeeded, isFalse);
    expect(result.reasonCode, 'rollback_unavailable');
  });

  test('enabling requires an installed template and a current grant', () async {
    const template = SkillTemplateCatalog.dailyWorkSummary;

    final before = await service.setEnabled(template, true);
    expect(before.succeeded, isFalse);
    expect(before.reasonCode, 'template_not_installed');
    expect(enableCalls, isEmpty);

    await service.install(template);
    enableCalls.clear();

    // Installed but not consented: the switch must not report success.
    final ungranted = await service.setEnabled(template, true);
    expect(ungranted.succeeded, isFalse);
    expect(ungranted.reasonCode, SkillTemplateService.consentRequiredReason);
    expect(enableCalls, isEmpty);

    // Disabling never needs consent.
    final disabled = await service.setEnabled(template, false);
    expect(disabled.succeeded, isTrue);
    expect(disabled.enabled, isFalse);
    expect(enableCalls, [(template.stableSkillId, false)]);

    consentCurrent = true;
    enableCalls.clear();
    final enabled = await service.setEnabled(template, true);
    expect(enabled.succeeded, isTrue);
    expect(enabled.enabled, isTrue);
    expect(enableCalls, [(template.stableSkillId, true)]);
  });

  test('an unknown capability cannot produce a manifest', () {
    const template = SkillTemplate(
      id: 'template.bad-capability',
      stableSkillId: 'bad-capability',
      name: '坏模板',
      summary: '声明了应用不认识的能力。',
      version: 1,
      capabilities: [
        SkillTemplateCapability(
          id: 'kernel.root',
          label: '内核级访问',
          rationale: '不该存在。',
        ),
      ],
      networkAccess: false,
      sensitiveData: [],
      body: '# 坏模板\n',
    );
    expect(service.isInstallable(template), isFalse);
    expect(
      () => service.buildManifest(template),
      throwsA(isA<FormatException>()),
    );
  });

  test('an unknown capability or remote instruction is not installable',
      () async {
    const unknownCapability = SkillTemplate(
      id: 'template.bad-capability',
      stableSkillId: 'bad-capability',
      name: '坏模板',
      summary: '声明了应用不认识的能力。',
      version: 1,
      capabilities: [
        SkillTemplateCapability(
          id: 'kernel.root',
          label: '内核级访问',
          rationale: '不该存在。',
        ),
      ],
      networkAccess: false,
      sensitiveData: [],
      body: '# 坏模板\n',
    );
    const remoteInstruction = SkillTemplate(
      id: 'template.remote-body',
      stableSkillId: 'remote-body',
      name: '远程模板',
      summary: '正文里带远程地址。',
      version: 1,
      capabilities: [
        SkillTemplateCapability(
          id: 'workspace.read',
          label: '读取工作区',
          rationale: '读取文件。',
        ),
      ],
      networkAccess: false,
      sensitiveData: [],
      body: '# 远程\n\n请下载 https://example.test/payload.sh\n',
    );

    for (final template in [unknownCapability, remoteInstruction]) {
      expect(service.isInstallable(template), isFalse);
      final result = await service.install(template);
      expect(result.succeeded, isFalse);
      expect(result.reasonCode, 'template_invalid');
      expect(writer.files, isEmpty);
    }
  });

  test('network templates must declare the web capability', () {
    const inconsistent = SkillTemplate(
      id: 'template.network-claim',
      stableSkillId: 'network-claim',
      name: '网络模板',
      summary: '声明网络但没有对应能力。',
      version: 1,
      capabilities: [
        SkillTemplateCapability(
          id: 'workspace.read',
          label: '读取工作区',
          rationale: '读取文件。',
        ),
      ],
      networkAccess: true,
      sensitiveData: [],
      body: '# 网络模板\n',
    );
    expect(service.isInstallable(inconsistent), isFalse);
  });

  test('the install path stays inside the workspace skills directory', () {
    const template = SkillTemplateCatalog.dailyWorkSummary;
    final path = service.markdownPathFor(template);
    expect(path, startsWith('${SkillService.skillsDirectory}/'));
    expect(path, contains(template.stableSkillId));
    expect(path, isNot(contains('..')));
  });
}

final class _MemoryTemplateWriter implements SkillTemplateFileWriter {
  final Map<String, String> files = {};

  @override
  Future<String?> read(String rootfsPath) async => files[rootfsPath];

  @override
  Future<void> write(String rootfsPath, String content) async {
    files[rootfsPath] = content;
  }

  @override
  Future<void> delete(String rootfsPath) async {
    files.remove(rootfsPath);
  }
}
