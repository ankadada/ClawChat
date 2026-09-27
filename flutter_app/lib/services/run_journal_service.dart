import 'dart:async';
import 'dart:convert';

import '../models/chat_models.dart';
import '../models/run_journal.dart';
import 'run_journal_store.dart';

/// Durable, bounded, redacted journal of agent runs and their tool attempts.
///
/// The journal is **display and diagnostics only**. It has no execution API:
/// it cannot start, retry, resume, or approve a run, and every public method
/// swallows storage failures so a journal problem can never break a run or a
/// cancellation. Writes are serialized so concurrent runs cannot interleave a
/// read-modify-write.
final class RunJournalService {
  RunJournalService({
    RunJournalStore? store,
    DateTime Function()? clock,
    Duration? commitTimeout,
  })  : _store = store ?? SecureRunJournalStore(),
        _clock = clock ?? DateTime.now,
        _commitTimeout = commitTimeout ?? RunJournalService.commitTimeout;

  /// Process-wide instance used by the chat provider and the journal screen.
  static RunJournalService instance = RunJournalService();

  /// Bounded wait for one critical journal commit.
  ///
  /// A slow or hanging encrypted write must never hang a run, but it must not
  /// be silent either: on timeout the run is marked incomplete so the journal
  /// UI can say the record may be missing instead of pretending it is whole.
  static const commitTimeout = Duration(seconds: 2);

  /// Replaces the shared instance; tests must restore it in tearDown.
  static void resetForTesting([RunJournalService? service]) {
    instance = service ?? RunJournalService();
  }

  /// Sentinel for the byte budget: the store writes an envelope (schema,
  /// revision, checksum) around the runs, so the service reserves room for it
  /// instead of trimming to the exact hard limit and then being rejected.
  static const envelopeReserveBytes = 512;

  /// Upper bound on queued commits. Once the writer is wedged and this many
  /// commits are waiting, further commits fail immediately (and are reported as
  /// incomplete) instead of growing the queue without bound.
  static const maxPendingCommits = 8;

  final RunJournalStore _store;
  final DateTime Function() _clock;
  final Duration _commitTimeout;

  /// Explicit writer queue: commits run strictly one at a time, and each waits
  /// for its own completion future rather than another operation's (so a zone
  /// change can never wedge the queue). The store's monotonic revision is the
  /// second net: a payload that lands out of order is atomically rejected.
  bool _busy = false;
  final List<void Function()> _queue = <void Function()>[];

  /// Monotonic journal revision. It is persisted with every payload so a store
  /// can atomically reject a stale write that arrives late.
  int _revision = 0;

  /// True when the last read found the store missing, corrupt, or unreadable.
  /// The journal then shows nothing but keeps accepting new runs.
  bool _readFailed = false;
  bool get readFailed => _readFailed;

  /// True when a critical commit failed or timed out. The journal UI surfaces
  /// it; it never grants or removes execution authority.
  bool _writeFailed = false;
  bool get writeFailed => _writeFailed;

  /// Runs whose last critical commit did not land: their record may be
  /// incomplete, so the UI must not present them as a complete trajectory.
  final Set<String> _incompleteRunIds = <String>{};
  bool isRunIncomplete(String runAttemptId) =>
      _incompleteRunIds.contains(runAttemptId);
  bool get hasIncompleteRuns => _incompleteRunIds.isNotEmpty;

  /// Sticky by design: once a run's commit failed, a later successful commit
  /// for the *same* run never erases the gap - its trajectory may already be
  /// missing a link. Only a new `runAttemptId` (or `clear()`, or pruning the
  /// record away) starts clean.
  void _markCommitSucceeded(String runAttemptId) {
    // Intentionally empty: see the doc comment.
  }

  void _markCommitFailed(String runAttemptId) {
    _writeFailed = true;
    _incompleteRunIds.add(runAttemptId);
  }

  /// Concurrent read-modify-write operations are serialized here.
  ///
  /// The queue is bounded on the wall clock: a link that has already been
  /// pending longer than [commitTimeout] is abandoned instead of being awaited,
  /// so one store that never answers cannot wedge every later commit (the
  /// caller only ever waits one bound, and the queue keeps moving). This is the
  /// deadlock guard for the commit barrier.
  Future<void> _serialize(Future<void> Function() operation) {
    final completer = Completer<void>();

    void run() {
      _busy = true;
      unawaited(() async {
        try {
          await operation();
          completer.complete();
        } catch (error, stackTrace) {
          completer.completeError(error, stackTrace);
        } finally {
          _busy = false;
          if (_queue.isNotEmpty) {
            scheduleMicrotask(_queue.removeAt(0));
          }
        }
      }());
    }

    if (_busy || _queue.isNotEmpty) {
      if (_queue.length >= maxPendingCommits) {
        // The writer is wedged and the backlog is full: fail the new commit
        // immediately (its caller records the gap) instead of growing the
        // queue without bound.
        throw StateError('run_journal_writer_backlog');
      }
      _queue.add(run);
    } else {
      run();
    }
    return completer.future;
  }

  /// Creates (or revives) the entry for [runAttemptId].
  ///
  /// Starting a run also prunes the journal to [maxRunJournalEntries].
  Future<RunJournalEntry?> beginRun({
    required String runAttemptId,
    required String sessionId,
    DateTime? now,
  }) async {
    if (!_isSafeId(runAttemptId) || !_isSafeId(sessionId)) return null;
    final startedAt = (now ?? _clock()).toUtc();
    return _mutate(runAttemptId, (entries) {
      final existing = entries[runAttemptId];
      final entry = existing ??
          RunJournalEntry(
            runAttemptId: runAttemptId,
            sessionId: sessionId,
            startedAt: startedAt,
            state: RunJournalState.running,
          );
      final next = entry.state == RunJournalState.running
          ? entry
          : entry.copyWith(state: RunJournalState.running, endedAt: startedAt);
      return (entries..[runAttemptId] = next, next);
    });
  }

  /// Mirrors the session recovery marker's tool attempts into the journal.
  ///
  /// Called whenever the marker changes; upserts by `operationId` and keeps the
  /// newest [maxRunJournalAttemptsPerEntry] attempts.
  Future<RunJournalEntry?> mirrorMarker({
    required String runAttemptId,
    required String sessionId,
    required Iterable<ToolAttemptRecoveryMetadata> attempts,
    DateTime? now,
  }) async {
    if (!_isSafeId(runAttemptId) || !_isSafeId(sessionId)) return null;
    final timestamp = (now ?? _clock()).toUtc();
    final mapped = [
      for (final attempt in attempts)
        RunJournalToolAttempt.fromRecoveryMetadata(attempt, now: timestamp),
    ];
    return _mutate(runAttemptId, (entries) {
      final entry = entries[runAttemptId] ??
          RunJournalEntry(
            runAttemptId: runAttemptId,
            sessionId: sessionId,
            startedAt: mapped.isEmpty ? timestamp : mapped.first.proposedAt,
            state: RunJournalState.running,
          );
      final next = entry.withAttempts(mapped);
      return (entries..[runAttemptId] = next, next);
    });
  }

  /// Ends a run.
  ///
  /// A success claim is downgraded to [RunJournalState.unknownOutcome] when any
  /// attempt has an unknown outcome or [outcomeKnown] is false; the journal
  /// never reports success it cannot prove. An entry that is already terminal
  /// is not reopened by a late end call.
  Future<RunJournalEntry?> endRun({
    required String runAttemptId,
    required RunJournalState state,
    String? endReason,
    bool outcomeKnown = true,
    DateTime? now,
  }) async {
    if (!_isSafeId(runAttemptId)) return null;
    if (state == RunJournalState.running) return null;
    final timestamp = (now ?? _clock()).toUtc();
    return _mutate(runAttemptId, (entries) {
      final entry = entries[runAttemptId];
      if (entry == null) return (entries, null);
      if (!entry.isActive) return (entries, entry);
      final reason = _sanitizeReason(endReason);
      // Fail closed: a terminal state that cannot prove the effects of every
      // attempt - or whose journal already lost a commit - is reported as an
      // unknown outcome, never as success, failure, or a clean cancellation.
      final effectiveState = switch (state) {
        RunJournalState.completed ||
        RunJournalState.cancelled ||
        RunJournalState.failed
            when !outcomeKnown ||
                entry.hasUnknownOutcome ||
                _incompleteRunIds.contains(runAttemptId) =>
          RunJournalState.unknownOutcome,
        _ => state,
      };
      final next = entry.copyWith(
        state: effectiveState,
        endedAt: timestamp,
        endReason: reason,
      );
      return (entries..[runAttemptId] = next, next);
    });
  }

  /// Marks every `running` entry that is not live in this process as
  /// interrupted, and every `started` attempt as an unknown outcome.
  ///
  /// This is the process-death recovery source: it only rewrites records, it
  /// never re-executes anything.
  Future<void> reconcileAtStartup({
    Iterable<String> liveRunAttemptIds = const [],
  }) async {
    final live = liveRunAttemptIds.toSet();
    final timestamp = _clock().toUtc();
    // An entry created after this call began belongs to a run that is (or just
    // was) live in this process, not to a previous one: never reconcile it.
    final cutoff = timestamp;
    try {
      await _serialize(() async {
        final entries = await _read();
        var changed = false;
        for (final id in entries.keys.toList()) {
          final entry = entries[id]!;
          if (!entry.isActive ||
              live.contains(id) ||
              entry.startedAt.isAfter(cutoff)) {
            continue;
          }
          entries[id] = entry.markInterrupted(timestamp);
          changed = true;
          _markCommitSucceeded(id);
        }
        if (changed) await _write(entries);
      });
      _writeFailed = false;
    } catch (_) {
      // A failed reconcile leaves the previous journal untouched; the startup
      // path never resumes anything either way.
      _writeFailed = true;
    }
  }

  /// Newest first.
  Future<List<RunJournalEntry>> recentRuns({int? limit}) async {
    try {
      final entries = await _read();
      final values = entries.values.toList()
        ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
      final bounded = limit == null || limit >= values.length
          ? values
          : values.sublist(0, limit);
      return List.unmodifiable(bounded);
    } catch (_) {
      return const [];
    }
  }

  Future<List<RunJournalEntry>> runsForSession(String sessionId) async {
    final runs = await recentRuns();
    return List.unmodifiable(
      runs.where((run) => run.sessionId == sessionId),
    );
  }

  /// The newest run for [sessionId] that still needs the user's attention.
  Future<RunJournalEntry?> pendingRunForSession(String sessionId) async {
    final runs = await runsForSession(sessionId);
    for (final run in runs) {
      if (run.requiresConfirmation) return run;
    }
    return null;
  }

  Future<void> clear() async {
    await _serialize(() async {
      try {
        await _store.clear();
        _readFailed = false;
        _incompleteRunIds.clear();
        _writeFailed = false;
      } catch (_) {
        // Clearing is best effort.
      }
    });
  }

  Future<RunJournalEntry?> _mutate(
    String runAttemptId,
    (Map<String, RunJournalEntry>, RunJournalEntry?) Function(
      Map<String, RunJournalEntry> entries,
    ) mutate,
  ) async {
    RunJournalEntry? changed;
    try {
      await _serialize(() async {
        final entries = await _read();
        final result = mutate(entries);
        changed = result.$2;
        if (changed == null) {
          return;
        }
        _prune(entries);
        await _write(entries);
      }).timeout(_commitTimeout);
      if (changed != null) _markCommitSucceeded(runAttemptId);
    } on TimeoutException {
      // The write may still land later; the record is marked incomplete so the
      // UI never claims a complete trajectory it cannot prove. The entry is not
      // returned as committed.
      changed = null;
      _markCommitFailed(runAttemptId);
    } catch (error) {
      changed = null;
      _markCommitFailed(runAttemptId);
    }
    return changed;
  }

  Future<Map<String, RunJournalEntry>> _read() async {
    try {
      final content = await _store.read();
      if (content == null || content.isEmpty) {
        _readFailed = false;
        return <String, RunJournalEntry>{};
      }
      final decoded = jsonDecode(content);
      if (decoded is! Map || decoded['runs'] is! List) {
        _readFailed = true;
        return <String, RunJournalEntry>{};
      }
      final storedRevision = decoded['revision'];
      if (storedRevision is int && storedRevision > _revision) {
        _revision = storedRevision;
      }
      final entries = <String, RunJournalEntry>{};
      for (final raw in decoded['runs']! as List) {
        if (raw is! Map) {
          _readFailed = true;
          return <String, RunJournalEntry>{};
        }
        final entry = RunJournalEntry.fromJson(Map<String, dynamic>.from(raw));
        if (entries.containsKey(entry.runAttemptId)) {
          _readFailed = true;
          return <String, RunJournalEntry>{};
        }
        entries[entry.runAttemptId] = entry;
      }
      _readFailed = false;
      return entries;
    } catch (_) {
      // Unreadable, corrupt, or tampered: show nothing and keep accepting new
      // records. The journal is display-only, so failing closed here never
      // blocks a run or its recovery banner.
      _readFailed = true;
      return <String, RunJournalEntry>{};
    }
  }

  Future<void> _write(Map<String, RunJournalEntry> entries) async {
    var ordered = entries.values.toList()
      ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    final revision = ++_revision;
    String encode(List<RunJournalEntry> runs) => jsonEncode({
          'schemaVersion': 1,
          'revision': revision,
          'runs': [for (final entry in runs) entry.toJson()],
        });
    var payload = encode(ordered);
    // Byte budget policy: drop the oldest *terminal* entries until the UTF-8
    // payload fits. A running entry is never dropped; when nothing safe is left
    // the write fails closed instead of silently truncating a live trajectory.
    const contentBudget =
        maxRunJournalPayloadBytes - SecureRunJournalStore.envelopeReserveBytes;
    while (utf8.encode(payload).length > contentBudget) {
      final terminal = ordered.where((entry) => !entry.isActive).toList();
      if (terminal.isEmpty) break;
      final oldest = terminal.first;
      entries.remove(oldest.runAttemptId);
      // The record is gone, so its sticky gap flag no longer describes
      // anything stored.
      _incompleteRunIds.remove(oldest.runAttemptId);
      ordered = ordered
          .where((entry) => entry.runAttemptId != oldest.runAttemptId)
          .toList();
      payload = encode(ordered);
    }
    if (utf8.encode(payload).length > contentBudget) {
      throw const FormatException('run_journal_payload_too_large');
    }
    if (_incompleteRunIds.isEmpty) _writeFailed = false;
    await _store.write(payload);
  }

  /// Keeps the newest [maxRunJournalEntries] by start time.
  void _prune(Map<String, RunJournalEntry> entries) {
    if (entries.length <= maxRunJournalEntries) return;
    final ordered = entries.values.toList()
      ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    for (final stale in ordered.take(entries.length - maxRunJournalEntries)) {
      entries.remove(stale.runAttemptId);
    }
  }

  static bool _isSafeId(String value) =>
      value.isNotEmpty &&
      value.length <= 120 &&
      !value.contains(RegExp(r'[^A-Za-z0-9._:-]'));

  static String? _sanitizeReason(String? reason) {
    if (reason == null) return null;
    final normalized = reason.trim().toLowerCase();
    if (normalized.isEmpty ||
        normalized.length > maxRunJournalReasonLength ||
        normalized.contains(RegExp(r'[^a-z0-9_]'))) {
      return null;
    }
    return normalized;
  }
}
