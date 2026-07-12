import 'dart:ui';

import 'package:clawchat/screens/local_data_recovery_screen.dart';
import 'package:clawchat/services/session_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('data center keeps sticky actions out of book hinge',
      (tester) async {
    await _pump(
      tester,
      const Size(900, 600),
      const [
        DisplayFeature(
          bounds: Rect.fromLTWH(440, 0, 20, 600),
          type: DisplayFeatureType.hinge,
          state: DisplayFeatureState.postureFlat,
        ),
      ],
    );
    await tester.pumpAndSettle();
    final action = find.byKey(const Key('local-data-primary-action'));
    expect(action, findsOneWidget);
    expect(tester.getTopLeft(action).dx, greaterThanOrEqualTo(460));
    expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
    expect(find.text('会话数据以这台设备上的本地副本为准。'), findsOneWidget);
  });

  testWidgets('tabletop and IME use top region without duplicate loads',
      (tester) async {
    final storage = _PreviewStorage();
    final screen = LocalDataRecoveryScreen(storage: storage);
    await _pump(
      tester,
      const Size(700, 600),
      const [
        DisplayFeature(
          bounds: Rect.fromLTWH(0, 300, 700, 20),
          type: DisplayFeatureType.fold,
          state: DisplayFeatureState.postureHalfOpened,
        ),
      ],
      child: screen,
      viewInsets: const EdgeInsets.only(bottom: 250),
      textScale: 2,
    );
    await tester.pumpAndSettle();
    final action = find.byKey(const Key('local-data-primary-action'));
    expect(tester.getBottomLeft(action).dy, lessThanOrEqualTo(300));
    expect(storage.previewCalls, 1);

    await _pump(
      tester,
      const Size(320, 600),
      const [],
      child: screen,
      viewInsets: const EdgeInsets.only(bottom: 220),
      textScale: 2,
    );
    await tester.pump();
    expect(storage.previewCalls, 1);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pump(
  WidgetTester tester,
  Size size,
  List<DisplayFeature> features, {
  Widget? child,
  EdgeInsets viewInsets = EdgeInsets.zero,
  double textScale = 1,
}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  return tester.pumpWidget(MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(
        size: size,
        displayFeatures: features,
        viewInsets: viewInsets,
        textScaler: TextScaler.linear(textScale),
      ),
      child: child ?? LocalDataRecoveryScreen(storage: _PreviewStorage()),
    ),
  ));
}

class _PreviewStorage extends SessionStorage {
  int previewCalls = 0;

  @override
  Future<void> init() async {}

  @override
  Future<SessionExportPreview> previewExport() async {
    previewCalls += 1;
    return SessionExportPreview(
      sessionCount: 2,
      earliest: DateTime.utc(2026, 1, 1),
      latest: DateTime.utc(2026, 1, 2),
      estimatedBytes: 2048,
    );
  }

  @override
  Future<List<SessionTrashEntry>> listTrash() async => const [];
}
