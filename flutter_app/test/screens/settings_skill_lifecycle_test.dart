import 'dart:async';
import 'dart:io';

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
  // The first workflow template, as the settings screen reads it.
  const templateMarkdown = 'root/workspace/skills/daily-work-summary/SKILL.md';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PreferencesService.resetForTesting();
    messenger.setMockMethodCallHandler(secure, (call) async {
      switch (call.method) {
        case 'read':
          return null;
        case 'readAll':
          return <String, String>{};
        case 'containsKey':
          return false;
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(native, null);
    messenger.setMockMethodCallHandler(secure, null);
    PreferencesService.resetForTesting();
  });

  testWidgets(
      'leaving settings during the consent scan never scans a disposed page',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 760);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    Completer<String>? heldScan;
    messenger.setMockMethodCallHandler(native, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
      switch (call.method) {
        case 'getArch':
          return 'arm64-v8a';
        case 'getBootstrapStatus':
          return <String, Object?>{'rootfsExists': true};
        case 'runInProot':
          final held = heldScan;
          if (held != null) return held.future;
          return '';
        case 'readRootfsFile':
          return args['path'] == templateMarkdown ? '# 每日工作总结' : null;
        case 'readRootfsFileBounded':
          return null;
        case 'writeRootfsFile':
          return true;
        case 'deleteRootfsFile':
          return true;
      }
      return null;
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: SettingsScreen(
          initialDestination: SettingsDestination.agentTools,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The template row renders as installed, so its switch starts the consent
    // flow (which first has to scan the installed skills).
    final templateTitle = find.textContaining('每日工作总结');
    await tester.scrollUntilVisible(
      templateTitle,
      320,
      scrollable: _detailScrollable(tester),
    );
    await tester.ensureVisible(templateTitle);
    await tester.pumpAndSettle();
    final templateSwitch = find.descendant(
      of: find.ancestor(of: templateTitle, matching: find.byType(ListTile)),
      matching: find.byType(Switch),
    );
    expect(templateSwitch, findsOneWidget);

    // Hold the consent scan, then leave the page while it is still pending.
    heldScan = Completer<String>();
    await tester.tap(templateSwitch);
    await tester.pump();

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();

    heldScan.complete('');
    await tester.pumpAndSettle();

    // The resumed consent flow must not scan or setState on the disposed page.
    expect(tester.takeException(), isNull);
  });

  test('the skill scan error state keeps its retry wiring', () {
    final source = File('lib/screens/settings_screen.dart').readAsStringSync();
    // A scan failure still lands in the explicit error tile with a retry, and
    // retrying runs the guarded load again instead of writing from a disposed
    // page.
    expect(source, contains("_skillsLoadError = '无法读取本地扩展'"));
    expect(source, contains('onPressed: _refreshSkillsAndUpdateStates'));
    expect(source, contains('本地扩展检查未完成。'));
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
