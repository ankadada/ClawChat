import 'dart:convert';

import 'package:clawchat/models/mcp_rich_surface.dart';
import 'package:clawchat/services/mcp_rich_surface_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  McpRichSurface buildSurface({bool withAction = true}) => McpRichSurface(
        surfaceId: 'surface-1',
        sessionId: 'session-1',
        resultId: 'result-1',
        operationId: 'operation-1',
        view: McpRichSurfaceViewModel(
          title: 'Local status',
          summary: 'Host-owned only.',
          actions: withAction
              ? [McpRichSurfaceActionRef(actionId: 'save-1', label: 'Save')]
              : const [],
        ),
      );

  String message(String type, Map<String, Object?> fields) => jsonEncode({
        'schemaVersion': 1,
        'origin': McpRichSurface.localOrigin,
        'type': type,
        'surfaceId': 'surface-1',
        ...fields,
      });

  Matcher protocolCode(String code) => isA<McpRichSurfaceProtocolException>()
      .having((error) => error.reasonCode, 'reasonCode', code);

  group('McpRichSurfaceProtocol', () {
    test('decodes only the four supported inbound message types', () {
      final resize = McpRichSurfaceProtocol.decodeInbound(
        message('resize', {'height': 240}),
      );
      final action = McpRichSurfaceProtocol.decodeInbound(
        message(
            'request_action', {'requestId': 'request-1', 'actionId': 'save-1'}),
      );
      final link = McpRichSurfaceProtocol.decodeInbound(
        message('open_link', {'url': 'https://example.invalid/path'}),
      );
      final close = McpRichSurfaceProtocol.decodeInbound(message('close', {}));

      expect(resize, isA<McpRichSurfaceResizeRequest>());
      expect(action, isA<McpRichSurfaceActionRequest>());
      expect(link, isA<McpRichSurfaceOpenLinkRequest>());
      expect(close, isA<McpRichSurfaceCloseRequest>());
    });

    test('rejects duplicate, unknown, oversized, deep, and foreign messages',
        () {
      expect(
        () => McpRichSurfaceProtocol.decodeInbound(
          '{"schemaVersion":1,"origin":"${McpRichSurface.localOrigin}",'
          '"type":"close","surfaceId":"surface-1","surfaceId":"other"}',
        ),
        throwsA(protocolCode('rich_duplicate_key')),
      );
      expect(
        () => McpRichSurfaceProtocol.decodeInbound(
          message('resize', {'height': 200, 'payload': 'not-accepted'}),
        ),
        throwsA(protocolCode('rich_message_fields')),
      );
      expect(
        () => McpRichSurfaceProtocol.decodeInbound('x' * 4097),
        throwsA(protocolCode('rich_input_too_large')),
      );
      expect(
        () => McpRichSurfaceProtocol.decodeInbound(
          '[[[[[[[[[0]]]]]]]]]',
        ),
        throwsA(protocolCode('rich_nesting_too_deep')),
      );
      expect(
        () => McpRichSurfaceProtocol.decodeInbound(
          jsonEncode({
            'schemaVersion': 1,
            'origin': 'https://example.invalid',
            'type': 'close',
            'surfaceId': 'surface-1',
          }),
        ),
        throwsA(protocolCode('rich_origin')),
      );
      expect(
        () => McpRichSurfaceProtocol.decodeInbound(message('execute_tool', {})),
        throwsA(protocolCode('rich_message_type')),
      );
    });

    test('requires bounded primitive fields and never accepts action payloads',
        () {
      expect(
        () => McpRichSurfaceProtocol.decodeInbound(
            message('resize', {'height': 80.0})),
        throwsA(protocolCode('rich_resize')),
      );
      expect(
        () => McpRichSurfaceProtocol.decodeInbound(
          message('request_action', {
            'requestId': 'request-1',
            'actionId': 'save-1',
            'payload': {'fact': 'not accepted'},
          }),
        ),
        throwsA(protocolCode('rich_message_fields')),
      );
      expect(
        () => McpRichSurfaceProtocol.decodeInbound(
          message('open_link', {'url': 'file:///private/data'}),
        ),
        throwsA(protocolCode('rich_link')),
      );
    });
  });

  group('McpRichSurfaceBridge', () {
    test('rejects external navigation and stale surface IDs without callbacks',
        () async {
      final router = _FakeRouter();
      final bridge =
          McpRichSurfaceBridge(surface: buildSurface(), actionRouter: router);

      final link = await bridge.handleMessage(
        message('open_link', {'url': 'https://example.invalid'}),
      );
      final stale = await bridge.handleMessage(jsonEncode({
        'schemaVersion': 1,
        'origin': McpRichSurface.localOrigin,
        'type': 'close',
        'surfaceId': 'other-surface',
      }));

      expect(link.reasonCode, 'rich_network_disabled');
      expect(stale.reasonCode, 'rich_surface_stale');
      expect(router.calls, isEmpty);
    });

    test('forwards only a current bound action once through the native router',
        () async {
      final router = _FakeRouter();
      final bridge =
          McpRichSurfaceBridge(surface: buildSurface(), actionRouter: router);
      final raw = message(
        'request_action',
        {'requestId': 'request-1', 'actionId': 'save-1'},
      );

      final accepted = await bridge.handleMessage(raw);
      final replay = await bridge.handleMessage(raw);

      expect(accepted.kind, McpRichSurfaceBridgeOutcomeKind.actionForwarded);
      expect(replay.reasonCode, 'rich_action_replay');
      expect(router.calls, ['result-1:save-1']);
    });

    test('rejects missing, stale, and unknown action bindings', () async {
      final noRouter = McpRichSurfaceBridge(surface: buildSurface());
      expect(
        (await noRouter.handleMessage(
          message('request_action',
              {'requestId': 'request-1', 'actionId': 'save-1'}),
        ))
            .reasonCode,
        'rich_action_stale',
      );

      final staleRouter = _FakeRouter(sessionId: 'other-session');
      final staleBridge = McpRichSurfaceBridge(
        surface: buildSurface(),
        actionRouter: staleRouter,
      );
      expect(
        (await staleBridge.handleMessage(
          message('request_action',
              {'requestId': 'request-1', 'actionId': 'save-1'}),
        ))
            .reasonCode,
        'rich_action_stale',
      );

      final staleOperationRouter = _FakeRouter(operationId: 'other-operation');
      final staleOperationBridge = McpRichSurfaceBridge(
        surface: buildSurface(),
        actionRouter: staleOperationRouter,
      );
      expect(
        (await staleOperationBridge.handleMessage(
          message(
            'request_action',
            {'requestId': 'request-1', 'actionId': 'save-1'},
          ),
        ))
            .reasonCode,
        'rich_action_stale',
      );

      final unknown = McpRichSurfaceBridge(
        surface: buildSurface(),
        actionRouter: _FakeRouter(),
      );
      expect(
        (await unknown.handleMessage(
          message('request_action',
              {'requestId': 'request-1', 'actionId': 'other'}),
        ))
            .reasonCode,
        'rich_action_stale',
      );
    });
  });
}

final class _FakeRouter implements McpRichSurfaceActionRouter {
  _FakeRouter({this.sessionId = 'session-1', this.operationId = 'operation-1'});

  String? sessionId;
  String? operationId;
  final List<String> calls = [];

  @override
  String? get currentSessionId => sessionId;

  @override
  String? get currentSurfaceOperationId => operationId;

  @override
  Future<void> dispatchStructuredAction({
    required String resultId,
    required String actionId,
  }) async {
    calls.add('$resultId:$actionId');
  }
}
