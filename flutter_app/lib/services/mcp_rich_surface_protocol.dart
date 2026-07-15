import '../models/mcp_rich_surface.dart';
import '../providers/chat_provider.dart';
import 'strict_json_decoder.dart';

/// Closed, local WebView protocol for [McpRichSurface].
///
/// Messages are strict JSON because a JavaScript channel only transports a
/// string. No input value becomes HTML, a navigation URL, a tool argument, or
/// a permission decision.
final class McpRichSurfaceProtocol {
  const McpRichSurfaceProtocol._();

  static const _decoder = StrictJsonDecoder(
    maxUtf8Bytes: McpRichSurface.maxMessageBytes,
    maxNestingDepth: 8,
  );

  static McpRichSurfaceInboundMessage decodeInbound(String rawMessage) {
    final Object? decoded;
    try {
      decoded = _decoder.decodeString(rawMessage);
    } on StrictJsonDecodeException catch (error) {
      throw McpRichSurfaceProtocolException('rich_${error.reasonCode}');
    }
    if (decoded is! Map) {
      throw const McpRichSurfaceProtocolException('rich_message_shape');
    }
    final message = <String, Object?>{};
    for (final entry in decoded.entries) {
      if (entry.key is! String) {
        throw const McpRichSurfaceProtocolException('rich_message_shape');
      }
      message[entry.key as String] = entry.value;
    }

    final type = _common(message);
    return switch (type) {
      'resize' => _decodeResize(message),
      'request_action' => _decodeAction(message),
      'open_link' => _decodeOpenLink(message),
      'close' => _decodeClose(message),
      _ => throw const McpRichSurfaceProtocolException('rich_message_type'),
    };
  }

  static String _common(Map<String, Object?> message) {
    final version = message['schemaVersion'];
    final origin = message['origin'];
    final type = message['type'];
    final surfaceId = message['surfaceId'];
    if (version is! int || version != McpRichSurface.schemaVersion) {
      throw const McpRichSurfaceProtocolException('rich_schema_version');
    }
    if (origin is! String || origin != McpRichSurface.localOrigin) {
      throw const McpRichSurfaceProtocolException('rich_origin');
    }
    if (type is! String ||
        surfaceId is! String ||
        !isMcpRichSurfaceId(surfaceId)) {
      throw const McpRichSurfaceProtocolException('rich_message_shape');
    }
    return type;
  }

  static McpRichSurfaceResizeRequest _decodeResize(
    Map<String, Object?> message,
  ) {
    _requireExactFields(message, const {
      'schemaVersion',
      'origin',
      'type',
      'surfaceId',
      'height',
    });
    final height = message['height'];
    if (height is! int || height < 80 || height > 720) {
      throw const McpRichSurfaceProtocolException('rich_resize');
    }
    return McpRichSurfaceResizeRequest(
      surfaceId: message['surfaceId']! as String,
      height: height.toDouble(),
    );
  }

  static McpRichSurfaceActionRequest _decodeAction(
    Map<String, Object?> message,
  ) {
    _requireExactFields(message, const {
      'schemaVersion',
      'origin',
      'type',
      'surfaceId',
      'requestId',
      'actionId',
    });
    final requestId = message['requestId'];
    final actionId = message['actionId'];
    if (requestId is! String ||
        actionId is! String ||
        !isMcpRichSurfaceId(requestId) ||
        !isMcpRichSurfaceId(actionId)) {
      throw const McpRichSurfaceProtocolException('rich_action');
    }
    return McpRichSurfaceActionRequest(
      surfaceId: message['surfaceId']! as String,
      requestId: requestId,
      actionId: actionId,
    );
  }

  static McpRichSurfaceOpenLinkRequest _decodeOpenLink(
    Map<String, Object?> message,
  ) {
    _requireExactFields(message, const {
      'schemaVersion',
      'origin',
      'type',
      'surfaceId',
      'url',
    });
    final rawUrl = message['url'];
    final uri =
        rawUrl is String && rawUrl.length <= 512 ? Uri.tryParse(rawUrl) : null;
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw const McpRichSurfaceProtocolException('rich_link');
    }
    return McpRichSurfaceOpenLinkRequest(
      surfaceId: message['surfaceId']! as String,
      uri: uri,
    );
  }

  static McpRichSurfaceCloseRequest _decodeClose(
    Map<String, Object?> message,
  ) {
    _requireExactFields(message, const {
      'schemaVersion',
      'origin',
      'type',
      'surfaceId',
    });
    return McpRichSurfaceCloseRequest(
      surfaceId: message['surfaceId']! as String,
    );
  }

  static void _requireExactFields(
    Map<String, Object?> value,
    Set<String> expected,
  ) {
    if (value.length != expected.length ||
        !value.keys.toSet().containsAll(expected)) {
      throw const McpRichSurfaceProtocolException('rich_message_fields');
    }
  }
}

sealed class McpRichSurfaceInboundMessage {
  const McpRichSurfaceInboundMessage({required this.surfaceId});

  final String surfaceId;
}

final class McpRichSurfaceResizeRequest extends McpRichSurfaceInboundMessage {
  const McpRichSurfaceResizeRequest({
    required super.surfaceId,
    required this.height,
  });

  final double height;
}

final class McpRichSurfaceActionRequest extends McpRichSurfaceInboundMessage {
  const McpRichSurfaceActionRequest({
    required super.surfaceId,
    required this.requestId,
    required this.actionId,
  });

  final String requestId;
  final String actionId;
}

final class McpRichSurfaceOpenLinkRequest extends McpRichSurfaceInboundMessage {
  const McpRichSurfaceOpenLinkRequest({
    required super.surfaceId,
    required this.uri,
  });

  final Uri uri;
}

final class McpRichSurfaceCloseRequest extends McpRichSurfaceInboundMessage {
  const McpRichSurfaceCloseRequest({required super.surfaceId});
}

final class McpRichSurfaceProtocolException implements Exception {
  const McpRichSurfaceProtocolException(this.reasonCode);

  final String reasonCode;

  @override
  String toString() => 'McpRichSurfaceProtocolException($reasonCode)';
}

/// Native-only adapter for an action proposal from a rich surface.
///
/// Its sole production implementation below calls [ChatProvider]'s existing
/// structured-action path, which allocates a fresh receipt operation and runs
/// hard-deny, capability, approval, and persistence checks. The operation ID
/// here is an ephemeral rich-surface binding identity; it is not an approval
/// and is never passed to a tool.
abstract interface class McpRichSurfaceActionRouter {
  String? get currentSessionId;
  String? get currentSurfaceOperationId;

  Future<void> dispatchStructuredAction({
    required String resultId,
    required String actionId,
  });
}

final class ChatProviderMcpRichSurfaceActionRouter
    implements McpRichSurfaceActionRouter {
  ChatProviderMcpRichSurfaceActionRouter({
    required this.chatProvider,
    required String Function() currentSurfaceOperationId,
  }) : _currentSurfaceOperationId = currentSurfaceOperationId;

  final ChatProvider chatProvider;
  final String Function() _currentSurfaceOperationId;

  @override
  String? get currentSessionId => chatProvider.currentSession?.id;

  @override
  String? get currentSurfaceOperationId => _currentSurfaceOperationId();

  @override
  Future<void> dispatchStructuredAction({
    required String resultId,
    required String actionId,
  }) async {
    // Do not call the provider unless the exact current native card still has
    // an available registered action. The provider rechecks this and every
    // policy boundary again before the effect boundary.
    if (chatProvider.structuredActionUnavailableReason(
          resultId: resultId,
          actionId: actionId,
        ) !=
        null) {
      return;
    }
    await chatProvider.executeStructuredAction(
      resultId: resultId,
      actionId: actionId,
    );
  }
}

final class McpRichSurfaceBridge {
  McpRichSurfaceBridge({
    required this.surface,
    this.actionRouter,
  });

  final McpRichSurface surface;
  final McpRichSurfaceActionRouter? actionRouter;
  final Set<String> _consumedRequestIds = <String>{};

  Future<McpRichSurfaceBridgeOutcome> handleMessage(String rawMessage) async {
    final McpRichSurfaceInboundMessage message;
    try {
      message = McpRichSurfaceProtocol.decodeInbound(rawMessage);
    } on McpRichSurfaceProtocolException catch (error) {
      return McpRichSurfaceBridgeOutcome.rejected(error.reasonCode);
    }
    if (message.surfaceId != surface.surfaceId) {
      return const McpRichSurfaceBridgeOutcome.rejected('rich_surface_stale');
    }

    return switch (message) {
      McpRichSurfaceResizeRequest(:final height) =>
        McpRichSurfaceBridgeOutcome.resized(height),
      McpRichSurfaceActionRequest() => _dispatchAction(message),
      McpRichSurfaceOpenLinkRequest() =>
        const McpRichSurfaceBridgeOutcome.rejected('rich_network_disabled'),
      McpRichSurfaceCloseRequest() =>
        const McpRichSurfaceBridgeOutcome.closed(),
    };
  }

  Future<McpRichSurfaceBridgeOutcome> _dispatchAction(
    McpRichSurfaceActionRequest request,
  ) async {
    final router = actionRouter;
    final actionKnown = surface.view.actions.any(
      (action) => action.actionId == request.actionId,
    );
    if (router == null ||
        !actionKnown ||
        router.currentSessionId != surface.sessionId ||
        router.currentSurfaceOperationId != surface.operationId) {
      return const McpRichSurfaceBridgeOutcome.rejected('rich_action_stale');
    }
    if (!_consumedRequestIds.add(request.requestId)) {
      return const McpRichSurfaceBridgeOutcome.rejected('rich_action_replay');
    }
    if (_consumedRequestIds.length > 64) {
      _consumedRequestIds.remove(_consumedRequestIds.first);
    }
    try {
      await router.dispatchStructuredAction(
        resultId: surface.resultId,
        actionId: request.actionId,
      );
      return const McpRichSurfaceBridgeOutcome.actionForwarded();
    } on Object {
      return const McpRichSurfaceBridgeOutcome.rejected(
          'rich_action_unavailable');
    }
  }
}

enum McpRichSurfaceBridgeOutcomeKind {
  resized,
  actionForwarded,
  closed,
  rejected,
}

final class McpRichSurfaceBridgeOutcome {
  const McpRichSurfaceBridgeOutcome._(
    this.kind, {
    this.height,
    this.reasonCode,
  });

  const McpRichSurfaceBridgeOutcome.resized(double height)
      : this._(McpRichSurfaceBridgeOutcomeKind.resized, height: height);

  const McpRichSurfaceBridgeOutcome.actionForwarded()
      : this._(McpRichSurfaceBridgeOutcomeKind.actionForwarded);

  const McpRichSurfaceBridgeOutcome.closed()
      : this._(McpRichSurfaceBridgeOutcomeKind.closed);

  const McpRichSurfaceBridgeOutcome.rejected(String reasonCode)
      : this._(
          McpRichSurfaceBridgeOutcomeKind.rejected,
          reasonCode: reasonCode,
        );

  final McpRichSurfaceBridgeOutcomeKind kind;
  final double? height;
  final String? reasonCode;
}
