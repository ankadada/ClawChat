import 'package:clawchat/screens/run_trace_screen.dart';
import 'package:clawchat/services/runtime_debug_events.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows metadata timeline and export preview before sharing',
      (tester) async {
    final service = RuntimeDebugEventService(tracingEnabled: true);
    final traceId = service.startRunTrace('session-1', data: {
      'trigger': 'message',
      'modelLabel': 'anthropic/test-model',
    })!;
    service.record(RuntimeDebugEvent(
      type: 'stream.started',
      sessionId: 'session-1',
      data: {'latencyMs': 8},
    ));
    service.finishRunTrace(traceId, RunTraceStatus.completed);

    await tester.pumpWidget(
      MaterialApp(home: RunTraceScreen(traceService: service)),
    );

    expect(find.text('Agent 运行详情'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
    expect(find.textContaining('session-1'), findsOneWidget);

    await tester.tap(find.byTooltip('导出预览'));
    await tester.pumpAndSettle();
    expect(find.text('脱敏导出预览'), findsOneWidget);
    expect(find.text('确认分享'), findsOneWidget);
    expect(find.textContaining('metadata_only'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('run-'));
    await tester.pumpAndSettle();
    expect(find.text('运行时间线'), findsOneWidget);
    expect(find.textContaining('stream.started'), findsOneWidget);
    expect(find.textContaining('latencyMs'), findsOneWidget);
  });

  testWidgets('clear requires confirmation and removes traces', (tester) async {
    final service = RuntimeDebugEventService(tracingEnabled: true);
    service.startRunTrace('session-1');

    await tester.pumpWidget(
      MaterialApp(home: RunTraceScreen(traceService: service)),
    );
    await tester.tap(find.byTooltip('清空'));
    await tester.pumpAndSettle();
    expect(find.text('清空运行详情？'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '清空'));
    await tester.pumpAndSettle();
    expect(find.text('暂无运行详情'), findsOneWidget);
    expect(service.recentRunTraces(), isEmpty);
  });
}
