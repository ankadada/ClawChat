class ToolCallExpansionState {
  ToolCallExpansionState._();

  static final Map<String, bool> _expandedByToolId = {};

  static bool isExpanded(String toolId) => _expandedByToolId[toolId] ?? false;

  static void setExpanded(String toolId, bool expanded) {
    _expandedByToolId[toolId] = expanded;
  }

  static void clear() => _expandedByToolId.clear();
}
