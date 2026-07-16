/// Shared names for the app-owned XDS typed-adapter contract.
///
/// These constants describe the adapter's fixed service boundary; they do not
/// grant capabilities to a legacy identity or to a skill manifest. The agent
/// exposes the adapter only when the app has a configured token, and the tool
/// still owns its fixed origin, schema, bounded input, and approval boundary.
final class LegacySkillCompatibility {
  const LegacySkillCompatibility._();

  static const xdsToolName = 'xds_agent';
  static const xdsDomain = 'ai-xds.tapdb.net';
  static const xdsTokenName = 'XDS_AGENT_TOKEN';
}
