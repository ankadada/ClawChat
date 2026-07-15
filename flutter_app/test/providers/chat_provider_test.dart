import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clawchat/constants.dart';
import 'package:clawchat/l10n/app_strings.dart';
import 'package:clawchat/models/chat_models.dart';
import 'package:clawchat/models/agent_run_center.dart';
import 'package:clawchat/models/extension_manifest.dart';
import 'package:clawchat/models/model_capabilities.dart' as caps;
import 'package:clawchat/models/provider_profile.dart';
import 'package:clawchat/models/workspace_import_receipt.dart';
import 'package:clawchat/providers/chat_provider.dart';
import 'package:clawchat/services/chat_context_utils.dart';
import 'package:clawchat/services/config_export_service.dart';
import 'package:clawchat/services/context_manager.dart';
import 'package:clawchat/services/context_summary_service.dart';
import 'package:clawchat/services/attachment_budget.dart';
import 'package:clawchat/services/startup_restore_guard.dart';
import 'package:clawchat/services/llm_service.dart';
import 'package:clawchat/services/native_bridge.dart';
import 'package:clawchat/services/preferences_service.dart';
import 'package:clawchat/services/provider_message_transform.dart';
import 'package:clawchat/services/runtime_debug_events.dart';
import 'package:clawchat/services/session_storage.dart';
import 'package:clawchat/services/skill_capability_policy.dart';
import 'package:clawchat/services/skill_service.dart';
import 'package:clawchat/services/token_calibration_service.dart';
import 'package:clawchat/services/tools/tool_policy.dart';
import 'package:clawchat/services/tools/tool_registry.dart';
import 'package:clawchat/services/tools/env_var_tool.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const int _maxContextTokens = 25000;

int charCount(Map<String, dynamic> msg) {
  // ignore: deprecated_member_use_from_same_package
  return ChatContextUtils.charCount(msg);
}

List<Map<String, dynamic>> truncateToFit(List<Map<String, dynamic>> messages) {
  return ChatContextUtils.truncateToFit(
    messages,
    maxTokens: _maxContextTokens,
    estimator: const TokenEstimator(),
  ).messages;
}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition was not met');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> _waitUntilAsync(
  Future<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition was not met');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const nativeChannel = MethodChannel(AppConstants.channelName);
  late Directory tempDir;
  late Map<String, String> secureStorage;

  Future<void> installPlatformMocks() async {
    SharedPreferences.setMockInitialValues({});
    PreferencesService.resetForTesting();
    secureStorage = {};
    tempDir = await Directory.systemTemp.createTemp('clawchat_provider_test_');

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathProviderChannel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return tempDir.path;
      }
      return null;
    });
    messenger.setMockMethodCallHandler(secureStorageChannel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
      final key = args['key']?.toString();
      switch (call.method) {
        case 'read':
          return key == null ? null : secureStorage[key];
        case 'write':
          if (key != null) {
            secureStorage[key] = args['value']?.toString() ?? '';
          }
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
    messenger.setMockMethodCallHandler(nativeChannel, (call) async {
      switch (call.method) {
        case 'consumePendingNavigateToSession':
          return null;
        case 'runInProot':
          return '';
        case 'readRootfsFile':
          return null;
        case 'writeRootfsFile':
          return true;
      }
      return true;
    });
  }

  Future<void> clearPlatformMocks() async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathProviderChannel, null);
    messenger.setMockMethodCallHandler(secureStorageChannel, null);
    messenger.setMockMethodCallHandler(nativeChannel, null);
    PreferencesService.resetForTesting();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  }

  void configureAnthropicProfile({
    required String baseUrl,
    bool developerMode = true,
  }) {
    final profile = ProviderProfile.defaults().copyWith(
      id: 'profile',
      apiKey: 'sk-test',
      apiFormat: ProviderProfile.anthropicFormat,
      baseUrl: baseUrl,
      model: 'claude-sonnet-4-20250514',
    );
    secureStorage['provider_profiles'] = jsonEncode([profile.toJson()]);
    SharedPreferences.setMockInitialValues({
      'active_provider_profile_id': 'profile',
      'context_token_budget': 65536,
      'developer_mode': developerMode,
    });
  }

  void configureModelFallbackProfiles({
    List<ProviderProfile>? fallbackProfiles,
    List<ModelFallbackTarget>? targets,
    int primaryThinkingBudget = 0,
    int contextTokenBudget = 65536,
    bool developerMode = true,
  }) {
    final configuredTargets = targets ??
        const [
          ModelFallbackTarget(targetProfileId: 'fallback'),
        ];
    final primary = ProviderProfile.defaults().copyWith(
      id: 'primary',
      name: 'Primary',
      apiKey: 'sk-test-primary',
      apiFormat: ProviderProfile.anthropicFormat,
      baseUrl: 'http://primary.test',
      model: 'claude-primary-200k',
      thinkingBudget: primaryThinkingBudget,
      fallbackTargets: configuredTargets,
    );
    final fallback = ProviderProfile.defaults().copyWith(
      id: 'fallback',
      name: 'Fallback',
      apiKey: 'sk-test-fallback',
      apiFormat: ProviderProfile.anthropicFormat,
      baseUrl: 'http://fallback.test',
      model: 'claude-fallback-200k',
      thinkingBudget: primaryThinkingBudget,
    );
    secureStorage['provider_profiles'] = jsonEncode([
      primary.toJson(),
      ...(fallbackProfiles ?? [fallback]).map((profile) => profile.toJson()),
    ]);
    SharedPreferences.setMockInitialValues({
      'active_provider_profile_id': 'primary',
      'context_token_budget': contextTokenBudget,
      'developer_mode': developerMode,
    });
  }

  group('alternative navigation', () {
    setUp(() async {
      await installPlatformMocks();
    });

    tearDown(() async {
      await clearPlatformMocks();
    });

    test('switches 2 to 1 to 2 to 1 without reordering versions', () async {
      final provider = ChatProvider();
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final session = await provider.createSession();
      session.messages
        ..clear()
        ..addAll([
          ChatMessage.user('prompt'),
          ChatMessage(
            role: 'assistant',
            content: [TextContent('v2')],
            alternatives: ['v1'],
          ),
        ]);

      provider.switchAlternative(1, 0);
      var message = provider.currentSession!.messages[1];
      expect(message.textContent, 'v1');
      expect(message.displayIndex, 1);
      expect((message.content.single as TextContent).text, 'v2');
      expect(message.alternatives, ['v1']);

      provider.switchAlternative(1, 1);
      message = provider.currentSession!.messages[1];
      expect(message.textContent, 'v2');
      expect(message.displayIndex, 2);
      expect((message.content.single as TextContent).text, 'v2');
      expect(message.alternatives, ['v1']);

      provider.switchAlternative(1, 0);
      message = provider.currentSession!.messages[1];
      expect(message.textContent, 'v1');
      expect(message.displayIndex, 1);
      expect((message.content.single as TextContent).text, 'v2');
      expect(message.alternatives, ['v1']);

      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
  });

  group('session metadata', () {
    setUp(() async {
      await installPlatformMocks();
    });

    tearDown(() async {
      await clearPlatformMocks();
    });

    test('renameSession preserves folder in session summary', () async {
      final storage = SessionStorage();
      await storage.init();
      final provider = ChatProvider(storage: storage);
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final session = await provider.createSession();
      await provider.moveToFolder(session.id, 'Work');
      await provider.renameSession(session.id, 'Renamed');

      expect(provider.sessions.single.title, 'Renamed');
      expect(provider.sessions.single.folder, 'Work');
    });
  });

  group('structured-result persistence handoff', () {
    setUp(() async {
      await installPlatformMocks();
      configureAnthropicProfile(baseUrl: 'http://127.0.0.1');
    });

    tearDown(clearPlatformMocks);

    test('persists a validated card beside its matching tool result', () async {
      const documentJson = '''{
        "schemaVersion":1,
        "resultId":"123e4567-e89b-42d3-a456-426614174000",
        "blocks":[{"kind":"notice","level":"info","text":"Stored safely"}]
      }''';
      var turns = 0;
      final storage = SessionStorage();
      await storage.init();
      final provider = ChatProvider(
        storage: storage,
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) {
            turns += 1;
            if (turns == 1) {
              return StreamDone(const LlmResponse(
                stopReason: 'tool_use',
                content: [
                  ContentBlock(
                    type: 'tool_use',
                    toolUseId: 'structured-1',
                    toolName: 'present_structured_result',
                    toolInput: {'documentJson': documentJson},
                  ),
                ],
              ));
            }
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'done')],
            ));
          },
        ),
      );
      addTearDown(provider.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();

      await provider.sendMessage('show result');
      await _waitUntil(() => provider.agentStatus == AgentStatus.idle);

      final resultMessage = provider.currentSession!.messages.firstWhere(
        (message) =>
            message.content.whereType<StructuredResultContent>().isNotEmpty,
      );
      expect(resultMessage.role, 'user');
      expect(resultMessage.toolResults.single.forLlm,
          'NOTICE [info]: Stored safely');
      expect(resultMessage.content.whereType<StructuredResultContent>(),
          hasLength(1));

      final persisted = await storage.getSession(session.id);
      expect(persisted, isNotNull);
      final persistedResult = persisted!.messages.firstWhere(
        (message) =>
            message.content.whereType<StructuredResultContent>().isNotEmpty,
      );
      expect(persistedResult.toolResults.single.forLlm,
          'NOTICE [info]: Stored safely');
      final apiBlockTypes = persisted
          .toApiMessages()
          .expand((message) => message['content'] is List
              ? message['content'] as List
              : const <Object?>[])
          .whereType<Map>()
          .map((block) => block['type']);
      expect(apiBlockTypes, isNot(contains('structured_result')));
    });
  });

  group('message queue undo', () {
    setUp(() async {
      await installPlatformMocks();
      configureAnthropicProfile(baseUrl: 'http://127.0.0.1');
    });

    tearDown(clearPlatformMocks);

    test('remove and clear restore exact order and attachment ownership',
        () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final provider = ChatProvider(
        llmServiceFactory: (config, {isInBackground}) => _BlockingLlmService(
          config,
          started: started,
          release: release,
        ),
      );
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();
      final active = provider.sendMessage('active');
      await started.future;
      unawaited(provider.sendMessage(
        'queued one',
        attachments: [TextContent('local attachment')],
      ));
      unawaited(provider.sendMessage('queued two'));
      await _waitUntil(() => provider.messageQueue.length == 2);
      final original = List<QueuedMessage>.from(provider.messageQueue);

      final one = provider.removeQueuedMessage(original.first.id)!;
      expect(provider.messageQueue.map((message) => message.id),
          [original.last.id]);
      expect(provider.restoreMessageQueue(one), isTrue);
      expect(provider.messageQueue.map((message) => message.id),
          original.map((message) => message.id));
      expect(
          identical(provider.messageQueue.first.attachments.first,
              original.first.attachments.first),
          isTrue);

      final all = provider.clearMessageQueue()!;
      expect(provider.messageQueue, isEmpty);
      expect(provider.restoreMessageQueue(all), isTrue);
      expect(provider.messageQueue.map((message) => message.id),
          original.map((message) => message.id));

      final afterDeletion = provider.clearMessageQueue()!;
      await provider.deleteSession(session.id);
      expect(provider.restoreMessageQueue(afterDeletion), isFalse);
      if (!release.isCompleted) release.complete();
      await active;
    });

    test('removing drain head reschedules once and sends only the next head',
        () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final timers = _ManualTimerScheduler();
      final provider = ChatProvider(
        messageQueueDrainTimerFactory: timers.schedule,
        llmServiceFactory: (config, {isInBackground}) => _BlockingLlmService(
          config,
          started: started,
          release: release,
        ),
      );
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await provider.createSession();
      final active = provider.sendMessage('active');
      await started.future;
      unawaited(provider.sendMessage('queued head'));
      unawaited(provider.sendMessage('queued next'));
      await _waitUntil(() => provider.messageQueue.length == 2);
      final original = List<QueuedMessage>.from(provider.messageQueue);

      if (!release.isCompleted) release.complete();
      await active;
      expect(timers.activeCount, 1);
      expect(timers.createdCount, 1);

      provider.removeQueuedMessage(original.first.id);
      expect(provider.messageQueue.single.id, original.last.id);
      expect(timers.activeCount, 1);
      expect(timers.createdCount, 2);

      timers.fireAll();
      await _waitUntil(() => provider.messageQueue.isEmpty);
      await _waitUntil(
        () => provider.currentSession!.messages
            .where((message) => message.role == 'user')
            .any((message) => message.textContent == 'queued next'),
      );
      final userMessages = provider.currentSession!.messages
          .where((message) => message.role == 'user')
          .map((message) => message.textContent);
      expect(userMessages.where((text) => text == 'queued next'), hasLength(1));
      expect(userMessages, isNot(contains('queued head')));
    });

    test('removing a non-head preserves the current drain timer', () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final timers = _ManualTimerScheduler();
      final provider = ChatProvider(
        messageQueueDrainTimerFactory: timers.schedule,
        llmServiceFactory: (config, {isInBackground}) => _BlockingLlmService(
          config,
          started: started,
          release: release,
        ),
      );
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await provider.createSession();
      final active = provider.sendMessage('active');
      await started.future;
      unawaited(provider.sendMessage('queued head'));
      unawaited(provider.sendMessage('queued tail'));
      await _waitUntil(() => provider.messageQueue.length == 2);
      final original = List<QueuedMessage>.from(provider.messageQueue);

      release.complete();
      await active;
      expect(timers.createdCount, 1);
      provider.removeQueuedMessage(original.last.id);
      expect(timers.createdCount, 1);

      timers.fireAll();
      await _waitUntil(() => provider.messageQueue.isEmpty);
      final userMessages = provider.currentSession!.messages
          .where((message) => message.role == 'user')
          .map((message) => message.textContent);
      expect(userMessages.where((text) => text == 'queued head'), hasLength(1));
      expect(userMessages, isNot(contains('queued tail')));
    });

    test('capacity-limited undo retains remaining order and attachments',
        () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final provider = ChatProvider(
        llmServiceFactory: (config, {isInBackground}) => _BlockingLlmService(
          config,
          started: started,
          release: release,
        ),
      );
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();
      final active = provider.sendMessage('active');
      await started.future;
      final attachment = TextContent('retained attachment');
      unawaited(provider.sendMessage('original one'));
      unawaited(provider.sendMessage(
        'original two',
        attachments: [attachment],
      ));
      unawaited(provider.sendMessage('original three'));
      await _waitUntil(
        () => provider.messageQueue.length == ChatProvider.maxQueuedMessages,
      );
      final original = List<QueuedMessage>.from(provider.messageQueue);
      final undo = provider.clearMessageQueue()!;

      unawaited(provider.sendMessage('new one'));
      unawaited(provider.sendMessage('new two'));
      await _waitUntil(() => provider.messageQueue.length == 2);
      final newItems = List<QueuedMessage>.from(provider.messageQueue);
      final partial = provider.restoreMessageQueueWithResult(undo);
      expect(partial.restoredCount, 1);
      expect(partial.remainingCount, 2);
      expect(provider.messageQueue, hasLength(ChatProvider.maxQueuedMessages));
      expect(provider.messageQueue.first.id, original.first.id);
      expect(
        identical(partial.remainingUndo!.messages.first.attachments.first,
            attachment),
        isTrue,
      );

      provider.removeQueuedMessage(newItems.first.id);
      provider.removeQueuedMessage(newItems.last.id);
      final completed =
          provider.restoreMessageQueueWithResult(partial.remainingUndo!);
      expect(completed.remainingUndo, isNull);
      expect(
        provider.messageQueue.map((message) => message.id),
        original.map((message) => message.id),
      );
      expect(
        identical(provider.messageQueue[1].attachments.first, attachment),
        isTrue,
      );

      final fullUndo = provider.clearMessageQueue()!;
      unawaited(provider.sendMessage('replacement one'));
      unawaited(provider.sendMessage('replacement two'));
      unawaited(provider.sendMessage('replacement three'));
      await _waitUntil(
        () => provider.messageQueue.length == ChatProvider.maxQueuedMessages,
      );
      final full = provider.restoreMessageQueueWithResult(fullUndo);
      expect(full.restoredCount, 0);
      expect(full.remainingCount, ChatProvider.maxQueuedMessages);
      expect(provider.messageQueue, hasLength(ChatProvider.maxQueuedMessages));
      expect(
        identical(
            full.remainingUndo!.messages[1].attachments.first, attachment),
        isTrue,
      );

      await provider.deleteSession(session.id);
      final missing =
          provider.restoreMessageQueueWithResult(full.remainingUndo!);
      expect(missing.sessionMissing, isTrue);
      expect(missing.restoredCount, 0);
      if (!release.isCompleted) release.complete();
      await active;
    });

    test('undo remains bound to its session across switching and deletion',
        () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final provider = ChatProvider(
        llmServiceFactory: (config, {isInBackground}) => _BlockingLlmService(
          config,
          started: started,
          release: release,
        ),
      );
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final source = await provider.createSession();
      final active = provider.sendMessage('active');
      await started.future;
      unawaited(provider.sendMessage('queued for source'));
      await _waitUntil(() => provider.messageQueue.length == 1);
      final undo = provider.clearMessageQueue()!;

      final other = await provider.createSession();
      expect(provider.currentSession!.id, other.id);
      final restored = provider.restoreMessageQueueWithResult(undo);
      expect(restored.restoredCount, 1);
      expect(provider.messageQueue, isEmpty);

      await provider.selectSession(source.id);
      expect(provider.messageQueue.single.text, 'queued for source');
      final deletionUndo = provider.clearMessageQueue()!;
      await provider.deleteSession(source.id);
      expect(
        provider.restoreMessageQueueWithResult(deletionUndo).sessionMissing,
        isTrue,
      );
      if (!release.isCompleted) release.complete();
      await active;
    });
  });

  group('workspace import receipt lifecycle', () {
    setUp(() async {
      await installPlatformMocks();
      configureAnthropicProfile(baseUrl: 'http://127.0.0.1');
    });

    tearDown(() async {
      NativeBridge.resetImportReadStreamForTesting();
      await clearPlatformMocks();
    });

    WorkspaceImportReceipt receipt(String operation) => WorkspaceImportReceipt(
          operationId: operation * 32,
          storedPath: '/root/workspace/uploads/report_${operation * 32}.bin',
          size: 3,
          sha256: 'f' * 64,
          displayName: 'report.bin',
        );

    ChatProvider providerFor(SessionStorage storage) => ChatProvider(
          storage: storage,
          llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
            config,
            onMessages: (_) => StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'done')],
            )),
          ),
        );

    test('durable message reference is saved before native ACK', () async {
      final storage = SessionStorage();
      await storage.init();
      final events = <String>[];
      late ChatProvider provider;
      NativeBridge.setWorkspaceImportLifecycleBrokerForTesting(
        (receipt, discard) async {
          events.add(discard ? 'discard' : 'ack');
          final persisted = await storage.getSession(
            provider.currentSession!.id,
          );
          expect(persisted!.messages.last.textContent,
              contains(receipt.storedPath));
          expect(persisted.pendingWorkspaceImports.single.operationId,
              receipt.operationId);
          return true;
        },
      );
      provider = providerFor(storage);
      addTearDown(provider.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await provider.createSession();
      final importReceipt = receipt('a');

      final committed = await provider.sendMessageWithWorkspaceImports(
        importReceipt.marker,
        workspaceImports: [importReceipt],
      );

      expect(committed, isTrue);
      await _waitUntil(() => events.contains('ack'));
      await _waitUntilAsync(() async =>
          (await storage.getSession(provider.currentSession!.id))!
              .pendingWorkspaceImports
              .isEmpty);
      expect(events, ['ack']);
    });

    test('reference save failure never ACKs and leaves draft ownership',
        () async {
      var saves = 0;
      final storage = SessionStorage(beforeCommitForTesting: (_) async {
        saves++;
        if (saves == 2) throw StateError('reference save failed');
      });
      await storage.init();
      var acknowledged = false;
      NativeBridge.setWorkspaceImportLifecycleBrokerForTesting(
        (_, __) async {
          acknowledged = true;
          return true;
        },
      );
      final provider = providerFor(storage);
      addTearDown(provider.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();
      final importReceipt = receipt('b');

      final committed = await provider.sendMessageWithWorkspaceImports(
        importReceipt.marker,
        workspaceImports: [importReceipt],
      );

      expect(committed, isFalse);
      expect(acknowledged, isFalse);
      final persisted = await storage.getSession(session.id);
      expect(persisted!.messages, isEmpty);
      expect(persisted.pendingWorkspaceImports, isEmpty);
    });

    test('restart reconciles crash-before-ACK receipt idempotently', () async {
      final storage = SessionStorage();
      await storage.init();
      final importReceipt = receipt('c');
      final session = ChatSession(
        id: 'pending_workspace_receipt',
        messages: [ChatMessage.user(importReceipt.marker)],
        pendingWorkspaceImports: [importReceipt],
      );
      await storage.saveSession(session);
      var acknowledgements = 0;
      NativeBridge.setWorkspaceImportLifecycleBrokerForTesting(
        (_, discard) async {
          expect(discard, isFalse);
          acknowledgements++;
          return true;
        },
      );
      final provider = providerFor(storage);
      addTearDown(provider.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await provider.selectSession(session.id);
      await provider.selectSession(session.id);

      expect(acknowledgements, 1);
      expect((await storage.getSession(session.id))!.pendingWorkspaceImports,
          isEmpty);
    });

    test('ACK failure retains the durable receipt and does not start model',
        () async {
      final storage = SessionStorage();
      await storage.init();
      NativeBridge.setWorkspaceImportLifecycleBrokerForTesting(
        (_, __) async => false,
      );
      var modelStarted = false;
      final provider = ChatProvider(
        storage: storage,
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) {
            modelStarted = true;
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'unsafe')],
            ));
          },
        ),
      );
      addTearDown(provider.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();
      final importReceipt = receipt('d');

      final committed = await provider.sendMessageWithWorkspaceImports(
        importReceipt.marker,
        workspaceImports: [importReceipt],
      );
      await _waitUntil(() => provider.agentStatus == AgentStatus.error);

      expect(committed, isTrue);
      expect(modelStarted, isFalse);
      final persisted = await storage.getSession(session.id);
      expect(persisted!.messages.single.textContent,
          contains(importReceipt.storedPath));
      expect(persisted.pendingWorkspaceImports.single.operationId,
          importReceipt.operationId);
    });

    test('startup discards published receipt with no durable session owner',
        () async {
      final storage = SessionStorage();
      await storage.init();
      final unowned = receipt('e');
      NativeBridge.setPendingWorkspaceImportListerForTesting(
        () async => [unowned],
      );
      final discarded = <String>[];
      NativeBridge.setWorkspaceImportLifecycleBrokerForTesting(
        (receipt, discard) async {
          expect(discard, isTrue);
          discarded.add(receipt.operationId);
          return true;
        },
      );

      final provider = providerFor(storage);
      addTearDown(provider.dispose);
      await _waitUntil(() => discarded.isNotEmpty);

      expect(discarded, [unowned.operationId]);
      expect(await storage.getAllSessions(), isEmpty);
    });

    for (final ackSucceeds in [true, false]) {
      test(
          'delete prevents resurrection after stalled ACK ${ackSucceeds ? 'success' : 'failure'}',
          () async {
        final storage = SessionStorage();
        await storage.init();
        final importReceipt = receipt(ackSucceeds ? 'f' : '1');
        final session = ChatSession(
          id: 'delete_stalled_ack_${ackSucceeds ? 'success' : 'failure'}',
          messages: [ChatMessage.user(importReceipt.marker)],
          pendingWorkspaceImports: [importReceipt],
        );
        await storage.saveSession(session);
        final ackEntered = Completer<void>();
        final releaseAck = Completer<void>();
        var discards = 0;
        NativeBridge.setWorkspaceImportLifecycleBrokerForTesting(
          (_, discard) async {
            if (discard) {
              discards++;
              return true;
            }
            if (!ackEntered.isCompleted) ackEntered.complete();
            await releaseAck.future;
            return ackSucceeds;
          },
        );
        final provider = providerFor(storage);
        addTearDown(provider.dispose);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        final select = provider.selectSession(session.id);
        await ackEntered.future.timeout(const Duration(seconds: 2));
        await provider.deleteSession(session.id);
        expect(storage.isSessionTombstoned(session.id), isTrue);
        expect(await storage.getSession(session.id), isNull);
        expect(discards, 1);

        releaseAck.complete();
        await select;
        expect(await storage.getSession(session.id), isNull);
        final reloadedStorage = SessionStorage();
        await reloadedStorage.init();
        expect(await reloadedStorage.getSession(session.id), isNull);
      });
    }
  });

  group('tool approval hardening', () {
    setUp(() async {
      await installPlatformMocks();
      configureAnthropicProfile(baseUrl: 'http://127.0.0.1');
    });

    tearDown(() async {
      await clearPlatformMocks();
    });

    test('background current session waits for exact notification approval',
        () async {
      var requestCount = 0;
      final nativeCalls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativeChannel, (call) async {
        nativeCalls.add(call);
        if (call.method == 'consumePendingNavigateToSession') return null;
        return true;
      });
      final tool = _EchoTool();
      final tools = ToolRegistry()..register(tool, risk: ToolRisk.dangerous);
      final provider = ChatProvider(
        toolRegistry: tools,
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => throw UnimplementedError(),
          onMessageEvents: (_) {
            requestCount++;
            if (requestCount == 1) {
              return [
                StreamDone(const LlmResponse(
                  stopReason: 'tool_use',
                  content: [
                    ContentBlock(
                      type: 'tool_use',
                      toolUseId: 'call_1',
                      toolName: 'echo',
                      toolInput: {'text': 'secret-free'},
                    ),
                  ],
                )),
              ];
            }
            return [
              StreamDone(const LlmResponse(
                stopReason: 'end_turn',
                content: [ContentBlock(type: 'text', text: 'done')],
              )),
            ];
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await provider.createSession();
      PreferencesService().toolApprovalPolicy =
          PreferencesService.toolApprovalAlways;
      provider.setAppInBackground(true);
      final send = provider.sendMessage('use tool');
      await _waitUntil(() => provider.pendingApproval != null);
      final request = provider.pendingApproval!;
      expect(request.operationId, isNotNull);
      expect(
        nativeCalls.map((call) => call.method),
        contains('showToolApprovalNotification'),
      );
      expect(
        nativeCalls.map((call) => call.method),
        contains('startAgentService'),
      );
      expect(
        nativeCalls.map((call) => call.method),
        isNot(contains('stopAgentServiceForSession')),
      );
      expect(provider.isSessionSending(provider.currentSession!.id), isTrue);
      expect(
        await provider.resolveToolApprovalFromNotificationForTesting(
          sessionId: provider.currentSession!.id,
          approvalId: request.operationId,
          approved: true,
        ),
        isTrue,
      );
      expect(
        await provider.resolveToolApprovalFromNotificationForTesting(
          sessionId: provider.currentSession!.id,
          approvalId: request.operationId,
          approved: true,
        ),
        isFalse,
      );
      await send;

      expect(requestCount, 2);
      final toolResult =
          provider.currentSession!.messages.expand((m) => m.toolResults).single;
      expect(toolResult.output, 'secret-free');
      expect(tool.executionCount, 1);
      expect(
        nativeCalls.map((call) => call.method),
        contains('clearToolApprovalNotification'),
      );
    });

    test('notification approval fails closed after switching sessions',
        () async {
      final tool = _EchoTool();
      var requestCount = 0;
      final provider = ChatProvider(
        toolRegistry: ToolRegistry()..register(tool, risk: ToolRisk.dangerous),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => throw UnimplementedError(),
          onMessageEvents: (_) {
            requestCount++;
            if (requestCount == 1) {
              return [
                StreamDone(const LlmResponse(
                  stopReason: 'tool_use',
                  content: [
                    ContentBlock(
                      type: 'tool_use',
                      toolUseId: 'call_switch',
                      toolName: 'echo',
                      toolInput: {'text': 'must-not-run'},
                    ),
                  ],
                )),
              ];
            }
            return [
              StreamDone(const LlmResponse(
                stopReason: 'end_turn',
                content: [ContentBlock(type: 'text', text: 'done')],
              )),
            ];
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final source = await provider.createSession();
      provider.setAppInBackground(true);
      final send = provider.sendMessage('use tool');
      await _waitUntil(() => provider.pendingApproval != null);
      final approvalId = provider.pendingApproval!.operationId;
      await provider.createSession();

      expect(
        await provider.resolveToolApprovalFromNotificationForTesting(
          sessionId: source.id,
          approvalId: approvalId,
          approved: true,
        ),
        isFalse,
      );
      expect(tool.executionCount, 0);
      provider.resolveToolApproval(
        operationId: provider.pendingApproval!.operationId,
        approved: false,
      );
      await send;
      expect(tool.executionCount, 0);
    });

    test('resumed approval handoff waits for the exact visible surface',
        () async {
      final nativeCalls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativeChannel, (call) async {
        nativeCalls.add(call);
        if (call.method == 'consumePendingNavigateToSession') return null;
        return true;
      });
      final tool = _EchoTool();
      var requestCount = 0;
      final provider = ChatProvider(
        toolRegistry: ToolRegistry()..register(tool, risk: ToolRisk.dangerous),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => throw UnimplementedError(),
          onMessageEvents: (_) {
            requestCount++;
            if (requestCount == 1) {
              return [
                StreamDone(const LlmResponse(
                  stopReason: 'tool_use',
                  content: [
                    ContentBlock(
                      type: 'tool_use',
                      toolUseId: 'call_handoff',
                      toolName: 'echo',
                      toolInput: {'text': 'must-not-run'},
                    ),
                  ],
                )),
              ];
            }
            return [
              StreamDone(const LlmResponse(
                stopReason: 'end_turn',
                content: [ContentBlock(type: 'text', text: 'done')],
              )),
            ];
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await provider.createSession();
      provider.setAppInBackground(true);
      final send = provider.sendMessage('use tool');
      await _waitUntil(() => provider.pendingApproval != null);
      final sessionId = provider.currentSession!.id;
      final approvalId = provider.pendingApproval!.operationId;

      expect(
        provider.confirmAppResumedApprovalSurface(
          approvalId: 'stale-operation',
        ),
        isFalse,
      );
      expect(
        nativeCalls.where(
          (call) => call.method == 'clearToolApprovalNotification',
        ),
        isEmpty,
      );
      expect(
        provider.confirmAppResumedApprovalSurface(approvalId: approvalId),
        isTrue,
      );
      await _waitUntil(
        () => nativeCalls.any(
          (call) => call.method == 'clearToolApprovalNotification',
        ),
      );
      expect(
        await provider.resolveToolApprovalFromNotificationForTesting(
          sessionId: sessionId,
          approvalId: approvalId,
          approved: true,
        ),
        isFalse,
      );

      provider.resolveToolApproval(
        operationId: provider.pendingApproval!.operationId,
        approved: false,
      );
      await send;
      expect(tool.executionCount, 0);
    });

    test('stale in-app decision IDs cannot resolve a newer approval', () async {
      final nativeCalls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativeChannel, (call) async {
        nativeCalls.add(call);
        if (call.method == 'consumePendingNavigateToSession') return null;
        return true;
      });
      final tool = _EchoTool();
      var requestCount = 0;
      final provider = ChatProvider(
        toolRegistry: ToolRegistry()..register(tool, risk: ToolRisk.dangerous),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => throw UnimplementedError(),
          onMessageEvents: (_) {
            requestCount++;
            if (requestCount == 1) {
              return [
                StreamDone(const LlmResponse(
                  stopReason: 'tool_use',
                  content: [
                    ContentBlock(
                      type: 'tool_use',
                      toolUseId: 'identity_a',
                      toolName: 'echo',
                      toolInput: {'text': 'first'},
                    ),
                    ContentBlock(
                      type: 'tool_use',
                      toolUseId: 'identity_b',
                      toolName: 'echo',
                      toolInput: {'text': 'second'},
                    ),
                  ],
                )),
              ];
            }
            return [
              StreamDone(const LlmResponse(
                stopReason: 'end_turn',
                content: [ContentBlock(type: 'text', text: 'done')],
              )),
            ];
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await provider.createSession();

      final send = provider.sendMessage('two approvals');
      await _waitUntil(() => provider.pendingApproval != null);
      final firstId = provider.pendingApproval!.operationId;
      expect(
        provider.resolveToolApproval(
          operationId: firstId,
          approved: true,
        ),
        isTrue,
      );
      await _waitUntil(
        () =>
            provider.pendingApproval?.operationId != null &&
            provider.pendingApproval!.operationId != firstId,
      );
      final secondId = provider.pendingApproval!.operationId;
      expect(tool.executionCount, 1);

      for (final staleDecision in const [
        (approved: false, rememberForSession: false),
        (approved: true, rememberForSession: false),
        (approved: true, rememberForSession: true),
      ]) {
        expect(
          provider.resolveToolApproval(
            operationId: firstId,
            approved: staleDecision.approved,
            rememberForSession: staleDecision.rememberForSession,
          ),
          isFalse,
        );
        expect(provider.pendingApproval!.operationId, secondId);
        expect(tool.executionCount, 1);
      }

      provider.setAppInBackground(true);
      await _waitUntil(
        () => nativeCalls.any(
          (call) =>
              call.method == 'showToolApprovalNotification' &&
              (call.arguments as Map)['approvalId'] == secondId,
        ),
      );
      final clearSecondBeforeStaleSurface = nativeCalls.where(
        (call) =>
            call.method == 'clearToolApprovalNotification' &&
            (call.arguments as Map)['approvalId'] == secondId,
      );
      expect(clearSecondBeforeStaleSurface, isEmpty);
      expect(
        provider.confirmAppResumedApprovalSurface(approvalId: firstId),
        isFalse,
      );
      expect(provider.pendingApproval!.operationId, secondId);
      expect(
        nativeCalls.where(
          (call) =>
              call.method == 'clearToolApprovalNotification' &&
              (call.arguments as Map)['approvalId'] == secondId,
        ),
        isEmpty,
      );

      expect(
        await provider.resolveToolApprovalFromNotificationForTesting(
          sessionId: provider.currentSession!.id,
          approvalId: secondId,
          approved: true,
        ),
        isTrue,
      );
      await send;

      expect(requestCount, 2);
      expect(tool.executionCount, 2);
      expect(provider.pendingApproval, isNull);
    });

    test('disabled notification capability fails closed without waiting',
        () async {
      final nativeCalls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativeChannel, (call) async {
        nativeCalls.add(call.method);
        if (call.method == 'consumePendingNavigateToSession') return null;
        if (call.method == 'showToolApprovalNotification') return false;
        return true;
      });
      final tool = _EchoTool();
      var requestCount = 0;
      final provider = ChatProvider(
        toolRegistry: ToolRegistry()..register(tool, risk: ToolRisk.dangerous),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => throw UnimplementedError(),
          onMessageEvents: (_) {
            requestCount++;
            if (requestCount == 1) {
              return [
                StreamDone(const LlmResponse(
                  stopReason: 'tool_use',
                  content: [
                    ContentBlock(
                      type: 'tool_use',
                      toolUseId: 'call_disabled',
                      toolName: 'echo',
                      toolInput: {'text': 'must-not-run'},
                    ),
                  ],
                )),
              ];
            }
            return [
              StreamDone(const LlmResponse(
                stopReason: 'end_turn',
                content: [ContentBlock(type: 'text', text: 'done')],
              )),
            ];
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await provider.createSession();
      PreferencesService().toolApprovalPolicy =
          PreferencesService.toolApprovalAlways;
      provider.setAppInBackground(true);
      await provider.sendMessage('use tool');

      expect(provider.pendingApproval, isNull);
      expect(tool.executionCount, 0);
      expect(
        provider.currentSession!.messages
            .where((message) => message.isSystemNotice)
            .map((message) => message.textContent),
        contains(contains('启用系统通知')),
      );
      expect(nativeCalls, contains('showToolApprovalNotification'));
      expect(nativeCalls, contains('stopAgentServiceForSession'));
    });

    test('non-current session denies dangerous tool approval', () async {
      var requestCount = 0;
      final storage = SessionStorage();
      await storage.init();
      final tools = ToolRegistry()
        ..register(_EchoTool(), risk: ToolRisk.dangerous);
      final provider = ChatProvider(
        storage: storage,
        toolRegistry: tools,
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => throw UnimplementedError(),
          onMessageEvents: (_) {
            requestCount++;
            if (requestCount == 1) {
              return [
                StreamDone(const LlmResponse(
                  stopReason: 'tool_use',
                  content: [
                    ContentBlock(
                      type: 'tool_use',
                      toolUseId: 'call_1',
                      toolName: 'echo',
                      toolInput: {'text': 'non-current'},
                    ),
                  ],
                )),
              ];
            }
            return [
              StreamDone(const LlmResponse(
                stopReason: 'end_turn',
                content: [ContentBlock(type: 'text', text: 'done')],
              )),
            ];
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final target = await provider.createSession();
      await provider.createSession();
      await provider.sendMessage('use tool', targetSessionId: target.id);

      expect(requestCount, 2);
      ChatSession? storedTarget;
      // Non-current session persistence is saved from the agent event stream
      // without blocking UI updates.
      for (var i = 0; i < 50; i++) {
        storedTarget = await storage.getSession(target.id);
        if (storedTarget!.messages.expand((m) => m.toolResults).isNotEmpty) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final toolResult =
          storedTarget!.messages.expand((m) => m.toolResults).single;
      expect(toolResult.output, contains('denied'));
      expect(toolResult.output, isNot(contains('non-current')));
    });

    test('auto policy executes approval-eligible tool once in foreground',
        () async {
      final nativeCalls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativeChannel, (call) async {
        nativeCalls.add(call.method);
        if (call.method == 'consumePendingNavigateToSession') return null;
        return true;
      });
      final tool = _EchoTool();
      var requestCount = 0;
      final provider = ChatProvider(
        toolRegistry: ToolRegistry()..register(tool, risk: ToolRisk.dangerous),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => throw UnimplementedError(),
          onMessageEvents: (_) {
            requestCount++;
            if (requestCount == 1) {
              return [
                StreamDone(const LlmResponse(
                  stopReason: 'tool_use',
                  content: [
                    ContentBlock(
                      type: 'tool_use',
                      toolUseId: 'auto_foreground',
                      toolName: 'echo',
                      toolInput: {'text': 'auto-foreground'},
                    ),
                  ],
                )),
              ];
            }
            return [
              StreamDone(const LlmResponse(
                stopReason: 'end_turn',
                content: [ContentBlock(type: 'text', text: 'done')],
              )),
            ];
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      PreferencesService().toolApprovalPolicy =
          PreferencesService.toolApprovalAuto;
      await provider.createSession();

      await provider.sendMessage('auto foreground');

      expect(provider.pendingApproval, isNull);
      expect(requestCount, 2);
      expect(tool.executionCount, 1);
      expect(nativeCalls, isNot(contains('showToolApprovalNotification')));
    });

    test('auto policy executes approval-eligible tool once in background',
        () async {
      final nativeCalls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativeChannel, (call) async {
        nativeCalls.add(call.method);
        if (call.method == 'consumePendingNavigateToSession') return null;
        if (call.method == 'showToolApprovalNotification') return false;
        return true;
      });
      final tool = _EchoTool();
      var requestCount = 0;
      final provider = ChatProvider(
        toolRegistry: ToolRegistry()..register(tool, risk: ToolRisk.dangerous),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => throw UnimplementedError(),
          onMessageEvents: (_) {
            requestCount++;
            if (requestCount == 1) {
              return [
                StreamDone(const LlmResponse(
                  stopReason: 'tool_use',
                  content: [
                    ContentBlock(
                      type: 'tool_use',
                      toolUseId: 'auto_background',
                      toolName: 'echo',
                      toolInput: {'text': 'auto-background'},
                    ),
                  ],
                )),
              ];
            }
            return [
              StreamDone(const LlmResponse(
                stopReason: 'end_turn',
                content: [ContentBlock(type: 'text', text: 'done')],
              )),
            ];
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      PreferencesService().toolApprovalPolicy =
          PreferencesService.toolApprovalAuto;
      await provider.createSession();
      provider.setAppInBackground(true);

      await provider.sendMessage('auto background');

      expect(provider.pendingApproval, isNull);
      expect(requestCount, 2);
      expect(tool.executionCount, 1);
      expect(nativeCalls, isNot(contains('showToolApprovalNotification')));
      expect(
        provider.currentSession!.messages
            .where((message) => message.isSystemNotice)
            .map((message) => message.textContent),
        isNot(contains(contains('启用系统通知'))),
      );
    });

    const nonInteractiveLifecycleStates = [
      'lifecycle-null',
      'inactive',
      'paused',
      'hidden',
      'detached',
      'screen-locked',
    ];
    for (final lifecycle in nonInteractiveLifecycleStates) {
      test(
          'auto policy bypasses approval surfaces in $lifecycle with notifications unavailable',
          () async {
        final nativeCalls = <String>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(nativeChannel, (call) async {
          nativeCalls.add(call.method);
          if (call.method == 'consumePendingNavigateToSession') return null;
          if (call.method == 'showToolApprovalNotification') return false;
          return true;
        });
        final tool = _EchoTool();
        var requestCount = 0;
        final provider = ChatProvider(
          toolRegistry: ToolRegistry()
            ..register(tool, risk: ToolRisk.dangerous),
          llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
            config,
            onMessages: (_) => throw UnimplementedError(),
            onMessageEvents: (_) {
              requestCount++;
              if (requestCount == 1) {
                return [
                  StreamDone(LlmResponse(
                    stopReason: 'tool_use',
                    content: [
                      ContentBlock(
                        type: 'tool_use',
                        toolUseId: 'auto_$lifecycle',
                        toolName: 'echo',
                        toolInput: {'text': lifecycle},
                      ),
                    ],
                  )),
                ];
              }
              return [
                StreamDone(const LlmResponse(
                  stopReason: 'end_turn',
                  content: [ContentBlock(type: 'text', text: 'done')],
                )),
              ];
            },
          ),
        );
        addTearDown(() async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          provider.dispose();
        });
        await Future<void>.delayed(const Duration(milliseconds: 50));
        PreferencesService().toolApprovalPolicy =
            PreferencesService.toolApprovalAuto;
        await provider.createSession();
        provider.setAppInBackground(true);

        await provider.sendMessage('auto $lifecycle');

        expect(provider.pendingApproval, isNull);
        expect(requestCount, 2);
        expect(tool.executionCount, 1);
        expect(nativeCalls, isNot(contains('showToolApprovalNotification')));
        expect(nativeCalls, isNot(contains('clearToolApprovalNotification')));
        expect(
          provider.currentSession!.messages
              .expand((message) => message.toolResults)
              .single
              .output,
          lifecycle,
        );
        expect(
          provider.currentSession!.messages
              .expand((message) => message.toolResults)
              .map((result) => result.output)
              .join('\n'),
          isNot(contains('blocked by safety settings')),
        );
        expect(
          provider.currentSession!.messages
              .where((message) => message.isSystemNotice)
              .map((message) => message.textContent),
          isNot(contains(contains('启用系统通知'))),
        );
      });
    }

    test('auto policy executes a valid non-visible session operation once',
        () async {
      final nativeCalls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativeChannel, (call) async {
        nativeCalls.add(call.method);
        if (call.method == 'consumePendingNavigateToSession') return null;
        if (call.method == 'showToolApprovalNotification') return false;
        return true;
      });
      final storage = SessionStorage();
      await storage.init();
      final tool = _EchoTool();
      var requestCount = 0;
      final provider = ChatProvider(
        storage: storage,
        toolRegistry: ToolRegistry()..register(tool, risk: ToolRisk.dangerous),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => throw UnimplementedError(),
          onMessageEvents: (_) {
            requestCount++;
            if (requestCount == 1) {
              return [
                StreamDone(const LlmResponse(
                  stopReason: 'tool_use',
                  content: [
                    ContentBlock(
                      type: 'tool_use',
                      toolUseId: 'auto_non_visible',
                      toolName: 'echo',
                      toolInput: {'text': 'non-visible-auto'},
                    ),
                  ],
                )),
              ];
            }
            return [
              StreamDone(const LlmResponse(
                stopReason: 'end_turn',
                content: [ContentBlock(type: 'text', text: 'done')],
              )),
            ];
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      PreferencesService().toolApprovalPolicy =
          PreferencesService.toolApprovalAuto;
      final target = await provider.createSession();
      final visible = await provider.createSession();
      provider.setAppInBackground(true);

      await provider.sendMessage(
        'auto non-visible',
        targetSessionId: target.id,
      );

      expect(provider.currentSession!.id, visible.id);
      expect(provider.pendingApproval, isNull);
      expect(requestCount, 2);
      expect(tool.executionCount, 1);
      expect(nativeCalls, isNot(contains('showToolApprovalNotification')));
      expect(
        (await storage.getSession(target.id))!
            .messages
            .expand((message) => message.toolResults)
            .single
            .output,
        'non-visible-auto',
      );
    });

    test('auto policy remains direct across lifecycle transitions', () async {
      final nativeCalls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativeChannel, (call) async {
        nativeCalls.add(call.method);
        if (call.method == 'consumePendingNavigateToSession') return null;
        if (call.method == 'showToolApprovalNotification') return false;
        return true;
      });
      final firstRequestStarted = Completer<void>();
      final releaseToolRequest = Completer<void>();
      final tool = _EchoTool();
      var gatedRequestCount = 0;
      final provider = ChatProvider(
        toolRegistry: ToolRegistry()..register(tool, risk: ToolRisk.dangerous),
        llmServiceFactory: (config, {isInBackground}) =>
            _GatedToolRequestLlmService(
          config,
          firstRequestStarted: firstRequestStarted,
          releaseToolRequest: releaseToolRequest,
          onRequest: () => ++gatedRequestCount,
        ),
      );
      addTearDown(() async {
        if (!releaseToolRequest.isCompleted) releaseToolRequest.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      PreferencesService().toolApprovalPolicy =
          PreferencesService.toolApprovalAuto;
      await provider.createSession();

      final send = provider.sendMessage('auto across transitions');
      await firstRequestStarted.future.timeout(const Duration(seconds: 2));
      provider.setAppInBackground(true);
      provider.setAppInBackground(false);
      provider.setAppInBackground(true);
      releaseToolRequest.complete();
      await send.timeout(const Duration(seconds: 5));

      expect(gatedRequestCount, 2);
      expect(provider.pendingApproval, isNull);
      expect(tool.executionCount, 1);
      expect(nativeCalls, isNot(contains('showToolApprovalNotification')));
      expect(nativeCalls, isNot(contains('clearToolApprovalNotification')));
    });

    test('auto policy stays direct after provider and activity recreation',
        () async {
      final nativeCalls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativeChannel, (call) async {
        nativeCalls.add(call.method);
        if (call.method == 'consumePendingNavigateToSession') return null;
        if (call.method == 'showToolApprovalNotification') return false;
        return true;
      });
      final storage = SessionStorage();
      await storage.init();
      final firstProvider = ChatProvider(storage: storage);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      PreferencesService().toolApprovalPolicy =
          PreferencesService.toolApprovalAuto;
      final session = await firstProvider.createSession();
      firstProvider.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final tool = _EchoTool();
      var requestCount = 0;
      final recreated = ChatProvider(
        storage: storage,
        toolRegistry: ToolRegistry()..register(tool, risk: ToolRisk.dangerous),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => throw UnimplementedError(),
          onMessageEvents: (_) {
            requestCount++;
            if (requestCount == 1) {
              return [
                StreamDone(const LlmResponse(
                  stopReason: 'tool_use',
                  content: [
                    ContentBlock(
                      type: 'tool_use',
                      toolUseId: 'auto_recreated',
                      toolName: 'echo',
                      toolInput: {'text': 'recreated-auto'},
                    ),
                  ],
                )),
              ];
            }
            return [
              StreamDone(const LlmResponse(
                stopReason: 'end_turn',
                content: [ContentBlock(type: 'text', text: 'done')],
              )),
            ];
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        recreated.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await recreated.selectSession(session.id);
      recreated.setAppInBackground(true);

      await recreated.sendMessage('auto after recreation');

      expect(recreated.pendingApproval, isNull);
      expect(requestCount, 2);
      expect(tool.executionCount, 1);
      expect(nativeCalls, isNot(contains('showToolApprovalNotification')));
      expect(nativeCalls, isNot(contains('clearToolApprovalNotification')));
    });

    test('auto policy does not override an explicit hard deny', () async {
      final tool = _EchoTool();
      var requestCount = 0;
      final provider = ChatProvider(
        toolRegistry: ToolRegistry()..register(tool, risk: ToolRisk.dangerous),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => throw UnimplementedError(),
          onMessageEvents: (_) {
            requestCount++;
            if (requestCount == 1) {
              return [
                StreamDone(const LlmResponse(
                  stopReason: 'tool_use',
                  content: [
                    ContentBlock(
                      type: 'tool_use',
                      toolUseId: 'auto_hard_deny',
                      toolName: 'echo',
                      toolInput: {'text': 'must-not-run'},
                    ),
                  ],
                )),
              ];
            }
            return [
              StreamDone(const LlmResponse(
                stopReason: 'end_turn',
                content: [ContentBlock(type: 'text', text: 'done')],
              )),
            ];
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final prefs = PreferencesService()
        ..toolApprovalPolicy = PreferencesService.toolApprovalAuto
        ..deniedToolNames = {'echo'};
      await provider.createSession();

      await provider.sendMessage('hard deny');

      expect(provider.pendingApproval, isNull);
      expect(tool.executionCount, 0);
      expect(
        provider.currentSession!.messages
            .expand((m) => m.toolResults)
            .single
            .output,
        'Tool blocked by safety settings.',
      );
      prefs.deniedToolNames = {};
    });

    test('foreground current session keeps explicit approval path', () async {
      var requestCount = 0;
      final tools = ToolRegistry()
        ..register(_EchoTool(), risk: ToolRisk.dangerous);
      final provider = ChatProvider(
        toolRegistry: tools,
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => throw UnimplementedError(),
          onMessageEvents: (_) {
            requestCount++;
            if (requestCount == 1) {
              return [
                StreamDone(const LlmResponse(
                  stopReason: 'tool_use',
                  content: [
                    ContentBlock(
                      type: 'tool_use',
                      toolUseId: 'call_1',
                      toolName: 'echo',
                      toolInput: {'text': 'approved'},
                    ),
                  ],
                )),
              ];
            }
            return [
              StreamDone(const LlmResponse(
                stopReason: 'end_turn',
                content: [ContentBlock(type: 'text', text: 'done')],
              )),
            ];
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await provider.createSession();
      final sendFuture = provider.sendMessage('use tool');
      await _waitUntil(() => provider.pendingApproval != null);
      provider.resolveToolApproval(
        operationId: provider.pendingApproval!.operationId,
        approved: true,
      );
      await sendFuture;

      expect(requestCount, 2);
      final toolResult =
          provider.currentSession!.messages.expand((m) => m.toolResults).single;
      expect(toolResult.output, 'approved');
    });

    test('allow once does not silently become a session policy', () async {
      var requestCount = 0;
      final tool = _EchoTool();
      final provider = ChatProvider(
        toolRegistry: ToolRegistry()..register(tool, risk: ToolRisk.dangerous),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => throw UnimplementedError(),
          onMessageEvents: (_) {
            requestCount++;
            if (requestCount.isOdd) {
              return [
                StreamDone(LlmResponse(
                  stopReason: 'tool_use',
                  content: [
                    ContentBlock(
                      type: 'tool_use',
                      toolUseId: 'call_$requestCount',
                      toolName: 'echo',
                      toolInput: const {'text': 'approved once'},
                    ),
                  ],
                )),
              ];
            }
            return [
              StreamDone(const LlmResponse(
                stopReason: 'end_turn',
                content: [ContentBlock(type: 'text', text: 'done')],
              )),
            ];
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      PreferencesService().toolApprovalPolicy =
          PreferencesService.toolApprovalSessionFirst;
      await provider.createSession();

      final first = provider.sendMessage('first');
      await _waitUntil(() => provider.pendingApproval != null);
      provider.resolveToolApproval(
        operationId: provider.pendingApproval!.operationId,
        approved: true,
      );
      await first;

      final second = provider.sendMessage('second');
      await _waitUntil(() => provider.pendingApproval != null);
      expect(tool.executionCount, 1);
      provider.resolveToolApproval(
        operationId: provider.pendingApproval!.operationId,
        approved: false,
      );
      await second;
      expect(tool.executionCount, 1);
    });

    test('new environment secret is redacted before approval and persistence',
        () async {
      const sentinel = 'provider-new-secret-sentinel';
      var requestCount = 0;
      final prefs = PreferencesService();
      final storage = SessionStorage();
      await storage.init();
      final provider = ChatProvider(
        storage: storage,
        toolRegistry: ToolRegistry()
          ..register(EnvVarTool(prefs), risk: ToolRisk.moderate),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => throw UnimplementedError(),
          onMessageEvents: (_) {
            requestCount++;
            if (requestCount == 1) {
              return [
                TextDelta('visible $sentinel'),
                ReasoningDelta('reasoning $sentinel'),
                ToolUseStart('set_secret_1', 'set_env_var'),
                ToolInputDelta(
                  '{"name":"NEW_PROVIDER_TOKEN","value":"$sentinel"}',
                ),
                StreamDone(const LlmResponse(
                  stopReason: 'tool_use',
                  content: [
                    ContentBlock(
                      type: 'tool_use',
                      toolUseId: 'set_secret_1',
                      toolName: 'set_env_var',
                      toolInput: {
                        'name': 'NEW_PROVIDER_TOKEN',
                        'value': sentinel,
                      },
                    ),
                  ],
                )),
              ];
            }
            return [
              StreamDone(const LlmResponse(
                stopReason: 'end_turn',
                content: [ContentBlock(type: 'text', text: 'done')],
              )),
            ];
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final session = await provider.createSession();
      final transientUiSnapshots = <String>[];
      provider.addListener(() {
        transientUiSnapshots.add(
          '${provider.streamingText}\n${provider.streamingReasoningText}',
        );
      });
      final sendFuture = provider.sendMessage('configure integration');
      await _waitUntil(() => provider.pendingApproval != null);

      expect(provider.pendingApproval!.arguments, {
        'name': 'NEW_PROVIDER_TOKEN',
        'value': ToolUseContent.redactedSecretValue,
      });
      expect(provider.streamingText, isNot(contains(sentinel)));
      expect(provider.streamingReasoningText, isNot(contains(sentinel)));
      expect(transientUiSnapshots.join('\n'), isNot(contains(sentinel)));
      expect(provider.currentSession!.toJson().toString(),
          isNot(contains(sentinel)));
      final approvalPendingOnDisk = await storage.getSession(session.id);
      expect(approvalPendingOnDisk!.toJson().toString(),
          isNot(contains(sentinel)));
      expect(await storage.searchSessions(sentinel), isEmpty);

      provider.resolveToolApproval(
        operationId: provider.pendingApproval!.operationId,
        approved: true,
      );
      await sendFuture;
      await prefs.init();

      expect(prefs.envVars['NEW_PROVIDER_TOKEN'], sentinel);
      final persisted = await storage.getSession(session.id);
      expect(persisted!.toJson().toString(), isNot(contains(sentinel)));
      expect(await storage.searchSessions(sentinel), isEmpty);
      expect(
        persisted.messages
            .expand((message) => message.toolUses)
            .single
            .input['value'],
        ToolUseContent.redactedSecretValue,
      );
      expect(secureStorage.values.join(), contains(sentinel));
      expect(
        provider.runtimeDebugEvents.recent(sessionId: session.id).toString(),
        isNot(contains(sentinel)),
      );
    });

    test('secret-setting stream error discards guarded UI and stored bytes',
        () async {
      const sentinel = 'provider-stream-error-private-value';
      final storage = SessionStorage();
      await storage.init();
      final events = RuntimeDebugEventService(tracingEnabled: true);
      final provider = ChatProvider(
        storage: storage,
        runtimeDebugEvents: events,
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => throw UnimplementedError(),
          onMessageEvents: (_) => [
            TextDelta('visible $sentinel'),
            ReasoningDelta('reasoning $sentinel'),
            ToolUseStart('set_secret_error', 'set_env_var'),
            ToolInputDelta(
              '{"name":"ERROR_TOKEN","value":"$sentinel"}',
            ),
            StreamError('stream interrupted'),
          ],
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final session = await provider.createSession();
      final transientUiSnapshots = <String>[];
      provider.addListener(() {
        transientUiSnapshots.add(
          '${provider.streamingText}\n${provider.streamingReasoningText}',
        );
      });

      await provider.sendMessage('configure integration');

      final stored = await storage.getSession(session.id);
      final diagnostics = await provider.buildDiagnosticsReport();
      expect(provider.errorMessage, isNotNull);
      expect(transientUiSnapshots.join('\n'), isNot(contains(sentinel)));
      expect(provider.currentSession!.toJson().toString(),
          isNot(contains(sentinel)));
      expect(stored!.toJson().toString(), isNot(contains(sentinel)));
      expect(await storage.searchSessions(sentinel), isEmpty);
      expect(events.recent(sessionId: session.id).toString(),
          isNot(contains(sentinel)));
      expect(diagnostics, isNot(contains(sentinel)));
    });

    test('cancel discards guarded secret bytes before any durable output',
        () async {
      const sentinel = 'provider-cancelled-private-value';
      final storage = SessionStorage();
      await storage.init();
      final buffered = Completer<void>();
      final release = Completer<void>();
      final events = RuntimeDebugEventService(tracingEnabled: true);
      final provider = ChatProvider(
        storage: storage,
        runtimeDebugEvents: events,
        llmServiceFactory: (config, {isInBackground}) =>
            _GuardedSecretPauseLlmService(
          config,
          sentinel: sentinel,
          buffered: buffered,
          release: release,
        ),
      );
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final session = await provider.createSession();
      final transientUiSnapshots = <String>[];
      provider.addListener(() {
        transientUiSnapshots.add(
          '${provider.streamingText}\n${provider.streamingReasoningText}',
        );
      });
      final sendFuture = provider.sendMessage('configure integration');
      await buffered.future.timeout(const Duration(seconds: 2));

      final cancelFuture = provider.cancelAgent(
        sessionId: session.id,
        savePartial: true,
      );
      release.complete();
      await cancelFuture;
      await sendFuture;

      final stored = await storage.getSession(session.id);
      final diagnostics = await provider.buildDiagnosticsReport();
      expect(transientUiSnapshots.join('\n'), isNot(contains(sentinel)));
      expect(provider.currentSession!.toJson().toString(),
          isNot(contains(sentinel)));
      expect(stored!.toJson().toString(), isNot(contains(sentinel)));
      expect(await storage.searchSessions(sentinel), isEmpty);
      expect(events.recent(sessionId: session.id).toString(),
          isNot(contains(sentinel)));
      expect(diagnostics, isNot(contains(sentinel)));
    });

    test('approval fails closed when current session changes', () async {
      var requestCount = 0;
      final storage = SessionStorage();
      await storage.init();
      final tool = _EchoTool();
      final provider = ChatProvider(
        storage: storage,
        toolRegistry: ToolRegistry()..register(tool, risk: ToolRisk.dangerous),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => throw UnimplementedError(),
          onMessageEvents: (_) {
            requestCount++;
            if (requestCount == 1) {
              return [
                StreamDone(const LlmResponse(
                  stopReason: 'tool_use',
                  content: [
                    ContentBlock(
                      type: 'tool_use',
                      toolUseId: 'call_1',
                      toolName: 'echo',
                      toolInput: {'text': 'must not execute'},
                    ),
                  ],
                )),
              ];
            }
            return [
              StreamDone(const LlmResponse(
                stopReason: 'end_turn',
                content: [ContentBlock(type: 'text', text: 'done')],
              )),
            ];
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final original = await provider.createSession();
      final sendFuture = provider.sendMessage('use tool');
      await _waitUntil(() => provider.pendingApproval != null);
      await provider.createSession();
      provider.resolveToolApproval(
        operationId: provider.pendingApproval!.operationId,
        approved: true,
      );
      await sendFuture;

      expect(tool.executionCount, 0);
      final stored = await storage.getSession(original.id);
      expect(
          stored!.messages
              .expand((message) => message.toolResults)
              .single
              .isError,
          isTrue);
    });
  });

  group('agent cancellation', () {
    setUp(() async {
      await installPlatformMocks();
      configureAnthropicProfile(baseUrl: 'http://127.0.0.1');
    });

    tearDown(() async {
      await clearPlatformMocks();
    });

    test('cancelAgent disposes active LLM request client', () async {
      final streamStarted = Completer<void>();
      final releaseStream = Completer<void>();
      final llmDisposed = Completer<void>();
      final provider = ChatProvider(
        llmServiceFactory: (config, {isInBackground}) => _BlockingLlmService(
          config,
          started: streamStarted,
          release: releaseStream,
          disposed: llmDisposed,
        ),
      );
      addTearDown(() async {
        if (!releaseStream.isCompleted) releaseStream.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final session = await provider.createSession();
      final sendFuture = provider.sendMessage('slow prompt');
      await streamStarted.future;

      await provider.cancelAgent(sessionId: session.id);

      await llmDisposed.future.timeout(const Duration(seconds: 1));
      expect(provider.isSessionSending(session.id), isFalse);
      await sendFuture;
    });

    test('active run marker stays durable but is not exposed as interrupted',
        () async {
      final streamStarted = Completer<void>();
      final releaseStream = Completer<void>();
      final storage = SessionStorage();
      await storage.init();
      final provider = ChatProvider(
        storage: storage,
        llmServiceFactory: (config, {isInBackground}) => _BlockingLlmService(
          config,
          started: streamStarted,
          release: releaseStream,
        ),
      );
      addTearDown(() async {
        if (!releaseStream.isCompleted) releaseStream.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final session = await provider.createSession();
      final sendFuture = provider.sendMessage('slow prompt');
      await streamStarted.future.timeout(const Duration(seconds: 2));

      expect(
        (await storage.getSession(session.id))!.inFlightAgentRun,
        isNotNull,
      );
      expect(provider.currentInterruptedAgentRun, isNull);

      await provider.cancelAgent(sessionId: session.id, savePartial: false);
      await sendFuture.timeout(const Duration(seconds: 2));
      await _waitUntil(() => !provider.isSessionSending(session.id));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        (await storage.getSession(session.id))!.inFlightAgentRun,
        isNull,
      );
    });

    test('rapid session switch hides owned run and reloads completion cleanly',
        () async {
      final streamStarted = Completer<void>();
      final releaseStream = Completer<void>();
      final storage = SessionStorage();
      await storage.init();
      final provider = ChatProvider(
        storage: storage,
        llmServiceFactory: (config, {isInBackground}) => _BlockingLlmService(
          config,
          started: streamStarted,
          release: releaseStream,
        ),
      );
      addTearDown(() async {
        if (!releaseStream.isCompleted) releaseStream.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final runningSession = await provider.createSession();
      final sendFuture = provider.sendMessage('switch while running');
      await streamStarted.future.timeout(const Duration(seconds: 2));
      final otherSession = await provider.createSession();

      await provider.selectSession(runningSession.id);
      expect(provider.isSessionSending(runningSession.id), isTrue);
      expect(provider.currentInterruptedAgentRun, isNull);
      await provider.selectSession(otherSession.id);

      releaseStream.complete();
      await sendFuture.timeout(const Duration(seconds: 2));
      await provider.selectSession(runningSession.id);

      expect(provider.currentSession!.messages.last.textContent, 'done');
      expect(provider.currentInterruptedAgentRun, isNull);
      expect(
        (await storage.getSession(runningSession.id))!.inFlightAgentRun,
        isNull,
      );
    });

    test('cancel during dangerous tool preserves unknown evidence', () async {
      final storage = SessionStorage();
      await storage.init();
      final tool = _BlockingDangerousTool();
      final events = RuntimeDebugEventService();
      var requestCount = 0;
      final provider = ChatProvider(
        storage: storage,
        runtimeDebugEvents: events,
        toolRegistry: ToolRegistry()..register(tool, risk: ToolRisk.dangerous),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) {
            requestCount++;
            if (requestCount == 1) {
              return StreamDone(const LlmResponse(
                stopReason: 'tool_use',
                content: [
                  ContentBlock(
                    type: 'tool_use',
                    toolUseId: 'slow_call',
                    toolName: 'slow_dangerous',
                    toolInput: {'value': 'must not leak'},
                  ),
                ],
              ));
            }
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'unexpected')],
            ));
          },
        ),
      );
      addTearDown(() async {
        if (!tool.release.isCompleted) tool.release.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final session = await provider.createSession();
      final sendFuture = provider.sendMessage('start slow tool');
      await _waitUntil(() => provider.pendingApproval != null);
      provider.resolveToolApproval(
        operationId: provider.pendingApproval!.operationId,
        approved: true,
      );
      await tool.started.future;

      await provider.cancelAgent(sessionId: session.id, savePartial: false);

      expect(provider.isSessionSending(session.id), isFalse);
      var stored = await storage.getSession(session.id);
      final cancelledMarker = stored!.inFlightAgentRun!;
      expect(cancelledMarker.recoveryKind,
          InterruptedRunRecoveryKind.unknownOutcome);
      expect(cancelledMarker.toolAttempts.single.lifecycle,
          ToolAttemptLifecycle.interruptedUnknown);
      expect(stored.messages.expand((message) => message.toolResults), isEmpty);
      expect(
        events
            .recent(sessionId: session.id)
            .where((event) => event.type == 'tool.attempt.interruptedUnknown'),
        hasLength(1),
      );
      expect(
        events
            .recent(sessionId: session.id)
            .where((event) => event.type == 'chat.run.cancelled'),
        hasLength(1),
      );
      expect(
          events
              .recent(sessionId: session.id)
              .map((event) => event.data)
              .toString(),
          isNot(contains('must not leak')));
      final trace = events.recentRunTraces(sessionId: session.id).single;
      expect(trace.status, RunTraceStatus.cancelled);
      expect(
        trace.events.where((event) => event.type == 'run.terminal'),
        hasLength(1),
      );
      expect(
        trace.events.map((event) => event.type),
        contains('tool.attempt.interruptedUnknown'),
      );
      expect(trace.events.toString(), isNot(contains('must not leak')));

      final reloaded = ChatProvider(storage: storage);
      addTearDown(reloaded.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await reloaded.selectSession(session.id);
      expect(reloaded.currentInterruptedAgentRun!.recoveryKind,
          InterruptedRunRecoveryKind.unknownOutcome);
      expect(tool.executionCount, 1);

      tool.release.complete();
      await sendFuture.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      stored = await storage.getSession(session.id);
      expect(stored!.inFlightAgentRun!.toolAttempts.single.lifecycle,
          ToolAttemptLifecycle.interruptedUnknown);
      expect(stored.messages.expand((message) => message.toolResults), isEmpty);
      expect(tool.executionCount, 1);
    });

    test('delete during non-cancellable tool cannot resurrect session',
        () async {
      final storage = SessionStorage();
      await storage.init();
      final tool = _BlockingDangerousTool();
      var requestCount = 0;
      final provider = ChatProvider(
        storage: storage,
        toolRegistry: ToolRegistry()..register(tool, risk: ToolRisk.dangerous),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) {
            requestCount++;
            if (requestCount == 1) {
              return StreamDone(const LlmResponse(
                stopReason: 'tool_use',
                content: [
                  ContentBlock(
                    type: 'tool_use',
                    toolUseId: 'delete_slow_call',
                    toolName: 'slow_dangerous',
                    toolInput: {'value': 'delete'},
                  ),
                ],
              ));
            }
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'late completion')],
            ));
          },
        ),
      );
      addTearDown(() async {
        if (!tool.release.isCompleted) tool.release.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final session = await provider.createSession();
      final send = provider.sendMessage('delete running session');
      await _waitUntil(() => provider.pendingApproval != null);
      provider.resolveToolApproval(
        operationId: provider.pendingApproval!.operationId,
        approved: true,
      );
      await tool.started.future.timeout(const Duration(seconds: 2));

      await provider.deleteSession(session.id);

      expect(storage.isSessionTombstoned(session.id), isTrue);
      expect(await storage.getSession(session.id), isNull);
      tool.release.complete();
      await send.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await storage.getSession(session.id), isNull);
      final reloadedStorage = SessionStorage();
      await reloadedStorage.init();
      expect(await reloadedStorage.getSession(session.id), isNull);
    });

    test('confirmed cancellable tool abort records known failure', () async {
      final storage = SessionStorage();
      await storage.init();
      final tool = _CancellableDangerousTool();
      final events = RuntimeDebugEventService();
      var requestCount = 0;
      final provider = ChatProvider(
        storage: storage,
        runtimeDebugEvents: events,
        toolRegistry: ToolRegistry()..register(tool, risk: ToolRisk.dangerous),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) {
            requestCount++;
            if (requestCount == 1) {
              return StreamDone(const LlmResponse(
                stopReason: 'tool_use',
                content: [
                  ContentBlock(
                    type: 'tool_use',
                    toolUseId: 'cancel_call',
                    toolName: 'cancellable_http',
                    toolInput: {'value': 'private'},
                  ),
                ],
              ));
            }
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'unexpected')],
            ));
          },
        ),
      );
      addTearDown(() async {
        if (!tool.confirmAbort.isCompleted) tool.confirmAbort.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final session = await provider.createSession();
      final sendFuture = provider.sendMessage('start cancellable tool');
      await _waitUntil(() => provider.pendingApproval != null);
      provider.resolveToolApproval(
        operationId: provider.pendingApproval!.operationId,
        approved: true,
      );
      await tool.started.future;

      await provider.cancelAgent(sessionId: session.id, savePartial: false);
      expect(
        (await storage.getSession(session.id))!
            .inFlightAgentRun!
            .toolAttempts
            .single
            .lifecycle,
        ToolAttemptLifecycle.interruptedUnknown,
      );

      tool.confirmAbort.complete();
      await tool.abortReported.future;
      await _waitUntil(() {
        final marker = provider.currentInterruptedAgentRun;
        return marker?.toolAttempts.single.lifecycle ==
            ToolAttemptLifecycle.failed;
      });
      await sendFuture.timeout(const Duration(seconds: 2));
      await _waitUntilAsync(() async {
        final marker = (await storage.getSession(session.id))?.inFlightAgentRun;
        return marker?.toolAttempts.single.lifecycle ==
            ToolAttemptLifecycle.failed;
      });

      final stored = await storage.getSession(session.id);
      final attempt = stored!.inFlightAgentRun!.toolAttempts.single;
      expect(attempt.lifecycle, ToolAttemptLifecycle.failed);
      expect(attempt.executionOutcomeKnown, isTrue);
      expect(stored.messages.expand((message) => message.toolResults), isEmpty);
      expect(
        events.recent(sessionId: session.id).where(
              (event) => event.type == 'tool.attempt.interruptedUnknown',
            ),
        hasLength(1),
      );
      expect(
        events.recent(sessionId: session.id).where(
              (event) => event.type == 'tool.attempt.failed',
            ),
        hasLength(1),
      );
      final cancelledEvents = events.recent(sessionId: session.id).where(
            (event) => event.type == 'chat.run.cancelled',
          );
      expect(cancelledEvents, hasLength(1));
      expect(cancelledEvents.single.data['lifecycle'], 'interruptedUnknown');
      final trace = events.recentRunTraces(sessionId: session.id).single;
      expect(trace.status, RunTraceStatus.cancelled);
      expect(
        trace.events.where((event) => event.type == 'run.terminal'),
        hasLength(1),
      );
    });

    test('late run A finalization cannot mutate recovery run C', () async {
      var armedCommits = 0;
      var armFinalSave = false;
      final finalSaveEntered = Completer<void>();
      final releaseFinalSave = Completer<void>();
      final storage = SessionStorage(beforeCommitForTesting: (_) async {
        if (!armFinalSave) return;
        armedCommits++;
        if (armedCommits == 3) {
          finalSaveEntered.complete();
          await releaseFinalSave.future;
        }
      });
      await storage.init();
      final events = RuntimeDebugEventService();
      final tool = _EchoTool();
      var factoryCount = 0;
      var recoveryRequestCount = 0;
      final provider = ChatProvider(
        storage: storage,
        runtimeDebugEvents: events,
        toolRegistry: ToolRegistry()..register(tool, risk: ToolRisk.dangerous),
        llmServiceFactory: (config, {isInBackground}) {
          factoryCount++;
          if (factoryCount == 1) {
            return _ScriptedLlmService(
              config,
              onMessages: (_) => StreamDone(const LlmResponse(
                stopReason: 'end_turn',
                content: [ContentBlock(type: 'text', text: 'A complete')],
              )),
            );
          }
          return _ScriptedLlmService(
            config,
            onMessages: (_) {
              recoveryRequestCount++;
              if (recoveryRequestCount == 1) {
                return StreamDone(const LlmResponse(
                  stopReason: 'tool_use',
                  content: [
                    ContentBlock(
                      type: 'tool_use',
                      toolUseId: 'run_c_tool',
                      toolName: 'echo',
                      toolInput: {'text': 'run C'},
                    ),
                  ],
                ));
              }
              return StreamDone(const LlmResponse(
                stopReason: 'end_turn',
                content: [ContentBlock(type: 'text', text: 'C complete')],
              ));
            },
          );
        },
      );
      addTearDown(() async {
        if (!releaseFinalSave.isCompleted) releaseFinalSave.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      PreferencesService().toolApprovalPolicy =
          PreferencesService.toolApprovalAlways;
      final session = await provider.createSession();
      armFinalSave = true;
      final runA = provider.sendMessage('run A');
      await finalSaveEntered.future.timeout(const Duration(seconds: 2));
      final runATrace = events.recentRunTraces(sessionId: session.id).single;
      final runAId = runATrace.events.first.data['runAttemptId'];

      await provider.cancelAgent(sessionId: session.id, savePartial: false);
      await runA;

      final runC = provider.sendMessage('run C');
      await _waitUntil(() => provider.isSessionSending(session.id));
      unawaited(provider.sendMessage('queued after C'));
      await _waitUntil(() => provider.messageQueue.length == 1);
      releaseFinalSave.complete();
      await _waitUntil(() => provider.pendingApproval != null);

      expect(provider.isSessionSending(session.id), isTrue);
      expect(provider.messageQueue.single.text, 'queued after C');
      expect(provider.pendingApproval!.runAttemptId, isNot(runAId));
      final traces = events.recentRunTraces(sessionId: session.id);
      expect(traces, hasLength(2));
      expect(traces.first.status, RunTraceStatus.cancelled);
      expect(traces.last.status, RunTraceStatus.inFlight);
      expect(
        traces.first.events.where((event) => event.type == 'run.terminal'),
        hasLength(1),
      );

      provider.clearMessageQueue();
      provider.resolveToolApproval(
        operationId: provider.pendingApproval!.operationId,
        approved: true,
      );
      await runC.timeout(const Duration(seconds: 2));

      expect(tool.executionCount, 1);
      expect(provider.isSessionSending(session.id), isFalse);
      expect(provider.pendingApproval, isNull);
      final completedTraces = events.recentRunTraces(sessionId: session.id);
      expect(completedTraces.last.status, RunTraceStatus.completed);
      for (final trace in completedTraces) {
        expect(
          trace.events.where((event) => event.type == 'run.terminal'),
          hasLength(1),
        );
      }
    });
  });

  group('persistent assistant error retry state', () {
    setUp(() async {
      await installPlatformMocks();
      configureAnthropicProfile(baseUrl: 'http://127.0.0.1');
    });

    tearDown(() async {
      await clearPlatformMocks();
    });

    test('normal successful response stays clear after storage reload',
        () async {
      final storage = SessionStorage();
      await storage.init();
      final provider = ChatProvider(
        storage: storage,
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => StreamDone(const LlmResponse(
            stopReason: 'end_turn',
            content: [ContentBlock(type: 'text', text: 'completed normally')],
          )),
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final session = await provider.createSession();
      await provider.sendMessage('normal request');

      expect(provider.currentInterruptedAgentRun, isNull);
      expect((await storage.getSession(session.id))!.inFlightAgentRun, isNull);

      final reloaded = ChatProvider(storage: storage);
      addTearDown(reloaded.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await reloaded.selectSession(session.id);
      expect(reloaded.currentSession!.messages.last.textContent,
          'completed normally');
      expect(reloaded.currentInterruptedAgentRun, isNull);
    });

    test('reload retains marker when text has no positive terminal proof',
        () async {
      final storage = SessionStorage();
      await storage.init();
      final startedAt = DateTime.utc(2026, 7, 11, 8);
      final session = ChatSession(
        id: 'stale-text-terminal',
        messages: [
          ChatMessage.user('normal request'),
          ChatMessage(
            role: 'assistant',
            content: [TextContent('durable completed response')],
            timestamp: startedAt.add(const Duration(seconds: 1)),
          ),
        ],
        inFlightAgentRun: AgentRunRecoveryMarker(
          runAttemptId: 'stale-text-run',
          startedAt: startedAt,
          updatedAt: startedAt,
        ),
      );
      await storage.saveSession(session);
      final provider = ChatProvider(storage: storage);
      addTearDown(provider.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await provider.selectSession(session.id);

      expect(provider.currentInterruptedAgentRun, isNotNull);
      expect(
        (await storage.getSession(session.id))!.inFlightAgentRun!.runAttemptId,
        'stale-text-run',
      );
    });

    test('reload keeps marker across partial text and assistant error',
        () async {
      final storage = SessionStorage();
      await storage.init();
      final startedAt = DateTime.utc(2026, 7, 10, 8);
      final session = ChatSession(
        id: 'partial-error-keeps-marker',
        messages: [
          ChatMessage.user('normal request'),
          ChatMessage(
            role: 'assistant',
            content: [TextContent('partial response')],
            timestamp: startedAt.add(const Duration(seconds: 1)),
          ),
          ChatMessage.assistantError(
            error: const AssistantErrorMetadata(
              message: 'provider unavailable',
              code: 'provider_unavailable',
              canRetry: true,
              retryAction: AssistantRetryAction.continueRecovery,
              recoveryRunAttemptId: 'partial-error-run',
            ),
            timestamp: startedAt.add(const Duration(seconds: 2)),
          ),
        ],
        inFlightAgentRun: AgentRunRecoveryMarker(
          runAttemptId: 'partial-error-run',
          startedAt: startedAt,
          updatedAt: startedAt,
        ),
      );
      await storage.saveSession(session);
      final provider = ChatProvider(storage: storage);
      addTearDown(provider.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await provider.selectSession(session.id);

      expect(provider.currentInterruptedAgentRun, isNotNull);
      expect(provider.errorMessage, 'provider unavailable');
      expect(
        (await storage.getSession(session.id))!.inFlightAgentRun!.runAttemptId,
        'partial-error-run',
      );
    });

    test('failed terminal clear stays recoverable after reload', () async {
      var commitCount = 0;
      final storage = SessionStorage(beforeCommitForTesting: (_) async {
        commitCount++;
        if (commitCount == 4) {
          throw StateError('injected terminal clear failure');
        }
      });
      await storage.init();
      final provider = ChatProvider(
        storage: storage,
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => StreamDone(const LlmResponse(
            stopReason: 'end_turn',
            content: [ContentBlock(type: 'text', text: 'durable terminal')],
          )),
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final session = await provider.createSession();
      await provider.sendMessage('normal request');

      final stale = await storage.getSession(session.id);
      expect(stale!.messages.last.textContent, 'durable terminal');
      expect(stale.inFlightAgentRun, isNotNull);

      final reloaded = ChatProvider(storage: storage);
      addTearDown(reloaded.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await reloaded.selectSession(session.id);

      expect(reloaded.currentInterruptedAgentRun, isNotNull);
      expect(
        (await storage.getSession(session.id))!.inFlightAgentRun!.runAttemptId,
        stale.inFlightAgentRun!.runAttemptId,
      );
    });

    test('reload keeps result evidence without inferring terminal from text',
        () async {
      final storage = SessionStorage();
      await storage.init();
      final startedAt = DateTime.utc(2026, 7, 11, 9);
      final session = ChatSession(
        id: 'stale-tool-terminal',
        messages: [
          ChatMessage.user('tool request'),
          ChatMessage(
            role: 'assistant',
            content: [
              ToolUseContent(
                id: 'tool-call',
                name: 'echo',
                input: const {'text': 'safe'},
              ),
            ],
            timestamp: startedAt.add(const Duration(seconds: 1)),
          ),
          ChatMessage(
            role: 'user',
            content: [
              ToolResultContent(
                toolUseId: 'tool-call',
                output: 'safe',
                metadata: const {'operationId': 'tool-operation'},
              ),
            ],
            timestamp: startedAt.add(const Duration(seconds: 2)),
          ),
          ChatMessage(
            role: 'assistant',
            content: [TextContent('tool completed normally')],
            timestamp: startedAt.add(const Duration(seconds: 3)),
          ),
        ],
        inFlightAgentRun: AgentRunRecoveryMarker(
          runAttemptId: 'stale-tool-run',
          startedAt: startedAt,
          updatedAt: startedAt.add(const Duration(seconds: 1)),
          phase: AgentRunRecoveryPhase.toolInFlight,
          toolAttempts: [
            ToolAttemptRecoveryMetadata(
              operationId: 'tool-operation',
              toolName: 'echo',
              risk: RecoveryToolRisk.safe,
              lifecycle: ToolAttemptLifecycle.completed,
              proposedAt: startedAt,
              updatedAt: startedAt.add(const Duration(seconds: 1)),
              executionStartedAt: startedAt,
              executionOutcomeKnown: true,
            ),
          ],
        ),
      );
      await storage.saveSession(session);
      final provider = ChatProvider(storage: storage);
      addTearDown(provider.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await provider.selectSession(session.id);

      expect(provider.currentInterruptedAgentRun, isNotNull);
      expect(
        provider.currentInterruptedAgentRun!.toolAttempts.single.lifecycle,
        ToolAttemptLifecycle.resultPersisted,
      );
      expect(
        (await storage.getSession(session.id))!
            .inFlightAgentRun!
            .toolAttempts
            .single
            .lifecycle,
        ToolAttemptLifecycle.resultPersisted,
      );
    });

    test('backgrounded normal run completes without recovery on reload',
        () async {
      final storage = SessionStorage();
      await storage.init();
      final provider = ChatProvider(
        storage: storage,
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => StreamDone(const LlmResponse(
            stopReason: 'end_turn',
            content: [ContentBlock(type: 'text', text: 'background complete')],
          )),
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final session = await provider.createSession();
      provider.setAppInBackground(true);
      await provider.sendMessage('finish in background');
      provider.setAppInBackground(false);

      final reloaded = ChatProvider(storage: storage);
      addTearDown(reloaded.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await reloaded.selectSession(session.id);
      expect(reloaded.currentInterruptedAgentRun, isNull);
      expect((await storage.getSession(session.id))!.inFlightAgentRun, isNull);
    });

    test('successful tool run stays clear after storage reload', () async {
      final storage = SessionStorage();
      await storage.init();
      final tool = _EchoTool();
      var requestCount = 0;
      final provider = ChatProvider(
        storage: storage,
        toolRegistry: ToolRegistry()..register(tool, risk: ToolRisk.safe),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) {
            requestCount++;
            if (requestCount == 1) {
              return StreamDone(const LlmResponse(
                stopReason: 'tool_use',
                content: [
                  ContentBlock(
                    type: 'tool_use',
                    toolUseId: 'echo-call',
                    toolName: 'echo',
                    toolInput: {'text': 'safe'},
                  ),
                ],
              ));
            }
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'tool done')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final session = await provider.createSession();
      await provider.sendMessage('use safe tool');

      expect(tool.executionCount, 1);
      expect(provider.currentInterruptedAgentRun, isNull);
      expect((await storage.getSession(session.id))!.inFlightAgentRun, isNull);

      final reloaded = ChatProvider(storage: storage);
      addTearDown(reloaded.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await reloaded.selectSession(session.id);
      expect(reloaded.currentInterruptedAgentRun, isNull);
    });

    test('reload restores sanitized provider failure retry state', () async {
      final storage = SessionStorage();
      await storage.init();
      const sensitiveCredential = 'credential-value-that-must-not-persist';
      final firstProvider = ChatProvider(
        storage: storage,
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => StreamError(
            'OpenAI API error (503): api_key=$sensitiveCredential unavailable',
            cause: Exception(
              'OpenAI API error (503): api_key=$sensitiveCredential unavailable',
            ),
          ),
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        firstProvider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final session = await firstProvider.createSession();
      await firstProvider.sendMessage('hello');

      final failed = firstProvider.currentSession!.messages.last;
      expect(failed.hasAssistantError, isTrue);
      expect(failed.assistantError!.canRetry, isTrue);
      expect(failed.assistantError!.message, contains('[redacted: api_key]'));
      expect(
        failed.assistantError!.message,
        isNot(contains(sensitiveCredential)),
      );
      expect(firstProvider.currentSession!.toApiMessages(), [
        {'role': 'user', 'content': 'hello'},
      ]);
      expect(firstProvider.currentInterruptedAgentRun, isNull);
      expect((await storage.getSession(session.id))!.inFlightAgentRun, isNull);

      final secondProvider = ChatProvider(
        storage: storage,
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => StreamDone(const LlmResponse(
            stopReason: 'end_turn',
            content: [ContentBlock(type: 'text', text: 'unused')],
          )),
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        secondProvider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await secondProvider.selectSession(session.id);

      expect(secondProvider.agentStatus, AgentStatus.error);
      expect(secondProvider.errorMessage, contains('[redacted: api_key]'));
      expect(
        secondProvider.errorMessage,
        isNot(contains(sensitiveCredential)),
      );
      expect(secondProvider.currentSession!.messages.last.hasAssistantError,
          isTrue);
      expect(secondProvider.currentInterruptedAgentRun, isNull);
    });

    test('dismiss interrupted run marker clears persisted state', () async {
      final storage = SessionStorage();
      await storage.init();
      final session = ChatSession(
        id: 'interrupted-dismiss',
        messages: [ChatMessage.user('original task')],
        inFlightAgentRun: AgentRunRecoveryMarker(
          runAttemptId: 'dismiss-run',
          startedAt: DateTime.utc(2026, 7, 7),
          updatedAt: DateTime.utc(2026, 7, 7),
        ),
      );
      await storage.saveSession(session);
      final provider = ChatProvider(storage: storage);
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await provider.selectSession(session.id);
      expect(provider.currentInterruptedAgentRun, isNotNull);

      await provider.dismissInterruptedAgentRun();

      expect(provider.currentInterruptedAgentRun, isNull);
      expect((await storage.getSession(session.id))!.inFlightAgentRun, isNull);
    });

    test('continue interrupted run injects recovery prompt and clears marker',
        () async {
      final storage = SessionStorage();
      await storage.init();
      final session = ChatSession(
        id: 'interrupted-continue',
        messages: [ChatMessage.user('original task')],
        inFlightAgentRun: AgentRunRecoveryMarker(
          runAttemptId: 'continue-run',
          startedAt: DateTime.utc(2026, 7, 7),
          updatedAt: DateTime.utc(2026, 7, 7),
        ),
      );
      await storage.saveSession(session);
      List<Map<String, dynamic>>? capturedMessages;
      final provider = ChatProvider(
        storage: storage,
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (messages) {
            capturedMessages = messages;
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'continued')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await provider.selectSession(session.id);
      expect(provider.currentInterruptedAgentRun, isNotNull);

      await provider.continueInterruptedAgentRun();

      expect(provider.currentInterruptedAgentRun, isNull);
      expect((await storage.getSession(session.id))!.inFlightAgentRun, isNull);
      expect(
        capturedMessages!.last['content'],
        contains('上次任务被中断'),
      );
      expect(provider.currentSession!.messages.last.textContent, 'continued');
      expect(
        provider.currentSession!.messages
            .where((message) => message.role == 'user')
            .map((message) => message.textContent),
        ['original task'],
      );
    });

    test(
        'unknown outcome recovery success keeps evidence immediately and after reload',
        () async {
      final storage = SessionStorage();
      await storage.init();
      final originalMarker = _unknownRecoveryMarker('unknown-success-origin');
      final session = ChatSession(
        id: 'unknown-success-retained',
        messages: [ChatMessage.user('original task')],
        inFlightAgentRun: originalMarker,
      );
      await storage.saveSession(session);
      final provider = ChatProvider(
        storage: storage,
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => StreamDone(const LlmResponse(
            stopReason: 'end_turn',
            content: [ContentBlock(type: 'text', text: 'model recovered')],
          )),
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await provider.selectSession(session.id);

      await provider.continueInterruptedAgentRun();

      final retained = provider.currentInterruptedAgentRun!;
      expect(retained.runAttemptId, isNot(originalMarker.runAttemptId));
      expect(retained.recoveryKind, InterruptedRunRecoveryKind.unknownOutcome);
      expect(retained.canClearAfterPositiveTerminal, isFalse);
      expect(provider.currentSession!.messages.last.textContent,
          'model recovered');
      expect(
        (await storage.getSession(session.id))!.inFlightAgentRun!.recoveryKind,
        InterruptedRunRecoveryKind.unknownOutcome,
      );

      final reloaded = ChatProvider(storage: storage);
      addTearDown(reloaded.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await reloaded.selectSession(session.id);

      expect(reloaded.currentInterruptedAgentRun, isNotNull);
      expect(reloaded.currentInterruptedAgentRun!.recoveryKind,
          InterruptedRunRecoveryKind.unknownOutcome);
      expect(reloaded.currentSession!.messages.last.textContent,
          'model recovered');
    });

    test('mixed recovery attempts retain unresolved unknown evidence',
        () async {
      final storage = SessionStorage();
      await storage.init();
      final timestamp = DateTime.utc(2026, 7, 10);
      final session = ChatSession(
        id: 'mixed-recovery-success-retained',
        messages: [
          ChatMessage.user('original task'),
          ChatMessage(
            role: 'user',
            content: [
              ToolResultContent(
                toolUseId: 'known-call',
                output: 'known result',
                metadata: const {'operationId': 'known-operation'},
              ),
            ],
          ),
        ],
        inFlightAgentRun: AgentRunRecoveryMarker(
          runAttemptId: 'mixed-origin',
          startedAt: timestamp,
          updatedAt: timestamp,
          phase: AgentRunRecoveryPhase.toolInFlight,
          toolAttempts: [
            ToolAttemptRecoveryMetadata(
              operationId: 'known-operation',
              toolName: 'web_fetch',
              risk: RecoveryToolRisk.safe,
              lifecycle: ToolAttemptLifecycle.resultPersisted,
              proposedAt: timestamp,
              updatedAt: timestamp,
              executionStartedAt: timestamp,
              executionOutcomeKnown: true,
            ),
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
      final provider = ChatProvider(
        storage: storage,
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => StreamDone(const LlmResponse(
            stopReason: 'end_turn',
            content: [ContentBlock(type: 'text', text: 'mixed recovered')],
          )),
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await provider.selectSession(session.id);

      await provider.continueInterruptedAgentRun();

      final retained = provider.currentInterruptedAgentRun!;
      expect(retained.recoveryKind, InterruptedRunRecoveryKind.unknownOutcome);
      expect(retained.toolAttempts, hasLength(2));
      expect(
        retained.toolAttempts
            .firstWhere((attempt) => attempt.operationId == 'known-operation')
            .lifecycle,
        ToolAttemptLifecycle.resultPersisted,
      );
      expect(
        retained.toolAttempts
            .firstWhere((attempt) => attempt.operationId == 'unknown-operation')
            .lifecycle,
        ToolAttemptLifecycle.interruptedUnknown,
      );
      expect(
          (await storage.getSession(session.id))!.inFlightAgentRun, isNotNull);
    });

    test('Continue preflight blockers retain the old recovery marker',
        () async {
      Future<void> verifyBlocked({
        required String id,
        required Future<void> Function(
          ChatProvider provider,
          SessionStorage storage,
        ) act,
        AttachmentBudget? attachmentBudget,
      }) async {
        final storage = SessionStorage();
        await storage.init();
        final marker = _unknownRecoveryMarker('old-$id');
        final session = ChatSession(
          id: id,
          messages: [ChatMessage.user('original task')],
          inFlightAgentRun: marker,
        );
        await storage.saveSession(session);
        var modelCalls = 0;
        final provider = ChatProvider(
          storage: storage,
          attachmentBudget: attachmentBudget,
          llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
            config,
            onMessages: (_) {
              modelCalls++;
              return StreamDone(const LlmResponse(
                stopReason: 'end_turn',
                content: [ContentBlock(type: 'text', text: 'unexpected')],
              ));
            },
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await provider.selectSession(id);

        await act(provider, storage);

        expect(provider.currentInterruptedAgentRun?.runAttemptId,
            marker.runAttemptId);
        expect(
          provider.currentSession!.messages
              .where((message) => message.role == 'user')
              .map((message) => message.textContent),
          ['original task'],
        );
        expect(modelCalls, 0);
        provider.dispose();
      }

      await verifyBlocked(
        id: 'recovery-missing-credential',
        act: (provider, _) async {
          PreferencesService().apiKey = null;
          await provider.continueInterruptedAgentRun();
        },
      );
      await verifyBlocked(
        id: 'recovery-attachment-rejected',
        attachmentBudget: const _RejectingAttachmentBudget(),
        act: (provider, _) => provider.continueInterruptedAgentRun(
          attachments: [TextContent('attachment')],
        ),
      );
      await verifyBlocked(
        id: 'recovery-missing-target',
        act: (provider, storage) async {
          await storage.deleteSession('recovery-missing-target');
          await provider.continueInterruptedAgentRun();
        },
      );
    });

    test('Continue concurrent limit retains old evidence', () async {
      final storage = SessionStorage();
      await storage.init();
      final marker = _unknownRecoveryMarker('old-concurrent');
      await storage.saveSession(ChatSession(
        id: 'recovery-concurrent-limit',
        messages: [ChatMessage.user('original task')],
        inFlightAgentRun: marker,
      ));
      final started = Completer<void>();
      final release = Completer<void>();
      final provider = ChatProvider(
        storage: storage,
        llmServiceFactory: (config, {isInBackground}) => _BlockingLlmService(
          config,
          started: started,
          release: release,
        ),
      );
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      PreferencesService().maxConcurrentAgents = 1;
      final other = await provider.createSession();
      final otherRun = provider.sendMessage('occupy slot');
      await started.future;
      await provider.selectSession('recovery-concurrent-limit');

      await provider.continueInterruptedAgentRun();

      expect(provider.currentInterruptedAgentRun?.runAttemptId,
          marker.runAttemptId);
      expect(provider.currentSession!.messages.single.textContent,
          'original task');
      await provider.cancelAgent(sessionId: other.id, savePartial: false);
      await otherRun;
    });

    test('replacement save failure and pre-commit boundary retain old evidence',
        () async {
      var failReplacement = false;
      var blockReplacement = false;
      final replacementEntered = Completer<void>();
      final releaseReplacement = Completer<void>();
      final storage = SessionStorage(beforeCommitForTesting: (_) async {
        if (failReplacement) throw StateError('injected replacement failure');
        if (blockReplacement) {
          if (!replacementEntered.isCompleted) replacementEntered.complete();
          await releaseReplacement.future;
        }
      });
      await storage.init();
      final firstMarker = _unknownRecoveryMarker('old-save-failure');
      await storage.saveSession(ChatSession(
        id: 'recovery-save-failure',
        messages: [ChatMessage.user('original task')],
        inFlightAgentRun: firstMarker,
      ));
      var modelCalls = 0;
      final provider = ChatProvider(
        storage: storage,
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) {
            modelCalls++;
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'continued')],
            ));
          },
        ),
      );
      addTearDown(() async {
        if (!releaseReplacement.isCompleted) releaseReplacement.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await provider.selectSession('recovery-save-failure');

      failReplacement = true;
      await provider.continueInterruptedAgentRun();
      failReplacement = false;
      expect(
        (await storage.getSession('recovery-save-failure'))!
            .inFlightAgentRun!
            .runAttemptId,
        firstMarker.runAttemptId,
      );
      expect(provider.currentInterruptedAgentRun!.runAttemptId,
          firstMarker.runAttemptId);
      expect(modelCalls, 0);

      blockReplacement = true;
      final continueFuture = provider.continueInterruptedAgentRun();
      await replacementEntered.future;
      final beforeCommit = await storage.getSession('recovery-save-failure');
      expect(beforeCommit!.inFlightAgentRun!.runAttemptId,
          firstMarker.runAttemptId);
      expect(beforeCommit.messages.single.textContent, 'original task');
      expect(modelCalls, 0);
      blockReplacement = false;
      releaseReplacement.complete();
      await continueFuture;
      expect(modelCalls, 1);
    });

    test('three interrupted Continue attempts do not accumulate messages',
        () async {
      final storage = SessionStorage();
      await storage.init();
      await storage.saveSession(ChatSession(
        id: 'recovery-repeat-continue',
        messages: [ChatMessage.user('original task')],
        inFlightAgentRun: _unknownRecoveryMarker('repeat-old-run'),
      ));
      final starts = <Completer<void>>[];
      final provider = ChatProvider(
        storage: storage,
        llmServiceFactory: (config, {isInBackground}) {
          final started = Completer<void>();
          starts.add(started);
          return _BlockingLlmService(
            config,
            started: started,
            release: Completer<void>(),
          );
        },
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await provider.selectSession('recovery-repeat-continue');

      for (var index = 0; index < 3; index++) {
        final attempt = provider.continueInterruptedAgentRun();
        await _waitUntil(() => starts.length > index);
        await starts[index].future;
        await provider.cancelAgent(savePartial: false);
        await attempt;
      }

      final stored = await storage.getSession('recovery-repeat-continue');
      expect(stored!.inFlightAgentRun!.recoveryKind,
          InterruptedRunRecoveryKind.unknownOutcome);
      expect(stored.messages, hasLength(1));
      expect(stored.messages.single.textContent, 'original task');
      expect(stored.toApiMessages(), [
        {'role': 'user', 'content': 'original task'},
      ]);
    });

    test('legacy Continue renews approval for every risky tool under auto',
        () async {
      final storage = SessionStorage();
      await storage.init();
      final startedAt = DateTime.utc(2026, 7, 7);
      final session = ChatSession(
        id: 'legacy-recovery-risky-tools',
        messages: [ChatMessage.user('original task')],
        inFlightAgentRun: AgentRunRecoveryMarker.fromJson({
          'startedAt': startedAt.toIso8601String(),
        }),
      );
      await storage.saveSession(session);
      final tool = _EchoTool();
      var requestCount = 0;
      final provider = ChatProvider(
        storage: storage,
        toolRegistry: ToolRegistry()..register(tool, risk: ToolRisk.dangerous),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) {
            requestCount++;
            if (requestCount == 1) {
              return StreamDone(const LlmResponse(
                stopReason: 'tool_use',
                content: [
                  ContentBlock(
                    type: 'tool_use',
                    toolUseId: 'legacy_call_1',
                    toolName: 'echo',
                    toolInput: {'text': 'first'},
                  ),
                  ContentBlock(
                    type: 'tool_use',
                    toolUseId: 'legacy_call_2',
                    toolName: 'echo',
                    toolInput: {'text': 'second'},
                  ),
                ],
              ));
            }
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'done')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      PreferencesService().toolApprovalPolicy =
          PreferencesService.toolApprovalAuto;
      await provider.selectSession(session.id);

      final recoveryFuture = provider.continueInterruptedAgentRun();
      final approvalOperationIds = <String>[];
      await _waitUntil(() => provider.pendingApproval != null);
      approvalOperationIds.add(provider.pendingApproval!.operationId);
      expect(tool.executionCount, 0);
      provider.resolveToolApproval(
        operationId: approvalOperationIds.last,
        approved: true,
      );
      await _waitUntil(() => provider.pendingApproval != null);
      approvalOperationIds.add(provider.pendingApproval!.operationId);
      expect(tool.executionCount, 1);
      provider.resolveToolApproval(
        operationId: approvalOperationIds.last,
        approved: true,
      );
      await recoveryFuture;

      expect(requestCount, 2);
      expect(tool.executionCount, 2);
      expect(approvalOperationIds.toSet(), hasLength(2));
      expect(provider.pendingApproval, isNull);
    });

    test('safe tool waits for explicit Continue but needs no approval',
        () async {
      final storage = SessionStorage();
      await storage.init();
      final startedAt = DateTime.utc(2026, 7, 7);
      final session = ChatSession(
        id: 'safe-recovery-continue',
        messages: [ChatMessage.user('original task')],
        inFlightAgentRun: AgentRunRecoveryMarker(
          runAttemptId: 'safe-recovery-run',
          startedAt: startedAt,
          updatedAt: startedAt,
        ),
      );
      await storage.saveSession(session);
      final tool = _EchoTool();
      var requestCount = 0;
      final provider = ChatProvider(
        storage: storage,
        toolRegistry: ToolRegistry()..register(tool, risk: ToolRisk.safe),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) {
            requestCount++;
            if (requestCount == 1) {
              return StreamDone(const LlmResponse(
                stopReason: 'tool_use',
                content: [
                  ContentBlock(
                    type: 'tool_use',
                    toolUseId: 'safe_call',
                    toolName: 'echo',
                    toolInput: {'text': 'safe'},
                  ),
                ],
              ));
            }
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'done')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await provider.selectSession(session.id);

      expect(tool.executionCount, 0);
      await provider.continueInterruptedAgentRun();

      expect(tool.executionCount, 1);
      expect(provider.pendingApproval, isNull);
    });

    test('reload marks started tool unknown and never executes it', () async {
      final storage = SessionStorage();
      await storage.init();
      final timestamp = DateTime.utc(2026, 7, 7);
      final session = ChatSession(
        id: 'interrupted-tool-started',
        messages: [
          ChatMessage.user('original task'),
          ChatMessage(
            role: 'assistant',
            content: [
              ToolUseContent(
                id: 'call_1',
                name: 'echo',
                input: const {'text': 'must not replay'},
              ),
            ],
          ),
        ],
        inFlightAgentRun: AgentRunRecoveryMarker(
          runAttemptId: 'run-started',
          startedAt: timestamp,
          updatedAt: timestamp,
          phase: AgentRunRecoveryPhase.toolInFlight,
          toolAttempts: [
            ToolAttemptRecoveryMetadata(
              operationId: 'operation-started',
              toolName: 'echo',
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
      final tool = _EchoTool();
      final provider = ChatProvider(
        storage: storage,
        toolRegistry: ToolRegistry()..register(tool, risk: ToolRisk.dangerous),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await provider.selectSession(session.id);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(tool.executionCount, 0);
      expect(provider.isSessionSending(session.id), isFalse);
      final marker = provider.currentInterruptedAgentRun!;
      expect(marker.recoveryKind, InterruptedRunRecoveryKind.unknownOutcome);
      expect(marker.toolAttempts.single.lifecycle,
          ToolAttemptLifecycle.interruptedUnknown);
      expect(
        (await storage.getSession(session.id))!
            .inFlightAgentRun!
            .toolAttempts
            .single
            .lifecycle,
        ToolAttemptLifecycle.interruptedUnknown,
      );
    });

    test('persisted tool result is reconciled and never executed twice',
        () async {
      final storage = SessionStorage();
      await storage.init();
      final timestamp = DateTime.utc(2026, 7, 7);
      final session = ChatSession(
        id: 'interrupted-tool-persisted',
        messages: [
          ChatMessage.user('original task'),
          ChatMessage(
            role: 'assistant',
            content: [
              ToolUseContent(
                id: 'call_1',
                name: 'echo',
                input: const {'text': 'already ran'},
              ),
            ],
          ),
          ChatMessage(
            role: 'user',
            content: [
              ToolResultContent(
                toolUseId: 'call_1',
                output: 'saved result',
                metadata: const {'operationId': 'operation-completed'},
              ),
            ],
          ),
        ],
        inFlightAgentRun: AgentRunRecoveryMarker(
          runAttemptId: 'run-completed',
          startedAt: timestamp,
          updatedAt: timestamp,
          phase: AgentRunRecoveryPhase.toolInFlight,
          toolAttempts: [
            ToolAttemptRecoveryMetadata(
              operationId: 'operation-completed',
              toolName: 'echo',
              risk: RecoveryToolRisk.dangerous,
              lifecycle: ToolAttemptLifecycle.completed,
              proposedAt: timestamp,
              updatedAt: timestamp,
              executionStartedAt: timestamp,
              executionOutcomeKnown: true,
            ),
          ],
        ),
      );
      await storage.saveSession(session);
      final tool = _EchoTool();
      List<Map<String, dynamic>>? capturedMessages;
      final provider = ChatProvider(
        storage: storage,
        toolRegistry: ToolRegistry()..register(tool, risk: ToolRisk.dangerous),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (messages) {
            capturedMessages = messages;
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'continued safely')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await provider.selectSession(session.id);
      expect(provider.currentInterruptedAgentRun!.toolAttempts.single.lifecycle,
          ToolAttemptLifecycle.resultPersisted);

      await provider.continueInterruptedAgentRun();

      expect(tool.executionCount, 0);
      expect(
        capturedMessages!
            .where((message) => message['role'] == 'assistant')
            .expand((message) => message['content'] as List)
            .whereType<Map>()
            .where((block) => block['type'] == 'tool_use'),
        hasLength(1),
      );
      expect(
        provider.currentSession!.messages
            .expand((message) => message.toolResults),
        hasLength(1),
      );
      expect(provider.currentSession!.messages.last.textContent,
          'continued safely');
      expect(provider.currentInterruptedAgentRun, isNull);
      expect((await storage.getSession(session.id))!.inFlightAgentRun, isNull);

      final reloaded = ChatProvider(storage: storage);
      addTearDown(reloaded.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await reloaded.selectSession(session.id);
      expect(reloaded.currentInterruptedAgentRun, isNull);
    });

    test(
        'recovery error retry preserves evidence and renews every approval under auto',
        () async {
      configureModelFallbackProfiles();
      final storage = SessionStorage();
      await storage.init();
      final timestamp = DateTime.utc(2026, 7, 10, 10);
      final session = _resultPersistedRecoverySession(
        id: 'recovery-error-immediate-retry',
        timestamp: timestamp,
      );
      await storage.saveSession(session);
      final tool = _EchoTool();
      var retryPhase = false;
      var retryModelCalls = 0;
      final provider = ChatProvider(
        storage: storage,
        toolRegistry: ToolRegistry()..register(tool, risk: ToolRisk.dangerous),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) {
            if (!retryPhase) {
              return StreamError(
                'OpenAI API error (503): temporarily unavailable',
                cause: Exception('OpenAI API error (503)'),
              );
            }
            retryModelCalls++;
            if (retryModelCalls == 1) {
              return StreamDone(const LlmResponse(
                stopReason: 'tool_use',
                content: [
                  ContentBlock(
                    type: 'tool_use',
                    toolUseId: 'retry_dangerous_1',
                    toolName: 'echo',
                    toolInput: {'text': 'first'},
                  ),
                  ContentBlock(
                    type: 'tool_use',
                    toolUseId: 'retry_dangerous_2',
                    toolName: 'echo',
                    toolInput: {'text': 'second'},
                  ),
                ],
              ));
            }
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'recovered')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      PreferencesService().toolApprovalPolicy =
          PreferencesService.toolApprovalAuto;
      await provider.selectSession(session.id);

      await provider.continueInterruptedAgentRun();

      final failed = provider.currentSession!.messages.last;
      final failedMarker = provider.currentInterruptedAgentRun!;
      expect(failed.assistantError!.isRecoveryRetry, isTrue);
      expect(failed.assistantError!.recoveryRunAttemptId,
          failedMarker.runAttemptId);
      expect(failedMarker.toolAttempts.single.lifecycle,
          ToolAttemptLifecycle.resultPersisted);
      expect(
        provider.currentSession!.messages
            .expand((message) => message.toolResults)
            .where((result) => result.toolUseId == 'old_completed_call'),
        hasLength(1),
      );

      retryPhase = true;
      final retry = provider.retryAssistantMessage(
        provider.currentSession!.messages.length - 1,
      );
      AssistantRetryStatus? earlyRetryStatus;
      unawaited(retry.then((status) => earlyRetryStatus = status));
      final approvalIds = <String>[];
      await _waitUntil(
        () => provider.pendingApproval != null || earlyRetryStatus != null,
      );
      expect(provider.pendingApproval, isNotNull,
          reason: 'retry completed early with $earlyRetryStatus');
      approvalIds.add(provider.pendingApproval!.operationId);
      expect(tool.executionCount, 0);
      provider.resolveToolApproval(
        operationId: approvalIds.last,
        approved: true,
      );
      await _waitUntil(() => provider.pendingApproval != null);
      approvalIds.add(provider.pendingApproval!.operationId);
      expect(tool.executionCount, 1);
      provider.resolveToolApproval(
        operationId: approvalIds.last,
        approved: true,
      );
      expect(await retry, AssistantRetryStatus.started);

      expect(retryModelCalls, 2);
      expect(approvalIds.toSet(), hasLength(2));
      expect(provider.pendingApproval, isNull);
      expect(tool.executionCount, 2);
      expect(provider.currentInterruptedAgentRun, isNull);
      expect((await storage.getSession(session.id))!.inFlightAgentRun, isNull);
      expect(
        provider.currentSession!.messages
            .expand((message) => message.toolResults)
            .where((result) => result.toolUseId == 'old_completed_call'),
        hasLength(1),
      );
      expect(
        provider.currentSession!.messages.any(
          (message) => message.hasAssistantError,
        ),
        isFalse,
      );
    });

    test('reloaded recovery error retry keeps provenance and approvals',
        () async {
      configureModelFallbackProfiles();
      final storage = SessionStorage();
      await storage.init();
      final timestamp = DateTime.utc(2026, 7, 10, 11);
      final session = _resultPersistedRecoverySession(
        id: 'recovery-error-reload-retry',
        timestamp: timestamp,
      );
      await storage.saveSession(session);
      final first = ChatProvider(
        storage: storage,
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => StreamError(
            'OpenAI API error (503): temporarily unavailable',
            cause: Exception('OpenAI API error (503)'),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await first.selectSession(session.id);
      await first.continueInterruptedAgentRun();
      final persistedFailure = await storage.getSession(session.id);
      expect(persistedFailure!.inFlightAgentRun, isNotNull);
      expect(persistedFailure.messages.last.assistantError!.isRecoveryRetry,
          isTrue);
      first.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final tool = _EchoTool();
      var requestCount = 0;
      final reloaded = ChatProvider(
        storage: storage,
        toolRegistry: ToolRegistry()..register(tool, risk: ToolRisk.dangerous),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) {
            requestCount++;
            if (requestCount == 1) {
              return StreamDone(const LlmResponse(
                stopReason: 'tool_use',
                content: [
                  ContentBlock(
                    type: 'tool_use',
                    toolUseId: 'reload_retry_1',
                    toolName: 'echo',
                    toolInput: {'text': 'first'},
                  ),
                  ContentBlock(
                    type: 'tool_use',
                    toolUseId: 'reload_retry_2',
                    toolName: 'echo',
                    toolInput: {'text': 'second'},
                  ),
                ],
              ));
            }
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'reload recovered')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        reloaded.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      PreferencesService().toolApprovalPolicy =
          PreferencesService.toolApprovalAuto;
      await reloaded.selectSession(session.id);
      final errorIndex = reloaded.currentSession!.messages.length - 1;

      final retry = reloaded.retryAssistantMessage(errorIndex);
      AssistantRetryStatus? earlyRetryStatus;
      unawaited(retry.then((status) => earlyRetryStatus = status));
      await _waitUntil(
        () => reloaded.pendingApproval != null || earlyRetryStatus != null,
      );
      expect(reloaded.pendingApproval, isNotNull,
          reason: 'retry completed early with $earlyRetryStatus');
      expect(tool.executionCount, 0);
      reloaded.resolveToolApproval(
        operationId: reloaded.pendingApproval!.operationId,
        approved: true,
      );
      await _waitUntil(() => reloaded.pendingApproval != null);
      expect(tool.executionCount, 1);
      reloaded.resolveToolApproval(
        operationId: reloaded.pendingApproval!.operationId,
        approved: true,
      );
      expect(await retry, AssistantRetryStatus.started);

      expect(requestCount, 2);
      expect(reloaded.pendingApproval, isNull);
      expect(tool.executionCount, 2);
      expect(reloaded.currentInterruptedAgentRun, isNull);
      expect(
        reloaded.currentSession!.messages
            .expand((message) => message.toolResults)
            .where((result) => result.toolUseId == 'old_completed_call'),
        hasLength(1),
      );
    });

    test('expired pre-start approval is renewed even under auto policy',
        () async {
      final storage = SessionStorage();
      await storage.init();
      final timestamp = DateTime.utc(2026, 7, 7);
      final session = ChatSession(
        id: 'interrupted-tool-approved',
        messages: [
          ChatMessage.user('original task'),
          ChatMessage(
            role: 'assistant',
            content: [
              ToolUseContent(
                id: 'old_call',
                name: 'echo',
                input: const {'text': 'old action'},
              ),
            ],
          ),
        ],
        inFlightAgentRun: AgentRunRecoveryMarker(
          runAttemptId: 'run-approved',
          startedAt: timestamp,
          updatedAt: timestamp,
          phase: AgentRunRecoveryPhase.toolInFlight,
          toolAttempts: [
            ToolAttemptRecoveryMetadata(
              operationId: 'operation-approved',
              toolName: 'echo',
              risk: RecoveryToolRisk.moderate,
              lifecycle: ToolAttemptLifecycle.approvedNotStarted,
              proposedAt: timestamp,
              updatedAt: timestamp,
            ),
          ],
        ),
      );
      await storage.saveSession(session);
      final tool = _EchoTool();
      var requestCount = 0;
      final provider = ChatProvider(
        storage: storage,
        toolRegistry: ToolRegistry()..register(tool, risk: ToolRisk.moderate),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) {
            requestCount++;
            if (requestCount == 1) {
              return StreamDone(const LlmResponse(
                stopReason: 'tool_use',
                content: [
                  ContentBlock(
                    type: 'tool_use',
                    toolUseId: 'new_call',
                    toolName: 'echo',
                    toolInput: {'text': 'new action'},
                  ),
                  ContentBlock(
                    type: 'tool_use',
                    toolUseId: 'new_call_2',
                    toolName: 'echo',
                    toolInput: {'text': 'second new action'},
                  ),
                ],
              ));
            }
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'done')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      PreferencesService().toolApprovalPolicy =
          PreferencesService.toolApprovalAuto;
      await provider.selectSession(session.id);

      final recoveryFuture = provider.continueInterruptedAgentRun();
      await _waitUntil(() => provider.pendingApproval != null);

      expect(tool.executionCount, 0);
      expect(provider.pendingApproval!.operationId, isNotEmpty);
      expect(provider.pendingApproval!.runAttemptId, isNotEmpty);
      final pendingMarker =
          (await storage.getSession(session.id))!.inFlightAgentRun!;
      expect(
          pendingMarker.runAttemptId, provider.pendingApproval!.runAttemptId);
      final pendingAttempt = pendingMarker.toolAttempts.singleWhere(
        (attempt) =>
            attempt.operationId == provider.pendingApproval!.operationId,
      );
      expect(pendingAttempt.lifecycle, ToolAttemptLifecycle.approvalPending);
      expect(pendingMarker.toJson().toString(), isNot(contains('new action')));
      expect(pendingMarker.toJson().toString(), isNot(contains('old action')));
      final firstOperationId = provider.pendingApproval!.operationId;
      provider.resolveToolApproval(
        operationId: firstOperationId,
        approved: true,
      );
      await _waitUntil(() => provider.pendingApproval != null);

      expect(tool.executionCount, 1);
      expect(provider.pendingApproval!.operationId, isNot(firstOperationId));
      provider.resolveToolApproval(
        operationId: provider.pendingApproval!.operationId,
        approved: true,
      );
      await recoveryFuture;

      expect(requestCount, 2);
      expect(tool.executionCount, 2);
      expect(provider.pendingApproval, isNull);
      final recovered = (await storage.getSession(session.id))!;
      expect(recovered.inFlightAgentRun, isNull);
      expect(
        recovered.messages
            .expand((message) => message.toolUses)
            .map((toolUse) => toolUse.id),
        isNot(contains('old_call')),
      );
      expect(
        recovered.messages
            .expand((message) => message.toolResults)
            .map((result) => result.output),
        containsAll(['new action', 'second new action']),
      );
    });

    test('retry removes stale failure marker and does not duplicate history',
        () async {
      final capturedRequests = <List<Map<String, dynamic>>>[];
      var requestCount = 0;
      final provider = ChatProvider(
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (messages) {
            requestCount++;
            capturedRequests.add(messages);
            if (requestCount == 1) {
              return StreamError(
                'OpenAI API error (503): temporarily unavailable',
                cause: Exception('OpenAI API error (503)'),
              );
            }
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'retry ok')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await provider.createSession();
      await provider.sendMessage('hello');
      final failedIndex = provider.currentSession!.messages.length - 1;

      final status = await provider.retryAssistantMessage(failedIndex);

      expect(status, AssistantRetryStatus.started);
      expect(provider.errorMessage, isNull);
      expect(requestCount, 2);
      expect(provider.currentSession!.messages, hasLength(2));
      expect(
        provider.currentSession!.messages.where((m) => m.role == 'user'),
        hasLength(1),
      );
      expect(
        provider.currentSession!.messages.where((m) => m.hasAssistantError),
        isEmpty,
      );
      expect(provider.currentSession!.messages.last.textContent, 'retry ok');
      expect(capturedRequests.last, [
        {'role': 'user', 'content': 'hello'},
      ]);
    });

    test('safety and invalid request failures persist non-fallback markers',
        () async {
      for (final scenario in const [
        ('safety', 'content policy safety refusal', 'safety_or_refusal'),
        (
          'invalid',
          'invalid_request 400 schema unsupported',
          'invalid_or_tool_error',
        ),
      ]) {
        final attemptedModels = <String>[];
        final provider = ChatProvider(
          llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
            config,
            onMessages: (_) {
              attemptedModels.add(config.model);
              return StreamError(
                scenario.$2,
                cause: Exception(scenario.$2),
              );
            },
          ),
        );
        addTearDown(() async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          provider.dispose();
        });
        await Future<void>.delayed(const Duration(milliseconds: 50));

        await provider.createSession();
        await provider.sendMessage('hello ${scenario.$1}');

        expect(attemptedModels, ['claude-sonnet-4-20250514']);
        final marker = provider.currentSession!.messages.last;
        expect(marker.hasAssistantError, isTrue);
        expect(marker.assistantError!.code, scenario.$3);
        expect(marker.assistantError!.fallbackReasonCode, scenario.$3);
        expect(marker.assistantError!.canRetry, isTrue);
      }
    });

    test('cancel does not persist assistant retry marker', () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final storage = SessionStorage();
      await storage.init();
      final provider = ChatProvider(
        storage: storage,
        llmServiceFactory: (config, {isInBackground}) => _BlockingLlmService(
          config,
          started: started,
          release: release,
        ),
      );
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final session = await provider.createSession();
      final sendFuture = provider.sendMessage('slow prompt');
      await started.future.timeout(const Duration(seconds: 2));

      await provider.cancelAgent(sessionId: session.id, savePartial: false);
      await sendFuture.timeout(const Duration(seconds: 2));

      expect(
        provider.currentSession!.messages.where((m) => m.hasAssistantError),
        isEmpty,
      );

      final reloaded = ChatProvider(storage: storage);
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        reloaded.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await reloaded.selectSession(session.id);

      expect(reloaded.agentStatus, AgentStatus.idle);
      expect(
        reloaded.currentSession!.messages.where((m) => m.hasAssistantError),
        isEmpty,
      );
    });
  });

  group('message edit branching', () {
    setUp(() async {
      await installPlatformMocks();
      configureAnthropicProfile(baseUrl: 'http://127.0.0.1');
    });

    tearDown(() async {
      await clearPlatformMocks();
    });

    test('branches before edited user message and reruns from edited text',
        () async {
      final storage = SessionStorage();
      await storage.init();
      List<Map<String, dynamic>>? capturedMessages;
      final provider = ChatProvider(
        storage: storage,
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (messages) {
            capturedMessages = messages;
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'edited answer')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final session = await provider.createSession();
      final originalId = session.id;
      session.contextSummary = ContextSummary(
        version: ContextSummaryService.version,
        text: 'old summary',
        coveredMessageCount: 3,
        coveredDigest: 'digest',
        sourceEstimatedTokens: 12,
        summaryEstimatedTokens: 2,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        model: 'claude',
        apiFormat: 'anthropic',
      );
      session.messages
        ..clear()
        ..addAll([
          ChatMessage.user('setup'),
          ChatMessage(
            role: 'assistant',
            content: [
              ToolUseContent(
                id: 'tool_1',
                name: 'echo',
                input: const {'text': 'setup'},
              ),
            ],
          ),
          ChatMessage.toolResults([
            {
              'tool_use_id': 'tool_1',
              'content': 'tool result',
            },
          ]),
          ChatMessage.user('revise me'),
          ChatMessage.assistant([
            {'type': 'text', 'text': 'obsolete answer'},
          ]),
        ]);
      await storage.saveSession(session);

      final status = await provider.editUserMessageAndResend(
        3,
        ' edited prompt ',
      );

      expect(status, EditUserMessageBranchStatus.started);
      final branch = provider.currentSession!;
      expect(branch.id, isNot(originalId));
      expect(branch.contextSummary, isNull);
      expect(branch.messages, hasLength(5));
      expect(branch.messages[0].textContent, 'setup');
      expect(branch.messages[1].toolUses.single.id, 'tool_1');
      expect(branch.messages[2].toolResults.single.toolUseId, 'tool_1');
      expect(branch.messages[3].textContent, 'edited prompt');
      expect(branch.messages[4].textContent, 'edited answer');

      final original = await storage.getSession(originalId);
      expect(original!.messages[3].textContent, 'revise me');
      expect(original.messages[4].textContent, 'obsolete answer');
      expect(original.contextSummary, isNotNull);

      final payload = jsonEncode(capturedMessages);
      expect(payload, contains('edited prompt'));
      expect(payload, isNot(contains('obsolete answer')));
    });

    test('edit branch preserves user image attachments', () async {
      final storage = SessionStorage();
      await storage.init();
      List<Map<String, dynamic>>? capturedMessages;
      final provider = ChatProvider(
        storage: storage,
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (messages) {
            capturedMessages = messages;
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'edited image')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final session = await provider.createSession();
      session.messages
        ..clear()
        ..addAll([
          ChatMessage.userContent([
            TextContent('describe original'),
            ImageContent(
              data: 'aGk=',
              mediaType: 'image/png',
              filename: 'tiny.png',
            ),
          ]),
          ChatMessage.assistant([
            {'type': 'text', 'text': 'obsolete answer'},
          ]),
        ]);
      await storage.saveSession(session);

      final status = await provider.editUserMessageAndResend(
        0,
        'describe edited',
      );

      expect(status, EditUserMessageBranchStatus.started);
      final branchUser = provider.currentSession!.messages
          .firstWhere((message) => message.role == 'user');
      expect(branchUser.textContent, 'describe edited');
      expect(branchUser.content.whereType<ImageContent>(), hasLength(1));
      final payload = jsonEncode(capturedMessages);
      expect(payload, contains('describe edited'));
      expect(payload, contains('"type":"image"'));
      expect(payload, isNot(contains('describe original')));
    });

    test('regenerate preserves user image attachments and alternatives',
        () async {
      final storage = SessionStorage();
      await storage.init();
      List<Map<String, dynamic>>? capturedMessages;
      final provider = ChatProvider(
        storage: storage,
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (messages) {
            capturedMessages = messages;
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'new image answer')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final session = await provider.createSession();
      session.messages
        ..clear()
        ..addAll([
          ChatMessage.userContent([
            TextContent('describe image'),
            ImageContent(
              data: 'aGk=',
              mediaType: 'image/png',
              filename: 'tiny.png',
            ),
          ]),
          ChatMessage(
            role: 'assistant',
            content: [TextContent('old image answer')],
          ),
        ]);
      await storage.saveSession(session);

      await provider.regenerateLastResponse();

      final messages = provider.currentSession!.messages;
      expect(messages, hasLength(2));
      expect(messages.first.content.whereType<ImageContent>(), hasLength(1));
      expect(messages.last.textContent, 'new image answer');
      expect(messages.last.alternatives, contains('old image answer'));
      final payload = jsonEncode(capturedMessages);
      expect(payload, contains('describe image'));
      expect(payload, contains('"type":"image"'));
    });

    test('assistant retry preserves user image attachments', () async {
      final storage = SessionStorage();
      await storage.init();
      List<Map<String, dynamic>>? capturedMessages;
      final provider = ChatProvider(
        storage: storage,
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (messages) {
            capturedMessages = messages;
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'retry image answer')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final session = await provider.createSession();
      session.messages
        ..clear()
        ..addAll([
          ChatMessage.userContent([
            TextContent('retry image'),
            ImageContent(
              data: 'aGk=',
              mediaType: 'image/png',
              filename: 'tiny.png',
            ),
          ]),
          ChatMessage(
            role: 'assistant',
            content: [TextContent('failed answer')],
            assistantError: const AssistantErrorMetadata(
              message: 'temporary model error',
              code: 'provider_error',
              canRetry: true,
            ),
          ),
        ]);
      await storage.saveSession(session);

      final status = await provider.retryAssistantMessage(1);

      expect(status, AssistantRetryStatus.started);
      final messages = provider.currentSession!.messages;
      expect(messages, hasLength(2));
      expect(messages.first.content.whereType<ImageContent>(), hasLength(1));
      expect(messages.last.textContent, 'retry image answer');
      final payload = jsonEncode(capturedMessages);
      expect(payload, contains('retry image'));
      expect(payload, contains('"type":"image"'));
    });

    test('rejects empty edited text without creating a branch', () async {
      final storage = SessionStorage();
      await storage.init();
      final provider = ChatProvider(
        storage: storage,
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => StreamDone(const LlmResponse(
            stopReason: 'end_turn',
            content: [ContentBlock(type: 'text', text: 'ok')],
          )),
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final session = await provider.createSession();
      session.messages
        ..clear()
        ..add(ChatMessage.user('keep me'));
      await storage.saveSession(session);

      final status = await provider.editUserMessageAndResend(0, '   ');

      expect(status, EditUserMessageBranchStatus.empty);
      expect(provider.currentSession!.id, session.id);
      expect((await storage.getSessionsSummary()), hasLength(1));
    });
  });

  group('session-owned regenerate and retry', () {
    setUp(() async {
      await installPlatformMocks();
      configureAnthropicProfile(baseUrl: 'http://127.0.0.1');
    });

    tearDown(clearPlatformMocks);

    test('regenerate remains owned by its initiating session after switch',
        () async {
      final saveEntered = Completer<void>();
      final releaseSave = Completer<void>();
      var blockedSessionId = '';
      var blockNext = false;
      final storage = SessionStorage(beforeCommitForTesting: (id) async {
        if (!blockNext || id != blockedSessionId) return;
        blockNext = false;
        saveEntered.complete();
        await releaseSave.future;
      });
      await storage.init();
      final captured = <List<Map<String, dynamic>>>[];
      final provider = ChatProvider(
        storage: storage,
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (messages) {
            captured.add(messages);
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'replacement')],
            ));
          },
        ),
      );
      addTearDown(() async {
        if (!releaseSave.isCompleted) releaseSave.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final owner = await provider.createSession();
      owner.messages
        ..clear()
        ..addAll([
          ChatMessage.user('owner prompt'),
          ChatMessage.assistant([
            {'type': 'text', 'text': 'old response'},
          ]),
        ]);
      await storage.saveSession(owner);
      final other = await provider.createSession();
      other.messages.add(ChatMessage.user('other history'));
      await storage.saveSession(other);
      final otherBefore =
          jsonEncode((await storage.getSession(other.id))!.toJson());
      await provider.selectSession(owner.id);

      blockedSessionId = owner.id;
      blockNext = true;
      final regenerate = provider.regenerateLastResponse();
      await saveEntered.future;
      await provider.selectSession(other.id);
      releaseSave.complete();
      await regenerate;

      expect(provider.currentSession!.id, other.id);
      expect(jsonEncode((await storage.getSession(other.id))!.toJson()),
          otherBefore);
      expect(captured, hasLength(1));
      expect(jsonEncode(captured.single), contains('owner prompt'));
      expect(jsonEncode(captured.single), isNot(contains('other history')));
      final persistedOwner = await storage.getSession(owner.id);
      expect(persistedOwner!.messages.last.textContent, 'replacement');
    });

    test('assistant retry keeps owner attachments after session switch',
        () async {
      final saveEntered = Completer<void>();
      final releaseSave = Completer<void>();
      var blockedSessionId = '';
      var blockNext = false;
      final storage = SessionStorage(beforeCommitForTesting: (id) async {
        if (!blockNext || id != blockedSessionId) return;
        blockNext = false;
        saveEntered.complete();
        await releaseSave.future;
      });
      await storage.init();
      List<Map<String, dynamic>>? request;
      final provider = ChatProvider(
        storage: storage,
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (messages) {
            request = messages;
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'retried')],
            ));
          },
        ),
      );
      addTearDown(() async {
        if (!releaseSave.isCompleted) releaseSave.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final owner = await provider.createSession();
      owner.messages
        ..clear()
        ..addAll([
          ChatMessage.userContent([
            TextContent('retry owner'),
            ImageContent(data: 'aGk=', mediaType: 'image/png'),
          ]),
          ChatMessage(
            role: 'assistant',
            content: [TextContent('failed')],
            assistantError: const AssistantErrorMetadata(
              message: 'temporary',
              code: 'provider_error',
              canRetry: true,
            ),
          ),
        ]);
      await storage.saveSession(owner);
      final other = await provider.createSession();
      other.messages.add(ChatMessage.user('other'));
      await storage.saveSession(other);
      final otherBefore =
          jsonEncode((await storage.getSession(other.id))!.toJson());
      await provider.selectSession(owner.id);

      blockedSessionId = owner.id;
      blockNext = true;
      final retry = provider.retryAssistantMessage(1);
      await saveEntered.future;
      await provider.selectSession(other.id);
      releaseSave.complete();

      expect(await retry, AssistantRetryStatus.started);
      expect(provider.currentSession!.id, other.id);
      expect(jsonEncode((await storage.getSession(other.id))!.toJson()),
          otherBefore);
      expect(jsonEncode(request), contains('"type":"image"'));
      expect(jsonEncode(request), isNot(contains('other')));
      expect((await storage.getSession(owner.id))!.messages.last.textContent,
          'retried');
    });

    test('deleting owner during replay save prevents request and resurrection',
        () async {
      final saveEntered = Completer<void>();
      final releaseSave = Completer<void>();
      var blockedSessionId = '';
      var blockNext = false;
      final storage = SessionStorage(beforeCommitForTesting: (id) async {
        if (!blockNext || id != blockedSessionId) return;
        blockNext = false;
        saveEntered.complete();
        await releaseSave.future;
      });
      await storage.init();
      var requestCount = 0;
      final provider = ChatProvider(
        storage: storage,
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) {
            requestCount++;
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'unexpected')],
            ));
          },
        ),
      );
      addTearDown(() async {
        if (!releaseSave.isCompleted) releaseSave.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final owner = await provider.createSession();
      owner.messages
        ..clear()
        ..addAll([
          ChatMessage.user('owner'),
          ChatMessage.assistant([
            {'type': 'text', 'text': 'old'},
          ]),
        ]);
      await storage.saveSession(owner);
      blockedSessionId = owner.id;
      blockNext = true;
      final regenerate = provider.regenerateLastResponse();
      await saveEntered.future;
      final deletion = provider.deleteSession(owner.id);
      releaseSave.complete();
      await Future.wait([regenerate, deletion]);

      expect(requestCount, 0);
      expect(await storage.getSession(owner.id), isNull);
    });

    test('newer replay supersedes stale blocked replay without tail corruption',
        () async {
      final saveEntered = Completer<void>();
      final releaseSave = Completer<void>();
      var blockedSessionId = '';
      var blockNext = false;
      final storage = SessionStorage(beforeCommitForTesting: (id) async {
        if (!blockNext || id != blockedSessionId) return;
        blockNext = false;
        saveEntered.complete();
        await releaseSave.future;
      });
      await storage.init();
      var requestCount = 0;
      final provider = ChatProvider(
        storage: storage,
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) {
            requestCount++;
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'new')],
            ));
          },
        ),
      );
      addTearDown(() async {
        if (!releaseSave.isCompleted) releaseSave.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final owner = await provider.createSession();
      owner.messages
        ..clear()
        ..addAll([
          ChatMessage.user('owner'),
          ChatMessage.assistant([
            {'type': 'text', 'text': 'old'},
          ]),
        ]);
      await storage.saveSession(owner);
      blockedSessionId = owner.id;
      blockNext = true;
      final stale = provider.regenerateLastResponse();
      await saveEntered.future;
      final current = provider.regenerateLastResponse();
      releaseSave.complete();
      await Future.wait([stale, current]);

      expect(requestCount, 1);
      final persisted = await storage.getSession(owner.id);
      expect(persisted!.messages.where((message) => message.role == 'user'),
          hasLength(1));
      expect(persisted.messages.last.textContent, 'new');
    });

    test('failed replay boundary save leaves in-memory tail unchanged',
        () async {
      var failSessionId = '';
      var failNext = false;
      final storage = SessionStorage(beforeCommitForTesting: (id) async {
        if (failNext && id == failSessionId) {
          failNext = false;
          throw StateError('injected replay save failure');
        }
      });
      await storage.init();
      var requestCount = 0;
      final provider = ChatProvider(
        storage: storage,
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) {
            requestCount++;
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'unexpected')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final owner = await provider.createSession();
      owner.messages
        ..clear()
        ..addAll([
          ChatMessage.user('owner'),
          ChatMessage.assistant([
            {'type': 'text', 'text': 'keep tail'},
          ]),
        ]);
      await storage.saveSession(owner);
      final before = jsonEncode(owner.messages.map((m) => m.toJson()).toList());
      failSessionId = owner.id;
      failNext = true;

      await provider.regenerateLastResponse();

      expect(requestCount, 0);
      expect(
        jsonEncode(provider.currentSession!.messages
            .map((message) => message.toJson())
            .toList()),
        before,
      );
      expect((await storage.getSession(owner.id))!.messages.last.textContent,
          'keep tail');
    });
  });

  group('safe mode and diagnostics', () {
    setUp(() async {
      await installPlatformMocks();
      configureAnthropicProfile(baseUrl: 'http://127.0.0.1');
    });

    tearDown(() async {
      await clearPlatformMocks();
    });

    test('safe mode skips selecting existing sessions until cleared', () async {
      final storage = SessionStorage();
      await storage.init();
      final session = ChatSession(
        id: 'safe_mode_session',
        title: 'bad long session',
        messages: [ChatMessage.user('large prompt')],
      );
      await storage.saveSession(session);
      final guard = StartupRestoreGuard();
      await guard.recordStartupFailure();
      await guard.recordStartupFailure();

      final provider =
          ChatProvider(storage: storage, startupRestoreGuard: guard);
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(provider.safeMode, isTrue);
      expect(provider.sessions.map((s) => s.id), contains('safe_mode_session'));

      await provider.selectSession('safe_mode_session');
      expect(provider.currentSession, isNull);
      expect(provider.errorMessage, contains('安全模式'));

      await provider.exitSafeMode();
      await provider.selectSession('safe_mode_session');
      expect(provider.currentSession?.id, 'safe_mode_session');
    });

    test('init failure safe-opens when restore guard prefs are unavailable',
        () async {
      final guard = StartupRestoreGuard(
        prefsFactory: () async => throw StateError('prefs unavailable'),
      );

      final firstProvider = ChatProvider(
        storage: _ThrowingInitSessionStorage(),
        startupRestoreGuard: guard,
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        firstProvider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(firstProvider.safeMode, isFalse);
      expect(firstProvider.startupFailureCount, 1);
      expect(firstProvider.sessions, isEmpty);
      expect(firstProvider.currentSession, isNull);
      expect(firstProvider.errorMessage, isNotNull);

      final secondProvider = ChatProvider(
        storage: _ThrowingInitSessionStorage(),
        startupRestoreGuard: guard,
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        secondProvider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(secondProvider.safeMode, isTrue);
      expect(secondProvider.startupFailureCount, 2);
      expect(secondProvider.sessions, isEmpty);
      expect(secondProvider.currentSession, isNull);
      expect(secondProvider.errorMessage, isNotNull);
    });

    test('diagnostics report excludes raw prompt, base64, and secrets',
        () async {
      final events = RuntimeDebugEventService(tracingEnabled: true);
      events.record(RuntimeDebugEvent(
        type: 'stream.terminal',
        sessionId: 's1',
        data: {
          'attempt': 1,
          'status': 'failed',
          'completeness': 'none',
          'durationMs': 1,
          'errorCode': 'provider_unavailable',
          'prompt': 'Authorization: Bearer abcdefghijklmnopqrstuvwxyz123456',
          'imageData': 'data:image/png;base64,${'a' * 200}',
          'api_key': 'sk-secretsecretsecret',
        },
      ));
      final provider = ChatProvider(runtimeDebugEvents: events);
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final report = await provider.buildDiagnosticsReport();

      expect(report, contains('ClawChat diagnostics'));
      expect(report, isNot(contains('sk-secretsecretsecret')));
      expect(report, isNot(contains('abcdefghijklmnopqrstuvwxyz')));
      expect(report, isNot(contains('data:image/png;base64')));
      expect(report, isNot(contains('aaaaaaaaaaaaaaaaaaaa')));
    });

    test('persisted Developer Mode on is applied once on every restart',
        () async {
      configureAnthropicProfile(
        baseUrl: 'http://127.0.0.1',
        developerMode: true,
      );

      final firstEvents = _CountingRuntimeDebugEventService();
      final firstProvider = ChatProvider(runtimeDebugEvents: firstEvents);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(firstProvider.developerMode, isTrue);
      expect(firstEvents.setTracingEnabledCalls, 1);
      await firstProvider.createSession();
      await firstProvider.buildDiagnosticsReport();
      expect(firstEvents.setTracingEnabledCalls, 1);
      firstEvents.record(RuntimeDebugEvent(
        type: 'stream.started',
        sessionId: 's1',
        data: const {'attempt': 1, 'latencyMs': 1},
      ));
      expect(firstEvents.recent().single.type, 'stream.started');
      firstProvider.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final secondEvents = _CountingRuntimeDebugEventService();
      final secondProvider = ChatProvider(runtimeDebugEvents: secondEvents);
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        secondProvider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(secondProvider.developerMode, isTrue);
      expect(secondEvents.setTracingEnabledCalls, 1);
      secondEvents.record(RuntimeDebugEvent(
        type: 'stream.started',
        sessionId: 's2',
        data: const {'attempt': 1, 'latencyMs': 2},
      ));
      expect(secondEvents.recent().single.type, 'stream.started');
    });

    test('persisted Developer Mode off clears stale capture on every restart',
        () async {
      configureAnthropicProfile(
        baseUrl: 'http://127.0.0.1',
        developerMode: false,
      );

      Future<ChatProvider> startWithStaleCapture(
        _CountingRuntimeDebugEventService events,
      ) async {
        events.setTracingEnabled(true);
        events.record(RuntimeDebugEvent(type: 'stale', sessionId: 's1'));
        events.startRunTrace('s1');
        final provider = ChatProvider(runtimeDebugEvents: events);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return provider;
      }

      final firstEvents = _CountingRuntimeDebugEventService();
      final firstProvider = await startWithStaleCapture(firstEvents);
      expect(firstProvider.developerMode, isFalse);
      expect(firstEvents.setTracingEnabledCalls, 2);
      expect(firstEvents.recent(), isEmpty);
      expect(firstEvents.recentRunTraces(), isEmpty);
      firstEvents.record(RuntimeDebugEvent(type: 'after.off', sessionId: 's1'));
      expect(firstEvents.recent(), isEmpty);
      firstProvider.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final secondEvents = _CountingRuntimeDebugEventService();
      final secondProvider = await startWithStaleCapture(secondEvents);
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        secondProvider.dispose();
      });
      expect(secondProvider.developerMode, isFalse);
      expect(secondEvents.setTracingEnabledCalls, 2);
      expect(secondEvents.recent(), isEmpty);
      expect(secondEvents.recentRunTraces(), isEmpty);
      final report = await secondProvider.buildDiagnosticsReport();
      expect(secondEvents.setTracingEnabledCalls, 2);
      expect(report, contains('Recent events\n- none'));
    });

    test('toggle off clears active concurrent capture and re-enable is fresh',
        () async {
      configureAnthropicProfile(
        baseUrl: 'http://127.0.0.1',
        developerMode: true,
      );
      final events = RuntimeDebugEventService();
      final provider = ChatProvider(runtimeDebugEvents: events);
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      events.startRunTrace('s1');
      events.startRunTrace('s2');
      events.record(RuntimeDebugEvent(
        type: 'tool.attempt.started',
        sessionId: 's1',
        data: const {
          'runAttemptId': 'run-1',
          'operationId': 'op-1',
          'toolName': 'bash',
        },
      ));
      expect(events.recentRunTraces(), hasLength(2));
      expect(events.recent(), isNotEmpty);

      provider.setDeveloperMode(false);
      events.record(RuntimeDebugEvent(
        type: 'tool.attempt.completed',
        sessionId: 's1',
        data: const {'runAttemptId': 'run-1', 'operationId': 'op-1'},
      ));
      expect(provider.developerMode, isFalse);
      expect(events.recent(), isEmpty);
      expect(events.recentRunTraces(), isEmpty);

      provider.setDeveloperMode(true);
      expect(events.recent(), isEmpty);
      expect(events.recentRunTraces(), isEmpty);
      final s1Trace = events.startRunTrace('s1')!;
      final s2Trace = events.startRunTrace('s2')!;
      events.record(RuntimeDebugEvent(
        type: 'stream.started',
        sessionId: 's1',
        data: const {'attempt': 1, 'latencyMs': 1},
      ));
      events.record(RuntimeDebugEvent(
        type: 'model.attempt.started',
        sessionId: 's2',
        data: const {'attempt': 1, 'modelLabel': 'openai/gpt-test'},
      ));
      expect(
        events.runTrace(s1Trace)!.events.map((event) => event.type),
        contains('stream.started'),
      );
      expect(
        events.runTrace(s1Trace)!.events.map((event) => event.type),
        isNot(contains('model.attempt.started')),
      );
      expect(
          events.runTrace(s2Trace)!.events.last.type, 'model.attempt.started');
    });

    test('disabling during a live provider run stops all later capture',
        () async {
      configureAnthropicProfile(
        baseUrl: 'http://127.0.0.1',
        developerMode: true,
      );
      final started = Completer<void>();
      final release = Completer<void>();
      final events = RuntimeDebugEventService();
      final provider = ChatProvider(
        runtimeDebugEvents: events,
        llmServiceFactory: (config, {isInBackground}) => _BlockingLlmService(
          config,
          started: started,
          release: release,
        ),
      );
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await provider.createSession();
      final sendFuture = provider.sendMessage('safe test message');
      await started.future.timeout(const Duration(seconds: 2));
      expect(events.recentRunTraces().single.status, RunTraceStatus.inFlight);
      expect(events.recent(), isNotEmpty);

      provider.setDeveloperMode(false);
      release.complete();
      await sendFuture.timeout(const Duration(seconds: 2));
      events.record(RuntimeDebugEvent(
        type: 'tool.attempt.completed',
        sessionId: provider.currentSession!.id,
        data: const {
          'runAttemptId': 'ignored-run',
          'operationId': 'ignored-operation',
        },
      ));

      expect(provider.developerMode, isFalse);
      expect(events.recent(), isEmpty);
      expect(events.recentRunTraces(), isEmpty);
    });

    test('sendMessage rejects oversized image attachment before persistence',
        () async {
      var requestCount = 0;
      final provider = ChatProvider(
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) {
            requestCount++;
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'ok')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();

      await provider.sendMessage('', attachments: [
        ImageContent(data: 'a' * (4 * 1024 * 1024 + 4), mediaType: 'image/png'),
      ]);

      expect(requestCount, 0);
      expect(provider.errorMessage, contains('图片数据过大'));
      expect(session.messages, isEmpty);
    });
  });

  group('model fallback runtime', () {
    setUp(() async {
      await installPlatformMocks();
      configureModelFallbackProfiles();
    });

    tearDown(() async {
      await clearPlatformMocks();
    });

    test('retryable primary network failure uses configured fallback once',
        () async {
      configureModelFallbackProfiles(developerMode: true);
      final attemptedModels = <String>[];
      final traces = RuntimeDebugEventService(tracingEnabled: true);
      final storage = SessionStorage();
      await storage.init();
      final provider = ChatProvider(
        storage: storage,
        runtimeDebugEvents: traces,
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) {
            attemptedModels.add(config.model);
            if (config.model == 'claude-primary-200k') {
              return StreamError(
                'OpenAI API error (503): temporarily unavailable',
                cause: Exception(
                  'OpenAI API error (503): temporarily unavailable',
                ),
              );
            }
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'fallback ok')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final session = await provider.createSession();
      await provider.sendMessage('hello');

      expect(provider.errorMessage, isNull);
      expect(attemptedModels, ['claude-primary-200k', 'claude-fallback-200k']);
      final messages = provider.currentSession!.messages;
      expect(messages.where((message) => message.role == 'user'), hasLength(1));
      expect(
        messages.where((message) => message.role == 'assistant'),
        hasLength(1),
      );
      expect(
        messages.any((message) =>
            message.isSystemNotice &&
            message.textContent.contains('已改用') &&
            message.textContent.contains('claude-fallback-200k')),
        isTrue,
      );
      expect(messages.toString(), isNot(contains('temporarily unavailable')));
      expect(
        provider.runtimeDebugEvents
            .recent()
            .where((event) => event.type == 'model.fallback.success'),
        hasLength(1),
      );
      final trace = traces.recentRunTraces().single;
      expect(trace.status, RunTraceStatus.completed);
      expect(
        trace.events.where((event) => event.type == 'model.attempt.started'),
        hasLength(2),
      );
      expect(
        trace.events.map((event) => event.type),
        containsAll(['model.fallback.attempt', 'model.fallback.success']),
      );
      expect(trace.events.toString(), isNot(contains('hello')));
      expect(provider.currentInterruptedAgentRun, isNull);
      expect((await storage.getSession(session.id))!.inFlightAgentRun, isNull);

      final reloaded = ChatProvider(storage: storage);
      addTearDown(reloaded.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await reloaded.selectSession(session.id);
      expect(reloaded.currentInterruptedAgentRun, isNull);
    });

    test('recovery fallback success cannot clear unknown tool evidence',
        () async {
      final attemptedModels = <String>[];
      final storage = SessionStorage();
      await storage.init();
      final session = ChatSession(
        id: 'recovery-fallback-unknown-retained',
        messages: [ChatMessage.user('original task')],
        inFlightAgentRun: _unknownRecoveryMarker('fallback-unknown-origin'),
      );
      await storage.saveSession(session);
      final provider = ChatProvider(
        storage: storage,
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) {
            attemptedModels.add(config.model);
            if (config.model == 'claude-primary-200k') {
              return StreamError(
                'OpenAI API error (503): temporarily unavailable',
                cause: Exception('OpenAI API error (503)'),
              );
            }
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'fallback recovered')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await provider.selectSession(session.id);

      await provider.continueInterruptedAgentRun();

      expect(attemptedModels, ['claude-primary-200k', 'claude-fallback-200k']);
      expect(
        provider.currentSession!.messages
            .where((message) => message.role == 'assistant')
            .last
            .textContent,
        'fallback recovered',
      );
      expect(provider.currentInterruptedAgentRun, isNotNull);
      expect(provider.currentInterruptedAgentRun!.recoveryKind,
          InterruptedRunRecoveryKind.unknownOutcome);
      expect(
          (await storage.getSession(session.id))!.inFlightAgentRun, isNotNull);
    });

    test('recovery fallback keeps skill binding and denies undeclared tool',
        () async {
      final storage = SessionStorage();
      await storage.init();
      final verified = _providerVerifiedSkill();
      final session = _skillBoundRecoverySession(
        id: 'recovery-fallback-undeclared',
        activation: verified,
      );
      await storage.saveSession(session);
      final tool = _EchoTool();
      final restoredSkillIds = <String>[];
      final fallbackCalls = <String, int>{};
      final provider = ChatProvider(
        storage: storage,
        toolRegistry: ToolRegistry()..register(tool, risk: ToolRisk.dangerous),
        skillCapabilityPolicyFactory: (domains) => SkillCapabilityPolicy(
          fixedToolDomains: domains,
          loader: (id) async {
            restoredSkillIds.add(id);
            return verified;
          },
        ),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) {
            if (config.model == 'claude-primary-200k') {
              return StreamError(
                'OpenAI API error (503): temporarily unavailable',
                cause: Exception('OpenAI API error (503)'),
              );
            }
            final call = (fallbackCalls[config.model] ?? 0) + 1;
            fallbackCalls[config.model] = call;
            if (call == 1) {
              return StreamDone(const LlmResponse(
                stopReason: 'tool_use',
                content: [
                  ContentBlock(
                    type: 'tool_use',
                    toolUseId: 'fallback_undeclared',
                    toolName: 'echo',
                    toolInput: {'text': 'blocked'},
                  ),
                ],
              ));
            }
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'denial handled')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      PreferencesService().toolApprovalPolicy =
          PreferencesService.toolApprovalAuto;
      await provider.selectSession(session.id);

      await provider.continueInterruptedAgentRun();

      expect(restoredSkillIds, [verified.id, verified.id]);
      expect(tool.executionCount, 0);
      expect(provider.pendingApproval, isNull);
      expect(
        provider.currentSession!.messages
            .expand((message) => message.toolResults)
            .singleWhere(
              (result) => result.toolUseId == 'fallback_undeclared',
            )
            .output,
        contains('did not declare tool'),
      );
      expect(
        provider.currentSession!.messages
            .where((message) => message.role == 'assistant')
            .last
            .textContent,
        'denial handled',
      );
    });

    test('declared recovery fallback tool still requires renewed approval',
        () async {
      final storage = SessionStorage();
      await storage.init();
      final verified = _providerVerifiedSkill(tools: const ['echo']);
      final session = _skillBoundRecoverySession(
        id: 'recovery-fallback-declared',
        activation: verified,
      );
      await storage.saveSession(session);
      final tool = _EchoTool();
      final fallbackCalls = <String, int>{};
      final provider = ChatProvider(
        storage: storage,
        toolRegistry: ToolRegistry()..register(tool, risk: ToolRisk.dangerous),
        skillCapabilityPolicyFactory: (domains) => SkillCapabilityPolicy(
          fixedToolDomains: domains,
          loader: (_) async => verified,
        ),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) {
            if (config.model == 'claude-primary-200k') {
              return StreamError(
                'OpenAI API error (503): temporarily unavailable',
                cause: Exception('OpenAI API error (503)'),
              );
            }
            final call = (fallbackCalls[config.model] ?? 0) + 1;
            fallbackCalls[config.model] = call;
            if (call == 1) {
              return StreamDone(const LlmResponse(
                stopReason: 'tool_use',
                content: [
                  ContentBlock(
                    type: 'tool_use',
                    toolUseId: 'fallback_declared',
                    toolName: 'echo',
                    toolInput: {'text': 'approved'},
                  ),
                ],
              ));
            }
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'approved done')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      PreferencesService().toolApprovalPolicy =
          PreferencesService.toolApprovalAuto;
      await provider.selectSession(session.id);

      final recovery = provider.continueInterruptedAgentRun();
      await _waitUntil(() => provider.pendingApproval != null);

      expect(tool.executionCount, 0);
      final replacement = (await storage.getSession(session.id))!
          .inFlightAgentRun!
          .skillActivation!;
      expect(replacement.sourceRunAttemptId, 'skill-origin-run');
      expect(replacement.skillId, verified.id);
      expect(replacement.trustDigest, verified.trustDigest);
      provider.resolveToolApproval(
        operationId: provider.pendingApproval!.operationId,
        approved: true,
      );
      await recovery;

      expect(tool.executionCount, 1);
      expect(provider.pendingApproval, isNull);
      expect(
        provider.currentSession!.messages
            .where((message) => message.role == 'assistant')
            .last
            .textContent,
        'approved done',
      );
    });

    test('stale recovery skill grant stays fail closed across fallback',
        () async {
      final storage = SessionStorage();
      await storage.init();
      final verified = _providerVerifiedSkill(tools: const ['echo']);
      final session = _skillBoundRecoverySession(
        id: 'recovery-fallback-stale',
        activation: verified,
      );
      session.messages
          .expand((message) => message.toolResults)
          .single
          .metadata['skillRunAttemptId'] = 'unrelated-history-run';
      session.inFlightAgentRun = session.inFlightAgentRun!.copyWith(
        skillActivation: RecoverySkillActivationMetadata(
          sourceRunAttemptId: 'skill-origin-run',
          skillId: verified.id,
          trustDigest: verified.trustDigest,
        ),
      );
      await storage.saveSession(session);
      final tool = _EchoTool();
      var restoreAttempts = 0;
      var fallbackRequestCount = 0;
      final provider = ChatProvider(
        storage: storage,
        toolRegistry: ToolRegistry()..register(tool, risk: ToolRisk.dangerous),
        skillCapabilityPolicyFactory: (domains) => SkillCapabilityPolicy(
          fixedToolDomains: domains,
          loader: (_) async {
            restoreAttempts++;
            throw StateError('grant changed');
          },
        ),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) {
            if (config.model == 'claude-primary-200k') {
              return StreamError(
                'OpenAI API error (503): temporarily unavailable',
                cause: Exception('OpenAI API error (503)'),
              );
            }
            fallbackRequestCount++;
            if (fallbackRequestCount == 1) {
              return StreamDone(const LlmResponse(
                stopReason: 'tool_use',
                content: [
                  ContentBlock(
                    type: 'tool_use',
                    toolUseId: 'fallback_stale',
                    toolName: 'echo',
                    toolInput: {'text': 'must not run'},
                  ),
                ],
              ));
            }
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'stale handled')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      PreferencesService().toolApprovalPolicy =
          PreferencesService.toolApprovalAuto;
      await provider.selectSession(session.id);

      await provider.continueInterruptedAgentRun();

      expect(restoreAttempts, 2);
      expect(tool.executionCount, 0);
      expect(provider.pendingApproval, isNull);
      expect(
        provider.currentSession!.messages
            .expand((message) => message.toolResults)
            .singleWhere((result) => result.toolUseId == 'fallback_stale')
            .output,
        contains('stale'),
      );
    });

    test('model group session uses group primary and fallback chain', () async {
      final active = ProviderProfile.defaults(name: 'Active').copyWith(
        id: 'active',
        apiKey: 'sk-test-active',
        apiFormat: ProviderProfile.anthropicFormat,
        baseUrl: 'http://active.test',
        model: 'active-model',
      );
      final groupPrimary =
          ProviderProfile.defaults(name: 'Group Primary').copyWith(
        id: 'group-primary',
        apiKey: 'sk-test-group-primary',
        apiFormat: ProviderProfile.anthropicFormat,
        baseUrl: 'http://group-primary.test',
        model: 'group-primary-model',
      );
      final groupFallback =
          ProviderProfile.defaults(name: 'Group Fallback').copyWith(
        id: 'group-fallback',
        apiKey: 'sk-test-group-fallback',
        apiFormat: ProviderProfile.anthropicFormat,
        baseUrl: 'http://group-fallback.test',
        model: 'group-fallback-model',
      );
      final group = ModelGroup(
        id: 'analysis-group',
        name: 'Analysis Group',
        primaryProfileId: 'group-primary',
        fallbackTargets: const [
          ModelFallbackTarget(targetProfileId: 'group-fallback'),
        ],
      );
      secureStorage['provider_profiles'] = jsonEncode([
        active.toJson(),
        groupPrimary.toJson(),
        groupFallback.toJson(),
      ]);
      SharedPreferences.setMockInitialValues({
        'active_provider_profile_id': 'active',
        'model_groups': jsonEncode([group.toJson()]),
        'context_token_budget': 65536,
        'developer_mode': true,
      });

      final attemptedModels = <String>[];
      final provider = ChatProvider(
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) {
            attemptedModels.add(config.model);
            if (config.model == 'group-primary-model') {
              return StreamError(
                'OpenAI API error (503): temporarily unavailable',
                cause: Exception(
                  'OpenAI API error (503): temporarily unavailable',
                ),
              );
            }
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'group fallback ok')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await provider.createSession(modelGroupId: 'analysis-group');
      await provider.sendMessage('hello');

      expect(provider.currentSession!.modelGroupId, 'analysis-group');
      expect(attemptedModels, ['group-primary-model', 'group-fallback-model']);
      expect(
        provider.currentSession!.messages
            .where((message) => message.role == 'assistant')
            .single
            .textContent,
        'group fallback ok',
      );
    });

    test('rolls back primary context patch before fallback success', () async {
      configureModelFallbackProfiles(contextTokenBudget: 4096);
      final summaryModels = <String>[];
      final attemptedModels = <String>[];
      final provider = ChatProvider(
        contextSummaryServiceFactory: () => _ScriptedContextSummaryService(
          onGenerate: (request) {
            summaryModels.add(request.llmConfig.model);
            return _summaryForRequestWithModel(request);
          },
        ),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) {
            attemptedModels.add(config.model);
            if (config.model == 'claude-primary-200k') {
              return StreamError(
                'OpenAI API error (503): temporarily unavailable',
                cause: Exception('OpenAI API error (503)'),
              );
            }
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'fallback ok')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final session = await provider.createSession();
      session.messages.addAll(_longContextMessages());

      await provider.sendMessage('final question');

      expect(provider.errorMessage, isNull);
      expect(attemptedModels, ['claude-primary-200k', 'claude-fallback-200k']);
      expect(summaryModels, ['claude-primary-200k', 'claude-fallback-200k']);
      expect(provider.currentContextSummary?.model, 'claude-fallback-200k');
      final contextNoticeCount = provider.currentSession!.messages
          .where((message) =>
              message.isSystemNotice && message.textContent.contains('已压缩为摘要'))
          .length;
      expect(contextNoticeCount, 1);
    });

    test('stream completeness error before visible output can fallback',
        () async {
      final attemptedModels = <String>[];
      final provider = ChatProvider(
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) {
            attemptedModels.add(config.model);
            if (config.model == 'claude-primary-200k') {
              return StreamError(
                'OpenAI stream interrupted: ended without finish_reason',
              );
            }
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'fallback ok')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await provider.createSession();
      await provider.sendMessage('hello');

      expect(provider.errorMessage, isNull);
      expect(attemptedModels, ['claude-primary-200k', 'claude-fallback-200k']);
      expect(
        provider.currentSession!.messages
            .where((message) => message.role == 'assistant')
            .single
            .textContent,
        'fallback ok',
      );
    });

    test(
        'guarded stream failure rolls back primary patch and falls back cleanly',
        () async {
      configureModelFallbackProfiles(
        contextTokenBudget: 4096,
        developerMode: true,
      );
      final traces = RuntimeDebugEventService(tracingEnabled: true);
      final summaryModels = <String>[];
      final attemptedModels = <String>[];
      var fallbackCreated = false;
      final provider = ChatProvider(
        runtimeDebugEvents: traces,
        contextSummaryServiceFactory: () => _ScriptedContextSummaryService(
          onGenerate: (request) {
            summaryModels.add(request.llmConfig.model);
            return _summaryForRequestWithModel(request);
          },
        ),
        llmServiceFactory: (config, {isInBackground}) {
          if (config.model == 'claude-fallback-200k') {
            fallbackCreated = true;
          }
          return _ScriptedLlmService(
            config,
            onMessages: (_) => StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'unused')],
            )),
            onMessageEvents: (_) {
              attemptedModels.add(config.model);
              if (config.model == 'claude-primary-200k') {
                return [
                  TextDelta('partial streamed text'),
                  ReasoningDelta('partial guarded reasoning'),
                  StreamError(
                    'OpenAI API error (503): temporarily unavailable',
                    cause: Exception('OpenAI API error (503)'),
                  ),
                ];
              }
              return [
                StreamDone(const LlmResponse(
                  stopReason: 'end_turn',
                  content: [ContentBlock(type: 'text', text: 'fallback')],
                )),
              ];
            },
          );
        },
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final session = await provider.createSession();
      session.messages.addAll(_longContextMessages());
      final assistantCountBefore = session.messages
          .where((message) => message.role == 'assistant')
          .length;

      await provider.sendMessage('final question');

      expect(provider.errorMessage, isNull);
      expect(
        attemptedModels,
        ['claude-primary-200k', 'claude-fallback-200k'],
      );
      expect(
        summaryModels,
        ['claude-primary-200k', 'claude-fallback-200k'],
      );
      expect(fallbackCreated, isTrue);
      expect(provider.currentContextSummary!.model, 'claude-fallback-200k');
      expect(
        provider.currentSession!.messages.where((message) =>
            message.isSystemNotice && message.textContent.contains('已压缩为摘要')),
        hasLength(1),
      );
      expect(
        provider.currentSession!.messages
            .where((message) => message.role == 'assistant'),
        hasLength(assistantCountBefore + 1),
      );
      expect(
        provider.currentSession!.messages
            .where((message) => message.role == 'assistant')
            .last
            .textContent,
        'fallback',
      );
      expect(
        provider.currentSession!.messages
            .map((message) => message.textContent)
            .join('\n'),
        isNot(contains('partial streamed text')),
      );
      expect(
        provider.currentSession!.messages
            .map((message) => message.textContent)
            .join('\n'),
        isNot(contains('partial guarded reasoning')),
      );
      expect(
        provider.runtimeDebugEvents.recent().any(
              (event) => event.type == 'model.fallback.success',
            ),
        isTrue,
      );
      final trace = traces.recentRunTraces().single;
      expect(trace.status, RunTraceStatus.completed);
      final terminals = trace.events
          .where((event) => event.type == 'stream.terminal')
          .toList();
      expect(terminals, hasLength(2));
      expect(terminals.first.data['status'], 'failed');
      expect(terminals.first.data['completeness'], 'partial');
      expect(terminals.last.data['status'], 'completed');
      expect(
        trace.events.where((event) => event.type == 'run.terminal'),
        hasLength(1),
      );
      expect(trace.events.toString(), isNot(contains('partial streamed text')));
      expect(
        trace.events.toString(),
        isNot(contains('partial guarded reasoning')),
      );
    });

    test('stream reset discards guarded attempts before clean fallback',
        () async {
      final provider = ChatProvider(
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => StreamDone(const LlmResponse(
            stopReason: 'end_turn',
            content: [ContentBlock(type: 'text', text: 'unused')],
          )),
          onMessageEvents: (_) => config.model == 'claude-primary-200k'
              ? [
                  TextDelta('dirty first attempt'),
                  const StreamReset(),
                  TextDelta('clean retry partial'),
                  StreamError(
                    'OpenAI API error (503): temporarily unavailable',
                    cause: Exception('OpenAI API error (503)'),
                  ),
                ]
              : [
                  StreamDone(const LlmResponse(
                    stopReason: 'end_turn',
                    content: [
                      ContentBlock(type: 'text', text: 'fallback after reset'),
                    ],
                  )),
                ],
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await provider.createSession();
      await provider.sendMessage('hello');

      final transcript = provider.currentSession!.messages
          .map((message) => message.textContent)
          .join('\n');
      expect(transcript, isNot(contains('dirty first attempt')));
      expect(transcript, isNot(contains('clean retry partial')));
      expect(transcript, contains('fallback after reset'));
      expect(
        provider.currentSession!.messages.any(
          (message) => message.hasAssistantError,
        ),
        isFalse,
      );
    });

    test('user cancellation after guarded output never starts fallback',
        () async {
      const sentinel = 'cancelled-guarded-fallback-sentinel';
      final buffered = Completer<void>();
      final release = Completer<void>();
      final createdModels = <String>[];
      final provider = ChatProvider(
        llmServiceFactory: (config, {isInBackground}) {
          createdModels.add(config.model);
          if (config.model == 'claude-primary-200k') {
            return _GuardedSecretPauseLlmService(
              config,
              sentinel: sentinel,
              buffered: buffered,
              release: release,
            );
          }
          return _ScriptedLlmService(
            config,
            onMessages: (_) => StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'must not appear')],
            )),
          );
        },
      );
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await provider.createSession();
      final send = provider.sendMessage('cancel guarded response');
      await buffered.future.timeout(const Duration(seconds: 2));
      final cancel = provider.cancelAgent(savePartial: true);
      release.complete();
      await cancel;
      await send;

      expect(createdModels, ['claude-primary-200k']);
      expect(
        provider.currentSession!.messages
            .map((message) => message.textContent)
            .join('\n'),
        isNot(contains(sentinel)),
      );
      expect(
        provider.runtimeDebugEvents.recent().any(
              (event) => event.type == 'model.fallback.attempt',
            ),
        isFalse,
      );
    });

    test('stream reset shows reconnecting notice until retry text arrives',
        () async {
      final resetEmitted = Completer<void>();
      final continueAfterReset = Completer<void>();
      final cleanTokenEmitted = Completer<void>();
      final finishStream = Completer<void>();
      final provider = ChatProvider(
        llmServiceFactory: (config, {isInBackground}) => _ResetPauseLlmService(
          config,
          resetEmitted: resetEmitted,
          continueAfterReset: continueAfterReset,
          cleanTokenEmitted: cleanTokenEmitted,
          finishStream: finishStream,
        ),
      );
      addTearDown(() async {
        if (!continueAfterReset.isCompleted) continueAfterReset.complete();
        if (!finishStream.isCompleted) finishStream.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await provider.createSession();
      final sendFuture = provider.sendMessage('hello');

      await resetEmitted.future.timeout(const Duration(seconds: 2));
      await _waitUntil(() => provider.streamingText.contains('连接中断'));
      expect(provider.agentStatus, AgentStatus.thinking);
      expect(provider.streamingText, isNot(contains('dirty first attempt')));

      continueAfterReset.complete();
      await cleanTokenEmitted.future.timeout(const Duration(seconds: 2));
      expect(provider.streamingText, contains('连接中断'));
      expect(provider.streamingText, isNot(contains('clean retry text')));
      expect(provider.agentStatus, AgentStatus.thinking);

      finishStream.complete();
      await sendFuture.timeout(const Duration(seconds: 2));
      expect(provider.currentSession!.messages.last.textContent,
          'clean retry text');
    });

    test('context patch rollback preserves interleaved non-patch messages', () {
      const notices = [
        ContextNotice.summaryCompacted(4),
        ContextNotice.truncated(
          droppedMessageCount: 2,
          droppedBlockCount: 0,
          estimatedTokens: 128,
        ),
      ];
      final summaryNotice = AppStrings.contextSummaryCompactedNotice(4);
      final truncationNotice = AppStrings.contextCompactedNotice(2, 128);

      final assistantBetweenNotices = [
        ChatMessage.user('before patch'),
        ChatMessage.systemNotice(summaryNotice),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('partial assistant survives')],
        ),
        ChatMessage.systemNotice(truncationNotice),
        ChatMessage.systemNotice('unrelated notice survives'),
      ];

      expect(
        ChatProvider.removeContextPatchNoticesForTesting(
          assistantBetweenNotices,
          startIndex: 1,
          notices: notices,
        ),
        2,
      );
      expect(
        assistantBetweenNotices.map((message) => message.textContent),
        [
          'before patch',
          'partial assistant survives',
          'unrelated notice survives',
        ],
      );

      final unrelatedNoticeBetweenPatchNotices = [
        ChatMessage.user('before patch'),
        ChatMessage.systemNotice('unrelated notice before patch'),
        ChatMessage.systemNotice(summaryNotice),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('partial assistant still survives')],
        ),
        ChatMessage.systemNotice('unrelated notice between patch notices'),
        ChatMessage.systemNotice(truncationNotice),
      ];

      expect(
        ChatProvider.removeContextPatchNoticesForTesting(
          unrelatedNoticeBetweenPatchNotices,
          startIndex: 1,
          notices: notices,
        ),
        2,
      );
      expect(
        unrelatedNoticeBetweenPatchNotices
            .map((message) => message.textContent),
        [
          'before patch',
          'unrelated notice before patch',
          'partial assistant still survives',
          'unrelated notice between patch notices',
        ],
      );
    });

    test('cancel before persisted messages rolls back primary patch', () async {
      configureModelFallbackProfiles(
        contextTokenBudget: 4096,
        developerMode: true,
      );
      final traces = RuntimeDebugEventService(tracingEnabled: true);
      final started = Completer<void>();
      final release = Completer<void>();
      final summaryModels = <String>[];
      var fallbackCreated = false;
      final provider = ChatProvider(
        runtimeDebugEvents: traces,
        contextSummaryServiceFactory: () => _ScriptedContextSummaryService(
          onGenerate: (request) {
            summaryModels.add(request.llmConfig.model);
            return _summaryForRequestWithModel(request);
          },
        ),
        llmServiceFactory: (config, {isInBackground}) {
          if (config.model == 'claude-fallback-200k') {
            fallbackCreated = true;
            return _ScriptedLlmService(
              config,
              onMessages: (_) => StreamDone(const LlmResponse(
                stopReason: 'end_turn',
                content: [ContentBlock(type: 'text', text: 'fallback')],
              )),
            );
          }
          return _BlockingLlmService(
            config,
            started: started,
            release: release,
          );
        },
      );
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final session = await provider.createSession();
      session.messages.addAll(_longContextMessages());
      final assistantCountBefore = session.messages
          .where((message) => message.role == 'assistant')
          .length;

      final sendFuture = provider.sendMessage('final question');
      await started.future.timeout(const Duration(seconds: 2));
      expect(provider.currentContextSummary?.model, 'claude-primary-200k');

      await provider.cancelAgent();
      await sendFuture.timeout(const Duration(seconds: 2));

      expect(summaryModels, ['claude-primary-200k']);
      expect(fallbackCreated, isFalse);
      expect(provider.currentContextSummary, isNull);
      expect(
        provider.currentSession!.messages.where((message) =>
            message.isSystemNotice && message.textContent.contains('已压缩为摘要')),
        isEmpty,
      );
      expect(
        provider.currentSession!.messages
            .where((message) => message.role == 'assistant'),
        hasLength(assistantCountBefore),
      );
      expect(provider.isSessionSending(provider.currentSession!.id), isFalse);
      expect(traces.recentRunTraces().single.status, RunTraceStatus.cancelled);
    });

    test('successful primary keeps context patch', () async {
      configureModelFallbackProfiles(
        contextTokenBudget: 4096,
        developerMode: true,
      );
      final traces = RuntimeDebugEventService(tracingEnabled: true);
      final summaryModels = <String>[];
      final attemptedModels = <String>[];
      final provider = ChatProvider(
        runtimeDebugEvents: traces,
        contextSummaryServiceFactory: () => _ScriptedContextSummaryService(
          onGenerate: (request) {
            summaryModels.add(request.llmConfig.model);
            return _summaryForRequestWithModel(request);
          },
        ),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) {
            attemptedModels.add(config.model);
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'primary ok')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final session = await provider.createSession();
      session.messages.addAll(_longContextMessages());

      await provider.sendMessage('final question');

      expect(provider.errorMessage, isNull);
      expect(attemptedModels, ['claude-primary-200k']);
      expect(summaryModels, ['claude-primary-200k']);
      expect(provider.currentContextSummary?.model, 'claude-primary-200k');
      final trace = traces.recentRunTraces().single;
      expect(trace.status, RunTraceStatus.completed);
      expect(
        trace.events.map((event) => event.type),
        containsAll([
          'context.assembly.started',
          'context.assembly.completed',
          'stream.started',
          'stream.terminal',
          'run.terminal',
        ]),
      );
      expect(
        provider.currentSession!.messages.where((message) =>
            message.isSystemNotice && message.textContent.contains('已压缩为摘要')),
        hasLength(1),
      );
    });

    test('fallback notices and events omit profile display names', () async {
      const sensitiveDisplayName = 'Confidential Project Phoenix';
      final fallback = ProviderProfile.defaults(
        name: sensitiveDisplayName,
      ).copyWith(
        id: 'fallback',
        apiKey: 'sk-test-fallback',
        apiFormat: ProviderProfile.anthropicFormat,
        baseUrl: 'http://fallback.test',
        model: 'claude-fallback-200k',
      );
      configureModelFallbackProfiles(fallbackProfiles: [fallback]);
      final provider = ChatProvider(
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) {
            if (config.model == 'claude-primary-200k') {
              return StreamError(
                'OpenAI API error (503): temporarily unavailable',
                cause: Exception('OpenAI API error (503)'),
              );
            }
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'fallback ok')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await provider.createSession();
      await provider.sendMessage('hello');

      final messageText = provider.currentSession!.messages
          .map((message) => message.textContent)
          .join('\n');
      final eventText = provider.runtimeDebugEvents
          .recent()
          .map((event) => '${event.type} ${event.data}')
          .join('\n');
      expect(messageText, contains('claude-fallback-200k'));
      expect(eventText, contains('claude-fallback-200k'));
      expect(messageText, isNot(contains(sensitiveDisplayName)));
      expect(eventText, isNot(contains(sensitiveDisplayName)));
    });

    test('uses original profile snapshot when profiles change in flight',
        () async {
      final primaryStarted = Completer<void>();
      final primaryRelease = Completer<void>();
      final createdModels = <String>[];
      final attemptedModels = <String>[];
      final provider = ChatProvider(
        llmServiceFactory: (config, {isInBackground}) {
          createdModels.add(config.model);
          if (config.model == 'claude-primary-200k') {
            return _BlockingLlmService(
              config,
              started: primaryStarted,
              release: primaryRelease,
              completionEvent: StreamError(
                'OpenAI API error (503): temporarily unavailable',
                cause: Exception('OpenAI API error (503)'),
              ),
            );
          }
          return _ScriptedLlmService(
            config,
            onMessages: (_) {
              attemptedModels.add(config.model);
              return StreamDone(LlmResponse(
                stopReason: 'end_turn',
                content: [
                  ContentBlock(type: 'text', text: 'used ${config.model}'),
                ],
              ));
            },
          );
        },
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await provider.createSession();
      final sendFuture = provider.sendMessage('hello');
      await primaryStarted.future.timeout(const Duration(seconds: 2));

      final profileB = ProviderProfile.defaults(name: 'Profile B').copyWith(
        id: 'profile_b',
        apiKey: 'sk-test-profile-b',
        apiFormat: ProviderProfile.anthropicFormat,
        baseUrl: 'http://profile-b.test',
        model: 'claude-profile-b-200k',
        fallbackTargets: const [
          ModelFallbackTarget(targetProfileId: 'fallback_b'),
        ],
      );
      final fallbackB = ProviderProfile.defaults(name: 'Fallback B').copyWith(
        id: 'fallback_b',
        apiKey: 'sk-test-fallback-b',
        apiFormat: ProviderProfile.anthropicFormat,
        baseUrl: 'http://fallback-b.test',
        model: 'claude-fallback-b-200k',
      );
      await ConfigExportService.importConfig(
        jsonEncode({
          'version': 1,
          'exportedAt': DateTime.utc(2026).toIso8601String(),
          'settings': {},
          'secrets': {
            'encrypted': false,
            'providerProfiles': [profileB.toJson(), fallbackB.toJson()],
            'envVars': {},
          },
        }),
        conflictResolution: ConflictResolution.replace,
      );

      primaryRelease.complete();
      await sendFuture.timeout(const Duration(seconds: 2));

      expect(provider.errorMessage, isNull);
      expect(createdModels, contains('claude-primary-200k'));
      expect(createdModels, contains('claude-fallback-200k'));
      expect(createdModels, isNot(contains('claude-profile-b-200k')));
      expect(createdModels, isNot(contains('claude-fallback-b-200k')));
      expect(attemptedModels, ['claude-fallback-200k']);
      expect(
        provider.currentSession!.messages
            .where((message) => message.role == 'assistant')
            .single
            .textContent,
        contains('claude-fallback-200k'),
      );
    });

    test('auth failure does not fallback and displayed error is sanitized',
        () async {
      final attemptedModels = <String>[];
      const secret = 'sk-proj-abcdefghijklmnopqrstuvwxyz123456';
      final provider = ChatProvider(
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) {
            attemptedModels.add(config.model);
            return StreamError(
              'OpenAI API error (401): api_key=$secret invalid',
              cause: Exception(
                'OpenAI API error (401): api_key=$secret invalid',
              ),
            );
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await provider.createSession();
      await provider.sendMessage('hello');

      expect(attemptedModels, ['claude-primary-200k']);
      expect(provider.errorMessage, contains('[redacted: api_key]'));
      expect(provider.errorMessage, isNot(contains(secret)));
      expect(provider.currentSession!.messages, hasLength(2));
      final errorMarker = provider.currentSession!.messages.last;
      expect(errorMarker.hasAssistantError, isTrue);
      expect(errorMarker.assistantError!.code, 'auth_or_permission');
      expect(errorMarker.assistantError!.canRetry, isTrue);
      expect(
          errorMarker.assistantError!.message, contains('[redacted: api_key]'));
      expect(errorMarker.assistantError!.message, isNot(contains(secret)));
      expect(
        provider.currentSession!.messages
            .where((message) => message.isSystemNotice),
        isEmpty,
      );
    });

    test('skips fallback candidates lacking tools vision or reasoning',
        () async {
      final fallbackProfiles = [
        ProviderProfile.defaults().copyWith(
          id: 'no_tools',
          name: 'No Tools',
          apiKey: 'sk-test-no-tools',
          apiFormat: ProviderProfile.anthropicFormat,
          baseUrl: 'http://no-tools.test',
          model: 'claude-no-tools-200k',
          thinkingBudget: 4096,
          capabilityOverride:
              const caps.CapabilityOverride(supportsTools: false),
        ),
        ProviderProfile.defaults().copyWith(
          id: 'no_vision',
          name: 'No Vision',
          apiKey: 'sk-test-no-vision',
          apiFormat: ProviderProfile.anthropicFormat,
          baseUrl: 'http://no-vision.test',
          model: 'claude-no-vision-200k',
          thinkingBudget: 4096,
          capabilityOverride:
              const caps.CapabilityOverride(supportsImages: false),
        ),
        ProviderProfile.defaults().copyWith(
          id: 'no_reasoning',
          name: 'No Reasoning',
          apiKey: 'sk-test-no-reasoning',
          apiFormat: ProviderProfile.openaiFormat,
          baseUrl: 'http://openai-compatible.test',
          model: 'gpt-4o-200k',
          thinkingBudget: 4096,
        ),
        ProviderProfile.defaults().copyWith(
          id: 'good',
          name: 'Good',
          apiKey: 'sk-test-good',
          apiFormat: ProviderProfile.anthropicFormat,
          baseUrl: 'http://good.test',
          model: 'claude-good-200k',
          thinkingBudget: 4096,
        ),
      ];
      configureModelFallbackProfiles(
        primaryThinkingBudget: 4096,
        fallbackProfiles: fallbackProfiles,
        targets: const [
          ModelFallbackTarget(targetProfileId: 'no_tools'),
          ModelFallbackTarget(targetProfileId: 'no_vision'),
          ModelFallbackTarget(targetProfileId: 'no_reasoning'),
          ModelFallbackTarget(targetProfileId: 'good'),
        ],
      );
      final attemptedModels = <String>[];
      final createdModels = <String>[];
      final provider = ChatProvider(
        llmServiceFactory: (config, {isInBackground}) {
          createdModels.add(config.model);
          return _ScriptedLlmService(
            config,
            onMessages: (_) {
              attemptedModels.add(config.model);
              if (config.model == 'claude-primary-200k') {
                return StreamError(
                  'OpenAI API error (503): temporarily unavailable',
                  cause: Exception('OpenAI API error (503)'),
                );
              }
              return StreamDone(const LlmResponse(
                stopReason: 'end_turn',
                content: [ContentBlock(type: 'text', text: 'good fallback')],
              ));
            },
          );
        },
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await provider.createSession();
      await provider.sendMessage('describe image', attachments: [
        ImageContent(data: 'abc123', mediaType: 'image/png'),
      ]);

      expect(provider.errorMessage, isNull);
      expect(
          createdModels,
          containsAll([
            'claude-no-tools-200k',
            'claude-no-vision-200k',
            'gpt-4o-200k',
            'claude-good-200k',
          ]));
      expect(attemptedModels, ['claude-primary-200k', 'claude-good-200k']);
      final skipReasons = provider.runtimeDebugEvents
          .recent()
          .where((event) => event.type == 'model.fallback.skipped')
          .map((event) => event.data['reason'])
          .toSet();
      expect(skipReasons, contains('tools_not_supported'));
      expect(skipReasons, contains('vision_not_supported'));
      expect(skipReasons, contains('reasoning_not_supported'));
    });

    test('does not fallback after tool execution has started', () async {
      var fallbackCreated = false;
      var primaryCalls = 0;
      final tools = ToolRegistry()..register(_EchoTool(), risk: ToolRisk.safe);
      final provider = ChatProvider(
        toolRegistry: tools,
        llmServiceFactory: (config, {isInBackground}) {
          if (config.model == 'claude-fallback-200k') {
            fallbackCreated = true;
          }
          return _ScriptedLlmService(
            config,
            onMessages: (_) => StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'unused')],
            )),
            onMessageEvents: (_) {
              if (config.model != 'claude-primary-200k') {
                return [
                  StreamDone(const LlmResponse(
                    stopReason: 'end_turn',
                    content: [ContentBlock(type: 'text', text: 'unused')],
                  )),
                ];
              }
              primaryCalls++;
              if (primaryCalls == 1) {
                return [
                  StreamDone(const LlmResponse(
                    stopReason: 'tool_use',
                    content: [
                      ContentBlock(
                        type: 'tool_use',
                        toolUseId: 'toolu_1',
                        toolName: 'echo',
                        toolInput: {'text': 'hello'},
                      ),
                    ],
                  )),
                ];
              }
              return [
                StreamError(
                  'OpenAI API error (503): temporarily unavailable',
                  cause: Exception('OpenAI API error (503)'),
                ),
              ];
            },
          );
        },
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await provider.createSession();
      await provider.sendMessage('use echo');

      expect(fallbackCreated, isFalse);
      expect(provider.errorMessage, isNotNull);
      expect(
        provider.currentSession!.messages
            .expand((message) => message.toolResults)
            .map((result) => result.output),
        contains('hello'),
      );
      expect(
        provider.runtimeDebugEvents.recent().any((event) =>
            event.type == 'model.fallback.skipped' &&
            event.data['reason'] == 'unsafe_after_partial_run'),
        isTrue,
      );
    });

    test('disposes primary on fallback switch and fallback on cancel',
        () async {
      final primaryDisposed = Completer<void>();
      final fallbackStarted = Completer<void>();
      final fallbackRelease = Completer<void>();
      final fallbackDisposed = Completer<void>();
      final provider = ChatProvider(
        llmServiceFactory: (config, {isInBackground}) {
          if (config.model == 'claude-primary-200k') {
            return _ScriptedLlmService(
              config,
              onMessages: (_) => StreamError(
                'OpenAI API error (503): temporarily unavailable',
                cause: Exception('OpenAI API error (503)'),
              ),
              onDispose: () {
                if (!primaryDisposed.isCompleted) primaryDisposed.complete();
              },
            );
          }
          return _BlockingLlmService(
            config,
            started: fallbackStarted,
            release: fallbackRelease,
            disposed: fallbackDisposed,
          );
        },
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await provider.createSession();
      final sendFuture = provider.sendMessage('hello');
      await fallbackStarted.future.timeout(const Duration(seconds: 2));

      await provider.cancelAgent();
      await primaryDisposed.future.timeout(const Duration(seconds: 2));
      await fallbackDisposed.future.timeout(const Duration(seconds: 2));
      await sendFuture.timeout(const Duration(seconds: 2));

      expect(provider.agentStatus, AgentStatus.idle);
      expect(provider.isSessionSending(provider.currentSession!.id), isFalse);
      expect(provider.currentSession!.messages, hasLength(1));
    });
  });

  group('encrypted content recovery', () {
    setUp(() async {
      await installPlatformMocks();
      configureAnthropicProfile(baseUrl: 'http://127.0.0.1');
    });

    tearDown(() async {
      await clearPlatformMocks();
    });

    test('persists sanitized history so the next send does not recover again',
        () async {
      var requestCount = 0;
      final provider = ChatProvider(
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (messages) {
            requestCount++;
            final serialized = messages.toString();
            if (serialized.contains('reasoning_content')) {
              return StreamError(
                'encrypted',
                cause: const EncryptedContentError(
                  'Anthropic API error: invalid_encrypted_content: encrypted',
                  code: 'invalid_encrypted_content',
                ),
              );
            }
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'ok')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final timestamp = DateTime(2026, 1, 2, 3, 4, 5);
      final session = await provider.createSession();
      session.messages.add(ChatMessage.systemNotice('before recovery'));
      session.messages.add(ChatMessage(
        role: 'assistant',
        content: [
          TextContent('cached', reasoningContent: 'hidden reasoning'),
          ImageContent(
            data: 'abc',
            mediaType: 'image/png',
            filename: 'screenshot.png',
          ),
        ],
        timestamp: timestamp,
        inputTokens: 11,
        outputTokens: 22,
        alternatives: ['previous answer'],
        activeAlternative: -1,
      ));

      await provider.sendMessage('first');
      expect(provider.errorMessage, isNull);
      expect(requestCount, 2);
      expect(provider.currentSession!.toApiMessages().toString(),
          isNot(contains('reasoning_content')));
      expect(
        provider.currentSession!.messages.any((m) =>
            m.isSystemNotice && m.textContent == '检测到缓存上下文失效，已自动恢复对话上下文'),
        isTrue,
      );
      expect(provider.currentSession!.messages.first.isSystemNotice, isTrue);
      expect(provider.currentSession!.messages.first.textContent,
          'before recovery');
      final sanitizedAssistant = provider.currentSession!.messages.firstWhere(
        (m) => m.role == 'assistant' && !m.isSystemNotice,
      );
      expect(sanitizedAssistant.timestamp, timestamp);
      expect(sanitizedAssistant.inputTokens, 11);
      expect(sanitizedAssistant.outputTokens, 22);
      expect(sanitizedAssistant.alternatives, ['previous answer']);
      expect(sanitizedAssistant.activeAlternative, -1);
      expect(
        sanitizedAssistant.content
            .whereType<TextContent>()
            .single
            .reasoningContent,
        isNull,
      );
      expect(
        sanitizedAssistant.content.whereType<ImageContent>().single.filename,
        'screenshot.png',
      );

      await provider.sendMessage('second');
      expect(provider.errorMessage, isNull);
      expect(requestCount, 3);
    });

    test('reports sanitized retry failure with retry details', () async {
      var requestCount = 0;
      final provider = ChatProvider(
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) {
            requestCount++;
            return StreamError(
              'encrypted',
              cause: const EncryptedContentError(
                'Anthropic API error: invalid_encrypted_content: encrypted',
                code: 'invalid_encrypted_content',
              ),
            );
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();
      session.messages.add(ChatMessage(
        role: 'assistant',
        content: [TextContent('cached', reasoningContent: 'hidden')],
      ));

      await provider.sendMessage('first');

      expect(requestCount, 2);
      expect(provider.errorMessage, contains('自动恢复上下文失败'));
      expect(
        provider.errorMessage,
        contains('sanitized retry also failed:'),
      );
    });

    test(
        'does not retry when provider recovery sanitization leaves no messages',
        () async {
      var requestCount = 0;
      final provider = ChatProvider(
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) {
            requestCount++;
            return StreamError(
              'encrypted',
              cause: const EncryptedContentError(
                'Anthropic API error: invalid_encrypted_content: encrypted',
                code: 'invalid_encrypted_content',
              ),
            );
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await provider.createSession();

      await provider.sendMessage(
        '',
        attachments: [
          ToolUseContent(
            id: 'orphan',
            name: 'bash',
            input: const {'cmd': 'pwd'},
          ),
        ],
      );

      expect(requestCount, 1);
      expect(provider.errorMessage, contains('自动恢复上下文失败'));
    });

    test('returns failed recovery error when sanitization leaves no messages',
        () async {
      final provider = ChatProvider();
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final messages = [
        {
          'role': 'assistant',
          'content': [
            {
              'type': 'tool_use',
              'id': 'orphan',
              'name': 'bash',
              'input': {'cmd': 'pwd'},
            },
          ],
        },
      ];

      final recoveryMessages = ChatContextUtils.sanitizeMessages(messages);
      expect(recoveryMessages, isEmpty);
      final error = provider.encryptedRecoveryEmptyErrorForTesting(
        const EncryptedContentError(
          'Anthropic API error: invalid_encrypted_content: encrypted',
          code: 'invalid_encrypted_content',
        ),
        recoveryMessages,
      );
      expect(error, contains('自动恢复上下文失败'));
    });
  });

  group('token-aware context budgeting', () {
    setUp(() async {
      await installPlatformMocks();
      configureAnthropicProfile(baseUrl: 'http://127.0.0.1');
    });

    tearDown(() async {
      await clearPlatformMocks();
    });

    test('manual context summary uses safe API prefix and keeps history',
        () async {
      final observedRequests = <ContextSummaryRequest>[];
      final storage = SessionStorage();
      final provider = ChatProvider(
        storage: storage,
        contextSummaryServiceFactory: () => _ScriptedContextSummaryService(
          onGenerate: (request) {
            observedRequests.add(request);
            return _summaryForRequest(request);
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();
      session.messages.addAll([
        ChatMessage.user('first prompt'),
        ChatMessage(
          role: 'assistant',
          content: [
            ToolUseContent(
              id: 'call_1',
              name: 'bash',
              input: const {'command': 'echo ok'},
            ),
          ],
        ),
        ChatMessage(
          role: 'user',
          content: [
            ToolResultContent(
              toolUseId: 'call_1',
              output: 'for-user-ok',
              forLlm: 'for-llm-ok',
            ),
          ],
        ),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('done')],
        ),
        ChatMessage.systemNotice('system notice hidden'),
        ChatMessage.user('recent prompt'),
      ]);
      final originalMessageCount = session.messages.length;

      final result = await provider.rebuildContextSummaryBeforeMessage(5);

      expect(result.success, isTrue);
      expect(result.requestedApiMessageCount, 4);
      expect(result.coveredMessageCount, 4);
      expect(observedRequests, hasLength(1));
      expect(observedRequests.single.messages, hasLength(4));
      final serialized = observedRequests.single.messages.toString();
      expect(serialized, contains('first prompt'));
      expect(serialized, contains('for-llm-ok'));
      expect(serialized, isNot(contains('system notice hidden')));
      expect(session.messages, hasLength(originalMessageCount));
      expect(provider.currentContextSummary?.coveredMessageCount, 4);

      final persisted = await storage.getSession(session.id);
      expect(persisted, isNotNull);
      expect(persisted!.messages, hasLength(originalMessageCount));
      expect(persisted.contextSummary?.coveredMessageCount, 4);
    });

    test('manual context summary backs off incomplete tool boundaries',
        () async {
      final observedRequests = <ContextSummaryRequest>[];
      final provider = ChatProvider(
        contextSummaryServiceFactory: () => _ScriptedContextSummaryService(
          onGenerate: (request) {
            observedRequests.add(request);
            return _summaryForRequest(request);
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();
      session.messages.addAll([
        ChatMessage.user('safe prompt'),
        ChatMessage(
          role: 'assistant',
          content: [
            ToolUseContent(
              id: 'call_1',
              name: 'bash',
              input: const {'command': 'echo ok'},
            ),
          ],
        ),
        ChatMessage(
          role: 'user',
          content: [
            ToolResultContent(
              toolUseId: 'call_1',
              output: 'ok',
              forLlm: 'ok',
            ),
          ],
        ),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('done')],
        ),
      ]);

      final result = await provider.rebuildContextSummaryBeforeMessage(2);

      expect(result.success, isTrue);
      expect(result.requestedApiMessageCount, 2);
      expect(result.coveredMessageCount, 1);
      expect(observedRequests, hasLength(1));
      expect(observedRequests.single.messages, hasLength(1));
      expect(observedRequests.single.messages.single['role'], 'user');
      expect(
        observedRequests.single.messages.toString(),
        isNot(contains('tool_use')),
      );
      expect(session.messages, hasLength(4));
    });

    test('manual context summary rejects while session is sending', () async {
      final observedRequests = <ContextSummaryRequest>[];
      final streamStarted = Completer<void>();
      final releaseStream = Completer<void>();
      final provider = ChatProvider(
        contextSummaryServiceFactory: () => _ScriptedContextSummaryService(
          onGenerate: (request) {
            observedRequests.add(request);
            return _summaryForRequest(request);
          },
        ),
        llmServiceFactory: (config, {isInBackground}) => _BlockingLlmService(
          config,
          started: streamStarted,
          release: releaseStream,
        ),
      );
      addTearDown(() async {
        if (!releaseStream.isCompleted) releaseStream.complete();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();
      session.messages.add(ChatMessage.user('old prompt'));

      final sendFuture = provider.sendMessage('busy prompt');
      await streamStarted.future;

      final result = await provider.rebuildContextSummaryBeforeMessage(1);

      expect(result.success, isFalse);
      expect(observedRequests, isEmpty);
      expect(provider.isSessionSending(session.id), isTrue);

      releaseStream.complete();
      await sendFuture;
    });

    test('manual context summary rejects duplicate rebuild taps', () async {
      final observedRequests = <ContextSummaryRequest>[];
      final summaryStarted = Completer<void>();
      final releaseSummary = Completer<void>();
      final provider = ChatProvider(
        contextSummaryServiceFactory: () => _ScriptedContextSummaryService(
          onGenerate: (request) async {
            observedRequests.add(request);
            if (!summaryStarted.isCompleted) summaryStarted.complete();
            await releaseSummary.future;
            return _summaryForRequest(request);
          },
        ),
      );
      addTearDown(() async {
        if (!releaseSummary.isCompleted) releaseSummary.complete();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();
      session.messages.addAll([
        ChatMessage.user('first prompt'),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('first response')],
        ),
      ]);

      final first = provider.rebuildContextSummaryBeforeMessage(2);
      await summaryStarted.future;
      expect(provider.isCurrentContextSummaryRebuilding, isTrue);
      expect(provider.canRebuildCurrentContextSummary, isFalse);

      final duplicate = await provider.rebuildContextSummaryBeforeMessage(2);

      expect(duplicate.success, isFalse);
      expect(observedRequests, hasLength(1));

      releaseSummary.complete();
      final completed = await first;
      expect(completed.success, isTrue);
      expect(provider.isCurrentContextSummaryRebuilding, isFalse);
      expect(provider.canRebuildCurrentContextSummary, isTrue);
      expect(session.messages, hasLength(2));
    });

    test('sendMessage uses token budget instead of raw character length',
        () async {
      SharedPreferences.setMockInitialValues({
        'active_provider_profile_id': 'profile',
        'context_token_budget': 32768,
        'developer_mode': true,
      });
      final observedMessages = <List<Map<String, dynamic>>>[];
      final provider = ChatProvider(
        contextSummaryServiceFactory: () => _ScriptedContextSummaryService(
          onGenerate: (request) => _summaryForRequest(request),
        ),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (messages) {
            observedMessages.add(messages);
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'ok')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();
      session.messages.addAll([
        ChatMessage.user('old-short-cjk-${'中' * 24000}'),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('old reply ${'中' * 24000}')],
        ),
        ChatMessage.user('recent prompt'),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('recent reply')],
        ),
      ]);

      await provider.sendMessage('new prompt');

      expect(provider.errorMessage, isNull);
      expect(observedMessages, hasLength(1));
      final serialized = observedMessages.single.toString();
      expect(serialized, isNot(contains('old-short-cjk')));
      expect(serialized, contains('new prompt'));
      expect(
        provider.currentSession!.messages
            .where((m) => m.isSystemNotice)
            .map((m) => m.textContent)
            .join('\n'),
        contains('压缩为摘要'),
      );
    });

    test('sendMessage reports orphan tool block cleanup separately', () async {
      final observedMessages = <List<Map<String, dynamic>>>[];
      final events = RuntimeDebugEventService();
      final provider = ChatProvider(
        runtimeDebugEvents: events,
        contextSummaryServiceFactory: () => _ScriptedContextSummaryService(
          onGenerate: (request) => _summaryForRequest(request),
        ),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (messages) {
            observedMessages.add(messages);
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'ok')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();
      session.messages.add(ChatMessage(
        role: 'assistant',
        content: [
          TextContent('kept text'),
          ToolUseContent(
            id: 'orphan',
            name: 'bash',
            input: const {'cmd': 'pwd'},
          ),
        ],
      ));

      await provider.sendMessage('new prompt');

      expect(provider.errorMessage, isNull);
      expect(observedMessages, hasLength(1));
      expect(observedMessages.single.toString(), isNot(contains('orphan')));
      expect(
        provider.currentSession!.messages
            .where((m) => m.isSystemNotice)
            .map((m) => m.textContent)
            .join('\n'),
        contains('清理了 1 个不完整的工具调用'),
      );
      final truncationEvent = events
          .recent(sessionId: session.id)
          .where((event) => event.type == 'context.truncated')
          .single;
      expect(truncationEvent.data['droppedBlockCount'], 1);
      expect(truncationEvent.data['overBudgetAfterTruncation'], isFalse);
    });

    test('sendMessage compresses old large tool results in payload only',
        () async {
      final observedMessages = <List<Map<String, dynamic>>>[];
      final events = RuntimeDebugEventService();
      final provider = ChatProvider(
        runtimeDebugEvents: events,
        contextSummaryServiceFactory: () => _ScriptedContextSummaryService(
          onGenerate: (request) => _summaryForRequest(request),
        ),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (messages) {
            observedMessages.add(messages);
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'ok')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();
      final oldOutput = 'old-output-${'x' * 3000}';
      final middleOutput = 'middle-output-${'y' * 3000}';
      final latestOutput = 'latest-output-${'z' * 3000}';
      session.messages.addAll([
        ChatMessage.user('old tool prompt'),
        ChatMessage(
          role: 'assistant',
          content: [
            ToolUseContent(
              id: 'call_old',
              name: 'bash',
              input: const {'cmd': 'cat old.txt'},
            ),
          ],
        ),
        ChatMessage(
          role: 'user',
          content: [
            ToolResultContent(toolUseId: 'call_old', output: oldOutput),
          ],
        ),
        ChatMessage(role: 'assistant', content: [TextContent('old done')]),
        ChatMessage.user('middle tool prompt'),
        ChatMessage(
          role: 'assistant',
          content: [
            ToolUseContent(
              id: 'call_middle',
              name: 'grep',
              input: const {'cmd': 'grep middle'},
            ),
          ],
        ),
        ChatMessage(
          role: 'user',
          content: [
            ToolResultContent(toolUseId: 'call_middle', output: middleOutput),
          ],
        ),
        ChatMessage(role: 'assistant', content: [TextContent('middle done')]),
        ChatMessage.user('latest tool prompt'),
        ChatMessage(
          role: 'assistant',
          content: [
            ToolUseContent(
              id: 'call_latest',
              name: 'cat',
              input: const {'cmd': 'cat latest.txt'},
            ),
          ],
        ),
        ChatMessage(
          role: 'user',
          content: [
            ToolResultContent(toolUseId: 'call_latest', output: latestOutput),
          ],
        ),
        ChatMessage(role: 'assistant', content: [TextContent('latest done')]),
      ]);

      await provider.sendMessage('new prompt');

      expect(provider.errorMessage, isNull);
      expect(observedMessages, hasLength(1));
      final payload = observedMessages.single.toString();
      expect(payload, contains('Tool result truncated'));
      expect(payload, contains('tool: bash'));
      expect(payload, contains('id: call_old'));
      expect(payload, isNot(contains(oldOutput)));
      expect(payload, contains(middleOutput));
      expect(payload, contains(latestOutput));
      expect(
        provider.currentSession!.toApiMessages().toString(),
        contains(oldOutput),
      );
      final compressionEvent = events
          .recent(sessionId: session.id)
          .where((event) => event.type == 'tool_result.compressed')
          .single;
      expect(compressionEvent.data['compressedCount'], 1);
      expect(compressionEvent.data.toString(), isNot(contains(oldOutput)));
    });

    test('large system prompt truncates history more aggressively', () async {
      SharedPreferences.setMockInitialValues({
        'active_provider_profile_id': 'profile',
        'context_token_budget': 32768,
        'developer_mode': true,
      });
      final observedMessages = <List<Map<String, dynamic>>>[];
      final provider = ChatProvider(
        contextSummaryServiceFactory: () => _ScriptedContextSummaryService(
          onGenerate: (request) => _summaryForRequest(request),
        ),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (messages) {
            observedMessages.add(messages);
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'ok')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      Future<int> sentMessageCountForSystemPrompt(String systemPrompt) async {
        final session = await provider.createSession();
        session.systemPrompt = systemPrompt;
        session.messages.addAll([
          ChatMessage.user('old-1 ${'中' * 4000}'),
          ChatMessage(
            role: 'assistant',
            content: [TextContent('old-2 ${'中' * 4000}')],
          ),
          ChatMessage.user('mid-1 ${'中' * 4000}'),
          ChatMessage(
            role: 'assistant',
            content: [TextContent('mid-2 ${'中' * 4000}')],
          ),
          ChatMessage.user('recent prompt'),
          ChatMessage(
            role: 'assistant',
            content: [TextContent('recent reply')],
          ),
        ]);

        await provider.sendMessage('new prompt');

        expect(provider.errorMessage, isNull);
        return observedMessages.last.length;
      }

      final smallPromptCount = await sentMessageCountForSystemPrompt('small');
      final largePromptCount =
          await sentMessageCountForSystemPrompt('large ${'中' * 20000}');

      expect(largePromptCount, lessThan(smallPromptCount));
    });

    test('image-heavy history contributes to token budget', () async {
      SharedPreferences.setMockInitialValues({
        'active_provider_profile_id': 'profile',
        'context_token_budget': 32768,
        'developer_mode': true,
      });
      final observedMessages = <List<Map<String, dynamic>>>[];
      final provider = ChatProvider(
        contextSummaryServiceFactory: () => _ScriptedContextSummaryService(
          onGenerate: (request) => _summaryForRequest(request),
        ),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (messages) {
            observedMessages.add(messages);
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'ok')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();
      for (var i = 0; i < 20; i++) {
        session.messages.add(ChatMessage.userContent([
          ImageContent(
            data: 'old-image-$i',
            mediaType: 'image/png',
          ),
        ]));
      }

      await provider.sendMessage('new prompt');

      expect(provider.errorMessage, isNull);
      expect(observedMessages, hasLength(1));
      final serialized = observedMessages.single.toString();
      expect(serialized, isNot(contains('old-image-0')));
      expect(serialized, contains('new prompt'));
    });

    test('encrypted recovery retry also uses token budget truncation',
        () async {
      final observedMessages = <List<Map<String, dynamic>>>[];
      final provider = ChatProvider(
        contextSummaryServiceFactory: () => _ScriptedContextSummaryService(
          onGenerate: (request) => _summaryForRequest(request),
        ),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (messages) {
            observedMessages.add(messages);
            if (observedMessages.length == 1) {
              return StreamError(
                'encrypted',
                cause: const EncryptedContentError(
                  'Anthropic API error: invalid_encrypted_content: encrypted',
                  code: 'invalid_encrypted_content',
                ),
              );
            }
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'ok')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();
      session.messages.addAll([
        ChatMessage.user('old-cjk-${'中' * 24000}'),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('old reply ${'中' * 24000}')],
        ),
        ChatMessage.user('recent prompt'),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('recent reply')],
        ),
      ]);

      await provider.sendMessage('new prompt');

      expect(provider.errorMessage, isNull);
      expect(observedMessages, hasLength(2));
      final retryPayload = observedMessages.last.toString();
      expect(retryPayload, isNot(contains('old-cjk')));
      expect(retryPayload, contains('new prompt'));
    });

    test('encrypted recovery retry uses provider transform cleanup', () async {
      final observedMessages = <List<Map<String, dynamic>>>[];
      final events = RuntimeDebugEventService();
      final provider = ChatProvider(
        runtimeDebugEvents: events,
        contextSummaryServiceFactory: () => _ScriptedContextSummaryService(
          onGenerate: (request) => _summaryForRequest(request),
        ),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (messages) {
            observedMessages.add(messages);
            if (observedMessages.length == 1) {
              return StreamError(
                'encrypted',
                cause: const EncryptedContentError(
                  'Anthropic API error: invalid_encrypted_content: encrypted',
                  code: 'invalid_encrypted_content',
                ),
              );
            }
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'ok')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();
      session.messages.add(ChatMessage(
        role: 'assistant',
        content: [
          TextContent('cached', reasoningContent: 'hidden reasoning'),
          ToolUseContent(
            id: 'call:1',
            name: 'bash',
            input: const {
              'cmd': 'pwd',
              'cache_control': {'type': 'ephemeral'},
              'nested': {'encrypted': 'blob', 'safe': true},
            },
          ),
        ],
      ));
      session.messages.add(ChatMessage(
        role: 'user',
        content: [
          ToolResultContent(
            toolUseId: 'call:1',
            output: 'done',
          ),
        ],
      ));

      await provider.sendMessage('new prompt');

      expect(provider.errorMessage, isNull);
      expect(observedMessages, hasLength(2));
      final retryPayload = observedMessages.last.toString();
      expect(retryPayload, isNot(contains('reasoning_content')));
      expect(retryPayload, isNot(contains('cache_control')));
      expect(retryPayload, isNot(contains('encrypted')));
      expect(retryPayload, contains('call_1'));
      expect(retryPayload, isNot(contains('call:1')));
      final recoveryEvents = events
          .recent(sessionId: session.id)
          .where((event) =>
              event.type == 'chat.recovery.invalid_encrypted_content')
          .toList();
      expect(recoveryEvents.map((event) => event.data['success']),
          containsAll([false, true]));
    });

    test('provider transform warning is recorded for unsupported images',
        () async {
      final events = RuntimeDebugEventService();
      final observedMessages = <List<Map<String, dynamic>>>[];
      final provider = ChatProvider(
        runtimeDebugEvents: events,
        contextSummaryServiceFactory: () => _ScriptedContextSummaryService(
          onGenerate: (request) => _summaryForRequest(request),
        ),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (messages) {
            observedMessages.add(messages);
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'ok')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();
      session.modelOverride = 'deepseek-r1';

      await provider.sendMessage('', attachments: [
        ImageContent(data: 'abc123', mediaType: 'image/png'),
      ]);

      expect(provider.errorMessage, isNull);
      expect(observedMessages, hasLength(1));
      final transformEvent = events
          .recent(sessionId: session.id)
          .where((event) => event.type == 'provider.transform.warning')
          .single;
      expect(transformEvent.data['warningCount'], greaterThan(0));
      expect(transformEvent.data['warningCode'], 'image_unsupported');
      expect(transformEvent.data.toString(), isNot(contains('abc123')));
    });

    test('provider transform warning preflight failure is best effort',
        () async {
      final events = RuntimeDebugEventService();
      final provider = ChatProvider(
        runtimeDebugEvents: events,
        providerTransformPreflight: (_, __) {
          throw StateError('preflight failed');
        },
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        () => provider.recordProviderTransformWarningsBestEffortForTesting(
          sessionId: 'session',
          messages: const [
            {'role': 'user', 'content': 'hello'},
          ],
          options: const ProviderTransformOptions(
            apiFormat: 'anthropic',
            modelId: 'model',
          ),
        ),
        returnsNormally,
      );
      expect(events.recent(sessionId: 'session'), isEmpty);
    });

    test('provider transform preflight records sensitive redaction stats',
        () async {
      final events = RuntimeDebugEventService();
      final provider = ChatProvider(runtimeDebugEvents: events);
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      provider.recordProviderTransformWarningsBestEffortForTesting(
        sessionId: 'session',
        messages: const [
          {
            'role': 'user',
            'content': 'Authorization: Bearer abcdefghijklmnopqrstuvwxyz123456',
          },
        ],
        options: const ProviderTransformOptions(
          apiFormat: 'anthropic',
          modelId: 'model',
        ),
      );

      final event = events
          .recent(sessionId: 'session')
          .singleWhere((event) => event.type == 'llm.sensitive_data_redacted');
      expect(event.data['stage'], 'provider_payload');
      expect(event.data['totalCount'], 1);
      expect(event.data.keys.toSet(), {'stage', 'totalCount'});
      expect(
        event.data.toString(),
        isNot(contains('abcdefghijklmnopqrstuvwxyz')),
      );
    });

    test('does not generate summary when messages fit token budget', () async {
      SharedPreferences.setMockInitialValues({
        'active_provider_profile_id': 'profile',
        'context_token_budget': 32768,
        'developer_mode': true,
      });
      final observedSystems = <String>[];
      var summaryCalls = 0;
      final provider = ChatProvider(
        contextSummaryServiceFactory: () => _ScriptedContextSummaryService(
          onGenerate: (request) {
            summaryCalls++;
            throw StateError('summary should not be generated');
          },
        ),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => StreamDone(const LlmResponse(
            stopReason: 'end_turn',
            content: [ContentBlock(type: 'text', text: 'ok')],
          )),
          onStreamSystem: observedSystems.add,
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();
      session.messages.addAll([
        ChatMessage.user('short old prompt'),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('short old answer')],
        ),
      ]);

      await provider.sendMessage('short new prompt');

      expect(provider.errorMessage, isNull);
      expect(summaryCalls, 0);
      expect(observedSystems, hasLength(1));
      expect(
        observedSystems.single,
        isNot(contains('conversation_context_summary')),
      );
    });

    test('model context window clamps user context token budget', () async {
      final profile = ProviderProfile.defaults().copyWith(
        id: 'profile',
        apiKey: 'sk-test',
        apiFormat: ProviderProfile.openaiFormat,
        baseUrl: 'https://api.openai.com',
        model: 'gpt-test-8k',
      );
      secureStorage['provider_profiles'] = jsonEncode([profile.toJson()]);
      SharedPreferences.setMockInitialValues({
        'active_provider_profile_id': 'profile',
        'context_token_budget': 65536,
        'developer_mode': true,
      });
      ContextSummaryRequest? observedRequest;
      final provider = ChatProvider(
        contextSummaryServiceFactory: () => _ScriptedContextSummaryService(
          onGenerate: (request) {
            observedRequest = request;
            return _summaryForRequest(request);
          },
        ),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => StreamDone(const LlmResponse(
            stopReason: 'end_turn',
            content: [ContentBlock(type: 'text', text: 'ok')],
          )),
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();
      session.messages.addAll([
        ChatMessage.user('old-window-${'中' * 12000}'),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('old reply ${'中' * 12000}')],
        ),
        ChatMessage.user('recent prompt'),
      ]);

      await provider.sendMessage('new prompt');

      expect(provider.errorMessage, isNull);
      expect(observedRequest, isNotNull);
      expect(observedRequest!.maxInputTokens, (8192 * 0.8).floor());
    });

    test('overflow generates summary and injects it into system prompt',
        () async {
      SharedPreferences.setMockInitialValues({
        'active_provider_profile_id': 'profile',
        'context_token_budget': 32768,
        'developer_mode': true,
      });
      final observedSystems = <String>[];
      final observedMessages = <List<Map<String, dynamic>>>[];
      var summaryCalls = 0;
      final events = RuntimeDebugEventService();
      final provider = ChatProvider(
        runtimeDebugEvents: events,
        contextSummaryServiceFactory: () => _ScriptedContextSummaryService(
          onGenerate: (request) {
            summaryCalls++;
            return ContextSummary(
              version: ContextSummaryService.version,
              text: '## Goal\nGenerated compact summary',
              coveredMessageCount: request.coveredMessageCount,
              coveredDigest: request.coveredDigest,
              sourceEstimatedTokens: request.sourceEstimatedTokens,
              summaryEstimatedTokens: 20,
              createdAt: DateTime.utc(2026),
              updatedAt: DateTime.utc(2026),
              model: 'claude',
              apiFormat: 'anthropic',
            );
          },
        ),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (messages) {
            observedMessages.add(messages);
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'ok')],
            ));
          },
          onStreamSystem: observedSystems.add,
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();
      session.messages.addAll([
        ChatMessage.user('old-summary-${'中' * 24000}'),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('old reply ${'中' * 24000}')],
        ),
        ChatMessage.user('recent prompt'),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('recent reply')],
        ),
      ]);

      await provider.sendMessage('new prompt');

      expect(provider.errorMessage, isNull);
      expect(summaryCalls, 1);
      expect(provider.currentSession!.contextSummary, isNotNull);
      expect(observedSystems.single, contains('Generated compact summary'));
      expect(observedSystems.single, contains('conversation_context_summary'));
      expect(
          observedMessages.single.toString(), isNot(contains('old-summary')));
      expect(observedMessages.single.toString(), contains('new prompt'));
      expect(
        provider.currentSession!.messages
            .where((m) => m.isSystemNotice)
            .map((m) => m.textContent)
            .join('\n'),
        contains('压缩为摘要'),
      );
      final summaryEvent = events
          .recent(
            sessionId: session.id,
          )
          .where((event) => event.type == 'context.summary.generated')
          .single;
      expect(summaryEvent.data['coveredMessageCount'], greaterThan(0));
      expect(summaryEvent.data['reused'], isFalse);
    });

    test('matching summary digest is reused without regeneration', () async {
      SharedPreferences.setMockInitialValues({
        'active_provider_profile_id': 'profile',
        'context_token_budget': 32768,
        'developer_mode': true,
      });
      final observedSystems = <String>[];
      var summaryCalls = 0;
      final events = RuntimeDebugEventService();
      final provider = ChatProvider(
        runtimeDebugEvents: events,
        contextSummaryServiceFactory: () => _ScriptedContextSummaryService(
          onGenerate: (request) {
            summaryCalls++;
            throw StateError('should reuse existing summary');
          },
        ),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => StreamDone(const LlmResponse(
            stopReason: 'end_turn',
            content: [ContentBlock(type: 'text', text: 'ok')],
          )),
          onStreamSystem: observedSystems.add,
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();
      final messages = [
        ChatMessage.user('old-reuse-${'中' * 24000}'),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('old reply ${'中' * 24000}')],
        ),
        ChatMessage.user('recent prompt'),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('recent reply')],
        ),
      ];
      session.messages.addAll(messages);
      final apiMessages = session.toApiMessages();
      final historyBudget = 32768 -
          const TokenEstimator()
              .estimateText(AppConstants.defaultSystemPrompt) -
          1891 -
          8192 -
          1024;
      final plan = ChatContextUtils.planCompaction(
        apiMessages,
        maxTokens: historyBudget,
        estimator: const TokenEstimator(),
      );
      session.contextSummary = ContextSummary(
        version: ContextSummaryService.version,
        text: '## Goal\nReusable summary',
        coveredMessageCount: plan.headForSummary.length,
        coveredDigest: plan.headDigest,
        sourceEstimatedTokens: plan.headEstimatedTokens,
        summaryEstimatedTokens: 20,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );

      await provider.sendMessage('new prompt');

      expect(provider.errorMessage, isNull);
      expect(summaryCalls, 0);
      expect(observedSystems.single, contains('Reusable summary'));
      final reusedEvent = events
          .recent(
            sessionId: session.id,
          )
          .where((event) => event.type == 'context.summary.reused')
          .single;
      expect(reusedEvent.data['coveredMessageCount'],
          session.contextSummary!.coveredMessageCount);
    });

    test('rolling update only sends unsummarized head messages', () async {
      SharedPreferences.setMockInitialValues({
        'active_provider_profile_id': 'profile',
        'context_token_budget': 32768,
        'developer_mode': true,
      });
      ContextSummaryRequest? observedRequest;
      final events = RuntimeDebugEventService();
      final provider = ChatProvider(
        runtimeDebugEvents: events,
        contextSummaryServiceFactory: () => _ScriptedContextSummaryService(
          onGenerate: (request) {
            observedRequest = request;
            return _summaryForRequest(request);
          },
        ),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => StreamDone(const LlmResponse(
            stopReason: 'end_turn',
            content: [ContentBlock(type: 'text', text: 'ok')],
          )),
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();
      session.messages.addAll([
        ChatMessage.user('covered-old-0 ${'中' * 10000}'),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('covered-old-1 ${'中' * 10000}')],
        ),
        ChatMessage.user('incremental-head-0 ${'中' * 10000}'),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('incremental-head-1 ${'中' * 10000}')],
        ),
        ChatMessage.user('recent prompt'),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('recent reply')],
        ),
      ]);
      final coveredMessages = session.toApiMessages().take(2).toList();
      session.contextSummary = ContextSummary(
        version: ContextSummaryService.version,
        text: '## Goal\nExisting rolling summary',
        coveredMessageCount: coveredMessages.length,
        coveredDigest: ChatContextUtils.digestMessages(coveredMessages),
        sourceEstimatedTokens:
            const TokenEstimator().estimateMessages(coveredMessages),
        summaryEstimatedTokens: 20,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );

      await provider.sendMessage('new prompt');

      expect(provider.errorMessage, isNull);
      expect(observedRequest, isNotNull);
      expect(observedRequest!.existingSummary?.text,
          contains('Existing rolling summary'));
      final serialized = observedRequest!.messages.toString();
      expect(serialized, contains('incremental-head-0'));
      expect(serialized, contains('incremental-head-1'));
      expect(serialized, isNot(contains('covered-old-0')));
      expect(serialized, isNot(contains('covered-old-1')));
    });

    test('stale rolling summary is ignored and rebuilt from changed prefix',
        () async {
      SharedPreferences.setMockInitialValues({
        'active_provider_profile_id': 'profile',
        'context_token_budget': 32768,
        'developer_mode': true,
      });
      ContextSummaryRequest? observedRequest;
      final events = RuntimeDebugEventService();
      final provider = ChatProvider(
        runtimeDebugEvents: events,
        contextSummaryServiceFactory: () => _ScriptedContextSummaryService(
          onGenerate: (request) {
            observedRequest = request;
            return _summaryForRequest(request);
          },
        ),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => StreamDone(const LlmResponse(
            stopReason: 'end_turn',
            content: [ContentBlock(type: 'text', text: 'ok')],
          )),
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();
      session.messages.addAll([
        ChatMessage.user('original-old-${'中' * 24000}'),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('old reply ${'中' * 24000}')],
        ),
        ChatMessage.user('recent prompt'),
      ]);
      final staleDigest =
          ChatContextUtils.digestMessages([session.toApiMessages().first]);
      session.contextSummary = ContextSummary(
        version: ContextSummaryService.version,
        text: '## Goal\nStale summary',
        coveredMessageCount: 1,
        coveredDigest: staleDigest,
        sourceEstimatedTokens: 100,
        summaryEstimatedTokens: 20,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );
      session.messages[0] = ChatMessage.user('changed-old-${'中' * 24000}');

      await provider.sendMessage('new prompt');

      expect(provider.errorMessage, isNull);
      expect(observedRequest, isNotNull);
      expect(observedRequest!.existingSummary, isNull);
      final serialized = observedRequest!.messages.toString();
      expect(serialized, contains('changed-old'));
      expect(serialized, isNot(contains('original-old')));
      final staleEvent = events
          .recent(
            sessionId: session.id,
          )
          .where((event) => event.type == 'context.summary.stale')
          .single;
      expect(staleEvent.data['reason'], 'digest_mismatch');
    });

    test('summary generation failure falls back and continues', () async {
      SharedPreferences.setMockInitialValues({
        'active_provider_profile_id': 'profile',
        'context_token_budget': 32768,
        'developer_mode': true,
      });
      final events = RuntimeDebugEventService();
      final provider = ChatProvider(
        runtimeDebugEvents: events,
        contextSummaryServiceFactory: () => _ScriptedContextSummaryService(
          onGenerate: (_) => throw StateError('summary unavailable'),
        ),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => StreamDone(const LlmResponse(
            stopReason: 'end_turn',
            content: [ContentBlock(type: 'text', text: 'ok')],
          )),
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();
      session.messages.addAll([
        ChatMessage.user('old-failure-${'中' * 24000}'),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('old reply ${'中' * 24000}')],
        ),
        ChatMessage.user('recent prompt'),
      ]);

      await provider.sendMessage('new prompt');

      expect(provider.errorMessage, isNull);
      expect(provider.currentSession!.contextSummary, isNotNull);
      expect(
        provider.currentSession!.messages
            .where((m) => m.isSystemNotice)
            .map((m) => m.textContent)
            .join('\n'),
        contains('摘要生成失败'),
      );
      final failedEvent = events
          .recent(
            sessionId: session.id,
          )
          .where((event) => event.type == 'context.summary.failed')
          .single;
      expect(failedEvent.data['stage'], 'llm');
    });

    test('summary and extractive fallback failures use pure P0 truncation',
        () async {
      SharedPreferences.setMockInitialValues({
        'active_provider_profile_id': 'profile',
        'context_token_budget': 32768,
        'developer_mode': true,
      });
      final observedSystems = <String>[];
      final observedMessages = <List<Map<String, dynamic>>>[];
      final events = RuntimeDebugEventService();
      final provider = ChatProvider(
        runtimeDebugEvents: events,
        contextSummaryServiceFactory: () => _ScriptedContextSummaryService(
          onGenerate: (_) => throw StateError('summary unavailable'),
          onExtractive: (_) => throw StateError('extractive unavailable'),
        ),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (messages) {
            observedMessages.add(
              messages
                  .map((message) => Map<String, dynamic>.from(message))
                  .toList(),
            );
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'ok')],
            ));
          },
          onStreamSystem: observedSystems.add,
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();
      session.messages.addAll([
        ChatMessage.user('old-double-failure-${'中' * 24000}'),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('old reply ${'中' * 24000}')],
        ),
        ChatMessage.user('recent prompt'),
      ]);

      await provider.sendMessage('new prompt');

      expect(provider.errorMessage, isNull);
      expect(provider.currentSession!.contextSummary, isNull);
      expect(observedSystems.single,
          isNot(contains('conversation_context_summary')));
      expect(observedMessages.single.toString(), contains('new prompt'));
      expect(
        provider.currentSession!.messages
            .where((m) => m.isSystemNotice)
            .map((m) => m.textContent)
            .join('\n'),
        contains('摘要生成失败'),
      );
      final failedStages = events
          .recent(sessionId: session.id)
          .where((event) => event.type == 'context.summary.failed')
          .map((event) => event.data['stage'])
          .toList();
      expect(failedStages, containsAll(['llm', 'extractive']));
    });

    test('sendCompare uses token-aware truncation', () async {
      SharedPreferences.setMockInitialValues({
        'active_provider_profile_id': 'profile',
        'context_token_budget': 32768,
        'developer_mode': true,
      });
      final observedMessages = <List<Map<String, dynamic>>>[];
      final storage = SessionStorage();
      await storage.init();
      final provider = ChatProvider(
        storage: storage,
        contextSummaryServiceFactory: () => _ScriptedContextSummaryService(
          onGenerate: (request) => _summaryForRequest(request),
        ),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => StreamDone(const LlmResponse(
            stopReason: 'end_turn',
            content: [ContentBlock(type: 'text', text: 'ok')],
          )),
          onChat: (messages) {
            observedMessages.add(messages);
            return LlmResponse(
              stopReason: 'end_turn',
              content: [
                ContentBlock(
                    type: 'text', text: 'ok ${observedMessages.length}')
              ],
            );
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();
      session.messages.addAll([
        ChatMessage.user('old-compare-${'中' * 24000}'),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('old reply ${'中' * 24000}')],
        ),
        ChatMessage.user('recent prompt'),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('recent reply')],
        ),
      ]);

      await provider.sendCompare('compare prompt', ['model-a', 'model-b']);

      expect(provider.errorMessage, isNull);
      expect(observedMessages, hasLength(2));
      for (final messages in observedMessages) {
        final serialized = messages.toString();
        expect(serialized, isNot(contains('old-compare')));
        expect(serialized, contains('compare prompt'));
      }
      expect(await provider.useCompareResult(1), isTrue);
      final selected = provider.currentSession!.messages.last;
      expect(selected.textContent, 'ok 2');
      expect(selected.alternatives, ['ok 1']);
      expect(selected.currentProvenance?.model, 'model-b');
      expect(selected.alternativeProvenance?.single?.model, 'model-a');
      final reloaded = await storage.getSession(session.id);
      expect(reloaded!.messages.last.textContent, 'ok 2');
      expect(reloaded.messages.last.currentProvenance?.model, 'model-b');
    });

    test('compare cancellation aborts only one result and keeps successes',
        () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final disposed = Completer<void>();
      final provider = ChatProvider(
        llmServiceFactory: (config, {isInBackground}) {
          if (config.model == 'model-a') {
            return _BlockingCompareLlmService(
              config,
              started: started,
              release: release,
              disposed: disposed,
            );
          }
          return _ScriptedLlmService(
            config,
            onMessages: (_) => StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'kept')],
            )),
          );
        },
      );
      addTearDown(provider.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await provider.createSession();

      final send =
          provider.sendCompare('compare prompt', ['model-a', 'model-b']);
      await started.future.timeout(const Duration(seconds: 2));
      provider.cancelCompareResult(
        'model-a',
        ownerSessionId: provider.compareOwnerSessionId!,
        compareGeneration: provider.compareOperationGeneration!,
      );
      await disposed.future.timeout(const Duration(seconds: 2));
      await send.timeout(const Duration(seconds: 2));

      expect(provider.compareResults, hasLength(2));
      expect(provider.compareResults![0].state, CompareResultState.cancelled);
      expect(provider.compareResults![1].state, CompareResultState.complete);
      expect(provider.compareResults![1].text, 'kept');
    });

    test('run center derives active and queued work from agent state',
        () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final provider = ChatProvider(
        llmServiceFactory: (config, {isInBackground}) => _BlockingLlmService(
          config,
          started: started,
          release: release,
        ),
      );
      addTearDown(provider.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();
      final send = provider.sendMessage('first');
      await started.future.timeout(const Duration(seconds: 2));
      await provider.sendMessage('second');

      final item = provider.agentRunCenterItems.singleWhere(
        (candidate) => candidate.sessionId == session.id,
      );
      expect(item.isActive, isTrue);
      expect(item.queuedCount, 1);

      await provider.cancelAgent(sessionId: session.id);
      await send.timeout(const Duration(seconds: 2));
    });

    test('run center reads bounded recovery metadata for unloaded sessions',
        () async {
      final storage = SessionStorage();
      await storage.init();
      final session = ChatSession(
        id: 'run-center-recovery',
        title: 'Recoverable session',
        remoteAgentConnectorId: 'historical_remote',
        inFlightAgentRun: _unknownRecoveryMarker('run-center-attempt'),
      );
      await storage.saveSession(session);
      final provider = ChatProvider(storage: storage);
      addTearDown(provider.dispose);
      await _waitUntil(
        () => provider.sessions.any((summary) => summary.id == session.id),
      );

      final items = await provider.loadRecoverableAgentRunCenterItems();

      final item = items.singleWhere(
        (candidate) => candidate.sessionId == session.id,
      );
      expect(item.phase, AgentRunCenterPhase.unknownOutcome);
      expect(item.recoveryKind, InterruptedRunRecoveryKind.unknownOutcome);
      expect(item.context, AgentRunCenterContext.external);
      expect(item.safeExecutionDisplayName, isNull);
    });

    test(
        'compare owner survives session switch, retry, and selected persistence',
        () async {
      final storage = SessionStorage();
      await storage.init();
      final observed = <String, List<List<Map<String, dynamic>>>>{};
      var modelACalls = 0;
      final provider = ChatProvider(
        storage: storage,
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => StreamDone(const LlmResponse(
            stopReason: 'end_turn',
            content: [ContentBlock(type: 'text', text: 'unused')],
          )),
          onChat: (messages) {
            observed.putIfAbsent(config.model, () => []).add(
                  messages
                      .map((message) => Map<String, dynamic>.from(message))
                      .toList(),
                );
            if (config.model == 'model-a' && modelACalls++ == 0) {
              throw StateError('injected');
            }
            return LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: '${config.model}-ok')],
            );
          },
        ),
      );
      addTearDown(provider.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final sessionA = await provider.createSession();
      sessionA.messages.add(ChatMessage.user('history-a'));
      await storage.saveSession(sessionA);
      final sessionB = await provider.createSession();
      sessionB.messages.add(ChatMessage.user('history-b'));
      await storage.saveSession(sessionB);
      await provider.selectSession(sessionA.id);

      final compare = provider.sendCompare(
        'owner prompt',
        ['model-a', 'model-b'],
      );
      await provider.selectSession(sessionB.id);
      await compare;

      expect(provider.compareOwnerSessionId, sessionA.id);
      expect(provider.compareBelongsToCurrentSession, isFalse);
      expect(
        provider.clearCompareResults(
          ownerSessionId: sessionB.id,
          compareGeneration: provider.compareOperationGeneration!,
        ),
        isFalse,
      );
      expect(provider.compareOwnerSessionId, sessionA.id);
      for (final requests in observed.values) {
        for (final messages in requests) {
          final serialized = messages.toString();
          expect(serialized, contains('history-a'));
          expect(serialized, isNot(contains('history-b')));
        }
      }

      await provider.retryCompareResult('model-a');
      expect(observed['model-a'], hasLength(2));
      expect(observed['model-a']!.last.toString(), contains('history-a'));
      expect(
          observed['model-a']!.last.toString(), isNot(contains('history-b')));

      expect(await provider.useCompareResult(1), isTrue);
      final persistedA = await storage.getSession(sessionA.id);
      final persistedB = await storage.getSession(sessionB.id);
      expect(persistedA!.messages.last.textContent, 'model-b-ok');
      expect(persistedA.messages[persistedA.messages.length - 2].textContent,
          'owner prompt');
      expect(persistedB!.messages.map((message) => message.textContent),
          ['history-b']);
    });

    test('deleted compare owner blocks terminal result and second compare',
        () async {
      final storage = SessionStorage();
      await storage.init();
      final started = Completer<void>();
      final release = Completer<void>();
      final observed = <List<Map<String, dynamic>>>[];
      final provider = ChatProvider(
        storage: storage,
        llmServiceFactory: (config, {isInBackground}) =>
            _BlockingCompareWithMessages(
          config,
          started: started,
          release: release,
          observed: observed,
        ),
      );
      addTearDown(provider.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final sessionA = await provider.createSession();
      sessionA.messages.add(ChatMessage.user('history-a'));
      await storage.saveSession(sessionA);
      final sessionB = await provider.createSession();
      sessionB.messages.add(ChatMessage.user('history-b'));
      await storage.saveSession(sessionB);
      await provider.selectSession(sessionA.id);

      final first =
          provider.sendCompare('owner prompt', ['model-a', 'model-b']);
      await started.future.timeout(const Duration(seconds: 2));
      await provider.selectSession(sessionB.id);
      await provider.sendCompare('second prompt', ['model-c', 'model-d']);
      expect(provider.compareOwnerSessionId, sessionA.id);
      await provider.deleteSession(sessionA.id);
      release.complete();
      await first.timeout(const Duration(seconds: 2));

      expect(await provider.useCompareResult(0), isFalse);
      expect(await storage.getSession(sessionA.id), isNull);
      expect(observed.single.toString(), contains('history-a'));
      expect(observed.single.toString(), isNot(contains('history-b')));
    });

    test(
        'owner tombstone immediately after capture prevents any compare request',
        () async {
      final storage = SessionStorage();
      await storage.init();
      var requests = 0;
      final provider = ChatProvider(
        storage: storage,
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => StreamDone(const LlmResponse(
            stopReason: 'end_turn',
            content: [ContentBlock(type: 'text', text: 'unused')],
          )),
          onChat: (_) {
            requests++;
            return const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'should-not-run')],
            );
          },
        ),
      );
      addTearDown(provider.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final owner = await provider.createSession();

      final compare =
          provider.sendCompare('owner prompt', ['model-a', 'model-b']);
      storage.tombstoneSession(owner.id);
      await compare;

      expect(requests, 0);
      expect(await provider.useCompareResult(0), isFalse);
    });

    test('sendCompare compresses old large tool results', () async {
      final observedMessages = <List<Map<String, dynamic>>>[];
      final provider = ChatProvider(
        contextSummaryServiceFactory: () => _ScriptedContextSummaryService(
          onGenerate: (request) => _summaryForRequest(request),
        ),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => StreamDone(const LlmResponse(
            stopReason: 'end_turn',
            content: [ContentBlock(type: 'text', text: 'ok')],
          )),
          onChat: (messages) {
            observedMessages.add(messages);
            return const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'ok')],
            );
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();
      final oldOutput = 'compare-old-output-${'x' * 3000}';
      final middleOutput = 'compare-middle-output-${'y' * 3000}';
      final latestOutput = 'compare-latest-output-${'z' * 3000}';
      session.messages.addAll([
        ChatMessage.user('old compare tool prompt'),
        ChatMessage(
          role: 'assistant',
          content: [
            ToolUseContent(
              id: 'call_old',
              name: 'bash',
              input: const {'cmd': 'cat old.txt'},
            ),
          ],
        ),
        ChatMessage(
          role: 'user',
          content: [
            ToolResultContent(toolUseId: 'call_old', output: oldOutput),
          ],
        ),
        ChatMessage(role: 'assistant', content: [TextContent('old done')]),
        ChatMessage.user('middle compare tool prompt'),
        ChatMessage(
          role: 'assistant',
          content: [
            ToolUseContent(
              id: 'call_middle',
              name: 'grep',
              input: const {'cmd': 'grep middle'},
            ),
          ],
        ),
        ChatMessage(
          role: 'user',
          content: [
            ToolResultContent(toolUseId: 'call_middle', output: middleOutput),
          ],
        ),
        ChatMessage(role: 'assistant', content: [TextContent('middle done')]),
        ChatMessage.user('latest compare tool prompt'),
        ChatMessage(
          role: 'assistant',
          content: [
            ToolUseContent(
              id: 'call_latest',
              name: 'cat',
              input: const {'cmd': 'cat latest.txt'},
            ),
          ],
        ),
        ChatMessage(
          role: 'user',
          content: [
            ToolResultContent(toolUseId: 'call_latest', output: latestOutput),
          ],
        ),
        ChatMessage(role: 'assistant', content: [TextContent('latest done')]),
      ]);

      await provider.sendCompare('compare prompt', ['model-a', 'model-b']);

      expect(provider.errorMessage, isNull);
      expect(observedMessages, hasLength(2));
      for (final messages in observedMessages) {
        final payload = messages.toString();
        expect(payload, contains('Tool result truncated'));
        expect(payload, contains('tool: bash'));
        expect(payload, isNot(contains(oldOutput)));
        expect(payload, contains(middleOutput));
        expect(payload, contains(latestOutput));
      }
    });

    test('valid summary is injected for compare', () async {
      SharedPreferences.setMockInitialValues({
        'active_provider_profile_id': 'profile',
        'context_token_budget': 32768,
        'developer_mode': true,
      });
      final observedSystems = <String>[];
      final provider = ChatProvider(
        contextSummaryServiceFactory: () => _ScriptedContextSummaryService(
          onGenerate: (request) => _summaryForRequest(request),
        ),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => StreamDone(const LlmResponse(
            stopReason: 'end_turn',
            content: [ContentBlock(type: 'text', text: 'ok')],
          )),
          onChat: (_) => const LlmResponse(
            stopReason: 'end_turn',
            content: [ContentBlock(type: 'text', text: 'ok')],
          ),
          onStreamSystem: observedSystems.add,
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();
      session.messages.addAll([
        ChatMessage.user('compare-covered-${'中' * 24000}'),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('compare old reply ${'中' * 24000}')],
        ),
        ChatMessage.user('recent prompt'),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('recent reply')],
        ),
      ]);
      final compareMessages = [
        ...session.toApiMessages(),
        {'role': 'user', 'content': 'compare prompt'},
      ];
      final historyBudget = 32768 -
          const TokenEstimator()
              .estimateText(AppConstants.defaultSystemPrompt) -
          8192 -
          1024;
      final plan = ChatContextUtils.planCompaction(
        compareMessages,
        maxTokens: historyBudget,
        estimator: const TokenEstimator(),
      );
      session.contextSummary = ContextSummary(
        version: ContextSummaryService.version,
        text: '## Goal\nValid compare summary',
        coveredMessageCount: plan.headForSummary.length,
        coveredDigest: plan.headDigest,
        sourceEstimatedTokens: plan.headEstimatedTokens,
        summaryEstimatedTokens: 20,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );

      await provider.sendCompare('compare prompt', ['model-a', 'model-b']);

      expect(provider.errorMessage, isNull);
      expect(observedSystems, hasLength(2));
      expect(observedSystems.join('\n'), contains('Valid compare summary'));
      expect(
        observedSystems.join('\n'),
        contains('conversation_context_summary'),
      );
    });

    test('stale summary is not injected for compare', () async {
      SharedPreferences.setMockInitialValues({
        'active_provider_profile_id': 'profile',
        'context_token_budget': 32768,
        'developer_mode': true,
      });
      final observedSystems = <String>[];
      final provider = ChatProvider(
        contextSummaryServiceFactory: () => _ScriptedContextSummaryService(
          onGenerate: (request) => _summaryForRequest(request),
        ),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => StreamDone(const LlmResponse(
            stopReason: 'end_turn',
            content: [ContentBlock(type: 'text', text: 'ok')],
          )),
          onChat: (_) => const LlmResponse(
            stopReason: 'end_turn',
            content: [ContentBlock(type: 'text', text: 'ok')],
          ),
          onStreamSystem: observedSystems.add,
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();
      session.messages.addAll([
        ChatMessage.user('compare-head-${'中' * 24000}'),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('old reply ${'中' * 24000}')],
        ),
        ChatMessage.user('recent prompt'),
      ]);
      session.contextSummary = ContextSummary(
        version: ContextSummaryService.version,
        text: '## Goal\nStale compare summary',
        coveredMessageCount: 1,
        coveredDigest: 'wrong-digest',
        sourceEstimatedTokens: 100,
        summaryEstimatedTokens: 20,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );

      await provider.sendCompare('compare prompt', ['model-a', 'model-b']);

      expect(provider.errorMessage, isNull);
      expect(observedSystems, hasLength(2));
      expect(
        observedSystems.join('\n'),
        isNot(contains('Stale compare summary')),
      );
      expect(
        observedSystems.join('\n'),
        isNot(contains('conversation_context_summary')),
      );
    });

    test('new session with only current message does not trigger summary',
        () async {
      SharedPreferences.setMockInitialValues({
        'active_provider_profile_id': 'profile',
        'context_token_budget': 32768,
        'developer_mode': true,
      });
      final observedSystems = <String>[];
      var summaryCalls = 0;
      final provider = ChatProvider(
        contextSummaryServiceFactory: () => _ScriptedContextSummaryService(
          onGenerate: (request) {
            summaryCalls++;
            throw StateError('summary should not be generated');
          },
        ),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => StreamDone(const LlmResponse(
            stopReason: 'end_turn',
            content: [ContentBlock(type: 'text', text: 'ok')],
          )),
          onStreamSystem: observedSystems.add,
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await provider.createSession();

      await provider.sendMessage('hello');

      expect(provider.errorMessage, isNull);
      expect(summaryCalls, 0);
      expect(observedSystems, hasLength(1));
      expect(
        observedSystems.single,
        isNot(contains('conversation_context_summary')),
      );
    });

    test('single over-budget current message does not trigger summary',
        () async {
      SharedPreferences.setMockInitialValues({
        'active_provider_profile_id': 'profile',
        'context_token_budget': 32768,
        'developer_mode': true,
      });
      final observedMessages = <List<Map<String, dynamic>>>[];
      final observedSystems = <String>[];
      var summaryCalls = 0;
      final provider = ChatProvider(
        contextSummaryServiceFactory: () => _ScriptedContextSummaryService(
          onGenerate: (request) {
            summaryCalls++;
            throw StateError('summary should not be generated');
          },
        ),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (messages) {
            observedMessages.add(
              messages
                  .map((message) => Map<String, dynamic>.from(message))
                  .toList(),
            );
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'ok')],
            ));
          },
          onStreamSystem: observedSystems.add,
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await provider.createSession();

      await provider.sendMessage('single-long-${'中' * 40000}');

      expect(provider.errorMessage, isNull);
      expect(summaryCalls, 0);
      expect(observedMessages.single, hasLength(1));
      expect(observedMessages.single.toString(), contains('single-long'));
      expect(
        observedSystems.single,
        isNot(contains('conversation_context_summary')),
      );
    });

    test('successful send updates token calibration', () async {
      final events = RuntimeDebugEventService();
      final provider = ChatProvider(
        runtimeDebugEvents: events,
        contextSummaryServiceFactory: () => _ScriptedContextSummaryService(
          onGenerate: (request) => _summaryForRequest(request),
        ),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => StreamDone(const LlmResponse(
            stopReason: 'end_turn',
            content: [ContentBlock(type: 'text', text: 'ok')],
            usage: LlmUsage(inputTokens: 22000, outputTokens: 50),
          )),
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final session = await provider.createSession();
      for (var i = 0; i < 12; i++) {
        session.messages.add(ChatMessage.user('history-$i ${'x' * 4000}'));
      }
      await provider.sendMessage('calibrate');

      expect(provider.errorMessage, isNull);
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(TokenCalibrationService.storageKey);
      expect(raw, isNotNull);
      final stored = jsonDecode(raw!) as Map<String, dynamic>;
      final entry = stored.values.single as Map<String, dynamic>;
      expect(entry['multiplier'] as double, greaterThan(1.0));
      expect(entry['sampleCount'], 1);
      final calibrationEvent = events
          .recent(sessionId: session.id)
          .where((event) => event.type == 'token.calibration.updated')
          .single;
      expect(calibrationEvent.data.containsKey('keyHash'), isFalse);
      expect(calibrationEvent.data['newMultiplier'], greaterThan(1.0));
      expect(calibrationEvent.data.toString(), isNot(contains('127.0.0.1')));
    });

    test('successful send records skipped token calibration event', () async {
      final events = RuntimeDebugEventService();
      final provider = ChatProvider(
        runtimeDebugEvents: events,
        contextSummaryServiceFactory: () => _ScriptedContextSummaryService(
          onGenerate: (request) => _summaryForRequest(request),
        ),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => StreamDone(const LlmResponse(
            stopReason: 'end_turn',
            content: [ContentBlock(type: 'text', text: 'ok')],
          )),
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final session = await provider.createSession();
      for (var i = 0; i < 12; i++) {
        session.messages.add(ChatMessage.user('history-$i ${'x' * 4000}'));
      }
      await provider.sendMessage('calibrate skip');

      expect(provider.errorMessage, isNull);
      final calibrationEvent = events
          .recent(sessionId: session.id)
          .where((event) => event.type == 'token.calibration.skipped')
          .single;
      expect(calibrationEvent.data['reason'], 'missing_actual_tokens');
      expect(calibrationEvent.data['estimatedInputTokens'], greaterThan(0));
    });

    test('sensitive redactions skip token calibration', () async {
      final events = RuntimeDebugEventService();
      final provider = ChatProvider(
        runtimeDebugEvents: events,
        contextSummaryServiceFactory: () => _ScriptedContextSummaryService(
          onGenerate: (request) => _summaryForRequest(request),
        ),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => StreamDone(const LlmResponse(
            stopReason: 'end_turn',
            content: [ContentBlock(type: 'text', text: 'ok')],
            usage: LlmUsage(inputTokens: 22000, outputTokens: 50),
          )),
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final session = await provider.createSession();
      for (var i = 0; i < 12; i++) {
        session.messages.add(ChatMessage.user('history-$i ${'x' * 4000}'));
      }
      await provider.sendMessage(
        'please use api_key=sk-proj-abcdefghijklmnopqrstuvwxyz123456',
      );

      expect(provider.errorMessage, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(TokenCalibrationService.storageKey), isNull);
      final calibrationEvent = events
          .recent(sessionId: session.id)
          .where((event) => event.type == 'token.calibration.skipped')
          .single;
      expect(calibrationEvent.data['reason'], 'sensitive_data_redacted');
      expect(calibrationEvent.data.toString(), isNot(contains('sk-proj-')));
    });

    test('encrypted recovery does not update token calibration', () async {
      var requestCount = 0;
      final provider = ChatProvider(
        contextSummaryServiceFactory: () => _ScriptedContextSummaryService(
          onGenerate: (request) => _summaryForRequest(request),
        ),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) {
            requestCount++;
            if (requestCount == 1) {
              return StreamError(
                'encrypted',
                cause: const EncryptedContentError(
                  'Anthropic API error: invalid_encrypted_content: encrypted',
                  code: 'invalid_encrypted_content',
                ),
              );
            }
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'ok')],
              usage: LlmUsage(inputTokens: 22000, outputTokens: 50),
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final session = await provider.createSession();
      for (var i = 0; i < 12; i++) {
        session.messages.add(ChatMessage.user('history-$i ${'x' * 4000}'));
      }
      await provider.sendMessage('recover');

      expect(provider.errorMessage, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(TokenCalibrationService.storageKey), isNull);
    });

    test('encrypted recovery retries summary-aware payload only', () async {
      SharedPreferences.setMockInitialValues({
        'active_provider_profile_id': 'profile',
        'context_token_budget': 32768,
        'developer_mode': true,
      });
      var requestCount = 0;
      final observedMessages = <List<Map<String, dynamic>>>[];
      final observedSystems = <String>[];
      final provider = ChatProvider(
        contextSummaryServiceFactory: () => _ScriptedContextSummaryService(
          onGenerate: (request) => _summaryForRequest(request),
        ),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (messages) {
            observedMessages.add(messages);
            requestCount++;
            if (requestCount == 1) {
              return StreamError(
                'encrypted',
                cause: const EncryptedContentError(
                  'Anthropic API error: invalid_encrypted_content: encrypted',
                  code: 'invalid_encrypted_content',
                ),
              );
            }
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'ok')],
            ));
          },
          onStreamSystem: observedSystems.add,
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();
      session.messages.addAll([
        ChatMessage.user('summarized-head-${'中' * 24000}'),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('old reply ${'中' * 24000}')],
        ),
        ChatMessage.user('recent prompt'),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('recent reply')],
        ),
      ]);
      final apiMessages = [
        ...session.toApiMessages(),
        {'role': 'user', 'content': 'new prompt'},
      ];
      final historyBudget = 32768 -
          const TokenEstimator()
              .estimateText(AppConstants.defaultSystemPrompt) -
          1891 -
          8192 -
          1024;
      final plan = ChatContextUtils.planCompaction(
        apiMessages,
        maxTokens: historyBudget,
        estimator: const TokenEstimator(),
      );
      session.contextSummary = ContextSummary(
        version: ContextSummaryService.version,
        text: '## Goal\nReusable recovery summary',
        coveredMessageCount: plan.headForSummary.length,
        coveredDigest: plan.headDigest,
        sourceEstimatedTokens: plan.headEstimatedTokens,
        summaryEstimatedTokens: 20,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );

      await provider.sendMessage('new prompt');

      expect(provider.errorMessage, isNull);
      expect(observedMessages, hasLength(2));
      for (final payload in observedMessages) {
        final serialized = payload.toString();
        expect(serialized, isNot(contains('summarized-head')));
        expect(serialized, contains('new prompt'));
      }
      expect(observedSystems, hasLength(2));
      expect(observedSystems.join('\n'), contains('Reusable recovery summary'));
    });

    test('tool-call agent loops do not update token calibration', () async {
      var requestCount = 0;
      final tools = ToolRegistry()..register(_EchoTool(), risk: ToolRisk.safe);
      final provider = ChatProvider(
        toolRegistry: tools,
        contextSummaryServiceFactory: () => _ScriptedContextSummaryService(
          onGenerate: (request) => _summaryForRequest(request),
        ),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => throw UnimplementedError(),
          onMessageEvents: (_) {
            requestCount++;
            if (requestCount == 1) {
              return [
                StreamDone(const LlmResponse(
                  stopReason: 'tool_use',
                  content: [
                    ContentBlock(
                      type: 'tool_use',
                      toolUseId: 'call_1',
                      toolName: 'echo',
                      toolInput: {'text': 'hi'},
                    ),
                  ],
                )),
              ];
            }
            return [
              StreamDone(const LlmResponse(
                stopReason: 'end_turn',
                content: [ContentBlock(type: 'text', text: 'ok')],
                usage: LlmUsage(inputTokens: 22000, outputTokens: 50),
              )),
            ];
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final session = await provider.createSession();
      for (var i = 0; i < 12; i++) {
        session.messages.add(ChatMessage.user('history-$i ${'x' * 4000}'));
      }
      await provider.sendMessage('use tool');

      expect(provider.errorMessage, isNull);
      expect(requestCount, 2);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(TokenCalibrationService.storageKey), isNull);
    });

    test('tool-call preflight repairs malformed args with sanitized event',
        () async {
      var requestCount = 0;
      final events = RuntimeDebugEventService();
      final tools = ToolRegistry()..register(_EchoTool(), risk: ToolRisk.safe);
      final provider = ChatProvider(
        runtimeDebugEvents: events,
        toolRegistry: tools,
        contextSummaryServiceFactory: () => _ScriptedContextSummaryService(
          onGenerate: (request) => _summaryForRequest(request),
        ),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => throw UnimplementedError(),
          onMessageEvents: (_) {
            requestCount++;
            if (requestCount == 1) {
              return [
                StreamDone(const LlmResponse(
                  stopReason: 'tool_use',
                  content: [
                    ContentBlock(
                      type: 'tool_use',
                      toolUseId: 'call_1',
                      toolName: 'echo',
                      toolInput: {},
                      rawToolInputJson: '{"text":"hi"',
                    ),
                  ],
                )),
              ];
            }
            return [
              StreamDone(const LlmResponse(
                stopReason: 'end_turn',
                content: [ContentBlock(type: 'text', text: 'ok')],
              )),
            ];
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final session = await provider.createSession();
      await provider.sendMessage('use repaired tool');

      expect(provider.errorMessage, isNull);
      expect(requestCount, 2);
      final toolResult = provider.currentSession!.messages
          .expand((message) => message.toolResults)
          .single;
      expect(toolResult.output, contains('hi'));

      final event = events
          .recent(sessionId: session.id)
          .where((event) => event.type == 'tool.preflight.repaired')
          .single;
      expect(event.data['repairCount'], 1);
      expect(event.data['jsonClosureRepairCount'], 1);
      expect(event.data.containsKey('toolName'), isFalse);
      expect(event.data.toString(), isNot(contains('hi')));
      expect(event.data.toString(), isNot(contains('text')));
    });

    test('tool calls persist ForUser while next LLM request receives ForLLM',
        () async {
      final observedMessages = <List<Map<String, dynamic>>>[];
      final tools = ToolRegistry()
        ..register(
          _DualTrackTool(),
          risk: ToolRisk.safe,
        );
      final provider = ChatProvider(
        toolRegistry: tools,
        contextSummaryServiceFactory: () => _ScriptedContextSummaryService(
          onGenerate: (request) => _summaryForRequest(request),
        ),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => throw UnimplementedError(),
          onMessageEvents: (messages) {
            observedMessages.add((jsonDecode(jsonEncode(messages)) as List)
                .map((message) => Map<String, dynamic>.from(message as Map))
                .toList());
            if (observedMessages.length == 1) {
              return [
                StreamDone(const LlmResponse(
                  stopReason: 'tool_use',
                  content: [
                    ContentBlock(
                      type: 'tool_use',
                      toolUseId: 'call_1',
                      toolName: 'dual_track',
                      toolInput: {'text': 'hi'},
                    ),
                  ],
                )),
              ];
            }
            return [
              StreamDone(const LlmResponse(
                stopReason: 'end_turn',
                content: [ContentBlock(type: 'text', text: 'ok')],
              )),
            ];
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await provider.createSession();
      await provider.sendMessage('use tool');

      expect(provider.errorMessage, isNull);
      expect(observedMessages, hasLength(2));
      final secondRequest = observedMessages.last.toString();
      expect(secondRequest, contains('compact for llm'));
      expect(secondRequest, isNot(contains('FULL USER OUTPUT')));

      final toolResult = provider.currentSession!.messages
          .expand((message) => message.toolResults)
          .single;
      expect(toolResult.output, contains('FULL USER OUTPUT'));
      expect(toolResult.llmOutput, contains('compact for llm'));
      expect(toolResult.toApiJson()['content'], contains('compact for llm'));
    });

    test('next send uses persisted calibration multiplier', () async {
      SharedPreferences.setMockInitialValues({
        'active_provider_profile_id': 'profile',
        'context_token_budget': 32768,
        TokenCalibrationService.storageKey: jsonEncode({
          'anthropic|127.0.0.1|profile|claude-sonnet-4-20250514': {
            'multiplier': 2.0,
            'sampleCount': 3,
            'updatedAtMillis': 1,
          },
        }),
      });
      final observedMessages = <List<Map<String, dynamic>>>[];
      final provider = ChatProvider(
        contextSummaryServiceFactory: () => _ScriptedContextSummaryService(
          onGenerate: (request) => _summaryForRequest(request),
        ),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (messages) {
            observedMessages.add(messages);
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'ok')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();
      session.messages.addAll([
        ChatMessage.user('old-calibrated-${'x' * 30000}'),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('old reply ${'x' * 30000}')],
        ),
        ChatMessage.user('recent prompt'),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('recent reply')],
        ),
      ]);

      await provider.sendMessage('new prompt');

      expect(provider.errorMessage, isNull);
      expect(observedMessages, hasLength(1));
      final serialized = observedMessages.single.toString();
      expect(serialized, isNot(contains('old-calibrated')));
      expect(serialized, isNot(contains('old reply')));
      expect(serialized, contains('new prompt'));
    });

    test('tool definitions are subtracted from message budget', () async {
      SharedPreferences.setMockInitialValues({
        'active_provider_profile_id': 'profile',
        'context_token_budget': 32768,
        'developer_mode': true,
      });
      final observedMessages = <List<Map<String, dynamic>>>[];
      final observedTools = <int>[];
      final provider = ChatProvider(
        contextSummaryServiceFactory: () => _ScriptedContextSummaryService(
          onGenerate: (request) => _summaryForRequest(request),
        ),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (messages) {
            observedMessages.add(messages);
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'ok')],
            ));
          },
          onTools: (tools) => observedTools.add(tools.length),
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();
      session.messages.addAll([
        ChatMessage.user('old-tools-${'中' * 17000}'),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('old reply ${'中' * 17000}')],
        ),
        ChatMessage.user('recent prompt'),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('recent reply')],
        ),
      ]);

      await provider.sendMessage('new prompt');

      expect(provider.errorMessage, isNull);
      expect(observedTools.single, greaterThan(0));
      final serialized = observedMessages.single.toString();
      expect(serialized, isNot(contains('old-tools')));
      expect(serialized, isNot(contains('old reply')));
      expect(serialized, contains('new prompt'));
    });

    test('unsupported tools are not subtracted from message budget', () async {
      SharedPreferences.setMockInitialValues({
        'active_provider_profile_id': 'profile',
        'context_token_budget': 32768,
        'developer_mode': true,
      });
      final tools = ToolRegistry()
        ..register(_LargeSchemaTool(), risk: ToolRisk.safe);
      final observedMessages = <List<Map<String, dynamic>>>[];
      final provider = ChatProvider(
        toolRegistry: tools,
        contextSummaryServiceFactory: () => _ScriptedContextSummaryService(
          onGenerate: (request) {
            throw StateError('summary should not be generated');
          },
        ),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          resolvedProfile: _resolvedProfileWithCapabilities(
            const caps.ModelCapabilities(supportsTools: false),
          ),
          onMessages: (messages) {
            observedMessages.add(messages);
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'ok')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();
      session.messages.add(ChatMessage.user('old-no-tools-${'中' * 14000}'));

      await provider.sendMessage('new prompt');

      expect(provider.errorMessage, isNull);
      expect(observedMessages, hasLength(1));
      final serialized = observedMessages.single.toString();
      expect(serialized, contains('old-no-tools'));
      expect(serialized, contains('new prompt'));
    });

    test('unsupported tools are not sent through AgentService', () async {
      final tools = ToolRegistry()..register(_EchoTool(), risk: ToolRisk.safe);
      final observedTools = <int>[];
      final provider = ChatProvider(
        toolRegistry: tools,
        contextSummaryServiceFactory: () => _ScriptedContextSummaryService(
          onGenerate: (request) => _summaryForRequest(request),
        ),
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          resolvedProfile: _resolvedProfileWithCapabilities(
            const caps.ModelCapabilities(supportsTools: false),
          ),
          onMessages: (_) => StreamDone(const LlmResponse(
            stopReason: 'end_turn',
            content: [ContentBlock(type: 'text', text: 'ok')],
          )),
          onTools: (tools) => observedTools.add(tools.length),
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await provider.createSession();
      await provider.sendMessage('hello');

      expect(provider.errorMessage, isNull);
      expect(observedTools, [0]);
    });
  });

  group('charCount - string content', () {
    test('counts simple string content', () {
      expect(charCount({'role': 'user', 'content': 'hello'}), 5);
    });

    test('counts top-level reasoning_content with string content', () {
      expect(
        charCount({
          'role': 'assistant',
          'content': 'hello',
          'reasoning_content': 'thinking',
        }),
        13,
      );
    });

    test('counts empty string as 0', () {
      expect(charCount({'role': 'user', 'content': ''}), 0);
    });

    test('counts long string accurately', () {
      final long = 'x' * 5000;
      expect(charCount({'role': 'user', 'content': long}), 5000);
    });
  });

  group('charCount - list content', () {
    test('counts text in list items', () {
      expect(
        charCount({
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'hello world'},
          ],
        }),
        11,
      );
    });

    test('counts reasoning_content in list text items', () {
      expect(
        charCount({
          'role': 'assistant',
          'content': [
            {
              'type': 'text',
              'text': 'hello',
              'reasoning_content': 'thinking',
            },
          ],
        }),
        13,
      );
    });

    test('counts content field in list items (tool_result)', () {
      expect(
        charCount({
          'role': 'user',
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 'call_1',
              'content': 'output text',
            },
          ],
        }),
        11,
      );
    });

    test('sums text and content across multiple items', () {
      expect(
        charCount({
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'abc'}, // 3
            {'type': 'text', 'text': 'de'}, // 2
          ],
        }),
        5,
      );
    });

    test('handles mixed text and tool_result items', () {
      expect(
        charCount({
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'hello'}, // 5
            {
              'type': 'tool_result',
              'tool_use_id': 'x',
              'content': '1234567890',
            }, // 10
          ],
        }),
        15,
      );
    });

    test('counts empty list as 0', () {
      expect(charCount({'role': 'user', 'content': <dynamic>[]}), 0);
    });

    test('ignores non-Map items in list', () {
      expect(
        charCount({
          'role': 'user',
          'content': ['plain string', 42],
        }),
        0,
      );
    });

    test('handles items without text or content keys', () {
      expect(
        charCount({
          'role': 'assistant',
          'content': [
            {'type': 'tool_use', 'id': 'call_1', 'name': 'bash'},
          ],
        }),
        0,
      );
    });
  });

  group('charCount - edge cases', () {
    test('returns 0 when content key is missing', () {
      expect(charCount({'role': 'user'}), 0);
    });

    test('returns 0 when content is null', () {
      expect(charCount({'role': 'user', 'content': null}), 0);
    });

    test('returns 0 when content is a number', () {
      expect(charCount({'role': 'user', 'content': 42}), 0);
    });

    test('returns 0 for empty map', () {
      expect(charCount({}), 0);
    });
  });

  group('truncateToFit - basic behavior', () {
    test('preserves all messages when under the limit', () {
      final msgs = [
        {'role': 'user', 'content': 'hi'},
        {'role': 'assistant', 'content': 'hello'},
      ];
      final result = truncateToFit(msgs);
      expect(result.length, 2);
      expect(result[0]['content'], 'hi');
      expect(result[1]['content'], 'hello');
    });

    test('does not modify original list', () {
      final msgs = List.generate(
        10,
        (i) => {
          'role': i.isEven ? 'user' : 'assistant',
          'content': 'x' * 20000,
        },
      );
      final originalLength = msgs.length;
      truncateToFit(msgs);
      expect(msgs.length, originalLength);
    });
  });

  group('truncateToFit - truncation behavior', () {
    test('removes oldest messages first when over limit', () {
      final msgs = List.generate(
        10,
        (i) => {
          'role': i.isEven ? 'user' : 'assistant',
          'content': 'msg_$i ${'x' * 20000}',
        },
      );
      final result = truncateToFit(msgs);
      expect(result.length, lessThan(10));
      expect(result.last['content'], contains('msg_9'));
    });

    test('always keeps at least 2 messages even if over limit', () {
      final msgs = [
        {'role': 'user', 'content': 'x' * 200000},
        {'role': 'assistant', 'content': 'y' * 200000},
        {'role': 'user', 'content': 'z' * 200000},
      ];
      final result = truncateToFit(msgs);
      expect(result.length, 2);
    });

    test('keeps exactly 2 when 3 messages exceed limit', () {
      final msgs = [
        {'role': 'user', 'content': 'a' * 50000},
        {'role': 'assistant', 'content': 'b' * 50000},
        {'role': 'user', 'content': 'c' * 50000},
      ];
      final result = truncateToFit(msgs);
      expect(result.length, 2);
      expect(result[0]['content'], startsWith('b'));
      expect(result[1]['content'], startsWith('c'));
    });

    test('does not truncate when exactly at limit', () {
      final msgs = [
        {'role': 'user', 'content': 'a' * 50000},
        {'role': 'assistant', 'content': 'b' * 50000},
      ];
      final result = truncateToFit(msgs);
      expect(result.length, 2);
    });

    test('handles single message (does not truncate below 2)', () {
      final msgs = [
        {'role': 'user', 'content': 'x' * 200000},
      ];
      final result = truncateToFit(msgs);
      expect(result.length, 1);
    });

    test('handles empty list', () {
      final result = truncateToFit([]);
      expect(result, isEmpty);
    });
  });

  group('truncateToFit - with list content', () {
    test('correctly counts and truncates list content messages', () {
      final msgs = List.generate(
        8,
        (i) => <String, dynamic>{
          'role': i.isEven ? 'user' : 'assistant',
          'content': [
            {'type': 'text', 'text': 'message_$i ${'y' * 20000}'},
          ],
        },
      );
      final result = truncateToFit(msgs);
      expect(result.length, lessThan(8));
      expect(result.length, greaterThanOrEqualTo(2));
    });
  });
}

class _ScriptedLlmService extends LlmService {
  final StreamEvent Function(List<Map<String, dynamic>> messages) onMessages;
  final List<StreamEvent> Function(List<Map<String, dynamic>> messages)?
      onMessageEvents;
  final LlmResponse Function(List<Map<String, dynamic>> messages)? onChat;
  final void Function(List<ToolDefinition> tools)? onTools;
  final void Function(String system)? onStreamSystem;
  final void Function()? onDispose;
  final caps.ResolvedModelProfile? resolvedProfile;

  _ScriptedLlmService(
    super.config, {
    required this.onMessages,
    this.onMessageEvents,
    this.onChat,
    this.onTools,
    this.onStreamSystem,
    this.onDispose,
    this.resolvedProfile,
  });

  @override
  caps.ResolvedModelProfile get resolvedModelProfile =>
      resolvedProfile ?? super.resolvedModelProfile;

  @override
  Future<LlmResponse> chat({
    required String system,
    required List<Map<String, dynamic>> messages,
    required List<ToolDefinition> tools,
  }) async {
    onStreamSystem?.call(system);
    onTools?.call(tools);
    final handler = onChat;
    if (handler != null) return handler(messages);
    final eventsHandler = onMessageEvents;
    if (eventsHandler != null) {
      for (final event in eventsHandler(messages)) {
        if (event is StreamDone) return event.response;
        if (event is StreamError) throw Exception(event.message);
      }
    }
    final event = onMessages(messages);
    if (event is StreamDone) return event.response;
    if (event is StreamError) throw Exception(event.message);
    return const LlmResponse(
      stopReason: 'end_turn',
      content: [ContentBlock(type: 'text', text: 'ok')],
    );
  }

  @override
  Stream<StreamEvent> chatStream({
    required String system,
    required List<Map<String, dynamic>> messages,
    required List<ToolDefinition> tools,
  }) async* {
    onStreamSystem?.call(system);
    onTools?.call(tools);
    final eventsHandler = onMessageEvents;
    if (eventsHandler != null) {
      for (final event in eventsHandler(messages)) {
        if (event is StreamDone) {
          final text = event.response.content
              .where((block) => block.type == 'text')
              .map((block) => block.text ?? '')
              .join();
          if (text.isNotEmpty) yield TextDelta(text);
        }
        yield event;
      }
      return;
    }
    final event = onMessages(messages);
    if (event is StreamDone) {
      final text = event.response.content
          .where((block) => block.type == 'text')
          .map((block) => block.text ?? '')
          .join();
      if (text.isNotEmpty) yield TextDelta(text);
    }
    yield event;
  }

  @override
  void dispose() {
    onDispose?.call();
    super.dispose();
  }
}

class _GatedToolRequestLlmService extends LlmService {
  _GatedToolRequestLlmService(
    super.config, {
    required this.firstRequestStarted,
    required this.releaseToolRequest,
    required this.onRequest,
  });

  final Completer<void> firstRequestStarted;
  final Completer<void> releaseToolRequest;
  final int Function() onRequest;

  @override
  Stream<StreamEvent> chatStream({
    required String system,
    required List<Map<String, dynamic>> messages,
    required List<ToolDefinition> tools,
  }) async* {
    final request = onRequest();
    if (request == 1) {
      if (!firstRequestStarted.isCompleted) firstRequestStarted.complete();
      await releaseToolRequest.future;
      yield StreamDone(const LlmResponse(
        stopReason: 'tool_use',
        content: [
          ContentBlock(
            type: 'tool_use',
            toolUseId: 'auto_transition',
            toolName: 'echo',
            toolInput: {'text': 'transition-auto'},
          ),
        ],
      ));
      return;
    }
    yield StreamDone(const LlmResponse(
      stopReason: 'end_turn',
      content: [ContentBlock(type: 'text', text: 'done')],
    ));
  }
}

class _ResetPauseLlmService extends LlmService {
  final Completer<void> resetEmitted;
  final Completer<void> continueAfterReset;
  final Completer<void> cleanTokenEmitted;
  final Completer<void> finishStream;

  _ResetPauseLlmService(
    super.config, {
    required this.resetEmitted,
    required this.continueAfterReset,
    required this.cleanTokenEmitted,
    required this.finishStream,
  });

  @override
  Stream<StreamEvent> chatStream({
    required String system,
    required List<Map<String, dynamic>> messages,
    required List<ToolDefinition> tools,
  }) async* {
    yield TextDelta('dirty first attempt');
    yield const StreamReset();
    if (!resetEmitted.isCompleted) resetEmitted.complete();
    await continueAfterReset.future;
    yield TextDelta('clean retry text');
    if (!cleanTokenEmitted.isCompleted) cleanTokenEmitted.complete();
    await finishStream.future;
    yield StreamDone(const LlmResponse(
      stopReason: 'end_turn',
      content: [ContentBlock(type: 'text', text: 'clean retry text')],
    ));
  }
}

class _GuardedSecretPauseLlmService extends LlmService {
  final String sentinel;
  final Completer<void> buffered;
  final Completer<void> release;

  _GuardedSecretPauseLlmService(
    super.config, {
    required this.sentinel,
    required this.buffered,
    required this.release,
  });

  @override
  Stream<StreamEvent> chatStream({
    required String system,
    required List<Map<String, dynamic>> messages,
    required List<ToolDefinition> tools,
  }) async* {
    yield TextDelta('visible $sentinel');
    yield ReasoningDelta('reasoning $sentinel');
    yield ToolUseStart('set_secret_cancel', 'set_env_var');
    yield ToolInputDelta(
      '{"name":"CANCELLED_TOKEN","value":"$sentinel"}',
    );
    if (!buffered.isCompleted) buffered.complete();
    await release.future;
    yield StreamError('cancelled test stream');
  }
}

class _BlockingLlmService extends LlmService {
  final Completer<void> started;
  final Completer<void> release;
  final Completer<void>? disposed;
  final StreamEvent completionEvent;

  _BlockingLlmService(
    super.config, {
    required this.started,
    required this.release,
    this.disposed,
    StreamEvent? completionEvent,
  }) : completionEvent = completionEvent ??
            StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'done')],
            ));

  @override
  Stream<StreamEvent> chatStream({
    required String system,
    required List<Map<String, dynamic>> messages,
    required List<ToolDefinition> tools,
  }) async* {
    if (!started.isCompleted) started.complete();
    await release.future;
    yield completionEvent;
  }

  @override
  void dispose() {
    if (disposed != null && !disposed!.isCompleted) {
      disposed!.complete();
    }
    if (!release.isCompleted) release.complete();
    super.dispose();
  }
}

class _ManualTimerScheduler {
  final List<_ManualTimer> _timers = [];

  int get createdCount => _timers.length;
  int get activeCount => _timers.where((timer) => timer.isActive).length;

  Timer schedule(Duration duration, void Function() callback) {
    final timer = _ManualTimer(callback);
    _timers.add(timer);
    return timer;
  }

  void fireAll() {
    for (final timer in List<_ManualTimer>.from(_timers)) {
      timer.fire();
    }
  }
}

class _ManualTimer implements Timer {
  _ManualTimer(this._callback);

  final void Function() _callback;
  bool _active = true;
  int _tick = 0;

  void fire() {
    if (!_active) return;
    _active = false;
    _tick = 1;
    _callback();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => _tick;
}

class _BlockingCompareLlmService extends LlmService {
  _BlockingCompareLlmService(
    super.config, {
    required this.started,
    required this.release,
    required this.disposed,
  });

  final Completer<void> started;
  final Completer<void> release;
  final Completer<void> disposed;

  @override
  Future<LlmResponse> chat({
    required String system,
    required List<Map<String, dynamic>> messages,
    List<ToolDefinition>? tools,
  }) async {
    if (!started.isCompleted) started.complete();
    await release.future;
    return const LlmResponse(
      stopReason: 'end_turn',
      content: [ContentBlock(type: 'text', text: 'ignored')],
    );
  }

  @override
  void dispose() {
    if (!disposed.isCompleted) disposed.complete();
    if (!release.isCompleted) release.complete();
    super.dispose();
  }
}

class _BlockingCompareWithMessages extends LlmService {
  _BlockingCompareWithMessages(
    super.config, {
    required this.started,
    required this.release,
    required this.observed,
  });

  final Completer<void> started;
  final Completer<void> release;
  final List<List<Map<String, dynamic>>> observed;

  @override
  Future<LlmResponse> chat({
    required String system,
    required List<Map<String, dynamic>> messages,
    List<ToolDefinition>? tools,
  }) async {
    observed.add(
      messages.map((message) => Map<String, dynamic>.from(message)).toList(),
    );
    if (!started.isCompleted) started.complete();
    await release.future;
    return const LlmResponse(
      stopReason: 'end_turn',
      content: [ContentBlock(type: 'text', text: 'late')],
    );
  }
}

class _CountingRuntimeDebugEventService extends RuntimeDebugEventService {
  int setTracingEnabledCalls = 0;

  @override
  void setTracingEnabled(bool enabled) {
    setTracingEnabledCalls++;
    super.setTracingEnabled(enabled);
  }
}

class _RejectingAttachmentBudget extends AttachmentBudget {
  const _RejectingAttachmentBudget();

  @override
  void checkMessageAttachments(List<MessageContent> attachments) {
    throw const AttachmentBudgetException('injected attachment rejection');
  }
}

AgentRunRecoveryMarker _unknownRecoveryMarker(String runAttemptId) {
  final timestamp = DateTime.utc(2026, 7, 10);
  return AgentRunRecoveryMarker(
    runAttemptId: runAttemptId,
    startedAt: timestamp,
    updatedAt: timestamp,
    phase: AgentRunRecoveryPhase.toolInFlight,
    toolAttempts: [
      ToolAttemptRecoveryMetadata(
        operationId: 'unknown-operation-$runAttemptId',
        toolName: 'web_fetch',
        risk: RecoveryToolRisk.moderate,
        lifecycle: ToolAttemptLifecycle.interruptedUnknown,
        proposedAt: timestamp,
        updatedAt: timestamp,
        executionStartedAt: timestamp,
      ),
    ],
  );
}

class _ThrowingInitSessionStorage extends SessionStorage {
  @override
  Future<void> init() async {
    throw StateError('session storage unavailable');
  }
}

class _ScriptedContextSummaryService extends ContextSummaryService {
  final FutureOr<ContextSummary> Function(ContextSummaryRequest request)
      onGenerate;
  final ContextSummary Function(ContextSummaryRequest request)? onExtractive;

  _ScriptedContextSummaryService({
    required this.onGenerate,
    this.onExtractive,
  });

  @override
  Future<ContextSummary> generateSummary(
    ContextSummaryRequest request,
  ) async {
    return await onGenerate(request);
  }

  @override
  ContextSummary extractiveFallback(ContextSummaryRequest request) {
    final handler = onExtractive;
    if (handler != null) return handler(request);
    return super.extractiveFallback(request);
  }
}

ContextSummary _summaryForRequest(ContextSummaryRequest request) {
  return ContextSummary(
    version: ContextSummaryService.version,
    text: '## Goal\nTest summary',
    coveredMessageCount: request.coveredMessageCount,
    coveredDigest: request.coveredDigest,
    sourceEstimatedTokens: request.sourceEstimatedTokens,
    summaryEstimatedTokens: 20,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
    model: 'claude',
    apiFormat: 'anthropic',
  );
}

ContextSummary _summaryForRequestWithModel(ContextSummaryRequest request) {
  return ContextSummary(
    version: ContextSummaryService.version,
    text: '## Goal\nTest summary for ${request.llmConfig.model}',
    coveredMessageCount: request.coveredMessageCount,
    coveredDigest: request.coveredDigest,
    sourceEstimatedTokens: request.sourceEstimatedTokens,
    summaryEstimatedTokens: 20,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
    model: request.llmConfig.model,
    apiFormat: request.llmConfig.format.name,
  );
}

List<ChatMessage> _longContextMessages() {
  return List.generate(8, (index) {
    final text = 'history_$index ${'x' * 20000}';
    if (index.isEven) return ChatMessage.user(text);
    return ChatMessage(
      role: 'assistant',
      content: [TextContent(text)],
    );
  });
}

caps.ResolvedModelProfile _resolvedProfileWithCapabilities(
  caps.ModelCapabilities capabilities,
) {
  return caps.ResolvedModelProfile(
    modelId: 'claude-sonnet-4-20250514',
    providerKey: 'anthropic|127.0.0.1',
    provider: const caps.ProviderCapabilities(
      apiFormat: caps.ApiFormat.anthropic,
      kind: caps.ProviderKind.anthropicNative,
      systemPromptMode: caps.SystemPromptMode.topLevel,
      defaultTokenLimitParameter: caps.TokenLimitParameter.maxTokens,
      streamingUsageMode: caps.StreamingUsageMode.nativeEvents,
    ),
    capabilities: capabilities,
  );
}

VerifiedSkillUse _providerVerifiedSkill({List<String> tools = const []}) {
  return VerifiedSkillUse(
    id: 'com.example.recovery',
    name: 'Recovery skill',
    path: '/root/workspace/skills/com.example.recovery/SKILL.md',
    skillContent: 'verified recovery skill',
    capabilities: ExtensionCapabilitySnapshot(
      tools: tools,
      commands: const [],
      networkDomains: const [],
      filesystemRead: const [],
      filesystemWrite: const [],
      androidIntents: const [],
      androidPermissions: const [],
      secretNames: const [],
      runtimes: const [],
      subprocessRequired: false,
      riskTier: 'low',
      updatePolicy: 'manual',
    ),
    manifestDigest: List.filled(64, 'a').join(),
    contentDigest: List.filled(64, 'b').join(),
    trustDigest: List.filled(64, 'c').join(),
    legacy: false,
  );
}

ChatSession _skillBoundRecoverySession({
  required String id,
  required VerifiedSkillUse activation,
}) {
  final timestamp = DateTime.utc(2026, 7, 7);
  return ChatSession(
    id: id,
    messages: [
      ChatMessage.user('original skill task'),
      ChatMessage(
        role: 'assistant',
        content: [
          ToolUseContent(
            id: 'skill_activation_call',
            name: 'load_skill',
            input: {'id': activation.id},
          ),
        ],
      ),
      ChatMessage(
        role: 'user',
        content: [
          ToolResultContent(
            toolUseId: 'skill_activation_call',
            output: 'skill activated',
            metadata: {
              'skillId': activation.id,
              'skillTrustDigest': activation.trustDigest,
              'skillRunAttemptId': 'skill-origin-run',
            },
          ),
        ],
      ),
    ],
    inFlightAgentRun: AgentRunRecoveryMarker(
      runAttemptId: 'skill-origin-run',
      startedAt: timestamp,
      updatedAt: timestamp,
    ),
  );
}

ChatSession _resultPersistedRecoverySession({
  required String id,
  required DateTime timestamp,
}) {
  return ChatSession(
    id: id,
    messages: [
      ChatMessage.user('original task'),
      ChatMessage(
        role: 'assistant',
        content: [
          ToolUseContent(
            id: 'old_completed_call',
            name: 'echo',
            input: const {'text': 'already completed'},
          ),
        ],
      ),
      ChatMessage(
        role: 'user',
        content: [
          ToolResultContent(
            toolUseId: 'old_completed_call',
            output: 'saved result',
            metadata: const {'operationId': 'old_completed_operation'},
          ),
        ],
      ),
    ],
    inFlightAgentRun: AgentRunRecoveryMarker(
      runAttemptId: 'result-persisted-origin',
      startedAt: timestamp,
      updatedAt: timestamp,
      toolAttempts: [
        ToolAttemptRecoveryMetadata(
          operationId: 'old_completed_operation',
          toolName: 'echo',
          risk: RecoveryToolRisk.dangerous,
          lifecycle: ToolAttemptLifecycle.resultPersisted,
          proposedAt: timestamp,
          updatedAt: timestamp,
          executionStartedAt: timestamp,
          executionOutcomeKnown: true,
        ),
      ],
    ),
  );
}

class _EchoTool extends Tool {
  int executionCount = 0;

  @override
  String get name => 'echo';

  @override
  String get description => 'Echo text';

  @override
  Map<String, dynamic> get inputSchema => const {
        'type': 'object',
        'properties': {
          'text': {'type': 'string'},
        },
      };

  @override
  Future<String> execute(Map<String, dynamic> input) async {
    executionCount++;
    return input['text']?.toString() ?? '';
  }
}

class _BlockingDangerousTool extends Tool {
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();
  int executionCount = 0;

  @override
  String get name => 'slow_dangerous';

  @override
  String get description => 'Slow non-cancellable tool';

  @override
  Map<String, dynamic> get inputSchema => const {
        'type': 'object',
        'properties': {
          'value': {'type': 'string'},
        },
      };

  @override
  Future<String> execute(Map<String, dynamic> input) async {
    throw UnimplementedError();
  }

  @override
  Future<ToolResultPayload> executeResultWithOperationAndCancellation(
    Map<String, dynamic> input, {
    String? sessionId,
    required String operationId,
    required ToolCancellationSignal cancellationSignal,
  }) async {
    executionCount++;
    if (!started.isCompleted) started.complete();
    await release.future;
    return const ToolResultPayload(forUser: 'late result');
  }
}

class _CancellableDangerousTool extends Tool {
  final Completer<void> started = Completer<void>();
  final Completer<void> confirmAbort = Completer<void>();
  final Completer<void> abortReported = Completer<void>();

  @override
  String get name => 'cancellable_http';

  @override
  String get description => 'Cancellable HTTP-like tool';

  @override
  Map<String, dynamic> get inputSchema => const {
        'type': 'object',
        'properties': {
          'value': {'type': 'string'},
        },
      };

  @override
  Future<String> execute(Map<String, dynamic> input) async {
    throw UnimplementedError();
  }

  @override
  Future<ToolResultPayload> executeResultWithOperationAndCancellation(
    Map<String, dynamic> input, {
    String? sessionId,
    required String operationId,
    required ToolCancellationSignal cancellationSignal,
  }) async {
    if (!started.isCompleted) started.complete();
    await cancellationSignal.whenCancelled;
    await confirmAbort.future;
    if (!abortReported.isCompleted) abortReported.complete();
    throw const ToolExecutionCancelledException(sideEffectsPrevented: true);
  }
}

class _LargeSchemaTool extends Tool {
  @override
  String get name => 'large_schema';

  @override
  String get description => 'Large schema used to exercise tool budgeting';

  @override
  Map<String, dynamic> get inputSchema => {
        'type': 'object',
        'properties': {
          'text': {
            'type': 'string',
            'description': 'x' * 30000,
          },
        },
      };

  @override
  Future<String> execute(Map<String, dynamic> input) async {
    return input['text']?.toString() ?? '';
  }
}

class _DualTrackTool extends Tool {
  @override
  String get name => 'dual_track';

  @override
  String get description => 'Returns distinct user and LLM tracks';

  @override
  Map<String, dynamic> get inputSchema => const {
        'type': 'object',
        'properties': {
          'text': {'type': 'string'},
        },
      };

  @override
  Future<String> execute(Map<String, dynamic> input) async {
    throw UnimplementedError('executeResult is used by AgentService');
  }

  @override
  Future<ToolResultPayload> executeResult(
    Map<String, dynamic> input, {
    String? sessionId,
  }) async {
    return const ToolResultPayload(
      forUser: 'FULL USER OUTPUT with detailed logs',
      forLlm: 'compact for llm',
      summary: 'dual track summary',
      metadata: {
        'toolName': 'dual_track',
        'originalChars': 35,
        'llmChars': 15,
        'truncated': false,
        'status': 'success',
      },
    );
  }
}
