import '../models/background_task.dart';
import 'background_task_coordinator.dart';
import 'background_task_policy_adapter.dart';
import 'memory_service.dart';
import 'native_bridge.dart';
import 'tools/tool_policy.dart';

typedef BackgroundTaskMemoryWriter = Future<bool> Function(
  String fact,
  String sessionId,
);
typedef BackgroundTaskShareLauncher = Future<bool> Function(
  String text,
  String? subject,
);

final class RegisteredBackgroundTaskKind {
  const RegisteredBackgroundTaskKind({
    required this.kind,
    required this.label,
    required this.description,
    required this.inputLabel,
    required this.requiresExternalSend,
    this.subjectLabel,
  });

  final String kind;
  final String label;
  final String description;
  final String inputLabel;
  final String? subjectLabel;
  final bool requiresExternalSend;
}

/// The finite, app-owned v2.8 registry. Its two definitions intentionally
/// call fixed local app APIs; no model, skill, or stored payload can install a
/// new definition or supply an arbitrary executor.
final class BackgroundTaskProductionDefinitions
    implements BackgroundTaskPolicyBindingResolver {
  BackgroundTaskProductionDefinitions({
    BackgroundTaskMemoryWriter? writeMemory,
    BackgroundTaskShareLauncher? launchShare,
  })  : _writeMemory = writeMemory ?? _defaultWriteMemory,
        _launchShare = launchShare ?? _defaultLaunchShare;

  static const rememberFactKind = 'remember_fact_v1';
  static const shareTextKind = 'share_text_v1';

  static const kinds = <RegisteredBackgroundTaskKind>[
    RegisteredBackgroundTaskKind(
      kind: rememberFactKind,
      label: '保存本地记忆',
      description: '把一条内容写入仅在本机保存的记忆。',
      inputLabel: '要保存的记忆',
      requiresExternalSend: false,
    ),
    RegisteredBackgroundTaskKind(
      kind: shareTextKind,
      label: '通过系统分享文本',
      description: '在确认后打开系统分享面板；外部送达结果不可自动验证。',
      inputLabel: '要分享的文本',
      subjectLabel: '分享主题（可选）',
      requiresExternalSend: true,
    ),
  ];

  final BackgroundTaskMemoryWriter _writeMemory;
  final BackgroundTaskShareLauncher _launchShare;

  List<BackgroundTaskDefinition> get definitions => [
        BackgroundTaskDefinition(
          kind: rememberFactKind,
          requiresExternalSend: false,
          dryRun: _rememberPreview,
          execute: _executeRemember,
        ),
        BackgroundTaskDefinition(
          kind: shareTextKind,
          requiresExternalSend: true,
          dryRun: _sharePreview,
          execute: _executeShare,
        ),
      ];

  RegisteredBackgroundTaskKind? kindFor(String kind) {
    for (final candidate in kinds) {
      if (candidate.kind == kind) return candidate;
    }
    return null;
  }

  Map<String, Object?> payloadFor({
    required String kind,
    required String text,
    String? subject,
  }) {
    final normalizedText = text.trim();
    if (kind == rememberFactKind) {
      return <String, Object?>{'version': 1, 'fact': normalizedText};
    }
    if (kind == shareTextKind) {
      return <String, Object?>{
        'version': 1,
        'text': normalizedText,
        'subject': subject?.trim().isEmpty ?? true ? null : subject!.trim(),
      };
    }
    throw const BackgroundTaskFormatException('task_kind_unregistered');
  }

  @override
  BackgroundTaskPolicyBinding? bindingFor(BackgroundTaskRecord task) {
    return switch (task.taskKind) {
      rememberFactKind => BackgroundTaskPolicyBinding(
          toolName: 'memory_add',
          risk: ToolRisk.moderate,
          argumentsFor: (record) => <String, dynamic>{
            'fact': _rememberPayload(record.localPayload),
          },
          safeTargetFor: (_) => '本机受保护的记忆存储',
        ),
      shareTextKind => BackgroundTaskPolicyBinding(
          toolName: 'phone_intent',
          risk: ToolRisk.dangerous,
          argumentsFor: (record) {
            final payload = _sharePayload(record.localPayload);
            return <String, dynamic>{
              'action': 'share',
              'params': <String, dynamic>{
                'text': payload.text,
                if (payload.subject != null) 'subject': payload.subject,
              },
            };
          },
          safeTargetFor: (_) => '系统分享面板',
        ),
      _ => null,
    };
  }

  BackgroundTaskPreview _rememberPreview(Map<String, Object?> payload) {
    final fact = _rememberPayload(payload);
    return BackgroundTaskPreview(
      safeSummary: '保存一条本地记忆（${fact.length} 个字符）',
      sideEffectSummary: '写入本机受保护的记忆存储',
    );
  }

  BackgroundTaskPreview _sharePreview(Map<String, Object?> payload) {
    final share = _sharePayload(payload);
    return BackgroundTaskPreview(
      safeSummary: '通过系统分享面板准备 ${share.text.length} 个字符的文本',
      sideEffectSummary: '可能向外部应用发送文本',
      targetSummary: '系统分享面板',
      unknowns: const ['接收方会在系统分享面板中选择，送达结果无法自动验证'],
    );
  }

  Future<BackgroundTaskExecutionResult> _executeRemember(
    BackgroundTaskRecord task,
  ) async {
    final fact = _rememberPayload(task.localPayload);
    final stored = await _writeMemory(fact, task.sessionId);
    return BackgroundTaskExecutionResult(
      succeeded: stored,
      outcomeKnown: true,
      safeSummary: stored ? '已保存到本地记忆' : '本地记忆未保存',
    );
  }

  Future<BackgroundTaskExecutionResult> _executeShare(
    BackgroundTaskRecord task,
  ) async {
    final payload = _sharePayload(task.localPayload);
    final opened = await _launchShare(payload.text, payload.subject);
    if (!opened) {
      return const BackgroundTaskExecutionResult(
        succeeded: false,
        outcomeKnown: true,
        safeSummary: '系统分享面板未打开',
      );
    }
    // Opening the chooser is locally observable; a later external send is not.
    return const BackgroundTaskExecutionResult(
      succeeded: true,
      outcomeKnown: false,
      safeSummary: '系统分享面板已打开，外部送达结果需要检查',
    );
  }

  static Future<bool> _defaultWriteMemory(String fact, String sessionId) async {
    if (!MemoryService.isEnabledForSessionSync(sessionId)) return false;
    final result = await MemoryService.addMemory(
      fact,
      source: 'background_task',
      sessionId: sessionId,
    );
    return result.index >= 0;
  }

  static Future<bool> _defaultLaunchShare(String text, String? subject) =>
      NativeBridge.shareText(text: text, subject: subject);
}

String _rememberPayload(Map<String, Object?> payload) {
  _requirePayloadKeys(payload, const {'version', 'fact'});
  if (payload['version'] != 1) {
    throw const BackgroundTaskFormatException(
        'remember_payload_version_invalid');
  }
  return _boundedPayloadText(
    payload['fact'],
    'remember_payload_fact_invalid',
    max: 2000,
  );
}

_SharePayload _sharePayload(Map<String, Object?> payload) {
  _requirePayloadKeys(payload, const {'version', 'text', 'subject'});
  if (payload['version'] != 1) {
    throw const BackgroundTaskFormatException('share_payload_version_invalid');
  }
  final subject = payload['subject'];
  return _SharePayload(
    _boundedPayloadText(payload['text'], 'share_payload_text_invalid',
        max: 2000),
    subject == null
        ? null
        : _boundedPayloadText(subject, 'share_payload_subject_invalid',
            max: 120),
  );
}

void _requirePayloadKeys(Map<String, Object?> payload, Set<String> expected) {
  if (payload.length != expected.length ||
      !payload.keys.toSet().containsAll(expected)) {
    throw const BackgroundTaskFormatException('task_payload_fields_invalid');
  }
}

String _boundedPayloadText(Object? value, String reasonCode,
    {required int max}) {
  if (value is! String || value.trim().isEmpty || value.length > max) {
    throw BackgroundTaskFormatException(reasonCode);
  }
  return value.trim();
}

final class _SharePayload {
  const _SharePayload(this.text, this.subject);

  final String text;
  final String? subject;
}
