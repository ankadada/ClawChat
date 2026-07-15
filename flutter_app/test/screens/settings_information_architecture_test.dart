import 'dart:ui';

import 'package:clawchat/constants.dart';
import 'package:clawchat/l10n/app_strings.dart';
import 'package:clawchat/screens/settings_screen.dart';
import 'package:clawchat/services/preferences_service.dart';
import 'package:clawchat/services/update_transaction.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const native = MethodChannel(AppConstants.channelName);
  const secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PreferencesService.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(native, (call) async {
      return switch (call.method) {
        'getArch' => 'arm64-v8a',
        'getBootstrapStatus' => <String, Object?>{
            'rootfsExists': true,
            'pythonInstalled': true,
          },
        'runInProot' => '',
        _ => null,
      };
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secure, (call) async {
      if (call.method == 'readAll') return <String, String>{};
      if (call.method == 'containsKey') return false;
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(native, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secure, null);
    PreferencesService.resetForTesting();
  });

  test('inventory maps every legacy control family to one task destination',
      () {
    expect(
        SettingsScreen.controlInventory, hasLength(greaterThanOrEqualTo(30)));
    expect(
      SettingsScreen.controlInventory.map((item) => item.destination).toSet(),
      SettingsDestination.values.toSet(),
    );
    final labels = SettingsScreen.controlInventory.map((item) => item.label);
    for (final required in [
      '模型提供商与模型组',
      '远程 Agent',
      '工具审批策略',
      '工具拒绝列表',
      'MCP 服务器',
      'Whisper 模型',
      '本地数据恢复',
      '应用更新',
      '技能与扩展',
      '隐私模式',
      '开发者模式',
      '主题',
      '隐私政策',
      '应用版本与关于',
    ]) {
      expect(labels, contains(required));
    }
    final searchable = SettingsScreen.controlInventory
        .expand((item) => [item.label, ...item.keywords])
        .join(' ')
        .toLowerCase();
    expect(searchable, isNot(contains('https://')));
    expect(searchable, isNot(contains('credential')));
    expect(SettingsScreen.extensionActionLabels, ['更新', '历史', '回滚']);
  });

  testWidgets('privacy policy action is visible and searchable from About',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: SettingsScreen()),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), '隐私政策');
    await tester.pump();
    expect(find.text('外观与关于'), findsOneWidget);
    expect(find.textContaining('匹配：隐私政策'), findsOneWidget);

    await tester.pumpWidget(
      const MaterialApp(
        home: SettingsDetailScreen(
          destination: SettingsDestination.appearanceAbout,
          skipInitialLoadForTesting: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('隐私政策'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byIcon(Icons.privacy_tip_outlined), findsOneWidget);
    expect(find.text('隐私政策'), findsOneWidget);
  });

  testWidgets('updates destination labels app and extension actions',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SettingsDetailScreen(
          destination: SettingsDestination.updatesExtensions,
          skipInitialLoadForTesting: true,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('应用更新'), findsOneWidget);
    expect(find.textContaining('当前版本'), findsOneWidget);
    expect(find.text('检查应用更新'), findsOneWidget);
    expect(find.text('技能与扩展'), findsOneWidget);
    expect(find.text('从本地更新'), findsOneWidget);
    expect(find.textContaining('不会自动下载或安装'), findsOneWidget);
  });

  testWidgets('data destination does not expose privacy or developer controls',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SettingsDetailScreen(
          destination: SettingsDestination.dataRecovery,
          skipInitialLoadForTesting: true,
        ),
      ),
    );
    await tester.pump();

    expect(find.text(AppStrings.localDataRecovery), findsOneWidget);
    expect(find.text('本地任务中心'), findsOneWidget);
    expect(find.text(AppStrings.privacyMode), findsNothing);
    expect(find.text('开发者模式'), findsNothing);
  });

  testWidgets('update actions live only in Updates and Extensions',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SettingsDetailScreen(
          destination: SettingsDestination.agentTools,
          skipInitialLoadForTesting: true,
        ),
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.system_update_alt), findsNothing);
    expect(find.byIcon(Icons.upgrade), findsNothing);
    expect(find.text('检查应用更新'), findsNothing);
  });

  testWidgets('app update stages expose the next truthful local state',
      (tester) async {
    const cases = <AppUpdateStage, String>{
      AppUpdateStage.verified: '已验证，可交给系统安装器',
      AppUpdateStage.handedOff: '系统安装器已打开',
      AppUpdateStage.installedObserved: '已观察到安装完成',
    };
    for (final entry in cases.entries) {
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsDetailScreen(
            key: UniqueKey(),
            destination: SettingsDestination.updatesExtensions,
            skipInitialLoadForTesting: true,
            appUpdateStateLoaderForTesting: (_) async =>
                _appUpdateState(entry.key),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(entry.value), findsOneWidget);
    }
  });

  testWidgets('unknown update state retries and fold rebuild does not reload',
      (tester) async {
    var calls = 0;
    final media = ValueNotifier(
      const MediaQueryData(
        size: Size(800, 700),
        displayFeatures: [
          DisplayFeature(
            bounds: Rect.fromLTWH(390, 0, 20, 700),
            type: DisplayFeatureType.hinge,
            state: DisplayFeatureState.postureFlat,
          ),
        ],
      ),
    );
    addTearDown(media.dispose);
    final detail = SettingsDetailScreen(
      destination: SettingsDestination.updatesExtensions,
      skipInitialLoadForTesting: true,
      appUpdateStateLoaderForTesting: (_) async {
        calls += 1;
        if (calls == 1) throw StateError('local state unavailable');
        return _appUpdateState(AppUpdateStage.handedOff);
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<MediaQueryData>(
          valueListenable: media,
          child: detail,
          builder: (_, data, child) => MediaQuery(data: data, child: child!),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('更新状态：未知'), findsOneWidget);
    expect(calls, 1);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('系统安装器已打开'), findsOneWidget);
    expect(calls, 2);

    media.value = media.value.copyWith(
      viewInsets: const EdgeInsets.only(bottom: 260),
    );
    await tester.pump();
    expect(find.text('系统安装器已打开'), findsOneWidget);
    expect(calls, 2);
  });

  testWidgets('landing search returns a control and normal back restores query',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    await tester.pumpWidget(
      const MaterialApp(home: SettingsScreen()),
    );

    expect(find.text('连接'), findsOneWidget);
    expect(find.text('开发者'), findsOneWidget);
    expect(find.text('工具审批策略'), findsNothing);

    await tester.enterText(find.byType(TextField), '审批');
    await tester.pump();
    expect(find.text('Agent 与工具'), findsOneWidget);
    expect(find.textContaining('匹配：工具审批策略'), findsOneWidget);
    expect(find.text('语音'), findsNothing);

    await tester.tap(find.text('Agent 与工具'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('工具审批策略'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.textContaining('匹配：工具审批策略'), findsOneWidget);
    expect(find.widgetWithText(TextField, '审批'), findsOneWidget);
  });

  testWidgets('voice deep link loads only the voice destination',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 900);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    await tester.pumpWidget(
      const MaterialApp(
        home: SettingsScreen(initialDestination: SettingsDestination.voice),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text(AppStrings.whisperModelLabel), findsOneWidget);
    expect(find.text('工具审批策略'), findsNothing);
    expect(find.text('隐私模式'), findsNothing);
  });

  testWidgets('book fold keeps index search and detail outside the hinge',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 700);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
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
          child: SettingsScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.enterText(find.byType(TextField).first, '隐私模式');
    await tester.pump();
    expect(find.text('隐私'), findsOneWidget);
    await tester.tap(find.text('隐私'));
    await tester.pump();
    expect(find.text('隐私模式'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tabletop and IME changes preserve search query', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 760);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    final media = ValueNotifier(
      const MediaQueryData(
        size: Size(400, 760),
        textScaler: TextScaler.linear(2),
        displayFeatures: [
          DisplayFeature(
            bounds: Rect.fromLTWH(0, 350, 400, 20),
            type: DisplayFeatureType.fold,
            state: DisplayFeatureState.postureHalfOpened,
          ),
        ],
      ),
    );
    addTearDown(media.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<MediaQueryData>(
          valueListenable: media,
          child: const SettingsScreen(),
          builder: (_, data, child) => MediaQuery(data: data, child: child!),
        ),
      ),
    );

    expect(tester.getTopLeft(find.byType(TextField)).dy,
        greaterThanOrEqualTo(370));
    await tester.enterText(find.byType(TextField), '应用更新');
    await tester.pump();
    expect(find.text('更新与扩展'), findsOneWidget);
    media.value = media.value.copyWith(
      viewInsets: const EdgeInsets.only(bottom: 280),
    );
    await tester.pump();

    expect(tester.getBottomLeft(find.byType(TextField)).dy,
        lessThanOrEqualTo(350));
    expect(find.widgetWithText(TextField, '应用更新'), findsOneWidget);
    expect(find.text('更新与扩展'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

AppUpdateStagingState _appUpdateState(AppUpdateStage stage) =>
    AppUpdateStagingState(
      targetId: AppConstants.packageName,
      version: '2.5.2',
      revision: 8,
      sha256: 'a' * 64,
      size: 1024,
      path: '/tmp/staged-update.apk',
      stage: stage,
      createdAt: '2026-07-12T00:00:00Z',
      handedOffAt:
          stage == AppUpdateStage.verified ? null : '2026-07-12T00:01:00Z',
    );
