import '../../models/structured_result.dart';
import 'tool_registry.dart';

/// Definition-only app-owned ingress for fixed structured presentation data.
///
/// [AgentService] intercepts this name before generic tool execution. Keeping
/// the definition in the registry makes the provider-visible schema explicit
/// without granting a model a generic UI or callback surface.
final class PresentStructuredResultTool extends Tool {
  @override
  String get name => StructuredResultIngress.toolName;

  @override
  String get description =>
      'Present a bounded structured result document. This stores data only and does not execute actions.';

  @override
  Map<String, dynamic> get inputSchema => const {
        'type': 'object',
        'additionalProperties': false,
        'required': ['documentJson'],
        'properties': {
          'documentJson': {
            'type': 'string',
            'description': 'Strict structured-result document JSON.',
            'maxLength': 16384,
          },
        },
      };

  @override
  Future<String> execute(Map<String, dynamic> input) {
    throw StateError('Structured-result ingress must be intercepted.');
  }
}
