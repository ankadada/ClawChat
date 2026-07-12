import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/remote_agent_connector.dart';
import 'remote_agent_connector.dart';
import 'session_storage.dart';

abstract interface class RemoteAgentMetadataStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

abstract interface class RemoteAgentSecretStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

final class SharedPreferencesRemoteAgentMetadataStorage
    implements RemoteAgentMetadataStorage {
  SharedPreferencesRemoteAgentMetadataStorage(this._preferences);

  final SharedPreferences _preferences;

  @override
  Future<String?> read(String key) async => _preferences.getString(key);

  @override
  Future<void> write(String key, String value) async {
    await _preferences.setString(key, value);
  }

  @override
  Future<void> delete(String key) async {
    await _preferences.remove(key);
  }
}

abstract interface class RemoteAgentRecoveryPreferences {
  Object? get(String key);
  String? getString(String key);
  Future<bool> setString(String key, String value);
  Future<bool> remove(String key);
}

final class SharedPreferencesRemoteAgentRecoveryPreferences
    implements RemoteAgentRecoveryPreferences {
  SharedPreferencesRemoteAgentRecoveryPreferences(this._preferences);

  final SharedPreferences _preferences;

  @override
  Object? get(String key) => _preferences.get(key);

  @override
  String? getString(String key) => _preferences.getString(key);

  @override
  Future<bool> setString(String key, String value) =>
      _preferences.setString(key, value);

  @override
  Future<bool> remove(String key) => _preferences.remove(key);
}

final class KeystoreRemoteAgentSecretStorage
    implements RemoteAgentSecretStorage {
  KeystoreRemoteAgentSecretStorage(this._storage);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

enum RemoteAgentMutationStep {
  journalPrepared,
  secretIssued,
  metadataCommitted,
  consentCommitted,
  memoryPublished,
  retirementQueued,
}

typedef RemoteAgentMutationFaultInjector = FutureOr<void> Function(
  RemoteAgentMutationStep step,
);

/// A request-local proof that config, credential and consent were current.
/// Mutations revoke every live lease and cancel its request-local operation.
final class RemoteAgentAuthorizationLease implements SessionCommitAuthority {
  RemoteAgentAuthorizationLease._({
    required RemoteAgentConfigurationService owner,
    required this.generation,
    required this.config,
    required this.consent,
    required this.cancellation,
  }) : _owner = owner;

  final RemoteAgentConfigurationService _owner;
  @override
  final int generation;
  final RemoteAgentConnectorConfig config;
  final RemoteAgentConsent consent;
  final RemoteAgentCancellation cancellation;
  bool _revoked = false;
  bool _released = false;

  @override
  bool get isValid => !_released && _owner._isLeaseValid(this);
  bool get wasRevoked => _revoked;

  void release() {
    if (_released) return;
    _released = true;
    _owner._releaseLease(this);
  }

  void _revoke() {
    if (_released || _revoked) return;
    _revoked = true;
    cancellation.cancel();
  }

  @override
  SessionCommitPermit? tryAcquireCommit() {
    if (!isValid) return null;
    return _owner._acquireCommit(this);
  }
}

/// Serializes and recovers every connector metadata/secret/consent mutation.
/// Raw credentials only cross [_secretStorage.write] and are never journaled.
final class RemoteAgentConfigurationService
    implements RemoteAgentCredentialResolver, RemoteAgentConsentStore {
  RemoteAgentConfigurationService({
    required RemoteAgentMetadataStorage metadataStorage,
    required RemoteAgentSecretStorage secretStorage,
    Uuid uuid = const Uuid(),
    RemoteAgentMutationFaultInjector? faultInjector,
  })  : _metadataStorage = metadataStorage,
        _secretStorage = secretStorage,
        _uuid = uuid,
        _faultInjector = faultInjector;

  static const _configKey = 'remote_agent_connector_config_v1';
  static const _consentKey = 'remote_agent_connector_consent_v1';
  static const _generationKey = 'remote_agent_connector_generation_v1';
  static const _mutationKey = 'remote_agent_connector_mutation_v1';
  static const _retirementKey = 'remote_agent_credential_retirements_v1';
  static const _recoveryBackupKey = 'remote_agent_recovery_backup_v1';
  static const _secretPrefix = 'remote_agent_credential_';
  static const _maxRetirements = 8;
  static const _maxMutationJournalBytes = 16 * 1024;
  static const _maxRecoveryBackupBytes = 256 * 1024;

  final RemoteAgentMetadataStorage _metadataStorage;
  final RemoteAgentSecretStorage _secretStorage;
  final Uuid _uuid;
  final RemoteAgentMutationFaultInjector? _faultInjector;

  RemoteAgentConnectorConfig? _config;
  RemoteAgentConsent? _consent;
  int _generation = 0;
  bool _initialized = false;
  Future<void> _mutationTail = Future<void>.value();
  final Set<RemoteAgentAuthorizationLease> _activeLeases = {};
  final Set<_RemoteAgentCommitPermit> _activeCommits = {};

  RemoteAgentConnectorConfig? get config => _config;
  RemoteAgentConsent? get consent => _consent;
  int get generation => _generation;
  bool get isReady => _config != null && _consent?.allows(_config!) == true;

  static Future<RemoteAgentConfigurationService> createForApp() async {
    final preferences = await SharedPreferences.getInstance();
    final service = RemoteAgentConfigurationService(
      metadataStorage: SharedPreferencesRemoteAgentMetadataStorage(preferences),
      secretStorage: KeystoreRemoteAgentSecretStorage(
        const FlutterSecureStorage(
          aOptions: AndroidOptions(encryptedSharedPreferences: true),
        ),
      ),
    );
    await service.init();
    return service;
  }

  /// Explicit destructive recovery only. Operational evidence is first copied
  /// into one bounded local backup; Keystore secret entries are never deleted.
  static Future<void> resetCorruptEvidenceForApp() async {
    final preferences = await SharedPreferences.getInstance();
    await resetCorruptEvidence(
      SharedPreferencesRemoteAgentRecoveryPreferences(preferences),
    );
  }

  static const _operationalRecoveryKeys = [
    _configKey,
    _consentKey,
    _generationKey,
    _mutationKey,
    _retirementKey,
  ];

  /// Idempotent explicit recovery transaction. A valid bounded backup is
  /// durable before any operational key is removed and is reused after a
  /// partial attempt. It never opens the credential store.
  static Future<void> resetCorruptEvidence(
    RemoteAgentRecoveryPreferences preferences, {
    DateTime Function()? clock,
  }) async {
    final existingBackup = preferences.getString(_recoveryBackupKey);
    if (existingBackup != null) {
      _validateRecoveryBackup(existingBackup);
    } else {
      final evidence = <String, Object?>{};
      for (final key in _operationalRecoveryKeys) {
        final value = preferences.get(key);
        if (value != null) evidence[key] = value;
      }
      if (evidence.isNotEmpty) {
        final backup = jsonEncode({
          'version': 1,
          'createdAt':
              (clock?.call() ?? DateTime.now()).toUtc().toIso8601String(),
          'evidence': evidence,
        });
        _validateRecoveryBackup(backup);
        if (!await preferences.setString(_recoveryBackupKey, backup) ||
            preferences.getString(_recoveryBackupKey) != backup) {
          throw StateError('Unable to preserve local recovery evidence.');
        }
      }
    }

    for (final key in _operationalRecoveryKeys) {
      if (preferences.get(key) == null) continue;
      final removed = await preferences.remove(key);
      if (!removed || preferences.get(key) != null) {
        throw StateError('Remote configuration reset is incomplete.');
      }
    }
    if (_operationalRecoveryKeys.any((key) => preferences.get(key) != null)) {
      throw StateError('Remote configuration reset is incomplete.');
    }
  }

  static void _validateRecoveryBackup(String backup) {
    if (utf8.encode(backup).length > _maxRecoveryBackupBytes) {
      throw const FormatException(
        'Remote configuration recovery backup is invalid.',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(backup);
    } catch (_) {
      throw const FormatException(
        'Remote configuration recovery backup is invalid.',
      );
    }
    if (decoded is! Map<String, dynamic> ||
        decoded.length != 3 ||
        decoded['version'] != 1 ||
        decoded['createdAt'] is! String ||
        DateTime.tryParse(decoded['createdAt'] as String) == null ||
        decoded['evidence'] is! Map<String, dynamic>) {
      throw const FormatException(
        'Remote configuration recovery backup is invalid.',
      );
    }
    final evidence = decoded['evidence'] as Map<String, dynamic>;
    if (evidence.isEmpty ||
        evidence.keys.any((key) => !_operationalRecoveryKeys.contains(key)) ||
        evidence.values.any((value) => !_isRecoveryValue(value))) {
      throw const FormatException(
        'Remote configuration recovery backup is invalid.',
      );
    }
  }

  static bool _isRecoveryValue(Object? value) =>
      value is String ||
      value is bool ||
      value is int ||
      value is double ||
      (value is List && value.every((item) => item is String));

  Future<void> init({RemoteAgentCancellation? cancellation}) {
    final operation = _serialized(() async {
      if (_initialized) return;
      final generationRaw = await _metadataStorage.read(_generationKey);
      final parsedGeneration =
          generationRaw == null ? 0 : int.tryParse(generationRaw);
      if (parsedGeneration == null ||
          parsedGeneration < 0 ||
          parsedGeneration > 0x7fffffffffffffff) {
        throw const FormatException('Invalid remote mutation generation.');
      }
      _generation = parsedGeneration;
      await _validatePendingJournal();
      await _publishDurableState();
      await _drainRetirements();
      await _reconcileIncompleteMutation();
      await _publishDurableState();
      await _drainRetirements();
      if (_config == null) {
        await _metadataStorage.delete(_consentKey);
        _consent = null;
      } else if (_consent?.allows(_config!) != true && _config!.enabled) {
        final disabled = _copyConfig(_config!, enabled: false);
        await _persistConfig(disabled);
        await _metadataStorage.delete(_consentKey);
        _config = disabled;
        _consent = null;
      }
      _initialized = true;
    });
    return cancellation == null
        ? operation
        : _raceRemoteAgentPreflight(operation, cancellation);
  }

  Future<RemoteAgentAuthorizationLease> claimAuthorization(
      String connectorId, RemoteAgentCancellation cancellation,
      {bool Function()? runtimeAuthorizationGuard}) async {
    _requireRuntimeAuthorization(runtimeAuthorizationGuard, cancellation);
    await init(cancellation: cancellation);
    _requireRuntimeAuthorization(runtimeAuthorizationGuard, cancellation);
    final operation = _serialized(() async {
      _requireRuntimeAuthorization(runtimeAuthorizationGuard, cancellation);
      final current = _config;
      final currentConsent = _consent;
      if (current == null ||
          current.id != connectorId ||
          currentConsent?.allows(current) != true ||
          cancellation.isCancelled) {
        throw const RemoteAgentFailure(
          RemoteAgentErrorCode.consentRequired,
          retryable: true,
        );
      }
      final credential = await _secretStorage.read(
        _secretKey(current.credentialReference),
      );
      _requireRuntimeAuthorization(runtimeAuthorizationGuard, cancellation);
      if (credential == null || credential.trim().isEmpty) {
        throw const RemoteAgentFailure(
          RemoteAgentErrorCode.credentialUnavailable,
        );
      }
      final lease = RemoteAgentAuthorizationLease._(
        owner: this,
        generation: _generation,
        config: current,
        consent: currentConsent!,
        cancellation: cancellation,
      );
      _activeLeases.add(lease);
      return lease;
    });
    return _raceRemoteAgentPreflight(operation, cancellation);
  }

  void _requireRuntimeAuthorization(
    bool Function()? guard,
    RemoteAgentCancellation cancellation,
  ) {
    if (cancellation.isCancelled || guard?.call() == false) {
      throw const RemoteAgentFailure(
        RemoteAgentErrorCode.consentRequired,
        retryable: true,
      );
    }
  }

  Future<T> _raceRemoteAgentPreflight<T>(
    Future<T> operation,
    RemoteAgentCancellation cancellation,
  ) {
    final result = Completer<T>();
    RemoteAgentCancellationRegistration? registration;
    var acceptingResult = true;

    void settleCancelled() {
      if (!acceptingResult) return;
      acceptingResult = false;
      registration?.dispose();
      result.completeError(
        const RemoteAgentFailure(RemoteAgentErrorCode.cancelled),
      );
    }

    registration = cancellation.onCancelled(settleCancelled);
    if (cancellation.isCancelled) settleCancelled();
    operation.then<void>(
      (value) {
        if (!acceptingResult) return;
        acceptingResult = false;
        registration?.dispose();
        result.complete(value);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!acceptingResult) return;
        acceptingResult = false;
        registration?.dispose();
        result.completeError(error, stackTrace);
      },
    );
    return result.future;
  }

  Future<RemoteAgentCredentialReference> saveConfiguration({
    required RemoteAgentConnectorKind kind,
    required String connectorId,
    required String displayName,
    required String baseUrl,
    required String remoteAgentId,
    String? credential,
  }) async {
    await init();
    return _serialized(() async {
      await _prepareForMutation();
      final old = _config;
      final trimmedCredential = credential?.trim();
      final reference = trimmedCredential == null || trimmedCredential.isEmpty
          ? old?.credentialReference
          : RemoteAgentCredentialReference.parse(
              'cred_${_uuid.v4().replaceAll('-', '')}',
            );
      if (reference == null) {
        throw const RemoteAgentFailure(
          RemoteAgentErrorCode.credentialUnavailable,
        );
      }
      final next = RemoteAgentConnectorConfig(
        kind: kind,
        id: connectorId,
        displayName: displayName,
        baseUrl: baseUrl,
        credentialReference: reference,
        remoteAgentId: remoteAgentId,
        enabled: false,
      );
      final generation = await _beginMutation();
      final issuedNewReference = old?.credentialReference != reference;
      final record = _MutationRecord(
        generation: generation,
        previousConfig: old,
        previousConsent: _consent,
        nextConfig: next,
        nextConsent: null,
        newReference: issuedNewReference ? reference : null,
        retireReference: issuedNewReference ? old?.credentialReference : null,
      );
      await _commitTransition(
        record,
        newCredential: issuedNewReference ? trimmedCredential : null,
      );
      return reference;
    });
  }

  Future<void> grantConsentAndEnable({required DateTime acceptedAt}) async {
    await init();
    await _serialized(() async {
      await _prepareForMutation();
      final current = _config;
      if (current == null ||
          (await _secretStorage.read(
                _secretKey(current.credentialReference),
              ))
                  ?.trim()
                  .isNotEmpty !=
              true) {
        throw const RemoteAgentFailure(
          RemoteAgentErrorCode.credentialUnavailable,
        );
      }
      final enabled = _copyConfig(current, enabled: true);
      final granted = RemoteAgentConsent.grant(enabled, acceptedAt: acceptedAt);
      final generation = await _beginMutation();
      await _commitTransition(_MutationRecord(
        generation: generation,
        previousConfig: current,
        previousConsent: _consent,
        nextConfig: enabled,
        nextConsent: granted,
      ));
    });
  }

  Future<void> disable() => _setDisabled();

  Future<void> revokeConsent() => _setDisabled();

  Future<void> _setDisabled() async {
    await init();
    await _serialized(() async {
      await _prepareForMutation();
      final current = _config;
      if (current == null) return;
      final disabled = _copyConfig(current, enabled: false);
      final generation = await _beginMutation();
      await _commitTransition(_MutationRecord(
        generation: generation,
        previousConfig: current,
        previousConsent: _consent,
        nextConfig: disabled,
        nextConsent: null,
      ));
    });
  }

  Future<void> removeCredential() async {
    await init();
    await _serialized(() async {
      await _prepareForMutation();
      final current = _config;
      if (current == null) return;
      final generation = await _beginMutation();
      await _commitTransition(_MutationRecord(
        generation: generation,
        previousConfig: current,
        previousConsent: _consent,
        nextConfig: null,
        nextConsent: null,
        retireReference: current.credentialReference,
      ));
    });
  }

  Future<bool> hasCredential() async {
    await init();
    final current = _config;
    return current != null &&
        (await _secretStorage.read(_secretKey(current.credentialReference)))
                ?.trim()
                .isNotEmpty ==
            true;
  }

  @override
  Future<String?> resolve(RemoteAgentCredentialReference reference) =>
      _secretStorage.read(_secretKey(reference));

  @override
  Future<RemoteAgentConsent?> read(String connectorId) async {
    await init();
    return _consent?.connectorId == connectorId ? _consent : null;
  }

  @override
  Future<void> write(RemoteAgentConsent consent) async {
    await init();
    await _serialized(() async {
      await _prepareForMutation();
      final current = _config;
      if (current == null || !consent.allows(current)) {
        throw const RemoteAgentFailure(
          RemoteAgentErrorCode.consentRequired,
        );
      }
      final generation = await _beginMutation();
      await _commitTransition(_MutationRecord(
        generation: generation,
        previousConfig: current,
        previousConsent: _consent,
        nextConfig: current,
        nextConsent: consent,
      ));
    });
  }

  @override
  Future<void> remove(String connectorId) async {
    await init();
    if (_config?.id != connectorId) return;
    await revokeConsent();
  }

  Future<int> _beginMutation() async {
    if (await _metadataStorage.read(_mutationKey) != null) {
      throw StateError('An earlier remote mutation is still unresolved.');
    }
    if (_generation >= 0x7fffffffffffffff) {
      throw StateError('Remote mutation generation is exhausted.');
    }
    _generation += 1;
    for (final lease in _activeLeases.toList(growable: false)) {
      lease._revoke();
    }
    _activeLeases.clear();
    final commits = _activeCommits
        .map((permit) => permit.completed.future)
        .toList(growable: false);
    if (commits.isNotEmpty) await Future.wait(commits);
    await _metadataStorage.write(_generationKey, '$_generation');
    return _generation;
  }

  Future<void> _commitTransition(
    _MutationRecord record, {
    String? newCredential,
  }) async {
    await _writeMutation(record.withPhase(_MutationPhase.prepared));
    await _fault(RemoteAgentMutationStep.journalPrepared);
    try {
      if (record.newReference != null) {
        await _secretStorage.write(
          _secretKey(record.newReference!),
          newCredential!,
        );
        await _fault(RemoteAgentMutationStep.secretIssued);
      }
      await _persistConfig(record.nextConfig);
      await _fault(RemoteAgentMutationStep.metadataCommitted);
      await _writeMutation(record.withPhase(_MutationPhase.metadataCommitted));
      await _persistConsent(record.nextConsent);
      await _fault(RemoteAgentMutationStep.consentCommitted);
      await _writeMutation(record.withPhase(_MutationPhase.consentCommitted));
      _config = record.nextConfig;
      _consent = record.nextConsent;
      await _fault(RemoteAgentMutationStep.memoryPublished);
      if (record.retireReference != null) {
        await _enqueueRetirement(record.retireReference!);
        await _fault(RemoteAgentMutationStep.retirementQueued);
      }
      await _metadataStorage.delete(_mutationKey);
      if (_generation == record.generation) await _drainRetirements();
    } catch (_) {
      await _recoverAfterTransitionFailure(record);
      rethrow;
    }
  }

  Future<void> _recoverAfterTransitionFailure(_MutationRecord record) async {
    final durable = await _readDurableMutationSnapshot();
    final state = _classifyDurableState(record, durable);
    if (state == _DurableMutationState.previous) {
      if (record.newReference != null) {
        try {
          await _deleteUnownedReference(record.newReference!, durable.config);
          await _metadataStorage.delete(_mutationKey);
        } catch (_) {
          // Prepared journal remains as bounded cleanup evidence.
        }
      } else {
        await _metadataStorage.delete(_mutationKey);
      }
      _config = durable.config;
      _consent = durable.consent;
      return;
    }
    if (state == _DurableMutationState.next) {
      await _publishDurableState();
    }
  }

  Future<void> _reconcileIncompleteMutation() async {
    final raw = await _metadataStorage.read(_mutationKey);
    if (raw == null) return;
    final record = _decodeMutation(raw);
    if (record == null) {
      throw const FormatException('Invalid remote mutation evidence.');
    }
    if (record.generation != _generation) {
      throw const FormatException('Stale remote mutation evidence.');
    }
    final durable = await _readDurableMutationSnapshot();
    final state = _classifyDurableState(record, durable);
    if (state == _DurableMutationState.invalid) {
      throw const FormatException('Inconsistent remote mutation state.');
    }
    if (state == _DurableMutationState.previous) {
      if (record.newReference != null) {
        try {
          await _deleteUnownedReference(record.newReference!, durable.config);
        } catch (_) {
          return;
        }
      }
      await _metadataStorage.delete(_mutationKey);
      return;
    }
    if (record.newReference != null) {
      final secret =
          await _secretStorage.read(_secretKey(record.newReference!));
      if (secret == null || secret.trim().isEmpty) {
        throw StateError('Committed remote credential is unavailable.');
      }
    }
    await _persistConsent(record.nextConsent);
    _config = record.nextConfig;
    _consent = record.nextConsent;
    if (record.retireReference != null) {
      await _enqueueRetirement(record.retireReference!);
    }
    await _metadataStorage.delete(_mutationKey);
  }

  Future<void> _publishDurableState() async {
    _config = _decodeConfig(await _metadataStorage.read(_configKey));
    _consent = _decodeConsent(await _metadataStorage.read(_consentKey));
  }

  Future<void> _prepareForMutation() async {
    await _validatePendingJournal();
    await _publishDurableState();
    await _drainRetirements();
    await _reconcileIncompleteMutation();
    await _publishDurableState();
    await _drainRetirements();
    if (await _metadataStorage.read(_mutationKey) != null) {
      throw StateError('An earlier remote mutation is still unresolved.');
    }
  }

  Future<void> _validatePendingJournal() async {
    final raw = await _metadataStorage.read(_mutationKey);
    if (raw == null) return;
    final record = _decodeMutation(raw);
    if (record == null) {
      throw const FormatException('Invalid remote mutation evidence.');
    }
    if (record.generation != _generation) {
      throw const FormatException('Stale remote mutation evidence.');
    }
    final durable = await _readDurableMutationSnapshot();
    if (_classifyDurableState(record, durable) ==
        _DurableMutationState.invalid) {
      throw const FormatException('Inconsistent remote mutation state.');
    }
  }

  Future<_DurableMutationSnapshot> _readDurableMutationSnapshot() async {
    final configRaw = await _metadataStorage.read(_configKey);
    final consentRaw = await _metadataStorage.read(_consentKey);
    final config = _decodeConfig(configRaw);
    final consent = _decodeConsent(consentRaw);
    return _DurableMutationSnapshot(
      config: config,
      consent: consent,
      isWellFormed: (configRaw == null || config != null) &&
          (consentRaw == null || consent != null),
    );
  }

  static _DurableMutationState _classifyDurableState(
    _MutationRecord record,
    _DurableMutationSnapshot durable,
  ) {
    if (!durable.isWellFormed) return _DurableMutationState.invalid;
    final isPrevious = _sameConfig(durable.config, record.previousConfig) &&
        _sameConsent(durable.consent, record.previousConsent);
    final isNextConfig = _sameConfig(durable.config, record.nextConfig);
    switch (record.phase) {
      case _MutationPhase.prepared:
        if (isPrevious) return _DurableMutationState.previous;
        if (isNextConfig &&
            _sameConsent(durable.consent, record.previousConsent)) {
          return _DurableMutationState.next;
        }
      case _MutationPhase.metadataCommitted:
        if (isNextConfig &&
            (_sameConsent(durable.consent, record.previousConsent) ||
                _sameConsent(durable.consent, record.nextConsent))) {
          return _DurableMutationState.next;
        }
      case _MutationPhase.consentCommitted:
        if (isNextConfig && _sameConsent(durable.consent, record.nextConsent)) {
          return _DurableMutationState.next;
        }
    }
    return _DurableMutationState.invalid;
  }

  Future<void> _deleteUnownedReference(
    RemoteAgentCredentialReference reference,
    RemoteAgentConnectorConfig? durableConfig,
  ) async {
    if (durableConfig?.credentialReference == reference) {
      throw StateError('Refusing to delete a durably owned credential.');
    }
    await _secretStorage.delete(_secretKey(reference));
  }

  Future<void> _persistConfig(RemoteAgentConnectorConfig? config) =>
      config == null
          ? _metadataStorage.delete(_configKey)
          : _metadataStorage.write(_configKey, jsonEncode(config.toJson()));

  Future<void> _persistConsent(RemoteAgentConsent? consent) => consent == null
      ? _metadataStorage.delete(_consentKey)
      : _metadataStorage.write(_consentKey, jsonEncode(consent.toJson()));

  Future<void> _enqueueRetirement(
    RemoteAgentCredentialReference reference,
  ) async {
    final pending = await _readRetirements();
    if (!pending.any((candidate) => candidate == reference)) {
      if (pending.length >= _maxRetirements) {
        throw StateError('Remote credential retirement queue is full.');
      }
      pending.add(reference);
      await _metadataStorage.write(
        _retirementKey,
        jsonEncode(pending.map((candidate) => candidate.value).toList()),
      );
    }
  }

  Future<void> _drainRetirements() async {
    final pending = await _readRetirements();
    if (pending.isEmpty) {
      await _metadataStorage.delete(_retirementKey);
      return;
    }
    final remaining = <RemoteAgentCredentialReference>[];
    for (final reference in pending) {
      if (_config?.credentialReference == reference) {
        remaining.add(reference);
        continue;
      }
      try {
        await _secretStorage.delete(_secretKey(reference));
      } catch (_) {
        remaining.add(reference);
      }
    }
    if (remaining.isEmpty) {
      await _metadataStorage.delete(_retirementKey);
    } else {
      await _metadataStorage.write(
        _retirementKey,
        jsonEncode(remaining.map((reference) => reference.value).toList()),
      );
    }
  }

  Future<List<RemoteAgentCredentialReference>> _readRetirements() async {
    final raw = await _metadataStorage.read(_retirementKey);
    if (raw == null) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List || decoded.length > _maxRetirements) {
        throw const FormatException('Invalid credential retirement evidence.');
      }
      return decoded
          .map(RemoteAgentCredentialReference.parse)
          .toList(growable: true);
    } catch (_) {
      throw const FormatException('Invalid credential retirement evidence.');
    }
  }

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    final previous = _mutationTail;
    _mutationTail = () async {
      try {
        await previous.catchError((_) {});
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    }();
    return completer.future;
  }

  bool _isLeaseValid(RemoteAgentAuthorizationLease lease) {
    final current = _config;
    return !lease._revoked &&
        !lease.cancellation.isCancelled &&
        lease.generation == _generation &&
        _activeLeases.contains(lease) &&
        current != null &&
        _sameConfig(current, lease.config) &&
        _consent?.allows(current) == true;
  }

  void _releaseLease(RemoteAgentAuthorizationLease lease) {
    _activeLeases.remove(lease);
  }

  _RemoteAgentCommitPermit _acquireCommit(
    RemoteAgentAuthorizationLease lease,
  ) {
    final permit = _RemoteAgentCommitPermit._(this, lease);
    _activeCommits.add(permit);
    return permit;
  }

  void _releaseCommit(_RemoteAgentCommitPermit permit) {
    _activeCommits.remove(permit);
  }

  Future<void> _fault(RemoteAgentMutationStep step) async {
    await _faultInjector?.call(step);
  }

  Future<void> _writeMutation(_MutationRecord record) async {
    final encoded = jsonEncode(record.toJson());
    if (utf8.encode(encoded).length > _maxMutationJournalBytes) {
      throw const FormatException('Remote mutation evidence is too large.');
    }
    final existingRaw = await _metadataStorage.read(_mutationKey);
    if (existingRaw != null) {
      final existing = _decodeMutation(existingRaw);
      if (existing == null || existing.generation != record.generation) {
        throw StateError('A different remote mutation owns the journal.');
      }
    }
    await _metadataStorage.write(_mutationKey, encoded);
  }

  static String _secretKey(RemoteAgentCredentialReference reference) =>
      '$_secretPrefix${reference.value}';

  static RemoteAgentConnectorConfig? _decodeConfig(String? raw) {
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map
          ? RemoteAgentConnectorConfig.fromJson(
              Map<String, Object?>.from(decoded),
            )
          : null;
    } catch (_) {
      return null;
    }
  }

  static RemoteAgentConsent? _decodeConsent(String? raw) {
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map
          ? RemoteAgentConsent.fromJson(Map<String, Object?>.from(decoded))
          : null;
    } catch (_) {
      return null;
    }
  }

  static _MutationRecord? _decodeMutation(String? raw) {
    if (raw == null) return null;
    if (utf8.encode(raw).length > _maxMutationJournalBytes) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map
          ? _MutationRecord.fromJson(Map<String, Object?>.from(decoded))
          : null;
    } catch (_) {
      return null;
    }
  }

  static bool _sameConfig(
    RemoteAgentConnectorConfig? left,
    RemoteAgentConnectorConfig? right,
  ) {
    if (left == null || right == null) return left == null && right == null;
    return jsonEncode(left.toJson()) == jsonEncode(right.toJson());
  }

  static bool _sameConsent(
    RemoteAgentConsent? left,
    RemoteAgentConsent? right,
  ) {
    if (left == null || right == null) return left == null && right == null;
    return jsonEncode(left.toJson()) == jsonEncode(right.toJson());
  }

  static RemoteAgentConnectorConfig _copyConfig(
    RemoteAgentConnectorConfig source, {
    required bool enabled,
  }) =>
      RemoteAgentConnectorConfig(
        kind: source.kind,
        id: source.id,
        displayName: source.displayName,
        baseUrl: source.baseUrl,
        credentialReference: source.credentialReference,
        remoteAgentId: source.remoteAgentId,
        enabled: enabled,
      );
}

final class _RemoteAgentCommitPermit implements SessionCommitPermit {
  _RemoteAgentCommitPermit._(this._owner, this.lease);

  final RemoteAgentConfigurationService _owner;
  final RemoteAgentAuthorizationLease lease;
  final Completer<void> completed = Completer<void>();

  @override
  void complete() {
    if (completed.isCompleted) return;
    completed.complete();
    _owner._releaseCommit(this);
  }
}

enum _MutationPhase { prepared, metadataCommitted, consentCommitted }

enum _DurableMutationState { previous, next, invalid }

final class _DurableMutationSnapshot {
  const _DurableMutationSnapshot({
    required this.config,
    required this.consent,
    required this.isWellFormed,
  });

  final RemoteAgentConnectorConfig? config;
  final RemoteAgentConsent? consent;
  final bool isWellFormed;
}

final class _MutationRecord {
  const _MutationRecord({
    required this.generation,
    required this.previousConfig,
    required this.previousConsent,
    required this.nextConfig,
    required this.nextConsent,
    this.phase = _MutationPhase.prepared,
    this.newReference,
    this.retireReference,
  });

  final int generation;
  final _MutationPhase phase;
  final RemoteAgentConnectorConfig? previousConfig;
  final RemoteAgentConsent? previousConsent;
  final RemoteAgentConnectorConfig? nextConfig;
  final RemoteAgentConsent? nextConsent;
  final RemoteAgentCredentialReference? newReference;
  final RemoteAgentCredentialReference? retireReference;

  _MutationRecord withPhase(_MutationPhase nextPhase) => _MutationRecord(
        generation: generation,
        phase: nextPhase,
        previousConfig: previousConfig,
        previousConsent: previousConsent,
        nextConfig: nextConfig,
        nextConsent: nextConsent,
        newReference: newReference,
        retireReference: retireReference,
      );

  Map<String, Object?> toJson() => {
        'version': 1,
        'generation': generation,
        'phase': phase.name,
        'previous_config': previousConfig?.toJson(),
        'previous_consent': previousConsent?.toJson(),
        'next_config': nextConfig?.toJson(),
        'next_consent': nextConsent?.toJson(),
        'new_reference': newReference?.value,
        'retire_reference': retireReference?.value,
      };

  factory _MutationRecord.fromJson(Map<String, Object?> json) {
    const expectedKeys = {
      'version',
      'generation',
      'phase',
      'previous_config',
      'previous_consent',
      'next_config',
      'next_consent',
      'new_reference',
      'retire_reference',
    };
    if (json.length != expectedKeys.length ||
        !json.keys.toSet().containsAll(expectedKeys) ||
        json['version'] != 1 ||
        json['generation'] is! int ||
        (json['generation']! as int) < 1 ||
        (json['generation']! as int) > 0x7fffffffffffffff) {
      throw const FormatException('Invalid remote mutation record.');
    }
    final phaseName = json['phase'];
    final phase = _MutationPhase.values
        .where((candidate) => candidate.name == phaseName)
        .firstOrNull;
    if (phase == null) {
      throw const FormatException('Invalid remote mutation phase.');
    }
    final record = _MutationRecord(
      generation: json['generation']! as int,
      phase: phase,
      previousConfig: _configFrom(json['previous_config']),
      previousConsent: _consentFrom(json['previous_consent']),
      nextConfig: _configFrom(json['next_config']),
      nextConsent: _consentFrom(json['next_consent']),
      newReference: _referenceFrom(json['new_reference']),
      retireReference: _referenceFrom(json['retire_reference']),
    );
    if ((record.previousConsent != null &&
            (record.previousConfig == null ||
                !record.previousConsent!.allows(record.previousConfig!))) ||
        (record.nextConsent != null &&
            (record.nextConfig == null ||
                !record.nextConsent!.allows(record.nextConfig!)))) {
      throw const FormatException('Invalid remote mutation binding.');
    }
    final previousReference = record.previousConfig?.credentialReference;
    final nextReference = record.nextConfig?.credentialReference;
    final referenceChanged = previousReference != nextReference;
    if ((record.newReference != null &&
            (record.nextConfig == null ||
                record.newReference != nextReference)) ||
        (referenceChanged &&
            nextReference != null &&
            record.newReference != nextReference) ||
        (!referenceChanged && record.newReference != null) ||
        (referenceChanged &&
            previousReference != null &&
            record.retireReference != previousReference) ||
        (!referenceChanged && record.retireReference != null) ||
        (previousReference == null && record.retireReference != null)) {
      throw const FormatException('Invalid remote mutation references.');
    }
    return record;
  }

  static RemoteAgentConnectorConfig? _configFrom(Object? raw) => raw == null
      ? null
      : RemoteAgentConnectorConfig.fromJson(
          Map<String, Object?>.from(raw as Map),
        );

  static RemoteAgentConsent? _consentFrom(Object? raw) => raw == null
      ? null
      : RemoteAgentConsent.fromJson(Map<String, Object?>.from(raw as Map));

  static RemoteAgentCredentialReference? _referenceFrom(Object? raw) =>
      raw == null ? null : RemoteAgentCredentialReference.parse(raw);
}
