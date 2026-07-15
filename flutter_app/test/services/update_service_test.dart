import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clawchat/constants.dart';
import 'package:clawchat/models/extension_manifest.dart';
import 'package:clawchat/models/update_models.dart';
import 'package:clawchat/services/skill_service.dart';
import 'package:clawchat/services/update_service.dart';
import 'package:clawchat/services/update_transaction.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    temp = await Directory.systemTemp.createTemp('clawchat_update_test_');
  });
  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('strict signed metadata rejects unknown fields and bad signatures',
      () async {
    final bytes = utf8.encode('archive');
    final metadata = _metadata(
      kind: 'extension',
      targetId: 'com.example.demo',
      version: '2.0.0',
      revision: 1,
      artifactBytes: bytes,
    );
    expect(
      () => SignedUpdateMetadata.fromJson({...metadata, 'extra': true}),
      throwsFormatException,
    );
    final service =
        UpdateService(signatureCheck: (_, __, ___, ____) async => false);
    await expectLater(
      service.checkLocalMetadata(
        jsonEncode(metadata),
        expectedKind: UpdateArtifactKind.extension,
        expectedTargetId: 'com.example.demo',
        currentVersion: '1.0.0',
        sourceIdentity: 'Local metadata: update.json',
      ),
      throwsFormatException,
    );
  });

  test('downgrades and same-version replays fail before artifact work',
      () async {
    expect(compareSemanticVersions('1.0.0-10', '1.0.0-2'), greaterThan(0));
    expect(compareSemanticVersions('1.0.0', '1.0.0-99'), greaterThan(0));
    final service = _service(temp: temp);
    for (final version in const ['1.0.0', '0.9.0']) {
      await expectLater(
        service.checkLocalMetadata(
          jsonEncode(_metadata(
            kind: 'extension',
            targetId: 'com.example.demo',
            version: version,
            revision: 1,
            artifactBytes: const [1],
          )),
          expectedKind: UpdateArtifactKind.extension,
          expectedTargetId: 'com.example.demo',
          currentVersion: '1.0.0',
          sourceIdentity: 'Local metadata: update.json',
        ),
        throwsFormatException,
      );
    }
  });

  test('extension plan verifies bytes and exposes capability escalation',
      () async {
    final bytes = utf8.encode('verified extension archive');
    final artifact = File('${temp.path}/update.zip')..writeAsBytesSync(bytes);
    final candidate = _candidate(version: '2.0.0', withPreviousGrant: true);
    final service = _service(
      temp: temp,
      prepareLocalSkill: (_) async => candidate,
    );
    final check = await service.checkLocalMetadata(
      jsonEncode(_metadata(
        kind: 'extension',
        targetId: candidate.id,
        version: candidate.version,
        revision: 1,
        artifactBytes: bytes,
      )),
      expectedKind: UpdateArtifactKind.extension,
      expectedTargetId: candidate.id,
      currentVersion: '1.0.0',
      sourceIdentity: 'Local metadata: update.json',
    );

    final plan = await service.planExtensionUpdate(
      check,
      localArtifactPath: artifact.path,
    );
    expect(plan.capabilityDiff?.added, contains('Command: curl'));
    await service.discardExtensionPlan(plan);
    expect(await service.loadExtensionUpdateState(candidate.id), isNull);
  });

  test(
      'remote extension check and plan use signed metadata then bounded archive',
      () async {
    final archive = utf8.encode('remote extension archive');
    final metadata = jsonEncode(_metadata(
      kind: 'extension',
      targetId: 'com.example.demo',
      version: '2.0.0',
      revision: 4,
      artifactBytes: archive,
    ));
    final client = _QueueClient([
      (_) => http.StreamedResponse(Stream.value(utf8.encode(metadata)), 200,
          contentLength: utf8.encode(metadata).length),
      (_) => http.StreamedResponse(Stream.value(archive), 200,
          contentLength: archive.length),
    ]);
    final candidate = _candidate(version: '2.0.0');
    final manifest = ExtensionManifest.fromJson(_manifest(version: '1.0.0'));
    final installed = SkillInfo(
      id: manifest.id,
      name: manifest.name,
      description: manifest.description,
      path: '/root/workspace/skills/com.example.demo/SKILL.md',
      version: manifest.version,
      riskTier: manifest.capabilities.riskTier,
      legacy: false,
      valid: true,
      consentCurrent: true,
      storedEnabled: true,
      capabilitySnapshot: manifest.capabilities.snapshot,
      enabled: true,
      manifest: manifest,
    );
    final service = _service(
      temp: temp,
      client: client,
      prepareLocalSkill: (_) async => candidate,
    );

    final check = await service.checkExtensionUpdate(installed);
    expect(check.sourceIdentity, 'HTTPS: https://updates.example/update.json');
    final plan = await service.planExtensionUpdate(check);
    expect(plan.candidate.id, installed.id);
    expect(plan.candidate.sourceIdentity,
        'HTTPS: https://updates.example/update.json');
    expect(client.requestCount, 2);
    await service.discardExtensionPlan(plan);
  });

  test('tampered local artifact is rejected without install or grant mutation',
      () async {
    final expected = utf8.encode('expected');
    final artifact = File('${temp.path}/tampered.zip')
      ..writeAsBytesSync(utf8.encode('tampered'));
    var prepareCalls = 0;
    final service = _service(
      temp: temp,
      prepareLocalSkill: (_) async {
        prepareCalls += 1;
        return _candidate(version: '2.0.0');
      },
    );
    final check = await service.checkLocalMetadata(
      jsonEncode(_metadata(
        kind: 'extension',
        targetId: 'com.example.demo',
        version: '2.0.0',
        revision: 1,
        artifactBytes: expected,
      )),
      expectedKind: UpdateArtifactKind.extension,
      expectedTargetId: 'com.example.demo',
      currentVersion: '1.0.0',
      sourceIdentity: 'Local metadata: update.json',
    );
    await expectLater(
      service.planExtensionUpdate(check, localArtifactPath: artifact.path),
      throwsFormatException,
    );
    expect(prepareCalls, 0);
    expect(await service.loadExtensionUpdateState('com.example.demo'), isNull);
  });

  test('apply persists sanitized revision and rollback failure keeps state',
      () async {
    final bytes = utf8.encode('extension');
    final artifact = File('${temp.path}/update.zip')..writeAsBytesSync(bytes);
    final candidate = _candidate(version: '2.0.0');
    var installs = 0;
    final service = _service(
      temp: temp,
      prepareLocalSkill: (_) async => candidate,
      installPreparedSkill: (_) async {
        installs += 1;
        return const SkillInstallResult(
          targetPath: '/root/workspace/skills/com.example.demo',
          backupPath: '/root/workspace/.skill-update-backups/com.example.demo',
          previousVersion: '1.0.0',
        );
      },
      rollbackInstalledSkill: ({
        required id,
        required backupPath,
        required expectedCurrentTrustDigest,
      }) async {
        throw StateError('injected rollback failure');
      },
    );
    final check = await service.checkLocalMetadata(
      jsonEncode(_metadata(
        kind: 'extension',
        targetId: candidate.id,
        version: candidate.version,
        revision: 7,
        artifactBytes: bytes,
      )),
      expectedKind: UpdateArtifactKind.extension,
      expectedTargetId: candidate.id,
      currentVersion: '1.0.0',
      sourceIdentity: 'Local metadata: update.json',
    );
    final plan = await service.planExtensionUpdate(
      check,
      localArtifactPath: artifact.path,
    );
    final state = await service.applyExtensionUpdate(plan);
    expect(installs, 1);
    expect(state.revision, 7);
    final persisted = (await SharedPreferences.getInstance())
        .getString(UpdateTransactionCoordinator.storageKey)!;
    expect(persisted, isNot(contains('signature')));
    expect(persisted, isNot(contains('artifactUrl')));

    await expectLater(
      service.rollbackExtension(candidate.id),
      throwsStateError,
    );
    expect(await service.loadExtensionUpdateState(candidate.id), isNotNull);
  });

  test('applied revision rejects replay even with a newer version', () async {
    final bytes = utf8.encode('extension');
    final artifact = File('${temp.path}/update.zip')..writeAsBytesSync(bytes);
    final candidate = _candidate(version: '2.0.0');
    final service = _service(
      temp: temp,
      prepareLocalSkill: (_) async => candidate,
      installPreparedSkill: (_) async => const SkillInstallResult(
        targetPath: '/root/workspace/skills/com.example.demo',
        backupPath: '/root/workspace/.skill-update-backups/com.example.demo',
        previousVersion: '1.0.0',
      ),
    );
    final first = await service.checkLocalMetadata(
      jsonEncode(_metadata(
        kind: 'extension',
        targetId: candidate.id,
        version: candidate.version,
        revision: 3,
        artifactBytes: bytes,
      )),
      expectedKind: UpdateArtifactKind.extension,
      expectedTargetId: candidate.id,
      currentVersion: '1.0.0',
      sourceIdentity: 'Local metadata: update.json',
    );
    await service.applyExtensionUpdate(await service.planExtensionUpdate(
      first,
      localArtifactPath: artifact.path,
    ));
    await expectLater(
      service.checkLocalMetadata(
        jsonEncode(_metadata(
          kind: 'extension',
          targetId: candidate.id,
          version: '3.0.0',
          revision: 3,
          artifactBytes: bytes,
        )),
        expectedKind: UpdateArtifactKind.extension,
        expectedTargetId: candidate.id,
        currentVersion: '2.0.0',
        sourceIdentity: 'Local metadata: update.json',
      ),
      throwsFormatException,
    );
  });

  test('successful rollback removes the consumed durable rollback state',
      () async {
    final bytes = utf8.encode('extension');
    final artifact = File('${temp.path}/update.zip')..writeAsBytesSync(bytes);
    final candidate = _candidate(version: '2.0.0');
    var rollbackCalls = 0;
    final service = _service(
      temp: temp,
      prepareLocalSkill: (_) async => candidate,
      installPreparedSkill: (_) async => const SkillInstallResult(
        targetPath: '/root/workspace/skills/com.example.demo',
        backupPath: '/root/workspace/.skill-update-backups/com.example.demo',
        previousVersion: '1.0.0',
      ),
      rollbackInstalledSkill: ({
        required id,
        required backupPath,
        required expectedCurrentTrustDigest,
      }) async {
        rollbackCalls += 1;
        return SkillRollbackResult(
          restoredVersion: '1.0.0',
          restoredTrustDigest: 'd' * 64,
        );
      },
    );
    final check = await service.checkLocalMetadata(
      jsonEncode(_metadata(
        kind: 'extension',
        targetId: candidate.id,
        version: candidate.version,
        revision: 2,
        artifactBytes: bytes,
      )),
      expectedKind: UpdateArtifactKind.extension,
      expectedTargetId: candidate.id,
      currentVersion: '1.0.0',
      sourceIdentity: 'Local metadata: update.json',
    );
    await service.applyExtensionUpdate(await service.planExtensionUpdate(
      check,
      localArtifactPath: artifact.path,
    ));

    final result = await service.rollbackExtension(candidate.id);
    expect(result.restoredVersion, '1.0.0');
    expect(rollbackCalls, 1);
    expect(await service.loadExtensionUpdateState(candidate.id), isNull);
  });

  test('rollback rename interruptions converge on restart and double recovery',
      () async {
    const id = 'com.example.demo';
    final old = InstalledSkillUpdateSnapshot(
      id: id,
      version: '1.0.0',
      trustDigest: 'b' * 64,
    );
    final newer = InstalledSkillUpdateSnapshot(
      id: id,
      version: '2.0.0',
      trustDigest: 'c' * 64,
    );
    for (final crashPoint in const [
      'beforeRollbackTargetPhase',
      'afterRollbackTargetMove',
      'beforeRollbackBackupPhase',
      'afterRollbackBackupMove',
    ]) {
      SharedPreferences.setMockInitialValues({});
      final seed = UpdateTransactionCoordinator();
      final ledger = await seed.load();
      ledger.revisions[id] = {'version': newer.version, 'revision': 5};
      ledger.extensionStates[id] = ExtensionUpdateState(
        id: id,
        version: newer.version,
        revision: 5,
        currentTrustDigest: newer.trustDigest,
        backupPath: SkillService.updateBackupPath(id),
        updatedAt: DateTime.utc(2026).toIso8601String(),
      ).toJson();
      await seed.save(ledger);

      InstalledSkillUpdateSnapshot? target = newer;
      InstalledSkillUpdateSnapshot? backup = old;
      InstalledSkillUpdateSnapshot? failed;
      Future<SkillRollbackResult> activate({
        required String id,
        required String backupPath,
        required String failedPath,
        required String expectedCurrentTrustDigest,
        required Future<void> Function() afterTargetMove,
        required Future<void> Function() afterBackupMove,
      }) async {
        failed = target;
        target = null;
        if (crashPoint == 'beforeRollbackTargetPhase') {
          throw const SkillActivationCrashSimulation();
        }
        await afterTargetMove();
        target = backup;
        backup = null;
        if (crashPoint == 'beforeRollbackBackupPhase') {
          throw const SkillActivationCrashSimulation();
        }
        await afterBackupMove();
        failed = null;
        return SkillRollbackResult(
          restoredVersion: old.version,
          restoredTrustDigest: old.trustDigest,
        );
      }

      UpdateService service({bool crashing = false}) => UpdateService(
            signatureCheck: (_, __, ___, ____) async => true,
            tempDirectoryProvider: () async => temp,
            installedSkillSnapshotReader: (_) async => target,
            backupSkillSnapshotReader: (_, __) async => backup,
            failedSkillSnapshotReader: (path, _) async =>
                path.contains('.skill-update-failures') ? failed : null,
            activatePreparedRollback: activate,
            finalizeRecoveredRollback: ({
              required id,
              required expectedTrustDigest,
            }) async =>
                SkillRollbackResult(
              restoredVersion: old.version,
              restoredTrustDigest: expectedTrustDigest,
            ),
            restoreUpdateBackup: ({
              required id,
              required backupPath,
              required expectedBackupTrustDigest,
            }) async {
              target = backup;
              backup = null;
              return target!;
            },
            restoreFailedUpdate: ({
              required id,
              required failedPath,
              required expectedTrustDigest,
            }) async {
              target = failed;
              failed = null;
              return target!;
            },
            discardRecoveryPath: (path, _) async {
              if (path.contains('.skill-update-failures')) failed = null;
            },
            failureInjector: crashing
                ? (point) async {
                    if (point == crashPoint) {
                      throw UpdateCrashSimulation(point);
                    }
                  }
                : null,
          );

      await expectLater(
        service(crashing: true).rollbackExtension(id),
        throwsA(anyOf(
          isA<UpdateCrashSimulation>(),
          isA<SkillActivationCrashSimulation>(),
        )),
      );
      final recovering = service();
      await recovering.reconcileAtStartup();
      await recovering.reconcileAtStartup();
      final recovered = await seed.load();
      expect(target?.trustDigest, old.trustDigest, reason: crashPoint);
      expect(backup, isNull, reason: crashPoint);
      expect(failed, isNull, reason: crashPoint);
      expect(recovered.transactions, isEmpty, reason: crashPoint);
      expect(recovered.extensionStates[id], isNull, reason: crashPoint);
    }
  });

  test(
      'rollback with lost backup restores new live object but retains evidence',
      () async {
    const id = 'com.example.demo';
    const transactionId = '12345678-1234-4123-8123-123456789abc';
    final newer = InstalledSkillUpdateSnapshot(
      id: id,
      version: '2.0.0',
      trustDigest: 'c' * 64,
    );
    final coordinator = UpdateTransactionCoordinator();
    final ledger = await coordinator.load();
    ledger.transactions[id] = DurableUpdateTransaction(
      transactionId: transactionId,
      targetId: id,
      phase: UpdateTransactionPhase.rollbackTargetMoved,
      precondition: UpdatePrecondition(
        version: '1.0.0',
        trustDigest: 'b' * 64,
        revision: 5,
      ),
      targetVersion: newer.version,
      targetRevision: 5,
      targetTrustDigest: newer.trustDigest,
      stagingPath: SkillService.updateBackupPath(id),
      targetPath: SkillService.updateTargetPath(id),
      backupPath: SkillService.updateBackupPath(id),
    );
    await coordinator.save(ledger);
    InstalledSkillUpdateSnapshot? target;
    InstalledSkillUpdateSnapshot? failed = newer;
    final service = UpdateService(
      signatureCheck: (_, __, ___, ____) async => true,
      tempDirectoryProvider: () async => temp,
      installedSkillSnapshotReader: (_) async => target,
      backupSkillSnapshotReader: (_, __) async => null,
      failedSkillSnapshotReader: (path, _) async =>
          path.contains('.skill-update-failures') ? failed : null,
      restoreFailedUpdate: ({
        required id,
        required failedPath,
        required expectedTrustDigest,
      }) async {
        target = failed;
        failed = null;
        return target!;
      },
    );
    await service.reconcileAtStartup();
    await service.reconcileAtStartup();
    final recovered = await coordinator.load();
    expect(target?.trustDigest, newer.trustDigest);
    expect(failed, isNull);
    expect(
      recovered.transactions[id]?.phase,
      UpdateTransactionPhase.rollbackTargetMoved,
    );
  });

  test('verified APK is handed off once and stale partial staging is removed',
      () async {
    final apk = utf8.encode('verified apk bytes');
    final updateRoot = Directory('${temp.path}/updates')..createSync();
    final stale = File('${updateRoot.path}/partial-crash.apk')
      ..writeAsStringSync('partial');
    var handoffs = 0;
    final client = _QueueClient([
      (_) => http.StreamedResponse(Stream.value(apk), 200,
          contentLength: apk.length),
    ]);
    final service = _service(
      temp: temp,
      client: client,
      apkHandoff: ({required path, required size, required sha256}) async {
        handoffs += 1;
        expect(await File(path).length(), size);
        return true;
      },
    );
    final metadata = _metadata(
      kind: 'androidApp',
      targetId: AppConstants.packageName,
      version: '2.9.0',
      revision: 1,
      artifactBytes: apk,
      artifactUrl: 'https://updates.example/app.apk',
    );
    final check = await service.checkLocalMetadata(
      jsonEncode(metadata),
      expectedKind: UpdateArtifactKind.androidApp,
      expectedTargetId: AppConstants.packageName,
      currentVersion: AppConstants.version,
      sourceIdentity: 'Local metadata: app.json',
    );
    final plan = await service.planAppUpdate(check);
    expect(await stale.exists(), isFalse);
    expect(await service.handoffAppUpdate(plan), isTrue);
    expect(await service.handoffAppUpdate(plan), isTrue);
    expect(handoffs, 2);
    expect(
      (await service.loadAppUpdateState(AppConstants.packageName))?.stage,
      AppUpdateStage.handedOff,
    );
  });

  test('redirect and oversized streamed artifact fail closed', () async {
    const expected = [1, 2, 3];
    for (final response in [
      http.StreamedResponse(const Stream.empty(), 302,
          headers: {'location': 'https://updates.example/other.apk'}),
      http.StreamedResponse(Stream.value(const [1, 2, 3, 4]), 200),
    ]) {
      final service = _service(
        temp: temp,
        client: _QueueClient([(_) => response]),
      );
      final check = await service.checkLocalMetadata(
        jsonEncode(_metadata(
          kind: 'androidApp',
          targetId: AppConstants.packageName,
          version: '2.9.0',
          revision: 1,
          artifactBytes: expected,
          artifactUrl: 'https://updates.example/app.apk',
        )),
        expectedKind: UpdateArtifactKind.androidApp,
        expectedTargetId: AppConstants.packageName,
        currentVersion: AppConstants.version,
        sourceIdentity: 'Local metadata: app.json',
      );
      await expectLater(service.planAppUpdate(check), throwsFormatException);
    }
  });

  test('cancellation settles a stalled download and removes partial file',
      () async {
    final controller = StreamController<List<int>>();
    final service = _service(
      temp: temp,
      client: _QueueClient([
        (_) => http.StreamedResponse(controller.stream, 200),
      ]),
    );
    const bytes = [1, 2, 3];
    final check = await service.checkLocalMetadata(
      jsonEncode(_metadata(
        kind: 'androidApp',
        targetId: AppConstants.packageName,
        version: '2.9.0',
        revision: 1,
        artifactBytes: bytes,
        artifactUrl: 'https://updates.example/app.apk',
      )),
      expectedKind: UpdateArtifactKind.androidApp,
      expectedTargetId: AppConstants.packageName,
      currentVersion: AppConstants.version,
      sourceIdentity: 'Local metadata: app.json',
    );
    final token = UpdateCancellationToken();
    final result = service.planAppUpdate(check, cancellationToken: token);
    await Future<void>.delayed(Duration.zero);
    controller.add([1]);
    await Future<void>.delayed(Duration.zero);
    token.cancel();
    await expectLater(
      result.timeout(const Duration(seconds: 2)),
      throwsStateError,
    );
    final updateRoot = Directory('${temp.path}/updates');
    final leftovers = await updateRoot
        .list()
        .where((entity) => entity.path.contains('partial-'))
        .toList();
    expect(leftovers, isEmpty);
    unawaited(controller.close());
  });

  test('out-of-order extension plan cannot replace a newer committed update',
      () async {
    final bytes = utf8.encode('extension');
    final artifact = File('${temp.path}/update.zip')..writeAsBytesSync(bytes);
    final candidates = [
      _candidate(version: '2.0.0'),
      _candidate(version: '3.0.0')
    ];
    var installed = InstalledSkillUpdateSnapshot(
      id: 'com.example.demo',
      version: '1.0.0',
      trustDigest: 'b' * 64,
    );
    var installs = 0;
    final service = UpdateService(
      signatureCheck: (_, __, ___, ____) async => true,
      tempDirectoryProvider: () async => temp,
      prepareLocalSkill: (_) async => candidates.removeAt(0),
      discardPreparedSkill: (_) async {},
      installedSkillSnapshotReader: (_) async => installed,
      installPreparedSkill: (candidate) async {
        installs += 1;
        installed = InstalledSkillUpdateSnapshot(
          id: candidate.id,
          version: candidate.version,
          trustDigest: candidate.trustDigest,
        );
        return SkillInstallResult(
          targetPath: SkillService.updateTargetPath(candidate.id),
          backupPath: SkillService.updateBackupPath(candidate.id),
          previousVersion: '1.0.0',
        );
      },
    );
    Future<UpdateCheck> check(String version, int revision) =>
        service.checkLocalMetadata(
          jsonEncode(_metadata(
            kind: 'extension',
            targetId: installed.id,
            version: version,
            revision: revision,
            artifactBytes: bytes,
          )),
          expectedKind: UpdateArtifactKind.extension,
          expectedTargetId: installed.id,
          currentVersion: '1.0.0',
          sourceIdentity: 'Local metadata: update.json',
        );

    final v2 = await service.planExtensionUpdate(
      await check('2.0.0', 2),
      localArtifactPath: artifact.path,
    );
    final v3 = await service.planExtensionUpdate(
      await check('3.0.0', 3),
      localArtifactPath: artifact.path,
    );
    final committed = await service.applyExtensionUpdate(v3);
    await expectLater(service.applyExtensionUpdate(v2), throwsStateError);

    expect(committed.revision, 3);
    expect(installed.version, '3.0.0');
    expect(installs, 1);
    expect((await service.loadExtensionUpdateState(installed.id))?.revision, 3);
  });

  for (final crashPoint in const [
    'afterMarker',
    'afterBackupMove',
    'afterNewMove',
    'afterLiveMove',
    'afterActivation',
    'afterVerification',
  ]) {
    test('restart recovery is idempotent for $crashPoint', () async {
      final bytes = utf8.encode('extension');
      final artifact = File('${temp.path}/update.zip')..writeAsBytesSync(bytes);
      final candidate = _candidate(version: '2.0.0');
      final old = InstalledSkillUpdateSnapshot(
        id: candidate.id,
        version: '1.0.0',
        trustDigest: 'b' * 64,
      );
      InstalledSkillUpdateSnapshot? installed = old;
      InstalledSkillUpdateSnapshot? backup;
      InstalledSkillUpdateSnapshot? staging = InstalledSkillUpdateSnapshot(
        id: candidate.id,
        version: candidate.version,
        trustDigest: candidate.trustDigest,
      );
      var rollbacks = 0;
      var restores = 0;
      Future<SkillRollbackResult> rollback({
        required String id,
        required String backupPath,
        required String expectedCurrentTrustDigest,
      }) async {
        rollbacks += 1;
        installed = old;
        backup = null;
        return SkillRollbackResult(
          restoredVersion: old.version,
          restoredTrustDigest: old.trustDigest,
        );
      }

      UpdateService service({UpdateFailureInjector? failureInjector}) =>
          UpdateService(
            signatureCheck: (_, __, ___, ____) async => true,
            tempDirectoryProvider: () async => temp,
            prepareLocalSkill: (_) async => candidate,
            discardPreparedSkill: (_) async {},
            installedSkillSnapshotReader: (_) async => installed,
            backupSkillSnapshotReader: (_, __) async => backup,
            stagingSkillSnapshotReader: (_, __) async => staging,
            activatePreparedSkill: (
              value,
              backupPath,
              afterBackupMove,
              afterNewMove,
            ) async {
              backup = installed;
              installed = null;
              await afterBackupMove();
              installed = staging;
              staging = null;
              await afterNewMove();
              return SkillInstallResult(
                targetPath: SkillService.updateTargetPath(value.id),
                backupPath: backupPath,
                previousVersion: old.version,
              );
            },
            restoreUpdateBackup: ({
              required id,
              required backupPath,
              required expectedBackupTrustDigest,
            }) async {
              restores += 1;
              installed = backup;
              backup = null;
              return installed!;
            },
            discardRecoveryPath: (path, id) async {
              if (path.contains('/.skill-update-backups/$id')) {
                backup = null;
              } else {
                staging = null;
              }
            },
            rollbackInstalledSkill: rollback,
            failureInjector: failureInjector,
          );

      final crashing = service(
        failureInjector: (point) async {
          if (point == crashPoint) {
            if (point == 'afterLiveMove') {
              throw const SkillActivationCrashSimulation();
            }
            throw UpdateCrashSimulation(point);
          }
        },
      );
      final check = await crashing.checkLocalMetadata(
        jsonEncode(_metadata(
          kind: 'extension',
          targetId: candidate.id,
          version: candidate.version,
          revision: 5,
          artifactBytes: bytes,
        )),
        expectedKind: UpdateArtifactKind.extension,
        expectedTargetId: candidate.id,
        currentVersion: old.version,
        sourceIdentity: 'Local metadata: update.json',
      );
      final plan = await crashing.planExtensionUpdate(
        check,
        localArtifactPath: artifact.path,
      );
      await expectLater(
        crashing.applyExtensionUpdate(plan),
        throwsA(
          crashPoint == 'afterLiveMove'
              ? isA<SkillActivationCrashSimulation>()
              : isA<UpdateCrashSimulation>(),
        ),
      );

      final recovering = service();
      await recovering.reconcileAtStartup();
      await recovering.reconcileAtStartup();
      final ledger = UpdateLedger.parse(
        (await SharedPreferences.getInstance())
            .getString(UpdateTransactionCoordinator.storageKey),
      );
      expect(ledger.transactions, isEmpty);
      if (crashPoint == 'afterVerification') {
        expect(installed?.version, candidate.version);
        expect(ledger.revisions[candidate.id]?['revision'], 5);
        expect(rollbacks, 0);
      } else {
        expect(installed?.version, old.version);
        expect(ledger.revisions[candidate.id], isNull);
        expect(
          rollbacks,
          const {'afterNewMove', 'afterLiveMove', 'afterActivation'}
                  .contains(crashPoint)
              ? 1
              : 0,
        );
        expect(restores, crashPoint == 'afterBackupMove' ? 1 : 0);
      }
      final persisted = (await SharedPreferences.getInstance())
          .getString(UpdateTransactionCoordinator.storageKey)!;
      expect(persisted, isNot(contains('artifactUrl')));
      expect(persisted, isNot(contains('signature')));
    });
  }

  test('recovery handles missing target, leftovers, and ambiguous layouts',
      () async {
    final old = InstalledSkillUpdateSnapshot(
      id: 'com.example.demo',
      version: '1.0.0',
      trustDigest: 'b' * 64,
    );
    final newer = InstalledSkillUpdateSnapshot(
      id: old.id,
      version: '2.0.0',
      trustDigest: 'c' * 64,
    );
    final transaction = DurableUpdateTransaction(
      transactionId: '12345678-1234-4123-8123-123456789abc',
      targetId: old.id,
      phase: UpdateTransactionPhase.backupMoved,
      precondition: UpdatePrecondition(
        version: old.version,
        trustDigest: old.trustDigest,
        revision: 0,
      ),
      targetVersion: newer.version,
      targetRevision: 2,
      targetTrustDigest: newer.trustDigest,
      stagingPath: '/root/workspace/.skill-import-staging/layout-test/package',
      targetPath: SkillService.updateTargetPath(old.id),
      backupPath: SkillService.updateBackupPath(old.id),
    );

    Future<UpdateLedger> runLayout({
      required InstalledSkillUpdateSnapshot? initialTarget,
      required InstalledSkillUpdateSnapshot? initialBackup,
      required InstalledSkillUpdateSnapshot? initialStaging,
    }) async {
      SharedPreferences.setMockInitialValues({});
      final seed = UpdateTransactionCoordinator();
      final ledger = await seed.load();
      ledger.transactions[old.id] = transaction;
      await seed.save(ledger);
      var target = initialTarget;
      var backup = initialBackup;
      var staging = initialStaging;
      final service = UpdateService(
        signatureCheck: (_, __, ___, ____) async => true,
        tempDirectoryProvider: () async => temp,
        installedSkillSnapshotReader: (_) async => target,
        backupSkillSnapshotReader: (_, __) async => backup,
        stagingSkillSnapshotReader: (_, __) async => staging,
        restoreUpdateBackup: ({
          required id,
          required backupPath,
          required expectedBackupTrustDigest,
        }) async {
          target = backup;
          backup = null;
          return target!;
        },
        discardRecoveryPath: (path, id) async {
          if (path.contains('/.skill-update-backups/$id')) {
            backup = null;
          } else {
            staging = null;
          }
        },
      );
      await service.reconcileAtStartup();
      await service.reconcileAtStartup();
      return UpdateLedger.parse(
        (await SharedPreferences.getInstance())
            .getString(UpdateTransactionCoordinator.storageKey),
      );
    }

    final missingNew = await runLayout(
      initialTarget: null,
      initialBackup: old,
      initialStaging: null,
    );
    expect(missingNew.transactions, isEmpty);

    final leftovers = await runLayout(
      initialTarget: old,
      initialBackup: old,
      initialStaging: newer,
    );
    expect(leftovers.transactions, isEmpty);

    final ambiguous = await runLayout(
      initialTarget: InstalledSkillUpdateSnapshot(
        id: old.id,
        version: '9.0.0',
        trustDigest: 'd' * 64,
      ),
      initialBackup: old,
      initialStaging: newer,
    );
    expect(
      ambiguous.transactions[old.id]?.phase,
      UpdateTransactionPhase.rollbackRequired,
    );
  });

  test('global ledger merge preserves concurrent unrelated target mutations',
      () async {
    const a = 'com.example.alpha';
    const b = 'com.example.beta';
    DurableUpdateTransaction transaction(String id, String suffix) =>
        DurableUpdateTransaction(
          transactionId: '12345678-1234-4123-8123-123456789ab$suffix',
          targetId: id,
          phase: UpdateTransactionPhase.prepared,
          precondition: UpdatePrecondition(
            version: '1.0.0',
            trustDigest: 'a' * 64,
            revision: 0,
          ),
          targetVersion: '2.0.0',
          targetRevision: 2,
          targetTrustDigest: 'b' * 64,
          stagingPath: '/root/workspace/.skill-import-staging/$suffix/package',
          targetPath: SkillService.updateTargetPath(id),
          backupPath: SkillService.updateBackupPath(id),
        );
    final coordinator = UpdateTransactionCoordinator();
    final alpha = await coordinator.load();
    final beta = await coordinator.load();
    alpha.transactions[a] = transaction(a, 'a');
    beta.transactions[b] = transaction(b, 'b');
    await Future.wait([coordinator.save(alpha), coordinator.save(beta)]);
    var combined = await coordinator.load();
    expect(combined.transactions.keys, containsAll([a, b]));

    final commitAlpha = await coordinator.load();
    final recoverBeta = await coordinator.load();
    final stageApp = await coordinator.load();
    commitAlpha.transactions.remove(a);
    commitAlpha.revisions[a] = {'version': '2.0.0', 'revision': 2};
    commitAlpha.extensionStates[a] = {
      'id': a,
      'version': '2.0.0',
      'revision': 2,
      'currentTrustDigest': 'b' * 64,
      'backupPath': SkillService.updateBackupPath(a),
      'updatedAt': DateTime.utc(2026).toIso8601String(),
    };
    recoverBeta.transactions[b] = recoverBeta.transactions[b]!.withPhase(
      UpdateTransactionPhase.rollbackRequired,
    );
    const appPlan = '87654321-4321-4123-8123-123456789abc';
    stageApp.appStates[appPlan] = AppUpdateStagingState(
      targetId: AppConstants.packageName,
      version: '2.9.0',
      revision: 7,
      sha256: 'c' * 64,
      size: 3,
      path: '${temp.path}/updates/verified-androidApp-7-object.apk',
      stage: AppUpdateStage.verified,
      createdAt: DateTime.utc(2026).toIso8601String(),
    );
    await Future.wait([
      coordinator.save(commitAlpha),
      coordinator.save(recoverBeta),
      coordinator.save(stageApp),
    ]);

    combined = await coordinator.load();
    expect(combined.revisions[a]?['revision'], 2);
    expect(combined.extensionStates[a]?['version'], '2.0.0');
    expect(
      combined.transactions[b]?.phase,
      UpdateTransactionPhase.rollbackRequired,
    );
    expect(combined.appStates[appPlan]?.revision, 7);
  });

  test('different extension targets apply concurrently without lost state',
      () async {
    const alphaId = 'com.example.alpha';
    const betaId = 'com.example.beta';
    final alphaCandidate = _candidate(version: '2.0.0', id: alphaId);
    final betaCandidate = _candidate(version: '2.0.0', id: betaId);
    final bytes = utf8.encode('extension');
    final alphaFile = File('${temp.path}/alpha.zip')..writeAsBytesSync(bytes);
    final betaFile = File('${temp.path}/beta.zip')..writeAsBytesSync(bytes);
    final installed = <String, InstalledSkillUpdateSnapshot>{
      for (final id in [alphaId, betaId])
        id: InstalledSkillUpdateSnapshot(
          id: id,
          version: '1.0.0',
          trustDigest: 'a' * 64,
        ),
    };
    final backups = <String, InstalledSkillUpdateSnapshot>{};
    var atBackup = 0;
    final bothBackedUp = Completer<void>();
    final service = UpdateService(
      signatureCheck: (_, __, ___, ____) async => true,
      tempDirectoryProvider: () async => temp,
      prepareLocalSkill: (path) async =>
          path.endsWith('alpha.zip') ? alphaCandidate : betaCandidate,
      discardPreparedSkill: (_) async {},
      installedSkillSnapshotReader: (id) async => installed[id],
      backupSkillSnapshotReader: (_, id) async => backups[id],
      stagingSkillSnapshotReader: (_, __) async => null,
      activatePreparedSkill: (
        candidate,
        backupPath,
        afterBackupMove,
        afterNewMove,
      ) async {
        backups[candidate.id] = installed.remove(candidate.id)!;
        await afterBackupMove();
        atBackup += 1;
        if (atBackup == 2) bothBackedUp.complete();
        await bothBackedUp.future;
        installed[candidate.id] = InstalledSkillUpdateSnapshot(
          id: candidate.id,
          version: candidate.version,
          trustDigest: candidate.trustDigest,
        );
        await afterNewMove();
        return SkillInstallResult(
          targetPath: SkillService.updateTargetPath(candidate.id),
          backupPath: backupPath,
          previousVersion: '1.0.0',
        );
      },
    );
    Future<ExtensionUpdatePlan> plan(
      PreparedSkillImport candidate,
      File artifact,
      int revision,
    ) async {
      final check = await service.checkLocalMetadata(
        jsonEncode(_metadata(
          kind: 'extension',
          targetId: candidate.id,
          version: candidate.version,
          revision: revision,
          artifactBytes: bytes,
        )),
        expectedKind: UpdateArtifactKind.extension,
        expectedTargetId: candidate.id,
        currentVersion: '1.0.0',
        sourceIdentity: 'Local metadata: update.json',
      );
      return service.planExtensionUpdate(
        check,
        localArtifactPath: artifact.path,
      );
    }

    final plans = await Future.wait([
      plan(alphaCandidate, alphaFile, 2),
      plan(betaCandidate, betaFile, 3),
    ]);
    await Future.wait(plans.map(service.applyExtensionUpdate));
    final ledger = await UpdateTransactionCoordinator().load();
    expect(ledger.transactions, isEmpty);
    expect(ledger.revisions[alphaId]?['revision'], 2);
    expect(ledger.revisions[betaId]?['revision'], 3);
    expect(ledger.extensionStates.keys, containsAll([alphaId, betaId]));
  });

  test('logical deadline aborts a stalled body and removes partial staging',
      () async {
    final controller = StreamController<List<int>>();
    final service = _service(
      temp: temp,
      client: _QueueClient([
        (_) => http.StreamedResponse(controller.stream, 200),
      ]),
      operationTimeout: const Duration(milliseconds: 30),
    );
    final check = await service.checkLocalMetadata(
      jsonEncode(_metadata(
        kind: 'androidApp',
        targetId: AppConstants.packageName,
        version: '2.9.0',
        revision: 9,
        artifactBytes: const [1, 2, 3],
        artifactUrl: 'https://updates.example/app.apk',
      )),
      expectedKind: UpdateArtifactKind.androidApp,
      expectedTargetId: AppConstants.packageName,
      currentVersion: AppConstants.version,
      sourceIdentity: 'Local metadata: app.json',
    );
    await expectLater(
      service.planAppUpdate(check),
      throwsA(isA<TimeoutException>()),
    );
    final root = Directory('${temp.path}/updates');
    expect(
      await root
          .list()
          .where((entity) => entity.path.contains('partial-'))
          .toList(),
      isEmpty,
    );
    await controller.close();
  });

  test('near-deadline success and cancellation are request-local', () async {
    final stalled = StreamController<List<int>>();
    const apk = [1, 2, 3];
    final client = _QueueClient([
      (_) => http.StreamedResponse(stalled.stream, 200),
      (_) => http.StreamedResponse(
            (() async* {
              await Future<void>.delayed(const Duration(milliseconds: 20));
              yield apk;
            })(),
            200,
          ),
    ]);
    final service = _service(
      temp: temp,
      client: client,
      operationTimeout: const Duration(milliseconds: 200),
    );
    Future<UpdateCheck> check() => service.checkLocalMetadata(
          jsonEncode(_metadata(
            kind: 'androidApp',
            targetId: AppConstants.packageName,
            version: '2.9.0',
            revision: 10,
            artifactBytes: apk,
            artifactUrl: 'https://updates.example/app.apk',
          )),
          expectedKind: UpdateArtifactKind.androidApp,
          expectedTargetId: AppConstants.packageName,
          currentVersion: AppConstants.version,
          sourceIdentity: 'Local metadata: app.json',
        );
    final token = UpdateCancellationToken();
    final cancelled = service.planAppUpdate(
      await check(),
      cancellationToken: token,
    );
    while (client.requestCount == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    token.cancel();
    await expectLater(cancelled, throwsStateError);
    final plan = await service.planAppUpdate(await check());
    expect(await File(plan.apkPath).readAsBytes(), apk);
    await service.discardAppPlan(plan);
    await stalled.close();
  });

  test('app handoff remains retryable until an installed version is observed',
      () async {
    const apk = [4, 5, 6];
    var installedVersion = AppConstants.version;
    var handoffs = 0;
    final service = UpdateService(
      httpClient: _QueueClient([
        (_) => http.StreamedResponse(Stream.value(apk), 200),
        (_) => http.StreamedResponse(Stream.value(apk), 200),
      ]),
      signatureCheck: (_, __, ___, ____) async => true,
      tempDirectoryProvider: () async => temp,
      installedAppVersionReader: () => installedVersion,
      apkHandoff: ({required path, required size, required sha256}) async {
        handoffs += 1;
        return true;
      },
    );
    Future<UpdateCheck> check() => service.checkLocalMetadata(
          jsonEncode(_metadata(
            kind: 'androidApp',
            targetId: AppConstants.packageName,
            version: '2.9.0',
            revision: 11,
            artifactBytes: apk,
            artifactUrl: 'https://updates.example/app.apk',
          )),
          expectedKind: UpdateArtifactKind.androidApp,
          expectedTargetId: AppConstants.packageName,
          currentVersion: AppConstants.version,
          sourceIdentity: 'Local metadata: app.json',
        );

    final first = await service.planAppUpdate(await check());
    final second = await service.planAppUpdate(await check());
    expect(first.apkPath, isNot(second.apkPath));
    expect(await File(first.apkPath).exists(), isTrue);
    expect(await File(second.apkPath).exists(), isTrue);
    expect(await service.handoffAppUpdate(first), isTrue);
    expect(await service.handoffAppUpdate(first), isTrue);
    expect(handoffs, 2);
    var ledger = UpdateLedger.parse(
      (await SharedPreferences.getInstance())
          .getString(UpdateTransactionCoordinator.storageKey),
    );
    expect(ledger.revisions[AppConstants.packageName], isNull);

    installedVersion = '2.9.0';
    await service.reconcileAtStartup();
    ledger = UpdateLedger.parse(
      (await SharedPreferences.getInstance())
          .getString(UpdateTransactionCoordinator.storageKey),
    );
    expect(ledger.revisions[AppConstants.packageName]?['revision'], 11);
    expect(
      ledger.appStates.values.single.stage,
      AppUpdateStage.installedObserved,
    );
    expect(await File(first.apkPath).exists(), isFalse);
    expect(await File(second.apkPath).exists(), isFalse);
  });

  test('commit persistence failure retains evidence for restart commit',
      () async {
    final bytes = utf8.encode('extension');
    final artifact = File('${temp.path}/update.zip')..writeAsBytesSync(bytes);
    final candidate = _candidate(version: '2.0.0');
    var installed = InstalledSkillUpdateSnapshot(
      id: candidate.id,
      version: '1.0.0',
      trustDigest: 'b' * 64,
    );
    final backup = InstalledSkillUpdateSnapshot(
      id: candidate.id,
      version: '1.0.0',
      trustDigest: 'b' * 64,
    );
    var writes = 0;
    Future<bool> writer(String value) async {
      writes += 1;
      if (writes >= 5) return false;
      return (await SharedPreferences.getInstance()).setString(
        UpdateTransactionCoordinator.storageKey,
        value,
      );
    }

    UpdateService service({UpdateLedgerWriter? ledgerWriter}) => UpdateService(
          signatureCheck: (_, __, ___, ____) async => true,
          tempDirectoryProvider: () async => temp,
          prepareLocalSkill: (_) async => candidate,
          discardPreparedSkill: (_) async {},
          installedSkillSnapshotReader: (_) async => installed,
          backupSkillSnapshotReader: (_, __) async => backup,
          stagingSkillSnapshotReader: (_, __) async => null,
          installPreparedSkill: (value) async {
            installed = InstalledSkillUpdateSnapshot(
              id: value.id,
              version: value.version,
              trustDigest: value.trustDigest,
            );
            return SkillInstallResult(
              targetPath: SkillService.updateTargetPath(value.id),
              backupPath: SkillService.updateBackupPath(value.id),
              previousVersion: '1.0.0',
            );
          },
          ledgerWriter: ledgerWriter,
        );
    final failing = service(ledgerWriter: writer);
    final check = await failing.checkLocalMetadata(
      jsonEncode(_metadata(
        kind: 'extension',
        targetId: candidate.id,
        version: candidate.version,
        revision: 12,
        artifactBytes: bytes,
      )),
      expectedKind: UpdateArtifactKind.extension,
      expectedTargetId: candidate.id,
      currentVersion: '1.0.0',
      sourceIdentity: 'Local metadata: update.json',
    );
    final plan = await failing.planExtensionUpdate(
      check,
      localArtifactPath: artifact.path,
    );
    await expectLater(failing.applyExtensionUpdate(plan), throwsStateError);
    var ledger = UpdateLedger.parse(
      (await SharedPreferences.getInstance())
          .getString(UpdateTransactionCoordinator.storageKey),
    );
    expect(
      ledger.transactions[candidate.id]?.phase,
      UpdateTransactionPhase.activatedVerified,
    );
    final recovering = service();
    await recovering.reconcileAtStartup();
    ledger = UpdateLedger.parse(
      (await SharedPreferences.getInstance())
          .getString(UpdateTransactionCoordinator.storageKey),
    );
    expect(ledger.transactions, isEmpty);
    expect(ledger.revisions[candidate.id]?['revision'], 12);
  });

  test('rollback failure remains recoverable and a later retry settles it',
      () async {
    final bytes = utf8.encode('extension');
    final artifact = File('${temp.path}/update.zip')..writeAsBytesSync(bytes);
    final candidate = _candidate(version: '2.0.0');
    final old = InstalledSkillUpdateSnapshot(
      id: candidate.id,
      version: '1.0.0',
      trustDigest: 'b' * 64,
    );
    var installed = old;
    InstalledSkillUpdateSnapshot? backup;
    var rollbackFails = true;
    final service = UpdateService(
      signatureCheck: (_, __, ___, ____) async => true,
      tempDirectoryProvider: () async => temp,
      prepareLocalSkill: (_) async => candidate,
      discardPreparedSkill: (_) async {},
      installedSkillSnapshotReader: (_) async => installed,
      backupSkillSnapshotReader: (_, __) async => backup,
      stagingSkillSnapshotReader: (_, __) async => null,
      installPreparedSkill: (value) async {
        backup = old;
        installed = InstalledSkillUpdateSnapshot(
          id: value.id,
          version: value.version,
          trustDigest: value.trustDigest,
        );
        return SkillInstallResult(
          targetPath: SkillService.updateTargetPath(value.id),
          backupPath: SkillService.updateBackupPath(value.id),
          previousVersion: old.version,
        );
      },
      rollbackInstalledSkill: ({
        required id,
        required backupPath,
        required expectedCurrentTrustDigest,
      }) async {
        if (rollbackFails) throw StateError('injected rollback failure');
        installed = old;
        backup = null;
        return SkillRollbackResult(
          restoredVersion: old.version,
          restoredTrustDigest: old.trustDigest,
        );
      },
      failureInjector: (point) async {
        if (point == 'afterActivation') {
          throw const UpdateCrashSimulation('afterActivation');
        }
      },
    );
    final check = await service.checkLocalMetadata(
      jsonEncode(_metadata(
        kind: 'extension',
        targetId: candidate.id,
        version: candidate.version,
        revision: 13,
        artifactBytes: bytes,
      )),
      expectedKind: UpdateArtifactKind.extension,
      expectedTargetId: candidate.id,
      currentVersion: old.version,
      sourceIdentity: 'Local metadata: update.json',
    );
    await expectLater(
      service.applyExtensionUpdate(await service.planExtensionUpdate(
        check,
        localArtifactPath: artifact.path,
      )),
      throwsA(isA<UpdateCrashSimulation>()),
    );
    await service.reconcileAtStartup();
    var ledger = UpdateLedger.parse(
      (await SharedPreferences.getInstance())
          .getString(UpdateTransactionCoordinator.storageKey),
    );
    expect(
      ledger.transactions[candidate.id]?.phase,
      UpdateTransactionPhase.rollbackRequired,
    );
    rollbackFails = false;
    await service.reconcileAtStartup();
    ledger = UpdateLedger.parse(
      (await SharedPreferences.getInstance())
          .getString(UpdateTransactionCoordinator.storageKey),
    );
    expect(ledger.transactions, isEmpty);
    expect(installed.version, old.version);
  });

  test('APK staging is bounded while a recent installer grant is retained',
      () async {
    const apk = [7, 8, 9];
    final client = _QueueClient(List.generate(
      5,
      (_) => (_) => http.StreamedResponse(Stream.value(apk), 200),
    ));
    final service = UpdateService(
      httpClient: client,
      signatureCheck: (_, __, ___, ____) async => true,
      tempDirectoryProvider: () async => temp,
      apkHandoff: ({required path, required size, required sha256}) async =>
          true,
    );
    Future<UpdateCheck> check() => service.checkLocalMetadata(
          jsonEncode(_metadata(
            kind: 'androidApp',
            targetId: AppConstants.packageName,
            version: '2.9.0',
            revision: 14,
            artifactBytes: apk,
            artifactUrl: 'https://updates.example/app.apk',
          )),
          expectedKind: UpdateArtifactKind.androidApp,
          expectedTargetId: AppConstants.packageName,
          currentVersion: AppConstants.version,
          sourceIdentity: 'Local metadata: app.json',
        );
    final granted = await service.planAppUpdate(await check());
    await service.handoffAppUpdate(granted);
    final superseded = <AppUpdatePlan>[];
    for (var index = 0; index < 4; index += 1) {
      superseded.add(await service.planAppUpdate(await check()));
    }
    final ledger = UpdateLedger.parse(
      (await SharedPreferences.getInstance())
          .getString(UpdateTransactionCoordinator.storageKey),
    );
    expect(await File(granted.apkPath).exists(), isTrue);
    expect(
      ledger.appStates.values
          .where((state) => state.stage == AppUpdateStage.handedOff),
      hasLength(1),
    );
    expect(ledger.appStates.length, lessThanOrEqualTo(4));
    expect(
      await Future.wait(
        superseded.map((plan) => File(plan.apkPath).exists()),
      ),
      contains(false),
    );
    expect(
      await Directory('${temp.path}/updates')
          .list()
          .where((entity) => entity is File && entity.path.endsWith('.apk'))
          .length,
      lessThanOrEqualTo(4),
    );
  });

  test('expired verified APK state and bytes are removed on startup', () async {
    const apk = [10, 11, 12];
    var now = DateTime.utc(2026, 1, 1);
    final service = UpdateService(
      httpClient: _QueueClient([
        (_) => http.StreamedResponse(Stream.value(apk), 200),
      ]),
      signatureCheck: (_, __, ___, ____) async => true,
      tempDirectoryProvider: () async => temp,
      now: () => now,
    );
    final check = await service.checkLocalMetadata(
      jsonEncode(_metadata(
        kind: 'androidApp',
        targetId: AppConstants.packageName,
        version: '2.9.0',
        revision: 15,
        artifactBytes: apk,
        artifactUrl: 'https://updates.example/app.apk',
      )),
      expectedKind: UpdateArtifactKind.androidApp,
      expectedTargetId: AppConstants.packageName,
      currentVersion: AppConstants.version,
      sourceIdentity: 'Local metadata: app.json',
    );
    final plan = await service.planAppUpdate(check);
    expect(await File(plan.apkPath).exists(), isTrue);
    now = now.add(const Duration(days: 8));
    await service.reconcileAtStartup();
    expect(await File(plan.apkPath).exists(), isFalse);
    expect(await service.loadAppUpdateState(AppConstants.packageName), isNull);
  });
}

UpdateService _service({
  required Directory temp,
  http.Client? client,
  Future<PreparedSkillImport> Function(String path)? prepareLocalSkill,
  PreparedSkillInstaller? installPreparedSkill,
  Future<SkillRollbackResult> Function({
    required String id,
    required String backupPath,
    required String expectedCurrentTrustDigest,
  })? rollbackInstalledSkill,
  Future<bool> Function({
    required String path,
    required int size,
    required String sha256,
  })? apkHandoff,
  Duration operationTimeout = const Duration(minutes: 2),
}) {
  var installed = InstalledSkillUpdateSnapshot(
    id: 'com.example.demo',
    version: '1.0.0',
    trustDigest: 'b' * 64,
  );
  return UpdateService(
    httpClient: client,
    signatureCheck: (_, __, ___, ____) async => true,
    tempDirectoryProvider: () async => temp,
    prepareLocalSkill: prepareLocalSkill,
    installedSkillSnapshotReader: (id) async =>
        id == installed.id ? installed : null,
    backupSkillSnapshotReader: (_, id) async => id == installed.id
        ? InstalledSkillUpdateSnapshot(
            id: id,
            version: '1.0.0',
            trustDigest: 'b' * 64,
          )
        : null,
    installPreparedSkill: installPreparedSkill == null
        ? null
        : (candidate) async {
            final result = await installPreparedSkill(candidate);
            installed = InstalledSkillUpdateSnapshot(
              id: candidate.id,
              version: candidate.version,
              trustDigest: candidate.trustDigest,
            );
            return result;
          },
    rollbackInstalledSkill: rollbackInstalledSkill == null
        ? null
        : ({
            required id,
            required backupPath,
            required expectedCurrentTrustDigest,
          }) async {
            final result = await rollbackInstalledSkill(
              id: id,
              backupPath: backupPath,
              expectedCurrentTrustDigest: expectedCurrentTrustDigest,
            );
            installed = InstalledSkillUpdateSnapshot(
              id: id,
              version: result.restoredVersion,
              trustDigest: result.restoredTrustDigest,
            );
            return result;
          },
    discardPreparedSkill: (_) async {},
    apkHandoff: apkHandoff,
    operationTimeout: operationTimeout,
  );
}

Map<String, dynamic> _metadata({
  required String kind,
  required String targetId,
  required String version,
  required int revision,
  required List<int> artifactBytes,
  String artifactUrl = 'https://updates.example/extension.zip',
}) =>
    {
      'schemaVersion': 1,
      'kind': kind,
      'targetId': targetId,
      'version': version,
      'revision': revision,
      'artifactUrl': artifactUrl,
      'artifactSha256': sha256.convert(artifactBytes).toString(),
      'artifactSize': artifactBytes.length,
      'signatureAlgorithm': 'SHA256withRSA',
      'keyId': 'a' * 64,
      'signature': base64Encode(const [1, 2, 3]),
    };

PreparedSkillImport _candidate({
  required String version,
  bool withPreviousGrant = false,
  String id = 'com.example.demo',
}) {
  final oldManifest = ExtensionManifest.fromJson(
    _manifest(version: '1.0.0', id: id),
  );
  final oldGrant = SkillTrustGrant(
    schemaVersion: 1,
    id: oldManifest.id,
    version: oldManifest.version,
    manifestDigest: 'b' * 64,
    contentDigest: 'c' * 64,
    snapshot: oldManifest.capabilities.snapshot,
    sourceIdentity: 'HTTPS: updates.example',
    legacy: false,
    grantedAt: DateTime.utc(2026).toIso8601String(),
  );
  return SkillService.inspectPackage(
    stagingPath:
        '/root/workspace/.skill-import-staging/${id.replaceAll('.', '-')}/package',
    sourceIdentity: 'HTTPS: updates.example',
    skillContent: 'updated instructions',
    manifestContent: jsonEncode(
      _manifest(version: version, addCurl: true, id: id),
    ),
    previousGrant: withPreviousGrant ? oldGrant : null,
  );
}

Map<String, dynamic> _manifest({
  required String version,
  bool addCurl = false,
  String id = 'com.example.demo',
}) =>
    {
      'schemaVersion': 1,
      'id': id,
      'name': 'Demo Skill',
      'description': 'A test skill.',
      'model': {
        'name': 'demo_skill',
        'description': 'Use for a test task.',
      },
      'version': version,
      'source': {'type': 'url', 'url': 'https://updates.example/update.json'},
      'integrity': <String, dynamic>{},
      'author': 'Example',
      'license': 'MIT',
      'capabilities': {
        'tools': ['bash'],
        'commands': [if (addCurl) 'curl'],
        'networkDomains': <String>[],
        'filesystem': {'read': <String>[], 'write': <String>[]},
        'android': {'intents': <String>[], 'permissions': <String>[]},
        'secrets': <String>[],
        'subprocess': {'required': false, 'runtimes': <String>[]},
        'riskTier': addCurl ? 'moderate' : 'low',
        'updatePolicy': 'manual',
      },
    };

final class _QueueClient extends http.BaseClient {
  _QueueClient(this._responses);

  final List<http.StreamedResponse Function(http.BaseRequest)> _responses;
  int requestCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requestCount += 1;
    if (_responses.isEmpty) throw StateError('unexpected request');
    expect(request.followRedirects, isFalse);
    return _responses.removeAt(0)(request);
  }
}
