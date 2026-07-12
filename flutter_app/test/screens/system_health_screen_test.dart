import 'dart:ui';

import 'package:clawchat/constants.dart';
import 'package:clawchat/l10n/app_strings.dart';
import 'package:clawchat/models/chat_models.dart';
import 'package:clawchat/providers/chat_provider.dart';
import 'package:clawchat/screens/dashboard_screen.dart';
import 'package:clawchat/services/preferences_service.dart';
import 'package:clawchat/services/session_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ChatProvider provider;
  const native = MethodChannel(AppConstants.channelName);
  const secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PreferencesService.resetForTesting();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(native, (call) async {
      if (call.method == 'consumePendingNavigateToSession') return null;
      return true;
    });
    messenger.setMockMethodCallHandler(secure, (call) async {
      if (call.method == 'readAll') return <String, String>{};
      if (call.method == 'containsKey') return false;
      return null;
    });
    provider = ChatProvider(storage: _MemoryStorage());
    await Future<void>.delayed(const Duration(milliseconds: 30));
  });

  tearDown(() async {
    provider.dispose();
    PreferencesService.resetForTesting();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(native, null);
    messenger.setMockMethodCallHandler(secure, null);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  });

  testWidgets('unknown local checks never render as ready', (tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<ChatProvider>.value(
        value: provider,
        child: MaterialApp(
          home: DashboardScreen(
            loadForTesting: () async => const SystemHealthSnapshot(
              runtime: SystemHealthKind.unknown,
              runtimeDetail: '无法读取嵌入式运行时状态',
              updateState: null,
              updatesKnown: false,
              extensionCount: 0,
              extensionsKnown: false,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('系统健康'), findsOneWidget);
    expect(find.textContaining('未知 · 无法读取嵌入式运行时状态'), findsOneWidget);
    expect(find.textContaining('未知 · 更新状态未知'), findsOneWidget);
    expect(find.textContaining('未知 · 扩展状态未知'), findsOneWidget);
    expect(find.textContaining('健康分数'), findsNothing);
    expect(find.textContaining('云账户'), findsNothing);
    expect(AppStrings.dashboard, '系统健康');
  });

  testWidgets(
      'failed health load retries once and layout changes do not reload',
      (tester) async {
    var calls = 0;
    final media = ValueNotifier(const MediaQueryData(size: Size(400, 800)));
    addTearDown(media.dispose);
    final screen = DashboardScreen(
      loadForTesting: () async {
        calls += 1;
        if (calls == 1) throw StateError('local check unavailable');
        return const SystemHealthSnapshot(
          runtime: SystemHealthKind.ready,
          runtimeDetail: '运行时已就绪',
          updateState: null,
          updatesKnown: true,
          extensionCount: 1,
          extensionsKnown: true,
        );
      },
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<ChatProvider>.value(
        value: provider,
        child: MaterialApp(
          home: ValueListenableBuilder<MediaQueryData>(
            valueListenable: media,
            child: screen,
            builder: (_, data, child) => MediaQuery(data: data, child: child!),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('系统状态未知'), findsOneWidget);
    expect(calls, 1);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.textContaining('就绪 · 运行时已就绪'), findsOneWidget);
    expect(calls, 2);

    media.value = const MediaQueryData(
      size: Size(800, 700),
      viewInsets: EdgeInsets.only(bottom: 240),
      displayFeatures: [
        DisplayFeature(
          bounds: Rect.fromLTWH(390, 0, 20, 700),
          type: DisplayFeatureType.hinge,
          state: DisplayFeatureState.postureFlat,
        ),
      ],
    );
    await tester.pump();
    expect(calls, 2);
  });

  testWidgets('book posture and large text keep actions outside hinge',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 700);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    await tester.pumpWidget(
      ChangeNotifierProvider<ChatProvider>.value(
        value: provider,
        child: MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(800, 700),
              textScaler: TextScaler.linear(2),
              displayFeatures: [
                DisplayFeature(
                  bounds: Rect.fromLTWH(390, 0, 20, 700),
                  type: DisplayFeatureType.hinge,
                  state: DisplayFeatureState.postureFlat,
                ),
              ],
            ),
            child: DashboardScreen(
              loadForTesting: () async => const SystemHealthSnapshot(
                runtime: SystemHealthKind.ready,
                runtimeDetail: '运行时已就绪',
                updateState: null,
                updatesKnown: true,
                extensionCount: 2,
                extensionsKnown: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('就绪 · 运行时已就绪'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('health-action-应用更新')),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.textContaining('就绪 · 没有已验证的待处理应用更新'), findsOneWidget);
    expect(find.text('查看更新'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _MemoryStorage extends SessionStorage {
  @override
  Future<void> init() async {}

  @override
  Future<List<SessionSummary>> getSessionsSummary() async => const [];

  @override
  Future<ChatSession?> getSession(String id) async => null;
}
