import 'background_task.dart';

/// Schema/bounds for the local scheduled-task store.
///
/// A schedule is a *local reminder plan* for an existing background task. It
/// never carries the task payload itself (that stays in the encrypted
/// background-task store) and it never executes anything: when a plan is due,
/// the UI surfaces it and the normal background-task approval/dispatch flow
/// still decides whether anything runs.
const int scheduledTaskSchemaVersion = 1;
const int maxScheduledTaskRecords = 32;
const int maxScheduledTaskHistoryEntries = 20;

/// Shortest allowed interval, in minutes.
const int minScheduledIntervalMinutes = 15;

/// Longest allowed interval, in minutes (24 hours).
const int maxScheduledIntervalMinutes = 24 * 60;

final class ScheduledTaskFormatException implements Exception {
  const ScheduledTaskFormatException(this.reasonCode);

  final String reasonCode;

  @override
  String toString() => 'ScheduledTaskFormatException($reasonCode)';
}

/// How a schedule repeats.
enum ScheduledTaskCadence {
  /// Runs once at [ScheduledTaskRecord.nextRunAt], then stops.
  once,

  /// Runs every [ScheduledTaskRecord.intervalMinutes] after the first run.
  interval,
}

extension ScheduledTaskCadenceWire on ScheduledTaskCadence {
  String get wireValue => switch (this) {
        ScheduledTaskCadence.once => 'once',
        ScheduledTaskCadence.interval => 'interval',
      };

  static ScheduledTaskCadence parse(Object? value) => switch (value) {
        'once' => ScheduledTaskCadence.once,
        'interval' => ScheduledTaskCadence.interval,
        _ => throw const ScheduledTaskFormatException('cadence_invalid'),
      };
}

/// One bounded history entry: what was launched, when, and how it ended.
final class ScheduledTaskRunRecord {
  const ScheduledTaskRunRecord({
    required this.backgroundTaskId,
    required this.startedAt,
    required this.state,
  });

  final String backgroundTaskId;
  final DateTime startedAt;

  /// A [BackgroundTaskState] wire value; kept as a string so a future state
  /// does not make an old history entry unreadable.
  final String state;

  bool get succeeded => state == BackgroundTaskState.succeeded.wireValue;

  Map<String, Object?> toJson() => {
        'backgroundTaskId': backgroundTaskId,
        'startedAt': startedAt.toUtc().toIso8601String(),
        'state': state,
      };

  factory ScheduledTaskRunRecord.fromJson(Object? value) {
    final json = _requiredMap(value, 'run_invalid');
    return ScheduledTaskRunRecord(
      backgroundTaskId:
          _boundedString(json['backgroundTaskId'], 'run_task_id_invalid', 64),
      startedAt: _requiredDate(json['startedAt'], 'run_started_at_invalid'),
      state: _boundedString(json['state'], 'run_state_invalid', 32),
    );
  }
}

/// A persisted schedule. The referenced background task owns the payload and
/// the approval state.
final class ScheduledTaskRecord {
  const ScheduledTaskRecord({
    required this.scheduleId,
    required this.taskId,
    required this.kind,
    required this.cadence,
    required this.intervalMinutes,
    required this.nextRunAt,
    required this.paused,
    required this.createdAt,
    required this.updatedAt,
    this.lastRunAt,
    this.lastState,
    this.failureCount = 0,
    this.history = const [],
  });

  final String scheduleId;
  final String taskId;
  final String kind;
  final ScheduledTaskCadence cadence;

  /// Interval in minutes for [ScheduledTaskCadence.interval]; 0 for `once`.
  final int intervalMinutes;

  /// Next planned run, or null when the plan is finished (a consumed `once`).
  final DateTime? nextRunAt;
  final bool paused;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? lastRunAt;

  /// Last observed background-task state wire value.
  final String? lastState;
  final int failureCount;

  /// Newest first, bounded to [maxScheduledTaskHistoryEntries].
  final List<ScheduledTaskRunRecord> history;

  bool get isFinished => nextRunAt == null;
  bool get isActive => !paused && !isFinished;

  bool isDue(DateTime now) => isActive && !nextRunAt!.isAfter(now);

  int get retryLimit => 3;

  bool get canRetryAfterFailure => failureCount < retryLimit;

  /// The user-visible "next run / retry" line.
  String nextRunSummary(DateTime now) {
    if (paused) return '已暂停';
    if (nextRunAt == null) return '已完成';
    final at = nextRunAt!;
    final delta = at.difference(now);
    if (delta.isNegative || delta == Duration.zero) return '等待确认执行';
    final minutes = delta.inMinutes;
    if (minutes < 60) return '$minutes 分钟后';
    final hours = delta.inHours;
    if (hours < 24) return '$hours 小时后';
    return '${delta.inDays} 天后';
  }

  String get lastOutcomeSummary {
    if (lastState == null) return '尚未执行';
    if (lastState == BackgroundTaskState.succeeded.wireValue) return '上次成功';
    if (failureCount > 0 && canRetryAfterFailure) {
      return '上次失败，将按计划重试（第 $failureCount 次）';
    }
    if (failureCount > 0) return '上次失败，重试次数已达上限';
    return '上次状态：$lastState';
  }

  /// Applies the outcome of one approved run and advances the plan.
  ///
  /// * `once` is consumed regardless of outcome.
  /// * `interval` advances one interval from the planned time, so a late
  ///   confirmation does not fire a catch-up storm.
  ScheduledTaskRecord afterRun({
    required String backgroundTaskId,
    required String state,
    required DateTime now,
  }) {
    final succeeded = state == BackgroundTaskState.succeeded.wireValue;
    final historyEntry = ScheduledTaskRunRecord(
      backgroundTaskId: backgroundTaskId,
      startedAt: now,
      state: state,
    );
    final nextHistory = [historyEntry, ...history]
        .take(maxScheduledTaskHistoryEntries)
        .toList(growable: false);
    final nextRunAt = switch (cadence) {
      ScheduledTaskCadence.once => null,
      ScheduledTaskCadence.interval => _plannedNextRun(now),
    };
    return copyWith(
      nextRunAt: nextRunAt,
      clearNextRunAt: nextRunAt == null,
      lastRunAt: now,
      lastState: state,
      failureCount: succeeded
          ? 0
          : (failureCount + 1).clamp(0, retryLimit + 1),
      history: nextHistory,
      updatedAt: now,
    );
  }

  DateTime _plannedNextRun(DateTime now) {
    final base = nextRunAt ?? now;
    var candidate = base.add(Duration(minutes: intervalMinutes));
    if (candidate.isBefore(now)) {
      // A long-paused plan skips missed occurrences instead of replaying them.
      final step = Duration(minutes: intervalMinutes);
      final missed = now.difference(candidate).inMilliseconds ~/ step.inMilliseconds;
      candidate = candidate.add(step * (missed + 1));
    }
    return candidate;
  }

  ScheduledTaskRecord copyWith({
    String? scheduleId,
    String? taskId,
    String? kind,
    ScheduledTaskCadence? cadence,
    int? intervalMinutes,
    DateTime? nextRunAt,
    bool clearNextRunAt = false,
    bool? paused,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? lastRunAt,
    String? lastState,
    int? failureCount,
    List<ScheduledTaskRunRecord>? history,
  }) {
    return ScheduledTaskRecord(
      scheduleId: scheduleId ?? this.scheduleId,
      taskId: taskId ?? this.taskId,
      kind: kind ?? this.kind,
      cadence: cadence ?? this.cadence,
      intervalMinutes: intervalMinutes ?? this.intervalMinutes,
      nextRunAt: clearNextRunAt ? null : (nextRunAt ?? this.nextRunAt),
      paused: paused ?? this.paused,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      lastRunAt: lastRunAt ?? this.lastRunAt,
      lastState: lastState ?? this.lastState,
      failureCount: failureCount ?? this.failureCount,
      history: history ?? this.history,
    );
  }

  Map<String, Object?> toJson() => {
        'schemaVersion': scheduledTaskSchemaVersion,
        'scheduleId': scheduleId,
        'taskId': taskId,
        'kind': kind,
        'cadence': cadence.wireValue,
        'intervalMinutes': intervalMinutes,
        'nextRunAt': nextRunAt?.toUtc().toIso8601String(),
        'paused': paused,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        'lastRunAt': lastRunAt?.toUtc().toIso8601String(),
        'lastState': lastState,
        'failureCount': failureCount,
        'history': history.map((entry) => entry.toJson()).toList(),
      };

  factory ScheduledTaskRecord.fromJson(Object? value) {
    final json = _requiredMap(value, 'schedule_invalid');
    if (json['schemaVersion'] != scheduledTaskSchemaVersion) {
      throw const ScheduledTaskFormatException('schedule_schema_invalid');
    }
    final cadence = ScheduledTaskCadenceWire.parse(json['cadence']);
    final interval = json['intervalMinutes'];
    if (interval is! int || interval < 0 || interval > maxScheduledIntervalMinutes) {
      throw const ScheduledTaskFormatException('schedule_interval_invalid');
    }
    if (cadence == ScheduledTaskCadence.interval &&
        (interval < minScheduledIntervalMinutes ||
            interval > maxScheduledIntervalMinutes)) {
      throw const ScheduledTaskFormatException('schedule_interval_invalid');
    }
    final paused = json['paused'];
    if (paused is! bool) {
      throw const ScheduledTaskFormatException('schedule_paused_invalid');
    }
    final failureCount = json['failureCount'];
    if (failureCount is! int || failureCount < 0 || failureCount > 64) {
      throw const ScheduledTaskFormatException('schedule_failure_count_invalid');
    }
    final rawHistory = json['history'];
    if (rawHistory is! List ||
        rawHistory.length > maxScheduledTaskHistoryEntries) {
      throw const ScheduledTaskFormatException('schedule_history_invalid');
    }
    return ScheduledTaskRecord(
      scheduleId: _boundedString(json['scheduleId'], 'schedule_id_invalid', 64),
      taskId: _boundedString(json['taskId'], 'schedule_task_id_invalid', 64),
      kind: _boundedString(json['kind'], 'schedule_kind_invalid', 64),
      cadence: cadence,
      intervalMinutes: interval,
      nextRunAt: _nullableDate(json['nextRunAt'], 'schedule_next_run_invalid'),
      paused: paused,
      createdAt: _requiredDate(json['createdAt'], 'schedule_created_at_invalid'),
      updatedAt: _requiredDate(json['updatedAt'], 'schedule_updated_at_invalid'),
      lastRunAt: _nullableDate(json['lastRunAt'], 'schedule_last_run_invalid'),
      lastState: _nullableBoundedString(
        json['lastState'],
        'schedule_last_state_invalid',
        32,
      ),
      failureCount: failureCount,
      history: List<ScheduledTaskRunRecord>.unmodifiable(
        rawHistory.map(ScheduledTaskRunRecord.fromJson),
      ),
    );
  }
}

Map<String, Object?> _requiredMap(Object? value, String reasonCode) {
  if (value is! Map) {
    throw ScheduledTaskFormatException(reasonCode);
  }
  return Map<String, Object?>.from(value);
}

String _boundedString(Object? value, String reasonCode, int max) {
  if (value is! String || value.isEmpty || value.length > max) {
    throw ScheduledTaskFormatException(reasonCode);
  }
  for (final unit in value.codeUnits) {
    if (unit < 0x20 || unit == 0x7f) {
      throw ScheduledTaskFormatException(reasonCode);
    }
  }
  return value;
}

String? _nullableBoundedString(Object? value, String reasonCode, int max) {
  if (value == null) return null;
  return _boundedString(value, reasonCode, max);
}

DateTime _requiredDate(Object? value, String reasonCode) {
  final parsed = value is String ? DateTime.tryParse(value) : null;
  if (parsed == null) {
    throw ScheduledTaskFormatException(reasonCode);
  }
  return parsed.toUtc();
}

DateTime? _nullableDate(Object? value, String reasonCode) {
  if (value == null) return null;
  return _requiredDate(value, reasonCode);
}
