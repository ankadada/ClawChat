import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clawchat/services/backup_run_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Package store that never touches the filesystem.
class _MemoryPackageStore implements BackupPackageStore {
  final Map<String, List<int>> saved = {};
  final List<String> deleted = [];

  @override
  Future<String> save(String fileName, List<int> bytes) async {
    saved[fileName] = List<int>.of(bytes);
    return fileName;
  }

  @override
  Future<void> delete(String handle) async {
    deleted.add(handle);
    saved.remove(handle);
  }
}

void main() {
  const packageJson = '{"version":1,"secrets":{"encrypted":false}}';

  BackupDestination fakeDestination(
    String id, {
    BackupDestinationWriter? write,
    List<List<int>>? received,
  }) {
    return BackupDestination(
      id: id,
      label: 'folder-$id',
      directoryPath: '/tmp/$id',
      writeFile: write ??
          (fileName, bytes) async {
            received?.add(List<int>.of(bytes));
          },
    );
  }

  BackupRunService buildService(
    _MemoryPackageStore store, {
    void Function(bool includePlaintextSecrets)? onBuild,
  }) {
    return BackupRunService(
      packageStore: store,
      buildPackage: ({String? password, bool includePlaintextSecrets = false}) async {
        onBuild?.call(includePlaintextSecrets);
        return packageJson;
      },
      now: () => DateTime.utc(2026, 1, 2, 3, 4, 5),
    );
  }

  test('records one success and one failure and keeps the local package',
      () async {
    final store = _MemoryPackageStore();
    final service = buildService(store);

    final outcome = await service.run(
      destinations: [
        fakeDestination('ok'),
        fakeDestination(
          'bad',
          write: (fileName, bytes) async =>
              throw const FileSystemException('folder is read-only'),
        ),
      ],
    );

    expect(outcome.status, BackupRunStatus.completedWithFailures);
    expect(
      outcome.results.map((result) => result.status).toList(),
      [
        BackupDestinationStatus.success,
        BackupDestinationStatus.failure,
      ],
    );
    expect(outcome.results[1].error, contains('read-only'));
    expect(outcome.localPackageKept, isTrue);
    expect(store.deleted, isEmpty);
    expect(store.saved, isNotEmpty);
  });

  test('removes the local package only when every destination succeeds',
      () async {
    final store = _MemoryPackageStore();
    final service = buildService(store);

    final firstBytes = <List<int>>[];
    final secondBytes = <List<int>>[];
    final outcome = await service.run(
      destinations: [
        fakeDestination('a', received: firstBytes),
        fakeDestination('b', received: secondBytes),
      ],
    );

    expect(outcome.status, BackupRunStatus.completed);
    expect(outcome.allSucceeded, isTrue);
    expect(outcome.localPackageKept, isFalse);
    expect(store.deleted, hasLength(1));
    expect(store.saved, isEmpty);

    // The same package reaches every destination.
    expect(firstBytes, hasLength(1));
    expect(secondBytes, hasLength(1));
    expect(firstBytes.single, secondBytes.single);
    expect(utf8.decode(firstBytes.single), packageJson);
    expect(outcome.packageName, 'clawchat-config-2026-01-02.json');
  });

  test('cancel stops the run, records the rest as cancelled, keeps the package',
      () async {
    final store = _MemoryPackageStore();
    final service = buildService(store);

    final started = Completer<void>();
    final gate = Completer<void>();
    final secondRan = <String>[];

    final outcomeFuture = service.run(
      destinations: [
        fakeDestination(
          'first',
          write: (fileName, bytes) async {
            if (!started.isCompleted) started.complete();
            await gate.future;
          },
        ),
        fakeDestination(
          'second',
          write: (fileName, bytes) async => secondRan.add(fileName),
        ),
      ],
    );

    await started.future;
    service.cancel();
    gate.complete();

    final outcome = await outcomeFuture;

    expect(outcome.status, BackupRunStatus.cancelled);
    expect(outcome.results[0].status, BackupDestinationStatus.success);
    expect(outcome.results[1].status, BackupDestinationStatus.cancelled);
    expect(secondRan, isEmpty);
    expect(outcome.localPackageKept, isTrue);
    expect(store.deleted, isEmpty);
    expect(store.saved, isNotEmpty);
  });

  test('plaintext secrets stay off unless the caller asks for them', () async {
    final store = _MemoryPackageStore();
    final seen = <bool>[];
    final service = buildService(
      store,
      onBuild: (includePlaintextSecrets) => seen.add(includePlaintextSecrets),
    );

    await service.run(destinations: [fakeDestination('redacted')]);
    await service.run(
      destinations: [fakeDestination('plaintext')],
      includePlaintextSecrets: true,
    );

    expect(seen, [false, true]);
  });

  test('reports a package build failure without touching destinations',
      () async {
    final store = _MemoryPackageStore();
    var writes = 0;
    final service = BackupRunService(
      packageStore: store,
      buildPackage: ({String? password, bool includePlaintextSecrets = false}) async {
        throw StateError('password mismatch');
      },
    );

    final outcome = await service.run(
      destinations: [
        fakeDestination(
          'a',
          write: (fileName, bytes) async => writes++,
        ),
      ],
    );

    expect(outcome.status, BackupRunStatus.failed);
    expect(outcome.error, contains('password mismatch'));
    expect(outcome.results.single.status, BackupDestinationStatus.failure);
    expect(writes, 0);
    expect(store.saved, isEmpty);
  });
}
