import 'dart:convert';
import 'dart:io';

import 'package:clawchat/constants.dart';
import 'package:clawchat/services/memory_service.dart';
import 'package:clawchat/services/memory_trust_store.dart';
import 'package:clawchat/services/preferences_service.dart';
import 'package:clawchat/services/tools/untrusted_data_policy.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(AppConstants.channelName);
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late Map<String, String> files;
  late Map<String, String> secureStore;

  setUp(() async {
    files = {};
    secureStore = {};
    MemoryService.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
      final key = args['key']?.toString();
      switch (call.method) {
        case 'read':
          return key == null ? null : secureStore[key];
        case 'write':
          if (key != null) secureStore[key] = args['value']?.toString() ?? '';
          return null;
        case 'delete':
          if (key != null) secureStore.remove(key);
          return null;
        case 'containsKey':
          return key != null && secureStore.containsKey(key);
        case 'readAll':
          return Map<String, String>.from(secureStore);
      }
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
      switch (call.method) {
        case 'readRootfsFile':
          return files[args['path']?.toString()];
        case 'writeRootfsFile':
          files[args['path']?.toString() ?? ''] =
              args['content']?.toString() ?? '';
          return true;
        case 'deleteRootfsFile':
          return files.remove(args['path']?.toString() ?? '') != null;
        case 'getFilesDir':
          return Directory.systemTemp.path;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
    MemoryService.resetForTesting();
    PreferencesService.resetForTesting();
  });

  Future<void> seedFacts({required bool globalEnabled}) async {
    MemoryService.resetForTesting();
    SharedPreferences.setMockInitialValues({'memory_enabled': globalEnabled});
    PreferencesService.resetForTesting();
    await PreferencesService().init();
    MemoryService.setTrustStoreForTesting(
      _FakeTrustStore(jsonEncode({
        'trusted pref'.toLowerCase(): SecureMemoryTrustStore.userTrustValue,
        'evil.example'.toLowerCase(): 'web',
      })),
    );
    files['root/.clawchat_memory.json'] =
        jsonEncode(['trusted pref', 'evil.example']);
  }

  MemoryTrustStore seedTrustStore() => _FakeTrustStore(jsonEncode({
        'trusted pref'.toLowerCase(): SecureMemoryTrustStore.userTrustValue,
        'evil.example'.toLowerCase(): 'web',
      }));

  /// Simulates a process restart: same encrypted store and rootfs bytes, fresh
  /// in-memory service state.
  Future<void> restartService({required bool globalEnabled}) async {
    MemoryService.resetForTesting();
    PreferencesService.resetForTesting();
    await PreferencesService().init();
    MemoryService.setTrustStoreForTesting(seedTrustStore());
  }

  test('listFacts shows provenance without weakening trust rules', () async {
    await seedFacts(globalEnabled: true);

    final facts = await MemoryService.listFacts();
    expect(facts, hasLength(2));
    expect(facts.first.text, 'trusted pref');
    expect(facts.first.trusted, isTrue);
    expect(facts.last.text, 'evil.example');
    expect(facts.last.trusted, isFalse);
    expect(facts.last.source, UntrustedSource.web);
    expect(facts.last.trustLabel, contains('web'));

    // The existing untrusted map still reports the same provenance.
    final untrusted = await MemoryService.getUntrustedMemories();
    expect(untrusted['evil.example'], UntrustedSource.web);
  });

  test('the response preview follows the global switch', () async {
    await seedFacts(globalEnabled: false);
    expect(await MemoryService.promptFactsForSession('session-1'), isEmpty);

    await seedFacts(globalEnabled: true);
    final used = await MemoryService.promptFactsForSession('session-1');
    expect(used.map((line) => line.text), ['trusted pref', 'evil.example']);
    expect(used.last.trusted, isFalse);
  });

  test('the run snapshot is recorded and never rewritten afterwards', () async {
    await seedFacts(globalEnabled: true);

    await MemoryService.buildMemoryPrompt(sessionId: 'session-1');
    var used = MemoryService.memoryUsedInLastRun('session-1');
    expect(used.map((line) => line.text), ['trusted pref', 'evil.example']);
    expect(used.first.trusted, isTrue);
    expect(used.last.trusted, isFalse);
    expect(used.last.source, UntrustedSource.web);
    // Another session has its own snapshot.
    expect(MemoryService.memoryUsedInLastRun('session-2'), isEmpty);

    // Changing the switches and forgetting the fact afterwards must not
    // rewrite what that response used.
    await MemoryService.setSessionEnabled('session-1', false);
    await MemoryService.forgetFact('evil.example');
    used = MemoryService.memoryUsedInLastRun('session-1');
    expect(used.map((line) => line.text), ['trusted pref', 'evil.example']);

    // The next prompt build replaces the snapshot with the new truth.
    await MemoryService.buildMemoryPrompt(sessionId: 'session-1');
    expect(MemoryService.memoryUsedInLastRun('session-1'), isEmpty);
  });

  test('the session override wins without touching the global switch',
      () async {
    await seedFacts(globalEnabled: true);

    await MemoryService.setSessionEnabled('session-1', false);
    var state = await MemoryService.sessionToggleState('session-1');
    expect(state.globalEnabled, isTrue);
    expect(state.effectiveEnabled, isFalse);
    expect(state.isOverride, isTrue);
    expect(await MemoryService.promptFactsForSession('session-1'), isEmpty);
    // Another session keeps the global default.
    expect(
      await MemoryService.promptFactsForSession('session-2'),
      hasLength(2),
    );

    await MemoryService.setSessionEnabled('session-1', true);
    state = await MemoryService.sessionToggleState('session-1');
    // Setting the same value as the global switch clears the override.
    expect(state.mode, SessionMemoryMode.followGlobal);
    expect(state.isOverride, isFalse);
    expect(state.effectiveEnabled, isTrue);
  });

  test('a session can enable memory while the global switch stays off',
      () async {
    await seedFacts(globalEnabled: false);

    await MemoryService.setSessionEnabled('session-1', true);
    final state = await MemoryService.sessionToggleState('session-1');
    expect(state.globalEnabled, isFalse);
    expect(state.mode, SessionMemoryMode.enabled);
    expect(state.effectiveEnabled, isTrue);
    expect(
      await MemoryService.promptFactsForSession('session-1'),
      hasLength(2),
    );
  });

  test('forgetFact removes one fact and keeps the other untrusted', () async {
    await seedFacts(globalEnabled: true);

    expect(await MemoryService.forgetFact('evil.example'), isTrue);
    final facts = await MemoryService.listFacts();
    expect(facts.map((fact) => fact.text), ['trusted pref']);

    // The remaining fact keeps its stored provenance.
    final untrusted = await MemoryService.getUntrustedMemories();
    expect(untrusted, isEmpty);
    expect(
      await MemoryService.forgetFact('evil.example'),
      isFalse,
    );
  });

  test('forgetting an untrusted fact does not promote other facts', () async {
    await seedFacts(globalEnabled: true);
    await MemoryService.addMemory('fresh note', source: 'settings');

    expect(await MemoryService.forgetFact('evil.example'), isTrue);
    final untrusted = await MemoryService.getUntrustedMemories();
    // The trusted fact stays trusted, and the newly added user fact is not
    // retroactively affected by the delete.
    expect(untrusted.containsKey('fresh note'), isFalse);
  });

  test('a non-Map or bad-schema trust store fails closed', () async {
    const payloads = [
      '[]',
      '"user"',
      '{"trusted pref": 42}',
      '{"trusted pref": null}',
      '{"trusted pref": "root"}',
      '{"trusted pref": {"user": true}}',
      '{"trusted pref": ["user"]}',
      '{"": "user"}',
    ];
    for (final payload in payloads) {
      await seedFacts(globalEnabled: true);
      final store = _FakeTrustStore(payload);
      MemoryService.setTrustStoreForTesting(store);

      // A broken trust store never promotes a stored fact to trusted.
      final facts = await MemoryService.listFacts();
      expect(facts, hasLength(2), reason: payload);
      expect(facts.every((fact) => !fact.trusted), isTrue, reason: payload);
      final untrusted = await MemoryService.getUntrustedMemories();
      expect(
        untrusted.keys.toSet(),
        {'trusted pref', 'evil.example'},
        reason: payload,
      );

      // The prompt keeps the untrusted heading and never lists a user fact.
      final prompt = await MemoryService.buildMemoryPrompt(
        sessionId: 'session-1',
      );
      expect(prompt, contains('Untrusted memories'), reason: payload);
      expect(prompt, isNot(contains('User memories')), reason: payload);

      // Nothing is repaired behind the user's back.
      expect(store.content, payload, reason: payload);
    }
  });

  test('session overrides live in encrypted storage and survive a restart',
      () async {
    await seedFacts(globalEnabled: true);
    await MemoryService.setSessionEnabled('session-1', false);

    // Stored in the encrypted app-private store, never in the guest rootfs.
    expect(
      secureStore.containsKey(SecureMemorySessionModeStore.storageKey),
      isTrue,
    );
    expect(
      files.containsKey(SecureMemorySessionModeStore.legacyRootfsPath),
      isFalse,
    );
    expect(await MemoryService.promptFactsForSession('session-1'), isEmpty);

    // A restart keeps the override; a session without one keeps the global
    // default.
    await restartService(globalEnabled: true);
    final state = await MemoryService.sessionToggleState('session-1');
    expect(state.mode, SessionMemoryMode.disabled);
    expect(state.effectiveEnabled, isFalse);
    expect(await MemoryService.promptFactsForSession('session-1'), isEmpty);
    expect(
      await MemoryService.promptFactsForSession('session-2'),
      hasLength(2),
    );
  });

  test('a guest-written legacy override file is inert and retired', () async {
    await seedFacts(globalEnabled: true);
    // The agent shell can write this file; it must not enable or disable
    // anything.
    files[SecureMemorySessionModeStore.legacyRootfsPath] =
        jsonEncode({'session-1': 'enabled', 'session-2': 'enabled'});

    final state = await MemoryService.sessionToggleState('session-1');
    expect(state.mode, SessionMemoryMode.disabled);
    expect(state.effectiveEnabled, isFalse);
    expect(await MemoryService.promptFactsForSession('session-1'), isEmpty);
    // The file is retired so a later launch reads the encrypted store only.
    expect(
      files.containsKey(SecureMemorySessionModeStore.legacyRootfsPath),
      isFalse,
    );
    // The global switch itself is unaffected.
    expect(MemoryService.isEnabledForSessionSync(null), isTrue);
  });

  test('a corrupted override store prefers disabled and recovers on write',
      () async {
    await seedFacts(globalEnabled: true);
    // A valid schema with a wrong checksum is a corrupt store, not an empty
    // one.
    secureStore[SecureMemorySessionModeStore.storageKey] = jsonEncode({
      'schemaVersion': 1,
      'entries': {'session-1': 'disabled'},
      'checksum': '0' * 64,
    });
    await restartService(globalEnabled: true);

    final corrupted = await MemoryService.sessionToggleState('session-1');
    expect(corrupted.mode, SessionMemoryMode.disabled);
    expect(corrupted.effectiveEnabled, isFalse);
    expect(await MemoryService.promptFactsForSession('session-1'), isEmpty);
    expect(MemoryService.isEnabledForSessionSync('session-1'), isFalse);

    // The user can set the switch again, which rewrites a well-formed store.
    await MemoryService.setSessionEnabled('session-2', true);
    final recovered = await MemoryService.sessionToggleState('session-2');
    expect(recovered.effectiveEnabled, isTrue);
    expect(
        await MemoryService.promptFactsForSession('session-2'), hasLength(2));
  });

  test('the session override store validates its checksum and schema',
      () async {
    final storage = _FakeProtectedStorage();
    final store = SecureMemorySessionModeStore(storage: storage);
    await store.write(jsonEncode({
      'session-2': 'enabled',
      'session-1': 'disabled',
    }));

    // Reading returns the canonical entries in a stable order.
    expect(
        await store.read(), '{"session-1":"disabled","session-2":"enabled"}');

    final envelope =
        jsonDecode(storage.values[SecureMemorySessionModeStore.storageKey]!)
            as Map<String, dynamic>;
    expect(envelope['schemaVersion'], 1);

    // An edited entry with the old checksum fails closed.
    final tampered = Map<String, dynamic>.from(envelope);
    tampered['entries'] = {'session-1': 'enabled'};
    storage.values[SecureMemorySessionModeStore.storageKey] =
        jsonEncode(tampered);
    await expectLater(store.read(), throwsA(isA<FormatException>()));

    // An unknown mode name never becomes an override.
    storage.values[SecureMemorySessionModeStore.storageKey] = jsonEncode({
      'schemaVersion': 1,
      'entries': {'a': 'maybe'},
      'checksum': 'x'
    });
    await expectLater(store.read(), throwsA(isA<FormatException>()));
    await expectLater(store.write(jsonEncode({'a': 'maybe'})),
        throwsA(isA<FormatException>()));
  });
  test('a failed session-mode write restores the previous override', () async {
    MemoryService.resetForTesting();
    SharedPreferences.setMockInitialValues({'memory_enabled': false});
    PreferencesService.resetForTesting();
    await PreferencesService().init();

    final store = _FlakySessionModeStore();
    MemoryService.setSessionModeStoreForTesting(store);

    await MemoryService.setSessionMemoryMode(
      'session-1',
      SessionMemoryMode.enabled,
    );
    expect(MemoryService.isEnabledForSessionSync('session-1'), isTrue);

    // The next write fails; the override must be rolled back and the error
    // still reach the caller.
    store.failWrites = true;
    await expectLater(
      MemoryService.setSessionMemoryMode(
        'session-1',
        SessionMemoryMode.disabled,
      ),
      throwsA(isA<StateError>()),
    );

    expect(MemoryService.isEnabledForSessionSync('session-1'), isTrue);
    expect(
      await MemoryService.getSessionMemoryMode('session-1'),
      SessionMemoryMode.enabled,
    );
  });
}

final class _FlakySessionModeStore implements MemorySessionModeStore {
  bool failWrites = false;
  String? stored;

  @override
  Future<String?> read() async => stored;

  @override
  Future<void> write(String content) async {
    if (failWrites) throw StateError('storage unavailable');
    stored = content;
  }

  @override
  Future<void> deleteLegacy() async {}
}

final class _FakeProtectedStorage implements MemoryTrustProtectedStorage {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

final class _FakeTrustStore implements MemoryTrustStore {
  _FakeTrustStore(this._content);

  String? _content;

  String? get content => _content;

  @override
  Future<String?> read() async => _content;

  @override
  Future<void> write(String content) async {
    _content = content;
  }

  @override
  Future<void> deleteLegacy() async {}
}
