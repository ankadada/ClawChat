import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'preferences_service.dart';

/// Applies one mirror snapshot to the local preferences. Injectable so tests
/// can prove the marker ordering without a failing disk.
typedef SettingsSnapshotRestorer = Future<void> Function(
  Map<String, dynamic> settings,
  List<Map<String, dynamic>> providerProfiles,
);

/// Allowlisted, non-secret snapshot of user settings.
///
/// Android system backup cannot filter individual SharedPreferences keys, and
/// an upgraded install may still hold a legacy plaintext `api_key` /
/// `env_vars` in `FlutterSharedPreferences.xml` before the first launch
/// migrates them. That file therefore stays excluded from backup. This mirror
/// carries exactly the settings produced by
/// [PreferencesService.exportAllSettings] plus the non-secret provider profile
/// identity metadata from [PreferencesService.exportProfileMetadata] — the
/// profile IDs model groups reference, with no API key and no base URL.
///
/// On startup [restoreIfFresh] imports the mirror when the main preferences
/// were never initialized on this install (a restored device or a wiped app).
/// The marker that records initialization lives in `FlutterSharedPreferences`,
/// which is not backed up, so a restore is imported exactly once. The marker is
/// written only after every restore write completed; an interrupted restore is
/// retried on the next launch.
class SettingsBackupMirror {
  static const String fileName = 'clawchat_settings_backup.json';
  static const int schemaVersion = 2;
  static const int maxFileBytes = 512 * 1024;

  final PreferencesService _prefs;
  final Future<Directory> Function() _documentsDirectory;
  final SettingsSnapshotRestorer? _restorerOverride;

  SettingsBackupMirror({
    PreferencesService? prefs,
    Future<Directory> Function()? documentsDirectory,
    SettingsSnapshotRestorer? restorer,
  })  : _prefs = prefs ?? PreferencesService(),
        _documentsDirectory =
            documentsDirectory ?? getApplicationDocumentsDirectory,
        _restorerOverride = restorer;

  Future<File> _file() async {
    final directory = await _documentsDirectory();
    return File('${directory.path}/$fileName');
  }

  /// Writes the current non-secret settings snapshot atomically.
  Future<void> save() async {
    await _prefs.init();
    final payload = jsonEncode({
      'version': schemaVersion,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'settings': _prefs.exportAllSettings(),
      'providerProfiles': _prefs.exportProfileMetadata(),
    });
    if (utf8.encode(payload).length > maxFileBytes) return;
    final file = await _file();
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(payload, flush: true);
    await temp.rename(file.path);
  }

  /// Imports the mirror when this install has no settings marker yet.
  ///
  /// Returns true when a snapshot was applied. Throws when the restore write
  /// fails, and deliberately leaves the marker unset in that case so the next
  /// launch retries. An absent, oversized, unreadable, or unsupported snapshot
  /// is ignored and only marks the install initialized.
  Future<bool> restoreIfFresh() async {
    await _prefs.init();
    if (_prefs.settingsInitialized) return false;
    final snapshot = await _readSnapshot(await _file());
    if (snapshot != null) {
      final restorer = _restorerOverride;
      if (restorer != null) {
        await restorer(snapshot.settings, snapshot.providerProfiles);
      } else {
        await _prefs.restoreFromMirror(
          settings: snapshot.settings,
          providerProfiles: snapshot.providerProfiles,
        );
      }
    }
    // Only now is a fresh restore consumed: every write above was awaited, and
    // a failure threw before this line.
    await _prefs.markSettingsInitialized();
    return snapshot != null;
  }

  Future<_SettingsSnapshot?> _readSnapshot(File file) async {
    try {
      if (!await file.exists()) return null;
      if (await file.length() > maxFileBytes) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      if (decoded['version'] != schemaVersion) return null;
      final settings = decoded['settings'];
      if (settings is! Map) return null;
      final profiles = decoded['providerProfiles'];
      return _SettingsSnapshot(
        settings: Map<String, dynamic>.from(settings),
        providerProfiles: profiles is Iterable
            ? profiles
                .whereType<Map>()
                .map((profile) => Map<String, dynamic>.from(profile))
                .toList(growable: false)
            : const [],
      );
    } catch (_) {
      return null;
    }
  }
}

class _SettingsSnapshot {
  const _SettingsSnapshot({
    required this.settings,
    required this.providerProfiles,
  });

  final Map<String, dynamic> settings;
  final List<Map<String, dynamic>> providerProfiles;
}
