import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:clawchat/app.dart';
import 'package:clawchat/constants.dart';
import 'package:clawchat/layout/foldable_layout.dart';
import 'package:clawchat/l10n/app_strings.dart';
import 'package:clawchat/models/chat_models.dart';
import 'package:clawchat/models/provider_profile.dart';
import 'package:clawchat/models/remote_agent_connector.dart';
import 'package:clawchat/models/structured_result.dart';
import 'package:clawchat/providers/chat_provider.dart';
import 'package:clawchat/screens/chat_screen.dart';
import 'package:clawchat/services/llm_service.dart';
import 'package:clawchat/services/mcp_rich_surface_protocol.dart';
import 'package:clawchat/services/preferences_service.dart';
import 'package:clawchat/services/remote_agent_configuration_service.dart';
import 'package:clawchat/services/remote_agent_connector.dart';
import 'package:clawchat/services/session_storage.dart';
import 'package:clawchat/services/tools/tool_policy.dart';
import 'package:clawchat/services/tools/tool_registry.dart';
import 'package:clawchat/widgets/structured_result_card.dart';
import 'package:clawchat/widgets/mcp_rich_surface_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('only resumed lifecycle is interactive for approvals', () {
    expect(isInteractiveChatLifecycle(AppLifecycleState.resumed), isTrue);
    expect(isInteractiveChatLifecycle(AppLifecycleState.inactive), isFalse);
    expect(isInteractiveChatLifecycle(AppLifecycleState.paused), isFalse);
    expect(isInteractiveChatLifecycle(AppLifecycleState.hidden), isFalse);
    expect(isInteractiveChatLifecycle(AppLifecycleState.detached), isFalse);
    expect(isInteractiveChatLifecycle(null), isFalse);
  });

  const nativeChannel = MethodChannel(AppConstants.channelName);
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late _MemorySessionStorage storage;
  late ChatProvider provider;
  late Map<String, String> secureStorage;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PreferencesService.resetForTesting();
    storage = _MemorySessionStorage();
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

    provider = ChatProvider(storage: storage);
    await testerPumpInitGap();
  });

  tearDown(() async {
    provider.dispose();
    await testerPumpInitGap();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(nativeChannel, null);
    messenger.setMockMethodCallHandler(secureStorageChannel, null);
    PreferencesService.resetForTesting();
  });

  testWidgets('renders latest window and loads older messages on demand',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 40000);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    const totalMessages = 260;
    final session = _syntheticSession(totalMessages);
    await storage.saveSession(session);
    await provider.selectSession(session.id);

    await _pumpChatScreen(tester, provider);

    expect(find.text(_messageText(0)), findsNothing);
    expect(find.text(_messageText(79)), findsNothing);
    expect(find.text(_messageText(80)), findsOneWidget);
    expect(find.text(_messageText(259)), findsOneWidget);
    expect(find.text(AppStrings.loadOlderMessages(80)), findsOneWidget);
    expect(find.text(AppStrings.hiddenOlderMessages(80)), findsOneWidget);

    await tester.tap(find.text(AppStrings.loadOlderMessages(80)));
    await tester.pump();
    await tester.pump();

    expect(find.text(_messageText(0)), findsOneWidget);
    expect(find.text(_messageText(79)), findsOneWidget);
    expect(find.text(_messageText(80)), findsOneWidget);
    expect(find.text(_messageText(259)), findsOneWidget);
    expect(find.text(AppStrings.loadOlderMessages(80)), findsNothing);
  });

  testWidgets(
      'grouped command surface preserves actions and scrolls at compact 200 percent text',
      (tester) async {
    final session = ChatSession(
      id: 'command_surface_session',
      title: 'Command Surface Session',
      messages: [
        ChatMessage.user('hello'),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('reply')],
          timestamp: DateTime.utc(2026, 1, 1),
        ),
      ],
    );
    await storage.saveSession(session);
    await provider.selectSession(session.id);

    await _pumpChatScreenWithMedia(
      tester,
      provider,
      size: const Size(320, 620),
      textScale: 2,
    );

    await _tapRightmostMoreAction(tester);
    await tester.pumpAndSettle();

    expect(find.text('对话'), findsOneWidget);
    for (final label in [
      AppStrings.regenerate,
      AppStrings.compareMode,
      AppStrings.contextSummary,
      AppStrings.usageSummary,
      AppStrings.switchModel,
      AppStrings.sessionRemoteAgent,
      AppStrings.terminal,
      AppStrings.dashboard,
      AppStrings.systemPromptTitle,
      AppStrings.sessionMemory,
      AppStrings.promptProfiles,
      AppStrings.editSystemPrompt,
      AppStrings.settings,
    ]) {
      await tester.scrollUntilVisible(
        find.text(label),
        96,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text(label), findsWidgets);
    }

    expect(find.text(AppStrings.settings), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'command surface stays inside tabletop primary region above fold and IME',
      (tester) async {
    await provider.createSession();
    const size = Size(600, 800);
    const bottomInset = 360.0;
    const features = [
      DisplayFeature(
        bounds: Rect.fromLTWH(0, 300, 600, 20),
        type: DisplayFeatureType.fold,
        state: DisplayFeatureState.postureHalfOpened,
      ),
    ];

    await _pumpResponsiveShellWithMedia(
      tester,
      provider,
      size: size,
      textScale: 2,
      viewInsets: const EdgeInsets.only(bottom: bottomInset),
      features: features,
    );

    final layout = FoldableLayout.resolve(
      size,
      features,
      bottomInset: bottomInset,
    );
    expect(layout.primary, const Rect.fromLTWH(0, 0, 600, 300));

    await _tapRightmostMoreAction(tester);
    await tester.pumpAndSettle();

    final surface = find.byKey(const ValueKey('chat-command-surface'));
    expect(surface, findsOneWidget);
    final surfaceRect = tester.getRect(surface);
    _expectRectInside(surfaceRect, layout.primary);
    expect(surfaceRect.overlaps(layout.occlusion!), isFalse);
    expect(
      surfaceRect.overlaps(
        Rect.fromLTWH(0, size.height - bottomInset, size.width, bottomInset),
      ),
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'command surface stays above keyboard on compact flat screen at large text',
      (tester) async {
    final session = ChatSession(
      id: 'flat_ime_command_surface_session',
      title: 'Flat IME Command Surface Session',
      messages: [
        ChatMessage.user('hello'),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('reply')],
          timestamp: DateTime.utc(2026, 1, 1),
        ),
      ],
    );
    await storage.saveSession(session);
    await provider.selectSession(session.id);
    const size = Size(320, 620);
    const bottomInset = 280.0;
    final usable = Rect.fromLTWH(
      0,
      0,
      size.width,
      size.height - bottomInset,
    );

    await _pumpChatScreenWithMedia(
      tester,
      provider,
      size: size,
      textScale: 2,
      viewInsets: const EdgeInsets.only(bottom: bottomInset),
    );
    expect(tester.takeException(), isNull);

    await _tapRightmostMoreAction(tester);
    await tester.pumpAndSettle();

    final surface = find.byKey(const ValueKey('chat-command-surface'));
    expect(surface, findsOneWidget);
    final surfaceRect = tester.getRect(surface);
    _expectRectInside(surfaceRect, usable);
    expect(
      surfaceRect.overlaps(
        Rect.fromLTWH(0, usable.bottom, size.width, bottomInset),
      ),
      isFalse,
    );

    await tester.scrollUntilVisible(
      find.text(AppStrings.settings),
      96,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text(AppStrings.settings), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('command surface stays inside book primary region',
      (tester) async {
    await provider.createSession();
    const size = Size(800, 700);
    const features = [
      DisplayFeature(
        bounds: Rect.fromLTWH(390, 0, 20, 700),
        type: DisplayFeatureType.hinge,
        state: DisplayFeatureState.postureFlat,
      ),
    ];

    await _pumpResponsiveShellWithMedia(
      tester,
      provider,
      size: size,
      textScale: 2,
      features: features,
    );

    final layout = FoldableLayout.resolve(size, features);
    await tester.tap(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byTooltip(AppStrings.more),
      ),
    );
    await tester.pumpAndSettle();

    final surfaceRect =
        tester.getRect(find.byKey(const ValueKey('chat-command-surface')));
    _expectRectInside(surfaceRect, layout.primary);
    expect(surfaceRect.overlaps(layout.occlusion!), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'empty chat start surface survives compact text, fold and IME constraints',
      (tester) async {
    await provider.createSession();

    await _pumpChatScreenWithMedia(
      tester,
      provider,
      size: const Size(320, 620),
      textScale: 2,
    );
    expect(find.text('本地工作区'), findsOneWidget);
    expect(find.text('执行上下文'), findsOneWidget);
    expect(find.text('当前模型'), findsOneWidget);
    expect(find.text(AppStrings.emptyPromptSummarizeCode), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _pumpResponsiveShellWithMedia(
      tester,
      provider,
      size: const Size(800, 700),
      textScale: 2,
      features: const [
        DisplayFeature(
          bounds: Rect.fromLTWH(390, 0, 20, 700),
          type: DisplayFeatureType.hinge,
          state: DisplayFeatureState.postureFlat,
        ),
      ],
    );
    expect(find.text('本地工作区'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _pumpResponsiveShellWithMedia(
      tester,
      provider,
      size: const Size(600, 620),
      textScale: 2,
      viewInsets: const EdgeInsets.only(bottom: 280),
      features: const [
        DisplayFeature(
          bounds: Rect.fromLTWH(0, 300, 600, 20),
          type: DisplayFeatureType.fold,
          state: DisplayFeatureState.postureHalfOpened,
        ),
      ],
    );
    expect(find.text('本地工作区'), findsOneWidget);
    expect(find.byTooltip(AppStrings.send), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty chat execution context updates after remote toggle',
      (tester) async {
    provider.dispose();
    final runtime = await _configuredRemoteRuntime();
    provider = ChatProvider(
      storage: storage,
      remoteAgentRuntimeBinding: runtime,
    );
    await tester.pump(const Duration(milliseconds: 50));
    await provider.createSession();

    await _pumpChatScreenWithMedia(
      tester,
      provider,
      size: const Size(360, 700),
      textScale: 2,
    );
    expect(provider.currentSession!.messages, isEmpty);
    expect(find.text('Local · default model group'), findsNWidgets(2));
    expect(find.text('External · Remote Agent'), findsNothing);

    expect(await provider.setCurrentSessionRemoteAgentEnabled(true), isTrue);
    await tester.pump();

    expect(provider.currentSession!.messages, isEmpty);
    expect(find.text('External · Remote Agent'), findsNWidgets(2));
    expect(find.text('Local · default model group'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'structured result stays chronological and outside folds at 200 percent text',
      (tester) async {
    final session = ChatSession(
      id: 'structured_result_surface',
      title: 'Structured result surface',
      messages: [
        ChatMessage.user('Earlier prompt'),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('Model response before the result')],
          timestamp: DateTime.utc(2026, 7, 15),
        ),
        ChatMessage(
          role: 'user',
          content: [
            ToolResultContent(toolUseId: 'present-1', output: ''),
            StructuredResultContent(document: _surfaceStructuredDocument()),
          ],
          timestamp: DateTime.utc(2026, 7, 15, 0, 0, 1),
        ),
      ],
      structuredActionReceipts: [
        _surfaceStructuredReceipt(),
      ],
    );
    await storage.saveSession(session);
    await provider.selectSession(session.id);

    await _pumpChatScreenWithMedia(
      tester,
      provider,
      size: const Size(600, 800),
    );
    final card = find.byType(StructuredResultCard);
    expect(card, findsOneWidget);
    final richDisclosure = find.byType(McpRichSurfaceDisclosure);
    expect(richDisclosure, findsOneWidget);
    final richWidget = tester.widget<McpRichSurfaceDisclosure>(richDisclosure);
    expect(
      richWidget.actionRouter,
      isA<ChatProviderMcpRichSurfaceActionRouter>(),
    );
    expect(richWidget.surface.resultId, _surfaceStructuredDocument().resultId);
    expect(find.byType(McpRichSurfaceView), findsNothing);
    expect(find.text('Model response before the result'), findsOneWidget);
    expect(find.text('Imported safely'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Model response before the result')).dy,
      lessThan(tester.getTopLeft(card).dy),
    );

    await _pumpChatScreenWithMedia(
      tester,
      provider,
      size: const Size(320, 700),
      textScale: 2,
    );
    expect(card, findsOneWidget);
    expect(find.byType(McpRichSurfaceDisclosure), findsOneWidget);
    expect(find.text('Show rich view'), findsOneWidget);
    expect(find.text('Action receipt saved'), findsOneWidget);
    expect(
      find.text('Action data is unavailable.'),
      findsOneWidget,
    );
    final disabledAction =
        find.widgetWithText(OutlinedButton, 'Save to local memory');
    expect(tester.widget<OutlinedButton>(disabledAction).onPressed, isNull);
    _expectRectInside(tester.getRect(card), Offset.zero & const Size(320, 700));
    await tester.tap(find.byKey(const Key('mcp-rich-surface-toggle')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(McpRichSurfaceView), findsOneWidget);
    expect(find.byType(McpRichSurfaceUnavailableNotice), findsOneWidget);
    _expectRectInside(
      tester.getRect(find.byType(McpRichSurfaceView)),
      Offset.zero & const Size(320, 700),
    );
    expect(card, findsOneWidget);
    expect(tester.takeException(), isNull);

    const bookSize = Size(800, 700);
    const bookHinge = Rect.fromLTWH(400, 0, 20, 700);
    await _pumpResponsiveShellWithMedia(
      tester,
      provider,
      size: bookSize,
      textScale: 2,
      features: const [
        DisplayFeature(
          bounds: bookHinge,
          type: DisplayFeatureType.hinge,
          state: DisplayFeatureState.postureFlat,
        ),
      ],
    );
    final bookLayout = FoldableLayout.resolve(bookSize, const [
      DisplayFeature(
        bounds: bookHinge,
        type: DisplayFeatureType.hinge,
        state: DisplayFeatureState.postureFlat,
      ),
    ]);
    final bookCardRect = tester.getRect(card);
    _expectRectInside(bookCardRect, bookLayout.primary);
    expect(bookCardRect.overlaps(bookHinge), isFalse);
    expect(find.byType(McpRichSurfaceView), findsNothing);
    expect(find.text('Show rich view'), findsOneWidget);
    expect(card, findsOneWidget);
    expect(tester.takeException(), isNull);

    const tabletopSize = Size(600, 1000);
    const tabletopFold = Rect.fromLTWH(0, 520, 600, 20);
    const bottomInset = 400.0;
    await _pumpResponsiveShellWithMedia(
      tester,
      provider,
      size: tabletopSize,
      textScale: 2,
      viewInsets: const EdgeInsets.only(bottom: bottomInset),
      features: const [
        DisplayFeature(
          bounds: tabletopFold,
          type: DisplayFeatureType.fold,
          state: DisplayFeatureState.postureHalfOpened,
        ),
      ],
    );
    final tabletopLayout = FoldableLayout.resolve(
      tabletopSize,
      const [
        DisplayFeature(
          bounds: tabletopFold,
          type: DisplayFeatureType.fold,
          state: DisplayFeatureState.postureHalfOpened,
        ),
      ],
      bottomInset: bottomInset,
    );
    final tabletopCardRect = tester.getRect(card);
    _expectRectInside(tabletopCardRect, tabletopLayout.primary);
    expect(tabletopCardRect.overlaps(tabletopFold), isFalse);
    expect(find.byType(McpRichSurfaceView), findsNothing);
    expect(find.text('Show rich view'), findsOneWidget);
    expect(card, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows interrupted run banner and dismisses it', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final session = ChatSession(
      id: 'interrupted_banner_session',
      title: 'Interrupted Banner Session',
      messages: [ChatMessage.user('hello')],
      inFlightAgentRun: AgentRunRecoveryMarker(
        runAttemptId: 'banner-run',
        startedAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
      ),
    );
    await storage.saveSession(session);
    await provider.selectSession(session.id);

    await _pumpChatScreen(tester, provider);

    expect(find.text('上次任务被中断'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '查看'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '忽略'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '继续'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '忽略'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('上次任务被中断'), findsNothing);
    expect(
      (await storage.getSession(session.id))!.inFlightAgentRun,
      isNull,
    );
  });

  testWidgets('does not label the currently owned run as interrupted',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final started = Completer<void>();
    final release = Completer<void>();
    provider.dispose();
    PreferencesService().apiKey = 'sk-test';
    provider = ChatProvider(
      storage: storage,
      llmServiceFactory: (config, {isInBackground}) => _BlockingLlmService(
        config,
        started: started,
        release: release,
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    final session = await provider.createSession();
    final send = provider.sendMessage('normal active request');
    for (var attempt = 0; attempt < 200 && !started.isCompleted; attempt++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(started.isCompleted, isTrue);

    await _pumpChatScreen(tester, provider);

    expect(provider.isSessionSending(session.id), isTrue);
    expect((await storage.getSession(session.id))!.inFlightAgentRun, isNotNull);
    expect(provider.currentInterruptedAgentRun, isNull);
    expect(find.text('上次任务被中断'), findsNothing);

    release.complete();
    for (var attempt = 0;
        attempt < 200 && provider.isSessionSending(session.id);
        attempt++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(provider.isSessionSending(session.id), isFalse);
    await send;
    expect(find.text('上次任务被中断'), findsNothing);
    expect((await storage.getSession(session.id))!.inFlightAgentRun, isNull);

    provider.dispose();
    provider = ChatProvider(storage: storage);
    await tester.pump(const Duration(milliseconds: 50));
    await provider.selectSession(session.id);
    await _pumpChatScreen(tester, provider);
    expect(provider.currentInterruptedAgentRun, isNull);
    expect(find.text('上次任务被中断'), findsNothing);
  });

  testWidgets('shows fail-closed unknown tool recovery details',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final timestamp = DateTime.utc(2026, 1, 1);
    final session = ChatSession(
      id: 'unknown_tool_recovery_banner',
      messages: [ChatMessage.user('hello')],
      inFlightAgentRun: AgentRunRecoveryMarker(
        runAttemptId: 'run-unknown',
        startedAt: timestamp,
        updatedAt: timestamp,
        phase: AgentRunRecoveryPhase.toolInFlight,
        toolAttempts: [
          ToolAttemptRecoveryMetadata(
            operationId: 'operation-unknown',
            toolName: 'write_file',
            risk: RecoveryToolRisk.dangerous,
            lifecycle: ToolAttemptLifecycle.started,
            proposedAt: timestamp,
            updatedAt: timestamp,
            executionStartedAt: timestamp,
          ),
        ],
      ),
    );
    await storage.saveSession(session);
    await provider.selectSession(session.id);

    await _pumpChatScreen(tester, provider);

    expect(find.textContaining('结果未知'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '重新发起'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '查看'));
    await tester.pumpAndSettle();
    expect(find.text('中断恢复详情'), findsOneWidget);
    expect(find.textContaining('run-unknown'), findsOneWidget);
    expect(find.textContaining('operation-unknown'), findsOneWidget);
    expect(find.textContaining('write_file · dangerous'), findsOneWidget);
  });

  testWidgets('unknown recovery success keeps banner after reload',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    provider.dispose();
    PreferencesService().apiKey = 'sk-test';
    provider = ChatProvider(
      storage: storage,
      llmServiceFactory: (config, {isInBackground}) =>
          _ImmediateLlmService(config),
    );
    await tester.pump(const Duration(milliseconds: 50));
    final timestamp = DateTime.utc(2026, 1, 1);
    final session = ChatSession(
      id: 'unknown_success_banner',
      messages: [ChatMessage.user('original task')],
      inFlightAgentRun: AgentRunRecoveryMarker(
        runAttemptId: 'unknown-success-origin',
        startedAt: timestamp,
        updatedAt: timestamp,
        phase: AgentRunRecoveryPhase.toolInFlight,
        toolAttempts: [
          ToolAttemptRecoveryMetadata(
            operationId: 'unknown-operation',
            toolName: 'write_file',
            risk: RecoveryToolRisk.dangerous,
            lifecycle: ToolAttemptLifecycle.interruptedUnknown,
            proposedAt: timestamp,
            updatedAt: timestamp,
            executionStartedAt: timestamp,
          ),
        ],
      ),
    );
    await storage.saveSession(session);
    await provider.selectSession(session.id);

    await provider.continueInterruptedAgentRun();
    await _pumpChatScreen(tester, provider);

    expect(find.text('model recovered'), findsOneWidget);
    expect(find.text('上次任务被中断'), findsOneWidget);
    expect(find.textContaining('结果未知'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '重新发起'), findsOneWidget);

    provider.dispose();
    provider = ChatProvider(storage: storage);
    await tester.pump(const Duration(milliseconds: 50));
    await provider.selectSession(session.id);
    await _pumpChatScreen(tester, provider);

    expect(provider.currentInterruptedAgentRun, isNotNull);
    expect(find.text('model recovered'), findsOneWidget);
    expect(find.text('上次任务被中断'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '重新发起'), findsOneWidget);
  });

  testWidgets('labels recovery-origin error action as safe Continue',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final timestamp = DateTime.utc(2026, 1, 1);
    final session = ChatSession(
      id: 'recovery_error_card',
      messages: [
        ChatMessage.user('original task'),
        ChatMessage.assistantError(
          error: const AssistantErrorMetadata(
            message: 'provider unavailable',
            code: 'provider_unavailable',
            canRetry: true,
            retryAction: AssistantRetryAction.continueRecovery,
            recoveryRunAttemptId: 'recovery-error-run',
          ),
        ),
      ],
      inFlightAgentRun: AgentRunRecoveryMarker(
        runAttemptId: 'recovery-error-run',
        startedAt: timestamp,
        updatedAt: timestamp,
      ),
    );
    await storage.saveSession(session);
    await provider.selectSession(session.id);

    await _pumpChatScreen(tester, provider);

    expect(find.text(AppStrings.assistantRecoveryErrorTitle), findsOneWidget);
    expect(find.text(AppStrings.assistantRecoveryContinue), findsOneWidget);
    expect(find.text(AppStrings.retry), findsNothing);
  });

  testWidgets('fold and unfold preserve one ChatScreen and its draft state',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 700);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await provider.createSession();
    const shellKey = ValueKey('responsive-shell');

    Future<void> pump(List<DisplayFeature> features) async {
      await tester.pumpWidget(
        ChangeNotifierProvider<ChatProvider>.value(
          value: provider,
          child: MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: const Size(800, 700),
                displayFeatures: features,
                textScaler: const TextScaler.linear(2),
              ),
              child: const ResponsiveShell(key: shellKey),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    await pump(const []);
    expect(find.bySemanticsLabel('调整会话列表宽度'), findsOneWidget);
    final resizeTarget = find.byKey(const ValueKey('sidebar-resize-target'));
    final visualLine = find.byKey(const ValueKey('sidebar-resize-visual-line'));
    expect(tester.getSize(resizeTarget).width, greaterThanOrEqualTo(48));
    expect(tester.getSize(visualLine).width, 1);
    expect(
      tester.getCenter(resizeTarget).dx,
      closeTo(tester.getCenter(visualLine).dx, 0.01),
    );
    expect(find.bySemanticsLabel(AppStrings.voiceStart), findsOneWidget);
    expect(find.byTooltip(AppStrings.send), findsOneWidget);
    final composer = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.hintText == AppStrings.inputHint,
    );
    expect(composer, findsOneWidget);
    await tester.enterText(composer, 'draft survives posture');

    await pump(const [
      DisplayFeature(
        bounds: Rect.fromLTWH(390, 0, 20, 700),
        type: DisplayFeatureType.hinge,
        state: DisplayFeatureState.postureFlat,
      ),
    ]);
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(resizeTarget, findsNothing);
    expect(find.text('draft survives posture'), findsOneWidget);

    await pump(const []);
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(find.text('draft survives posture'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tabletop with IME keeps chat in the usable upper region',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 800);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await provider.createSession();

    await tester.pumpWidget(
      ChangeNotifierProvider<ChatProvider>.value(
        value: provider,
        child: const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(600, 800),
              viewInsets: EdgeInsets.only(bottom: 360),
              textScaler: TextScaler.linear(2),
              displayFeatures: [
                DisplayFeature(
                  bounds: Rect.fromLTWH(0, 300, 600, 20),
                  type: DisplayFeatureType.fold,
                  state: DisplayFeatureState.postureHalfOpened,
                ),
              ],
            ),
            child: ResponsiveShell(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(ChatScreen), findsOneWidget);
    expect(tester.getTopLeft(find.byType(ChatScreen)).dy, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'production shell keeps compare decision and composer in 300dp tabletop pane',
      (tester) async {
    provider.dispose();
    final profile = ProviderProfile.defaults().copyWith(
      id: 'compare-profile',
      apiKey: 'test-key',
      model: 'compare-model',
    );
    secureStorage['provider_profiles'] = jsonEncode([profile.toJson()]);
    SharedPreferences.setMockInitialValues({
      'active_provider_profile_id': 'compare-profile',
    });
    PreferencesService.resetForTesting();
    var requests = 0;
    provider = ChatProvider(
      storage: storage,
      llmServiceFactory: (config, {isInBackground}) =>
          _CompareCompositionLlmService(config, onRequest: () => requests++),
    );
    await tester.runAsync(() async {
      await testerPumpInitGap();
      await provider.createSession();
      await provider.sendCompare('layout prompt', ['model-a', 'model-b']);
    });
    expect(requests, 2);

    Future<void> pump(
      Size size,
      List<DisplayFeature> features, {
      double bottomInset = 0,
      double textScale = 1,
    }) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      await tester.pumpWidget(
        ChangeNotifierProvider<ChatProvider>.value(
          value: provider,
          child: MaterialApp(
            theme: ThemeData(useMaterial3: true),
            builder: (context, child) => MediaQuery(
              data: MediaQueryData(
                size: size,
                displayFeatures: features,
                viewInsets: EdgeInsets.only(bottom: bottomInset),
                textScaler: TextScaler.linear(textScale),
              ),
              child: child!,
            ),
            home: const ResponsiveShell(key: ValueKey('compare-shell')),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
    }

    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const tabletop = DisplayFeature(
      bounds: Rect.fromLTWH(0, 300, 600, 20),
      type: DisplayFeatureType.fold,
      state: DisplayFeatureState.postureHalfOpened,
    );
    await pump(const Size(600, 620), const [tabletop], textScale: 2);
    expect(
        find.byKey(const ValueKey('compact-compare-decision')), findsOneWidget);
    expect(find.text(AppStrings.useInConversation), findsOneWidget);
    expect(find.byTooltip(AppStrings.send), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.enterText(find.byType(TextField).last, 'draft survives');
    await tester.tap(find.byTooltip('下一个结果'));
    await tester.pump();
    expect(find.textContaining('2/2'), findsOneWidget);

    await pump(
      const Size(600, 620),
      const [
        DisplayFeature(
          bounds: Rect.fromLTWH(0, 300, 600, 0),
          type: DisplayFeatureType.fold,
          state: DisplayFeatureState.postureHalfOpened,
        ),
      ],
      bottomInset: 280,
      textScale: 2,
    );
    expect(find.text(AppStrings.useInConversation), findsOneWidget);
    expect(find.text('draft survives'), findsOneWidget);
    expect(find.textContaining('2/2'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await pump(
      const Size(800, 600),
      const [
        DisplayFeature(
          bounds: Rect.fromLTWH(400, 0, 0, 600),
          type: DisplayFeatureType.fold,
          state: DisplayFeatureState.postureHalfOpened,
        ),
      ],
    );
    expect(requests, 2);
    expect(find.text('draft survives'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'public foreground agent flow shows approval before one execution',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    provider.dispose();
    final profile = ProviderProfile.defaults().copyWith(
      id: 'approval-profile',
      apiKey: 'test-key',
      model: 'approval-model',
    );
    secureStorage['provider_profiles'] = jsonEncode([profile.toJson()]);
    SharedPreferences.setMockInitialValues({
      'active_provider_profile_id': 'approval-profile',
      'tool_approval_policy': PreferencesService.toolApprovalAlways,
    });
    PreferencesService.resetForTesting();
    final tool = _ApprovalCommandTool();
    var requestCount = 0;
    provider = ChatProvider(
      storage: storage,
      toolRegistry: ToolRegistry()..register(tool, risk: ToolRisk.dangerous),
      llmServiceFactory: (config, {isInBackground}) =>
          _ApprovalLlmService(config, onRequest: () => ++requestCount),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await provider.createSession();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _pumpChatScreen(tester, provider);

    late Future<void> send;
    await tester.runAsync(() async {
      send = provider.sendMessage('run harmless approval check');
      for (var attempt = 0;
          attempt < 200 && provider.pendingApproval == null;
          attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(provider.pendingApproval, isNotNull);
    });
    await tester.pump();
    await tester.pump();

    expect(
      find.text(AppStrings.toolApprovalAllowOnce),
      findsOneWidget,
      reason:
          'provider=${provider.pendingApproval?.toolName} requests=$requestCount '
          'executions=${tool.executionCount}',
    );
    expect(provider.pendingApproval, isNotNull);
    expect(find.text(AppStrings.toolApprovalTitle), findsOneWidget);
    expect(find.text(AppStrings.toolApprovalDeny), findsOneWidget);
    expect(find.text(AppStrings.toolApprovalAllowSession), findsOneWidget);
    expect(find.text(AppStrings.toolApprovalAllowOnce), findsOneWidget);
    expect(tool.executionCount, 0);

    await tester.tap(find.text(AppStrings.toolApprovalAllowOnce));
    await tester.pump();
    await tester.runAsync(() => send.timeout(const Duration(seconds: 5)));
    await tester.pump();

    expect(requestCount, 2);
    expect(tool.executionCount, 1);
    expect(
      provider.currentSession!.messages
          .expand((m) => m.toolResults)
          .single
          .output,
      'approved harmless command',
    );
  });

  testWidgets('stale approval dialog cannot decide a replacement operation',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final nativeCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeChannel, (call) async {
      nativeCalls.add(call);
      if (call.method == 'consumePendingNavigateToSession') return null;
      return true;
    });
    provider.dispose();
    final profile = ProviderProfile.defaults().copyWith(
      id: 'approval-identity-profile',
      apiKey: 'test-key',
      model: 'approval-identity-model',
    );
    secureStorage['provider_profiles'] = jsonEncode([profile.toJson()]);
    SharedPreferences.setMockInitialValues({
      'active_provider_profile_id': 'approval-identity-profile',
      'tool_approval_policy': PreferencesService.toolApprovalAlways,
    });
    PreferencesService.resetForTesting();
    final tool = _ApprovalCommandTool();
    var requestCount = 0;
    provider = ChatProvider(
      storage: storage,
      toolRegistry: ToolRegistry()..register(tool, risk: ToolRisk.dangerous),
      llmServiceFactory: (config, {isInBackground}) =>
          _SequentialApprovalLlmService(
        config,
        onRequest: () => ++requestCount,
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await provider.createSession();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _pumpChatScreen(tester, provider);

    late Future<void> send;
    await tester.runAsync(() async {
      send = provider.sendMessage('run two approval checks');
      for (var attempt = 0;
          attempt < 200 && provider.pendingApproval == null;
          attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(provider.pendingApproval, isNotNull);
    });
    await tester.pump();
    await tester.pump();
    final firstId = provider.pendingApproval!.operationId;
    final firstAllow = find.byKey(
      ValueKey('tool-approval-allow-once:$firstId'),
    );
    expect(firstAllow, findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    await tester.runAsync(() async {
      expect(
        await provider.resolveToolApprovalFromNotificationForTesting(
          sessionId: provider.currentSession!.id,
          approvalId: firstId,
          approved: true,
        ),
        isTrue,
      );
      for (var attempt = 0;
          attempt < 200 &&
              (provider.pendingApproval == null ||
                  provider.pendingApproval!.operationId == firstId);
          attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(provider.pendingApproval, isNotNull);
    });
    final secondId = provider.pendingApproval!.operationId;
    expect(secondId, isNot(firstId));
    expect(tool.executionCount, 1);
    expect(firstAllow, findsOneWidget);
    expect(
      nativeCalls.where(
        (call) =>
            call.method == 'showToolApprovalNotification' &&
            (call.arguments as Map)['approvalId'] == secondId,
      ),
      hasLength(1),
    );

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.tap(firstAllow);
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(tool.executionCount, 1);
    expect(provider.pendingApproval!.operationId, secondId);
    expect(firstAllow, findsNothing);
    final secondAllow = find.byKey(
      ValueKey('tool-approval-allow-once:$secondId'),
    );
    expect(secondAllow, findsOneWidget);
    expect(
      nativeCalls.where(
        (call) =>
            call.method == 'clearToolApprovalNotification' &&
            (call.arguments as Map)['approvalId'] == secondId,
      ),
      hasLength(1),
    );

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    await tester.runAsync(() async {
      expect(
        await provider.resolveToolApprovalFromNotificationForTesting(
          sessionId: provider.currentSession!.id,
          approvalId: secondId,
          approved: true,
        ),
        isTrue,
      );
      await send.timeout(const Duration(seconds: 5));
    });
    expect(secondAllow, findsOneWidget);
    expect(provider.pendingApproval, isNull);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(requestCount, 2);
    expect(tool.executionCount, 2);
    expect(
      tool.executedCommands,
      ['printf approval-a', 'printf approval-b'],
    );
    expect(secondAllow, findsNothing);
    expect(provider.pendingApproval, isNull);
  });
}

Future<void> testerPumpInitGap() {
  return Future<void>.delayed(const Duration(milliseconds: 20));
}

Future<void> _pumpChatScreen(WidgetTester tester, ChatProvider provider) async {
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

Future<void> _pumpChatScreenWithMedia(
  WidgetTester tester,
  ChatProvider provider, {
  required Size size,
  double textScale = 1,
  List<DisplayFeature> features = const [],
  EdgeInsets viewInsets = EdgeInsets.zero,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    ChangeNotifierProvider<ChatProvider>.value(
      value: provider,
      child: MaterialApp(
        theme: ThemeData(useMaterial3: true),
        builder: (context, child) => MediaQuery(
          data: MediaQueryData(
            size: size,
            displayFeatures: features,
            viewInsets: viewInsets,
            textScaler: TextScaler.linear(textScale),
          ),
          child: child!,
        ),
        home: const ChatScreen(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _pumpResponsiveShellWithMedia(
  WidgetTester tester,
  ChatProvider provider, {
  required Size size,
  double textScale = 1,
  List<DisplayFeature> features = const [],
  EdgeInsets viewInsets = EdgeInsets.zero,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    ChangeNotifierProvider<ChatProvider>.value(
      value: provider,
      child: MaterialApp(
        theme: ThemeData(useMaterial3: true),
        builder: (context, child) => MediaQuery(
          data: MediaQueryData(
            size: size,
            displayFeatures: features,
            viewInsets: viewInsets,
            textScaler: TextScaler.linear(textScale),
          ),
          child: child!,
        ),
        home: const ResponsiveShell(key: ValueKey('test-responsive-shell')),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void _expectRectInside(Rect actual, Rect expected) {
  expect(actual.left, greaterThanOrEqualTo(expected.left));
  expect(actual.top, greaterThanOrEqualTo(expected.top));
  expect(actual.right, lessThanOrEqualTo(expected.right));
  expect(actual.bottom, lessThanOrEqualTo(expected.bottom));
}

Future<void> _tapRightmostMoreAction(WidgetTester tester) async {
  final candidates = find.byTooltip(AppStrings.more).evaluate().toList();
  expect(candidates, isNotEmpty);
  Element? rightmost;
  var rightmostX = double.negativeInfinity;
  for (final candidate in candidates) {
    final center = tester.getCenter(find.byWidget(candidate.widget));
    if (center.dx > rightmostX) {
      rightmost = candidate;
      rightmostX = center.dx;
    }
  }
  await tester.tap(find.byWidget(rightmost!.widget));
}

Future<RemoteAgentRuntimeBinding> _configuredRemoteRuntime() async {
  final configuration = RemoteAgentConfigurationService(
    metadataStorage: _RemoteMemoryStorage(),
    secretStorage: _RemoteMemoryStorage(),
  );
  await configuration.saveConfiguration(
    kind: RemoteAgentConnectorKind.openClawGateway,
    connectorId: 'primary_remote',
    displayName: 'Remote Agent',
    baseUrl: 'https://agent.example/v1/chat/completions',
    remoteAgentId: 'agent_1',
    credential: 'secure-value',
  );
  await configuration.grantConsentAndEnable(
    acceptedAt: DateTime.utc(2026, 7, 11),
  );
  return RemoteAgentRuntimeBinding(
    configuration: configuration,
    connector: const _NoopRemoteConnector(),
  );
}

ChatSession _syntheticSession(int totalMessages) {
  return ChatSession(
    id: 'render_window_session',
    title: 'Render Window Session',
    messages: [
      for (var index = 0; index < totalMessages; index++)
        ChatMessage(
          role: index.isEven ? 'user' : 'assistant',
          content: [TextContent(_messageText(index))],
          timestamp: DateTime.utc(2026, 1, 1).add(Duration(seconds: index)),
        ),
    ],
  );
}

String _messageText(int index) => 'synthetic render window message $index';

StructuredResultDocument _surfaceStructuredDocument() =>
    const StructuredResultDocument(
      schemaVersion: 1,
      resultId: '00000000-0000-4000-8000-000000000010',
      blocks: [
        StructuredNoticeBlock(
          level: StructuredNoticeLevel.info,
          text: 'Imported safely',
        ),
        StructuredActionListBlock(
          actions: [
            StructuredResultAction(
              actionId: 'save-1',
              label: 'Save to local memory',
              kind: 'save_to_memory',
              payload: {'fact': 'Only local, consented data may be saved.'},
            ),
          ],
        ),
      ],
    );

StructuredActionReceipt _surfaceStructuredReceipt() => StructuredActionReceipt(
      schemaVersion: 1,
      receiptId: '00000000-0000-4000-8000-000000000011',
      operationId: '00000000-0000-4000-8000-000000000012',
      sourceKind: 'structured_result',
      resultId: '00000000-0000-4000-8000-000000000010',
      actionId: 'save-1',
      actionKind: 'save_to_memory',
      toolName: 'memory_write',
      canonicalInputDigest: structuredActionInputDigest(
          (_surfaceStructuredDocument().blocks[1] as StructuredActionListBlock)
              .actions
              .single),
      createdAt: DateTime.utc(2026, 7, 15),
      updatedAt: DateTime.utc(2026, 7, 15, 0, 0, 1),
      hardDeny: 'not_denied',
      skillDeny: 'not_applicable',
      approval: 'approved',
      state: 'resultPersisted',
      outcome: 'success',
      outcomeKnown: true,
      safeSummary: 'Saved to local memory.',
    );

final class _RemoteMemoryStorage
    implements RemoteAgentMetadataStorage, RemoteAgentSecretStorage {
  final Map<String, String> _values = {};

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }
}

final class _NoopRemoteConnector implements RemoteAgentConnector {
  const _NoopRemoteConnector();

  @override
  Stream<RemoteAgentEvent> send(
    RemoteAgentConnectorConfig config,
    RemoteAgentConsent? consent,
    RemoteAgentRequest request, {
    RemoteAgentCancellation? cancellation,
    bool Function()? authorizationGuard,
  }) {
    return const Stream<RemoteAgentEvent>.empty();
  }
}

class _ApprovalLlmService extends LlmService {
  _ApprovalLlmService(super.config, {required this.onRequest});

  final int Function() onRequest;

  @override
  Stream<StreamEvent> chatStream({
    required String system,
    required List<Map<String, dynamic>> messages,
    required List<ToolDefinition> tools,
  }) async* {
    final request = onRequest();
    if (request == 1) {
      yield StreamDone(const LlmResponse(
        stopReason: 'tool_use',
        content: [
          ContentBlock(
            type: 'tool_use',
            toolUseId: 'approval-call',
            toolName: 'bash',
            toolInput: {'command': 'printf harmless-approval'},
          ),
        ],
      ));
      return;
    }
    yield StreamDone(const LlmResponse(
      stopReason: 'end_turn',
      content: [ContentBlock(type: 'text', text: 'approval complete')],
    ));
  }
}

class _SequentialApprovalLlmService extends LlmService {
  _SequentialApprovalLlmService(super.config, {required this.onRequest});

  final int Function() onRequest;

  @override
  Stream<StreamEvent> chatStream({
    required String system,
    required List<Map<String, dynamic>> messages,
    required List<ToolDefinition> tools,
  }) async* {
    final request = onRequest();
    if (request == 1) {
      yield StreamDone(const LlmResponse(
        stopReason: 'tool_use',
        content: [
          ContentBlock(
            type: 'tool_use',
            toolUseId: 'approval-a',
            toolName: 'bash',
            toolInput: {'command': 'printf approval-a'},
          ),
          ContentBlock(
            type: 'tool_use',
            toolUseId: 'approval-b',
            toolName: 'bash',
            toolInput: {'command': 'printf approval-b'},
          ),
        ],
      ));
      return;
    }
    yield StreamDone(const LlmResponse(
      stopReason: 'end_turn',
      content: [ContentBlock(type: 'text', text: 'approvals complete')],
    ));
  }
}

class _ApprovalCommandTool extends Tool {
  int executionCount = 0;
  final List<String> executedCommands = [];

  @override
  String get name => 'bash';

  @override
  String get description => 'Execute a harmless command';

  @override
  Map<String, dynamic> get inputSchema => const {
        'type': 'object',
        'properties': {
          'command': {'type': 'string'},
        },
        'required': ['command'],
      };

  @override
  Future<String> execute(Map<String, dynamic> input) async {
    executionCount++;
    executedCommands.add(input['command']?.toString() ?? '');
    return 'approved harmless command';
  }
}

class _CompareCompositionLlmService extends LlmService {
  _CompareCompositionLlmService(super.config, {required this.onRequest});

  final VoidCallback onRequest;

  @override
  Future<LlmResponse> chat({
    required String system,
    required List<Map<String, dynamic>> messages,
    List<ToolDefinition>? tools,
  }) async {
    onRequest();
    return LlmResponse(
      stopReason: 'end_turn',
      content: [ContentBlock(type: 'text', text: '${config.model} result')],
    );
  }
}

class _MemorySessionStorage extends SessionStorage {
  final Map<String, ChatSession> _sessions = {};

  @override
  Future<void> init() async {}

  @override
  Future<List<SessionSummary>> getSessionsSummary() async {
    return _sessions.values
        .map(
          (session) => SessionSummary(
            id: session.id,
            title: session.title,
            createdAt: session.createdAt,
            updatedAt: session.updatedAt,
            folder: session.folder,
          ),
        )
        .toList();
  }

  @override
  Future<ChatSession?> getSession(String id) async => _sessions[id];

  @override
  Future<void> saveSession(
    ChatSession session, {
    int? expectedGeneration,
    SessionCommitGuard? commitGuard,
  }) async {
    _sessions[session.id] = ChatSession.fromJson(
      jsonDecode(jsonEncode(session.toJson())) as Map<String, dynamic>,
    );
  }

  @override
  Future<void> deleteSession(String id) async {
    _sessions.remove(id);
  }

  @override
  Future<ChatSession?> forkSession(
      String sessionId, int upToMessageIndex) async {
    final source = _sessions[sessionId];
    if (source == null ||
        upToMessageIndex < 0 ||
        upToMessageIndex >= source.messages.length) {
      return null;
    }
    final fork = ChatSession(
      id: 'fork_${_sessions.length}',
      title: AppStrings.forkedFromTitle(source.title),
      messages: source.messages.take(upToMessageIndex + 1).toList(),
    );
    await saveSession(fork);
    return fork;
  }

  @override
  Future<void> clearAll() async {
    _sessions.clear();
  }
}

class _BlockingLlmService extends LlmService {
  final Completer<void> started;
  final Completer<void> release;

  _BlockingLlmService(
    super.config, {
    required this.started,
    required this.release,
  });

  @override
  Stream<StreamEvent> chatStream({
    required String system,
    required List<Map<String, dynamic>> messages,
    required List<ToolDefinition> tools,
  }) async* {
    if (!started.isCompleted) started.complete();
    await release.future;
    yield StreamDone(const LlmResponse(
      stopReason: 'end_turn',
      content: [ContentBlock(type: 'text', text: 'completed')],
    ));
  }
}

class _ImmediateLlmService extends LlmService {
  _ImmediateLlmService(super.config);

  @override
  Stream<StreamEvent> chatStream({
    required String system,
    required List<Map<String, dynamic>> messages,
    required List<ToolDefinition> tools,
  }) async* {
    yield StreamDone(const LlmResponse(
      stopReason: 'end_turn',
      content: [ContentBlock(type: 'text', text: 'model recovered')],
    ));
  }
}
