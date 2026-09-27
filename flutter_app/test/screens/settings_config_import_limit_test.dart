import 'package:clawchat/constants.dart';
import 'package:clawchat/l10n/app_strings.dart';
import 'package:clawchat/screens/settings_screen.dart';
import 'package:clawchat/services/config_export_service.dart';
import 'package:clawchat/services/preferences_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// v2.18: the config-import picker enforces the 50 MiB hard cap before the
/// file is read, copied or staged, and shows one actionable message.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const nativeChannel = MethodChannel(AppConstants.channelName);
  const secureChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<String> nativeCalls;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PreferencesService.resetForTesting();
    nativeCalls = [];
    messenger.setMockMethodCallHandler(nativeChannel, (call) async {
      nativeCalls.add(call.method);
      return null;
    });
    messenger.setMockMethodCallHandler(secureChannel, (call) async {
      switch (call.method) {
        case 'readAll':
          return <String, String>{};
        case 'containsKey':
          return false;
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(nativeChannel, null);
    messenger.setMockMethodCallHandler(secureChannel, null);
    PreferencesService.resetForTesting();
  });

  Future<void> pumpSettings(
    WidgetTester tester,
    Future<FilePickerResult?> Function() picker,
  ) async {
    await tester.pumpWidget(MaterialApp(
      home: SettingsScreen(
        skipInitialLoadForTesting: true,
        initialDestination: SettingsDestination.dataRecovery,
        importConfigPickerForTesting: picker,
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> tapImportConfig(WidgetTester tester) async {
    final tile = find.widgetWithText(ListTile, AppStrings.importConfig);
    await tester.scrollUntilVisible(
      tile,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(tile);
    await tester.pumpAndSettle();
  }

  testWidgets('an oversized pick is refused with the file, size and limit',
      (tester) async {
    await pumpSettings(
      tester,
      () async => FilePickerResult([
        PlatformFile(
          name: 'huge-config.json',
          size: 60 * 1024 * 1024,
          // A path that does not exist: reading it would fail loudly, so the
          // test also proves the guard runs before any read.
          path: '/nonexistent-clawchat-test/huge-config.json',
        ),
      ]),
    );

    await tapImportConfig(tester);

    expect(
      find.textContaining('huge-config.json'),
      findsOneWidget,
      reason: 'the message must name the picked file',
    );
    expect(find.textContaining('60.0MB'), findsOneWidget);
    expect(find.textContaining('上限 50.0MB'), findsOneWidget);
    expect(find.text(AppStrings.importConfigComplete), findsNothing);
    expect(find.textContaining(AppStrings.importConfigFailed), findsNothing);
    // Nothing was read or staged through the platform.
    expect(nativeCalls, isNot(contains('stagePickedContentUri')));
    expect(nativeCalls, isNot(contains('importHostFileToWorkspace')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a pick without a readable path says so instead of doing nothing',
      (tester) async {
    await pumpSettings(
      tester,
      () async => FilePickerResult([
        PlatformFile(name: 'provider-only.json', size: 1024),
      ]),
    );

    await tapImportConfig(tester);

    expect(find.textContaining('无法读取配置文件'), findsOneWidget);
    expect(find.textContaining('provider-only.json'), findsOneWidget);
    expect(nativeCalls, isNot(contains('stagePickedContentUri')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a pick exactly at the cap passes the guard, not the size error',
      (tester) async {
    // The parse/preview success path itself is covered by the service tests;
    // here the point is that the boundary value is not rejected by the guard.
    var picked = 0;
    await pumpSettings(
      tester,
      () async {
        picked += 1;
        return FilePickerResult([
          PlatformFile(
            name: 'at-limit.json',
            size: ConfigExportService.maxImportBytes,
            path: '/nonexistent-clawchat-test/at-limit.json',
          ),
        ]);
      },
    );

    await tapImportConfig(tester);

    expect(picked, 1, reason: 'the picker flow ran');
    expect(find.textContaining('配置文件过大'), findsNothing);
    expect(find.textContaining('上限 50.0MB'), findsNothing);
    expect(nativeCalls, isNot(contains('stagePickedContentUri')));
    expect(tester.takeException(), isNull);
  });
}
