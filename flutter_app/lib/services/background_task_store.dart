import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/background_task.dart';
import 'strict_json_decoder.dart';

abstract interface class BackgroundTaskStore {
  Future<BackgroundTaskRecord?> read(String taskId);
  Future<List<BackgroundTaskRecord>> readAll();
  Future<void> write(BackgroundTaskRecord record);
}

abstract interface class BackgroundTaskProtectedStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

final class FlutterSecureBackgroundTaskStorage
    implements BackgroundTaskProtectedStorage {
  FlutterSecureBackgroundTaskStorage({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
}

/// A local protected-store implementation that serializes the complete task
/// set in one encrypted value. The serialized mutation tail prevents in-process
/// interleaving; callers must still reconcile a malformed persisted value
/// before they make an execution decision.
final class SecureBackgroundTaskStore implements BackgroundTaskStore {
  SecureBackgroundTaskStore({
    BackgroundTaskProtectedStorage? storage,
    this.maxRecords = 32,
  }) : _storage = storage ?? FlutterSecureBackgroundTaskStorage();

  static const storageKey = 'clawchat_background_tasks_v1';

  final BackgroundTaskProtectedStorage _storage;
  final int maxRecords;
  Future<void> _mutationTail = Future<void>.value();

  @override
  Future<BackgroundTaskRecord?> read(String taskId) async {
    final records = await readAll();
    for (final record in records) {
      if (record.taskId == taskId) return record;
    }
    return null;
  }

  @override
  Future<List<BackgroundTaskRecord>> readAll() async {
    final source = await _storage.read(storageKey);
    if (source == null) return const [];
    try {
      final decoded = StrictJsonDecoder(
        maxUtf8Bytes: maxBackgroundTaskRecordBytes * maxRecords,
        maxNestingDepth: 32,
      ).decodeString(source);
      if (decoded is! Map) {
        throw const BackgroundTaskFormatException('task_store_schema_invalid');
      }
      final root = Map<String, Object?>.from(decoded);
      if (root.length != 2 ||
          root['schemaVersion'] != backgroundTaskSchemaVersion ||
          root['records'] is! List) {
        throw const BackgroundTaskFormatException('task_store_schema_invalid');
      }
      final rawRecords = root['records'] as List;
      if (rawRecords.length > maxRecords) {
        throw const BackgroundTaskFormatException('task_store_record_limit');
      }
      final records = <BackgroundTaskRecord>[];
      final ids = <String>{};
      for (final value in rawRecords) {
        final record = BackgroundTaskRecord.fromJson(value);
        if (!ids.add(record.taskId)) {
          throw const BackgroundTaskFormatException('task_store_duplicate_id');
        }
        records.add(record);
      }
      return List.unmodifiable(records);
    } on BackgroundTaskFormatException {
      rethrow;
    } on StrictJsonDecodeException catch (error) {
      throw BackgroundTaskFormatException('task_store_${error.reasonCode}');
    }
  }

  @override
  Future<void> write(BackgroundTaskRecord record) => _serialize(() async {
        final records = (await readAll()).toList(growable: true);
        final index = records
            .indexWhere((candidate) => candidate.taskId == record.taskId);
        if (index >= 0) {
          records[index] = record;
        } else {
          if (records.length >= maxRecords) {
            throw const BackgroundTaskFormatException(
                'task_store_record_limit');
          }
          records.add(record);
        }
        final payload = jsonEncode({
          'schemaVersion': backgroundTaskSchemaVersion,
          'records': records.map((item) => item.toJson()).toList(),
        });
        if (utf8.encode(payload).length >
            maxBackgroundTaskRecordBytes * maxRecords) {
          throw const BackgroundTaskFormatException('task_store_too_large');
        }
        await _storage.write(storageKey, payload);
      });

  Future<void> _serialize(Future<void> Function() operation) {
    final completer = Completer<void>();
    _mutationTail = _mutationTail.catchError((_) {}).then((_) async {
      try {
        await operation();
        completer.complete();
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}

final class InMemoryBackgroundTaskStore implements BackgroundTaskStore {
  final Map<String, BackgroundTaskRecord> _records = {};

  @override
  Future<BackgroundTaskRecord?> read(String taskId) async => _records[taskId];

  @override
  Future<List<BackgroundTaskRecord>> readAll() async =>
      List.unmodifiable(_records.values);

  @override
  Future<void> write(BackgroundTaskRecord record) async {
    // Route through the strict serializer so tests use the same bounds/parser
    // as the protected-store implementation.
    _records[record.taskId] = BackgroundTaskRecord.fromJson(record.toJson());
  }
}
