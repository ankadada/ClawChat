import 'package:clawchat/models/mcp_rich_surface.dart';
import 'package:clawchat/models/structured_result.dart';
import 'package:clawchat/services/mcp_rich_surface_protocol.dart';
import 'package:clawchat/widgets/mcp_rich_surface_view.dart';
import 'package:clawchat/widgets/structured_result_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  McpRichSurface buildSurface() => McpRichSurface(
        surfaceId: 'surface-1',
        sessionId: 'session-1',
        resultId: 'result-1',
        operationId: 'operation-1',
        view: McpRichSurfaceViewModel(
          title: 'Local status',
          summary: 'Host-owned rich display.',
        ),
      );

  Widget host(
    Widget child, {
    required Size size,
    EdgeInsets viewInsets = EdgeInsets.zero,
    TextScaler textScaler = TextScaler.noScaling,
  }) =>
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: size,
            viewInsets: viewInsets,
            textScaler: textScaler,
          ),
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: size.width, child: child),
            ),
          ),
        ),
      );

  testWidgets('fails closed to an accessible native notice', (tester) async {
    await tester.pumpWidget(host(
      McpRichSurfaceView(surface: buildSurface(), forceUnavailable: true),
      size: const Size(320, 600),
    ));

    expect(find.text('Local status'), findsOneWidget);
    expect(
      find.text(
          'Rich content could not be displayed safely. Native content remains available.'),
      findsOneWidget,
    );
    expect(
      tester.getSemantics(find.byType(McpRichSurfaceUnavailableNotice)).label,
      contains('Rich content unavailable'),
    );
  });

  testWidgets('fits a 320dp pane at 200 percent text scale', (tester) async {
    await tester.pumpWidget(host(
      McpRichSurfaceView(
        surface: buildSurface(),
        childForTesting: const ColoredBox(
          key: Key('rich-test-child'),
          color: Colors.blue,
        ),
      ),
      size: const Size(320, 800),
      textScaler: const TextScaler.linear(2),
    ));

    final size = tester.getSize(find.byKey(const Key('rich-test-child')));
    expect(size.width, 320);
    expect(size.height, 320);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shrinks within an IME-limited tabletop viewport',
      (tester) async {
    await tester.pumpWidget(host(
      McpRichSurfaceView(
        surface: buildSurface(),
        childForTesting: const ColoredBox(
          key: Key('rich-test-child'),
          color: Colors.blue,
        ),
      ),
      size: const Size(720, 600),
      viewInsets: const EdgeInsets.only(bottom: 420),
      textScaler: const TextScaler.linear(2),
    ));

    final size = tester.getSize(find.byKey(const Key('rich-test-child')));
    expect(size.height, lessThanOrEqualTo(180));
    expect(tester.takeException(), isNull);
  });

  test('fixed document blocks network and does not use HTML insertion', () {
    expect(mcpRichSurfaceHtml, contains("connect-src 'none'"));
    expect(mcpRichSurfaceHtml, contains("frame-src 'none'"));
    expect(mcpRichSurfaceHtml, contains('textContent'));
    expect(mcpRichSurfaceHtml, isNot(contains('innerHTML')));
    expect(
      mcpRichSurfaceHtml,
      contains('min-height: 48px; min-width: 48px'),
    );
  });

  testWidgets(
      'opt-in fallback keeps the authoritative native card at 320dp and 200 percent',
      (tester) async {
    final router = _FakeRouter();
    await tester.pumpWidget(host(
      SingleChildScrollView(
        child: Column(
          children: [
            const StructuredResultCard(
              document: _nativeDocument,
              isInvalid: false,
            ),
            McpRichSurfaceDisclosure(
              surface: buildSurface(),
              actionRouter: router,
              forceUnavailable: true,
            ),
          ],
        ),
      ),
      size: const Size(320, 700),
      textScaler: const TextScaler.linear(2),
    ));

    final toggle = find.byKey(const Key('mcp-rich-surface-toggle'));
    expect(find.byType(StructuredResultCard), findsOneWidget);
    expect(find.byType(McpRichSurfaceView), findsNothing);
    expect(tester.getSize(toggle).height, greaterThanOrEqualTo(48));

    await tester.tap(toggle);
    await tester.pump();

    expect(find.byType(StructuredResultCard), findsOneWidget);
    expect(find.byType(McpRichSurfaceUnavailableNotice), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(host(
      SingleChildScrollView(
        child: Column(
          children: [
            const StructuredResultCard(
              document: _nativeDocument,
              isInvalid: false,
            ),
            McpRichSurfaceDisclosure(
              surface: buildSurface(),
              actionRouter: router,
              forceUnavailable: true,
            ),
          ],
        ),
      ),
      size: const Size(390, 600),
      viewInsets: const EdgeInsets.only(bottom: 240),
      textScaler: const TextScaler.linear(2),
    ));
    if (find.text('Show rich view').evaluate().isNotEmpty) {
      await tester.tap(find.byKey(const Key('mcp-rich-surface-toggle')));
      await tester.pump();
    }
    await tester.pump();
    expect(find.byType(StructuredResultCard), findsOneWidget);
    expect(find.byType(McpRichSurfaceUnavailableNotice), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('navigation policy allows only the local initial document', () {
    expect(mcpRichSurfaceAllowsNavigation('about:blank'), isTrue);
    expect(mcpRichSurfaceAllowsNavigation('https://example.invalid'), isFalse);
    expect(mcpRichSurfaceAllowsNavigation('file:///private/data'), isFalse);
    expect(mcpRichSurfaceAllowsNavigation('about:blank#other'), isFalse);
  });

  test('geometry is bounded for narrow, book, and IME profiles', () {
    expect(
      mcpRichSurfaceHeight(
        requestedHeight: 240,
        availableHeight: 800,
        textScaler: const TextScaler.linear(2),
      ),
      320,
    );
    expect(
      mcpRichSurfaceHeight(
        requestedHeight: 720,
        availableHeight: 360,
        textScaler: TextScaler.noScaling,
      ),
      360,
    );
    expect(
      mcpRichSurfaceHeight(
        requestedHeight: 240,
        availableHeight: 160,
        textScaler: const TextScaler.linear(2),
      ),
      160,
    );
  });
}

const _nativeDocument = StructuredResultDocument(
  schemaVersion: 1,
  resultId: '123e4567-e89b-42d3-a456-426614174000',
  blocks: [
    StructuredNoticeBlock(
      level: StructuredNoticeLevel.info,
      text: 'Native result stays available',
    ),
  ],
);

final class _FakeRouter implements McpRichSurfaceActionRouter {
  @override
  String? get currentSessionId => 'session-1';

  @override
  String? get currentSurfaceOperationId => 'operation-1';

  @override
  Future<void> dispatchStructuredAction({
    required String resultId,
    required String actionId,
  }) async {}
}
