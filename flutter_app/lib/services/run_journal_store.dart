import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/run_journal.dart';
import 'memory_trust_store.dart';

/// Storage seam for the run journal. The production implementation keeps the
/// whole payload in encrypted app-private storage.
abstract interface class RunJournalStore {
  /// The verified journal payload
  /// (`{schemaVersion, revision, runs, checksum}`), or null when nothing has
  /// been stored yet. Throws when the payload fails its checksum, schema, or
  /// revision rule, so the caller can fail closed.
  Future<String?> read();

  Future<void> write(String content);

  Future<void> clear();
}

/// Encrypted journal storage with a SHA-256 envelope and a monotonic revision.
///
/// Reuses the same `FlutterSecureStorage` bridge as the memory trust flags:
/// the journal records run and tool-attempt metadata, so it belongs in the
/// encrypted store rather than a file the guest shell could read.
final class SecureRunJournalStore implements RunJournalStore {
  SecureRunJournalStore({MemoryTrustProtectedStorage? storage})
      : _storage = storage ?? FlutterSecureMemoryTrustStorage();

  /// The single authoritative journal entry.
  static const storageKey = 'clawchat.run_journal.v1';

  /// Domain separator for the envelope checksum.
  static const checksumDomain = 'clawchat-run-journal-v1';

  /// Bytes reserved for the envelope (schema, revision, checksum, JSON
  /// punctuation) so the service can trim the runs payload to a size the store
  /// will actually accept.
  static const envelopeReserveBytes = 512;

  final MemoryTrustProtectedStorage _storage;

  /// Highest revision this store has committed (or read). Guards against a
  /// delayed older payload overwriting a newer one.
  int _lastCommittedRevision = 0;

  @override
  Future<String?> read() async {
    final stored = await _storage.read(storageKey);
    if (stored == null || stored.isEmpty) return null;
    final decoded = jsonDecode(stored);
    if (decoded is! Map ||
        decoded.length != 4 ||
        decoded['schemaVersion'] != 1 ||
        decoded['runs'] is! List ||
        decoded['checksum'] is! String ||
        decoded['revision'] is! int) {
      throw const FormatException('run_journal_store_schema');
    }
    final revision = decoded['revision']! as int;
    final runs = _canonicalRuns(decoded['runs']! as List);
    if (_checksum(revision, runs) != decoded['checksum']) {
      throw const FormatException('run_journal_store_checksum');
    }
    if (revision > _lastCommittedRevision) _lastCommittedRevision = revision;
    return jsonEncode({
      'schemaVersion': 1,
      'revision': revision,
      'runs': jsonDecode(runs),
      'checksum': decoded['checksum'],
    });
  }

  @override
  Future<void> write(String content) async {
    final decoded = jsonDecode(content);
    final revision = decoded is Map ? decoded['revision'] : null;
    if (decoded is! Map || decoded['runs'] is! List || revision is! int) {
      throw const FormatException('run_journal_store_schema');
    }
    // Atomic stale-write rejection: an older payload that lands after a newer
    // one (a delayed or retried write) is discarded instead of overwriting it.
    if (revision <= _lastCommittedRevision) {
      throw const FormatException('run_journal_stale_write');
    }
    final runs = _canonicalRuns(decoded['runs']! as List);
    final payload = jsonEncode({
      'schemaVersion': 1,
      'revision': revision,
      'runs': jsonDecode(runs),
      'checksum': _checksum(revision, runs),
    });
    // Second, hard boundary for the byte budget: the service trims by policy,
    // the store refuses anything that would exceed the limit anyway.
    if (utf8.encode(payload).length > maxRunJournalPayloadBytes) {
      throw const FormatException('run_journal_payload_too_large');
    }
    await _storage.write(storageKey, payload);
    if (revision > _lastCommittedRevision) _lastCommittedRevision = revision;
  }

  @override
  Future<void> clear() async {
    await _storage.write(storageKey, '');
    _lastCommittedRevision = 0;
  }

  static String _canonicalRuns(List<Object?> runs) =>
      jsonEncode([for (final run in runs) run]);

  static String _checksum(int revision, String canonicalRuns) => sha256
      .convert(utf8.encode('$checksumDomain\n$revision\n$canonicalRuns'))
      .toString();
}

/// In-memory store for tests and for the pre-storage failure path. It enforces
/// the same revision rule as the encrypted store.
final class InMemoryRunJournalStore implements RunJournalStore {
  String? _content;
  int _lastCommittedRevision = 0;

  /// The raw payload, for tests that assert what is (not) stored.
  String? get content => _content;

  // `Future.sync`/`Future.value` complete in the caller's zone. Widget tests run
  // under a fake-async zone; an `async` body whose completion is scheduled in a
  // different zone would never resume there.
  @override
  Future<String?> read() => Future<String?>.value(_content);

  @override
  Future<void> write(String content) => Future<void>.sync(() {
        final decoded = jsonDecode(content);
        final revision = decoded is Map ? decoded['revision'] : null;
        if (revision is int && revision <= _lastCommittedRevision) {
          throw const FormatException('run_journal_stale_write');
        }
        if (revision is int) _lastCommittedRevision = revision;
        _content = content;
      });

  @override
  Future<void> clear() => Future<void>.sync(() {
        _content = null;
        _lastCommittedRevision = 0;
      });
}
