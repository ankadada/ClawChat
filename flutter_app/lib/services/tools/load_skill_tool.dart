import 'tool_registry.dart';

/// Declares the dedicated local-skill activation operation to the model.
///
/// [AgentService] intercepts this tool before registry execution, verifies the
/// current install grant, and returns the exact verified SKILL.md bytes. The
/// registry implementation is deliberately non-functional so callers cannot
/// bypass that trust boundary by invoking the tool directly.
class LoadSkillTool extends Tool {
  @override
  String get name => 'load_skill';

  @override
  String get description =>
      'Activate a locally installed skill by stable ID. The runtime verifies '
      'the current consent grant before returning any skill instructions.';

  @override
  Map<String, dynamic> get inputSchema => const {
        'type': 'object',
        'properties': {
          'id': {
            'type': 'string',
            'description': 'Stable skill ID from the available-skill ID list',
          },
        },
        'required': ['id'],
        'additionalProperties': false,
      };

  @override
  Future<String> execute(Map<String, dynamic> input) async =>
      'Error: load_skill is available only through the verified agent runtime.';
}
