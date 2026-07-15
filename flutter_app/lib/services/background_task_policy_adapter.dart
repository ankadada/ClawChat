import '../models/background_task.dart';
import 'background_task_coordinator.dart';
import 'skill_capability_policy.dart';
import 'tools/tool_policy.dart';

final class BackgroundTaskPolicyBinding {
  const BackgroundTaskPolicyBinding({
    required this.toolName,
    required this.risk,
    required this.argumentsFor,
    required this.safeTargetFor,
  });

  /// A fixed, app-owned tool mapping. It is not a model-supplied executor.
  final String toolName;
  final ToolRisk risk;
  final Map<String, dynamic> Function(BackgroundTaskRecord task) argumentsFor;
  final String Function(BackgroundTaskRecord task) safeTargetFor;

  ToolApprovalRequest requestFor(
    BackgroundTaskRecord task,
    String operationId,
  ) =>
      ToolApprovalRequest(
        toolName: toolName,
        arguments: Map<String, dynamic>.from(argumentsFor(task)),
        risk: risk,
        operationId: operationId,
      );
}

abstract interface class BackgroundTaskPolicyBindingResolver {
  BackgroundTaskPolicyBinding? bindingFor(BackgroundTaskRecord task);
}

final class BackgroundTaskPolicySettingsSnapshot {
  const BackgroundTaskPolicySettingsSnapshot({
    required this.approvalPolicy,
    required this.deniedToolNames,
    required this.bashCommandDenyPatterns,
  });

  final String approvalPolicy;
  final Set<String> deniedToolNames;
  final List<String> bashCommandDenyPatterns;
}

abstract interface class BackgroundTaskPolicySettings {
  Future<BackgroundTaskPolicySettingsSnapshot> read();
}

enum BackgroundTaskApprovalKind { standard, externalSend }

final class BackgroundTaskApprovalPrompt {
  const BackgroundTaskApprovalPrompt({
    required this.task,
    required this.operationId,
    required this.request,
    required this.kind,
    required this.safeTargetSummary,
  });

  final BackgroundTaskRecord task;
  final String operationId;
  final ToolApprovalRequest request;
  final BackgroundTaskApprovalKind kind;
  final String safeTargetSummary;
}

abstract interface class BackgroundTaskApprovalGateway {
  Future<bool> requestStandard(BackgroundTaskApprovalPrompt prompt);
  Future<bool> requestExternalSend(BackgroundTaskApprovalPrompt prompt);
}

/// Uses the existing hard-deny and skill-capability policy types for v2.8
/// records. It does not provide an alternate allow path: hard deny is checked
/// first, skill deny second, and every approval reaches the supplied local UI
/// gateway. The external gateway is always interactive, including Auto Allow.
final class SharedBackgroundTaskPolicyAdapter implements BackgroundTaskPolicy {
  SharedBackgroundTaskPolicyAdapter({
    required BackgroundTaskPolicyBindingResolver bindings,
    required BackgroundTaskPolicySettings settings,
    required BackgroundTaskApprovalGateway approvals,
    SkillCapabilityPolicy Function()? skillPolicyFactory,
  })  : _bindings = bindings,
        _settings = settings,
        _approvals = approvals,
        _skillPolicyFactory = skillPolicyFactory ?? SkillCapabilityPolicy.new;

  final BackgroundTaskPolicyBindingResolver _bindings;
  final BackgroundTaskPolicySettings _settings;
  final BackgroundTaskApprovalGateway _approvals;
  final SkillCapabilityPolicy Function() _skillPolicyFactory;
  final Set<String> _sessionApprovedTools = <String>{};

  @override
  Future<BackgroundTaskPolicyDecision> hardAndSkillPreflight({
    required BackgroundTaskRecord task,
    required String operationId,
  }) async {
    final bound = await _boundRequestFor(task, operationId);
    if (bound == null) {
      return const BackgroundTaskPolicyDecision.deny(
          'task_policy_binding_invalid');
    }
    final toolPolicy = await _toolPolicy();
    final hardDeny = toolPolicy.denyFor(bound.request);
    if (hardDeny != null) {
      return const BackgroundTaskPolicyDecision.deny('task_hard_deny');
    }
    try {
      final skillDeny = _skillPolicyFactory().denyFor(bound.request);
      if (skillDeny != null) {
        return const BackgroundTaskPolicyDecision.deny('task_skill_deny');
      }
    } on Object {
      return const BackgroundTaskPolicyDecision.deny(
          'task_skill_policy_unavailable');
    }
    return const BackgroundTaskPolicyDecision.allow();
  }

  @override
  Future<BackgroundTaskPolicyDecision> requestStandardApproval({
    required BackgroundTaskRecord task,
    required String operationId,
  }) async {
    final preflight = await hardAndSkillPreflight(
      task: task,
      operationId: operationId,
    );
    if (!preflight.allowed) return preflight;
    final bound = await _boundRequestFor(task, operationId);
    if (bound == null) {
      return const BackgroundTaskPolicyDecision.deny(
          'task_policy_binding_invalid');
    }
    final settings = await _settings.read();
    if (settings.approvalPolicy == 'auto') {
      return const BackgroundTaskPolicyDecision.allow();
    }
    final sessionKey = '${task.sessionId}:${bound.request.toolName}';
    if (settings.approvalPolicy == 'session_first' &&
        _sessionApprovedTools.contains(sessionKey)) {
      return const BackgroundTaskPolicyDecision.allow();
    }
    final approved = await _approveWithTask(task, bound);
    if (!approved) {
      return const BackgroundTaskPolicyDecision.deny('task_approval_denied');
    }
    if (settings.approvalPolicy == 'session_first') {
      _sessionApprovedTools.add(sessionKey);
    }
    return const BackgroundTaskPolicyDecision.allow();
  }

  @override
  Future<BackgroundTaskPolicyDecision> requestExternalSendConfirmation({
    required BackgroundTaskRecord task,
    required String operationId,
  }) async {
    final preflight = await hardAndSkillPreflight(
      task: task,
      operationId: operationId,
    );
    if (!preflight.allowed) return preflight;
    final bound = await _boundRequestFor(task, operationId);
    if (bound == null) {
      return const BackgroundTaskPolicyDecision.deny(
          'task_policy_binding_invalid');
    }
    final approved = await _approvals.requestExternalSend(
      BackgroundTaskApprovalPrompt(
        task: task,
        operationId: operationId,
        request: bound.request,
        kind: BackgroundTaskApprovalKind.externalSend,
        safeTargetSummary: bound.safeTargetSummary,
      ),
    );
    return approved
        ? const BackgroundTaskPolicyDecision.allow()
        : const BackgroundTaskPolicyDecision.deny(
            'task_external_confirmation_denied',
          );
  }

  Future<_BoundBackgroundTaskRequest?> _boundRequestFor(
    BackgroundTaskRecord task,
    String operationId,
  ) async {
    try {
      final binding = _bindings.bindingFor(task);
      if (binding == null) return null;
      final safeTarget = binding.safeTargetFor(task).trim();
      if (!_isSafeTargetSummary(safeTarget)) return null;
      return _BoundBackgroundTaskRequest(
        request: binding.requestFor(task, operationId),
        safeTargetSummary: safeTarget,
      );
    } on BackgroundTaskFormatException {
      return null;
    } on Object {
      return null;
    }
  }

  Future<ToolPolicy> _toolPolicy() async {
    final settings = await _settings.read();
    return ToolPolicy(
      deniedToolNames: settings.deniedToolNames,
      bashCommandDenyPatterns: settings.bashCommandDenyPatterns,
      onApprovalRequired: (request) async {
        final pending = _approvalBindings[request.operationId];
        if (pending == null || pending.bound.request != request) return false;
        return _approvals.requestStandard(
          BackgroundTaskApprovalPrompt(
            task: pending.task,
            operationId: request.operationId,
            request: request,
            kind: BackgroundTaskApprovalKind.standard,
            safeTargetSummary: pending.bound.safeTargetSummary,
          ),
        );
      },
    );
  }

  // ToolPolicy exposes its callback with a ToolApprovalRequest only. Bind each
  // operation independently so concurrent task requests cannot borrow another
  // task's approval identity or safe target.
  final Map<String, _PendingBackgroundTaskApproval> _approvalBindings = {};

  Future<bool> _approveWithTask(
    BackgroundTaskRecord task,
    _BoundBackgroundTaskRequest bound,
  ) async {
    final operationId = bound.request.operationId;
    if (_approvalBindings.containsKey(operationId)) return false;
    _approvalBindings[operationId] =
        _PendingBackgroundTaskApproval(task, bound);
    try {
      return await (await _toolPolicy()).approve(bound.request);
    } finally {
      _approvalBindings.remove(operationId);
    }
  }
}

final class _BoundBackgroundTaskRequest {
  const _BoundBackgroundTaskRequest({
    required this.request,
    required this.safeTargetSummary,
  });

  final ToolApprovalRequest request;
  final String safeTargetSummary;
}

final class _PendingBackgroundTaskApproval {
  const _PendingBackgroundTaskApproval(this.task, this.bound);

  final BackgroundTaskRecord task;
  final _BoundBackgroundTaskRequest bound;
}

bool _isSafeTargetSummary(String value) =>
    value.isNotEmpty &&
    value.length <= 160 &&
    !value.contains(RegExp(r'[\x00-\x1f\x7f]'));
