import 'skill_service.dart';

/// Removes publisher-controlled skill instructions from persisted history
/// before context planning, summary generation, recovery, or comparison.
///
/// The fixed marker preserves provider tool-pair structure. Current skill
/// bytes may only be reconstructed later by AgentService from a live verified
/// grant; summaries therefore never become an instruction cache.
class SkillHistoryProjection {
  static const omittedMarker =
      '[Local skill instructions omitted. Reactivate with load_skill before use.]';

  const SkillHistoryProjection._();

  static List<Map<String, dynamic>> project(
    List<Map<String, dynamic>> messages,
  ) {
    final activationIds = <String>{};
    for (final message in messages) {
      final content = message['content'];
      if (content is! List) continue;
      for (final raw in content) {
        if (raw is! Map || raw['type'] != 'tool_use') continue;
        final name = (raw['name'] ?? raw['tool_name'])?.toString();
        final input = raw['input'] ?? raw['tool_input'];
        final id = (raw['id'] ?? raw['tool_use_id'])?.toString();
        final path = input is Map ? input['path'] : null;
        if (id != null &&
            (name == 'load_skill' ||
                (name == 'read_file' &&
                    path is String &&
                    SkillService.isInstalledSkillEntrypoint(path)))) {
          activationIds.add(id);
        }
      }
    }

    return messages.map((message) {
      final content = message['content'];
      if (content is! List) return Map<String, dynamic>.from(message);
      final projected = <dynamic>[];
      for (final raw in content) {
        if (raw is! Map) {
          projected.add(raw);
          continue;
        }
        final block = Map<String, dynamic>.from(raw);
        final id = block['tool_use_id']?.toString();
        final metadata = block['metadata'];
        final hasSkillMetadata = metadata is Map &&
            (metadata['skillId'] is String ||
                metadata['skillEntrypoint'] is String);
        if (block['type'] == 'tool_result' &&
            ((id != null && activationIds.contains(id)) || hasSkillMetadata)) {
          projected.add(<String, dynamic>{
            'type': 'tool_result',
            'tool_use_id': id ?? '',
            'content': omittedMarker,
            if (block['is_error'] == true) 'is_error': true,
          });
        } else {
          projected.add(block);
        }
      }
      return <String, dynamic>{...message, 'content': projected};
    }).toList();
  }
}
