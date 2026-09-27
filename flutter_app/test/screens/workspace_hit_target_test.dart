import 'package:clawchat/constants.dart';
import 'package:clawchat/l10n/app_strings.dart';
import 'package:clawchat/providers/chat_provider.dart';
import 'package:clawchat/screens/chat_screen.dart';
import 'package:clawchat/screens/workspaces_screen.dart';
import 'package:clawchat/services/preferences_service.dart';
import 'package:clawchat/services/session_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Hit-target regressions for the two v2.16 P0 device reports:
/// 1. the chat workspace chip must open the workspaces page from any point of
///    its visible (and semantic) area, including wide landscape toolbars;
/// 2. the full-screen workspace naming page must accept a cancel tap across its
///    whole target, not only on the painted label.
///
/// The layout regressions that must not come back are pinned alongside them:
/// keyboard insets, 320dp width and 200 percent text.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const nativeChannel = MethodChannel(AppConstants.channelName);
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late ChatProvider provider;
  late Map<String, String> secureStorage;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PreferencesService.resetForTesting();
    secureStorage = {};

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(nativeChannel, (call) async {
      switch (call.method) {
        case 'consumePendingNavigateToSession':
          return null;
        case 'runInProot':
          return '';
        case 'stopRecording':
          return '';
        case 'getArch':
          return 'arm64-v8a';
        case 'getBootstrapStatus':
          return <String, Object?>{'rootfsExists': true};
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

    provider = ChatProvider(storage: _NoopSessionStorage());
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });

  tearDown(() async {
    provider.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(nativeChannel, null);
    messenger.setMockMethodCallHandler(secureStorageChannel, null);
    PreferencesService.resetForTesting();
  });

  void useWindow(
    WidgetTester tester, {
    required Size size,
    double textScale = 1,
    EdgeInsets viewInsets = EdgeInsets.zero,
  }) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Widget mediaApp({
    required Size size,
    double textScale = 1,
    EdgeInsets viewInsets = EdgeInsets.zero,
    required Widget home,
  }) =>
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        builder: (context, child) => MediaQuery(
          data: MediaQueryData(
            size: size,
            viewInsets: viewInsets,
            textScaler: TextScaler.linear(textScale),
          ),
          child: child!,
        ),
        home: home,
      );

  Future<void> pumpChat(
    WidgetTester tester, {
    required Size size,
    double textScale = 1,
    EdgeInsets viewInsets = EdgeInsets.zero,
  }) async {
    useWindow(tester, size: size, textScale: textScale, viewInsets: viewInsets);
    await tester.pumpWidget(
      ChangeNotifierProvider<ChatProvider>.value(
        value: provider,
        child: mediaApp(
          size: size,
          textScale: textScale,
          viewInsets: viewInsets,
          home: const ChatScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> pumpWorkspaces(
    WidgetTester tester, {
    required Size size,
    double textScale = 1,
    EdgeInsets viewInsets = EdgeInsets.zero,
  }) async {
    useWindow(tester, size: size, textScale: textScale, viewInsets: viewInsets);
    await tester.pumpWidget(
      ChangeNotifierProvider<ChatProvider>.value(
        value: provider,
        child: mediaApp(
          size: size,
          textScale: textScale,
          viewInsets: viewInsets,
          home: const WorkspacesScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder chip() => find.byKey(const ValueKey('chat-workspace-chip'));

  /// Points across the chip: center, the four edge midpoints and the corners,
  /// each inset by one pixel so the tap lands inside the box.
  List<Offset> samplePoints(Rect rect) => [
        rect.center,
        Offset(rect.left + 1, rect.center.dy),
        Offset(rect.right - 1, rect.center.dy),
        Offset(rect.center.dx, rect.top + 1),
        Offset(rect.center.dx, rect.bottom - 1),
        rect.topLeft + const Offset(1, 1),
        rect.bottomRight - const Offset(1, 1),
      ];

  Future<void> expectChipOpensWorkspacesAt(
    WidgetTester tester,
    Offset point,
    String reason,
  ) async {
    expect(find.byType(WorkspacesScreen), findsNothing);
    await tester.tapAt(point);
    await tester.pumpAndSettle();
    expect(find.byType(WorkspacesScreen), findsOneWidget, reason: reason);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(WorkspacesScreen), findsNothing);
  }

  testWidgets('wide landscape chip opens workspaces from its whole area',
      (tester) async {
    await provider.setActiveWorkspace(provider.activeWorkspace.id);
    await provider.createWorkspace(name: 'Docs');
    await pumpChat(tester, size: const Size(800, 360));
    await tester.pumpAndSettle();

    expect(chip(), findsOneWidget);
    expect(
      find.descendant(of: chip(), matching: find.text('Docs')),
      findsOneWidget,
    );
    final rect = tester.getRect(chip());
    // The control is a real touch target, not just the 24dp pill: the whole
    // visible area inside the toolbar accepts the tap.
    expect(rect.width, greaterThanOrEqualTo(48),
        reason: 'chip target width $rect');
    expect(rect.height, greaterThanOrEqualTo(48),
        reason: 'chip target height $rect');
    for (final point in samplePoints(rect)) {
      await expectChipOpensWorkspacesAt(
        tester,
        point,
        'chip tap at $point must open workspaces (chip rect $rect)',
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide landscape chip carries label and tap action together',
      (tester) async {
    await provider.setActiveWorkspace(provider.activeWorkspace.id);
    await provider.createWorkspace(name: 'Docs');
    await pumpChat(tester, size: const Size(800, 360));
    await tester.pumpAndSettle();

    final handle = tester.ensureSemantics();
    final workspaceNode = find.semantics.byLabel(RegExp('当前工作区：Docs'));
    expect(workspaceNode.evaluate(), hasLength(1));
    final node = workspaceNode.evaluate().single;
    expect(node.label, contains('Docs'));
    // The node a screen reader focuses is the one that activates the page.
    expect(
      node.getSemanticsData().hasAction(SemanticsAction.tap),
      isTrue,
      reason: 'semantics node for the chip must expose the tap action',
    );
    expect(node.rect.width, greaterThanOrEqualTo(48));
    expect(node.rect.height, greaterThanOrEqualTo(48));
    // Screen readers activate the action, so it must really navigate.
    tester.semantics.tap(workspaceNode);
    await tester.pumpAndSettle();
    expect(find.byType(WorkspacesScreen), findsOneWidget);
    handle.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact 320dp chip at 200 percent text still opens workspaces',
      (tester) async {
    await provider.setActiveWorkspace(provider.activeWorkspace.id);
    await provider.createWorkspace(name: 'Docs');
    await pumpChat(
      tester,
      size: const Size(320, 720),
      textScale: 2,
    );
    await tester.pumpAndSettle();

    expect(chip(), findsOneWidget);
    final rect = tester.getRect(chip());
    // The compact chip keeps a 48dp target at 320dp and 200 percent text.
    expect(rect.width, greaterThanOrEqualTo(48),
        reason: 'compact chip target width $rect');
    expect(rect.height, greaterThanOrEqualTo(48),
        reason: 'compact chip target height $rect');
    await expectChipOpensWorkspacesAt(
      tester,
      Offset(rect.right - 1, rect.bottom - 1),
      'compact chip corner tap at $rect must open workspaces',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('landscape chip stays tappable with the keyboard open',
      (tester) async {
    await provider.setActiveWorkspace(provider.activeWorkspace.id);
    await provider.createWorkspace(name: 'Docs');
    const size = Size(800, 360);
    const keyboard = EdgeInsets.only(bottom: 200);
    await pumpChat(tester, size: size, viewInsets: keyboard);
    await tester.pumpAndSettle();

    final rect = tester.getRect(chip());
    expect(rect.bottom, lessThanOrEqualTo(size.height - keyboard.bottom));
    await expectChipOpensWorkspacesAt(
      tester,
      Offset(rect.left + 1, rect.top + 1),
      'chip corner tap at $rect must open workspaces with the IME open',
    );
    // The composer stays in the body instead of overflowing it, and its own
    // rows scroll inside the clamped height.
    final field = find.byType(TextField);
    expect(field, findsOneWidget);
    final fieldRect = tester.getRect(field);
    expect(fieldRect.height, greaterThan(0));
    expect(
        fieldRect.bottom, lessThanOrEqualTo(size.height - keyboard.bottom + 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('naming page cancel target covers the whole app bar slot',
      (tester) async {
    await provider.setActiveWorkspace(provider.activeWorkspace.id);
    const size = Size(800, 360);
    const keyboard = EdgeInsets.only(bottom: 240);
    await pumpWorkspaces(tester, size: size, viewInsets: keyboard);

    await tester.tap(
      find.widgetWithText(FloatingActionButton, AppStrings.workspaceCreate),
    );
    await tester.pumpAndSettle();

    final cancel = find.byKey(const ValueKey('workspace-name-cancel'));
    expect(cancel, findsOneWidget);
    final rect = tester.getRect(cancel);
    // A real 48dp-class target, not just the painted label.
    expect(rect.width, greaterThanOrEqualTo(48));
    expect(rect.height, greaterThanOrEqualTo(48));

    final handle = tester.ensureSemantics();
    final node = tester.getSemantics(cancel);
    expect(node.label, contains(AppStrings.cancel));
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    expect(node.rect.width, greaterThanOrEqualTo(48));
    expect(node.rect.height, greaterThanOrEqualTo(48));
    handle.dispose();

    // Tap the far corner: outside the painted text, inside the target.
    await tester.tapAt(Offset(rect.right - 2, rect.bottom - 2));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('workspace-name-field')), findsNothing);
    expect(provider.workspaces, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'naming page cancel works at 320dp, 200 percent text, keyboard open',
      (tester) async {
    await provider.setActiveWorkspace(provider.activeWorkspace.id);
    const size = Size(320, 720);
    const keyboard = EdgeInsets.only(bottom: 320);
    await pumpWorkspaces(
      tester,
      size: size,
      textScale: 2,
      viewInsets: keyboard,
    );

    await tester.tap(
      find.widgetWithText(FloatingActionButton, AppStrings.workspaceCreate),
    );
    await tester.pumpAndSettle();

    final cancel = find.byKey(const ValueKey('workspace-name-cancel'));
    final field = find.byKey(const ValueKey('workspace-name-field'));
    expect(cancel, findsOneWidget);
    expect(field, findsOneWidget);

    final rect = tester.getRect(cancel);
    expect(rect.width, greaterThanOrEqualTo(48));
    expect(rect.height, greaterThanOrEqualTo(48));
    // The label is inside the target: at 200 percent text a fixed 56dp slot
    // used to squeeze the painted text outside its own tap box.
    final label = find.descendant(
      of: cancel,
      matching: find.text(AppStrings.cancel),
    );
    final labelRect = tester.getRect(label);
    expect(labelRect.left, greaterThanOrEqualTo(rect.left));
    expect(labelRect.right, lessThanOrEqualTo(rect.right));
    expect(labelRect.top, greaterThanOrEqualTo(rect.top));
    expect(labelRect.bottom, lessThanOrEqualTo(rect.bottom));

    await tester.tapAt(Offset(rect.right - 2, rect.bottom - 2));
    await tester.pumpAndSettle();
    expect(field, findsNothing);
    expect(provider.workspaces, hasLength(1));
    expect(tester.takeException(), isNull);
  });
}

final class _NoopSessionStorage extends SessionStorage {
  @override
  Future<void> init() async {}

  @override
  Future<List<SessionSummary>> getSessionsSummary() async => const [];
}
