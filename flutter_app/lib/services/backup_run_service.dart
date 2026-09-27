import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'atomic_file_write.dart';
import 'config_export_service.dart';
import 'storage_budget.dart';

/// Status of one destination inside a backup run.
enum BackupDestinationStatus {
  pending,
  running,
  success,
  failure,
  cancelled,
}

/// Terminal status of a whole backup run.
enum BackupRunStatus {
  running,
  completed,
  completedWithFailures,
  cancelled,
  failed,
}

/// Writes the exported package into one destination folder.
typedef BackupDestinationWriter = Future<void> Function(
  String fileName,
  List<int> bytes,
);

/// Builds the exported configuration package as JSON.
typedef BackupPackageBuilder = Future<String> Function({
  String? password,
  bool includePlaintextSecrets,
});

/// One place a backup run can write the exported package to.
class BackupDestination {
  const BackupDestination({
    required this.id,
    required this.label,
    required this.directoryPath,
    required this.writeFile,
  });

  /// A destination backed by a real local folder chosen by the file picker.
  factory BackupDestination.folder(String directoryPath) {
    return BackupDestination(
      id: directoryPath,
      label: _folderLabel(directoryPath),
      directoryPath: directoryPath,
      writeFile: (fileName, bytes) async {
        // Atomic publish: the folder only ever gains the complete package.
        await writeFileAtomically(
          '$directoryPath${Platform.pathSeparator}$fileName',
          bytes,
        );
      },
    );
  }

  final String id;
  final String label;
  final String directoryPath;
  final BackupDestinationWriter writeFile;

  static String _folderLabel(String path) {
    final parts = path
        .split(RegExp(r'[/\\]'))
        .where((part) => part.trim().isNotEmpty)
        .toList();
    if (parts.isEmpty) return path;
    return parts.last;
  }
}

/// Result recorded for a single destination.
class BackupDestinationResult {
  const BackupDestinationResult({
    required this.id,
    required this.label,
    required this.directoryPath,
    required this.status,
    this.error,
  });

  final String id;
  final String label;
  final String directoryPath;
  final BackupDestinationStatus status;
  final String? error;

  bool get succeeded => status == BackupDestinationStatus.success;
}

/// Snapshot emitted while a run is in progress and once when it ends.
class BackupRunProgress {
  const BackupRunProgress({
    required this.total,
    required this.finished,
    required this.results,
    required this.status,
    this.currentLabel,
  });

  final int total;
  final int finished;
  final List<BackupDestinationResult> results;
  final BackupRunStatus status;
  final String? currentLabel;

  double? get fraction {
    if (total <= 0) return null;
    return finished / total;
  }
}

/// Final outcome of a run, including where the staged local package went.
class BackupRunOutcome {
  const BackupRunOutcome({
    required this.status,
    required this.results,
    required this.packageName,
    required this.localPackagePath,
    required this.localPackageKept,
    this.error,
  });

  final BackupRunStatus status;
  final List<BackupDestinationResult> results;
  final String packageName;
  final String localPackagePath;

  /// True when the staged local package was kept for a retry. It is removed
  /// only after every selected destination succeeded.
  final bool localPackageKept;
  final String? error;

  bool get allSucceeded =>
      results.isNotEmpty && results.every((result) => result.succeeded);
}

/// Keeps the staged local package while a run is in progress.
abstract class BackupPackageStore {
  Future<String> save(String fileName, List<int> bytes);

  Future<void> delete(String handle);
}

/// Default store: one private temp file per run.
class FileBackupPackageStore implements BackupPackageStore {
  FileBackupPackageStore({Directory? directory, AtomicRename? rename})
      : _directory = directory,
        _rename = rename;

  Directory? _directory;
  final AtomicRename? _rename;

  @override
  Future<String> save(String fileName, List<int> bytes) async {
    final directory = _directory ??=
        await Directory.systemTemp.createTemp('clawchat-backup-');
    final path = '${directory.path}${Platform.pathSeparator}$fileName';
    // Atomic publish: the returned path always points at a complete package.
    await writeFileAtomically(path, bytes, rename: _rename);
    return path;
  }

  @override
  Future<void> delete(String handle) async {
    final file = File(handle);
    if (await file.exists()) {
      await file.delete();
    }
  }
}

/// Runs the existing config export against one or more local destinations.
///
/// The package is staged locally first. It is deleted only after every
/// selected destination succeeds, so a failed or cancelled run always leaves
/// the local package available for a retry. Secrets stay redacted unless the
/// caller passes [includePlaintextSecrets] after the existing confirmation.
class BackupRunService {
  BackupRunService({
    BackupPackageStore? packageStore,
    BackupPackageBuilder? buildPackage,
    DateTime Function()? now,
    StorageBudget? storageBudget,
  })  : _packageStore = packageStore ?? FileBackupPackageStore(),
        _buildPackage = buildPackage ?? _defaultBuildPackage,
        _now = now ?? DateTime.now,
        _storageBudget = storageBudget ?? StorageBudget();

  static Future<String> _defaultBuildPackage({
    String? password,
    bool includePlaintextSecrets = false,
  }) {
    return ConfigExportService.exportConfig(
      password: password,
      includePlaintextSecrets: includePlaintextSecrets,
    );
  }

  final BackupPackageStore _packageStore;
  final BackupPackageBuilder _buildPackage;
  final DateTime Function() _now;
  final StorageBudget _storageBudget;

  final StreamController<BackupRunProgress> _progressController =
      StreamController<BackupRunProgress>.broadcast();

  bool _running = false;
  bool _cancelRequested = false;

  Stream<BackupRunProgress> get progress => _progressController.stream;

  bool get isRunning => _running;

  /// Requests cancellation. A destination already being written finishes; any
  /// destination that has not started is recorded as cancelled.
  void cancel() {
    if (_running) _cancelRequested = true;
  }

  Future<BackupRunOutcome> run({
    required List<BackupDestination> destinations,
    bool includePlaintextSecrets = false,
    String? password,
  }) async {
    if (_running) {
      throw StateError('a backup run is already in progress');
    }
    if (destinations.isEmpty) {
      throw ArgumentError.value(
        destinations,
        'destinations',
        'select at least one folder',
      );
    }

    _running = true;
    _cancelRequested = false;

    final packageName = _packageFileName();
    final results = <BackupDestinationResult>[];
    var localPackagePath = '';
    // No package exists until the atomic save succeeded: a failed stage must
    // never be reported as "local package kept".
    var localPackageKept = false;
    BackupRunStatus status = BackupRunStatus.running;
    String? runError;

    try {
      final List<int> bytes;
      try {
        // §5 AND-6: fail before staging anything when the disk cannot take it,
        // so a nearly full device gets one actionable message instead of a
        // half-written export.
        final budget = await _storageBudget.ensureCapacity(operation: '导出备份');
        if (!budget.allowed) {
          throw StateError(budget.message ?? '存储空间不足，导出已取消。');
        }
        final jsonStr = await _buildPackage(
          password: password,
          includePlaintextSecrets: includePlaintextSecrets,
        );
        bytes = utf8.encode(jsonStr);
        localPackagePath = await _packageStore.save(packageName, bytes);
        localPackageKept = true;
      } catch (error) {
        runError = error.toString();
        status = BackupRunStatus.failed;
        for (final destination in destinations) {
          results.add(
            _result(
              destination,
              BackupDestinationStatus.failure,
              error: runError,
            ),
          );
        }
        return _finish(
          destinations,
          results,
          status,
          packageName,
          localPackagePath,
          localPackageKept,
          runError,
        );
      }

      for (final destination in destinations) {
        if (_cancelRequested) {
          results.add(_result(destination, BackupDestinationStatus.cancelled));
          _emit(destinations, results, status);
          continue;
        }

        _emit(destinations, results, status, currentLabel: destination.label);
        try {
          await destination.writeFile(packageName, bytes);
          results.add(_result(destination, BackupDestinationStatus.success));
        } catch (error) {
          results.add(
            _result(
              destination,
              BackupDestinationStatus.failure,
              error: error.toString(),
            ),
          );
        }
        _emit(destinations, results, status);
      }

      if (_cancelRequested) {
        status = BackupRunStatus.cancelled;
      } else if (results.every((result) => result.succeeded)) {
        status = BackupRunStatus.completed;
      } else {
        status = BackupRunStatus.completedWithFailures;
      }

      if (status == BackupRunStatus.completed) {
        try {
          await _packageStore.delete(localPackagePath);
          localPackageKept = false;
        } catch (_) {
          // Keeping the staged copy is the safe failure mode.
          localPackageKept = true;
        }
      }
    } finally {
      _running = false;
    }

    return _finish(
      destinations,
      results,
      status,
      packageName,
      localPackagePath,
      localPackageKept,
      runError,
    );
  }

  BackupRunOutcome _finish(
    List<BackupDestination> destinations,
    List<BackupDestinationResult> results,
    BackupRunStatus status,
    String packageName,
    String localPackagePath,
    bool localPackageKept,
    String? error,
  ) {
    _emit(destinations, results, status);
    return BackupRunOutcome(
      status: status,
      results: List.unmodifiable(results),
      packageName: packageName,
      localPackagePath: localPackagePath,
      localPackageKept: localPackageKept,
      error: error,
    );
  }

  void _emit(
    List<BackupDestination> destinations,
    List<BackupDestinationResult> results,
    BackupRunStatus status, {
    String? currentLabel,
  }) {
    if (_progressController.isClosed) return;
    _progressController.add(
      BackupRunProgress(
        total: destinations.length,
        finished: results.length,
        results: List.unmodifiable(results),
        status: status,
        currentLabel: currentLabel,
      ),
    );
  }

  BackupDestinationResult _result(
    BackupDestination destination,
    BackupDestinationStatus status, {
    String? error,
  }) {
    return BackupDestinationResult(
      id: destination.id,
      label: destination.label,
      directoryPath: destination.directoryPath,
      status: status,
      error: error,
    );
  }

  String _packageFileName() {
    final date = _now().toIso8601String().split('T').first;
    return 'clawchat-config-$date.json';
  }

  Future<void> dispose() => _progressController.close();
}
