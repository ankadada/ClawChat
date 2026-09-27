import 'package:clawchat/constants.dart';
import 'package:clawchat/screens/scheduled_tasks_screen.dart';
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
      switch (call.method) {
        case 'getArch':
          return 'arm64-v8a';
        case 'getBootstrapStatus':
          return <String, Object?>{'rootfsExists': true};
        case 'runInProot':
          return '';
      }
      return null;
    });
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

  testWidgets('the settings entry opens the local plan screen', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SettingsScreen(
          initialDestination: SettingsDestination.dataRecovery,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final entry = find.text('计划执行');
    await tester.scrollUntilVisible(
      entry,
      320,
      scrollable: _detailScrollable(tester),
    );
    await tester.ensureVisible(entry);
    await tester.pumpAndSettle();

    await tester.tap(entry);
    await tester.pumpAndSettle();

    // The promised plan screen opens (not a dead-end tile) and still says a
    // due plan needs the task-center confirmation.
    expect(find.byType(ScheduledTasksScreen), findsOneWidget);
    expect(find.text('新建计划'), findsOneWidget);
    expect(find.textContaining('需要你再次确认才会执行'), findsWidgets);
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
