import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clawchat/services/atomic_file_write.dart';
import 'package:clawchat/services/backup_run_service.dart';
import 'package:clawchat/services/storage_budget.dart';
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
      buildPackage: (
          {String? password, bool includePlaintextSecrets = false}) async {
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

  test(
      'real destination folders receive the exact bytes and report per-target results',
      () async {
    final root = await Directory.systemTemp.createTemp('clawchat_backup_dest_');
    addTearDown(() => root.delete(recursive: true));
    final first = Directory('${root.path}/first')..createSync();
    final second = Directory('${root.path}/second')..createSync();
    // A file where the destination folder is expected makes that write fail
    // deterministically.
    final blocked = File('${root.path}/blocked')..writeAsStringSync('file');
    final store = _MemoryPackageStore();

    final service = BackupRunService(
      packageStore: store,
      buildPackage: (
          {String? password, bool includePlaintextSecrets = false}) async {
        return packageJson;
      },
      now: () => DateTime.utc(2026, 1, 2, 3, 4, 5),
      storageBudget: StorageBudget(
        availableBytesReader: () async => 1 << 40,
      ),
    );

    final outcome = await service.run(
      destinations: [
        BackupDestination.folder(first.path),
        BackupDestination.folder(second.path),
        BackupDestination.folder('${blocked.path}/nested'),
      ],
    );

    expect(outcome.status, BackupRunStatus.completedWithFailures);
    expect(
      outcome.results.map((result) => result.status).toList(),
      [
        BackupDestinationStatus.success,
        BackupDestinationStatus.success,
        BackupDestinationStatus.failure,
      ],
    );
    for (final directory in [first, second]) {
      final files = directory
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.json'))
          .toList();
      expect(files, hasLength(1),
          reason: '${directory.path} must hold exactly the package');
      expect(files.single.readAsStringSync(), packageJson);
    }
    // The failed target keeps a user-readable error and no partial file.
    expect(outcome.results.last.error, isNotNull);
    expect(
      Directory('${blocked.path}/nested').existsSync(),
      isFalse,
    );
    // No destination directory keeps a half-written temporary file.
    expect(
      root
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.part')),
      isEmpty,
    );
    // One failure keeps the staged copy for a retry instead of claiming success.
    expect(outcome.localPackageKept, isTrue);
    expect(store.deleted, isEmpty);
  });

  test('a destination write fails mid-flight without publishing a partial file',
      () async {
    final root = await Directory.systemTemp.createTemp('clawchat_partial_');
    addTearDown(() => root.delete(recursive: true));
    final directory = Directory('${root.path}/dest')..createSync();
    final store = _MemoryPackageStore();

    // Fail the write after half the bytes reached the temporary file.
    await expectLater(
      writeFileAtomically(
        '${directory.path}/package.json',
        List<int>.filled(64, 7),
        suffix: 'deadbeef',
        writePart: (part, bytes) async {
          final handle = await part.open(mode: FileMode.writeOnly);
          try {
            await handle.writeFrom(bytes.sublist(0, bytes.length ~/ 2));
            await handle.flush();
          } finally {
            await handle.close();
          }
          throw const FileSystemException('disk full');
        },
      ),
      throwsA(isA<FileSystemException>()),
    );

    // Neither the final file nor any .part survives a failed publish.
    expect(Directory(directory.path).listSync(), isEmpty);

    final service = BackupRunService(
      packageStore: store,
      buildPackage: (
          {String? password, bool includePlaintextSecrets = false}) async {
        return packageJson;
      },
      now: () => DateTime.utc(2026, 1, 2, 3, 4, 5),
      storageBudget: StorageBudget(availableBytesReader: () async => 1 << 40),
    );
    final outcome = await service.run(
      destinations: [BackupDestination.folder(directory.path)],
    );
    expect(outcome.status, BackupRunStatus.completed);
    expect(directory.listSync().whereType<File>(), hasLength(1));
    expect(
      directory.listSync().whereType<File>().single.path.endsWith('.part'),
      isFalse,
    );
  });

  test('a rename failure leaves no file at the target path', () async {
    final root = await Directory.systemTemp.createTemp('clawchat_rename_');
    addTearDown(() => root.delete(recursive: true));
    final directory = Directory('${root.path}/dest')..createSync();
    final target = '${directory.path}/package.json';

    await expectLater(
      writeFileAtomically(
        target,
        const [1, 2, 3],
        suffix: 'cafebabe',
        rename: (from, to) async => throw const FileSystemException('rename'),
      ),
      throwsA(isA<FileSystemException>()),
    );

    expect(File(target).existsSync(), isFalse);
    expect(Directory(directory.path).listSync(), isEmpty);
  });

  test('a failed package stage is not reported as a kept local package',
      () async {
    final staging = await Directory.systemTemp.createTemp('clawchat_stage_');
    addTearDown(() => staging.delete(recursive: true));
    final store = FileBackupPackageStore(
      directory: staging,
      rename: (from, to) async => throw const FileSystemException('rename'),
    );

    final service = BackupRunService(
      packageStore: store,
      buildPackage: (
          {String? password, bool includePlaintextSecrets = false}) async {
        return packageJson;
      },
      now: () => DateTime.utc(2026, 1, 2, 3, 4, 5),
      storageBudget: StorageBudget(availableBytesReader: () async => 1 << 40),
    );
    final received = <List<int>>[];
    final outcome = await service.run(
      destinations: [fakeDestination('a', received: received)],
    );

    expect(outcome.status, BackupRunStatus.failed);
    expect(outcome.localPackagePath, isEmpty);
    expect(outcome.localPackageKept, isFalse,
        reason: 'no package was staged, so none can be claimed kept');
    expect(received, isEmpty);
    // The failed stage leaves the staging directory clean.
    expect(staging.listSync(), isEmpty);
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

  test('aborts before staging when the device storage is full', () async {
    final store = _MemoryPackageStore();
    final received = <List<int>>[];
    var built = false;
    final service = BackupRunService(
      packageStore: store,
      buildPackage: (
          {String? password, bool includePlaintextSecrets = false}) async {
        built = true;
        return packageJson;
      },
      now: () => DateTime.utc(2026, 1, 2, 3, 4, 5),
      storageBudget: StorageBudget(
        availableBytesReader: () async => 512,
      ),
    );

    final outcome = await service.run(
      destinations: [fakeDestination('a', received: received)],
    );

    expect(built, isFalse, reason: 'no package may be built on a full disk');
    expect(store.saved, isEmpty);
    expect(received, isEmpty);
    expect(outcome.status, BackupRunStatus.failed);
    expect(outcome.error, contains('可用存储不足'));
    expect(
      outcome.results.single.status,
      BackupDestinationStatus.failure,
    );
    expect(outcome.results.single.error, contains('可用存储不足'));
  });

  test('runs normally when free space is unreported', () async {
    final store = _MemoryPackageStore();
    final received = <List<int>>[];
    final service = BackupRunService(
      packageStore: store,
      buildPackage: (
          {String? password, bool includePlaintextSecrets = false}) async {
        return packageJson;
      },
      now: () => DateTime.utc(2026, 1, 2, 3, 4, 5),
      storageBudget: StorageBudget(availableBytesReader: () async => null),
    );

    final outcome = await service.run(
      destinations: [fakeDestination('a', received: received)],
    );

    expect(outcome.status, BackupRunStatus.completed);
    expect(received, hasLength(1));
  });

  test('reports a package build failure without touching destinations',
      () async {
    final store = _MemoryPackageStore();
    var writes = 0;
    final service = BackupRunService(
      packageStore: store,
      buildPackage: (
          {String? password, bool includePlaintextSecrets = false}) async {
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
