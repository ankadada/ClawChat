import 'package:clawchat/services/skill_history_projection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('projects retained load_skill pair to a fixed bounded marker', () {
    final projected = SkillHistoryProjection.project([
      {
        'role': 'assistant',
        'content': [
          {
            'type': 'tool_use',
            'id': 'load_1',
            'name': 'load_skill',
            'input': {'id': 'com.example.demo'},
          },
        ],
      },
      {
        'role': 'user',
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': 'load_1',
            'content': 'untrusted-skill-body',
          },
        ],
      },
    ]);

    final serialized = projected.toString();
    expect(serialized, isNot(contains('untrusted-skill-body')));
    expect(serialized, contains(SkillHistoryProjection.omittedMarker));
  });

  test('projects metadata-tagged result even when activation pair was dropped',
      () {
    final projected = SkillHistoryProjection.project([
      {
        'role': 'user',
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': 'dropped_load',
            'content': 'stale-skill-body',
            'metadata': {
              'skillId': 'com.example.demo',
              'skillTrustDigest': List.filled(64, 'a').join(),
            },
          },
        ],
      },
    ]);

    final serialized = projected.toString();
    expect(serialized, isNot(contains('stale-skill-body')));
    expect(serialized, contains(SkillHistoryProjection.omittedMarker));
    expect(serialized, isNot(contains('skillTrustDigest')));
  });
}
