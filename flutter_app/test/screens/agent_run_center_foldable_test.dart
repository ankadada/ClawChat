import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:clawchat/constants.dart';
import 'package:clawchat/models/chat_models.dart';
import 'package:clawchat/providers/chat_provider.dart';
import 'package:clawchat/screens/agent_run_center_screen.dart';
import 'package:clawchat/services/preferences_service.dart';
import 'package:clawchat/services/session_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  const secureChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const nativeChannel = MethodChannel(AppConstants.channelName);
  late Directory tempDir;
  late _CountingSessionStorage storage;
  late ChatProvider provider;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PreferencesService.resetForTesting();
    tempDir = await Directory.systemTemp.createTemp('run_center_fold_');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathChannel, (_) async => tempDir.path);
    messenger.setMockMethodCallHandler(secureChannel, (call) async {
      if (call.method == 'readAll') return <String, String>{};
      if (call.method == 'containsKey') return false;
      return null;
    });
    messenger.setMockMethodCallHandler(nativeChannel, (call) async {
      if (call.method == 'consumePendingNavigateToSession') return null;
      if (call.method == 'runInProot') return '';
      return true;
    });
    storage = _CountingSessionStorage();
    await storage.init();
    await storage.saveSession(ChatSession(
      id: 'fold-recovery',
      title: 'Fold recovery',
      inFlightAgentRun: AgentRunRecoveryMarker(
        runAttemptId: 'fold-attempt',
        startedAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
      ),
    ));
    provider = ChatProvider(storage: storage);
    await _waitUntil(() => provider.sessions.isNotEmpty);
    await provider.selectSession('fold-recovery');
  });

  tearDown(() async {
    provider.dispose();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathChannel, null);
    messenger.setMockMethodCallHandler(secureChannel, null);
    messenger.setMockMethodCallHandler(nativeChannel, null);
    PreferencesService.resetForTesting();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  for (final hingeWidth in [20.0, 0.0]) {
    testWidgets('book hinge width $hingeWidth preserves selected detail',
        (tester) async {
      const size = Size(800, 600);
      final hinge = Rect.fromLTWH(400, 0, hingeWidth, 600);
      final features = [
        DisplayFeature(
          bounds: hinge,
          type: hingeWidth == 0
              ? DisplayFeatureType.fold
              : DisplayFeatureType.hinge,
          state: hingeWidth == 0
              ? DisplayFeatureState.postureHalfOpened
              : DisplayFeatureState.postureFlat,
        ),
      ];
      await _pumpRunCenter(
        tester,
        provider: provider,
        size: size,
        features: features,
      );
      final readsAfterOpen = storage.getSessionCalls;
      final listRect = tester.getRect(find.ancestor(
        of: find.text('Fold recovery'),
        matching: find.byType(ListTile),
      ));
      expect(listRect.left, greaterThanOrEqualTo(hinge.right));
      expect(listRect.overlaps(hinge), isFalse);

      await tester.tap(find.text('Fold recovery'));
      await tester.pumpAndSettle();
      final actionRect = tester.getRect(find.text('打开会话'));
      expect(actionRect.right, lessThanOrEqualTo(hinge.left));
      expect(actionRect.overlaps(hinge), isFalse);

      await _pumpRunCenter(
        tester,
        provider: provider,
        size: size,
        features: [
          const DisplayFeature(
            bounds: Rect.fromLTWH(400, 0, 0, 600),
            type: DisplayFeatureType.fold,
            state: DisplayFeatureState.postureHalfOpened,
          ),
        ],
      );
      expect(find.text('打开会话'), findsOneWidget);
      expect(storage.getSessionCalls, readsAfterOpen);
    });
  }

  for (final foldHeight in [20.0, 0.0]) {
    testWidgets('tabletop fold height $foldHeight routes detail in usable pane',
        (tester) async {
      const size = Size(600, 800);
      final fold = Rect.fromLTWH(0, 300, 600, foldHeight);
      final features = [
        DisplayFeature(
          bounds: fold,
          type: DisplayFeatureType.fold,
          state: DisplayFeatureState.postureHalfOpened,
        ),
      ];
      await _pumpRunCenter(
        tester,
        provider: provider,
        size: size,
        features: features,
      );
      final listRect = tester.getRect(find.ancestor(
        of: find.text('Fold recovery'),
        matching: find.byType(ListTile),
      ));
      expect(listRect.top, greaterThanOrEqualTo(fold.bottom));
      expect(listRect.overlaps(fold), isFalse);

      await tester.tap(find.text('Fold recovery'));
      await tester.pumpAndSettle();
      final detailRect = tester.getRect(find.byType(AppBar));
      expect(detailRect.top, greaterThanOrEqualTo(fold.bottom));
      expect(detailRect.overlaps(fold), isFalse);

      await _pumpRunCenter(
        tester,
        provider: provider,
        size: size,
        features: features,
        bottomInset: 360,
      );
      final imeDetail = tester.getRect(find.byType(AppBar));
      expect(imeDetail.bottom, lessThanOrEqualTo(fold.top));
      expect(imeDetail.overlaps(fold), isFalse);
    });
  }
}

Future<void> _pumpRunCenter(
  WidgetTester tester, {
  required ChatProvider provider,
  required Size size,
  required List<DisplayFeature> features,
  double bottomInset = 0,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(ChangeNotifierProvider<ChatProvider>.value(
    value: provider,
    child: MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQueryData(
          size: size,
          displayFeatures: features,
          viewInsets: EdgeInsets.only(bottom: bottomInset),
        ),
        child: child!,
      ),
      home: const AgentRunCenterScreen(key: ValueKey('run-center-fold')),
    ),
  ));
  await tester.pumpAndSettle();
}

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition not met');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

final class _CountingSessionStorage extends SessionStorage {
  int getSessionCalls = 0;

  @override
  Future<ChatSession?> getSession(String id) {
    getSessionCalls++;
    return super.getSession(id);
  }
}
