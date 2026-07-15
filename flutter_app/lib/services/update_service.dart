import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../constants.dart';
import '../models/extension_manifest.dart';
import '../models/update_models.dart';
import 'app_http.dart';
import 'native_bridge.dart';
import 'skill_service.dart';
import 'update_transaction.dart';

typedef UpdateTempDirectoryProvider = Future<Directory> Function();
typedef UpdateSignatureCheck = Future<bool> Function(
  Uint8List payload,
  String signature,
  String algorithm,
  String keyId,
);
typedef PreparedSkillInstaller = Future<SkillInstallResult> Function(
  PreparedSkillImport candidate,
);
typedef PreparedSkillDiscarder = Future<void> Function(
  PreparedSkillImport candidate,
);
typedef PreparedSkillActivator = Future<SkillInstallResult> Function(
  PreparedSkillImport candidate,
  String backupPath,
  Future<void> Function() afterBackupMove,
  Future<void> Function() afterNewMove,
);
typedef InstalledSkillSnapshotReader = Future<InstalledSkillUpdateSnapshot?>
    Function(String id);
typedef SkillPathSnapshotReader = Future<InstalledSkillUpdateSnapshot?>
    Function(String path, String id);
typedef UpdateBackupRestorer = Future<InstalledSkillUpdateSnapshot> Function({
  required String id,
  required String backupPath,
  required String expectedBackupTrustDigest,
});
typedef UpdateFailedRestorer = Future<InstalledSkillUpdateSnapshot> Function({
  required String id,
  required String failedPath,
  required String expectedTrustDigest,
});
typedef PreparedSkillRollbackActivator = Future<SkillRollbackResult> Function({
  required String id,
  required String backupPath,
  required String failedPath,
  required String expectedCurrentTrustDigest,
  required Future<void> Function() afterTargetMove,
  required Future<void> Function() afterBackupMove,
});
typedef UpdateRollbackFinalizer = Future<SkillRollbackResult> Function({
  required String id,
  required String expectedTrustDigest,
});
typedef UpdateFailureInjector = Future<void> Function(String point);

/// Test-only failure used to model process death without catch cleanup.
final class UpdateCrashSimulation implements Exception {
  const UpdateCrashSimulation(this.point);

  final String point;
}

Future<void> _runActivationInterruption(
  Future<void> Function() callback,
) async {
  try {
    await callback();
  } on UpdateCrashSimulation {
    throw const SkillActivationCrashSimulation();
  }
}

final class UpdateCancellationToken {
  bool _cancelled = false;
  final Completer<void> _signal = Completer<void>();

  bool get isCancelled => _cancelled;
  Future<void> get whenCancelled => _signal.future;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _signal.complete();
  }
}

final class ExtensionUpdatePlan {
  const ExtensionUpdatePlan._({
    required this.planId,
    required this.check,
    required this.candidate,
    required this.precondition,
  });

  final String planId;
  final UpdateCheck check;
  final PreparedSkillImport candidate;
  final UpdatePrecondition precondition;

  CapabilityDiff? get capabilityDiff => candidate.capabilityDiff;
}

final class AppUpdatePlan {
  const AppUpdatePlan._({
    required this.planId,
    required this.check,
    required this.apkPath,
  });

  final String planId;
  final UpdateCheck check;
  final String apkPath;
}

final class ExtensionUpdateState {
  const ExtensionUpdateState({
    required this.id,
    required this.version,
    required this.revision,
    required this.currentTrustDigest,
    required this.backupPath,
    required this.updatedAt,
  });

  final String id;
  final String version;
  final int revision;
  final String currentTrustDigest;
  final String backupPath;
  final String updatedAt;

  factory ExtensionUpdateState.fromJson(Map<String, dynamic> json) {
    final state = ExtensionUpdateState(
      id: json['id'] as String? ?? '',
      version: json['version'] as String? ?? '',
      revision: json['revision'] as int? ?? 0,
      currentTrustDigest: json['currentTrustDigest'] as String? ?? '',
      backupPath: json['backupPath'] as String? ?? '',
      updatedAt: json['updatedAt'] as String? ?? '',
    );
    if (state.id.isEmpty ||
        state.revision <= 0 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(state.currentTrustDigest) ||
        state.backupPath.isEmpty) {
      throw const FormatException('Stored extension update state is invalid.');
    }
    return state;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'version': version,
        'revision': revision,
        'currentTrustDigest': currentTrustDigest,
        'backupPath': backupPath,
        'updatedAt': updatedAt,
      };
}

/// Signed, bounded staged updates. Check and plan never mutate live packages.
final class UpdateService {
  UpdateService({
    http.Client? httpClient,
    UpdateSignatureCheck? signatureCheck,
    UpdateTempDirectoryProvider? tempDirectoryProvider,
    Future<PreparedSkillImport> Function(String path)? prepareLocalSkill,
    PreparedSkillInstaller? installPreparedSkill,
    PreparedSkillActivator? activatePreparedSkill,
    PreparedSkillDiscarder? discardPreparedSkill,
    Future<SkillRollbackResult> Function({
      required String id,
      required String backupPath,
      required String expectedCurrentTrustDigest,
    })? rollbackInstalledSkill,
    PreparedSkillRollbackActivator? activatePreparedRollback,
    UpdateRollbackFinalizer? finalizeRecoveredRollback,
    Future<bool> Function({
      required String path,
      required int size,
      required String sha256,
    })? apkHandoff,
    InstalledSkillSnapshotReader? installedSkillSnapshotReader,
    SkillPathSnapshotReader? backupSkillSnapshotReader,
    SkillPathSnapshotReader? stagingSkillSnapshotReader,
    SkillPathSnapshotReader? failedSkillSnapshotReader,
    UpdateBackupRestorer? restoreUpdateBackup,
    UpdateFailedRestorer? restoreFailedUpdate,
    Future<void> Function(String path, String id)? discardRecoveryPath,
    String Function()? installedAppVersionReader,
    Duration operationTimeout = const Duration(minutes: 2),
    DateTime Function()? now,
    UpdateLedgerWriter? ledgerWriter,
    UpdateFailureInjector? failureInjector,
  })  : _injectedHttpClient = httpClient,
        _signatureCheck = signatureCheck ??
            ((payload, signature, algorithm, keyId) =>
                NativeBridge.verifyUpdateSignature(
                  payload: payload,
                  signature: signature,
                  algorithm: algorithm,
                  keyId: keyId,
                )),
        _tempDirectoryProvider = tempDirectoryProvider ?? getTemporaryDirectory,
        _prepareLocalSkill = prepareLocalSkill ??
            ((path) async {
              await SkillService.cleanupAbandonedImportStaging();
              return SkillService.prepareSkillFromLocalPath(path);
            }),
        _activatePreparedSkill = activatePreparedSkill ??
            (installPreparedSkill == null
                ? ((candidate, backupPath, afterBackupMove, afterNewMove) =>
                    SkillService.installPreparedSkill(
                      candidate,
                      inspectionReviewConfirmed: true,
                      preserveBackup: true,
                      preservedBackupPath: backupPath,
                      afterBackupMove: () =>
                          _runActivationInterruption(afterBackupMove),
                      afterNewMove: () =>
                          _runActivationInterruption(afterNewMove),
                    ))
                : ((candidate, backupPath, afterBackupMove,
                    afterNewMove) async {
                    final result = await installPreparedSkill(candidate);
                    await afterBackupMove();
                    await afterNewMove();
                    return SkillInstallResult(
                      targetPath: result.targetPath,
                      backupPath: backupPath,
                      previousVersion: result.previousVersion,
                    );
                  })),
        _activatePreparedRollback = activatePreparedRollback ??
            (rollbackInstalledSkill == null
                ? ({
                    required id,
                    required backupPath,
                    required failedPath,
                    required expectedCurrentTrustDigest,
                    required afterTargetMove,
                    required afterBackupMove,
                  }) =>
                    SkillService.rollbackInstalledSkill(
                      id: id,
                      backupPath: backupPath,
                      failedPath: failedPath,
                      expectedCurrentTrustDigest: expectedCurrentTrustDigest,
                      afterTargetMove: () =>
                          _runActivationInterruption(afterTargetMove),
                      afterBackupMove: () =>
                          _runActivationInterruption(afterBackupMove),
                    )
                : ({
                    required id,
                    required backupPath,
                    required failedPath,
                    required expectedCurrentTrustDigest,
                    required afterTargetMove,
                    required afterBackupMove,
                  }) async {
                    final result = await rollbackInstalledSkill(
                      id: id,
                      backupPath: backupPath,
                      expectedCurrentTrustDigest: expectedCurrentTrustDigest,
                    );
                    await afterTargetMove();
                    await afterBackupMove();
                    return result;
                  }),
        _finalizeRecoveredRollback = finalizeRecoveredRollback ??
            (rollbackInstalledSkill == null
                ? SkillService.finalizeRecoveredRollback
                : null),
        _discardPreparedSkill =
            discardPreparedSkill ?? SkillService.discardPreparedImport,
        _apkHandoff = apkHandoff ?? NativeBridge.handoffVerifiedApk,
        _installedSkillSnapshotReader = installedSkillSnapshotReader ??
            SkillService.inspectInstalledForUpdate,
        _backupSkillSnapshotReader =
            backupSkillSnapshotReader ?? SkillService.inspectUpdatePath,
        _stagingSkillSnapshotReader =
            stagingSkillSnapshotReader ?? SkillService.inspectUpdatePath,
        _failedSkillSnapshotReader = failedSkillSnapshotReader ??
            (stagingSkillSnapshotReader == null
                ? SkillService.inspectUpdatePath
                : ((_, __) async => null)),
        _restoreUpdateBackup =
            restoreUpdateBackup ?? SkillService.restoreUpdateBackup,
        _restoreFailedUpdate =
            restoreFailedUpdate ?? SkillService.restoreFailedUpdate,
        _discardRecoveryPath =
            discardRecoveryPath ?? SkillService.discardUpdateRecoveryPath,
        _installedAppVersionReader =
            installedAppVersionReader ?? (() => AppConstants.version),
        _operationTimeout = operationTimeout,
        _now = now ?? (() => DateTime.now().toUtc()),
        _transactions = UpdateTransactionCoordinator(writer: ledgerWriter),
        _failureInjector = failureInjector;

  static const _maxMetadataBytes = 64 * 1024;
  static const _maxExtensionBytes = 25 * 1024 * 1024;
  static const _maxApkBytes = 200 * 1024 * 1024;
  static const _maxVerifiedApkCount = 3;
  static const _maxVerifiedApkAge = Duration(days: 7);
  static const _grantRetention = Duration(hours: 24);

  final http.Client? _injectedHttpClient;
  final UpdateSignatureCheck _signatureCheck;
  final UpdateTempDirectoryProvider _tempDirectoryProvider;
  final Future<PreparedSkillImport> Function(String path) _prepareLocalSkill;
  final PreparedSkillActivator _activatePreparedSkill;
  final PreparedSkillRollbackActivator _activatePreparedRollback;
  final UpdateRollbackFinalizer? _finalizeRecoveredRollback;
  final PreparedSkillDiscarder _discardPreparedSkill;
  final Future<bool> Function({
    required String path,
    required int size,
    required String sha256,
  }) _apkHandoff;
  final InstalledSkillSnapshotReader _installedSkillSnapshotReader;
  final SkillPathSnapshotReader _backupSkillSnapshotReader;
  final SkillPathSnapshotReader _stagingSkillSnapshotReader;
  final SkillPathSnapshotReader _failedSkillSnapshotReader;
  final UpdateBackupRestorer _restoreUpdateBackup;
  final UpdateFailedRestorer _restoreFailedUpdate;
  final Future<void> Function(String path, String id) _discardRecoveryPath;
  final String Function() _installedAppVersionReader;
  final Duration _operationTimeout;
  final DateTime Function() _now;
  final UpdateTransactionCoordinator _transactions;
  final UpdateFailureInjector? _failureInjector;
  final Map<String, Object> _activePlans = <String, Object>{};

  http.Client get _client =>
      _injectedHttpClient ?? AppHttpClientRegistry.instance.webFetchClient;

  Future<UpdateCheck> checkExtensionUpdate(
    SkillInfo installed, {
    String? localMetadata,
    String? sourceIdentity,
    UpdateCancellationToken? cancellationToken,
  }) async {
    if (!installed.valid || installed.legacy || installed.manifest == null) {
      throw StateError('Only valid manifested extensions can be updated.');
    }
    if (installed.manifest!.capabilities.updatePolicy != 'manual') {
      throw StateError('Extension updates are disabled by its manifest.');
    }
    return _transactions.run(installed.id, () async {
      final deadline = _newDeadline();
      final current = await _installedSkillSnapshotReader(installed.id);
      if (current == null || current.version != installed.version) {
        throw StateError('Installed extension changed before update check.');
      }
      final metadataSource = localMetadata ??
          await _downloadText(
            _validatedMetadataUri(installed.manifest!.source.url),
            cancellationToken,
            deadline,
          );
      _throwIfCancelled(cancellationToken);
      return _checkMetadata(
        metadataSource,
        expectedKind: UpdateArtifactKind.extension,
        expectedTargetId: installed.id,
        currentVersion: current.version,
        currentTrustDigest: current.trustDigest,
        sourceIdentity: sourceIdentity ??
            _remoteIdentity(
                _validatedMetadataUri(installed.manifest!.source.url)),
      );
    });
  }

  Future<UpdateCheck> checkAppUpdate(
    String metadataUrl, {
    String currentVersion = AppConstants.version,
    UpdateCancellationToken? cancellationToken,
  }) async {
    final uri = _validatedMetadataUri(metadataUrl);
    return _transactions.run(AppConstants.packageName, () async {
      final source = await _downloadText(
        uri,
        cancellationToken,
        _newDeadline(),
      );
      _throwIfCancelled(cancellationToken);
      return _checkMetadata(
        source,
        expectedKind: UpdateArtifactKind.androidApp,
        expectedTargetId: AppConstants.packageName,
        currentVersion: currentVersion,
        sourceIdentity: _remoteIdentity(uri),
      );
    });
  }

  Future<UpdateCheck> checkLocalMetadata(
    String metadataSource, {
    required UpdateArtifactKind expectedKind,
    required String expectedTargetId,
    required String currentVersion,
    required String sourceIdentity,
  }) =>
      _transactions.run(
        expectedTargetId,
        () => _checkMetadata(
          metadataSource,
          expectedKind: expectedKind,
          expectedTargetId: expectedTargetId,
          currentVersion: currentVersion,
          sourceIdentity: sourceIdentity,
        ),
      );

  Future<UpdateCheck> _checkMetadata(
    String source, {
    required UpdateArtifactKind expectedKind,
    required String expectedTargetId,
    required String currentVersion,
    required String sourceIdentity,
    String? currentTrustDigest,
  }) async {
    final metadata = SignedUpdateMetadata.parse(source);
    if (metadata.kind != expectedKind ||
        metadata.targetId != expectedTargetId) {
      throw const FormatException('Update target does not match.');
    }
    if (compareSemanticVersions(metadata.version, currentVersion) <= 0) {
      throw const FormatException('Update is a downgrade or replayed version.');
    }
    final maxBytes = metadata.kind == UpdateArtifactKind.androidApp
        ? _maxApkBytes
        : _maxExtensionBytes;
    if (metadata.artifactSize > maxBytes) {
      throw const FormatException('Update artifact is too large.');
    }
    final ledger = await _transactions.load();
    final appliedRevision =
        ledger.revisions[metadata.targetId]?['revision'] as int? ?? 0;
    if (metadata.revision <= appliedRevision) {
      throw const FormatException('Update revision was already applied.');
    }
    final signatureValid = await _signatureCheck(
      metadata.signedPayload,
      metadata.signature,
      metadata.signatureAlgorithm,
      metadata.keyId,
    );
    if (!signatureValid) {
      throw const FormatException('Update metadata signature is untrusted.');
    }
    return UpdateCheck(
      metadata: metadata,
      sourceIdentity: sourceIdentity,
      currentVersion: currentVersion,
      currentTrustDigest: currentTrustDigest,
      appliedRevision: appliedRevision,
    );
  }

  Future<ExtensionUpdatePlan> planExtensionUpdate(
    UpdateCheck check, {
    String? localArtifactPath,
    UpdateCancellationToken? cancellationToken,
  }) async {
    if (check.metadata.kind != UpdateArtifactKind.extension) {
      throw StateError('Extension update metadata required.');
    }
    return _transactions.run(check.metadata.targetId, () async {
      File? downloaded;
      PreparedSkillImport? candidate;
      try {
        final current = await _installedSkillSnapshotReader(
          check.metadata.targetId,
        );
        if (current == null) {
          throw StateError('Installed extension is unavailable.');
        }
        final ledger = await _transactions.load();
        final appliedRevision =
            ledger.revisions[current.id]?['revision'] as int? ?? 0;
        _validateExtensionPrecondition(check, current, appliedRevision);
        final deadline = _newDeadline();
        final artifactPath = localArtifactPath ??
            (downloaded = await _downloadVerifiedArtifact(
              check.metadata,
              cancellationToken: cancellationToken,
              deadline: deadline,
            ))
                .path;
        if (localArtifactPath != null) {
          await _verifyLocalArtifact(File(localArtifactPath), check.metadata);
        }
        _throwIfCancelled(cancellationToken);
        candidate = _withSourceIdentity(
          await _prepareLocalSkill(artifactPath),
          check.sourceIdentity,
        );
        _throwIfCancelled(cancellationToken);
        if (candidate.id != check.metadata.targetId ||
            candidate.version != check.metadata.version ||
            candidate.legacy ||
            candidate.manifest == null) {
          throw const FormatException(
            'Staged extension identity does not match signed metadata.',
          );
        }
        if (candidate.manifest!.capabilities.updatePolicy == 'disabled') {
          throw const FormatException('Staged extension disables updates.');
        }
        final planId = const Uuid().v4();
        final plan = ExtensionUpdatePlan._(
          planId: planId,
          check: check,
          candidate: candidate,
          precondition: UpdatePrecondition(
            version: current.version,
            trustDigest: current.trustDigest,
            revision: appliedRevision,
          ),
        );
        _activePlans[planId] = plan;
        return plan;
      } catch (_) {
        if (candidate != null) {
          await _discardPreparedSkill(candidate);
        }
        rethrow;
      } finally {
        if (downloaded != null) await _deleteBestEffort(downloaded);
      }
    });
  }

  Future<ExtensionUpdateState> applyExtensionUpdate(
    ExtensionUpdatePlan plan,
  ) async {
    return _transactions.run(plan.candidate.id, () async {
      if (!identical(_activePlans.remove(plan.planId), plan)) {
        throw StateError('Extension update plan is stale or already consumed.');
      }
      final current = await _installedSkillSnapshotReader(plan.candidate.id);
      final ledger = await _transactions.load();
      final appliedRevision =
          ledger.revisions[plan.candidate.id]?['revision'] as int? ?? 0;
      try {
        _validatePlanPrecondition(plan, current, appliedRevision);
      } catch (_) {
        await _discardPreparedSkill(plan.candidate);
        rethrow;
      }

      var transaction = DurableUpdateTransaction(
        transactionId: plan.planId,
        targetId: plan.candidate.id,
        phase: UpdateTransactionPhase.prepared,
        precondition: plan.precondition,
        targetVersion: plan.candidate.version,
        targetRevision: plan.check.metadata.revision,
        targetTrustDigest: plan.candidate.trustDigest,
        stagingPath: plan.candidate.stagingPath,
        targetPath: SkillService.updateTargetPath(plan.candidate.id),
        backupPath: SkillService.updateBackupPath(
          plan.candidate.id,
          transactionId: plan.planId,
        ),
        failedPath: SkillService.updateFailedPath(
          plan.candidate.id,
          plan.planId,
        ),
      );
      ledger.transactions[transaction.targetId] = transaction;
      await _transactions.save(ledger);
      await _injectFailure('afterMarker');

      try {
        final result = await _activatePreparedSkill(
          plan.candidate,
          transaction.backupPath,
          () async {
            transaction = transaction.withPhase(
              UpdateTransactionPhase.backupMoved,
            );
            ledger.transactions[transaction.targetId] = transaction;
            await _transactions.save(ledger);
            await _injectFailure('afterBackupMove');
          },
          () async {
            transaction = transaction.withPhase(
              UpdateTransactionPhase.newMoved,
            );
            ledger.transactions[transaction.targetId] = transaction;
            await _transactions.save(ledger);
            await _injectFailure('afterNewMove');
            await _injectFailure('afterLiveMove');
          },
        );
        await _injectFailure('afterActivation');
        if (result.backupPath != transaction.backupPath ||
            result.previousVersion != plan.precondition.version) {
          throw StateError('Extension update backup was not preserved.');
        }
        final activated = await _installedSkillSnapshotReader(
          plan.candidate.id,
        );
        if (activated == null ||
            activated.version != plan.candidate.version ||
            activated.trustDigest != plan.candidate.trustDigest) {
          throw StateError('Activated extension failed verification.');
        }
        transaction = transaction.withPhase(
          UpdateTransactionPhase.activatedVerified,
        );
        ledger.transactions[transaction.targetId] = transaction;
        await _transactions.save(ledger);
        await _injectFailure('afterVerification');
        final state = _stateFromTransaction(transaction);
        final previousRollback = _extensionStateFromLedger(
          ledger,
          transaction.targetId,
        );
        _commitExtensionTransaction(ledger, transaction, state);
        await _transactions.save(ledger);
        if (previousRollback != null &&
            previousRollback.backupPath != state.backupPath) {
          try {
            await _discardRecoveryPath(
              previousRollback.backupPath,
              transaction.targetId,
            );
          } catch (_) {
            // The new committed rollback remains authoritative and verified.
          }
        }
        return state;
      } on UpdateCrashSimulation {
        rethrow;
      } on SkillActivationCrashSimulation {
        rethrow;
      } catch (_) {
        await _recoverExtensionTransaction(transaction,
            rethrowOnFailure: false);
        rethrow;
      }
    });
  }

  Future<void> discardExtensionPlan(ExtensionUpdatePlan plan) async {
    await _transactions.run(plan.candidate.id, () async {
      if (!identical(_activePlans.remove(plan.planId), plan)) return;
      await _discardPreparedSkill(plan.candidate);
    });
  }

  Future<SkillRollbackResult> rollbackExtension(String id) async {
    return _transactions.run(id, () async {
      final ledger = await _transactions.load();
      final state = _extensionStateFromLedger(ledger, id);
      if (state == null) throw StateError('No verified rollback is available.');
      final backup = await _backupSkillSnapshotReader(state.backupPath, id);
      if (backup == null) {
        throw StateError('Verified rollback backup is unavailable.');
      }
      final rollbackId = const Uuid().v4();
      var currentTransaction = DurableUpdateTransaction(
        transactionId: rollbackId,
        targetId: id,
        phase: UpdateTransactionPhase.rollbackRequired,
        precondition: UpdatePrecondition(
          version: backup.version,
          trustDigest: backup.trustDigest,
          revision: state.revision,
        ),
        targetVersion: state.version,
        targetRevision: state.revision,
        targetTrustDigest: state.currentTrustDigest,
        stagingPath: state.backupPath,
        targetPath: SkillService.updateTargetPath(id),
        backupPath: state.backupPath,
        failedPath: SkillService.updateFailedPath(id, rollbackId),
      );
      ledger.transactions[id] = currentTransaction;
      await _transactions.save(ledger);
      try {
        final result = await _activatePreparedRollback(
          id: id,
          backupPath: state.backupPath,
          failedPath: currentTransaction.failedPath,
          expectedCurrentTrustDigest: state.currentTrustDigest,
          afterTargetMove: () async {
            currentTransaction = currentTransaction.withPhase(
              UpdateTransactionPhase.rollbackTargetMoved,
            );
            ledger.transactions[id] = currentTransaction;
            await _transactions.save(ledger);
            await _injectFailure('afterRollbackTargetMove');
          },
          afterBackupMove: () async {
            currentTransaction = currentTransaction.withPhase(
              UpdateTransactionPhase.rollbackBackupMoved,
            );
            ledger.transactions[id] = currentTransaction;
            await _transactions.save(ledger);
            await _injectFailure('afterRollbackBackupMove');
          },
        );
        ledger.extensionStates.remove(id);
        ledger.transactions.remove(id);
        await _transactions.save(ledger);
        return result;
      } catch (_) {
        // Retain rollbackRequired evidence for idempotent restart recovery.
        rethrow;
      }
    });
  }

  Future<AppUpdatePlan> planAppUpdate(
    UpdateCheck check, {
    UpdateCancellationToken? cancellationToken,
  }) async {
    if (check.metadata.kind != UpdateArtifactKind.androidApp) {
      throw StateError('Android app update metadata required.');
    }
    return _transactions.run(check.metadata.targetId, () async {
      final ledger = await _transactions.load();
      _validateAppPrecondition(check, ledger);
      final apk = await _downloadVerifiedArtifact(
        check.metadata,
        cancellationToken: cancellationToken,
        deadline: _newDeadline(),
      );
      try {
        _throwIfCancelled(cancellationToken);
        final planId = const Uuid().v4();
        final plan = AppUpdatePlan._(
          planId: planId,
          check: check,
          apkPath: apk.path,
        );
        _activePlans[planId] = plan;
        ledger.appStates[planId] = AppUpdateStagingState(
          targetId: check.metadata.targetId,
          version: check.metadata.version,
          revision: check.metadata.revision,
          sha256: check.metadata.artifactSha256,
          size: check.metadata.artifactSize,
          path: apk.path,
          stage: AppUpdateStage.verified,
          createdAt: _now().toIso8601String(),
        );
        await _transactions.save(ledger);
        await _pruneAppStaging(ledger, protectedPlanId: planId);
        await _transactions.save(ledger);
        await _cleanupVerifiedApks(ledger, protectedPaths: {apk.path});
        return plan;
      } catch (_) {
        await _deleteBestEffort(apk);
        rethrow;
      }
    });
  }

  Future<bool> handoffAppUpdate(AppUpdatePlan plan) async {
    return _transactions.run(plan.check.metadata.targetId, () async {
      if (!identical(_activePlans[plan.planId], plan)) {
        throw StateError('App update plan is stale or already discarded.');
      }
      final metadata = plan.check.metadata;
      final ledger = await _transactions.load();
      _validateAppPrecondition(plan.check, ledger, allowPendingSame: true);
      final state = ledger.appStates[plan.planId];
      if (state == null ||
          state.path != plan.apkPath ||
          state.version != metadata.version ||
          state.revision != metadata.revision ||
          state.sha256 != metadata.artifactSha256) {
        throw StateError('App update staging ownership changed.');
      }
      final now = _now();
      final activeGrants = ledger.appStates.entries.where((entry) {
        if (entry.key == plan.planId ||
            entry.value.stage != AppUpdateStage.handedOff) {
          return false;
        }
        final handedOffAt = DateTime.tryParse(entry.value.handedOffAt ?? '');
        return handedOffAt != null &&
            now.difference(handedOffAt) < _grantRetention;
      }).toList();
      final retainedBytes = activeGrants.fold<int>(
        metadata.artifactSize,
        (total, entry) => total + entry.value.size,
      );
      if (activeGrants.length >= _maxVerifiedApkCount ||
          retainedBytes > _maxApkBytes * 2) {
        throw StateError('Verified app update staging is at capacity.');
      }
      await _verifyLocalArtifact(File(plan.apkPath), metadata);
      final handedOff = await _apkHandoff(
        path: plan.apkPath,
        size: metadata.artifactSize,
        sha256: metadata.artifactSha256,
      );
      if (!handedOff) {
        throw StateError('System installer handoff was rejected.');
      }
      ledger.appStates[plan.planId] = state.withStage(
        AppUpdateStage.handedOff,
        handedOffAt: now.toIso8601String(),
      );
      await _transactions.save(ledger);
      return true;
    });
  }

  Future<void> discardAppPlan(AppUpdatePlan plan) async {
    await _transactions.run(plan.check.metadata.targetId, () async {
      if (!identical(_activePlans.remove(plan.planId), plan)) return;
      final ledger = await _transactions.load();
      final state = ledger.appStates[plan.planId];
      if (state?.path == plan.apkPath &&
          state?.stage == AppUpdateStage.verified) {
        ledger.appStates.remove(plan.planId);
        await _transactions.save(ledger);
        await _deleteBestEffort(File(plan.apkPath));
      }
    });
  }

  Future<String> _downloadText(
    Uri uri,
    UpdateCancellationToken? cancellationToken,
    DateTime deadline,
  ) async {
    final bytes = await _downloadBytes(
      uri,
      maxBytes: _maxMetadataBytes,
      expectedSize: null,
      destination: null,
      cancellationToken: cancellationToken,
      accept: 'application/json',
      deadline: deadline,
    );
    try {
      return const Utf8Decoder(allowMalformed: false).convert(bytes!);
    } on FormatException {
      throw const FormatException('Update metadata is not valid UTF-8.');
    }
  }

  Future<File> _downloadVerifiedArtifact(
    SignedUpdateMetadata metadata, {
    UpdateCancellationToken? cancellationToken,
    required DateTime deadline,
  }) async {
    final root = Directory('${(await _tempDirectoryProvider()).path}/updates');
    await root.create(recursive: true);
    await _cleanupPartialStaging(root);
    final suffix = metadata.kind == UpdateArtifactKind.androidApp
        ? '.apk'
        : _archiveSuffix(metadata.artifactUrl.path);
    final file = File('${root.path}/partial-${const Uuid().v4()}$suffix');
    try {
      await _downloadBytes(
        metadata.artifactUrl,
        maxBytes: metadata.kind == UpdateArtifactKind.androidApp
            ? _maxApkBytes
            : _maxExtensionBytes,
        expectedSize: metadata.artifactSize,
        destination: file,
        cancellationToken: cancellationToken,
        accept: 'application/octet-stream',
        deadline: deadline,
      );
      await _verifyLocalArtifact(file, metadata);
      final verified = File(
        '${root.path}/verified-${metadata.kind.name}-${metadata.revision}-'
        '${const Uuid().v4()}$suffix',
      );
      await file.rename(verified.path);
      return verified;
    } catch (_) {
      await _deleteBestEffort(file);
      rethrow;
    }
  }

  Future<List<int>?> _downloadBytes(
    Uri uri, {
    required int maxBytes,
    required int? expectedSize,
    required File? destination,
    required UpdateCancellationToken? cancellationToken,
    required String accept,
    required DateTime deadline,
  }) async {
    _validateHttpsUri(uri);
    _throwIfCancelled(cancellationToken);
    final abort = Completer<void>();
    final deadlineSignal = Completer<void>();
    final remaining = deadline.difference(_now());
    if (remaining <= Duration.zero) {
      throw TimeoutException('Update operation timed out.');
    }
    final deadlineTimer = Timer(remaining, () {
      if (!deadlineSignal.isCompleted) deadlineSignal.complete();
      if (!abort.isCompleted) abort.complete();
    });
    if (cancellationToken != null) {
      unawaited(cancellationToken.whenCancelled.then((_) {
        if (!abort.isCompleted) abort.complete();
      }));
    }
    final request = http.AbortableRequest(
      'GET',
      uri,
      abortTrigger: abort.future,
    )
      ..followRedirects = false
      ..persistentConnection = false
      ..headers[HttpHeaders.acceptHeader] = accept;
    final send = _client.send(request);
    unawaited(send.then((lateResponse) {
      if (cancellationToken?.isCancelled == true ||
          deadlineSignal.isCompleted) {
        return _cancelResponse(lateResponse);
      }
    }, onError: (Object _, StackTrace __) {}));
    late final http.StreamedResponse response;
    try {
      response = await Future.any<http.StreamedResponse>([
        send,
        deadlineSignal.future.then(
          (_) => throw TimeoutException('Update operation timed out.'),
        ),
        if (cancellationToken != null)
          cancellationToken.whenCancelled.then(
            (_) => throw StateError('Update cancelled.'),
          ),
      ]);
    } catch (_) {
      deadlineTimer.cancel();
      if (!abort.isCompleted) abort.complete();
      rethrow;
    }
    if (response.isRedirect ||
        const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
      await _cancelResponse(response);
      deadlineTimer.cancel();
      if (!abort.isCompleted) abort.complete();
      throw const FormatException('Update redirects are not allowed.');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await _cancelResponse(response);
      deadlineTimer.cancel();
      if (!abort.isCompleted) abort.complete();
      throw const FormatException('Update download failed.');
    }
    final declared = response.contentLength;
    if (declared != null &&
        (declared > maxBytes ||
            (expectedSize != null && declared != expectedSize))) {
      await _cancelResponse(response);
      deadlineTimer.cancel();
      if (!abort.isCompleted) abort.complete();
      throw const FormatException('Update download size is invalid.');
    }
    IOSink? sink;
    final output = destination == null ? <int>[] : null;
    var count = 0;
    final bodyDone = Completer<void>();
    StreamSubscription<List<int>>? subscription;
    try {
      if (destination != null) sink = destination.openWrite();
      void fail(Object error, StackTrace stackTrace) {
        if (bodyDone.isCompleted) return;
        bodyDone.completeError(error, stackTrace);
      }

      subscription = response.stream.listen(
        (chunk) {
          if (bodyDone.isCompleted) return;
          try {
            _throwIfCancelled(cancellationToken);
            count += chunk.length;
            if (count > maxBytes ||
                (expectedSize != null && count > expectedSize)) {
              throw const FormatException('Update download is oversized.');
            }
            sink?.add(chunk);
            output?.addAll(chunk);
          } catch (error, stackTrace) {
            fail(error, stackTrace);
            unawaited(subscription?.cancel() ?? Future<void>.value());
          }
        },
        onError: fail,
        onDone: () {
          if (!bodyDone.isCompleted) bodyDone.complete();
        },
        cancelOnError: true,
      );
      if (cancellationToken != null) {
        unawaited(cancellationToken.whenCancelled.then((_) async {
          if (bodyDone.isCompleted) return;
          if (!abort.isCompleted) abort.complete();
          try {
            await (subscription?.cancel() ?? Future<void>.value())
                .timeout(const Duration(milliseconds: 250));
          } catch (_) {
            // The logical operation still detaches fail closed.
          } finally {
            if (!bodyDone.isCompleted) {
              bodyDone.completeError(StateError('Update cancelled.'));
            }
          }
        }));
      }
      unawaited(deadlineSignal.future.then((_) async {
        if (bodyDone.isCompleted) return;
        try {
          await (subscription?.cancel() ?? Future<void>.value())
              .timeout(const Duration(milliseconds: 250));
        } catch (_) {
          // The shared client remains owned by the application.
        } finally {
          if (!bodyDone.isCompleted) {
            bodyDone.completeError(
              TimeoutException('Update operation timed out.'),
            );
          }
        }
      }));
      await bodyDone.future;
      if (count == 0 || (expectedSize != null && count != expectedSize)) {
        throw const FormatException('Update download is incomplete.');
      }
      await sink?.flush();
      await sink?.close();
      sink = null;
      return output;
    } finally {
      deadlineTimer.cancel();
      if (!abort.isCompleted) abort.complete();
      try {
        await (subscription?.cancel() ?? Future<void>.value())
            .timeout(const Duration(milliseconds: 250));
      } catch (_) {}
      if (sink != null) {
        try {
          await sink.close().timeout(const Duration(milliseconds: 250));
        } catch (_) {}
      }
    }
  }

  static Future<void> _cancelResponse(http.StreamedResponse response) async {
    final subscription = response.stream.listen(null);
    try {
      await subscription.cancel().timeout(const Duration(milliseconds: 250));
    } catch (_) {}
  }

  Future<void> _verifyLocalArtifact(
    File file,
    SignedUpdateMetadata metadata,
  ) async {
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file ||
        stat.size != metadata.artifactSize) {
      throw const FormatException('Update artifact size mismatch.');
    }
    final output = AccumulatorSink<Digest>();
    final input = sha256.startChunkedConversion(output);
    await for (final chunk in file.openRead()) {
      input.add(chunk);
    }
    input.close();
    if (output.events.single.toString() != metadata.artifactSha256) {
      throw const FormatException('Update artifact SHA-256 mismatch.');
    }
  }

  Future<void> _cleanupPartialStaging(Directory root) async {
    await for (final entity in root.list(followLinks: false)) {
      if (entity is File &&
          entity.path.split('/').last.startsWith('partial-')) {
        await _deleteBestEffort(entity);
      }
    }
  }

  Future<ExtensionUpdateState?> loadExtensionUpdateState(String id) async {
    return _extensionStateFromLedger(await _transactions.load(), id);
  }

  Future<AppUpdateStagingState?> loadAppUpdateState(String id) async {
    final states = (await _transactions.load())
        .appStates
        .values
        .where((state) => state.targetId == id)
        .toList()
      ..sort((a, b) => b.revision.compareTo(a.revision));
    return states.isEmpty ? null : states.first;
  }

  /// Explicit operator action; normal startup never overwrites corrupt state.
  Future<void> recoverCorruptLedgerFromLastKnownGood() =>
      _transactions.recoverLastKnownGood();

  /// Idempotently reconciles crash evidence and observes completed app installs.
  Future<void> reconcileAtStartup() async {
    final ledger = await _transactions.load();
    for (final id in ledger.transactions.keys.toList(growable: false)) {
      await _transactions.run(id, () async {
        final latest = await _transactions.load();
        final transaction = latest.transactions[id];
        if (transaction != null) {
          await _recoverExtensionTransaction(
            transaction,
            rethrowOnFailure: false,
          );
        }
      });
    }
    await _transactions.run(AppConstants.packageName, () async {
      final latest = await _transactions.load();
      final observedVersion = _installedAppVersionReader();
      final matches = latest.appStates.entries
          .where((entry) =>
              entry.value.targetId == AppConstants.packageName &&
              entry.value.stage != AppUpdateStage.installedObserved &&
              entry.value.version == observedVersion)
          .toList()
        ..sort((a, b) => b.value.revision.compareTo(a.value.revision));
      if (matches.isNotEmpty) {
        final entry = matches.first;
        final state = entry.value;
        latest.revisions[state.targetId] = {
          'version': state.version,
          'revision': state.revision,
        };
        latest.appStates[entry.key] = state.withStage(
          AppUpdateStage.installedObserved,
        );
        for (final pending in latest.appStates.entries.toList()) {
          if (pending.value.targetId != state.targetId) continue;
          await _deleteBestEffort(File(pending.value.path));
          if (pending.key != entry.key) latest.appStates.remove(pending.key);
        }
        await _transactions.save(latest);
        _activePlans.removeWhere(
          (_, value) => value is AppUpdatePlan && value.apkPath == state.path,
        );
      }
      await _pruneAppStaging(latest);
      await _transactions.save(latest);
      await _cleanupVerifiedApks(latest);
    });
  }

  void _validateExtensionPrecondition(
    UpdateCheck check,
    InstalledSkillUpdateSnapshot current,
    int appliedRevision,
  ) {
    if (current.version != check.currentVersion ||
        (check.currentTrustDigest != null &&
            current.trustDigest != check.currentTrustDigest) ||
        appliedRevision != check.appliedRevision ||
        check.metadata.revision <= appliedRevision ||
        compareSemanticVersions(check.metadata.version, current.version) <= 0) {
      throw StateError('Extension update check is stale.');
    }
  }

  void _validatePlanPrecondition(
    ExtensionUpdatePlan plan,
    InstalledSkillUpdateSnapshot? current,
    int appliedRevision,
  ) {
    if (current == null ||
        current.version != plan.precondition.version ||
        current.trustDigest != plan.precondition.trustDigest ||
        appliedRevision != plan.precondition.revision ||
        plan.check.metadata.revision <= appliedRevision ||
        compareSemanticVersions(plan.candidate.version, current.version) <= 0) {
      throw StateError('Extension update plan is stale.');
    }
  }

  void _validateAppPrecondition(
    UpdateCheck check,
    UpdateLedger ledger, {
    bool allowPendingSame = false,
  }) {
    final currentVersion = _installedAppVersionReader();
    final revision =
        ledger.revisions[check.metadata.targetId]?['revision'] as int? ?? 0;
    final pending = ledger.appStates.values
        .where((state) => state.targetId == check.metadata.targetId)
        .toList();
    final newestPendingRevision = pending.fold<int>(
      0,
      (highest, state) => state.revision > highest ? state.revision : highest,
    );
    if (currentVersion != check.currentVersion ||
        check.metadata.revision <= revision ||
        compareSemanticVersions(check.metadata.version, currentVersion) <= 0 ||
        (allowPendingSame && check.metadata.revision < newestPendingRevision)) {
      throw StateError('App update check is stale.');
    }
  }

  ExtensionUpdateState _stateFromTransaction(
    DurableUpdateTransaction transaction,
  ) =>
      ExtensionUpdateState(
        id: transaction.targetId,
        version: transaction.targetVersion,
        revision: transaction.targetRevision,
        currentTrustDigest: transaction.targetTrustDigest,
        backupPath: transaction.backupPath,
        updatedAt: _now().toIso8601String(),
      );

  ExtensionUpdateState? _extensionStateFromLedger(
    UpdateLedger ledger,
    String id,
  ) {
    final json = ledger.extensionStates[id];
    if (json == null) return null;
    try {
      return ExtensionUpdateState.fromJson(Map<String, dynamic>.from(json));
    } catch (_) {
      return null;
    }
  }

  void _commitExtensionTransaction(
    UpdateLedger ledger,
    DurableUpdateTransaction transaction,
    ExtensionUpdateState state,
  ) {
    ledger.extensionStates[state.id] = state.toJson();
    ledger.revisions[state.id] = {
      'version': state.version,
      'revision': state.revision,
    };
    ledger.transactions.remove(transaction.targetId);
  }

  Future<void> _recoverExtensionTransaction(
    DurableUpdateTransaction transaction, {
    required bool rethrowOnFailure,
  }) async {
    try {
      final ledger = await _transactions.load();
      final current = await _installedSkillSnapshotReader(transaction.targetId);
      final backup = await _backupSkillSnapshotReader(
        transaction.backupPath,
        transaction.targetId,
      );
      final isRollback = transaction.stagingPath == transaction.backupPath;
      final staging = isRollback
          ? null
          : await _stagingSkillSnapshotReader(
              transaction.stagingPath,
              transaction.targetId,
            );
      final failed = await _failedSkillSnapshotReader(
        transaction.failedPath,
        transaction.targetId,
      );
      bool isOld(InstalledSkillUpdateSnapshot? value) =>
          value != null &&
          value.version == transaction.precondition.version &&
          value.trustDigest == transaction.precondition.trustDigest;
      bool isNew(InstalledSkillUpdateSnapshot? value) =>
          value != null &&
          value.version == transaction.targetVersion &&
          value.trustDigest == transaction.targetTrustDigest;
      final knownCurrent = current == null || isOld(current) || isNew(current);
      final knownBackup = backup == null || isOld(backup);
      final knownStaging = staging == null || isNew(staging);
      final knownFailed = failed == null || isNew(failed);
      if (!knownCurrent || !knownBackup || !knownStaging || !knownFailed) {
        throw StateError('Extension update recovery layout is ambiguous.');
      }
      if (isRollback) {
        var active = transaction;
        if (isNew(current) && isOld(backup) && failed == null) {
          await _activatePreparedRollback(
            id: transaction.targetId,
            backupPath: transaction.backupPath,
            failedPath: transaction.failedPath,
            expectedCurrentTrustDigest: transaction.targetTrustDigest,
            afterTargetMove: () async {
              active = active.withPhase(
                UpdateTransactionPhase.rollbackTargetMoved,
              );
              ledger.transactions[transaction.targetId] = active;
              await _transactions.save(ledger);
            },
            afterBackupMove: () async {
              active = active.withPhase(
                UpdateTransactionPhase.rollbackBackupMoved,
              );
              ledger.transactions[transaction.targetId] = active;
              await _transactions.save(ledger);
            },
          );
        } else if (current == null && isOld(backup) && isNew(failed)) {
          await _restoreUpdateBackup(
            id: transaction.targetId,
            backupPath: transaction.backupPath,
            expectedBackupTrustDigest: transaction.precondition.trustDigest,
          );
          await _discardRecoveryPath(
            transaction.failedPath,
            transaction.targetId,
          );
        } else if (isOld(current) && backup == null) {
          if (isNew(failed)) {
            await _discardRecoveryPath(
              transaction.failedPath,
              transaction.targetId,
            );
          }
        } else if (current == null && backup == null && isNew(failed)) {
          await _restoreFailedUpdate(
            id: transaction.targetId,
            failedPath: transaction.failedPath,
            expectedTrustDigest: transaction.targetTrustDigest,
          );
          throw StateError(
              'Rollback backup was lost; updated extension restored.');
        } else {
          throw StateError('Extension rollback recovery layout is ambiguous.');
        }
        final restored = await _installedSkillSnapshotReader(
          transaction.targetId,
        );
        if (!isOld(restored)) {
          throw StateError('Recovered extension rollback did not verify.');
        }
        await _finalizeRecoveredRollback?.call(
          id: transaction.targetId,
          expectedTrustDigest: transaction.precondition.trustDigest,
        );
        ledger.extensionStates.remove(transaction.targetId);
        ledger.transactions.remove(transaction.targetId);
        await _transactions.save(ledger);
        return;
      }
      if (transaction.phase == UpdateTransactionPhase.activatedVerified &&
          isNew(current) &&
          isOld(backup)) {
        final state = _stateFromTransaction(transaction);
        final previousRollback = _extensionStateFromLedger(
          ledger,
          transaction.targetId,
        );
        _commitExtensionTransaction(ledger, transaction, state);
        await _transactions.save(ledger);
        if (previousRollback != null &&
            previousRollback.backupPath != state.backupPath) {
          try {
            await _discardRecoveryPath(
              previousRollback.backupPath,
              transaction.targetId,
            );
          } catch (_) {}
        }
        return;
      }
      if (isOld(current)) {
        if (isNew(failed)) {
          await _finalizeRecoveredRollback?.call(
            id: transaction.targetId,
            expectedTrustDigest: transaction.precondition.trustDigest,
          );
          await _discardRecoveryPath(
            transaction.failedPath,
            transaction.targetId,
          );
        }
        if (isNew(staging)) {
          await _discardRecoveryPath(
            transaction.stagingPath,
            transaction.targetId,
          );
        }
        if (isOld(backup)) {
          await _discardRecoveryPath(
            transaction.backupPath,
            transaction.targetId,
          );
        }
        ledger.transactions.remove(transaction.targetId);
        await _transactions.save(ledger);
        return;
      }
      if (current == null && isOld(backup)) {
        final restored = await _restoreUpdateBackup(
          id: transaction.targetId,
          backupPath: transaction.backupPath,
          expectedBackupTrustDigest: transaction.precondition.trustDigest,
        );
        if (!isOld(restored)) {
          throw StateError('Restored extension backup did not verify.');
        }
        if (isNew(failed)) {
          await _finalizeRecoveredRollback?.call(
            id: transaction.targetId,
            expectedTrustDigest: transaction.precondition.trustDigest,
          );
          await _discardRecoveryPath(
            transaction.failedPath,
            transaction.targetId,
          );
        }
        if (isNew(staging)) {
          await _discardRecoveryPath(
            transaction.stagingPath,
            transaction.targetId,
          );
        }
        ledger.transactions.remove(transaction.targetId);
        await _transactions.save(ledger);
        return;
      }
      if (isNew(current) && isOld(backup)) {
        await _activatePreparedRollback(
          id: transaction.targetId,
          backupPath: transaction.backupPath,
          failedPath: transaction.failedPath,
          expectedCurrentTrustDigest: transaction.targetTrustDigest,
          afterTargetMove: () async {
            ledger.transactions[transaction.targetId] = transaction.withPhase(
              UpdateTransactionPhase.rollbackTargetMoved,
            );
            await _transactions.save(ledger);
          },
          afterBackupMove: () async {
            ledger.transactions[transaction.targetId] = transaction.withPhase(
              UpdateTransactionPhase.rollbackBackupMoved,
            );
            await _transactions.save(ledger);
          },
        );
        final restored = await _installedSkillSnapshotReader(
          transaction.targetId,
        );
        if (!isOld(restored)) {
          throw StateError('Recovered extension rollback did not verify.');
        }
        await _finalizeRecoveredRollback?.call(
          id: transaction.targetId,
          expectedTrustDigest: transaction.precondition.trustDigest,
        );
        if (isNew(staging)) {
          await _discardRecoveryPath(
            transaction.stagingPath,
            transaction.targetId,
          );
        }
        ledger.transactions.remove(transaction.targetId);
        await _transactions.save(ledger);
        return;
      }
      if (current == null && backup == null && isNew(failed)) {
        await _restoreFailedUpdate(
          id: transaction.targetId,
          failedPath: transaction.failedPath,
          expectedTrustDigest: transaction.targetTrustDigest,
        );
      }
      ledger.transactions[transaction.targetId] = transaction.withPhase(
        UpdateTransactionPhase.rollbackRequired,
      );
      await _transactions.save(ledger);
      throw StateError('Extension update recovery requires rollback.');
    } catch (_) {
      try {
        final ledger = await _transactions.load();
        final current = ledger.transactions[transaction.targetId];
        if (current != null &&
            current.phase.index <
                UpdateTransactionPhase.rollbackTargetMoved.index) {
          ledger.transactions[transaction.targetId] = current.withPhase(
            UpdateTransactionPhase.rollbackRequired,
          );
          await _transactions.save(ledger);
        }
      } catch (_) {
        // Preserve the last successfully persisted recovery phase.
      }
      if (rethrowOnFailure) rethrow;
    }
  }

  Future<void> _cleanupVerifiedApks(
    UpdateLedger ledger, {
    Set<String> protectedPaths = const {},
  }) async {
    final root = Directory('${(await _tempDirectoryProvider()).path}/updates');
    if (!await root.exists()) return;
    final now = _now();
    final protected = <String>{
      ...protectedPaths,
      ..._activePlans.values
          .whereType<AppUpdatePlan>()
          .map((plan) => plan.apkPath),
    };
    for (final state in ledger.appStates.values) {
      final handedOffAt = DateTime.tryParse(state.handedOffAt ?? '');
      if (state.stage == AppUpdateStage.handedOff &&
          handedOffAt != null &&
          now.difference(handedOffAt) < _grantRetention) {
        protected.add(state.path);
      }
    }
    final files = <({File file, FileStat stat})>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! File ||
          !entity.path.split('/').last.startsWith('verified-') ||
          protected.contains(entity.path)) {
        continue;
      }
      final stat = await entity.stat();
      if (now.difference(stat.modified.toUtc()) > _maxVerifiedApkAge) {
        await _deleteBestEffort(entity);
      } else {
        files.add((file: entity, stat: stat));
      }
    }
    files.sort((a, b) => b.stat.modified.compareTo(a.stat.modified));
    var keptBytes = 0;
    for (var index = 0; index < files.length; index += 1) {
      keptBytes += files[index].stat.size;
      if (index >= _maxVerifiedApkCount || keptBytes > _maxApkBytes * 2) {
        await _deleteBestEffort(files[index].file);
      }
    }
  }

  Future<void> _pruneAppStaging(
    UpdateLedger ledger, {
    String? protectedPlanId,
  }) async {
    final now = _now();
    final entries = ledger.appStates.entries.toList()
      ..sort((a, b) {
        if (a.key == protectedPlanId) return -1;
        if (b.key == protectedPlanId) return 1;
        return b.value.createdAt.compareTo(a.value.createdAt);
      });
    final activeGrantKeys = <String>{};
    var retainedCount = 0;
    var retainedBytes = 0;
    for (final entry in entries) {
      final handedOffAt = DateTime.tryParse(entry.value.handedOffAt ?? '');
      if (entry.value.stage == AppUpdateStage.handedOff &&
          handedOffAt != null &&
          now.difference(handedOffAt) < _grantRetention) {
        activeGrantKeys.add(entry.key);
        retainedCount += 1;
        retainedBytes += entry.value.size;
      }
    }
    for (final entry in entries) {
      final state = entry.value;
      final createdAt = DateTime.tryParse(state.createdAt);
      final activeGrant = activeGrantKeys.contains(entry.key);
      if (activeGrant) continue;
      final expired =
          createdAt == null || now.difference(createdAt) > _maxVerifiedApkAge;
      final exceedsBounds = retainedCount >= _maxVerifiedApkCount ||
          retainedBytes + state.size > _maxApkBytes * 2;
      if (expired || exceedsBounds) {
        ledger.appStates.remove(entry.key);
        _activePlans.remove(entry.key);
        await _deleteBestEffort(File(state.path));
        continue;
      }
      retainedCount += 1;
      retainedBytes += state.size;
    }
  }

  DateTime _newDeadline() => _now().add(_operationTimeout);

  Future<void> _injectFailure(String point) async {
    await _failureInjector?.call(point);
  }

  static Uri _validatedMetadataUri(String? value) {
    if (value == null) {
      throw const FormatException('Extension has no update metadata URL.');
    }
    final uri = Uri.tryParse(value);
    if (uri == null) {
      throw const FormatException('Update metadata URL is invalid.');
    }
    _validateHttpsUri(uri);
    return uri;
  }

  static void _validateHttpsUri(Uri uri) {
    if (uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('Update URL must be credential-free HTTPS.');
    }
  }

  static String _remoteIdentity(Uri uri) =>
      'HTTPS: ${uri.replace(query: null, fragment: null)}';

  static String _archiveSuffix(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.tar.gz')) return '.tar.gz';
    if (lower.endsWith('.tgz')) return '.tgz';
    if (lower.endsWith('.zip')) return '.zip';
    throw const FormatException('Extension update must be an archive.');
  }

  static void _throwIfCancelled(UpdateCancellationToken? token) {
    if (token?.isCancelled == true) {
      throw StateError('Update cancelled.');
    }
  }

  static Future<void> _deleteBestEffort(FileSystemEntity entity) async {
    try {
      if (await entity.exists()) await entity.delete(recursive: true);
    } catch (_) {}
  }

  static PreparedSkillImport _withSourceIdentity(
    PreparedSkillImport candidate,
    String sourceIdentity,
  ) {
    return PreparedSkillImport(
      stagingPath: candidate.stagingPath,
      sourceIdentity: sourceIdentity,
      id: candidate.id,
      name: candidate.name,
      description: candidate.description,
      version: candidate.version,
      manifest: candidate.manifest,
      capabilitySnapshot: candidate.capabilitySnapshot,
      integrityStatus: candidate.integrityStatus,
      legacy: candidate.legacy,
      manifestDigest: candidate.manifestDigest,
      contentDigest: candidate.contentDigest,
      trustDigest: candidate.trustDigest,
      previousGrant: candidate.previousGrant,
      inspection: candidate.inspection,
      installedCandidate: candidate.installedCandidate,
    );
  }
}
