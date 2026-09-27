import 'dart:async';
import 'dart:io';

import 'package:clawchat/constants.dart';
import 'package:clawchat/screens/settings_screen.dart';
import 'package:clawchat/services/file_attachment_service.dart';
import 'package:clawchat/services/native_bridge.dart';
import 'package:clawchat/services/preferences_service.dart';
import 'package:file_picker/file_picker.dart';
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
    FileAttachmentService.resetPickerForTesting();
    NativeBridge.resetImportReadStreamForTesting();
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
    FileAttachmentService.resetPickerForTesting();
    NativeBridge.resetImportReadStreamForTesting();
    PreferencesService.resetForTesting();
  });

  testWidgets(
      'leaving settings mid-pick cleans both staged copies and nothing else',
      (tester) async {
    final stagingDirectory =
        Directory.systemTemp.createTempSync('settings-pick-');
    addTearDown(() => stagingDirectory.deleteSync(recursive: true));
    // Staged copies this flow owns; the provider originals are not files here.
    final metadataPath =
        '${stagingDirectory.path}/clawchat_picked_content/meta.json';
    final archivePath =
        '${stagingDirectory.path}/clawchat_picked_content/update.zip';
    File(metadataPath)
      ..createSync(recursive: true)
      ..writeAsStringSync('{}');
    File(archivePath)
      ..createSync(recursive: true)
      ..writeAsStringSync('zip');

    final archiveStagingStarted = Completer<void>();
    final archiveStagingRelease = Completer<void>();
    final cleanupDone = Completer<void>();
    final discarded = <String>[];

    NativeBridge.setPickedContentStagersForTesting(
      stager: (contentUri, displayName, maxBytes) async {
        if (contentUri == 'content://archive') {
          if (!archiveStagingStarted.isCompleted) {
            archiveStagingStarted.complete();
          }
          await archiveStagingRelease.future;
          return archivePath;
        }
        return metadataPath;
      },
      disposer: (path) async {
        discarded.add(path);
        final file = File(path);
        if (file.existsSync()) file.deleteSync();
        if (discarded.length == 2 && !cleanupDone.isCompleted) {
          cleanupDone.complete();
        }
      },
    );

    FileAttachmentService.setPickerForTesting(({
      required FileType type,
      required bool allowMultiple,
      required List<String>? allowedExtensions,
    }) async {
      if (allowedExtensions?.contains('json') ?? false) {
        return FilePickerResult([
          PlatformFile(
              name: 'meta.json', size: 2, identifier: 'content://meta'),
        ]);
      }
      return FilePickerResult([
        PlatformFile(
          name: 'update.zip',
          size: 3,
          identifier: 'content://archive',
        ),
      ]);
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: SettingsScreen(
          initialDestination: SettingsDestination.updatesExtensions,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final localUpdate = find.text('从本地更新');
    await tester.scrollUntilVisible(
      localUpdate,
      320,
      scrollable: _detailScrollable(tester),
    );
    await tester.ensureVisible(localUpdate);
    await tester.pumpAndSettle();

    // The picker copies real files, so its file I/O needs the real event loop.
    // The metadata copy is staged; the archive staging call is held open.
    await tester.runAsync(() async {
      await tester.tap(localUpdate);
      await archiveStagingStarted.future
          .timeout(const Duration(seconds: 5), onTimeout: () {});
    });
    expect(archiveStagingStarted.isCompleted, isTrue);

    // Leave the page, then let the held staging and the flow finish.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    await tester.runAsync(() async {
      archiveStagingRelease.complete();
      await cleanupDone.future
          .timeout(const Duration(seconds: 5), onTimeout: () {});
    });
    await tester.pumpAndSettle();

    // Both staged copies of this flow were dropped, and nothing else was.
    expect(cleanupDone.isCompleted, isTrue);
    expect(discarded, containsAll([metadataPath, archivePath]));
    expect(discarded, hasLength(2));
    expect(File(metadataPath).existsSync(), isFalse);
    expect(File(archivePath).existsSync(), isFalse);
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
