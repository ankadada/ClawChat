import 'dart:convert';

import 'package:clawchat/services/update_transaction.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Map<String, dynamic> emptyLedger() => {
        'schemaVersion': 1,
        'generation': 0,
        'revisions': <String, dynamic>{},
        'extensionStates': <String, dynamic>{},
        'transactions': <String, dynamic>{},
        'appStates': <String, dynamic>{},
      };

  test('strict ledger rejects unknown, missing, and malformed fields', () {
    expect(
      () => UpdateLedger.parse(jsonEncode({...emptyLedger(), 'extra': true})),
      throwsFormatException,
    );
    final missing = emptyLedger()..remove('transactions');
    expect(
      () => UpdateLedger.parse(jsonEncode(missing)),
      throwsFormatException,
    );
    expect(
      () => UpdateLedger.parse(jsonEncode({
        ...emptyLedger(),
        'revisions': {
          'com.example.demo': {
            'version': '2.0.0',
            'revision': 2,
            'unknown': false,
          },
        },
      })),
      throwsFormatException,
    );
    expect(
      () => UpdateLedger.parse(jsonEncode({
        ...emptyLedger(),
        'schemaVersion': 99,
      })),
      throwsFormatException,
    );
  });

  test('ledger enforces encoded size and per-map record bounds', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      UpdateTransactionCoordinator.storageKey,
      'x' * (UpdateTransactionCoordinator.maxBytes + 1),
    );
    await expectLater(
      UpdateTransactionCoordinator().load(),
      throwsA(isA<UpdateLedgerCorruptException>()),
    );

    SharedPreferences.setMockInitialValues({});
    final coordinator = UpdateTransactionCoordinator();
    final ledger = await coordinator.load();
    for (var index = 0;
        index <= UpdateTransactionCoordinator.maxRecordsPerMap;
        index += 1) {
      ledger.revisions['com.example.target$index'] = {
        'version': '2.0.0',
        'revision': index + 1,
      };
    }
    await expectLater(coordinator.save(ledger), throwsFormatException);
  });

  test('nested paths, digests, timestamps, and cross-fields fail closed', () {
    final badApp = emptyLedger();
    badApp['appStates'] = {
      '12345678-1234-4123-8123-123456789abc': {
        'targetId': 'com.anka.clawbot',
        'version': '2.0.0',
        'revision': 2,
        'sha256': 'a' * 64,
        'size': 3,
        'path': '/outside/object.apk',
        'stage': 'verified',
        'createdAt': 'not-a-timestamp',
      },
    };
    expect(
      () => UpdateLedger.parse(jsonEncode(badApp)),
      throwsFormatException,
    );

    final mismatchedState = emptyLedger();
    mismatchedState['extensionStates'] = {
      'com.example.demo': {
        'id': 'com.example.demo',
        'version': '2.0.0',
        'revision': 2,
        'currentTrustDigest': 'b' * 64,
        'backupPath': '/root/workspace/.skill-update-backups/com.example.demo',
        'updatedAt': DateTime.utc(2026).toIso8601String(),
      },
    };
    expect(
      () => UpdateLedger.parse(jsonEncode(mismatchedState)),
      throwsFormatException,
    );
  });

  test('corrupt primary blocks updates until explicit LKG recovery', () async {
    final coordinator = UpdateTransactionCoordinator();
    final seed = await coordinator.load();
    seed.revisions['com.example.demo'] = {
      'version': '2.0.0',
      'revision': 7,
    };
    await coordinator.save(seed);

    final failing = UpdateTransactionCoordinator(
      writer: (value) async {
        await (await SharedPreferences.getInstance()).setString(
          UpdateTransactionCoordinator.storageKey,
          '{',
        );
        return false;
      },
    );
    final stale = await failing.load();
    stale.revisions['com.example.other'] = {
      'version': '3.0.0',
      'revision': 8,
    };
    await expectLater(failing.save(stale), throwsStateError);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(UpdateTransactionCoordinator.storageKey), '{');
    await expectLater(
      coordinator.load(),
      throwsA(isA<UpdateLedgerCorruptException>()),
    );

    await coordinator.recoverLastKnownGood();
    final recovered = await coordinator.load();
    expect(recovered.revisions['com.example.demo']?['revision'], 7);
    expect(recovered.revisions['com.example.other'], isNull);
    expect(
      prefs.getString(UpdateTransactionCoordinator.corruptEvidenceKey),
      '{',
    );
  });

  test('missing primary is first-run only without recovery evidence', () async {
    final encoded = jsonEncode({
      ...emptyLedger(),
      'revisions': {
        'com.example.demo': {'version': '2.0.0', 'revision': 7},
      },
    });
    for (final primary in <String?>[null, '']) {
      SharedPreferences.setMockInitialValues({
        if (primary != null) UpdateTransactionCoordinator.storageKey: primary,
        UpdateTransactionCoordinator.backupKey: encoded,
      });
      await expectLater(
        UpdateTransactionCoordinator().load(),
        throwsA(isA<UpdateLedgerCorruptException>()),
      );
    }

    SharedPreferences.setMockInitialValues({
      UpdateTransactionCoordinator.corruptEvidenceKey: 'evidence',
    });
    await expectLater(
      UpdateTransactionCoordinator().load(),
      throwsA(isA<UpdateLedgerCorruptException>()),
    );
  });

  test('LKG recovery requires durable evidence before restoring primary',
      () async {
    final encoded = jsonEncode({
      ...emptyLedger(),
      'revisions': {
        'com.example.demo': {'version': '2.0.0', 'revision': 7},
      },
    });
    Future<void> verifyRejected(UpdateLedgerEvidenceWriter writer) async {
      SharedPreferences.setMockInitialValues({
        UpdateTransactionCoordinator.backupKey: encoded,
      });
      final coordinator = UpdateTransactionCoordinator(
        evidenceWriter: writer,
      );
      await expectLater(coordinator.recoverLastKnownGood(), throwsStateError);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(UpdateTransactionCoordinator.storageKey), false);
      expect(prefs.getString(UpdateTransactionCoordinator.backupKey), encoded);
    }

    await verifyRejected((_) async => false);
    await verifyRejected((_) async => throw StateError('injected'));

    SharedPreferences.setMockInitialValues({
      UpdateTransactionCoordinator.backupKey: encoded,
    });
    final coordinator = UpdateTransactionCoordinator();
    await coordinator.recoverLastKnownGood();
    final recovered = await coordinator.load();
    expect(recovered.revisions['com.example.demo']?['revision'], 7);
    expect(
      (await SharedPreferences.getInstance())
          .containsKey(UpdateTransactionCoordinator.corruptEvidenceKey),
      true,
    );
  });
}
