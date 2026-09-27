import 'dart:async';

import 'package:clawchat/constants.dart';
import 'package:clawchat/screens/settings_screen.dart';
import 'package:clawchat/services/memory_service.dart';
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
  const memoryPath = 'root/.clawchat_memory.json';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PreferencesService.resetForTesting();
    MemoryService.resetForTesting();
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
    MemoryService.resetForTesting();
    PreferencesService.resetForTesting();
  });

  testWidgets('leaving settings while a memory write is pending is safe',
      (tester) async {
    final pendingWrite = Completer<void>();
    var writes = 0;
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
          return args['path'] == memoryPath ? '["fact one"]' : null;
        case 'readRootfsFileBounded':
          return null;
        case 'writeRootfsFile':
          writes++;
          if (args['path'] == memoryPath) await pendingWrite.future;
          return true;
        case 'deleteRootfsFile':
          return true;
      }
      return null;
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: SettingsScreen(
          initialDestination: SettingsDestination.dataRecovery,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final fact = find.text('fact one');
    await tester.scrollUntilVisible(
      fact,
      320,
      scrollable: _detailScrollable(tester),
    );
    await tester.ensureVisible(fact);
    await tester.pumpAndSettle();
    expect(fact, findsOneWidget);

    // Forget the fact, but hold the storage write open.
    final deleteIcon = find.descendant(
      of: find.ancestor(of: fact, matching: find.byType(ListTile)),
      matching: find.byIcon(Icons.delete_outline),
    );
    await tester.tap(deleteIcon);
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.byType(AlertDialog),
      matching: find.widgetWithText(TextButton, '删除'),
    ));
    await tester.pumpAndSettle();
    expect(writes, greaterThan(0));

    // Leave the page while the write is still in flight.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();

    pendingWrite.complete();
    await tester.pumpAndSettle();

    // The late continuation must not setState on the disposed page.
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
