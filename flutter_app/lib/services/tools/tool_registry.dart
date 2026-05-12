import '../../services/llm_service.dart';
import 'bash_tool.dart';
import 'read_file_tool.dart';
import 'write_file_tool.dart';
import 'web_fetch_tool.dart';

abstract class Tool {
  String get name;
  String get description;
  Map<String, dynamic> get inputSchema;

  Future<String> execute(Map<String, dynamic> input);

  ToolDefinition toDefinition() => ToolDefinition(
    name: name,
    description: description,
    inputSchema: inputSchema,
  );
}

class ToolRegistry {
  final Map<String, Tool> _tools = {};

  ToolRegistry();

  factory ToolRegistry.withDefaults() {
    final registry = ToolRegistry();
    registry.register(BashTool());
    registry.register(ReadFileTool());
    registry.register(WriteFileTool());
    registry.register(WebFetchTool());
    return registry;
  }

  void register(Tool tool) {
    _tools[tool.name] = tool;
  }

  void unregister(String name) {
    _tools.remove(name);
  }

  List<ToolDefinition> getToolDefinitions() {
    return _tools.values.map((t) => t.toDefinition()).toList();
  }

  Future<String> executeTool(String name, Map<String, dynamic> input) async {
    final tool = _tools[name];
    if (tool == null) throw Exception('Unknown tool: $name');
    return tool.execute(input);
  }

  List<String> get availableTools => _tools.keys.toList();
}
