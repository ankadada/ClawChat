import 'package:clawchat/constants.dart';
import 'package:clawchat/l10n/app_strings.dart';
import 'package:clawchat/providers/chat_provider.dart';
import 'package:clawchat/screens/chat_screen.dart';
import 'package:clawchat/services/attachment_budget.dart';
import 'package:clawchat/services/file_attachment_service.dart';
import 'package:clawchat/services/native_bridge.dart';
import 'package:clawchat/services/preferences_service.dart';
import 'package:clawchat/services/session_storage.dart';
import 'package:clawchat/widgets/pasted_text_blocks.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// §5 AND-3/AND-6: an oversized SAF pick must produce one visible, actionable
/// size error and must not stage anything behind the user's back.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const nativeChannel = MethodChannel(AppConstants.channelName);
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late ChatProvider provider;
  late Map<String, String> secureStorage;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PreferencesService.resetForTesting();
    FileAttachmentService.resetPickerForTesting();
    secureStorage = {};
    messenger.setMockMethodCallHandler(nativeChannel, (call) async {
      switch (call.method) {
        case 'consumePendingNavigateToSession':
        case 'consumePendingShareIntent':
          return null;
        case 'runInProot':
          return '';
        case 'getBootstrapStatus':
          return <String, Object?>{'availableBytes': 1 << 40};
      }
      return true;
    });
    messenger.setMockMethodCallHandler(secureStorageChannel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
      final key = args['key']?.toString();
      switch (call.method) {
        case 'read':
          return key == null ? null : secureStorage[key];
        case 'write':
          if (key != null) secureStorage[key] = args['value']?.toString() ?? '';
          return null;
        case 'delete':
          if (key != null) secureStorage.remove(key);
          return null;
        case 'deleteAll':
          secureStorage.clear();
          return null;
        case 'containsKey':
          return key != null && secureStorage.containsKey(key);
        case 'readAll':
          return Map<String, String>.from(secureStorage);
      }
      return null;
    });
    provider = ChatProvider(storage: _MemorySessionStorage());
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });

  tearDown(() async {
    provider.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    FileAttachmentService.resetPickerForTesting();
    NativeBridge.setPickedContentStagersForTesting(
        stager: null, disposer: null);
    messenger.setMockMethodCallHandler(nativeChannel, null);
    messenger.setMockMethodCallHandler(secureStorageChannel, null);
    PreferencesService.resetForTesting();
  });

  Future<void> pumpChat(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<ChatProvider>.value(
        value: provider,
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: const ChatScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> pickFile(WidgetTester tester) async {
    await tester.tap(find.byTooltip(AppStrings.attachFile));
    await tester.pumpAndSettle();
    await tester.tap(find.text(AppStrings.pickFile));
    await tester.pumpAndSettle();
  }

  testWidgets('an oversized SAF pick shows the limit and stages nothing',
      (tester) async {
    var stagerCalls = 0;
    NativeBridge.setPickedContentStagersForTesting(
      stager: (uri, name, maxBytes) async {
        stagerCalls += 1;
        throw StateError('an oversized document must not be staged');
      },
    );
    FileAttachmentService.setPickerForTesting(
      ({required type, required allowMultiple, allowedExtensions}) async =>
          FilePickerResult([
        PlatformFile(
          name: 'big_archive.zip',
          size: 60 * 1024 * 1024,
          identifier: 'content://downloads/documents/60',
        ),
      ]),
    );

    await pumpChat(tester);
    await pickFile(tester);

    expect(stagerCalls, 0, reason: 'nothing may be copied for a rejected file');
    expect(
      find.textContaining('big_archive.zip'),
      findsWidgets,
      reason: 'the error must name the file the user picked',
    );
    expect(
      find.textContaining('60.0 MB'),
      findsWidgets,
      reason: 'the error must state the actual size',
    );
    expect(
      find.textContaining('上限 50.0 MB'),
      findsWidgets,
      reason: 'the error must state the limit',
    );
    // Nothing was attached and the composer stays usable.
    expect(find.textContaining('[Image attached'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a refused send keeps the draft and explains why',
      (tester) async {
    // No provider credential is configured in this harness, so the provider
    // refuses the send before recording anything.
    await pumpChat(tester);
    await tester.enterText(
      find.descendant(
        of: find.byType(ComposerFieldMarker),
        matching: find.byType(TextField),
      ),
      'draft that must survive a refusal',
    );
    await tester.pump();

    await tester.tap(find.byTooltip(AppStrings.send));
    await tester.pumpAndSettle();

    // The text is still in the composer and the user is told why plus how to
    // fix it, instead of a silent no-op.
    final field = tester.widget<TextField>(
      find.descendant(
        of: find.byType(ComposerFieldMarker),
        matching: find.byType(TextField),
      ),
    );
    expect(field.controller!.text, 'draft that must survive a refusal');
    expect(
      find.textContaining(AppStrings.messageNotSent),
      findsWidgets,
    );
    expect(find.text(AppStrings.openMessageSettings), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a native size rejection keeps the size error, not a generic one',
      (tester) async {
    NativeBridge.setPickedContentStagersForTesting(
      stager: (uri, name, maxBytes) async {
        throw PlatformException(
          code: NativeBridge.pickedContentTooLargeCode,
          message: 'picked content exceeds the size limit',
          details: <String, Object?>{
            'limitBytes': AttachmentBudget.maxWorkspaceImportBytes,
            'actualBytes': 60 * 1024 * 1024,
          },
        );
      },
    );
    // The picker reports no size it can trust, so the platform rejection is the
    // only signal the app gets.
    FileAttachmentService.setPickerForTesting(
      ({required type, required allowMultiple, allowedExtensions}) async =>
          FilePickerResult([
        PlatformFile(
          name: 'provider_only.zip',
          size: 0,
          identifier: 'content://downloads/documents/unknown-size',
        ),
      ]),
    );

    await pumpChat(tester);
    await pickFile(tester);

    expect(find.textContaining('上限 50.0 MB'), findsWidgets);
    expect(find.textContaining('无法读取所选文件'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

class _MemorySessionStorage extends SessionStorage {
  @override
  Future<void> init() async {}
}
