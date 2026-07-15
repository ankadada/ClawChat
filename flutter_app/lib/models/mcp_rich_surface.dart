import 'dart:convert';

import 'chat_models.dart';
import 'structured_result.dart';

final _sensitiveDisplayMarkers = <RegExp>[
  RegExp(
    r'\b(?:api[ _-]?key|access[ _-]?token|authorization|password|secret|bearer|private[ _-]?key)\b',
    caseSensitive: false,
  ),
  RegExp(r'\b(?:sk|rk)_[A-Za-z0-9_-]{12,}\b'),
  RegExp(r'\bAKIA[0-9A-Z]{16}\b'),
  RegExp(r'-----BEGIN [A-Z ]+KEY-----'),
];

/// A deliberately small, host-owned description of an optional rich surface.
///
/// This is not a structured-result block and is never accepted from model
/// prose, tool output, or arbitrary HTML. The app-owned adapter below may
/// derive it from an already strict native result, and the user must still
/// expand it explicitly. The data sent to the WebView has no tool payload,
/// capability, URL, or secret field.
final class McpRichSurface {
  factory McpRichSurface({
    required String surfaceId,
    required String sessionId,
    required String resultId,
    required String operationId,
    required McpRichSurfaceViewModel view,
  }) {
    if (!_isOpaqueId(surfaceId) ||
        !_isOpaqueId(sessionId) ||
        !_isOpaqueId(resultId) ||
        !_isOpaqueId(operationId)) {
      throw const McpRichSurfaceException('invalid_surface_identity');
    }
    final surface = McpRichSurface._(
      surfaceId: surfaceId,
      sessionId: sessionId,
      resultId: resultId,
      operationId: operationId,
      view: view,
    );
    if (utf8.encode(jsonEncode(surface.renderMessage)).length >
        maxMessageBytes) {
      throw const McpRichSurfaceException('render_too_large');
    }
    return surface;
  }

  const McpRichSurface._({
    required this.surfaceId,
    required this.sessionId,
    required this.resultId,
    required this.operationId,
    required this.view,
  });

  static const int schemaVersion = 1;
  static const int maxMessageBytes = 4 * 1024;

  /// The bridge checks this constant in every message. It is an origin label
  /// for the fixed local document, not a network origin or an authorization.
  static const String localOrigin = 'clawchat_mcp_rich_local_v1';
  static const String hostStatusRenderer = 'host_status_v1';

  final String surfaceId;
  final String sessionId;
  final String resultId;
  final String operationId;
  final McpRichSurfaceViewModel view;

  /// The only host-to-WebView message. Values are fixed data fields rendered
  /// with DOM text nodes by the host-owned local document.
  Map<String, Object?> get renderMessage => {
        'schemaVersion': schemaVersion,
        'origin': localOrigin,
        'type': 'render',
        'surfaceId': surfaceId,
        'renderer': hostStatusRenderer,
        'view': view.toWire(),
      };
}

/// Converts an already strict, persisted native result into the sole reviewed
/// local renderer. This adapter is app-owned: it accepts no HTML, URL, tool
/// name, action payload, or model-selected renderer.
final class McpRichSurfaceAdapter {
  const McpRichSurfaceAdapter._();

  static McpRichSurface? fromStructuredResult({
    required String sessionId,
    required StructuredResultContent content,
    Set<String> availableActionIds = const <String>{},
  }) {
    if (content.isInvalid) return null;
    try {
      final document = content.document;
      final metrics = <McpRichSurfaceMetric>[];
      final richActions = <McpRichSurfaceActionRef>[];
      for (final block in document.blocks) {
        switch (block) {
          case StructuredKeyValueBlock(:final items):
            for (final item in items) {
              if (metrics.length >= 12) return null;
              metrics.add(McpRichSurfaceMetric(
                label: _display(item.key, 48),
                value: _display(item.value, 120),
              ));
            }
          case StructuredActionListBlock(actions: final blockActions):
            for (final action in blockActions) {
              if (!availableActionIds.contains(action.actionId)) continue;
              if (richActions.length >= 4) return null;
              richActions.add(McpRichSurfaceActionRef(
                actionId: action.actionId,
                label: _display(action.label, 160),
              ));
            }
          case StructuredNoticeBlock() || StructuredItemListBlock():
            break;
        }
      }
      return McpRichSurface(
        surfaceId: 'structured.${document.resultId}',
        sessionId: sessionId,
        resultId: document.resultId,
        operationId: 'display.${document.resultId}',
        view: McpRichSurfaceViewModel(
          title: 'Structured result details',
          summary: _display(document.projection, 240),
          metrics: metrics,
          actions: richActions,
        ),
      );
    } on McpRichSurfaceException {
      return null;
    }
  }

  static String _display(String value, int maxScalars) {
    final display = StructuredText.display(value);
    if (display.isEmpty) {
      throw const McpRichSurfaceException('invalid_render_view');
    }
    final runes = display.runes.toList(growable: false);
    if (runes.length <= maxScalars) return display;
    return '${String.fromCharCodes(runes.take(maxScalars - 1))}\u2026';
  }
}

/// Bounded display data for the sole reviewed local renderer.
///
/// It intentionally has no HTML, Markdown, callback, URL, tool name, action
/// payload, or capability field. Sensitive source data must be summarized by
/// native code before this object is constructed.
final class McpRichSurfaceViewModel {
  factory McpRichSurfaceViewModel({
    required String title,
    required String summary,
    List<McpRichSurfaceMetric> metrics = const [],
    List<McpRichSurfaceActionRef> actions = const [],
  }) {
    if (!_isSafeText(title, min: 1, max: 80) ||
        !_isSafeText(summary, min: 1, max: 240) ||
        metrics.length > 12 ||
        actions.length > 4) {
      throw const McpRichSurfaceException('invalid_render_view');
    }
    final metricKeys = <String>{};
    if (!metrics.every((metric) => metricKeys.add(metric.label))) {
      throw const McpRichSurfaceException('duplicate_render_metric');
    }
    final actionIds = <String>{};
    if (!actions.every((action) => actionIds.add(action.actionId))) {
      throw const McpRichSurfaceException('duplicate_render_action');
    }
    return McpRichSurfaceViewModel._(
      title: title,
      summary: summary,
      metrics: List.unmodifiable(metrics),
      actions: List.unmodifiable(actions),
    );
  }

  const McpRichSurfaceViewModel._({
    required this.title,
    required this.summary,
    required this.metrics,
    required this.actions,
  });

  final String title;
  final String summary;
  final List<McpRichSurfaceMetric> metrics;
  final List<McpRichSurfaceActionRef> actions;

  Map<String, Object?> toWire() => {
        'title': title,
        'summary': summary,
        'metrics': metrics.map((metric) => metric.toWire()).toList(),
        'actions': actions.map((action) => action.toWire()).toList(),
      };
}

final class McpRichSurfaceMetric {
  factory McpRichSurfaceMetric({
    required String label,
    required String value,
  }) {
    if (!_isSafeText(label, min: 1, max: 48) ||
        !_isSafeText(value, min: 1, max: 120)) {
      throw const McpRichSurfaceException('invalid_render_metric');
    }
    return McpRichSurfaceMetric._(label: label, value: value);
  }

  const McpRichSurfaceMetric._({required this.label, required this.value});

  final String label;
  final String value;

  Map<String, Object?> toWire() => {'label': label, 'value': value};
}

/// A native-owned reference to an already registered structured action.
///
/// It is display metadata only. The WebView cannot provide or alter the action
/// payload, and tapping it returns to Flutter for the receipt/policy path.
final class McpRichSurfaceActionRef {
  factory McpRichSurfaceActionRef({
    required String actionId,
    required String label,
  }) {
    if (!_isStructuredActionId(actionId) ||
        !_isSafeText(label, min: 1, max: 160)) {
      throw const McpRichSurfaceException('invalid_render_action');
    }
    return McpRichSurfaceActionRef._(actionId: actionId, label: label);
  }

  const McpRichSurfaceActionRef._({
    required this.actionId,
    required this.label,
  });

  final String actionId;
  final String label;

  Map<String, Object?> toWire() => {'actionId': actionId, 'label': label};
}

final class McpRichSurfaceException implements Exception {
  const McpRichSurfaceException(this.reasonCode);

  final String reasonCode;

  @override
  String toString() => 'McpRichSurfaceException($reasonCode)';
}

bool isMcpRichSurfaceId(String value) => _isOpaqueId(value);

bool _isOpaqueId(String value) =>
    value.isNotEmpty &&
    value.length <= 128 &&
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]*$').hasMatch(value);

bool _isStructuredActionId(String value) =>
    value.isNotEmpty &&
    value.length <= 96 &&
    RegExp(r'^[a-z0-9._-]+$').hasMatch(value);

bool _isSafeText(String value, {required int min, required int max}) {
  final scalarCount = value.runes.length;
  if (scalarCount < min || scalarCount > max) return false;
  return !value.runes.any((scalar) => scalar <= 0x1f || scalar == 0x7f) &&
      !_sensitiveDisplayMarkers.any((pattern) => pattern.hasMatch(value));
}
