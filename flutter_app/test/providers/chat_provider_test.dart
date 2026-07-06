import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clawchat/constants.dart';
import 'package:clawchat/models/chat_models.dart';
import 'package:clawchat/models/model_capabilities.dart' as caps;
import 'package:clawchat/models/provider_profile.dart';
import 'package:clawchat/providers/chat_provider.dart';
import 'package:clawchat/services/chat_context_utils.dart';
import 'package:clawchat/services/config_export_service.dart';
import 'package:clawchat/services/context_summary_service.dart';
import 'package:clawchat/services/startup_restore_guard.dart';
import 'package:clawchat/services/llm_service.dart';
import 'package:clawchat/services/preferences_service.dart';
import 'package:clawchat/services/provider_message_transform.dart';
import 'package:clawchat/services/runtime_debug_events.dart';
import 'package:clawchat/services/session_storage.dart';
import 'package:clawchat/services/token_calibration_service.dart';
import 'package:clawchat/services/tools/tool_policy.dart';
import 'package:clawchat/services/tools/tool_registry.dart';
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
    });
  }

  void configureModelFallbackProfiles({
    List<ProviderProfile>? fallbackProfiles,
    List<ModelFallbackTarget>? targets,
    int primaryThinkingBudget = 0,
    int contextTokenBudget = 65536,
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

  group('tool approval hardening', () {
    setUp(() async {
      await installPlatformMocks();
      configureAnthropicProfile(baseUrl: 'http://127.0.0.1');
    });

    tearDown(() async {
      await clearPlatformMocks();
    });

    test('background current session denies dangerous tool approval', () async {
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
      provider.setAppInBackground(true);
      await provider.sendMessage('use tool');

      expect(requestCount, 2);
      final toolResult =
          provider.currentSession!.messages.expand((m) => m.toolResults).single;
      expect(toolResult.output, contains('denied'));
      expect(toolResult.output, isNot(contains('secret-free')));
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
      provider.resolveToolApproval(true);
      await sendFuture;

      expect(requestCount, 2);
      final toolResult =
          provider.currentSession!.messages.expand((m) => m.toolResults).single;
      expect(toolResult.output, 'approved');
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

      provider.cancelAgent(sessionId: session.id);

      await llmDisposed.future.timeout(const Duration(seconds: 1));
      expect(provider.isSessionSending(session.id), isFalse);
      await sendFuture;
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

      provider.cancelAgent(sessionId: session.id, savePartial: false);
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
      final events = RuntimeDebugEventService();
      events.record(RuntimeDebugEvent(
        type: 'provider.debug',
        sessionId: 's1',
        data: {
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
      final attemptedModels = <String>[];
      final provider = ChatProvider(
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

      await provider.createSession();
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

    test('stream failure rolls back primary patch and blocks fallback',
        () async {
      configureModelFallbackProfiles(contextTokenBudget: 4096);
      final summaryModels = <String>[];
      final attemptedModels = <String>[];
      var fallbackCreated = false;
      final provider = ChatProvider(
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

      expect(provider.errorMessage, isNotNull);
      expect(attemptedModels, ['claude-primary-200k']);
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
        hasLength(assistantCountBefore + 1),
      );
      final errorMarker = provider.currentSession!.messages.last;
      expect(errorMarker.hasAssistantError, isTrue);
      expect(errorMarker.assistantError!.fallbackReasonCode,
          'unsafe_after_partial_run');
      expect(errorMarker.assistantError!.canRetry, isTrue);
      expect(
        provider.currentSession!.messages
            .map((message) => message.textContent)
            .join('\n'),
        isNot(contains('partial streamed text')),
      );
      expect(
        provider.runtimeDebugEvents.recent().any((event) =>
            event.type == 'model.fallback.skipped' &&
            event.data['reason'] == 'unsafe_after_partial_run'),
        isTrue,
      );
    });

    test('cancel before persisted messages rolls back primary patch', () async {
      configureModelFallbackProfiles(contextTokenBudget: 4096);
      final started = Completer<void>();
      final release = Completer<void>();
      final summaryModels = <String>[];
      var fallbackCreated = false;
      final provider = ChatProvider(
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

      provider.cancelAgent();
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
    });

    test('successful primary keeps context patch', () async {
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

      provider.cancelAgent();
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
      expect(
        transformEvent.data['firstWarning'],
        contains('image content replaced'),
      );
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
      expect(event.data.toString(), contains('bearer_token'));
      expect(
        event.data.toString(),
        isNot(contains('abcdefghijklmnopqrstuvwxyz')),
      );
    });

    test('does not generate summary when messages fit token budget', () async {
      SharedPreferences.setMockInitialValues({
        'active_provider_profile_id': 'profile',
        'context_token_budget': 32768,
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
      });
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
      expect(calibrationEvent.data['keyHash'], isA<String>());
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
      expect(event.data['repairTypes'], {'json_closure': 1});
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

class _EchoTool extends Tool {
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
    return input['text']?.toString() ?? '';
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
  Future<ToolResultPayload> executeResult(Map<String, dynamic> input) async {
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
