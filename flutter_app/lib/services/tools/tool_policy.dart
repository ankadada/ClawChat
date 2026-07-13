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
  final String? runAttemptId;
  final String operationId;

  const ToolApprovalRequest({
    required this.toolName,
    required this.arguments,
    required this.risk,
    required this.operationId,
    this.runAttemptId,
  });
}

typedef ToolApprovalCallback = FutureOr<bool> Function(
  ToolApprovalRequest request,
);

typedef ToolAdditionalDenyCheck = ToolDenyDecision? Function(
  ToolApprovalRequest request,
);

class ToolDenyDecision {
  final String ruleType;
  final String ruleId;
  final String message;

  const ToolDenyDecision({
    required this.ruleType,
    required this.ruleId,
    required this.message,
  });
}

class ToolPolicy {
  final Set<ToolRisk> approvalRequiredFor;
  final ToolApprovalCallback? onApprovalRequired;
  final Set<String> deniedToolNames;
  final List<String> bashCommandDenyPatterns;
  final ToolAdditionalDenyCheck? additionalDenyCheck;

  const ToolPolicy({
    this.approvalRequiredFor = const {ToolRisk.moderate, ToolRisk.dangerous},
    this.onApprovalRequired,
    this.deniedToolNames = const {},
    this.bashCommandDenyPatterns = const [],
    this.additionalDenyCheck,
  });

  bool requiresApproval(ToolRisk risk) => approvalRequiredFor.contains(risk);

  ToolDenyDecision? denyFor(ToolApprovalRequest request) {
    if (deniedToolNames.contains(request.toolName)) {
      return ToolDenyDecision(
        ruleType: 'tool',
        ruleId: 'tool:${request.toolName}',
        message: 'Tool blocked by safety settings.',
      );
    }
    final command = _shellLikeCommand(request);
    if (command != null && command.isNotEmpty) {
      for (var i = 0; i < bashCommandDenyPatterns.length; i++) {
        if (_matchesBashDenyPattern(command, bashCommandDenyPatterns[i])) {
          return ToolDenyDecision(
            ruleType: 'bash_pattern',
            ruleId: 'bash_pattern_${i + 1}',
            message: 'Bash command blocked by safety settings.',
          );
        }
      }
    }
    return additionalDenyCheck?.call(request);
  }

  Future<bool> approve(ToolApprovalRequest request) async {
    if (denyFor(request) != null) return false;
    if (!requiresApproval(request.risk)) return true;

    final callback = onApprovalRequired;
    if (callback == null) return false;

    return callback(request);
  }

  bool _matchesBashDenyPattern(String command, String pattern) {
    final normalizedPattern = pattern.trim();
    if (normalizedPattern.isEmpty) return false;
    try {
      return RegExp(normalizedPattern, caseSensitive: false).hasMatch(command);
    } on FormatException {
      return command.toLowerCase().contains(normalizedPattern.toLowerCase());
    }
  }

  String? _shellLikeCommand(ToolApprovalRequest request) {
    if (request.toolName == 'bash') {
      final command = request.arguments['command'];
      return command is String ? command : null;
    }
    if (!request.toolName.startsWith('mcp_')) return null;
    for (final key in const ['command', 'cmd', 'script']) {
      final value = request.arguments[key];
      if (value is String && value.trim().isNotEmpty) return value;
    }
    return null;
  }
}
