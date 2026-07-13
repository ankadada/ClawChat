import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:clawchat/app.dart';
import 'package:clawchat/constants.dart';
import 'package:clawchat/l10n/app_strings.dart';
import 'package:clawchat/models/chat_models.dart';
import 'package:clawchat/models/provider_profile.dart';
import 'package:clawchat/providers/chat_provider.dart';
import 'package:clawchat/screens/chat_screen.dart';
import 'package:clawchat/services/llm_service.dart';
import 'package:clawchat/services/preferences_service.dart';
import 'package:clawchat/services/session_storage.dart';
import 'package:clawchat/services/tools/tool_policy.dart';
import 'package:clawchat/services/tools/tool_registry.dart';
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
