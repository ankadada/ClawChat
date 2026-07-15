import 'dart:convert';
import 'dart:ui';

import 'package:clawchat/constants.dart';
import 'package:clawchat/l10n/app_strings.dart';
import 'package:clawchat/screens/settings_screen.dart';
import 'package:clawchat/services/bundled_legacy_skill_catalog.dart';
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
          if (command.startsWith("find '/root/workspace/skills'")) {
            return '/root/workspace/skills/github/SKILL.md';
          }
          return '';
        case 'readRootfsFile':
        case 'readRootfsFileBounded':
          final path = args['path'] as String;
          if (path.endsWith('/SKILL.md')) {
            const content =
                '---\nname: github\ndescription: legacy preset\n---\nbody';
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
      'shows bounded reason with a disabled switch at 320dp and 200% text',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 720);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    await _pumpSettings(
      tester,
      const MediaQueryData(
        size: Size(320, 720),
        textScaler: TextScaler.linear(2),
      ),
    );

    final tile = await _revealLockedPreset(tester);
    expect(
      find.text(BundledLegacySkillCatalog.legacyUnavailableReason),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Switch>(
              find.descendant(of: tile, matching: find.byType(Switch)))
          .onChanged,
      isNull,
    );
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(
      find.text(AppStrings.bundledLegacyPresetsUnavailable),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(AppStrings.bundledLegacyPresetsUnavailable));
    await tester.pumpAndSettle();
    expect(
      find.text(AppStrings.bundledLegacyPresetsUnavailableDescription),
      findsOneWidget,
    );
    expect(find.text('Install disabled'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('updates destination also keeps the preset switch locked',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 760);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    await _pumpSettings(
      tester,
      const MediaQueryData(
        size: Size(400, 760),
        textScaler: TextScaler.linear(2),
      ),
      destination: SettingsDestination.updatesExtensions,
    );

    final tile = await _revealLockedPreset(tester);
    expect(
      find.text(BundledLegacySkillCatalog.legacyUnavailableReason),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Switch>(
            find.descendant(of: tile, matching: find.byType(Switch)),
          )
          .onChanged,
      isNull,
    );
    for (final label in SettingsScreen.extensionActionLabels) {
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, label),
            )
            .onPressed,
        isNull,
        reason: label,
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('book posture keeps locked preset control outside the hinge',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 700);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    const hinge = Rect.fromLTWH(390, 0, 20, 700);
    await _pumpSettings(
      tester,
      const MediaQueryData(
        size: Size(800, 700),
        textScaler: TextScaler.linear(2),
        displayFeatures: [
          DisplayFeature(
            bounds: hinge,
            type: DisplayFeatureType.hinge,
            state: DisplayFeatureState.postureFlat,
          ),
        ],
      ),
    );

    final tile = await _revealLockedPreset(tester);
    expect(tester.getRect(tile).overlaps(hinge), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'tabletop and IME keep the locked preset control in the active region',
      (tester) async {
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
          child: const SettingsScreen(
            initialDestination: SettingsDestination.agentTools,
          ),
          builder: (_, data, child) => MediaQuery(data: data, child: child!),
        ),
      ),
    );
    await tester.pumpAndSettle();

    var tile = await _revealLockedPreset(tester);
    expect(tester.getRect(tile).top, greaterThanOrEqualTo(370));

    media.value = media.value.copyWith(
      viewInsets: const EdgeInsets.only(bottom: 280),
    );
    await tester.pumpAndSettle();
    tile = await _revealLockedPreset(tester);
    final imeSwitch = tester.getRect(
      find.descendant(of: tile, matching: find.byType(Switch)),
    );
    expect(imeSwitch.overlaps(const Rect.fromLTWH(0, 350, 400, 20)), isFalse);
    expect(imeSwitch.bottom, lessThanOrEqualTo(350));
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpSettings(
  WidgetTester tester,
  MediaQueryData media, {
  SettingsDestination destination = SettingsDestination.agentTools,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: media,
        child: SettingsScreen(
          initialDestination: destination,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<Finder> _revealLockedPreset(WidgetTester tester) async {
  final reason = find.text(BundledLegacySkillCatalog.legacyUnavailableReason);
  await tester.scrollUntilVisible(
    reason,
    360,
    scrollable: _detailScrollable(tester),
  );
  final tile = find.ancestor(of: reason, matching: find.byType(SwitchListTile));
  expect(tile, findsOneWidget);
  return tile;
}

Finder _detailScrollable(WidgetTester tester) {
  final vertical = tester
      .widgetList<Scrollable>(find.byType(Scrollable))
      .where((scrollable) => scrollable.axisDirection == AxisDirection.down)
      .toList();
  expect(vertical, isNotEmpty);
  return find.byWidget(vertical.last);
}
