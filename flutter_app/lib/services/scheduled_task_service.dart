import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/scheduled_task.dart';
import 'strict_json_decoder.dart';

/// Persistence for local schedules. Implementations are intentionally dumb:
/// they never execute a task and never touch the background-task store.
abstract interface class ScheduledTaskStore {
  Future<List<ScheduledTaskRecord>> readAll();
  Future<void> writeAll(List<ScheduledTaskRecord> records);
}

const int _maxScheduledTaskRecordBytes = 4 * 1024;

final class SharedPreferencesScheduledTaskStore implements ScheduledTaskStore {
  SharedPreferencesScheduledTaskStore({
    Future<SharedPreferences> Function()? preferencesFactory,
  }) : _preferencesFactory =
            preferencesFactory ?? SharedPreferences.getInstance;

  static const storageKey = 'clawchat_scheduled_tasks_v1';

  final Future<SharedPreferences> Function() _preferencesFactory;
  Future<void> _mutationTail = Future<void>.value();

  @override
  Future<List<ScheduledTaskRecord>> readAll() async {
    final prefs = await _preferencesFactory();
    final source = prefs.getString(storageKey);
    if (source == null || source.isEmpty) return const [];
    try {
      final decoded = const StrictJsonDecoder(
        maxUtf8Bytes: _maxScheduledTaskRecordBytes * maxScheduledTaskRecords,
        maxNestingDepth: 24,
      ).decodeString(source);
      if (decoded is! Map) {
        throw const ScheduledTaskFormatException('store_schema_invalid');
      }
      final root = Map<String, Object?>.from(decoded);
      if (root.length != 2 ||
          root['schemaVersion'] != scheduledTaskSchemaVersion ||
          root['records'] is! List) {
        throw const ScheduledTaskFormatException('store_schema_invalid');
      }
      final rawRecords = root['records'] as List;
      if (rawRecords.length > maxScheduledTaskRecords) {
        throw const ScheduledTaskFormatException('store_record_limit');
      }
      final records = <ScheduledTaskRecord>[];
      final ids = <String>{};
      for (final value in rawRecords) {
        final record = ScheduledTaskRecord.fromJson(value);
        if (!ids.add(record.scheduleId)) {
          throw const ScheduledTaskFormatException('store_duplicate_id');
        }
        records.add(record);
      }
      return List.unmodifiable(records);
    } on ScheduledTaskFormatException {
      rethrow;
    } on StrictJsonDecodeException catch (error) {
      throw ScheduledTaskFormatException('store_${error.reasonCode}');
    }
  }

  @override
  Future<void> writeAll(List<ScheduledTaskRecord> records) => _serialize(() async {
        if (records.length > maxScheduledTaskRecords) {
          throw const ScheduledTaskFormatException('store_record_limit');
        }
        final ordered = [...records]
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
        final payload = jsonEncode({
          'schemaVersion': scheduledTaskSchemaVersion,
          'records': ordered.map((record) => record.toJson()).toList(),
        });
        if (utf8.encode(payload).length >
            _maxScheduledTaskRecordBytes * maxScheduledTaskRecords) {
          throw const ScheduledTaskFormatException('store_too_large');
        }
        final prefs = await _preferencesFactory();
        await prefs.setString(storageKey, payload);
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

final class InMemoryScheduledTaskStore implements ScheduledTaskStore {
  final Map<String, ScheduledTaskRecord> _records = {};

  @override
  Future<List<ScheduledTaskRecord>> readAll() async =>
      List.unmodifiable(_records.values);

  @override
  Future<void> writeAll(List<ScheduledTaskRecord> records) async {
    _records
      ..clear()
      ..addEntries(records.map((record) => MapEntry(record.scheduleId, record)));
  }
}

/// Local owner of scheduled-task plans.
///
/// The service only persists and advances plans. It deliberately exposes no
/// dispatch, model, share, SMS, or phone entry point: a due plan is surfaced to
/// the existing background-task approval flow, and [markRun] records the
/// outcome that flow already decided.
final class ScheduledTaskService {
  ScheduledTaskService({
    ScheduledTaskStore? store,
    DateTime Function()? clock,
    String Function()? newId,
  })  : _store = store ?? SharedPreferencesScheduledTaskStore(),
        _clock = clock ?? DateTime.now,
        _newId = newId ?? _defaultScheduleId;

  final ScheduledTaskStore _store;
  final DateTime Function() _clock;
  final String Function() _newId;

  Future<List<ScheduledTaskRecord>> list() async => _sorted(await _safeRead());

  Future<List<ScheduledTaskRecord>> due([DateTime? now]) async {
    final at = (now ?? _clock()).toUtc();
    return List.unmodifiable(
      _sorted(await _safeRead()).where((record) => record.isDue(at)),
    );
  }

  Future<ScheduledTaskRecord?> findByTaskId(String taskId) async {
    for (final record in await _safeRead()) {
      if (record.taskId == taskId) return record;
    }
    return null;
  }

  Future<ScheduledTaskRecord?> findById(String scheduleId) async {
    for (final record in await _safeRead()) {
      if (record.scheduleId == scheduleId) return record;
    }
    return null;
  }

  /// Creates one plan for an existing background task.
  ///
  /// Rejects a second plan for the same task and refuses to exceed the local
  /// record bound; nothing is executed.
  Future<ScheduledTaskRecord> create({
    required String taskId,
    required String kind,
    required ScheduledTaskCadence cadence,
    required DateTime firstRunAt,
    int intervalMinutes = 60,
  }) async {
    final normalizedTaskId = _requireSafeSegment(taskId, 'task_id_invalid');
    final normalizedKind = _requireSafeSegment(kind, 'kind_invalid');
    final interval = _normalizeInterval(cadence, intervalMinutes);
    final records = (await _safeRead()).toList(growable: true);
    if (records.any((record) => record.taskId == normalizedTaskId)) {
      throw const ScheduledTaskFormatException('schedule_already_exists');
    }
    if (records.length >= maxScheduledTaskRecords) {
      throw const ScheduledTaskFormatException('store_record_limit');
    }
    final now = _clock().toUtc();
    final record = ScheduledTaskRecord(
      scheduleId: _newId(),
      taskId: normalizedTaskId,
      kind: normalizedKind,
      cadence: cadence,
      intervalMinutes: interval,
      nextRunAt: firstRunAt.toUtc(),
      paused: false,
      createdAt: now,
      updatedAt: now,
    );
    records.add(record);
    await _store.writeAll(records);
    return record;
  }

  Future<bool> pause(String scheduleId) => _update(
        scheduleId,
        (record) => record.paused || record.isFinished
            ? null
            : record.copyWith(paused: true, updatedAt: _clock().toUtc()),
      );

  /// Resumes a paused or finished plan. A consumed `interval` plan is
  /// rescheduled from now; a consumed `once` plan needs an explicit
  /// [nextRunAt].
  Future<bool> resume(String scheduleId, {DateTime? nextRunAt}) => _update(
        scheduleId,
        (record) {
          if (!record.paused && !record.isFinished) return null;
          final now = _clock().toUtc();
          var next = record.nextRunAt;
          if (next == null) {
            if (record.cadence == ScheduledTaskCadence.once) {
              next = nextRunAt?.toUtc();
              if (next == null) return null;
            } else {
              next = (nextRunAt?.toUtc() ?? now)
                  .add(Duration(minutes: record.intervalMinutes));
            }
          } else if (!next.isAfter(now)) {
            // A resume of an overdue plan never fires immediately; the user
            // still confirms the actual run in the task center.
            next = nextRunAt?.toUtc() ?? now.add(const Duration(minutes: 1));
          }
          return record.copyWith(
            paused: false,
            nextRunAt: next,
            updatedAt: now,
          );
        },
      );

  Future<bool> delete(String scheduleId) async {
    final records = (await _safeRead()).toList(growable: true);
    final before = records.length;
    records.removeWhere((record) => record.scheduleId == scheduleId);
    if (records.length == before) return false;
    await _store.writeAll(records);
    return true;
  }

  /// Records the terminal outcome of one *already approved* run.
  Future<ScheduledTaskRecord?> markRun({
    required String scheduleId,
    required String backgroundTaskId,
    required String state,
    DateTime? now,
  }) async {
    final normalizedState = _requireSafeSegment(state, 'state_invalid');
    final normalizedTaskId =
        _requireSafeSegment(backgroundTaskId, 'run_task_id_invalid');
    final records = (await _safeRead()).toList(growable: true);
    final index =
        records.indexWhere((record) => record.scheduleId == scheduleId);
    if (index < 0) return null;
    final updated = records[index].afterRun(
      backgroundTaskId: normalizedTaskId,
      state: normalizedState,
      now: (now ?? _clock()).toUtc(),
    );
    records[index] = updated;
    await _store.writeAll(records);
    return updated;
  }

  Future<bool> _update(
    String scheduleId,
    ScheduledTaskRecord? Function(ScheduledTaskRecord record) transform,
  ) async {
    final records = (await _safeRead()).toList(growable: true);
    final index =
        records.indexWhere((record) => record.scheduleId == scheduleId);
    if (index < 0) return false;
    final updated = transform(records[index]);
    if (updated == null) return false;
    records[index] = updated;
    await _store.writeAll(records);
    return true;
  }

  Future<List<ScheduledTaskRecord>> _safeRead() async {
    try {
      return await _store.readAll();
    } on ScheduledTaskFormatException {
      rethrow;
    } on Object {
      throw const ScheduledTaskFormatException('store_unavailable');
    }
  }

  List<ScheduledTaskRecord> _sorted(List<ScheduledTaskRecord> records) {
    final sorted = records.toList(growable: false)
      ..sort((a, b) {
        final aNext = a.nextRunAt;
        final bNext = b.nextRunAt;
        if (aNext == null && bNext == null) {
          return b.updatedAt.compareTo(a.updatedAt);
        }
        if (aNext == null) return 1;
        if (bNext == null) return -1;
        return aNext.compareTo(bNext);
      });
    return List.unmodifiable(sorted);
  }

  static String _defaultScheduleId() =>
      'schedule_${DateTime.now().microsecondsSinceEpoch}';

  static int _normalizeInterval(
    ScheduledTaskCadence cadence,
    int intervalMinutes,
  ) {
    if (cadence == ScheduledTaskCadence.once) return 0;
    if (intervalMinutes < minScheduledIntervalMinutes ||
        intervalMinutes > maxScheduledIntervalMinutes) {
      throw const ScheduledTaskFormatException('schedule_interval_invalid');
    }
    return intervalMinutes;
  }

  static String _requireSafeSegment(String value, String reasonCode) {
    final trimmed = value.trim();
    if (trimmed.isEmpty ||
        trimmed.length > 64 ||
        trimmed.contains(RegExp(r'[^A-Za-z0-9._:-]'))) {
      throw ScheduledTaskFormatException(reasonCode);
    }
    return trimmed;
  }
}
