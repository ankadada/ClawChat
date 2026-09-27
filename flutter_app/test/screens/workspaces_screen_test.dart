import 'package:clawchat/constants.dart';
import 'package:clawchat/l10n/app_strings.dart';
import 'package:clawchat/models/workspace.dart';
import 'package:clawchat/providers/chat_provider.dart';
import 'package:clawchat/screens/settings_screen.dart';
import 'package:clawchat/screens/workspaces_screen.dart';
import 'package:clawchat/services/preferences_service.dart';
import 'package:clawchat/services/session_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const native = MethodChannel(AppConstants.channelName);
  const secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late ChatProvider provider;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PreferencesService.resetForTesting();
    provider = ChatProvider(storage: _NoopSessionStorage());
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
    provider.dispose();
    messenger.setMockMethodCallHandler(native, null);
    messenger.setMockMethodCallHandler(secure, null);
    PreferencesService.resetForTesting();
  });

  Future<void> pumpScreen(
    WidgetTester tester, {
    Size? size,
    double textScale = 1,
    EdgeInsets? viewInsets,
    Widget? home,
  }) async {
    // Touch one workspace API so preferences (and the persisted workspace
    // list) are initialized without changing which workspace is active.
    await provider.setActiveWorkspace(provider.activeWorkspace.id);
    await tester.pumpWidget(
      ChangeNotifierProvider<ChatProvider>.value(
        value: provider,
        child: MaterialApp(
          // The builder wraps the Navigator, so routes pushed from this
          // screen (the name dialog) inherit the size, text scale and
          // keyboard insets the test wants.
          builder: size == null && viewInsets == null
              ? null
              : (context, child) {
                  final base = MediaQuery.of(context);
                  return MediaQuery(
                    data: base.copyWith(
                      size: size ?? base.size,
                      viewInsets: viewInsets ?? base.viewInsets,
                      textScaler: TextScaler.linear(textScale),
                    ),
                    child: child!,
                  );
                },
          home: home ?? const WorkspacesScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder rowFor(String id) => find.byKey(ValueKey('workspace-row-$id'));

  testWidgets('lists the current workspace with its scope', (tester) async {
    await pumpScreen(tester);

    expect(provider.workspaces, hasLength(1));
    expect(rowFor(WorkspaceMetadata.defaultWorkspaceId), findsOneWidget);
    expect(find.textContaining(AppStrings.workspaceActive), findsWidgets);
    expect(find.textContaining('/root/workspace'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('creating validates the name, switches, and reports it',
      (tester) async {
    await pumpScreen(tester);

    await tester.tap(
        find.widgetWithText(FloatingActionButton, AppStrings.workspaceCreate));
    await tester.pumpAndSettle();

    // An empty name is refused with a visible reason.
    await tester
        .tap(find.widgetWithText(FilledButton, AppStrings.workspaceCreate));
    await tester.pumpAndSettle();
    expect(find.text(AppStrings.workspaceNameRequired), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Docs');
    await tester
        .tap(find.widgetWithText(FilledButton, AppStrings.workspaceCreate));
    await tester.pumpAndSettle();

    expect(find.textContaining('已创建「Docs」'), findsOneWidget);
    expect(provider.activeWorkspace.name, 'Docs');
    expect(rowFor(provider.activeWorkspace.id), findsOneWidget);
  });

  testWidgets('switching moves the active marker and says what it affects',
      (tester) async {
    await provider.createWorkspace(name: 'Docs');
    await pumpScreen(tester);

    expect(provider.activeWorkspace.name, 'Docs');
    await tester.tap(rowFor(WorkspaceMetadata.defaultWorkspaceId));
    await tester.pumpAndSettle();

    expect(provider.activeWorkspace.id, WorkspaceMetadata.defaultWorkspaceId);
    expect(find.textContaining('已切换到「工作区」'), findsOneWidget);
    expect(find.textContaining('已有会话保留自己的归属'), findsWidgets);
  });

  testWidgets('renaming validates and reports the result', (tester) async {
    await provider.createWorkspace(name: 'Docs');
    await pumpScreen(tester);

    await tester.tap(
      find.descendant(
          of: rowFor(provider.activeWorkspace.id),
          matching: find.byIcon(Icons.more_vert)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(AppStrings.workspaceRename));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.widgetWithText(FilledButton, AppStrings.save));
    await tester.pumpAndSettle();
    expect(find.text(AppStrings.workspaceNameRequired), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Handbuch');
    await tester.tap(find.widgetWithText(FilledButton, AppStrings.save));
    await tester.pumpAndSettle();

    expect(find.textContaining('已重命名为「Handbuch」'), findsOneWidget);
    expect(provider.activeWorkspace.name, 'Handbuch');
  });

  testWidgets('the default workspace offers no delete, others do',
      (tester) async {
    await provider.createWorkspace(name: 'Docs');
    await pumpScreen(tester);

    // The default workspace cannot be deleted.
    await tester.tap(
      find.descendant(
        of: rowFor(WorkspaceMetadata.defaultWorkspaceId),
        matching: find.byIcon(Icons.more_vert),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(AppStrings.workspaceDelete), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    // A user workspace can, with a confirmation that names the scope.
    final docsId = provider.activeWorkspace.id;
    await tester.tap(
      find.descendant(
          of: rowFor(docsId), matching: find.byIcon(Icons.more_vert)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(AppStrings.workspaceDelete));
    await tester.pumpAndSettle();
    expect(find.textContaining('工作区目录和其中的文件不会被删除'), findsOneWidget);

    await tester
        .tap(find.widgetWithText(FilledButton, AppStrings.workspaceDelete));
    await tester.pumpAndSettle();

    expect(find.textContaining('已删除工作区「Docs」'), findsOneWidget);
    expect(provider.workspaces, hasLength(1));
    // Deleting the active workspace falls back to the default one.
    expect(provider.activeWorkspace.id, WorkspaceMetadata.defaultWorkspaceId);
  });

  testWidgets('the settings entry opens workspace management', (tester) async {
    await pumpScreen(
      tester,
      home: const SettingsScreen(
        initialDestination: SettingsDestination.agentTools,
      ),
    );

    final entry = find.byKey(const ValueKey('settings-workspaces-entry'));
    await tester.scrollUntilVisible(
      entry,
      320,
      scrollable: find.byWidget(
        tester
            .widgetList<Scrollable>(find.byType(Scrollable))
            .where((s) => s.axisDirection == AxisDirection.down)
            .last,
      ),
    );
    await tester.ensureVisible(entry);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();

    expect(find.byType(WorkspacesScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the name dialog is tappable in landscape with a tall keyboard',
      (tester) async {
    // The device case: 800x360 landscape with the IME open. The route must
    // lay out against the real view insets the platform reports.
    const size = Size(800, 360);
    const keyboard = EdgeInsets.only(bottom: 240);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final semantics = tester.ensureSemantics();

    await pumpScreen(tester, size: size, viewInsets: keyboard);
    await tester.tap(
      find.widgetWithText(FloatingActionButton, AppStrings.workspaceCreate),
    );
    await tester.pumpAndSettle();

    final keyboardTop = size.height - keyboard.bottom;
    final field = find.byKey(const ValueKey('workspace-name-field'));
    expect(field, findsOneWidget);
    final fieldRect = tester.getRect(field);
    final fieldBox = tester.renderObject<RenderBox>(field);
    // The device report was a 10dp strip at the very bottom: the real render
    // box must be tall enough to type in, and live in the upper area of the
    // window, not squeezed against the keyboard edge.
    expect(fieldBox.size.height, greaterThanOrEqualTo(40));
    expect(fieldRect.top, lessThan(280));
    expect(fieldRect.bottom, lessThanOrEqualTo(keyboardTop + 8));

    final confirm = find.byKey(const ValueKey('workspace-name-confirm'));
    final confirmRect = tester.getRect(confirm);
    expect(confirmRect.width, greaterThan(0));
    expect(confirmRect.height, greaterThan(0));
    expect(confirmRect.bottom, lessThanOrEqualTo(keyboardTop));

    // Everything is in the semantics tree and the field really is a text
    // field, not a decoratively laid out one.
    expect(
      tester.getSemantics(find.byType(EditableText)).hasFlag(
            SemanticsFlag.isTextField,
          ),
      isTrue,
    );
    expect(tester.getSemantics(confirm).rect.height, greaterThan(0));

    // The confirm button works by tapping: submitting never depends on Enter.
    await tester.enterText(field, 'Landscape Docs');
    expect(find.text('Landscape Docs'), findsOneWidget);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(provider.activeWorkspace.name, 'Landscape Docs');
    semantics.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets('renaming is tappable in landscape with the keyboard open',
      (tester) async {
    await provider.createWorkspace(name: 'Docs');
    const size = Size(800, 360);
    const keyboard = EdgeInsets.only(bottom: 240);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    // Open the rename page first, then let the IME appear: the order a device
    // sees, and it keeps the list rows reachable for the menu tap.
    await pumpScreen(tester, size: size);
    await tester.tap(
      find.descendant(
        of: rowFor(provider.activeWorkspace.id),
        matching: find.byIcon(Icons.more_vert),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(AppStrings.workspaceRename));
    await tester.pumpAndSettle();

    final field = find.byKey(const ValueKey('workspace-name-field'));
    expect(field, findsOneWidget);
    // The keyboard now covers the bottom of the window; the page must still
    // keep the field and the confirm action on screen.
    await pumpScreen(tester, size: size, viewInsets: keyboard);
    await tester.pumpAndSettle();
    final keyboardTop = size.height - keyboard.bottom;
    final fieldRect = tester.getRect(field);
    expect(
      tester.renderObject<RenderBox>(field).size.height,
      greaterThanOrEqualTo(40),
    );
    expect(fieldRect.top, lessThan(280));
    expect(fieldRect.bottom, lessThanOrEqualTo(keyboardTop + 8));
    expect(
        tester
            .getRect(find.byKey(const ValueKey('workspace-name-confirm')))
            .height,
        greaterThan(0));

    await tester.enterText(field, 'Handbuch');
    await tester.tap(find.byKey(const ValueKey('workspace-name-confirm')));
    await tester.pumpAndSettle();

    expect(provider.activeWorkspace.name, 'Handbuch');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the dialog stays usable at 360dp, 200 percent text, keyboard',
      (tester) async {
    const size = Size(360, 800);
    const keyboard = EdgeInsets.only(bottom: 360);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await pumpScreen(
      tester,
      size: size,
      textScale: 2,
      viewInsets: keyboard,
    );
    await tester.tap(
      find.widgetWithText(FloatingActionButton, AppStrings.workspaceCreate),
    );
    await tester.pumpAndSettle();

    final field = find.byKey(const ValueKey('workspace-name-field'));
    final confirm = find.byKey(const ValueKey('workspace-name-confirm'));
    expect(field, findsOneWidget);
    expect(confirm, findsOneWidget);
    expect(
      tester.renderObject<RenderBox>(field).size.height,
      greaterThanOrEqualTo(40),
    );
    expect(tester.getRect(confirm).height, greaterThan(0));

    await tester.enterText(field, 'Docs');
    await tester.tap(confirm);
    await tester.pumpAndSettle();

    expect(provider.activeWorkspace.name, 'Docs');
    expect(tester.takeException(), isNull);
  });

  testWidgets('stays usable at 320dp and 200 percent text', (tester) async {
    await provider.createWorkspace(name: 'Ein sehr langer Arbeitsbereichsname');
    await pumpScreen(tester, size: const Size(320, 720), textScale: 2);

    expect(rowFor(provider.activeWorkspace.id), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

final class _NoopSessionStorage extends SessionStorage {
  @override
  Future<void> init() async {}

  @override
  Future<List<SessionSummary>> getSessionsSummary() async => const [];
}
