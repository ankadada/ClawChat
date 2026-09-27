import 'dart:async';
import 'dart:convert';

import '../models/extension_manifest.dart';
import '../models/skill_template.dart';
import 'native_bridge.dart';
import 'skill_service.dart';
import 'skill_template_catalog.dart';

/// Local file operations for template install/rollback.
abstract interface class SkillTemplateFileWriter {
  Future<String?> read(String rootfsPath);
  Future<void> write(String rootfsPath, String content);
  Future<void> delete(String rootfsPath);
}

/// Everything a template owns lives under the workspace skills directory.
const String kSkillTemplateScope = '/root/workspace';

final class NativeSkillTemplateFileWriter implements SkillTemplateFileWriter {
  const NativeSkillTemplateFileWriter();

  @override
  Future<String?> read(String rootfsPath) =>
      NativeBridge.readRootfsFile(_bridgePath(rootfsPath));

  @override
  Future<void> write(String rootfsPath, String content) async {
    final path = _bridgePath(rootfsPath);
    // The package lives in <workspace>/skills/<id>/, which a fresh workspace
    // does not have yet: create that directory through the same scoped broker
    // and fail closed when either step is refused. Ignoring the broker's
    // answer here made an install report success while nothing was written.
    final parent = _parentPath(path);
    if (parent.isNotEmpty &&
        !await NativeBridge.createRootfsDirectory(
          parent,
          allowedRoots: const [kSkillTemplateScope],
        )) {
      throw StateError('Template directory is unavailable');
    }
    final written = await NativeBridge.writeRootfsFile(
      path,
      content,
      allowedRoots: const [kSkillTemplateScope],
    );
    if (!written) {
      throw StateError('Template write was refused');
    }
  }

  @override
  Future<void> delete(String rootfsPath) async {
    final deleted = await NativeBridge.deleteRootfsFile(
      _bridgePath(rootfsPath),
      allowedRoots: const [kSkillTemplateScope],
    );
    if (!deleted) {
      throw StateError('Template delete was refused');
    }
  }

  static String _bridgePath(String path) =>
      path.startsWith('/') ? path.substring(1) : path;

  static String _parentPath(String path) {
    final slash = path.lastIndexOf('/');
    return slash <= 0 ? '' : path.substring(0, slash);
  }
}

typedef SkillTemplateEnableAction = Future<void> Function(
  String stableSkillId,
  bool enabled,
);

typedef SkillTemplateEnabledReader = Future<bool> Function(
  String stableSkillId,
);

/// Whether the scanned skill for this stable id carries a current trust grant.
///
/// A template can only be enabled through the existing consent flow, so the
/// enable action refuses while the grant is missing or stale.
typedef SkillTemplateConsentReader = Future<bool> Function(
  String stableSkillId,
);

/// Local template lifecycle: preview, install (disabled), enable/disable, and
/// rollback to the previously installed package.
///
/// Installing writes a controlled `skill.json` manifest plus the local
/// `SKILL.md`. The manifest is the only capability declaration the app trusts
/// afterwards: `SkillService` scans it as a normal manifested skill, enabling
/// needs the existing trust grant/consent, and `SkillCapabilityPolicy` denies
/// any tool the manifest did not declare. The service never runs the template
/// itself.
final class SkillTemplateService {
  SkillTemplateService({
    List<SkillTemplate>? templates,
    SkillTemplateFileWriter? writer,
    SkillTemplateEnableAction? enable,
    SkillTemplateEnabledReader? isEnabled,
    SkillTemplateConsentReader? isConsentCurrent,
  })  : templates =
            List.unmodifiable(templates ?? SkillTemplateCatalog.entries),
        _writer = writer ?? const NativeSkillTemplateFileWriter(),
        _enable = enable ?? _defaultEnable,
        _isEnabled = isEnabled ?? _defaultIsEnabled,
        _isConsentCurrent = isConsentCurrent ?? _defaultIsConsentCurrent;

  static const int maxTemplateBodyBytes = 16 * 1024;
  static const String manifestFileName = 'skill.json';
  static const String markdownFileName = 'SKILL.md';

  /// Reason code returned when enabling needs the existing consent flow first.
  static const String consentRequiredReason = 'template_consent_required';

  final List<SkillTemplate> templates;
  final SkillTemplateFileWriter _writer;
  final SkillTemplateEnableAction _enable;
  final SkillTemplateEnabledReader _isEnabled;
  final SkillTemplateConsentReader _isConsentCurrent;

  SkillTemplate? templateById(String id) {
    for (final template in templates) {
      if (template.id == id) return template;
    }
    return null;
  }

  String directoryFor(SkillTemplate template) =>
      '${SkillService.skillsDirectory}/${template.stableSkillId}';

  String markdownPathFor(SkillTemplate template) =>
      '${directoryFor(template)}/$markdownFileName';

  String manifestPathFor(SkillTemplate template) =>
      '${directoryFor(template)}/$manifestFileName';

  String rollbackPathFor(SkillTemplate template) =>
      '${markdownPathFor(template)}.rollback';

  String manifestRollbackPathFor(SkillTemplate template) =>
      '${manifestPathFor(template)}.rollback';

  /// The manifest the install writes for [template].
  ///
  /// Every declared capability expands through
  /// [skillTemplateManifestCapabilities]; an unknown capability fails here
  /// instead of silently producing an empty declaration.
  ExtensionManifest buildManifest(SkillTemplate template) {
    final tools = <String>{};
    final filesystemRead = <String>{};
    final filesystemWrite = <String>{};
    final androidPermissions = <String>{};
    final networkDomains = <String>{};
    for (final capability in template.capabilities) {
      final mapping = skillTemplateManifestCapabilities[capability.id];
      if (mapping == null) {
        throw FormatException('Unknown template capability: ${capability.id}');
      }
      tools.addAll(mapping.toolNames);
      filesystemRead.addAll(mapping.filesystemRead);
      filesystemWrite.addAll(mapping.filesystemWrite);
      androidPermissions.addAll(mapping.androidPermissions);
      networkDomains.addAll(mapping.networkDomains);
    }
    final riskTier = template.networkAccess || template.sensitiveData.isNotEmpty
        ? 'moderate'
        : 'low';
    final placeholder = ExtensionManifest(
      schemaVersion: ExtensionManifest.currentSchemaVersion,
      id: template.stableSkillId,
      name: template.name,
      description: template.summary,
      model: ModelFacingIdentity(
        name: template.stableSkillId,
        description: template.summary,
      ),
      version: '1.${template.version}.0',
      source: const ExtensionSource(type: 'local'),
      integrity: const ExtensionIntegrity(),
      author: 'ClawChat',
      license: 'GPL-3.0',
      capabilities: ExtensionCapabilities(
        tools: _sorted(tools),
        commands: const [],
        networkDomains: _sorted(networkDomains),
        filesystem: FilesystemCapabilities(
          read: _sorted(filesystemRead),
          write: _sorted(filesystemWrite),
        ),
        android: AndroidCapabilities(
          intents: const [],
          permissions: _sorted(androidPermissions),
        ),
        secrets: const [],
        subprocess: const SubprocessCapabilities(
          required: false,
          runtimes: [],
        ),
        riskTier: riskTier,
        updatePolicy: 'manual',
      ),
    );
    // The canonical digest excludes integrity, so a self-describing digest can
    // be embedded without recursing. A tampered or truncated `skill.json` then
    // fails `failsIntegrityClosed` at scan time instead of being read as an
    // unverified declaration.
    return ExtensionManifest(
      schemaVersion: placeholder.schemaVersion,
      id: placeholder.id,
      name: placeholder.name,
      description: placeholder.description,
      model: placeholder.model,
      version: placeholder.version,
      source: placeholder.source,
      integrity: ExtensionIntegrity(
        algorithm: 'sha256',
        digest: placeholder.canonicalDigest,
      ),
      author: placeholder.author,
      license: placeholder.license,
      capabilities: placeholder.capabilities,
    );
  }

  String buildManifestJson(SkillTemplate template) =>
      jsonEncode(buildManifest(template).toJson());

  /// Everything the user must see before installing: declared capabilities,
  /// the exact manifest declaration, network use, private data, and risk notes.
  SkillTemplatePreview preview(SkillTemplate template) {
    final riskNotes = <String>[];
    if (template.networkAccess) {
      riskNotes.add('模板声明会访问网络；实际网络动作仍由工具的既有策略决定。');
    } else {
      riskNotes.add('不访问网络。');
    }
    if (template.sensitiveData.isNotEmpty) {
      riskNotes.add('会接触手机隐私数据：${template.sensitiveData.join('、')}。');
    }
    riskNotes.add('安装会写入 skill.json 声明，安装后默认禁用；启用仍走现有技能同意与能力策略。');
    if (template.capabilities
        .any((capability) => capability.id.startsWith('workspace.'))) {
      riskNotes.add(
          '文件读写在当前能力策略下仍是显式拒绝（skill_filesystem_unenforceable），声明不会变成运行期文件权限。');
    }
    if (!_isValidTemplate(template)) {
      riskNotes.add('模板校验未通过，安装入口已关闭。');
    }
    return SkillTemplatePreview(
      template: template,
      capabilityLines: [
        for (final capability in template.capabilities)
          '${capability.label}（${capability.id}）：${capability.rationale}',
      ],
      manifestLines: _manifestLines(template),
      networkLine: template.networkAccess ? '需要网络：是' : '需要网络：否（仅本地文件与工具）',
      sensitiveDataLines: template.sensitiveData.isEmpty
          ? const ['不接触手机隐私数据']
          : List.unmodifiable(template.sensitiveData),
      riskNotes: List.unmodifiable(riskNotes),
    );
  }

  List<String> _manifestLines(SkillTemplate template) {
    if (!_isValidTemplate(template)) return const ['模板校验未通过，不生成声明。'];
    final manifest = buildManifest(template);
    final capabilities = manifest.capabilities;
    return [
      '工具：${capabilities.tools.join('、')}',
      if (capabilities.filesystem.read.isNotEmpty)
        '文件读取声明：${capabilities.filesystem.read.join('、')}',
      if (capabilities.filesystem.write.isNotEmpty)
        '文件写入声明：${capabilities.filesystem.write.join('、')}',
      if (capabilities.android.permissions.isNotEmpty)
        'Android 权限声明：${capabilities.android.permissions.join('、')}',
      if (capabilities.networkDomains.isNotEmpty)
        '网络域名声明：${capabilities.networkDomains.join('、')}',
      '风险等级：${capabilities.riskTier}',
    ];
  }

  bool isInstallable(SkillTemplate template) => _isValidTemplate(template);

  /// The installed package exactly as the consent flow needs it, read from the
  /// template's own files.
  ///
  /// The generic skill scan is not required here: it runs in the guest runtime
  /// and can be unavailable, and it is not what decides whether the files the
  /// user consented to are present. Returns null when the package is
  /// incomplete, so the caller reports a real failure instead of consent.
  Future<PreparedSkillImport?> installedCandidate(
      SkillTemplate template) async {
    final markdown = await _readOrNull(markdownPathFor(template));
    final manifest = await _readOrNull(manifestPathFor(template));
    if (markdown == null || manifest == null) return null;
    try {
      return SkillService.inspectPackage(
        stagingPath: directoryFor(template),
        sourceIdentity: 'Installed locally',
        skillContent: markdown,
        manifestContent: manifest,
        installedCandidate: true,
      );
    } on Object {
      return null;
    }
  }

  Future<SkillTemplateStatus> status(SkillTemplate template) async {
    final installed = await _readOrNull(markdownPathFor(template)) != null;
    final rollback = await _readOrNull(rollbackPathFor(template)) != null ||
        await _readOrNull(manifestRollbackPathFor(template)) != null;
    var enabled = false;
    if (installed) {
      enabled = await _isEnabledSafely(template.stableSkillId);
      if (!enabled) {
        enabled = await _installedTemplateEnabled(template);
        // The guest scan may not see the package at all (runtime unavailable).
        // The stored switch plus a grant matching the installed files is the
        // same state the scan reports, read without the guest.
      }
    }
    return SkillTemplateStatus(
      templateId: template.id,
      installed: installed,
      enabled: enabled,
      rollbackAvailable: rollback,
    );
  }

  /// Whether the installed template is enabled, decided from the files that are
  /// actually installed plus the stored switch and grant.
  Future<bool> _installedTemplateEnabled(SkillTemplate template) async {
    try {
      final candidate = await installedCandidate(template);
      if (candidate == null) return false;
      final grant = (await SkillService.loadTrustGrants())[candidate.id];
      final grantCurrent = grant != null &&
          grant.manifestDigest == candidate.manifestDigest &&
          grant.contentDigest == candidate.contentDigest &&
          grant.version == candidate.version &&
          grant.legacy == candidate.legacy;
      if (!grantCurrent) return false;
      return SkillService.isSkillStoredEnabled(
        candidate.id,
        aliases: [candidate.name],
      );
    } on Object {
      return false;
    }
  }

  /// Writes the controlled manifest and the local body, and leaves the skill
  /// disabled (the grant becomes stale, so consent is required again).
  ///
  /// Previous package files are preserved as rollback copies before they are
  /// replaced.
  Future<SkillTemplateActionResult> install(SkillTemplate template) async {
    if (!_isValidTemplate(template)) {
      return _failure(template, 'template_invalid');
    }
    try {
      final markdown = await _readOrNull(markdownPathFor(template));
      final manifest = await _readOrNull(manifestPathFor(template));
      if (markdown != null) {
        await _writer.write(rollbackPathFor(template), markdown);
      }
      if (manifest != null) {
        await _writer.write(manifestRollbackPathFor(template), manifest);
      }
      await _writer.write(markdownPathFor(template), template.skillMarkdown);
      await _writer.write(
          manifestPathFor(template), buildManifestJson(template));
      await _enableSafely(template.stableSkillId, false);
      return _result(template,
          succeeded: true,
          installed: true,
          enabled: false,
          rollbackAvailable: markdown != null || manifest != null);
    } catch (_) {
      return _failure(template, 'template_install_failed');
    }
  }

  /// Restores the previously installed package and disables the skill.
  Future<SkillTemplateActionResult> rollback(SkillTemplate template) async {
    if (!_isValidTemplate(template)) {
      return _failure(template, 'template_invalid');
    }
    try {
      final previousMarkdown = await _readOrNull(rollbackPathFor(template));
      final previousManifest =
          await _readOrNull(manifestRollbackPathFor(template));
      if (previousMarkdown == null && previousManifest == null) {
        return _failure(template, 'rollback_unavailable');
      }
      if (previousMarkdown != null) {
        await _writer.write(markdownPathFor(template), previousMarkdown);
        await _writer.delete(rollbackPathFor(template));
      }
      if (previousManifest != null) {
        await _writer.write(manifestPathFor(template), previousManifest);
        await _writer.delete(manifestRollbackPathFor(template));
      }
      await _enableSafely(template.stableSkillId, false);
      return _result(template,
          succeeded: true,
          installed: true,
          enabled: false,
          rollbackAvailable: false);
    } catch (_) {
      return _failure(template, 'template_rollback_failed');
    }
  }

  Future<SkillTemplateActionResult> setEnabled(
    SkillTemplate template,
    bool enabled,
  ) async {
    if (!_isValidTemplate(template)) {
      return _failure(template, 'template_invalid');
    }
    final installed = await _readOrNull(markdownPathFor(template)) != null;
    if (!installed) {
      return _failure(template, 'template_not_installed');
    }
    if (enabled && !await _isConsentCurrentSafely(template.stableSkillId)) {
      // Enabling without a current grant would flip a switch that the scan and
      // use-time checks ignore. Require the existing consent flow instead.
      return _failure(template, consentRequiredReason);
    }
    try {
      await _enableSafely(template.stableSkillId, enabled);
      final rollback = await _readOrNull(rollbackPathFor(template)) != null ||
          await _readOrNull(manifestRollbackPathFor(template)) != null;
      return _result(template,
          succeeded: true,
          installed: true,
          enabled: enabled,
          rollbackAvailable: rollback);
    } catch (_) {
      return _failure(template, 'template_enable_failed');
    }
  }

  Future<String?> _readOrNull(String path) async {
    try {
      return await _writer.read(path);
    } catch (_) {
      return null;
    }
  }

  Future<void> _enableSafely(String stableSkillId, bool enabled) async {
    await _enable(stableSkillId, enabled);
  }

  Future<bool> _isEnabledSafely(String stableSkillId) async {
    try {
      return await _isEnabled(stableSkillId);
    } catch (_) {
      return false;
    }
  }

  Future<bool> _isConsentCurrentSafely(String stableSkillId) async {
    try {
      return await _isConsentCurrent(stableSkillId);
    } catch (_) {
      return false;
    }
  }

  /// A template is installable only when its declared surface is one the app
  /// can reason about, its generated manifest round-trips, and its body carries
  /// no remote fetch instructions.
  bool _isValidTemplate(SkillTemplate template) {
    if (!_isSafeSegment(template.id) ||
        !_isSafeSegment(template.stableSkillId)) {
      return false;
    }
    if (template.body.trim().isEmpty ||
        utf8.encode(template.body).length > maxTemplateBodyBytes) {
      return false;
    }
    if (template.networkAccess &&
        !template.capabilities
            .any((capability) => capability.id == 'web.read')) {
      return false;
    }
    for (final capability in template.capabilities) {
      if (!knownSkillTemplateCapabilities.contains(capability.id) ||
          !skillTemplateManifestCapabilities.containsKey(capability.id)) {
        return false;
      }
    }
    if (!_manifestRoundTrips(template)) return false;
    return !_containsRemoteInstruction(template.body);
  }

  /// The generated manifest must parse as a normal app manifest and declare
  /// exactly the mapped capabilities: no more, no less.
  bool _manifestRoundTrips(SkillTemplate template) {
    try {
      final manifest = buildManifest(template);
      if (manifest.id != template.stableSkillId) return false;
      final parsed = ExtensionManifest.parse(buildManifestJson(template));
      if (parsed.failsIntegrityClosed ||
          parsed.integrityStatus != IntegrityStatus.verifiedDigest) {
        return false;
      }
      final expectedTools = <String>{};
      final expectedPermissions = <String>{};
      for (final capability in template.capabilities) {
        final mapping = skillTemplateManifestCapabilities[capability.id]!;
        expectedTools.addAll(mapping.toolNames);
        expectedPermissions.addAll(mapping.androidPermissions);
      }
      return parsed.capabilities.tools.toSet().containsAll(expectedTools) &&
          parsed.capabilities.tools.length == expectedTools.length &&
          parsed.capabilities.android.permissions
              .toSet()
              .containsAll(expectedPermissions) &&
          parsed.capabilities.subprocess.required == false &&
          parsed.capabilities.secrets.isEmpty;
    } on Object {
      return false;
    }
  }

  static List<String> _sorted(Set<String> values) =>
      values.toList(growable: false)..sort();

  static bool _containsRemoteInstruction(String body) {
    final lower = body.toLowerCase();
    return lower.contains('http://') ||
        lower.contains('https://') ||
        lower.contains('curl ') ||
        lower.contains('wget ');
  }

  static bool _isSafeSegment(String value) =>
      value.isNotEmpty &&
      value.length <= 64 &&
      !value.contains(RegExp(r'[^A-Za-z0-9._-]'));

  static SkillTemplateActionResult _result(
    SkillTemplate template, {
    required bool succeeded,
    required bool installed,
    required bool enabled,
    required bool rollbackAvailable,
  }) =>
      SkillTemplateActionResult(
        succeeded: succeeded,
        templateId: template.id,
        installed: installed,
        enabled: enabled,
        rollbackAvailable: rollbackAvailable,
      );

  static SkillTemplateActionResult _failure(
    SkillTemplate template,
    String reasonCode,
  ) =>
      SkillTemplateActionResult(
        succeeded: false,
        templateId: template.id,
        installed: false,
        enabled: false,
        rollbackAvailable: false,
        reasonCode: reasonCode,
      );

  static Future<void> _defaultEnable(String stableSkillId, bool enabled) async {
    await SkillService.setSkillEnabled(stableSkillId, enabled);
    await SkillService.setSkillEnabled('legacy.$stableSkillId', enabled);
  }

  static Future<bool> _defaultIsEnabled(String stableSkillId) async {
    for (final skill in await SkillService.scanSkills()) {
      if (_matchesStableId(skill, stableSkillId)) return skill.enabled;
    }
    return false;
  }

  static Future<bool> _defaultIsConsentCurrent(String stableSkillId) async {
    for (final skill in await SkillService.scanSkills()) {
      if (_matchesStableId(skill, stableSkillId)) {
        return skill.valid && skill.consentCurrent;
      }
    }
    return false;
  }

  static bool _matchesStableId(SkillInfo skill, String stableSkillId) =>
      skill.id == stableSkillId ||
      skill.name == stableSkillId ||
      skill.id == 'legacy.$stableSkillId';
}
