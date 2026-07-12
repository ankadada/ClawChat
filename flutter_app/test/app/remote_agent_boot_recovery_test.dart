import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:clawchat/app.dart';
import 'package:clawchat/constants.dart';
import 'package:clawchat/models/chat_models.dart';
import 'package:clawchat/models/remote_agent_connector.dart';
import 'package:clawchat/providers/chat_provider.dart';
import 'package:clawchat/screens/chat_screen.dart';
import 'package:clawchat/services/app_http.dart';
import 'package:clawchat/services/llm_service.dart';
import 'package:clawchat/services/preferences_service.dart';
import 'package:clawchat/services/remote_agent_boot.dart';
import 'package:clawchat/services/remote_agent_configuration_service.dart';
import 'package:clawchat/services/session_storage.dart';
import 'package:clawchat/screens/remote_agent_configuration_recovery_screen.dart';
import 'package:clawchat/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureStorage = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  const native = MethodChannel(AppConstants.channelName);
  late Directory tempDir;
  late Map<String, String> secureValues;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PreferencesService.resetForTesting();
    tempDir = await Directory.systemTemp.createTemp('remote_boot_test_');
    secureValues = {'api_key': 'local-test-key'};
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(secureStorage, (call) async {
      final arguments = Map<String, dynamic>.from(call.arguments as Map? ?? {});
      final key = arguments['key']?.toString();
      return switch (call.method) {
        'read' => key == null ? null : secureValues[key],
        'readAll' => Map<String, String>.from(secureValues),
        'containsKey' => key != null && secureValues.containsKey(key),
        'write' => () {
            if (key != null) {
              secureValues[key] = arguments['value']?.toString() ?? '';
            }
          }(),
        'delete' => key == null ? null : secureValues.remove(key),
        'deleteAll' => secureValues.clear(),
        _ => null,
      };
    });
    messenger.setMockMethodCallHandler(pathProvider, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return tempDir.path;
      }
      return null;
    });
    messenger.setMockMethodCallHandler(native, (call) async {
      return switch (call.method) {
        'setupDirs' ||
        'writeResolv' ||
        'isBootstrapComplete' ||
        'startAgentService' ||
        'stopAgentService' ||
        'stopAgentServiceForSession' =>
          true,
        'getArch' => 'arm64-v8a',
        'getBootstrapStatus' => <String, Object?>{
            'rootfsExists': true,
            'pythonInstalled': true,
          },
        'runInProot' => '',
        _ => null,
      };
    });
  });

  tearDown(() async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(secureStorage, null);
    messenger.setMockMethodCallHandler(pathProvider, null);
    messenger.setMockMethodCallHandler(native, null);
    PreferencesService.resetForTesting();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  for (final failure in const ['corrupt', 'stale', 'oversized']) {
    testWidgets('$failure evidence renders recovery instead of blank launch',
        (tester) async {
      var attempts = 0;
      final registry = AppHttpClientRegistry(
        runtimeInfo: AppRuntimeInfo.forTesting(),
      );
      await tester.pumpWidget(ClawChatApp(
        runtimeInfo: AppRuntimeInfo.forTesting(),
        httpRegistry: registry,
        remoteAgentConfigurationLoader: () async {
          attempts += 1;
          throw FormatException(
            '$failure evidence at forbidden.example/private?key=hidden',
          );
        },
        operationalHomeBuilderForTesting: (_, localOnly) =>
            Text(localOnly ? 'local test home' : 'ready test home'),
      ));
      await tester.pump();

      expect(find.text('需要恢复本地配置'), findsOneWidget);
      expect(find.textContaining('forbidden.example'), findsNothing);
      expect(find.textContaining('private'), findsNothing);
      expect(attempts, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('Retry proceeds after repaired loader without duplicate attempts',
      (tester) async {
    var attempts = 0;
    final configuration = _configuration();
    final registry = AppHttpClientRegistry(
      runtimeInfo: AppRuntimeInfo.forTesting(),
    );
    await tester.pumpWidget(ClawChatApp(
      runtimeInfo: AppRuntimeInfo.forTesting(),
      httpRegistry: registry,
      remoteAgentConfigurationLoader: () async {
        attempts += 1;
        if (attempts == 1) throw const FormatException('invalid evidence');
        return configuration;
      },
      operationalHomeBuilderForTesting: (_, localOnly) =>
          Text(localOnly ? 'local test home' : 'ready test home'),
    ));
    await tester.pump();
    expect(attempts, 1);

    await tester.tap(find.byKey(const ValueKey('remote-configuration-retry')));
    await tester.pumpAndSettle();
    expect(find.text('ready test home'), findsOneWidget);
    expect(attempts, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('safe local mode remains interactive and disables remote entry',
      (tester) async {
    var localActions = 0;
    final controller = RemoteAgentBootController(
      loader: () async => throw const FormatException('invalid evidence'),
    );
    final registry = AppHttpClientRegistry(
      runtimeInfo: AppRuntimeInfo.forTesting(),
    );
    await tester.pumpWidget(ClawChatApp(
      runtimeInfo: AppRuntimeInfo.forTesting(),
      httpRegistry: registry,
      bootControllerForTesting: controller,
      operationalHomeBuilderForTesting: (_, localOnly) => Column(
        children: [
          Text(localOnly ? 'local test home' : 'ready test home'),
          FilledButton(
            onPressed: () => localActions += 1,
            child: const Text('local chat action'),
          ),
        ],
      ),
    ));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('remote-configuration-local-only')),
    );
    await tester.pumpAndSettle();
    expect(find.text('local test home'), findsOneWidget);
    await tester.tap(find.text('local chat action'));
    expect(localActions, 1);
    await tester.pumpWidget(const SizedBox.shrink());

    SharedPreferences.setMockInitialValues({});
    PreferencesService.resetForTesting();
    await PreferencesService().init();
    await tester.pumpWidget(
      ChangeNotifierProvider<RemoteAgentBootController>.value(
        value: controller,
        child: const MaterialApp(
          home: SettingsDetailScreen(
            destination: SettingsDestination.connections,
            skipInitialLoadForTesting: true,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('远程配置证据尚未恢复'), findsOneWidget);
    final remoteTile = tester.widget<ListTile>(
      find.widgetWithText(ListTile, '远程 Agent 连接器'),
    );
    expect(remoteTile.onTap, isNull);
    expect(find.text('重试恢复'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    PreferencesService.resetForTesting();
    controller.dispose();
  });

  testWidgets(
      'production tree keeps provider chat navigation draft queue and run identity',
      (tester) async {
    var attempts = 0;
    var providerCreations = 0;
    final configuration = await _readyConfiguration();
    final sessionStorage = _MemorySessionStorage();
    final controller = RemoteAgentBootController(loader: () async {
      attempts += 1;
      if (attempts < 3) throw const FormatException('invalid evidence');
      return configuration;
    });
    final started = Completer<void>();
    final release = Completer<void>();
    late ChatProvider createdProvider;
    final registry = AppHttpClientRegistry(
      runtimeInfo: AppRuntimeInfo.forTesting(),
    );
    final app = ClawChatApp(
      runtimeInfo: AppRuntimeInfo.forTesting(),
      httpRegistry: registry,
      bootControllerForTesting: controller,
      chatProviderFactoryForTesting: (binding) {
        providerCreations += 1;
        return createdProvider = ChatProvider(
          storage: sessionStorage,
          remoteAgentRuntimeBinding: binding,
          llmServiceFactory: (config, {isInBackground}) => _BlockingLlmService(
            config,
            started: started,
            release: release,
          ),
        );
      },
    );

    Future<void> pumpWithFeatures(List<DisplayFeature> features) =>
        tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(
              size: const Size(800, 700),
              displayFeatures: features,
            ),
            child: app,
          ),
        );

    await pumpWithFeatures(const []);
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('remote-configuration-local-only')),
    );
    await _pumpUntil(
        tester, () => find.byType(ChatScreen).evaluate().isNotEmpty);
    await _waitUntil(() => createdProvider.providerProfiles.isNotEmpty);

    final session = await createdProvider.createSession();
    createdProvider.saveDraft(session.id, 'unsent local draft');
    final firstSend = createdProvider.sendMessage('delayed local run');
    await started.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () => throw StateError(
        'local run did not start: ${createdProvider.errorMessage}',
      ),
    );
    unawaited(createdProvider.sendMessage('queued local turn'));
    await _pumpUntil(tester, () => createdProvider.messageQueue.length == 1);
    await tester.pump();

    final providerBefore = Provider.of<ChatProvider>(
      tester.element(find.byType(ChatScreen)),
      listen: false,
    );
    final chatStateBefore = tester.state(find.byType(ChatScreen));
    final navigatorBefore =
        tester.state<NavigatorState>(find.byType(Navigator));
    final registryBefore = Provider.of<AppHttpClientRegistry>(
      tester.element(find.byType(ChatScreen)),
      listen: false,
    );

    await controller.retry();
    await tester.pump();
    expect(controller.status, RemoteAgentBootStatus.localOnly);
    expect(providerCreations, 1);
    expect(
      identical(
        Provider.of<ChatProvider>(
          tester.element(find.byType(ChatScreen)),
          listen: false,
        ),
        providerBefore,
      ),
      isTrue,
    );
    expect(providerBefore.remoteAgentAvailable, isFalse);

    await pumpWithFeatures(const [
      DisplayFeature(
        bounds: Rect.fromLTWH(390, 0, 20, 700),
        type: DisplayFeatureType.hinge,
        state: DisplayFeatureState.postureFlat,
      ),
    ]);
    await controller.retry();
    await tester.pump();

    final providerAfter = Provider.of<ChatProvider>(
      tester.element(find.byType(ChatScreen)),
      listen: false,
    );
    expect(identical(providerAfter, providerBefore), isTrue);
    expect(identical(tester.state(find.byType(ChatScreen)), chatStateBefore),
        isTrue);
    expect(
      identical(tester.state<NavigatorState>(find.byType(Navigator)),
          navigatorBefore),
      isTrue,
    );
    expect(
      identical(
        Provider.of<AppHttpClientRegistry>(
          tester.element(find.byType(ChatScreen)),
          listen: false,
        ),
        registryBefore,
      ),
      isTrue,
    );
    expect(providerCreations, 1);
    expect(providerAfter.currentSession?.id, session.id);
    expect(providerAfter.getDraft(session.id), 'unsent local draft');
    expect(providerAfter.messageQueue, hasLength(1));
    expect(providerAfter.isSessionSending(session.id), isTrue);
    expect(providerAfter.remoteAgentAvailable, isTrue);

    await controller.useLocalOnly();
    await tester.pump();
    expect(
        identical(
            Provider.of<ChatProvider>(
              tester.element(find.byType(ChatScreen)),
              listen: false,
            ),
            providerBefore),
        isTrue);
    expect(providerAfter.remoteAgentAvailable, isFalse);
    expect(providerAfter.isSessionSending(session.id), isTrue);
    expect(providerAfter.messageQueue, hasLength(1));

    release.complete();
    await firstSend;
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  test('failed explicit reset remains recovery until verified retry succeeds',
      () async {
    var resets = 0;
    var loads = 0;
    final configuration = _configuration();
    final controller = RemoteAgentBootController(
      loader: () async {
        loads += 1;
        if (loads == 1) throw const FormatException('invalid evidence');
        return configuration;
      },
      resetter: () async {
        resets += 1;
        if (resets == 1) throw StateError('partial removal');
      },
    );

    await controller.start();
    await controller.resetEvidenceAndRetry();
    expect(controller.status, RemoteAgentBootStatus.recovery);
    expect(controller.failureCode, 'remote_configuration_reset_failed');
    expect(loads, 1);

    await controller.resetEvidenceAndRetry();
    expect(controller.status, RemoteAgentBootStatus.ready);
    expect(loads, 2);
    controller.dispose();
  });

  test('safe local relaunch preserves corrupt evidence without deletion',
      () async {
    final metadata = _MemoryMetadataStorage()
      ..values['remote_agent_connector_generation_v1'] = '4'
      ..values['remote_agent_connector_mutation_v1'] = 'x' * (17 * 1024);
    final original = Map<String, String>.from(metadata.values);

    Future<RemoteAgentConfigurationService> load() async {
      final service = RemoteAgentConfigurationService(
        metadataStorage: metadata,
        secretStorage: _MemorySecretStorage(),
      );
      await service.init();
      return service;
    }

    final first = RemoteAgentBootController(loader: load);
    await first.start();
    expect(first.status, RemoteAgentBootStatus.recovery);
    await first.useLocalOnly();
    expect(first.status, RemoteAgentBootStatus.localOnly);
    expect(metadata.values, original);
    expect(metadata.deleteCount, 0);
    first.dispose();

    final relaunched = RemoteAgentBootController(loader: load);
    await relaunched.start();
    expect(relaunched.status, RemoteAgentBootStatus.recovery);
    expect(metadata.values, original);
    expect(metadata.deleteCount, 0);
    relaunched.dispose();
  });

  testWidgets('book tabletop and zero folds preserve one init attempt',
      (tester) async {
    final controller = RemoteAgentBootController(
      loader: () async => throw const FormatException('invalid evidence'),
      resetter: () async {},
    );
    await controller.start();
    expect(controller.attemptCount, 1);

    Future<void> pump(Size size, List<DisplayFeature> features,
        {double bottomInset = 0}) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: const TextScaler.linear(2),
            viewInsets: EdgeInsets.only(bottom: bottomInset),
            displayFeatures: features,
          ),
          child: RemoteAgentConfigurationRecoveryScreen(
            controller: controller,
          ),
        ),
      ));
      await tester.pump();
    }

    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      controller.dispose();
    });
    await pump(const Size(800, 700), const [
      DisplayFeature(
        bounds: Rect.fromLTWH(390, 0, 20, 700),
        type: DisplayFeatureType.hinge,
        state: DisplayFeatureState.postureFlat,
      ),
    ]);
    final retry = find.byKey(const ValueKey('remote-configuration-retry'));
    expect(tester.getRect(retry).left, greaterThanOrEqualTo(410));
    expect(controller.attemptCount, 1);

    await pump(
        const Size(600, 800),
        const [
          DisplayFeature(
            bounds: Rect.fromLTWH(0, 300, 600, 20),
            type: DisplayFeatureType.fold,
            state: DisplayFeatureState.postureHalfOpened,
          ),
        ],
        bottomInset: 360);
    await tester.drag(
      find.byKey(const ValueKey('remote-configuration-recovery-scroll')),
      const Offset(0, -300),
    );
    await tester.pump();
    expect(tester.getRect(retry).bottom, lessThanOrEqualTo(300));
    expect(controller.attemptCount, 1);

    await pump(const Size(800, 700), const [
      DisplayFeature(
        bounds: Rect.fromLTWH(400, 0, 0, 700),
        type: DisplayFeatureType.fold,
        state: DisplayFeatureState.postureHalfOpened,
      ),
    ]);
    expect(tester.getRect(retry).left, greaterThanOrEqualTo(400));
    expect(controller.attemptCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('advanced reset requires exact confirmation', (tester) async {
    var resets = 0;
    var attempts = 0;
    final configuration = _configuration();
    final controller = RemoteAgentBootController(
      loader: () async {
        attempts += 1;
        if (attempts == 1) throw const FormatException('invalid evidence');
        return configuration;
      },
      resetter: () async => resets += 1,
    );
    await controller.start();
    await tester.pumpWidget(
      AnimatedBuilder(
        animation: controller,
        builder: (_, __) => MaterialApp(
          home: switch (controller.status) {
            RemoteAgentBootStatus.recovery =>
              RemoteAgentConfigurationRecoveryScreen(controller: controller),
            RemoteAgentBootStatus.initializing =>
              const RemoteAgentBootProgressScreen(),
            _ => const Scaffold(body: Text('ready')),
          },
        ),
      ),
    );

    await tester.tap(find.text('高级恢复…'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, '重置并重试'),
          )
          .onPressed,
      isNull,
    );
    await tester.enterText(find.byType(TextField), 'RESET');
    await tester.pump();
    await tester.tap(find.text('重置并重试'));
    await tester.pumpAndSettle();
    expect(resets, 1);
    expect(attempts, 2);
    expect(controller.status, RemoteAgentBootStatus.ready);
    expect(find.text('ready'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}

RemoteAgentConfigurationService _configuration() =>
    RemoteAgentConfigurationService(
      metadataStorage: _MemoryMetadataStorage(),
      secretStorage: _MemorySecretStorage(),
    );

Future<RemoteAgentConfigurationService> _readyConfiguration() async {
  final configuration = _configuration();
  await configuration.saveConfiguration(
    kind: RemoteAgentConnectorKind.cozeOpenApi,
    connectorId: 'primary_remote',
    displayName: 'Remote Agent',
    baseUrl: 'https://agent.example/v3/chat',
    remoteAgentId: 'agent_1',
    credential: 'secure-value',
  );
  await configuration.grantConsentAndEnable(
    acceptedAt: DateTime.utc(2026, 7, 12),
  );
  return configuration;
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition,
) async {
  for (var i = 0; i < 50 && !condition(); i += 1) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(condition(), isTrue);
}

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition not met');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

final class _BlockingLlmService extends LlmService {
  _BlockingLlmService(
    super.config, {
    required this.started,
    required this.release,
  });

  final Completer<void> started;
  final Completer<void> release;

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

  @override
  void dispose() {
    if (!release.isCompleted) release.complete();
    super.dispose();
  }
}

final class _MemorySessionStorage extends SessionStorage {
  final Map<String, ChatSession> _sessions = {};

  @override
  Future<void> init() async {}

  @override
  Future<void> saveSession(
    ChatSession session, {
    int? expectedGeneration,
    SessionCommitGuard? commitGuard,
  }) async {
    _sessions[session.id] = ChatSession.fromJson(session.toJson());
  }

  @override
  Future<ChatSession?> getSession(String id) async {
    final session = _sessions[id];
    return session == null ? null : ChatSession.fromJson(session.toJson());
  }

  @override
  Future<List<ChatSession>> getAllSessions() async => _sessions.values
      .map((session) => ChatSession.fromJson(session.toJson()))
      .toList(growable: false);

  @override
  Future<List<SessionSummary>> getSessionsSummary() async => _sessions.values
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

final class _MemoryMetadataStorage implements RemoteAgentMetadataStorage {
  final Map<String, String> values = {};
  int deleteCount = 0;

  @override
  Future<void> delete(String key) async {
    deleteCount += 1;
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

final class _MemorySecretStorage implements RemoteAgentSecretStorage {
  final Map<String, String> values = {};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}
