import 'dart:ui';

import 'package:clawchat/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('divider allocates 48dp hit target around a 1dp visual line',
      (tester) async {
    final deltas = <double>[];
    var resets = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              height: 240,
              child: SidebarResizeDivider(
                semanticValue: '280 dp',
                onDragUpdate: deltas.add,
                onReset: () => resets += 1,
              ),
            ),
          ),
        ),
      ),
    );

    final target = find.byKey(const ValueKey('sidebar-resize-target'));
    final line = find.byKey(const ValueKey('sidebar-resize-visual-line'));
    final targetRect = tester.getRect(target);
    expect(targetRect.width, 48);
    expect(tester.getSize(line).width, 1);
    expect(tester.getCenter(line).dx, closeTo(targetRect.center.dx, 0.01));

    await tester.drag(target, const Offset(30, 0));
    expect(deltas, isNotEmpty);
    final callsAfterInside = deltas.length;

    final edge = Offset(targetRect.left + 2, targetRect.center.dy);
    await tester.tapAt(edge);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(edge);
    await tester.pump(const Duration(milliseconds: 400));
    expect(resets, 1);

    final outside = Offset(targetRect.left - 2, targetRect.center.dy);
    await tester.tapAt(outside);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(outside);
    await tester.pump(const Duration(milliseconds: 400));
    expect(deltas, hasLength(callsAfterInside));
    expect(resets, 1);

    final semantics = tester.getSemantics(target);
    expect(semantics.label, '调整会话列表宽度');
    expect(semantics.value, contains('280 dp'));
    expect(
      semantics.getSemanticsData().hasAction(SemanticsAction.increase),
      isTrue,
    );
    expect(
      semantics.getSemanticsData().hasAction(SemanticsAction.decrease),
      isTrue,
    );

    Focus.of(tester.element(target)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(deltas.last, 24);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    expect(deltas.last, -24);
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    expect(resets, 2);
  });
}
