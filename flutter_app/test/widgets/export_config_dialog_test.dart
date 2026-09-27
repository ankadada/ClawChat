import 'package:clawchat/l10n/app_strings.dart';
import 'package:clawchat/widgets/export_config_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

/// v2.18: the export-config primary action must be a complete, reachable
/// target on compact viewports (narrow window / large accessibility text).
void main() {
  const primaryKey = ValueKey('export-config-primary-action');

  Future<ExportConfigOptions?> openDialog(
    WidgetTester tester, {
    required Size size,
    required double textScale,
  }) async {
    ExportConfigOptions? result;
    // Drive the real viewport too: the dialog measures the window, not just
    // the injected MediaQuery.
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(textScale),
          ),
          child: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () async {
                    result = await showExportConfigDialog(context);
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('a narrow viewport renders a full-width, fully visible action',
      (tester) async {
    await openDialog(tester, size: const Size(320, 480), textScale: 1.0);

    final button = find.byKey(primaryKey);
    expect(button, findsOneWidget);
    final rect = tester.getRect(button);
    const screen = Size(320, 480);
    final body = tester.getRect(find.byType(SingleChildScrollView));
    expect(rect.height, greaterThanOrEqualTo(48.0));
    expect(rect.left, greaterThanOrEqualTo(0));
    // Stretched across the dialog body, so no sliver of the target is cut off.
    expect(rect.width, closeTo(body.width, 0.5));
    expect(rect.right, lessThanOrEqualTo(screen.width));
    expect(rect.bottom, lessThanOrEqualTo(screen.height));
    expect(tester.takeException(), isNull);
  });

  testWidgets('large accessibility text keeps the action fully hittable',
      (tester) async {
    await openDialog(tester, size: const Size(360, 640), textScale: 1.8);

    final button = find.byKey(primaryKey);
    expect(button, findsOneWidget);
    final rect = tester.getRect(button);
    const screen = Size(360, 640);
    final body = tester.getRect(find.byType(SingleChildScrollView));
    expect(rect.height, greaterThanOrEqualTo(48.0));
    expect(rect.width, closeTo(body.width, 0.5));
    expect(rect.right, lessThanOrEqualTo(screen.width + 0.5));
    expect(rect.bottom, lessThanOrEqualTo(screen.height));

    // The corner of the target belongs to the button: an empty password must
    // trigger the in-dialog validation, proving the tap landed.
    await tester.tapAt(Offset(rect.left + 2, rect.top + 2));
    await tester.pumpAndSettle();
    expect(find.text(AppStrings.passwordRequired), findsOneWidget);
    expect(find.byType(ExportConfigDialog), findsOneWidget);
  });

  testWidgets('the action exposes one labelled, enabled semantics node',
      (tester) async {
    final handle = tester.ensureSemantics();
    await openDialog(tester, size: const Size(360, 640), textScale: 1.4);

    final labelled = find.bySemanticsLabel(AppStrings.exportConfig);
    expect(
      labelled,
      findsWidgets,
      reason: 'the button keeps the visible label as its semantics label',
    );
    final node = tester.getSemantics(find.byKey(primaryKey));
    expect(node.hasFlag(SemanticsFlag.isButton), isTrue);
    expect(node.hasFlag(SemanticsFlag.isEnabled), isTrue);
    expect(
      node.getSemanticsData().hasAction(SemanticsAction.tap),
      isTrue,
    );
    handle.dispose();
  });

  testWidgets('a wide viewport keeps the action in the dialog action row',
      (tester) async {
    final handle = tester.ensureSemantics();
    await openDialog(tester, size: const Size(800, 800), textScale: 1.0);

    final rect = tester.getRect(find.byKey(primaryKey));
    expect(rect.height, greaterThanOrEqualTo(48.0));
    // Not stretched: the action stays compact next to cancel.
    expect(rect.width, lessThan(800 * 0.8));

    // A valid password pops the dialog with the encryption choice.
    await tester.enterText(
      find.widgetWithText(TextField, AppStrings.setPassword),
      'secret-pass',
    );
    await tester.enterText(
      find.widgetWithText(TextField, AppStrings.confirmPassword),
      'secret-pass',
    );
    await tester.tap(find.byKey(primaryKey));
    await tester.pumpAndSettle();
    expect(find.byType(ExportConfigDialog), findsNothing);
    handle.dispose();
  });
}
