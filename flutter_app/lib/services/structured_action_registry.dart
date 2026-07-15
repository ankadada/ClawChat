import '../models/structured_result.dart';
import 'tools/memory_tools.dart';
import 'tools/tool_policy.dart';
import 'tools/tool_registry.dart';

/// App-owned bridge from a fixed structured-result action kind to one existing
/// tool contract.  This intentionally has no callback or generic tool-name
/// input: model data can select only the v2.7 allowlisted action below.
final class StructuredActionRegistry {
  const StructuredActionRegistry._();

  static const saveToMemoryKind = 'save_to_memory';
  static const memoryWriteToolName = 'memory_write';

  static StructuredActionResolution? resolve(
    StructuredResultAction action, {
    required ToolRegistry tools,
    required String sessionId,
  }) {
    if (action.kind != saveToMemoryKind) return null;

    // Re-check and normalize the persisted model through the same pure helper
    // used by receipt hashing and restart ownership validation.
    final canonicalInput = canonicalStructuredActionInput(
      action.kind,
      action.payload,
    );
    if (canonicalInput == null) return null;

    final inputSchema = tools.inputSchemaFor(
      memoryWriteToolName,
      sessionId: sessionId,
    );
    if (inputSchema == null ||
        !MemoryWriteTool.isStructuredActionCompatibleSchema(inputSchema)) {
      return null;
    }

    return StructuredActionResolution(
      actionKind: saveToMemoryKind,
      toolName: memoryWriteToolName,
      input: Map<String, dynamic>.unmodifiable(canonicalInput),
      inputSchema: Map.unmodifiable(inputSchema),
      risk: tools.riskFor(memoryWriteToolName),
    );
  }
}

/// Fully resolved, app-owned action data.  The provider passes only this
/// exact input to [ToolRegistry], after the normal policy/approval pipeline.
final class StructuredActionResolution {
  const StructuredActionResolution({
    required this.actionKind,
    required this.toolName,
    required this.input,
    required this.inputSchema,
    required this.risk,
  });

  final String actionKind;
  final String toolName;
  final Map<String, dynamic> input;
  final Map<String, dynamic> inputSchema;
  final ToolRisk risk;
}
