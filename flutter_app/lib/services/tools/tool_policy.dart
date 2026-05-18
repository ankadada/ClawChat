import 'dart:async';

enum ToolRisk {
  safe,
  moderate,
  dangerous,
}

class ToolApprovalRequest {
  final String toolName;
  final Map<String, dynamic> arguments;
  final ToolRisk risk;

  const ToolApprovalRequest({
    required this.toolName,
    required this.arguments,
    required this.risk,
  });
}

typedef ToolApprovalCallback = FutureOr<bool> Function(
  ToolApprovalRequest request,
);

class ToolPolicy {
  final Set<ToolRisk> approvalRequiredFor;
  final ToolApprovalCallback? onApprovalRequired;

  const ToolPolicy({
    this.approvalRequiredFor = const {ToolRisk.moderate, ToolRisk.dangerous},
    this.onApprovalRequired,
  });

  bool requiresApproval(ToolRisk risk) => approvalRequiredFor.contains(risk);

  Future<bool> approve(ToolApprovalRequest request) async {
    if (!requiresApproval(request.risk)) return true;

    final callback = onApprovalRequired;
    if (callback == null) return false;

    return callback(request);
  }
}
