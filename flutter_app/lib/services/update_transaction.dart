import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

enum UpdateTransactionPhase {
  prepared,
  backupMoved,
  newMoved,
  activatedVerified,
  rollbackTargetMoved,
  rollbackBackupMoved,
  committed,
  rollbackRequired,
}

enum AppUpdateStage { verified, handedOff, installedObserved }

final class UpdateLedgerCorruptException implements Exception {
  const UpdateLedgerCorruptException(this.message);

  final String message;

  @override
  String toString() => 'UpdateLedgerCorruptException: $message';
}

final class UpdatePrecondition {
  const UpdatePrecondition({
    required this.version,
    required this.trustDigest,
    required this.revision,
  });

  final String version;
  final String trustDigest;
  final int revision;

  Map<String, Object> toJson() => {
        'version': version,
        'trustDigest': trustDigest,
        'revision': revision,
      };

  factory UpdatePrecondition.fromJson(Map<String, dynamic> json) {
    _requireExactKeys(json, const {'version', 'trustDigest', 'revision'});
    final value = UpdatePrecondition(
      version: _string(json['version']),
      trustDigest: _string(json['trustDigest']),
      revision: _integer(json['revision']),
    );
    if (!_semanticVersion.hasMatch(value.version) ||
        !_digest.hasMatch(value.trustDigest) ||
        value.revision < 0) {
      throw const FormatException('Stored update precondition is invalid.');
    }
    return value;
  }
}

/// Minimal crash-recovery evidence. It intentionally excludes network and
/// signature metadata, credentials, manifests, and package contents.
final class DurableUpdateTransaction {
  const DurableUpdateTransaction({
    required this.transactionId,
    required this.targetId,
    required this.phase,
    required this.precondition,
    required this.targetVersion,
    required this.targetRevision,
    required this.targetTrustDigest,
    required this.stagingPath,
    required this.targetPath,
    required this.backupPath,
    String? failedPath,
  }) : failedPath = failedPath ??
            '/root/workspace/.skill-update-failures/$targetId/$transactionId';

  final String transactionId;
  final String targetId;
  final UpdateTransactionPhase phase;
  final UpdatePrecondition precondition;
  final String targetVersion;
  final int targetRevision;
  final String targetTrustDigest;
  final String stagingPath;
  final String targetPath;
  final String backupPath;
  final String failedPath;

  DurableUpdateTransaction withPhase(UpdateTransactionPhase value) =>
      DurableUpdateTransaction(
        transactionId: transactionId,
        targetId: targetId,
        phase: value,
        precondition: precondition,
        targetVersion: targetVersion,
        targetRevision: targetRevision,
        targetTrustDigest: targetTrustDigest,
        stagingPath: stagingPath,
        targetPath: targetPath,
        backupPath: backupPath,
        failedPath: failedPath,
      );

  Map<String, Object> toJson() => {
        'transactionId': transactionId,
        'targetId': targetId,
        'phase': phase.name,
        'precondition': precondition.toJson(),
        'targetVersion': targetVersion,
        'targetRevision': targetRevision,
        'targetTrustDigest': targetTrustDigest,
        'stagingPath': stagingPath,
        'targetPath': targetPath,
        'backupPath': backupPath,
        'failedPath': failedPath,
      };

  factory DurableUpdateTransaction.fromJson(Map<String, dynamic> json) {
    _requireExactKeys(json, const {
      'transactionId',
      'targetId',
      'phase',
      'precondition',
      'targetVersion',
      'targetRevision',
      'targetTrustDigest',
      'stagingPath',
      'targetPath',
      'backupPath',
      'failedPath',
    });
    final targetId = _string(json['targetId']);
    final transaction = DurableUpdateTransaction(
      transactionId: _string(json['transactionId']),
      targetId: targetId,
      phase: UpdateTransactionPhase.values.byName(_string(json['phase'])),
      precondition: UpdatePrecondition.fromJson(_object(json['precondition'])),
      targetVersion: _string(json['targetVersion']),
      targetRevision: _integer(json['targetRevision']),
      targetTrustDigest: _string(json['targetTrustDigest']),
      stagingPath: _string(json['stagingPath']),
      targetPath: _string(json['targetPath']),
      backupPath: _string(json['backupPath']),
      failedPath: _string(json['failedPath']),
    );
    if (!_transactionId.hasMatch(transaction.transactionId) ||
        !_targetId.hasMatch(targetId) ||
        !_semanticVersion.hasMatch(transaction.targetVersion) ||
        (transaction.stagingPath == transaction.backupPath
            ? transaction.targetRevision != transaction.precondition.revision
            : transaction.targetRevision <=
                transaction.precondition.revision) ||
        !_digest.hasMatch(transaction.targetTrustDigest) ||
        transaction.targetPath != '/root/workspace/skills/$targetId' ||
        !_safeBackupPath(targetId, transaction.backupPath) ||
        !_safeFailedPath(
          targetId,
          transaction.transactionId,
          transaction.failedPath,
        ) ||
        (transaction.stagingPath != transaction.backupPath &&
            !transaction.stagingPath
                .startsWith('/root/workspace/.skill-import-staging/'))) {
      throw const FormatException('Stored update transaction is invalid.');
    }
    return transaction;
  }
}

final class AppUpdateStagingState {
  const AppUpdateStagingState({
    required this.targetId,
    required this.version,
    required this.revision,
    required this.sha256,
    required this.size,
    required this.path,
    required this.stage,
    required this.createdAt,
    this.handedOffAt,
  });

  final String targetId;
  final String version;
  final int revision;
  final String sha256;
  final int size;
  final String path;
  final AppUpdateStage stage;
  final String createdAt;
  final String? handedOffAt;

  AppUpdateStagingState withStage(
    AppUpdateStage value, {
    String? handedOffAt,
  }) =>
      AppUpdateStagingState(
        targetId: targetId,
        version: version,
        revision: revision,
        sha256: sha256,
        size: size,
        path: path,
        stage: value,
        createdAt: createdAt,
        handedOffAt: handedOffAt ?? this.handedOffAt,
      );

  Map<String, Object?> toJson() => {
        'targetId': targetId,
        'version': version,
        'revision': revision,
        'sha256': sha256,
        'size': size,
        'path': path,
        'stage': stage.name,
        'createdAt': createdAt,
        if (handedOffAt != null) 'handedOffAt': handedOffAt,
      };

  factory AppUpdateStagingState.fromJson(Map<String, dynamic> json) {
    final allowed = <String>{
      'targetId',
      'version',
      'revision',
      'sha256',
      'size',
      'path',
      'stage',
      'createdAt',
      if (json.containsKey('handedOffAt')) 'handedOffAt',
    };
    _requireExactKeys(json, allowed);
    final state = AppUpdateStagingState(
      targetId: _string(json['targetId']),
      version: _string(json['version']),
      revision: _integer(json['revision']),
      sha256: _string(json['sha256']),
      size: _integer(json['size']),
      path: _string(json['path']),
      stage: AppUpdateStage.values.byName(_string(json['stage'])),
      createdAt: _string(json['createdAt']),
      handedOffAt:
          json.containsKey('handedOffAt') ? _string(json['handedOffAt']) : null,
    );
    final createdAt = DateTime.tryParse(state.createdAt);
    final handedOffAt = DateTime.tryParse(state.handedOffAt ?? '');
    if (!_targetId.hasMatch(state.targetId) ||
        !_semanticVersion.hasMatch(state.version) ||
        state.revision <= 0 ||
        state.size <= 0 ||
        !_digest.hasMatch(state.sha256) ||
        !_safeAppPath(state.path) ||
        createdAt == null ||
        !createdAt.isUtc ||
        (state.stage == AppUpdateStage.handedOff && handedOffAt == null) ||
        (handedOffAt != null && !handedOffAt.isUtc)) {
      throw const FormatException('Stored app update state is invalid.');
    }
    return state;
  }
}

final class UpdateLedger {
  UpdateLedger({
    this.generation = 0,
    Map<String, Map<String, Object>>? revisions,
    Map<String, Map<String, Object?>>? extensionStates,
    Map<String, DurableUpdateTransaction>? transactions,
    Map<String, AppUpdateStagingState>? appStates,
  })  : revisions = revisions ?? {},
        extensionStates = extensionStates ?? {},
        transactions = transactions ?? {},
        appStates = appStates ?? {};

  int generation;
  final Map<String, Map<String, Object>> revisions;
  final Map<String, Map<String, Object?>> extensionStates;
  final Map<String, DurableUpdateTransaction> transactions;
  final Map<String, AppUpdateStagingState> appStates;
  String? _base;

  Map<String, Object> toJson() => {
        'schemaVersion': 1,
        'generation': generation,
        'revisions': revisions,
        'extensionStates': extensionStates,
        'transactions': transactions.map(
          (key, value) => MapEntry(key, value.toJson()),
        ),
        'appStates': appStates.map(
          (key, value) => MapEntry(key, value.toJson()),
        ),
      };

  factory UpdateLedger.parse(String? source) {
    if (source == null || source.isEmpty) {
      final ledger = UpdateLedger();
      ledger._base = jsonEncode(ledger.toJson());
      return ledger;
    }
    if (utf8.encode(source).length > UpdateTransactionCoordinator.maxBytes) {
      throw const FormatException('Stored update ledger is oversized.');
    }
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const FormatException('Stored update ledger must be an object.');
    }
    final json = Map<String, dynamic>.from(decoded);
    _requireExactKeys(json, const {
      'schemaVersion',
      'generation',
      'revisions',
      'extensionStates',
      'transactions',
      'appStates',
    });
    if (json['schemaVersion'] != 1) {
      throw const FormatException(
          'Stored update ledger schema is unsupported.');
    }
    final ledger = UpdateLedger(generation: _integer(json['generation']));
    if (ledger.generation < 0) {
      throw const FormatException(
          'Stored update ledger generation is invalid.');
    }
    final revisions = _boundedMap(json['revisions']);
    for (final entry in revisions.entries) {
      if (!_targetId.hasMatch(entry.key)) {
        throw const FormatException('Stored revision target is invalid.');
      }
      final value = _object(entry.value);
      _requireExactKeys(value, const {'version', 'revision'});
      final version = _string(value['version']);
      final revision = _integer(value['revision']);
      if (!_semanticVersion.hasMatch(version) || revision <= 0) {
        throw const FormatException('Stored revision is invalid.');
      }
      ledger.revisions[entry.key] = {'version': version, 'revision': revision};
    }
    final states = _boundedMap(json['extensionStates']);
    for (final entry in states.entries) {
      final value = _object(entry.value);
      _requireExactKeys(value, const {
        'id',
        'version',
        'revision',
        'currentTrustDigest',
        'backupPath',
        'updatedAt',
      });
      final id = _string(value['id']);
      final version = _string(value['version']);
      final revision = _integer(value['revision']);
      final digest = _string(value['currentTrustDigest']);
      final backupPath = _string(value['backupPath']);
      final updatedAt = DateTime.tryParse(_string(value['updatedAt']));
      if (entry.key != id ||
          !_targetId.hasMatch(id) ||
          !_semanticVersion.hasMatch(version) ||
          revision <= 0 ||
          !_digest.hasMatch(digest) ||
          !_safeBackupPath(id, backupPath) ||
          updatedAt == null ||
          !updatedAt.isUtc) {
        throw const FormatException('Stored extension state is invalid.');
      }
      ledger.extensionStates[id] = Map<String, Object?>.from(value);
    }
    final transactions = _boundedMap(json['transactions']);
    for (final entry in transactions.entries) {
      final transaction = DurableUpdateTransaction.fromJson(
        _object(entry.value),
      );
      if (transaction.targetId != entry.key) {
        throw const FormatException('Stored transaction target mismatches.');
      }
      ledger.transactions[entry.key] = transaction;
    }
    final appStates = _boundedMap(json['appStates']);
    for (final entry in appStates.entries) {
      if (!_transactionId.hasMatch(entry.key)) {
        throw const FormatException('Stored app plan ID is invalid.');
      }
      ledger.appStates[entry.key] = AppUpdateStagingState.fromJson(
        _object(entry.value),
      );
    }
    ledger._validateCrossFields();
    ledger._base = source;
    return ledger;
  }

  void _validateCrossFields() {
    for (final entry in extensionStates.entries) {
      final revision = revisions[entry.key];
      if (revision == null ||
          revision['version'] != entry.value['version'] ||
          revision['revision'] != entry.value['revision']) {
        throw const FormatException('Extension state revision mismatches.');
      }
    }
    for (final state in appStates.values) {
      if (state.stage != AppUpdateStage.installedObserved) continue;
      final revision = revisions[state.targetId];
      if (revision == null ||
          revision['version'] != state.version ||
          revision['revision'] != state.revision) {
        throw const FormatException('Observed app revision mismatches.');
      }
    }
  }
}

typedef UpdateLedgerWriter = Future<bool> Function(String value);
typedef UpdateLedgerEvidenceWriter = Future<bool> Function(String value);

/// One global ledger mutation primitive plus per-target operation locks.
final class UpdateTransactionCoordinator {
  UpdateTransactionCoordinator({
    UpdateLedgerWriter? writer,
    UpdateLedgerEvidenceWriter? evidenceWriter,
  })  : _writer = writer,
        _evidenceWriter = evidenceWriter;

  static const storageKey = 'secure_update_ledger_v1';
  static const backupKey = 'secure_update_ledger_lkg_v1';
  static const corruptEvidenceKey = 'secure_update_ledger_corrupt_v1';
  static const maxBytes = 256 * 1024;
  static const maxRecordsPerMap = 128;
  static final Map<String, Future<void>> _targetTails = {};
  static Future<void> _ledgerTail = Future<void>.value();

  final UpdateLedgerWriter? _writer;
  final UpdateLedgerEvidenceWriter? _evidenceWriter;

  Future<T> run<T>(String targetId, Future<T> Function() action) async {
    if (!_targetId.hasMatch(targetId)) {
      throw const FormatException('Update target ID is invalid.');
    }
    final previous = _targetTails[targetId] ?? Future<void>.value();
    final release = Completer<void>();
    _targetTails[targetId] = release.future;
    await previous.catchError((_) {});
    try {
      return await action();
    } finally {
      release.complete();
      if (identical(_targetTails[targetId], release.future)) {
        _targetTails.remove(targetId);
      }
    }
  }

  Future<UpdateLedger> load() => _withLedgerLock(() async {
        final prefs = await SharedPreferences.getInstance();
        return _loadPrimary(prefs);
      });

  /// Merges only keys changed since [ledger] was loaded. Unrelated concurrent
  /// target changes are retained; same-key conflicts fail closed.
  Future<void> save(UpdateLedger ledger) => _withLedgerLock(() async {
        final prefs = await SharedPreferences.getInstance();
        final current = _loadPrimary(prefs);
        final base = UpdateLedger.parse(ledger._base);
        final merged = _merge(base, ledger, current);
        merged.generation = current.generation + 1;
        final encoded = _encodeChecked(merged);
        final currentEncoded = _encodeChecked(current);
        if (!await prefs.setString(backupKey, currentEncoded)) {
          throw StateError('Unable to persist last-known-good update ledger.');
        }
        final saved = _writer == null
            ? await prefs.setString(storageKey, encoded)
            : await _writer(encoded);
        if (!saved) throw StateError('Unable to persist update transaction.');
        ledger.generation = merged.generation;
        ledger.revisions
          ..clear()
          ..addAll(merged.revisions);
        ledger.extensionStates
          ..clear()
          ..addAll(merged.extensionStates);
        ledger.transactions
          ..clear()
          ..addAll(merged.transactions);
        ledger.appStates
          ..clear()
          ..addAll(merged.appStates);
        ledger._base = encoded;
      });

  Future<void> recoverLastKnownGood() => _withLedgerLock(() async {
        final prefs = await SharedPreferences.getInstance();
        final primary = prefs.getString(storageKey);
        try {
          _loadPrimary(prefs);
          return;
        } catch (_) {
          final backup = prefs.getString(backupKey);
          if (backup == null || backup.isEmpty) {
            throw StateError('No last-known-good update ledger is available.');
          }
          if (primary != null && utf8.encode(primary).length > maxBytes) {
            throw StateError('Corrupt update ledger evidence is oversized.');
          }
          final recovered = UpdateLedger.parse(backup);
          final recoveredEncoded = _encodeChecked(recovered);
          final evidence = primary ?? '';
          final evidenceSaved = _evidenceWriter == null
              ? await prefs.setString(corruptEvidenceKey, evidence)
              : await _evidenceWriter(evidence);
          if (!evidenceSaved) {
            throw StateError('Unable to preserve corrupt ledger evidence.');
          }
          if (!await prefs.setString(storageKey, recoveredEncoded)) {
            throw StateError('Unable to restore update ledger.');
          }
        }
      });

  UpdateLedger _loadPrimary(SharedPreferences prefs) {
    final primary = prefs.getString(storageKey);
    if (primary == null || primary.isEmpty) {
      final hasRecoveryEvidence =
          (prefs.getString(backupKey)?.isNotEmpty ?? false) ||
              prefs.containsKey(corruptEvidenceKey);
      if (hasRecoveryEvidence) {
        throw const UpdateLedgerCorruptException(
          'Secure update state is missing; explicit recovery is required.',
        );
      }
    }
    return _parsePrimary(primary);
  }

  UpdateLedger _parsePrimary(String? source) {
    try {
      return UpdateLedger.parse(source);
    } catch (error) {
      throw UpdateLedgerCorruptException(
        'Secure update state is corrupt; explicit recovery is required '
        '(${error.runtimeType}).',
      );
    }
  }

  static Future<T> _withLedgerLock<T>(Future<T> Function() action) async {
    final previous = _ledgerTail;
    final release = Completer<void>();
    _ledgerTail = release.future;
    await previous.catchError((_) {});
    try {
      return await action();
    } finally {
      release.complete();
    }
  }

  static UpdateLedger _merge(
    UpdateLedger base,
    UpdateLedger proposed,
    UpdateLedger current,
  ) {
    final merged = UpdateLedger.parse(_encodeChecked(current));
    _mergeMap(base.revisions, proposed.revisions, merged.revisions);
    _mergeMap(
      base.extensionStates,
      proposed.extensionStates,
      merged.extensionStates,
    );
    _mergeMap(base.transactions, proposed.transactions, merged.transactions);
    _mergeMap(base.appStates, proposed.appStates, merged.appStates);
    merged._validateCrossFields();
    return merged;
  }

  static void _mergeMap<T>(
      Map<String, T> base, Map<String, T> proposed, Map<String, T> current) {
    final keys = <String>{...base.keys, ...proposed.keys};
    for (final key in keys) {
      final baseValue = base[key];
      final proposedValue = proposed[key];
      if (_same(baseValue, proposedValue)) continue;
      if (!_same(current[key], baseValue)) {
        throw StateError('Concurrent update ledger conflict.');
      }
      if (proposed.containsKey(key)) {
        current[key] = proposedValue as T;
      } else {
        current.remove(key);
      }
    }
  }
}

String _encodeChecked(UpdateLedger ledger) {
  if (ledger.revisions.length > UpdateTransactionCoordinator.maxRecordsPerMap ||
      ledger.extensionStates.length >
          UpdateTransactionCoordinator.maxRecordsPerMap ||
      ledger.transactions.length >
          UpdateTransactionCoordinator.maxRecordsPerMap ||
      ledger.appStates.length > UpdateTransactionCoordinator.maxRecordsPerMap) {
    throw const FormatException('Update ledger record limit exceeded.');
  }
  ledger._validateCrossFields();
  final encoded = jsonEncode(ledger.toJson());
  if (utf8.encode(encoded).length > UpdateTransactionCoordinator.maxBytes) {
    throw const FormatException('Update ledger encoded size exceeded.');
  }
  UpdateLedger.parse(encoded);
  return encoded;
}

Map<String, dynamic> _boundedMap(Object? value) {
  if (value is! Map ||
      value.length > UpdateTransactionCoordinator.maxRecordsPerMap) {
    throw const FormatException('Stored update ledger map is invalid.');
  }
  return Map<String, dynamic>.from(value);
}

Map<String, dynamic> _object(Object? value) {
  if (value is! Map) throw const FormatException('Expected an object.');
  return Map<String, dynamic>.from(value);
}

String _string(Object? value) {
  if (value is! String || value.isEmpty || value.trim() != value) {
    throw const FormatException('Expected a bounded string.');
  }
  return value;
}

int _integer(Object? value) {
  if (value is! int) throw const FormatException('Expected an integer.');
  return value;
}

void _requireExactKeys(Map<String, dynamic> value, Set<String> expected) {
  if (value.length != expected.length ||
      !expected.every(value.containsKey) ||
      value.keys.any((key) => !expected.contains(key))) {
    throw const FormatException('Stored update ledger fields are invalid.');
  }
}

bool _same(Object? left, Object? right) =>
    jsonEncode(_jsonValue(left)) == jsonEncode(_jsonValue(right));

Object? _jsonValue(Object? value) => switch (value) {
      DurableUpdateTransaction transaction => transaction.toJson(),
      AppUpdateStagingState state => state.toJson(),
      _ => value,
    };

bool _safeAppPath(String value) {
  if (!value.startsWith('/') ||
      value.contains('/../') ||
      value.contains('/./')) {
    return false;
  }
  final name = value.split('/').last;
  return value.contains('/updates/') &&
      name.startsWith('verified-androidApp-') &&
      name.endsWith('.apk');
}

bool _safeBackupPath(String id, String value) {
  final base = '/root/workspace/.skill-update-backups/$id';
  if (value == base) return true;
  if (!value.startsWith('$base/')) return false;
  return _transactionId.hasMatch(value.substring(base.length + 1));
}

bool _safeFailedPath(String id, String transactionId, String value) =>
    value == '/root/workspace/.skill-update-failures/$id/$transactionId';

final _digest = RegExp(r'^[a-f0-9]{64}$');
final _targetId = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]{1,127}$');
final _transactionId = RegExp(
  r'^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$',
);
final _semanticVersion = RegExp(
  r'^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$',
);
