import 'dart:convert';
import 'dart:async';

import 'package:clawchat/models/remote_agent_connector.dart';
import 'package:clawchat/services/remote_agent_configuration_service.dart';
import 'package:clawchat/services/remote_agent_connector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('legacy Coze metadata is disabled until OpenClaw is reconfigured',
      () async {
    final metadata = _MemoryMetadataStorage();
    final secrets = _MemorySecretStorage();
    final reference = RemoteAgentCredentialReference.parse(
      'cred_0123456789abcdefghijklmnopqrstuv',
    );
    final legacy = RemoteAgentConnectorConfig(
      kind: RemoteAgentConnectorKind.cozeOpenApi,
      id: 'primary_remote',
      displayName: 'Remote Agent',
      baseUrl: 'https://legacy.example/v3/chat',
      credentialReference: reference,
      remoteAgentId: 'legacy_agent',
      enabled: true,
    );
    metadata.values['remote_agent_connector_config_v1'] =
        jsonEncode(legacy.toJson());
    metadata.values['remote_agent_connector_consent_v1'] = jsonEncode(
      RemoteAgentConsent.grant(
        legacy,
        acceptedAt: DateTime.utc(2026, 7, 11),
      ).toJson(),
    );
    secrets.values['remote_agent_credential_${reference.value}'] =
        'legacy-secret';

    final service = RemoteAgentConfigurationService(
      metadataStorage: metadata,
      secretStorage: secrets,
    );
    await service.init();

    expect(service.config!.kind, RemoteAgentConnectorKind.cozeOpenApi);
    expect(service.config!.enabled, isFalse);
    expect(service.consent, isNull);
    expect(service.isReady, isFalse);
    expect(
      metadata.values,
      isNot(contains('remote_agent_connector_consent_v1')),
    );
    expect(secrets.values.values, contains('legacy-secret'));
  });

  test('issues opaque reference and stores raw credential only as a secret',
      () async {
    final metadata = _MemoryMetadataStorage();
    final secrets = _MemorySecretStorage();
    final service = RemoteAgentConfigurationService(
      metadataStorage: metadata,
      secretStorage: secrets,
    );

    const rawCredential = 'credential-only-for-secure-store';
    final reference = await service.saveConfiguration(
      kind: RemoteAgentConnectorKind.openClawGateway,
      connectorId: 'primary_remote',
      displayName: 'Remote Agent',
      baseUrl: 'https://agent.example/v1/chat/completions',
      remoteAgentId: 'agent_1',
      credential: rawCredential,
    );

    expect(reference.value, startsWith('cred_'));
    expect(reference.toString(), isNot(contains(reference.value)));
    expect(jsonEncode(metadata.values), isNot(contains(rawCredential)));
    expect(secrets.values.values, contains(rawCredential));
    expect(await service.resolve(reference), rawCredential);
    expect(service.isReady, isFalse);
  });

  test('consent is configuration-bound and edits revoke enablement', () async {
    final metadata = _MemoryMetadataStorage();
    final secrets = _MemorySecretStorage();
    final service = RemoteAgentConfigurationService(
      metadataStorage: metadata,
      secretStorage: secrets,
    );
    await service.saveConfiguration(
      kind: RemoteAgentConnectorKind.openClawGateway,
      connectorId: 'primary_remote',
      displayName: 'Remote Agent',
      baseUrl: 'https://agent.example/v1/chat/completions',
      remoteAgentId: 'agent_1',
      credential: 'first-secret',
    );
    await service.grantConsentAndEnable(
      acceptedAt: DateTime.utc(2026, 7, 11),
    );

    expect(service.isReady, isTrue);
    expect(service.consent!.allows(service.config!), isTrue);

    await service.saveConfiguration(
      kind: RemoteAgentConnectorKind.openClawGateway,
      connectorId: 'primary_remote',
      displayName: 'Remote Agent',
      baseUrl: 'https://changed.example/v1/chat/completions',
      remoteAgentId: 'agent_1',
    );

    expect(service.config!.enabled, isFalse);
    expect(service.consent, isNull);
    expect(service.isReady, isFalse);
  });

  test('credential replacement deletes old secret and removal is complete',
      () async {
    final metadata = _MemoryMetadataStorage();
    final secrets = _MemorySecretStorage();
    final service = RemoteAgentConfigurationService(
      metadataStorage: metadata,
      secretStorage: secrets,
    );
    final first = await service.saveConfiguration(
      kind: RemoteAgentConnectorKind.openClawGateway,
      connectorId: 'primary_remote',
      displayName: 'Remote Agent',
      baseUrl: 'https://agent.example/v1/chat/completions',
      remoteAgentId: 'agent_1',
      credential: 'first-secret',
    );
    final second = await service.saveConfiguration(
      kind: RemoteAgentConnectorKind.openClawGateway,
      connectorId: 'primary_remote',
      displayName: 'Remote Agent',
      baseUrl: 'https://agent.example/v1/chat/completions',
      remoteAgentId: 'agent_1',
      credential: 'second-secret',
    );

    expect(await service.resolve(first), isNull);
    expect(await service.resolve(second), 'second-secret');
    await service.removeCredential();
    expect(service.config, isNull);
    expect(await service.resolve(second), isNull);
    for (final key in [
      'remote_agent_connector_config_v1',
      'remote_agent_connector_consent_v1',
      'remote_agent_connector_mutation_v1',
      'remote_agent_credential_retirements_v1',
    ]) {
      expect(metadata.values, isNot(contains(key)));
    }
  });

  test('all mutation phases recover without orphan or cross-binding', () async {
    for (final step in RemoteAgentMutationStep.values) {
      final metadata = _MemoryMetadataStorage();
      final secrets = _MemorySecretStorage();
      final initial = RemoteAgentConfigurationService(
        metadataStorage: metadata,
        secretStorage: secrets,
      );
      final oldReference = await initial.saveConfiguration(
        kind: RemoteAgentConnectorKind.openClawGateway,
        connectorId: 'primary_remote',
        displayName: 'Remote Agent',
        baseUrl: 'https://agent.example/v1/chat/completions',
        remoteAgentId: 'agent_1',
        credential: 'initial-secret',
      );
      await initial.grantConsentAndEnable(
        acceptedAt: DateTime.utc(2026, 7, 11),
      );
      var injected = false;
      final faulted = RemoteAgentConfigurationService(
        metadataStorage: metadata,
        secretStorage: secrets,
        faultInjector: (candidate) {
          if (!injected && candidate == step) {
            injected = true;
            throw StateError('injected mutation fault');
          }
        },
      );
      await faulted.init();
      await expectLater(
        faulted.saveConfiguration(
          kind: RemoteAgentConnectorKind.openClawGateway,
          connectorId: 'primary_remote',
          displayName: 'Remote Agent',
          baseUrl: 'https://changed.example/v1/chat/completions',
          remoteAgentId: 'agent_2',
          credential: 'replacement-secret',
        ),
        throwsStateError,
        reason: step.name,
      );

      final restarted = RemoteAgentConfigurationService(
        metadataStorage: metadata,
        secretStorage: secrets,
      );
      await restarted.init();
      expect(restarted.config, isNotNull, reason: step.name);
      expect(
        restarted.isReady,
        step == RemoteAgentMutationStep.journalPrepared ||
            step == RemoteAgentMutationStep.secretIssued,
        reason: step.name,
      );
      expect(metadata.values.toString(), isNot(contains('replacement-secret')),
          reason: step.name);
      expect(metadata.values,
          isNot(contains('remote_agent_connector_mutation_v1')),
          reason: step.name);
      if (step == RemoteAgentMutationStep.journalPrepared ||
          step == RemoteAgentMutationStep.secretIssued) {
        expect(restarted.config!.credentialReference, oldReference,
            reason: step.name);
        expect(secrets.values.values, contains('initial-secret'),
            reason: step.name);
      } else {
        expect(restarted.config!.remoteAgentId, 'agent_2', reason: step.name);
        expect(secrets.values.values, contains('replacement-secret'),
            reason: step.name);
        expect(await restarted.resolve(oldReference), isNull,
            reason: step.name);
      }
    }
  });

  test(
      'consent persistence failure publishes durable config and restart finishes',
      () async {
    final backing = _MemoryMetadataStorage();
    final metadata = _FaultingMetadataStorage(backing);
    final secrets = _MemorySecretStorage();
    final service = RemoteAgentConfigurationService(
      metadataStorage: metadata,
      secretStorage: secrets,
    );
    await service.saveConfiguration(
      kind: RemoteAgentConnectorKind.openClawGateway,
      connectorId: 'primary_remote',
      displayName: 'Remote Agent',
      baseUrl: 'https://agent.example/v1/chat/completions',
      remoteAgentId: 'agent_1',
      credential: 'initial-secret',
    );
    await service.grantConsentAndEnable(
      acceptedAt: DateTime.utc(2026, 7, 11),
    );
    metadata.failNextDeleteOf = 'remote_agent_connector_consent_v1';

    await expectLater(
      service.saveConfiguration(
        kind: RemoteAgentConnectorKind.openClawGateway,
        connectorId: 'primary_remote',
        displayName: 'Remote Agent',
        baseUrl: 'https://changed.example/v1/chat/completions',
        remoteAgentId: 'agent_2',
        credential: 'replacement-secret',
      ),
      throwsStateError,
    );

    expect(service.config!.remoteAgentId, 'agent_2');
    expect(service.isReady, isFalse);
    final restarted = RemoteAgentConfigurationService(
      metadataStorage: backing,
      secretStorage: secrets,
    );
    await restarted.init();
    expect(restarted.config!.remoteAgentId, 'agent_2');
    expect(restarted.consent, isNull);
    expect(
        backing.values, isNot(contains('remote_agent_connector_mutation_v1')));
  });

  test('consent grant resumes from every post-metadata interruption', () async {
    for (final step in [
      RemoteAgentMutationStep.metadataCommitted,
      RemoteAgentMutationStep.consentCommitted,
      RemoteAgentMutationStep.memoryPublished,
    ]) {
      final metadata = _MemoryMetadataStorage();
      final secrets = _MemorySecretStorage();
      final initial = RemoteAgentConfigurationService(
        metadataStorage: metadata,
        secretStorage: secrets,
      );
      await initial.saveConfiguration(
        kind: RemoteAgentConnectorKind.openClawGateway,
        connectorId: 'primary_remote',
        displayName: 'Remote Agent',
        baseUrl: 'https://agent.example/v1/chat/completions',
        remoteAgentId: 'agent_1',
        credential: 'initial-secret',
      );
      var injected = false;
      final faulted = RemoteAgentConfigurationService(
        metadataStorage: metadata,
        secretStorage: secrets,
        faultInjector: (candidate) {
          if (!injected && candidate == step) {
            injected = true;
            throw StateError('injected consent fault');
          }
        },
      );
      await faulted.init();
      await expectLater(
        faulted.grantConsentAndEnable(
          acceptedAt: DateTime.utc(2026, 7, 11),
        ),
        throwsStateError,
        reason: step.name,
      );

      final restarted = RemoteAgentConfigurationService(
        metadataStorage: metadata,
        secretStorage: secrets,
      );
      await restarted.init();
      expect(restarted.isReady, isTrue, reason: step.name);
      expect(
        metadata.values,
        isNot(contains('remote_agent_connector_mutation_v1')),
        reason: step.name,
      );
    }
  });

  test('failed old-secret retirement leaves bounded evidence and retries',
      () async {
    final metadata = _MemoryMetadataStorage();
    final backingSecrets = _MemorySecretStorage();
    final secrets = _FaultingSecretStorage(backingSecrets);
    final service = RemoteAgentConfigurationService(
      metadataStorage: metadata,
      secretStorage: secrets,
    );
    final oldReference = await service.saveConfiguration(
      kind: RemoteAgentConnectorKind.openClawGateway,
      connectorId: 'primary_remote',
      displayName: 'Remote Agent',
      baseUrl: 'https://agent.example/v1/chat/completions',
      remoteAgentId: 'agent_1',
      credential: 'initial-secret',
    );
    secrets.failNextDelete = true;
    await service.saveConfiguration(
      kind: RemoteAgentConnectorKind.openClawGateway,
      connectorId: 'primary_remote',
      displayName: 'Remote Agent',
      baseUrl: 'https://changed.example/v1/chat/completions',
      remoteAgentId: 'agent_2',
      credential: 'replacement-secret',
    );

    expect(metadata.values, contains('remote_agent_credential_retirements_v1'));
    expect(await service.resolve(oldReference), 'initial-secret');
    final restarted = RemoteAgentConfigurationService(
      metadataStorage: metadata,
      secretStorage: backingSecrets,
    );
    await restarted.init();
    expect(await restarted.resolve(oldReference), isNull);
    expect(metadata.values,
        isNot(contains('remote_agent_credential_retirements_v1')));
  });

  test('concurrent mutation pairs serialize with monotonic ownership',
      () async {
    for (final scenario in ['save_save', 'save_remove', 'save_disable']) {
      final metadata = _MemoryMetadataStorage();
      final secrets = _MemorySecretStorage();
      final blocker = _MutationBlocker();
      final service = RemoteAgentConfigurationService(
        metadataStorage: metadata,
        secretStorage: secrets,
        faultInjector: blocker.call,
      );
      await service.saveConfiguration(
        kind: RemoteAgentConnectorKind.openClawGateway,
        connectorId: 'primary_remote',
        displayName: 'Remote Agent',
        baseUrl: 'https://agent.example/v1/chat/completions',
        remoteAgentId: 'agent_1',
        credential: 'initial-secret',
      );
      blocker.arm();
      final first = service.saveConfiguration(
        kind: RemoteAgentConnectorKind.openClawGateway,
        connectorId: 'primary_remote',
        displayName: 'Remote Agent',
        baseUrl: 'https://first.example/v1/chat/completions',
        remoteAgentId: 'agent_2',
        credential: 'first-replacement',
      );
      await blocker.entered.future;
      final Future<void> second;
      if (scenario == 'save_save') {
        second = service
            .saveConfiguration(
              kind: RemoteAgentConnectorKind.openClawGateway,
              connectorId: 'primary_remote',
              displayName: 'Remote Agent',
              baseUrl: 'https://second.example/v1/chat/completions',
              remoteAgentId: 'agent_3',
              credential: 'second-replacement',
            )
            .then((_) {});
      } else if (scenario == 'save_remove') {
        second = service.removeCredential();
      } else {
        second = service.disable();
      }
      blocker.release.complete();
      await first;
      await second;

      expect(service.generation, 3, reason: scenario);
      expect(metadata.values.toString(), isNot(contains('first-replacement')),
          reason: scenario);
      if (scenario == 'save_save') {
        expect(service.config!.remoteAgentId, 'agent_3');
        expect(secrets.values.values, contains('second-replacement'));
        expect(secrets.values.values, isNot(contains('first-replacement')));
      } else if (scenario == 'save_remove') {
        expect(service.config, isNull);
        expect(secrets.values, isEmpty);
      } else {
        expect(service.config!.remoteAgentId, 'agent_2');
        expect(service.config!.enabled, isFalse);
        expect(secrets.values.values, contains('first-replacement'));
      }
    }
  });

  test('revocation cancels every lease while ordinary cancel stays local',
      () async {
    final metadata = _MemoryMetadataStorage();
    final secrets = _MemorySecretStorage();
    final service = RemoteAgentConfigurationService(
      metadataStorage: metadata,
      secretStorage: secrets,
    );
    await service.saveConfiguration(
      kind: RemoteAgentConnectorKind.openClawGateway,
      connectorId: 'primary_remote',
      displayName: 'Remote Agent',
      baseUrl: 'https://agent.example/v1/chat/completions',
      remoteAgentId: 'agent_1',
      credential: 'initial-secret',
    );
    await service.grantConsentAndEnable(
      acceptedAt: DateTime.utc(2026, 7, 11),
    );
    final firstCancellation = RemoteAgentCancellation();
    final secondCancellation = RemoteAgentCancellation();
    final first = await service.claimAuthorization(
      'primary_remote',
      firstCancellation,
    );
    final second = await service.claimAuthorization(
      'primary_remote',
      secondCancellation,
    );

    firstCancellation.cancel();
    expect(first.isValid, isFalse);
    expect(second.isValid, isTrue);
    expect(secondCancellation.isCancelled, isFalse);

    await service.revokeConsent();
    expect(first.wasRevoked, isTrue);
    expect(second.wasRevoked, isTrue);
    expect(secondCancellation.isCancelled, isTrue);
    expect(service.isReady, isFalse);
  });

  test('full retirement queue preserves journal and later makes fair progress',
      () async {
    final metadata = _MemoryMetadataStorage();
    final backingSecrets = _MemorySecretStorage();
    final secrets = _FaultingSecretStorage(backingSecrets)..failDeletes = true;
    final service = RemoteAgentConfigurationService(
      metadataStorage: metadata,
      secretStorage: secrets,
    );
    await service.saveConfiguration(
      kind: RemoteAgentConnectorKind.openClawGateway,
      connectorId: 'primary_remote',
      displayName: 'Remote Agent',
      baseUrl: 'https://agent.example/v1/chat/completions',
      remoteAgentId: 'agent_0',
      credential: 'secret_0',
    );
    for (var index = 1; index <= 8; index += 1) {
      await service.saveConfiguration(
        kind: RemoteAgentConnectorKind.openClawGateway,
        connectorId: 'primary_remote',
        displayName: 'Remote Agent',
        baseUrl: 'https://agent.example/v1/chat/completions',
        remoteAgentId: 'agent_$index',
        credential: 'secret_$index',
      );
    }
    final queueBefore =
        metadata.values['remote_agent_credential_retirements_v1'];
    expect((jsonDecode(queueBefore!) as List), hasLength(8));

    await expectLater(
      service.saveConfiguration(
        kind: RemoteAgentConnectorKind.openClawGateway,
        connectorId: 'primary_remote',
        displayName: 'Remote Agent',
        baseUrl: 'https://agent.example/v1/chat/completions',
        remoteAgentId: 'agent_9',
        credential: 'secret_9',
      ),
      throwsStateError,
    );
    final reservedJournal =
        metadata.values['remote_agent_connector_mutation_v1'];
    expect(reservedJournal, isNotNull);
    expect(service.config!.remoteAgentId, 'agent_9');

    await expectLater(service.disable(), throwsStateError);
    expect(
        metadata.values['remote_agent_connector_mutation_v1'], reservedJournal);
    expect(service.config!.remoteAgentId, 'agent_9');

    final blockedRestart = RemoteAgentConfigurationService(
      metadataStorage: metadata,
      secretStorage: secrets,
    );
    await expectLater(blockedRestart.init(), throwsStateError);
    expect(
        metadata.values['remote_agent_connector_mutation_v1'], reservedJournal);

    secrets.failDeletes = false;
    await service.disable();
    expect(service.config!.enabled, isFalse);
    expect(
        metadata.values, isNot(contains('remote_agent_connector_mutation_v1')));
    expect(metadata.values,
        isNot(contains('remote_agent_credential_retirements_v1')));
    expect(backingSecrets.values, hasLength(1));

    final recovered = RemoteAgentConfigurationService(
      metadataStorage: metadata,
      secretStorage: secrets,
    );
    await recovered.init();
    expect(recovered.config!.remoteAgentId, 'agent_9');
    expect(recovered.config!.enabled, isFalse);
  });

  test('prepared journal rejects cross-state ownership before any deletion',
      () async {
    for (final mutation in ['new-routing', 'new-metadata', 'retired-routing']) {
      final fixture = await _faultedJournalFixture();
      const journalKey = 'remote_agent_connector_mutation_v1';
      const configKey = 'remote_agent_connector_config_v1';
      final journal = jsonDecode(fixture.metadata.values[journalKey]!)
          as Map<String, dynamic>;
      final durable = Map<String, dynamic>.from(mutation == 'retired-routing'
          ? journal['previous_config'] as Map
          : journal['next_config'] as Map);
      if (mutation == 'new-routing') {
        durable['remote_agent_id'] = 'cross_state_agent';
      } else if (mutation == 'new-metadata') {
        durable['display_name'] = 'Cross-state metadata';
      } else {
        durable['base_url'] = 'https://cross-state.example/v1/chat/completions';
      }
      fixture.metadata.values[configKey] = jsonEncode(durable);
      final secretsBefore = Map<String, String>.from(fixture.secrets.values);
      final journalBefore = fixture.metadata.values[journalKey];

      for (var restart = 0; restart < 2; restart += 1) {
        final service = RemoteAgentConfigurationService(
          metadataStorage: fixture.metadata,
          secretStorage: fixture.secrets,
        );
        await expectLater(service.init(), throwsFormatException,
            reason: '$mutation restart $restart');
        expect(fixture.secrets.values, secretsBefore,
            reason: '$mutation restart $restart');
        expect(fixture.metadata.values[journalKey], journalBefore,
            reason: '$mutation restart $restart');
      }
    }
  });

  test('exact previous prepared state deletes only the unowned new secret',
      () async {
    final metadata = _MemoryMetadataStorage();
    final secrets = _MemorySecretStorage();
    final initial = RemoteAgentConfigurationService(
      metadataStorage: metadata,
      secretStorage: secrets,
    );
    await initial.saveConfiguration(
      kind: RemoteAgentConnectorKind.openClawGateway,
      connectorId: 'primary_remote',
      displayName: 'Remote Agent',
      baseUrl: 'https://agent.example/v1/chat/completions',
      remoteAgentId: 'agent_1',
      credential: 'initial-secret',
    );
    final faulted = RemoteAgentConfigurationService(
      metadataStorage: metadata,
      secretStorage: secrets,
      faultInjector: (step) {
        if (step == RemoteAgentMutationStep.journalPrepared) {
          throw StateError('injected prepared fault');
        }
      },
    );
    await faulted.init();
    await expectLater(
      faulted.saveConfiguration(
        kind: RemoteAgentConnectorKind.openClawGateway,
        connectorId: 'primary_remote',
        displayName: 'Remote Agent',
        baseUrl: 'https://changed.example/v1/chat/completions',
        remoteAgentId: 'agent_2',
        credential: 'replacement-secret',
      ),
      throwsStateError,
    );
    const journalKey = 'remote_agent_connector_mutation_v1';
    final journal =
        jsonDecode(metadata.values[journalKey]!) as Map<String, dynamic>;
    final newReference = journal['new_reference'] as String;
    final previousReference =
        (journal['previous_config'] as Map)['credential_reference'] as String;
    secrets.values['remote_agent_credential_$newReference'] =
        'issued-before-restart';

    await RemoteAgentConfigurationService(
      metadataStorage: metadata,
      secretStorage: secrets,
    ).init();

    expect(
        secrets.values, contains('remote_agent_credential_$previousReference'));
    expect(secrets.values,
        isNot(contains('remote_agent_credential_$newReference')));
    expect(metadata.values, isNot(contains(journalKey)));
  });

  test('exact next prepared state resumes forward without cross-deletion',
      () async {
    final fixture = await _faultedJournalFixture();
    final journal = jsonDecode(
            fixture.metadata.values['remote_agent_connector_mutation_v1']!)
        as Map<String, dynamic>;
    final newReference = journal['new_reference'] as String;

    final recovered = RemoteAgentConfigurationService(
      metadataStorage: fixture.metadata,
      secretStorage: fixture.secrets,
    );
    await recovered.init();

    expect(recovered.config!.remoteAgentId, 'agent_2');
    expect(fixture.secrets.values,
        contains('remote_agent_credential_$newReference'));
    expect(fixture.metadata.values,
        isNot(contains('remote_agent_connector_mutation_v1')));
  });

  test('prepared journal requires exact consent for previous and next states',
      () async {
    for (final side in ['previous', 'next']) {
      final fixture = await _faultedJournalFixture();
      const journalKey = 'remote_agent_connector_mutation_v1';
      final journal = jsonDecode(fixture.metadata.values[journalKey]!)
          as Map<String, dynamic>;
      final config = RemoteAgentConnectorConfig.fromJson(
        Map<String, Object?>.from(journal['${side}_config'] as Map),
      );
      fixture.metadata.values['remote_agent_connector_config_v1'] =
          jsonEncode(config.toJson());
      fixture.metadata.values['remote_agent_connector_consent_v1'] = jsonEncode(
        RemoteAgentConsent.grant(
          config,
          acceptedAt: DateTime.utc(2026, 7, 11),
        ).toJson(),
      );
      final secretsBefore = Map<String, String>.from(fixture.secrets.values);

      await expectLater(
        RemoteAgentConfigurationService(
          metadataStorage: fixture.metadata,
          secretStorage: fixture.secrets,
        ).init(),
        throwsFormatException,
        reason: side,
      );
      expect(fixture.secrets.values, secretsBefore, reason: side);
      expect(fixture.metadata.values, contains(journalKey), reason: side);
    }
  });

  test('malformed stale and oversized journals fail closed without deletion',
      () async {
    for (final corruption in [
      'generation',
      'new_reference',
      'retire_reference',
      'missing_config',
      'extra_config',
      'phase',
      'phase_state',
      'oversized',
    ]) {
      final fixture = await _faultedJournalFixture();
      const key = 'remote_agent_connector_mutation_v1';
      final originalJournal =
          jsonDecode(fixture.metadata.values[key]!) as Map<String, dynamic>;
      final previousConfig =
          originalJournal['previous_config'] as Map<String, dynamic>;
      fixture.metadata.values['remote_agent_credential_retirements_v1'] =
          jsonEncode([previousConfig['credential_reference']]);
      if (corruption == 'oversized') {
        fixture.metadata.values[key] = 'x' * (17 * 1024);
      } else {
        final journal =
            jsonDecode(fixture.metadata.values[key]!) as Map<String, dynamic>;
        switch (corruption) {
          case 'generation':
            journal['generation'] = (journal['generation'] as int) + 1;
          case 'new_reference':
            journal['new_reference'] = 'cred_abcdefghijklmnopqrstuvwxyz012345';
          case 'retire_reference':
            journal['retire_reference'] =
                'cred_abcdefghijklmnopqrstuvwxyz012345';
          case 'missing_config':
            journal.remove('next_config');
          case 'extra_config':
            (journal['next_config'] as Map<String, dynamic>)['extra'] = true;
          case 'phase':
            journal['phase'] = 'unknown';
          case 'phase_state':
            journal['phase'] = 'metadataCommitted';
            fixture.metadata.values['remote_agent_connector_config_v1'] =
                jsonEncode(journal['previous_config']);
        }
        fixture.metadata.values[key] = jsonEncode(journal);
      }
      final secretsBefore = Map<String, String>.from(fixture.secrets.values);
      final restarted = RemoteAgentConfigurationService(
        metadataStorage: fixture.metadata,
        secretStorage: fixture.secrets,
      );

      await expectLater(restarted.init(), throwsFormatException,
          reason: corruption);
      expect(fixture.secrets.values, secretsBefore, reason: corruption);
      expect(fixture.metadata.values, contains(key), reason: corruption);
    }
  });

  group('explicit corrupt-evidence reset transaction', () {
    const keys = [
      'remote_agent_connector_config_v1',
      'remote_agent_connector_consent_v1',
      'remote_agent_connector_generation_v1',
      'remote_agent_connector_mutation_v1',
      'remote_agent_credential_retirements_v1',
    ];

    _RecoveryPreferences evidence() => _RecoveryPreferences({
          for (final key in keys) key: 'metadata',
        });

    for (final index in [0, 2, 4]) {
      test('remove false at position $index preserves backup and remainder',
          () async {
        final preferences = evidence()..failRemoveKey = keys[index];

        await expectLater(
          RemoteAgentConfigurationService.resetCorruptEvidence(preferences),
          throwsStateError,
        );

        expect(
          preferences.values['remote_agent_recovery_backup_v1'],
          isA<String>(),
        );
        expect(preferences.values, contains(keys[index]));
        expect(preferences.removeCalls, index + 1);
      });
    }

    test('partial attempt reuses valid backup and continues to completion',
        () async {
      final preferences = evidence()..failRemoveKey = keys[2];
      await expectLater(
        RemoteAgentConfigurationService.resetCorruptEvidence(preferences),
        throwsStateError,
      );
      final backup = preferences.values['remote_agent_recovery_backup_v1'];
      expect(preferences.setStringCalls, 1);

      preferences.failRemoveKey = null;
      await RemoteAgentConfigurationService.resetCorruptEvidence(preferences);

      expect(preferences.setStringCalls, 1);
      expect(preferences.values['remote_agent_recovery_backup_v1'], backup);
      for (final key in keys) {
        expect(preferences.values, isNot(contains(key)));
      }
    });

    test('malformed and oversized existing backups block every removal',
        () async {
      for (final backup in ['not-json', 'x' * (257 * 1024)]) {
        final preferences = evidence()
          ..values['remote_agent_recovery_backup_v1'] = backup;

        await expectLater(
          RemoteAgentConfigurationService.resetCorruptEvidence(preferences),
          throwsFormatException,
        );
        expect(preferences.removeCalls, 0);
        for (final key in keys) {
          expect(preferences.values, contains(key));
        }
      }
    });

    test('all keys absent is idempotent and does not create a backup',
        () async {
      final preferences = _RecoveryPreferences({});

      await RemoteAgentConfigurationService.resetCorruptEvidence(preferences);
      await RemoteAgentConfigurationService.resetCorruptEvidence(preferences);

      expect(preferences.values, isEmpty);
      expect(preferences.removeCalls, 0);
      expect(preferences.setStringCalls, 0);
    });
  });
}

final class _RecoveryPreferences implements RemoteAgentRecoveryPreferences {
  _RecoveryPreferences(this.values);

  final Map<String, Object?> values;
  String? failRemoveKey;
  int removeCalls = 0;
  int setStringCalls = 0;

  @override
  Object? get(String key) => values[key];

  @override
  String? getString(String key) => values[key] as String?;

  @override
  Future<bool> remove(String key) async {
    removeCalls += 1;
    if (key == failRemoveKey) return false;
    values.remove(key);
    return true;
  }

  @override
  Future<bool> setString(String key, String value) async {
    setStringCalls += 1;
    values[key] = value;
    return true;
  }
}

Future<
    ({
      _MemoryMetadataStorage metadata,
      _MemorySecretStorage secrets,
    })> _faultedJournalFixture() async {
  final metadata = _MemoryMetadataStorage();
  final secrets = _MemorySecretStorage();
  final initial = RemoteAgentConfigurationService(
    metadataStorage: metadata,
    secretStorage: secrets,
  );
  await initial.saveConfiguration(
    kind: RemoteAgentConnectorKind.openClawGateway,
    connectorId: 'primary_remote',
    displayName: 'Remote Agent',
    baseUrl: 'https://agent.example/v1/chat/completions',
    remoteAgentId: 'agent_1',
    credential: 'initial-secret',
  );
  final faulted = RemoteAgentConfigurationService(
    metadataStorage: metadata,
    secretStorage: secrets,
    faultInjector: (step) {
      if (step == RemoteAgentMutationStep.metadataCommitted) {
        throw StateError('injected journal fault');
      }
    },
  );
  await faulted.init();
  await expectLater(
    faulted.saveConfiguration(
      kind: RemoteAgentConnectorKind.openClawGateway,
      connectorId: 'primary_remote',
      displayName: 'Remote Agent',
      baseUrl: 'https://changed.example/v1/chat/completions',
      remoteAgentId: 'agent_2',
      credential: 'replacement-secret',
    ),
    throwsStateError,
  );
  return (metadata: metadata, secrets: secrets);
}

final class _MemoryMetadataStorage implements RemoteAgentMetadataStorage {
  final Map<String, String> values = {};

  @override
  Future<void> delete(String key) async => values.remove(key);

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

final class _FaultingMetadataStorage implements RemoteAgentMetadataStorage {
  _FaultingMetadataStorage(this.backing);
  final _MemoryMetadataStorage backing;
  String? failNextDeleteOf;

  @override
  Future<void> delete(String key) async {
    if (failNextDeleteOf == key) {
      failNextDeleteOf = null;
      throw StateError('injected metadata delete fault');
    }
    await backing.delete(key);
  }

  @override
  Future<String?> read(String key) => backing.read(key);

  @override
  Future<void> write(String key, String value) => backing.write(key, value);
}

final class _FaultingSecretStorage implements RemoteAgentSecretStorage {
  _FaultingSecretStorage(this.backing);
  final _MemorySecretStorage backing;
  bool failNextDelete = false;
  bool failDeletes = false;

  @override
  Future<void> delete(String key) async {
    if (failDeletes || failNextDelete) {
      failNextDelete = false;
      throw StateError('injected secret delete fault');
    }
    await backing.delete(key);
  }

  @override
  Future<String?> read(String key) => backing.read(key);

  @override
  Future<void> write(String key, String value) => backing.write(key, value);
}

final class _MutationBlocker {
  Completer<void> entered = Completer<void>();
  Completer<void> release = Completer<void>();
  bool _armed = false;

  void arm() => _armed = true;

  Future<void> call(RemoteAgentMutationStep step) async {
    if (!_armed || step != RemoteAgentMutationStep.journalPrepared) return;
    _armed = false;
    entered.complete();
    await release.future;
  }
}
