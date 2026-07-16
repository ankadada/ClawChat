import 'dart:convert';
import 'package:clawchat/constants.dart';
import 'package:clawchat/screens/settings_screen.dart';
import 'package:clawchat/services/preferences_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const native = MethodChannel(AppConstants.channelName);
  const secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PreferencesService.resetForTesting();
    messenger.setMockMethodCallHandler(native, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
      switch (call.method) {
        case 'getArch':
          return 'arm64-v8a';
        case 'getBootstrapStatus':
          return <String, Object?>{'rootfsExists': true};
        case 'runInProot':
          final command = args['command'] as String;
          if (command.contains("find '/root/workspace/.agents/skills'")) {
            return '/root/workspace/.agents/skills/xds-skills/SKILL.md';
          }
          return '';
        case 'readRootfsFile':
        case 'readRootfsFileBounded':
          final path = args['path'] as String;
          if (path.endsWith('/xds-skills/SKILL.md')) {
            const content =
                '---\nname: xds-skills\ndescription: XDS tools\n---\nUse XDS.';
            return call.method == 'readRootfsFileBounded'
                ? utf8.encode(content)
                : content;
          }
          return null;
      }
      return null;
    });
    messenger.setMockMethodCallHandler(secure, (call) async {
      if (call.method == 'readAll') return <String, String>{};
      if (call.method == 'containsKey') return false;
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(native, null);
    messenger.setMockMethodCallHandler(secure, null);
    PreferencesService.resetForTesting();
  });

  testWidgets(
      'unmanifested CLI-managed skill is visible but explicitly unavailable',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 760);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: Size(400, 760),
            textScaler: TextScaler.linear(2),
          ),
          child: SettingsScreen(
            initialDestination: SettingsDestination.updatesExtensions,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final title = find.text('xds-skills · vlegacy');
    await tester.scrollUntilVisible(
      title,
      320,
      scrollable: _detailScrollable(tester),
    );
    await tester.ensureVisible(title);
    await tester.pumpAndSettle();
    expect(title, findsOneWidget);
    expect(
      find.text('需要兼容升级：此 Skill 缺少受支持的权限清单。请通过 xd-skill 更新后重新授权。'),
      findsOneWidget,
    );

    final tile = find.ancestor(
      of: title,
      matching: find.byType(SwitchListTile),
    );
    expect(tile, findsOneWidget);
    final toggle = find.descendant(of: tile, matching: find.byType(Switch));
    expect(tester.widget<Switch>(toggle).onChanged, isNull);

    for (final label in SettingsScreen.extensionActionLabels) {
      final button = find.widgetWithText(OutlinedButton, label);
      expect(button, findsOneWidget);
      expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Agent and Tools lists CLI-managed skill at 320dp and 200 percent text',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 720);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: Size(320, 720),
            textScaler: TextScaler.linear(2),
          ),
          child: SettingsScreen(
            initialDestination: SettingsDestination.agentTools,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final title = find.text('xds-skills · Legacy');
    await tester.scrollUntilVisible(
      title,
      320,
      scrollable: _detailScrollable(tester),
    );
    await tester.ensureVisible(title);
    await tester.pumpAndSettle();
    expect(title, findsOneWidget);
    expect(
      find.textContaining('需要兼容升级：此 Skill 缺少受支持的权限清单'),
      findsOneWidget,
    );
    final tile = find.ancestor(
      of: title,
      matching: find.byType(SwitchListTile),
    );
    expect(tile, findsOneWidget);
    final toggle = find.descendant(of: tile, matching: find.byType(Switch));
    expect(tester.widget<Switch>(toggle).onChanged, isNull);
    expect(tester.takeException(), isNull);
  });
}

Finder _detailScrollable(WidgetTester tester) {
  final vertical = tester
      .widgetList<Scrollable>(find.byType(Scrollable))
      .where((scrollable) => scrollable.axisDirection == AxisDirection.down)
      .toList();
  expect(vertical, isNotEmpty);
  return find.byWidget(vertical.last);
}
