import 'dart:async';
import 'dart:io';

import 'package:clawchat/constants.dart';
import 'package:clawchat/models/chat_models.dart';
import 'package:clawchat/models/remote_agent_connector.dart';
import 'package:clawchat/models/agent_run_center.dart';
import 'package:clawchat/providers/chat_provider.dart';
import 'package:clawchat/services/preferences_service.dart';
import 'package:clawchat/services/remote_agent_configuration_service.dart';
import 'package:clawchat/services/remote_agent_connector.dart';
import 'package:clawchat/services/session_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  const secureChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const nativeChannel = MethodChannel(AppConstants.channelName);
  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PreferencesService.resetForTesting();
    tempDir = await Directory.systemTemp.createTemp('remote_provider_test_');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathChannel, (_) async => tempDir.path);
    messenger.setMockMethodCallHandler(secureChannel, (call) async {
      if (call.method == 'readAll') return <String, String>{};
      if (call.method == 'containsKey') return false;
      return null;
    });
    messenger.setMockMethodCallHandler(nativeChannel, (call) async {
      if (call.method == 'consumePendingNavigateToSession') return null;
      if (call.method == 'runInProot') return '';
      return true;
    });
  });

  tearDown(() async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathChannel, null);
    messenger.setMockMethodCallHandler(secureChannel, null);
    messenger.setMockMethodCallHandler(nativeChannel, null);
    PreferencesService.resetForTesting();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('per-session opt-in maps local history and commits terminal only',
      () async {
    final fixture = await _fixture();
    addTearDown(fixture.provider.dispose);
    final local = await fixture.provider.createSession();
    expect(local.remoteAgentConnectorId, isNull);
    expect(
        fixture.provider.currentExecutionContextLabel, startsWith('Local ·'));
    expect(await fixture.provider.setCurrentSessionRemoteAgentEnabled(true),
        isTrue);
    expect(fixture.provider.currentExecutionContextLabel,
        'External · Remote Agent');

    await fixture.provider.sendMessage('first local turn');

    expect(fixture.connector.requests, hasLength(1));
    expect(fixture.connector.requests.single.localSessionId, local.id);
    expect(
      fixture.connector.requests.single.messages
          .map((message) => '${message.role}:${message.text}'),
      ['user:first local turn'],
    );
    expect(
        local.messages.map((message) => message.role), ['user', 'assistant']);
    expect(local.messages.last.textContent, 'terminal reply');
    expect(fixture.provider.activeRemoteCancellationCount, 0);

    final second = await fixture.provider.createSession();
    expect(second.remoteAgentConnectorId, isNull);
    expect(fixture.provider.currentSessionUsesRemoteAgent, isFalse);
  });

  test('failure persists sanitized retry state without partial response',
      () async {
    final fixture = await _fixture(mode: _ConnectorMode.failure);
    addTearDown(fixture.provider.dispose);
    final session = await fixture.provider.createSession();
    await fixture.provider.setCurrentSessionRemoteAgentEnabled(true);

    await fixture.provider.sendMessage('request that fails');

    expect(session.messages, hasLength(2));
    expect(session.messages.first.role, 'user');
    expect(session.messages.last.hasAssistantError, isTrue);
    expect(session.messages.last.textContent, isEmpty);
    expect(session.messages.last.assistantError!.code,
        'remote_agent_transportFailure');
    expect(session.messages.last.assistantError!.canRetry, isTrue);

    fixture.connector.mode = _ConnectorMode.complete;
    expect(
      await fixture.provider.retryAssistantMessage(1),
      AssistantRetryStatus.started,
    );
    expect(
        session.messages.map((message) => message.role), ['user', 'assistant']);
    expect(session.messages.last.textContent, 'terminal reply');
    expect(fixture.connector.cancellations, hasLength(2));
    expect(
      identical(
        fixture.connector.cancellations.first,
        fixture.connector.cancellations.last,
      ),
      isFalse,
    );
    expect(fixture.provider.activeRemoteCancellationCount, 0);
  });

  test('authorization failures offer local recovery and are not retryable',
      () async {
    final fixture = await _fixture();
    addTearDown(fixture.provider.dispose);
    final session = await fixture.provider.createSession();
    await fixture.provider.setCurrentSessionRemoteAgentEnabled(true);
    await fixture.configuration.revokeConsent();

    await fixture.provider.sendMessage('authorization changed');

    expect(fixture.connector.requests, isEmpty);
    expect(session.messages.last.assistantError!.code,
        'remote_agent_consentRequired');
    expect(session.messages.last.assistantError!.canRetry, isFalse);
    expect(
      await fixture.provider.setCurrentSessionRemoteAgentEnabled(false),
      isTrue,
    );
    expect(
        fixture.provider.currentExecutionContextLabel, startsWith('Local ·'));
    expect(fixture.provider.activeRemoteCancellationCount, 0);
  });

  test('detach during configuration init stops connector before start',
      () async {
    final stores = await _configuredStores();
    final metadata = _BlockingMetadataStorage(stores.metadata)..arm();
    final configuration = RemoteAgentConfigurationService(
      metadataStorage: metadata,
      secretStorage: stores.secrets,
    );
    final fixture = await _fixtureForConfiguration(configuration);
    addTearDown(fixture.provider.dispose);
    addTearDown(() {
      if (!metadata.release.isCompleted) metadata.release.complete();
    });
    final session = await fixture.provider.createSession();
    await _selectRemoteSession(fixture, session);

    final send = fixture.provider.sendMessage('blocked init');
    await metadata.entered.future;
    expect(fixture.provider.activeRemoteCancellationCount, 1);
    await fixture.runtime.detach(reason: 'recovery required');
    await send.timeout(const Duration(seconds: 1));

    expect(fixture.connector.requests, isEmpty);
    expect(fixture.provider.activeRemoteCancellationCount, 0);
    expect(fixture.provider.agentStatus, isNot(AgentStatus.thinking));
    metadata.release.complete();
    await Future<void>.delayed(Duration.zero);
    expect(fixture.connector.requests, isEmpty);
  });

  test('detach during secure read stops connector before start', () async {
    final stores = await _configuredStores();
    final secrets = _BlockingSecretStorage(stores.secrets);
    final configuration = RemoteAgentConfigurationService(
      metadataStorage: stores.metadata,
      secretStorage: secrets,
    );
    await configuration.init();
    secrets.arm();
    final fixture = await _fixtureForConfiguration(configuration);
    addTearDown(fixture.provider.dispose);
    addTearDown(() {
      if (!secrets.release.isCompleted) secrets.release.complete();
    });
    final session = await fixture.provider.createSession();
    await _selectRemoteSession(fixture, session);

    final send = fixture.provider.sendMessage('blocked secret read');
    await secrets.entered.future;
    expect(fixture.provider.activeRemoteCancellationCount, 1);
    await fixture.runtime.detach(reason: 'recovery required');
    await send.timeout(const Duration(seconds: 1));

    expect(fixture.connector.requests, isEmpty);
    expect(fixture.provider.activeRemoteCancellationCount, 0);
    expect(fixture.provider.agentStatus, isNot(AgentStatus.thinking));
    secrets.release.completeError(StateError('late secure read failure'));
    await Future<void>.delayed(Duration.zero);
    expect(fixture.connector.requests, isEmpty);
  });

  test('ordinary cancel settles only its hung secure-read session', () async {
    final stores = await _configuredStores();
    final secrets = _BlockingSecretStorage(stores.secrets);
    final configuration = RemoteAgentConfigurationService(
      metadataStorage: stores.metadata,
      secretStorage: secrets,
    );
    await configuration.init();
    secrets.arm();
    final fixture = await _fixtureForConfiguration(configuration);
    addTearDown(fixture.provider.dispose);
    addTearDown(() {
      if (!secrets.release.isCompleted) secrets.release.complete();
    });
    final hung = await fixture.provider.createSession();
    await _selectRemoteSession(fixture, hung);
    final other = await fixture.provider.createSession();
    fixture.provider.saveDraft(other.id, 'preserved local draft');

    final send = fixture.provider.sendMessage(
      'cancel hung preflight',
      targetSessionId: hung.id,
    );
    await secrets.entered.future;
    await fixture.provider.cancelAgent(sessionId: hung.id);
    await send.timeout(const Duration(seconds: 1));

    expect(fixture.provider.activeRemoteCancellationCount, 0);
    expect(fixture.provider.isSessionSending(hung.id), isFalse);
    expect(fixture.provider.currentSession?.id, other.id);
    expect(fixture.provider.getDraft(other.id), 'preserved local draft');
    expect(fixture.connector.requests, isEmpty);
    secrets.release.complete();
    await Future<void>.delayed(Duration.zero);
    expect(fixture.connector.requests, isEmpty);
  });

  test('detach settles two hung sessions and queued work can drain', () async {
    final stores = await _configuredStores();
    final secrets = _BlockingSecretStorage(stores.secrets);
    final configuration = RemoteAgentConfigurationService(
      metadataStorage: stores.metadata,
      secretStorage: secrets,
    );
    await configuration.init();
    secrets.arm();
    final fixture = await _fixtureForConfiguration(configuration);
    addTearDown(fixture.provider.dispose);
    addTearDown(() {
      if (!secrets.release.isCompleted) secrets.release.complete();
    });
    final first = await fixture.provider.createSession();
    await _selectRemoteSession(fixture, first);
    final second = await fixture.provider.createSession();
    await _selectRemoteSession(fixture, second);

    final firstSend = fixture.provider.sendMessage(
      'first hung preflight',
      targetSessionId: first.id,
    );
    final secondSend = fixture.provider.sendMessage(
      'second hung preflight',
      targetSessionId: second.id,
    );
    await secrets.entered.future;
    await _waitUntil(() => fixture.provider.activeRemoteCancellationCount == 2);
    await fixture.provider.sendMessage(
      'queued after hung preflight',
      targetSessionId: first.id,
    );
    await fixture.runtime.detach(reason: 'recovery required');
    await Future.wait([firstSend, secondSend])
        .timeout(const Duration(seconds: 1));

    expect(fixture.provider.activeRemoteCancellationCount, 0);
    expect(fixture.provider.isSessionSending(first.id), isFalse);
    expect(fixture.provider.isSessionSending(second.id), isFalse);
    final newStores = await _configuredStores();
    final newConfiguration = RemoteAgentConfigurationService(
      metadataStorage: newStores.metadata,
      secretStorage: newStores.secrets,
    );
    await newConfiguration.init();
    final newConnector = _FakeConnector(_ConnectorMode.complete);
    await fixture.runtime.attach(newConfiguration, newConnector);
    await _waitUntil(() => newConnector.requests.length == 1);
    expect(
      fixture.provider.agentRunCenterItems.every(
        (item) => item.sessionId != first.id || item.queuedCount == 0,
      ),
      isTrue,
    );
    expect(fixture.connector.requests, isEmpty);
    expect(newConnector.requests, hasLength(1));
    secrets.release.complete();
  });

  test('detach after authorization but before send stops connector start',
      () async {
    final blocker = _AsyncBlocker()..arm();
    final fixture = await _fixture(
      beforeRemoteConnectorSendForTesting: blocker.call,
    );
    addTearDown(fixture.provider.dispose);
    await fixture.provider.createSession();
    await fixture.provider.setCurrentSessionRemoteAgentEnabled(true);

    final send = fixture.provider.sendMessage('blocked connector preflight');
    await blocker.entered.future;
    await fixture.runtime.detach(reason: 'recovery required');
    blocker.release.complete();
    await send;

    expect(fixture.connector.requests, isEmpty);
    expect(fixture.provider.activeRemoteCancellationCount, 0);
  });

  test('cancellation allocates operation token and commits no assistant',
      () async {
    final fixture = await _fixture(mode: _ConnectorMode.waitForCancellation);
    addTearDown(fixture.provider.dispose);
    final session = await fixture.provider.createSession();
    await fixture.provider.setCurrentSessionRemoteAgentEnabled(true);

    final send = fixture.provider.sendMessage('cancel this request');
    await _waitUntil(
        () => fixture.provider.agentStatus == AgentStatus.thinking);
    await fixture.provider.cancelAgent(savePartial: true);
    await send;

    expect(fixture.connector.cancellations, hasLength(1));
    expect(fixture.connector.cancellations.single.isCancelled, isTrue);
    expect(session.messages, hasLength(1));
    expect(session.messages.single.role, 'user');
    expect(fixture.provider.agentStatus, AgentStatus.idle);
    expect(fixture.provider.activeRemoteCancellationCount, 0);
  });

  test('config mutations during durable user save never reach connector',
      () async {
    for (final mutation in ['edit', 'replace', 'remove', 'disable']) {
      final blocker = _CommitBlocker();
      final fixture = await _fixture(
        storage: SessionStorage(beforeCommitForTesting: blocker.call),
      );
      addTearDown(fixture.provider.dispose);
      final session = await fixture.provider.createSession();
      await fixture.provider.setCurrentSessionRemoteAgentEnabled(true);
      blocker.arm();

      final send = fixture.provider.sendMessage('pre-send mutation');
      await blocker.entered.future;
      switch (mutation) {
        case 'edit':
          await fixture.configuration.saveConfiguration(
            kind: RemoteAgentConnectorKind.cozeOpenApi,
            connectorId: 'primary_remote',
            displayName: 'Remote Agent',
            baseUrl: 'https://edited.example/v3/chat',
            remoteAgentId: 'agent_2',
          );
        case 'replace':
          await fixture.configuration.saveConfiguration(
            kind: RemoteAgentConnectorKind.cozeOpenApi,
            connectorId: 'primary_remote',
            displayName: 'Remote Agent',
            baseUrl: 'https://edited.example/v3/chat',
            remoteAgentId: 'agent_2',
            credential: 'replacement-secret',
          );
        case 'remove':
          await fixture.configuration.removeCredential();
        case 'disable':
          await fixture.configuration.disable();
      }
      blocker.release.complete();
      await send;

      expect(fixture.connector.requests, isEmpty, reason: mutation);
      expect(session.messages.where((message) => message.role == 'assistant'),
          hasLength(1),
          reason: mutation);
      expect(session.messages.last.hasAssistantError, isTrue, reason: mutation);
      expect(fixture.provider.activeRemoteCancellationCount, 0,
          reason: mutation);
    }
  });

  test('revocation during stream aborts and persists no terminal assistant',
      () async {
    final fixture = await _fixture(mode: _ConnectorMode.waitForCancellation);
    addTearDown(fixture.provider.dispose);
    final session = await fixture.provider.createSession();
    await fixture.provider.setCurrentSessionRemoteAgentEnabled(true);

    final send = fixture.provider.sendMessage('stream revocation');
    await fixture.connector.started.future;
    await fixture.configuration.disable();
    await send;

    expect(fixture.connector.cancellations.single.isCancelled, isTrue);
    expect(session.messages.last.hasAssistantError, isTrue);
    expect(
        session.messages.where((message) =>
            message.role == 'assistant' && message.textContent.isNotEmpty),
        isEmpty);
    expect(fixture.provider.activeRemoteCancellationCount, 0);
  });

  test('revocation after terminal event prevents durable assistant commit',
      () async {
    final fixture = await _fixture(mode: _ConnectorMode.terminalThenWait);
    addTearDown(fixture.provider.dispose);
    final session = await fixture.provider.createSession();
    await fixture.provider.setCurrentSessionRemoteAgentEnabled(true);

    final send = fixture.provider.sendMessage('terminal revocation');
    await fixture.connector.terminalYielded.future;
    await fixture.configuration.revokeConsent();
    fixture.connector.terminalRelease.complete();
    await send;

    expect(session.messages.last.hasAssistantError, isTrue);
    expect(
        session.messages.where((message) =>
            message.role == 'assistant' && message.textContent.isNotEmpty),
        isEmpty);
    expect(fixture.provider.activeRemoteCancellationCount, 0);
  });

  test('two sessions use fresh tokens; local cancel stays request-local',
      () async {
    final fixture = await _fixture(mode: _ConnectorMode.waitForCancellation);
    addTearDown(fixture.provider.dispose);
    final first = await fixture.provider.createSession();
    await fixture.provider.setCurrentSessionRemoteAgentEnabled(true);
    final second = await fixture.provider.createSession();
    await fixture.provider.setCurrentSessionRemoteAgentEnabled(true);

    final firstSend = fixture.provider.sendMessage(
      'first concurrent request',
      targetSessionId: first.id,
    );
    final secondSend = fixture.provider.sendMessage(
      'second concurrent request',
      targetSessionId: second.id,
    );
    await _waitUntil(() => fixture.connector.cancellations.length == 2);
    expect(
        identical(fixture.connector.cancellations[0],
            fixture.connector.cancellations[1]),
        isFalse);
    final firstIndex = fixture.connector.requests
        .indexWhere((request) => request.localSessionId == first.id);
    final secondIndex = fixture.connector.requests
        .indexWhere((request) => request.localSessionId == second.id);

    await fixture.provider.cancelAgent(sessionId: first.id);
    expect(fixture.connector.cancellations[firstIndex].isCancelled, isTrue);
    expect(fixture.connector.cancellations[secondIndex].isCancelled, isFalse);
    await fixture.runtime.detach(reason: 'recovery required');
    await Future.wait([firstSend, secondSend]);

    final persistedFirst = await fixture.storage.getSession(first.id);
    expect(persistedFirst!.messages, hasLength(1));
    expect(second.messages.last.hasAssistantError, isTrue);
    expect(
        fixture.connector.cancellations,
        everyElement(
          predicate<RemoteAgentCancellation>((token) => token.isCancelled),
        ));
    expect(fixture.provider.activeRemoteCancellationCount, 0);
  });

  test('reattach uses a new generation and stale operation stays cancelled',
      () async {
    final blocker = _AsyncBlocker()..arm();
    final fixture = await _fixture(
      beforeRemoteConnectorSendForTesting: blocker.call,
    );
    addTearDown(fixture.provider.dispose);
    final session = await fixture.provider.createSession();
    await fixture.provider.setCurrentSessionRemoteAgentEnabled(true);

    final oldSend = fixture.provider.sendMessage('old generation');
    await blocker.entered.future;
    await fixture.runtime.detach(reason: 'recovery required');

    final newStores = await _configuredStores();
    final newConfiguration = RemoteAgentConfigurationService(
      metadataStorage: newStores.metadata,
      secretStorage: newStores.secrets,
    );
    await newConfiguration.init();
    final newConnector = _FakeConnector(_ConnectorMode.complete);
    await fixture.runtime.attach(newConfiguration, newConnector);
    blocker.release.complete();
    await oldSend;

    expect(fixture.connector.requests, isEmpty);
    expect(newConnector.requests, isEmpty);
    await fixture.provider.sendMessage('new generation');
    expect(newConnector.requests, hasLength(1));
    expect(session.messages.last.textContent, 'terminal reply');
    expect(fixture.provider.activeRemoteCancellationCount, 0);
  });

  test('reattach starts fresh send while old secure read stays unresolved',
      () async {
    final oldStores = await _configuredStores();
    final oldSecrets = _BlockingSecretStorage(oldStores.secrets);
    final oldConfiguration = RemoteAgentConfigurationService(
      metadataStorage: oldStores.metadata,
      secretStorage: oldSecrets,
    );
    await oldConfiguration.init();
    oldSecrets.arm();
    final fixture = await _fixtureForConfiguration(oldConfiguration);
    addTearDown(fixture.provider.dispose);
    addTearDown(() {
      if (!oldSecrets.release.isCompleted) oldSecrets.release.complete();
    });
    final session = await fixture.provider.createSession();
    await _selectRemoteSession(fixture, session);

    final oldSend = fixture.provider.sendMessage('old blocked generation');
    await oldSecrets.entered.future;
    await fixture.runtime.detach(reason: 'recovery required');
    await oldSend.timeout(const Duration(seconds: 1));

    final newStores = await _configuredStores();
    final newConfiguration = RemoteAgentConfigurationService(
      metadataStorage: newStores.metadata,
      secretStorage: newStores.secrets,
    );
    await newConfiguration.init();
    final newConnector = _FakeConnector(_ConnectorMode.complete);
    await fixture.runtime.attach(newConfiguration, newConnector);
    await fixture.provider.sendMessage('fresh generation');

    expect(fixture.connector.requests, isEmpty);
    expect(newConnector.requests, hasLength(1));
    expect(session.messages.last.textContent, 'terminal reply');
    expect(fixture.provider.activeRemoteCancellationCount, 0);
    oldSecrets.release.complete();
    await Future<void>.delayed(Duration.zero);
    expect(fixture.connector.requests, isEmpty);
  });

  test('provider dispose settles hung preflight without listener leak',
      () async {
    final stores = await _configuredStores();
    final secrets = _BlockingSecretStorage(stores.secrets);
    final configuration = RemoteAgentConfigurationService(
      metadataStorage: stores.metadata,
      secretStorage: secrets,
    );
    await configuration.init();
    secrets.arm();
    final fixture = await _fixtureForConfiguration(configuration);
    addTearDown(fixture.runtime.dispose);
    addTearDown(() {
      if (!secrets.release.isCompleted) secrets.release.complete();
    });
    final session = await fixture.provider.createSession();
    await _selectRemoteSession(fixture, session);

    final send = fixture.provider.sendMessage('dispose hung preflight');
    await secrets.entered.future;
    fixture.provider.dispose();
    await send.timeout(const Duration(seconds: 1));

    expect(fixture.provider.activeRemoteCancellationCount, 0);
    expect(fixture.connector.requests, isEmpty);
    secrets.release.completeError(StateError('late error after dispose'));
    await Future<void>.delayed(Duration.zero);
    expect(fixture.connector.requests, isEmpty);
  });

  test('run center keeps background remote context after switching local',
      () async {
    final fixture = await _fixture(mode: _ConnectorMode.waitForCancellation);
    addTearDown(fixture.provider.dispose);
    final remote = await fixture.provider.createSession();
    await fixture.provider.setCurrentSessionRemoteAgentEnabled(true);
    final local = await fixture.provider.createSession();

    final send = fixture.provider.sendMessage(
      'background remote',
      targetSessionId: remote.id,
    );
    await fixture.connector.started.future.timeout(const Duration(seconds: 2));
    expect(fixture.provider.currentSession!.id, local.id);
    final item = fixture.provider.agentRunCenterItems.singleWhere(
      (candidate) => candidate.sessionId == remote.id,
    );
    expect(item.context, AgentRunCenterContext.external);
    expect(item.safeExecutionDisplayName, 'Remote Agent');

    await fixture.configuration.disable();
    await send;
    final historical = fixture.provider.agentRunCenterItems.singleWhere(
      (candidate) => candidate.sessionId == remote.id,
    );
    expect(historical.context, AgentRunCenterContext.external);
    expect(historical.safeExecutionDisplayName, 'Remote Agent');
  });

  test('run center labels background local from its own session metadata',
      () async {
    final fixture = await _fixture();
    addTearDown(fixture.provider.dispose);
    final local = await fixture.provider.createSession();
    local.modelOverride = 'local-safe-model';
    await fixture.storage.saveSession(local);
    final remote = await fixture.provider.createSession();
    await fixture.provider.setCurrentSessionRemoteAgentEnabled(true);

    await fixture.provider
        .sendMessage('local failure', targetSessionId: local.id);

    expect(fixture.provider.currentSession!.id, remote.id);
    final item = fixture.provider.agentRunCenterItems.singleWhere(
      (candidate) => candidate.sessionId == local.id,
    );
    expect(item.context, AgentRunCenterContext.local);
    expect(item.safeExecutionDisplayName, 'local-safe-model');
    await fixture.provider.deleteSession(local.id);
    expect(
      fixture.provider.agentRunCenterItems
          .where((candidate) => candidate.sessionId == local.id),
      isEmpty,
    );
  });

  test('revocation before guarded rename rejects durable assistant snapshot',
      () async {
    final blocker = _NthCommitBlocker();
    final fixture = await _fixture(
      storage: SessionStorage(beforeCommitForTesting: blocker.call),
    );
    addTearDown(fixture.provider.dispose);
    final session = await fixture.provider.createSession();
    await fixture.provider.setCurrentSessionRemoteAgentEnabled(true);
    blocker.armAfter(1);

    final send = fixture.provider.sendMessage('guarded commit revocation');
    await blocker.entered.future;
    final beforeRelease = await fixture.storage.getSession(session.id);
    expect(beforeRelease!.messages, hasLength(1));
    await fixture.configuration.disable();
    blocker.release.complete();
    await send;

    final persisted = await fixture.storage.getSession(session.id);
    expect(persisted!.messages.last.hasAssistantError, isTrue);
    expect(
      persisted.messages.where((message) =>
          message.role == 'assistant' && message.textContent.isNotEmpty),
      isEmpty,
    );
  });

  test('commit permit linearizes before concurrent revocation returns',
      () async {
    final blocker = _CommitBlocker()..arm();
    final fixture = await _fixture(
      storage: SessionStorage(afterCommitPermitForTesting: blocker.call),
    );
    addTearDown(fixture.provider.dispose);
    final session = await fixture.provider.createSession();
    await fixture.provider.setCurrentSessionRemoteAgentEnabled(true);

    final send = fixture.provider.sendMessage('commit wins linearization');
    await blocker.entered.future;
    var revocationReturned = false;
    final revoke = fixture.configuration.disable().then((_) {
      revocationReturned = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(revocationReturned, isFalse);
    blocker.release.complete();
    await Future.wait([send, revoke]);

    final persisted = await fixture.storage.getSession(session.id);
    expect(persisted!.messages.last.textContent, 'terminal reply');
    expect(revocationReturned, isTrue);
  });

  test('runtime detach waits when terminal commit owns linearization',
      () async {
    final blocker = _CommitBlocker()..arm();
    final fixture = await _fixture(
      storage: SessionStorage(afterCommitPermitForTesting: blocker.call),
    );
    addTearDown(fixture.provider.dispose);
    final session = await fixture.provider.createSession();
    await fixture.provider.setCurrentSessionRemoteAgentEnabled(true);

    final send = fixture.provider.sendMessage('runtime commit wins');
    await blocker.entered.future;
    var detachReturned = false;
    final detach = fixture.runtime
        .detach(reason: 'recovery required')
        .then((_) => detachReturned = true);
    await Future<void>.delayed(Duration.zero);
    expect(detachReturned, isFalse);
    blocker.release.complete();
    await Future.wait([send, detach]);

    final persisted = await fixture.storage.getSession(session.id);
    expect(persisted!.messages.last.textContent, 'terminal reply');
    expect(detachReturned, isTrue);
    expect(fixture.provider.activeRemoteCancellationCount, 0);
  });

  test('guarded terminal save failure removes assistant and stores retry state',
      () async {
    var failed = false;
    final fixture = await _fixture(
      storage: SessionStorage(afterCommitPermitForTesting: (_) async {
        if (!failed) {
          failed = true;
          throw StateError('injected guarded save failure');
        }
      }),
    );
    addTearDown(fixture.provider.dispose);
    final session = await fixture.provider.createSession();
    await fixture.provider.setCurrentSessionRemoteAgentEnabled(true);

    await fixture.provider.sendMessage('guarded save failure');

    final persisted = await fixture.storage.getSession(session.id);
    expect(persisted!.messages.last.hasAssistantError, isTrue);
    expect(
      persisted.messages.where((message) =>
          message.role == 'assistant' && message.textContent.isNotEmpty),
      isEmpty,
    );
  });

  test('session tombstone defeats guarded assistant rename', () async {
    final blocker = _CommitBlocker()..arm();
    final fixture = await _fixture(
      storage: SessionStorage(afterCommitPermitForTesting: blocker.call),
    );
    addTearDown(fixture.provider.dispose);
    final session = await fixture.provider.createSession();
    await fixture.provider.setCurrentSessionRemoteAgentEnabled(true);
    final send = fixture.provider.sendMessage('delete during guarded save');
    await blocker.entered.future;
    final deletion = fixture.provider.deleteSession(session.id);
    await Future<void>.delayed(Duration.zero);
    blocker.release.complete();
    await Future.wait([send, deletion]);

    expect(await fixture.storage.getSession(session.id), isNull);
  });

  test('runtime detach cancels remote work without replacing provider',
      () async {
    final fixture = await _fixture(mode: _ConnectorMode.waitForCancellation);
    addTearDown(fixture.provider.dispose);
    final provider = fixture.provider;
    final session = await provider.createSession();
    provider.saveDraft(session.id, 'local draft');
    await provider.setCurrentSessionRemoteAgentEnabled(true);

    final send = provider.sendMessage('remote turn');
    await fixture.connector.started.future;
    await fixture.runtime.detach(reason: 'remote recovery required');
    await send;

    expect(identical(provider, fixture.provider), isTrue);
    expect(provider.remoteAgentAvailable, isFalse);
    expect(provider.remoteAgentUnavailableReason, 'remote recovery required');
    expect(provider.currentSession?.id, session.id);
    expect(provider.getDraft(session.id), 'local draft');
    expect(fixture.connector.cancellations.single.isCancelled, isTrue);
    expect(
      provider.currentSession!.messages.where(
        (message) =>
            message.role == 'assistant' && message.textContent.isNotEmpty,
      ),
      isEmpty,
    );
    expect(provider.activeRemoteCancellationCount, 0);
  });
}

Future<_Fixture> _fixture({
  _ConnectorMode mode = _ConnectorMode.complete,
  SessionStorage? storage,
  RemoteConnectorPreflight? beforeRemoteConnectorSendForTesting,
}) async {
  final metadata = _MemoryStorage();
  final secrets = _MemoryStorage();
  final configuration = RemoteAgentConfigurationService(
    metadataStorage: metadata,
    secretStorage: secrets,
  );
  await configuration.saveConfiguration(
    kind: RemoteAgentConnectorKind.cozeOpenApi,
    connectorId: 'primary_remote',
    displayName: 'Remote Agent',
    baseUrl: 'https://agent.example/v3/chat',
    remoteAgentId: 'agent_1',
    credential: 'secure-value',
  );
  await configuration.grantConsentAndEnable(
    acceptedAt: DateTime.utc(2026, 7, 11),
  );
  final sessionStorage = storage ?? SessionStorage();
  await sessionStorage.init();
  final connector = _FakeConnector(mode);
  final runtime = RemoteAgentRuntimeBinding(
    configuration: configuration,
    connector: connector,
  );
  final provider = ChatProvider(
    storage: sessionStorage,
    remoteAgentRuntimeBinding: runtime,
    beforeRemoteConnectorSendForTesting: beforeRemoteConnectorSendForTesting,
  );
  await Future<void>.delayed(const Duration(milliseconds: 100));
  return _Fixture(
    provider,
    connector,
    configuration,
    sessionStorage,
    runtime,
  );
}

Future<
    ({
      _MemoryStorage metadata,
      _MemoryStorage secrets,
    })> _configuredStores() async {
  final metadata = _MemoryStorage();
  final secrets = _MemoryStorage();
  final configuration = RemoteAgentConfigurationService(
    metadataStorage: metadata,
    secretStorage: secrets,
  );
  await configuration.saveConfiguration(
    kind: RemoteAgentConnectorKind.cozeOpenApi,
    connectorId: 'primary_remote',
    displayName: 'Remote Agent',
    baseUrl: 'https://agent.example/v3/chat',
    remoteAgentId: 'agent_1',
    credential: 'secure-value',
  );
  await configuration.grantConsentAndEnable(
    acceptedAt: DateTime.utc(2026, 7, 11),
  );
  return (metadata: metadata, secrets: secrets);
}

Future<_Fixture> _fixtureForConfiguration(
  RemoteAgentConfigurationService configuration,
) async {
  final sessionStorage = SessionStorage();
  await sessionStorage.init();
  final connector = _FakeConnector(_ConnectorMode.complete);
  final runtime = RemoteAgentRuntimeBinding(
    configuration: configuration,
    connector: connector,
  );
  final provider = ChatProvider(
    storage: sessionStorage,
    remoteAgentRuntimeBinding: runtime,
  );
  await Future<void>.delayed(const Duration(milliseconds: 100));
  return _Fixture(
    provider,
    connector,
    configuration,
    sessionStorage,
    runtime,
  );
}

Future<void> _selectRemoteSession(_Fixture fixture, ChatSession session) async {
  session.remoteAgentConnectorId = 'primary_remote';
  await fixture.storage.saveSession(session);
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

enum _ConnectorMode {
  complete,
  failure,
  waitForCancellation,
  terminalThenWait,
}

final class _FakeConnector implements RemoteAgentConnector {
  _FakeConnector(this.mode);
  _ConnectorMode mode;
  final List<RemoteAgentRequest> requests = [];
  final List<RemoteAgentCancellation> cancellations = [];
  final Completer<void> started = Completer<void>();
  final Completer<void> terminalYielded = Completer<void>();
  final Completer<void> terminalRelease = Completer<void>();

  @override
  Stream<RemoteAgentEvent> send(
    RemoteAgentConnectorConfig config,
    RemoteAgentConsent? consent,
    RemoteAgentRequest request, {
    RemoteAgentCancellation? cancellation,
    bool Function()? authorizationGuard,
  }) async* {
    if (authorizationGuard?.call() == false) {
      throw const RemoteAgentFailure(
        RemoteAgentErrorCode.consentRequired,
        retryable: true,
      );
    }
    requests.add(request);
    cancellations.add(cancellation!);
    if (!started.isCompleted) started.complete();
    switch (mode) {
      case _ConnectorMode.complete:
        yield const RemoteAgentComplete(text: 'terminal reply');
      case _ConnectorMode.failure:
        throw const RemoteAgentFailure(
          RemoteAgentErrorCode.transportFailure,
          retryable: true,
        );
      case _ConnectorMode.waitForCancellation:
        await cancellation.whenCancelled;
        throw const RemoteAgentFailure(RemoteAgentErrorCode.cancelled);
      case _ConnectorMode.terminalThenWait:
        yield const RemoteAgentComplete(text: 'terminal reply');
        if (!terminalYielded.isCompleted) terminalYielded.complete();
        await terminalRelease.future;
    }
  }
}

final class _MemoryStorage
    implements RemoteAgentMetadataStorage, RemoteAgentSecretStorage {
  final Map<String, String> values = {};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

final class _BlockingMetadataStorage implements RemoteAgentMetadataStorage {
  _BlockingMetadataStorage(this.delegate);

  final RemoteAgentMetadataStorage delegate;
  final Completer<void> entered = Completer<void>();
  final Completer<void> release = Completer<void>();
  bool _armed = false;

  void arm() => _armed = true;

  @override
  Future<void> delete(String key) => delegate.delete(key);

  @override
  Future<String?> read(String key) async {
    if (_armed) {
      _armed = false;
      entered.complete();
      await release.future;
    }
    return delegate.read(key);
  }

  @override
  Future<void> write(String key, String value) => delegate.write(key, value);
}

final class _BlockingSecretStorage implements RemoteAgentSecretStorage {
  _BlockingSecretStorage(this.delegate);

  final RemoteAgentSecretStorage delegate;
  final Completer<void> entered = Completer<void>();
  final Completer<void> release = Completer<void>();
  bool _armed = false;

  void arm() => _armed = true;

  @override
  Future<void> delete(String key) => delegate.delete(key);

  @override
  Future<String?> read(String key) async {
    if (_armed) {
      _armed = false;
      entered.complete();
      await release.future;
    }
    return delegate.read(key);
  }

  @override
  Future<void> write(String key, String value) => delegate.write(key, value);
}

final class _Fixture {
  const _Fixture(
    this.provider,
    this.connector,
    this.configuration,
    this.storage,
    this.runtime,
  );
  final ChatProvider provider;
  final _FakeConnector connector;
  final RemoteAgentConfigurationService configuration;
  final SessionStorage storage;
  final RemoteAgentRuntimeBinding runtime;
}

final class _CommitBlocker {
  final Completer<void> entered = Completer<void>();
  final Completer<void> release = Completer<void>();
  bool _armed = false;

  void arm() => _armed = true;

  Future<void> call(String _) async {
    if (!_armed) return;
    _armed = false;
    entered.complete();
    await release.future;
  }
}

final class _NthCommitBlocker {
  final Completer<void> entered = Completer<void>();
  final Completer<void> release = Completer<void>();
  int _remaining = -1;

  void armAfter(int commitsToSkip) => _remaining = commitsToSkip;

  Future<void> call(String _) async {
    if (_remaining < 0) return;
    if (_remaining > 0) {
      _remaining -= 1;
      return;
    }
    _remaining = -1;
    entered.complete();
    await release.future;
  }
}

final class _AsyncBlocker {
  final Completer<void> entered = Completer<void>();
  final Completer<void> release = Completer<void>();
  bool _armed = false;

  void arm() => _armed = true;

  Future<void> call() async {
    if (!_armed) return;
    _armed = false;
    entered.complete();
    await release.future;
  }
}
