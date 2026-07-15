import 'package:clawchat/models/mcp_rich_surface.dart';
import 'package:clawchat/models/chat_models.dart';
import 'package:clawchat/models/structured_result.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  McpRichSurface buildSurface(
      {List<McpRichSurfaceActionRef> actions = const []}) {
    return McpRichSurface(
      surfaceId: 'surface-1',
      sessionId: 'session-1',
      resultId: 'result-1',
      operationId: 'operation-1',
      view: McpRichSurfaceViewModel(
        title: 'Local status',
        summary: 'A host-owned rich surface.',
        metrics: [McpRichSurfaceMetric(label: 'State', value: 'Ready')],
        actions: actions,
      ),
    );
  }

  test('renders only the fixed host message shape', () {
    final message = buildSurface(
      actions: [McpRichSurfaceActionRef(actionId: 'save-1', label: 'Save')],
    ).renderMessage;

    expect(message.keys, {
      'schemaVersion',
      'origin',
      'type',
      'surfaceId',
      'renderer',
      'view',
    });
    expect(message['type'], 'render');
    expect(message['renderer'], McpRichSurface.hostStatusRenderer);
    expect(message.toString(), isNot(contains('payload')));
    expect(message.toString(), isNot(contains('toolName')));
  });

  test('rejects malformed identities and duplicate local action references',
      () {
    expect(
      () => McpRichSurface(
        surfaceId: '../surface',
        sessionId: 'session-1',
        resultId: 'result-1',
        operationId: 'operation-1',
        view: McpRichSurfaceViewModel(title: 'Title', summary: 'Summary'),
      ),
      throwsA(
        isA<McpRichSurfaceException>().having(
            (error) => error.reasonCode, 'reason', 'invalid_surface_identity'),
      ),
    );
    expect(
      () => buildSurface(
        actions: [
          McpRichSurfaceActionRef(actionId: 'save-1', label: 'Save'),
          McpRichSurfaceActionRef(actionId: 'save-1', label: 'Save again'),
        ],
      ),
      throwsA(
        isA<McpRichSurfaceException>().having(
            (error) => error.reasonCode, 'reason', 'duplicate_render_action'),
      ),
    );
  });

  test('rejects control characters and oversized display values', () {
    expect(
      () => McpRichSurfaceViewModel(title: 'Title\n', summary: 'Summary'),
      throwsA(isA<McpRichSurfaceException>()),
    );
    expect(
      () => McpRichSurfaceMetric(label: 'State', value: 'x' * 121),
      throwsA(isA<McpRichSurfaceException>()),
    );
    expect(
      () => McpRichSurfaceViewModel(
        title: 'Title',
        summary: 'Authorization: Bearer not-for-display',
      ),
      throwsA(isA<McpRichSurfaceException>()),
    );
    expect(
      () => McpRichSurfaceActionRef(actionId: 'Save-1', label: 'Save'),
      throwsA(isA<McpRichSurfaceException>()),
    );
  });

  test('host adapter derives bounded display data without action payloads', () {
    const document = StructuredResultDocument(
      schemaVersion: 1,
      resultId: '123e4567-e89b-42d3-a456-426614174000',
      blocks: [
        StructuredNoticeBlock(
          level: StructuredNoticeLevel.info,
          text: 'Imported safely',
        ),
        StructuredKeyValueBlock(
          items: [StructuredKeyValueItem(key: 'State', value: 'Ready')],
        ),
        StructuredActionListBlock(
          actions: [
            StructuredResultAction(
              actionId: 'save-1',
              label: 'Save locally',
              kind: 'save_to_memory',
              payload: {'fact': 'Never sent to the WebView'},
            ),
          ],
        ),
      ],
    );
    final surface = McpRichSurfaceAdapter.fromStructuredResult(
      sessionId: 'session-1',
      content: const StructuredResultContent(document: document),
      availableActionIds: const {'save-1'},
    );

    expect(surface, isNotNull);
    expect(surface!.view.metrics.single.value, 'Ready');
    expect(surface.view.actions.single.actionId, 'save-1');
    expect(surface.renderMessage.toString(), isNot(contains('Never sent')));
    expect(surface.renderMessage.toString(), isNot(contains('payload')));
    expect(surface.renderMessage.toString(), isNot(contains('toolName')));
  });

  test('host adapter omits invalid or sensitive rich projections', () {
    const sensitive = StructuredResultDocument(
      schemaVersion: 1,
      resultId: '123e4567-e89b-42d3-a456-426614174000',
      blocks: [
        StructuredNoticeBlock(
          level: StructuredNoticeLevel.info,
          text: 'Use API key only in native content',
        ),
      ],
    );

    expect(
      McpRichSurfaceAdapter.fromStructuredResult(
        sessionId: 'session-1',
        content: const StructuredResultContent(document: sensitive),
      ),
      isNull,
    );
    expect(
      McpRichSurfaceAdapter.fromStructuredResult(
        sessionId: 'session-1',
        content: StructuredResultContent.invalid(),
      ),
      isNull,
    );
  });
}
