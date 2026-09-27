import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'native_bridge.dart';
import 'tools/untrusted_data_policy.dart';

/// Storage for the memory trust flags.
///
/// A plain file is **not** enough: the host `/proc` is bind-mounted into proot
/// (`ProcessManager.kt`), so a guest path such as
/// `/proc/self/root/data/.../files/clawchat_state/memory_untrusted.json` can
/// name an app-private file and rewrite it. The flags therefore live in
/// encrypted app storage (EncryptedSharedPreferences) instead of a file.
abstract interface class MemoryTrustStore {
  /// The persisted content, or null when nothing has been stored yet.
  Future<String?> read();

  /// Persist [content] to the encrypted store.
  Future<void> write(String content);

  /// Remove the pre-2.9.0 plain files after a one-time import (best effort).
  Future<void> deleteLegacy();
}

/// Minimal seam over `FlutterSecureStorage`, mirroring
/// `FlutterSecureBackgroundTaskStorage`.
abstract interface class MemoryTrustProtectedStorage {
  Future<String?> read(String key);

  Future<void> write(String key, String value);
}

/// The production [MemoryTrustProtectedStorage].
final class FlutterSecureMemoryTrustStorage
    implements MemoryTrustProtectedStorage {
  FlutterSecureMemoryTrustStorage({FlutterSecureStorage? storage})
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

/// Encrypted, non-file storage for the memory trust flags.
class SecureMemoryTrustStore implements MemoryTrustStore {
  SecureMemoryTrustStore({MemoryTrustProtectedStorage? storage})
      : _storage = storage ?? FlutterSecureMemoryTrustStorage();

  /// The single authoritative trust-flag entry.
  static const storageKey = 'clawchat.memory_untrusted.v1';

  /// Recorded value for a fact the user typed or explicitly confirmed.
  static const userTrustValue = 'user';

  /// Pre-2.9.0 trust file inside the proot rootfs (guest-writable).
  static const legacyRootfsPath = 'root/.clawchat_memory_untrusted.json';

  /// Interim 2.9.0 plain file under `$filesDir/clawchat_state`.
  static const legacyPlainFileName = 'memory_untrusted.json';
  static const legacyPlainDirectoryName = 'clawchat_state';

  final MemoryTrustProtectedStorage _storage;

  @override
  Future<String?> read() async {
    final stored = await _storage.read(storageKey);
    if (stored != null && stored.isNotEmpty) return stored;
    // One-time import. Once the encrypted store holds a value, neither plain
    // file is read again, so a guest rewrite of either one is inert.
    final migrated = await _readMigratableFiles();
    if (migrated == null || migrated.isEmpty) return null;
    await _storage.write(storageKey, migrated);
    await deleteLegacy();
    return migrated;
  }

  @override
  Future<void> write(String content) => _storage.write(storageKey, content);

  @override
  Future<void> deleteLegacy() async {
    await _deletePlainFile();
    await _deleteRootfsFile();
  }

  /// Merge every pre-existing trust file into one map.
  ///
  /// Both sources are unioned rather than first-match-wins: a guest-created
  /// empty `{}` in one location must not hide real flags in the other. An
  /// existing file that cannot be parsed returns null, which the caller turns
  /// into a fail-closed state for the stored facts.
  ///
  /// **Legacy files are guest-writable**, so nothing they contain may be
  /// imported as user-confirmed. A `user` value (or any value that is not a
  /// known source) becomes the strictest source instead; a fact the user
  /// confirms after the migration still becomes trusted through the normal
  /// confirm path.
  Future<String?> _readMigratableFiles() async {
    final sources = <String>[];
    final plain = await _readPlainFile();
    if (plain != null && plain.isNotEmpty) sources.add(plain);
    final legacy = await _readRootfsFile();
    if (legacy != null && legacy.isNotEmpty) sources.add(legacy);
    if (sources.isEmpty) return null;

    final merged = <String, String>{};
    for (final source in sources) {
      final Object? decoded;
      try {
        decoded = jsonDecode(source);
      } catch (_) {
        return null;
      }
      if (decoded is! Map) return null;
      for (final entry in decoded.entries) {
        final key = entry.key.toString().toLowerCase();
        final raw = entry.value?.toString() ?? '';
        if (key.isEmpty || raw.isEmpty) continue;
        final imported = _importedTrustValue(raw);
        final existing = merged[key];
        if (existing == null ||
            _sourceStrictness(imported) > _sourceStrictness(existing)) {
          merged[key] = imported;
        }
      }
    }
    return jsonEncode(merged);
  }

  /// The trust value an imported legacy entry is allowed to carry.
  ///
  /// `user` and unknown values are not trusted: they become the strictest
  /// source, so a guest-written legacy file can never confirm a fact.
  static String _importedTrustValue(String raw) {
    if (raw == userTrustValue) return UntrustedSource.phone.name;
    for (final source in UntrustedSource.values) {
      if (source.name == raw) return source.name;
    }
    return UntrustedSource.phone.name;
  }

  static int _sourceStrictness(String value) => switch (value) {
        'phone' || 'mcp' => 2,
        'web' => 1,
        _ => 2,
      };

  Future<File> _plainFile() async {
    final filesDir = await NativeBridge.getFilesDir();
    return File(
        '$filesDir/$legacyPlainDirectoryName/$legacyPlainFileName');
  }

  Future<String?> _readPlainFile() async {
    try {
      final file = await _plainFile();
      if (!await file.exists()) return null;
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  Future<void> _deletePlainFile() async {
    try {
      final file = await _plainFile();
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best effort; the encrypted store is authoritative either way.
    }
  }

  Future<String?> _readRootfsFile() async {
    try {
      return await NativeBridge.readRootfsFile(legacyRootfsPath);
    } catch (_) {
      return null;
    }
  }

  Future<void> _deleteRootfsFile() async {
    try {
      await NativeBridge.deleteRootfsFile(legacyRootfsPath);
    } catch (_) {
      // Best effort; the encrypted store is authoritative either way.
    }
  }
}
