import '../../services/llm_service.dart';
import '../../models/chat_models.dart';
import '../llm_content_sanitizer.dart';
import '../preferences_service.dart';
import 'bash_tool.dart';
import 'env_var_tool.dart';
import 'phone_intent_tool.dart';
import 'read_file_tool.dart';
import 'tool_result_formatter.dart';
import 'tool_policy.dart';
import 'write_file_tool.dart';
import 'web_fetch_tool.dart';
import 'web_search_tool.dart';
import 'image_gen_tool.dart';

abstract class Tool {
  String get name;
  String get description;
  Map<String, dynamic> get inputSchema;

  Future<String> execute(Map<String, dynamic> input);

  Future<ToolResultPayload> executeResult(Map<String, dynamic> input) async {
    final output = await execute(input);
    return ToolResultFormatter.format(
      toolName: name,
      input: input,
      output: output,
    );
  }

  ToolDefinition toDefinition() => ToolDefinition(
        name: name,
        description: description,
        inputSchema: inputSchema,
      );
}

class ToolRegistry {
  final Map<String, Tool> _tools = {};
  final Map<String, ToolRisk> _risks = {};

  ToolRegistry();

  factory ToolRegistry.withDefaults({PreferencesService? prefs}) {
    final registry = ToolRegistry();
    registry.register(BashTool(), risk: ToolRisk.dangerous);
    registry.register(ReadFileTool(), risk: ToolRisk.moderate);
    registry.register(WriteFileTool(), risk: ToolRisk.dangerous);
    registry.register(WebFetchTool(), risk: ToolRisk.moderate);
    registry.register(
      EnvVarTool(prefs ?? PreferencesService()),
      risk: ToolRisk.moderate,
    );
    if (prefs != null) {
      registry.register(PhoneIntentTool(prefs), risk: ToolRisk.dangerous);
    }
    registry.register(WebSearchTool(), risk: ToolRisk.safe);
    if (prefs != null) {
      registry.register(ImageGenTool(prefs), risk: ToolRisk.safe);
    }
    return registry;
  }

  void register(Tool tool, {ToolRisk risk = ToolRisk.dangerous}) {
    _tools[tool.name] = tool;
    _risks[tool.name] = risk;
  }

  void unregister(String name) {
    _tools.remove(name);
    _risks.remove(name);
  }

  List<ToolDefinition> getToolDefinitions() {
    return _tools.values.map((t) => t.toDefinition()).toList();
  }

  Future<String> executeTool(String name, Map<String, dynamic> input) async {
    final payload = await executeToolResult(name, input);
    return payload.forUser;
  }

  Future<ToolResultPayload> executeToolResult(
    String name,
    Map<String, dynamic> input,
  ) async {
    final tool = _tools[name];
    if (tool == null) throw Exception('Unknown tool: $name');
    return tool.executeResult(input);
  }

  static String sanitizeToolOutput(String output) {
    return const LlmContentSanitizer().sanitizeText(output).text;
  }

  bool hasTool(String name) => _tools.containsKey(name);

  ToolRisk riskFor(String name) => _risks[name] ?? ToolRisk.dangerous;

  List<String> get availableTools => _tools.keys.toList();
}
