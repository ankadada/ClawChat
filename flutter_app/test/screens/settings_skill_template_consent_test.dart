import 'dart:convert';
import 'package:clawchat/constants.dart';
import 'package:clawchat/services/skill_service.dart';
import 'package:clawchat/services/skill_template_catalog.dart';
import 'package:clawchat/services/skill_template_service.dart';
import 'package:clawchat/l10n/app_strings.dart';
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

  Finder detailScrollable(WidgetTester tester) {
    final vertical = tester
        .widgetList<Scrollable>(find.byType(Scrollable))
        .where((scrollable) => scrollable.axisDirection == AxisDirection.down)
        .toList();
    expect(vertical, isNotEmpty);
    return find.byWidget(vertical.last);
  }

  testWidgets('installing a template from the list asks for consent first',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 760);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final writes = <Map<String, dynamic>>[];
    messenger.setMockMethodCallHandler(native, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
      switch (call.method) {
        case 'getArch':
          return 'arm64-v8a';
        case 'getBootstrapStatus':
          return <String, Object?>{'rootfsExists': true};
        case 'runInProot':
          return '';
        case 'readRootfsFile':
        case 'readRootfsFileBounded':
          return null;
        case 'createRootfsDirectory':
          return true;
        case 'writeRootfsFile':
        case 'writeRootfsFileBounded':
          writes.add(args);
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

    final installIcon = find.byIcon(Icons.download_outlined).first;
    await tester.scrollUntilVisible(
      installIcon,
      320,
      scrollable: detailScrollable(tester),
    );
    await tester.ensureVisible(installIcon);
    await tester.pumpAndSettle();

    await tester.tap(installIcon);
    await tester.pumpAndSettle();

    // The permission preview opens first; nothing is written yet.
    expect(find.textContaining('需要的权限'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '安装到工作区'), findsOneWidget);
    expect(writes, isEmpty);

    await tester.tap(find.widgetWithText(FilledButton, '安装到工作区'));
    await tester.pumpAndSettle();

    expect(writes, isNotEmpty);
    expect(find.textContaining('已安装'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'the updates/extensions destination offers the workflow templates',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 760);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    messenger.setMockMethodCallHandler(native, (call) async {
      switch (call.method) {
        case 'getArch':
          return 'arm64-v8a';
        case 'getBootstrapStatus':
          return <String, Object?>{'rootfsExists': true};
        case 'runInProot':
          return '';
        case 'readRootfsFile':
        case 'readRootfsFileBounded':
          return null;
        case 'createRootfsDirectory':
          return true;
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
          initialDestination: SettingsDestination.updatesExtensions,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The extensions surface names the template entry and lists a template,
    // so a device user who looks here finds the promised workflow templates.
    final header = find.text(AppStrings.skillTemplates);
    await tester.scrollUntilVisible(
      header,
      320,
      scrollable: detailScrollable(tester),
    );
    await tester.ensureVisible(header);
    await tester.pumpAndSettle();

    expect(header, findsWidgets);
    expect(find.textContaining('每日工作总结'), findsOneWidget);
    expect(find.textContaining('安装后默认禁用'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('enabling an installed template consents from its own files',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 760);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    // Device case: the installed package is on disk, but the guest scan
    // returns nothing, so the skills list never lists it.
    final logs = <String>[];
    final originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) logs.add(message);
    };

    const template = SkillTemplateCatalog.dailyWorkSummary;
    final markdownPath =
        'root/workspace/skills/${template.stableSkillId}/SKILL.md';
    final manifestPath =
        'root/workspace/skills/${template.stableSkillId}/skill.json';
    final manifestJson = SkillTemplateService().buildManifestJson(template);

    messenger.setMockMethodCallHandler(native, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
      switch (call.method) {
        case 'getArch':
          return 'arm64-v8a';
        case 'getBootstrapStatus':
          return <String, Object?>{'rootfsExists': true};
        case 'runInProot':
          return '';
        case 'readRootfsFile':
        case 'readRootfsFileBounded':
          final path = args['path']?.toString();
          if (path == markdownPath) {
            return call.method == 'readRootfsFileBounded'
                ? Uint8List.fromList(utf8.encode(template.skillMarkdown))
                : template.skillMarkdown;
          }
          if (path == manifestPath) {
            return call.method == 'readRootfsFileBounded'
                ? Uint8List.fromList(utf8.encode(manifestJson))
                : manifestJson;
          }
          return null;
        case 'createRootfsDirectory':
          return true;
        case 'writeRootfsFile':
        case 'writeRootfsFileBounded':
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

    final templateTitle = find.textContaining(template.name);
    await tester.scrollUntilVisible(
      templateTitle,
      320,
      scrollable: detailScrollable(tester),
    );
    await tester.ensureVisible(templateTitle);
    await tester.pumpAndSettle();

    final templateSwitch = find.descendant(
      of: find.ancestor(of: templateTitle, matching: find.byType(ListTile)),
      matching: find.byType(Switch),
    );
    expect(templateSwitch, findsOneWidget);
    expect(tester.widget<Switch>(templateSwitch).value, isFalse);
    // Installed but not enabled: the subtitle must say exactly that.
    expect(find.textContaining('已安装（未启用）'), findsOneWidget);

    // Enabling must reach the existing consent dialog, built from the
    // installed files, instead of claiming there is no local skill file.
    await tester.tap(templateSwitch);
    await tester.pumpAndSettle();

    expect(find.text('Review skill capabilities'), findsOneWidget);
    expect(find.textContaining('未找到本地技能文件'), findsNothing);
    // Device-diagnosable classification, safe to paste from logcat.
    expect(
      logs.any((line) =>
          line.contains('[clawchat.template]') &&
          line.contains('consent candidate built from installed files')),
      isTrue,
    );

    await tester.tap(find.byType(FilledButton).last);
    await tester.pumpAndSettle();

    expect(
      await SkillService.isSkillStoredEnabled(template.stableSkillId),
      isTrue,
    );
    // The switch is on, but the guest scan never listed the package: the user
    // must be told that runtime execution may be unavailable.
    expect(
      logs.any((line) => line.contains('guest scan does not list it')),
      isTrue,
    );
    expect(
      find.textContaining('运行期执行可能暂不可用'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    // The row subtitle follows the real switch state, not just the files.
    expect(find.textContaining('已启用'), findsOneWidget);
    expect(find.textContaining('已安装（未启用）'), findsNothing);

    // Re-entering the screen keeps the enabled state and the subtitle.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      const MaterialApp(
        home: SettingsScreen(
          initialDestination: SettingsDestination.agentTools,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final reopenedTitle = find.textContaining(template.name);
    await tester.scrollUntilVisible(
      reopenedTitle,
      320,
      scrollable: detailScrollable(tester),
    );
    await tester.ensureVisible(reopenedTitle);
    await tester.pumpAndSettle();
    expect(find.textContaining('已启用'), findsOneWidget);

    // Turning it back off returns the row to installed-but-disabled.
    final reopenedSwitch = find.descendant(
      of: find.ancestor(
        of: reopenedTitle,
        matching: find.byType(ListTile),
      ),
      matching: find.byType(Switch),
    );
    expect(tester.widget<Switch>(reopenedSwitch).value, isTrue);
    await tester.tap(reopenedSwitch);
    await tester.pumpAndSettle();
    expect(find.textContaining('已安装（未启用）'), findsOneWidget);

    // The test binding asserts every foundation debug variable is restored
    // before the body ends.
    debugPrint = originalDebugPrint;
  });

  testWidgets('rolling back a template confirms before restoring files',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 760);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    messenger.setMockMethodCallHandler(native, (call) async {
      switch (call.method) {
        case 'getArch':
          return 'arm64-v8a';
        case 'getBootstrapStatus':
          return <String, Object?>{'rootfsExists': true};
        case 'runInProot':
          return '';
        case 'readRootfsFile':
          return 'installed body';
        case 'readRootfsFileBounded':
          return null;
        case 'createRootfsDirectory':
          return true;
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

    final rollbackIcon = find.byIcon(Icons.history).first;
    await tester.scrollUntilVisible(
      rollbackIcon,
      320,
      scrollable: detailScrollable(tester),
    );
    await tester.ensureVisible(rollbackIcon);
    await tester.pumpAndSettle();

    await tester.tap(rollbackIcon);
    await tester.pumpAndSettle();

    expect(find.text('回滚到上一版本'), findsOneWidget);
    expect(find.textContaining('恢复安装前的本地文件'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '删除').last);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
