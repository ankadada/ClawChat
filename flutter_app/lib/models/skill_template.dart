/// A capability a local template expects before it can do useful work.
///
/// The preview is descriptive, not a grant: enabling still goes through the
/// existing skill consent and capability policy.
final class SkillTemplateCapability {
  const SkillTemplateCapability({
    required this.id,
    required this.label,
    required this.rationale,
  });

  final String id;
  final String label;
  final String rationale;

  bool get isSensitive => switch (id) {
        'phone.calendar.read' ||
        'phone.sms.read' ||
        'phone.contacts.read' =>
          true,
        _ => false,
      };
}

/// One app-owned workflow template.
///
/// Templates are compiled into the app. They carry no URL, no installer
/// command, and no remote fetch: installing one writes a local `SKILL.md` into
/// the workspace skills directory, disabled.
final class SkillTemplate {
  const SkillTemplate({
    required this.id,
    required this.stableSkillId,
    required this.name,
    required this.summary,
    required this.version,
    required this.capabilities,
    required this.networkAccess,
    required this.sensitiveData,
    required this.body,
  });

  final String id;

  /// Directory/stable id under the workspace skills directory.
  final String stableSkillId;

  final String name;
  final String summary;
  final int version;
  final List<SkillTemplateCapability> capabilities;

  /// True when the workflow may reach the network through an existing tool.
  final bool networkAccess;

  /// Human-readable list of private data the workflow can touch.
  final List<String> sensitiveData;

  /// The local `SKILL.md` body written on install.
  final String body;

  String get skillMarkdown => '${body.trimRight()}\n';
}

/// What the user sees before installing or enabling a template.
final class SkillTemplatePreview {
  const SkillTemplatePreview({
    required this.template,
    required this.capabilityLines,
    required this.manifestLines,
    required this.networkLine,
    required this.sensitiveDataLines,
    required this.riskNotes,
  });

  final SkillTemplate template;
  final List<String> capabilityLines;

  /// The exact `skill.json` declaration the install writes.
  final List<String> manifestLines;

  final String networkLine;
  final List<String> sensitiveDataLines;
  final List<String> riskNotes;

  String get title => template.name;

  bool get touchesSensitiveData => template.sensitiveData.isNotEmpty;
}

/// Local install state for one template.
final class SkillTemplateStatus {
  const SkillTemplateStatus({
    required this.templateId,
    required this.installed,
    required this.enabled,
    required this.rollbackAvailable,
  });

  final String templateId;
  final bool installed;
  final bool enabled;
  final bool rollbackAvailable;
}

/// Result of an install/rollback action.
final class SkillTemplateActionResult {
  const SkillTemplateActionResult({
    required this.succeeded,
    required this.templateId,
    required this.installed,
    required this.enabled,
    required this.rollbackAvailable,
    this.reasonCode,
  });

  final bool succeeded;
  final String templateId;
  final bool installed;
  final bool enabled;
  final bool rollbackAvailable;
  final String? reasonCode;
}

/// The declared capability ids the app knows how to reason about. A template
/// that declares anything else fails the preview closed.
const Set<String> knownSkillTemplateCapabilities = {
  'workspace.read',
  'workspace.write',
  'memory.read',
  'memory.write',
  'web.read',
  'phone.calendar.read',
};

/// The manifest fields one declared template capability expands to.
///
/// This is the single mapping the preview, the installed `skill.json`, and the
/// skill capability policy all agree on: a template never gains a capability
/// that is not written here, and the installed manifest is the only trust
/// source the app reads back.
final class SkillTemplateManifestCapability {
  const SkillTemplateManifestCapability({
    required this.toolNames,
    this.filesystemRead = const [],
    this.filesystemWrite = const [],
    this.androidPermissions = const [],
    this.networkDomains = const [],
  });

  final List<String> toolNames;
  final List<String> filesystemRead;
  final List<String> filesystemWrite;
  final List<String> androidPermissions;
  final List<String> networkDomains;
}

/// Capability id → manifest declaration.
const Map<String, SkillTemplateManifestCapability>
    skillTemplateManifestCapabilities = {
  'workspace.read': SkillTemplateManifestCapability(
    toolNames: ['read_file'],
    filesystemRead: ['/root/workspace'],
  ),
  'workspace.write': SkillTemplateManifestCapability(
    toolNames: ['write_file'],
    filesystemWrite: ['/root/workspace'],
  ),
  'memory.read': SkillTemplateManifestCapability(
    toolNames: ['memory_get'],
  ),
  'memory.write': SkillTemplateManifestCapability(
    toolNames: ['memory_write'],
  ),
  'phone.calendar.read': SkillTemplateManifestCapability(
    toolNames: ['phone_read'],
    androidPermissions: ['READ_CALENDAR'],
  ),
  // Web access is only the app's fixed search endpoint: a template cannot
  // declare an arbitrary host, and `web_fetch` of any other domain stays denied
  // by the existing skill capability policy.
  'web.read': SkillTemplateManifestCapability(
    toolNames: ['web_search'],
    networkDomains: ['html.duckduckgo.com'],
  ),
};
