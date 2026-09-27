import 'dart:io';

import 'native_bridge.dart';

/// Status of the guest DNS resolver file (`/etc/resolv.conf`).
enum MachineDnsStatus {
  /// A readable `resolv.conf` with at least one usable `nameserver`.
  ready,

  /// No readable `resolv.conf`, or one without a usable `nameserver`.
  missing,

  /// The local check itself could not run.
  unknown,
}

/// Disk usage for the Alpine machine.
///
/// The agent workspace lives inside the rootfs (`<rootfs>/root/workspace`), so
/// [usedBytes] is the rootfs total, which already includes the workspace. The
/// workspace is reported separately only for the detail line.
final class MachineDiskUsage {
  const MachineDiskUsage({
    this.rootfsBytes,
    this.workspaceBytes,
    this.freeBytes,
    this.truncated = false,
  });

  const MachineDiskUsage.unknown()
      : rootfsBytes = null,
        workspaceBytes = null,
        freeBytes = null,
        truncated = false;

  final int? rootfsBytes;
  final int? workspaceBytes;
  final int? freeBytes;

  /// True when the walk hit [MachineHealthProbe.maxWalkEntries] and the number
  /// is incomplete. An incomplete number is reported as unknown, not guessed.
  final bool truncated;

  bool get known => rootfsBytes != null && !truncated;

  int? get usedBytes => known ? rootfsBytes : null;
}

/// Local, read-only probe behind the System Health machine tiles.
///
/// It runs no shell command, starts no proot process, and never binds shared
/// storage. Everything it reads lives in app-private storage.
final class MachineHealthProbe {
  MachineHealthProbe({
    Future<String> Function()? filesDir,
    Future<Map<String, dynamic>> Function()? bootstrapStatus,
  })  : _filesDir = filesDir ?? NativeBridge.getFilesDir,
        _bootstrapStatus = bootstrapStatus ?? NativeBridge.getBootstrapStatus;

  final Future<String> Function() _filesDir;
  final Future<Map<String, dynamic>> Function() _bootstrapStatus;

  /// Hard cap so a damaged or huge rootfs cannot jank the shell thread.
  static const int maxWalkEntries = 20000;

  /// Free-space warning threshold: below this the machine cannot install a
  /// package comfortably, so the tile asks the user to act.
  static const int lowFreeSpaceBytes = 64 * 1024 * 1024;

  Future<MachineDiskUsage> diskUsage() async {
    String rootfsPath;
    int? freeBytes;
    try {
      final status = await _bootstrapStatus();
      final rawRootfs = status['rootfsPath'];
      rootfsPath = rawRootfs is String && rawRootfs.isNotEmpty
          ? rawRootfs
          : '${await _filesDir()}/rootfs/alpine';
      final rawFree = status['availableBytes'];
      freeBytes = rawFree is int && rawFree >= 0 ? rawFree : null;
    } catch (_) {
      try {
        rootfsPath = '${await _filesDir()}/rootfs/alpine';
      } catch (_) {
        return const MachineDiskUsage.unknown();
      }
    }

    try {
      final rootfs = _measureDirectory(rootfsPath);
      if (rootfs.truncated) {
        return MachineDiskUsage(
          rootfsBytes: null,
          workspaceBytes: null,
          freeBytes: freeBytes,
          truncated: true,
        );
      }
      final workspace = _measureDirectory('$rootfsPath/root/workspace');
      return MachineDiskUsage(
        rootfsBytes: rootfs.bytes,
        workspaceBytes: workspace.bytes,
        freeBytes: freeBytes,
      );
    } catch (_) {
      return MachineDiskUsage(truncated: false, freeBytes: freeBytes);
    }
  }

  Future<MachineDnsStatus> dnsStatus() async {
    try {
      final base = await _filesDir();
      final candidates = <String>[
        '$base/config/resolv.conf',
        '$base/rootfs/alpine/etc/resolv.conf',
      ];
      for (final path in candidates) {
        final file = File(path);
        if (!file.existsSync()) continue;
        if (_hasUsableNameserver(file.readAsStringSync())) {
          return MachineDnsStatus.ready;
        }
      }
      return MachineDnsStatus.missing;
    } catch (_) {
      return MachineDnsStatus.unknown;
    }
  }

  static ({int bytes, bool truncated}) _measureDirectory(String path) {
    final directory = Directory(path);
    if (!directory.existsSync()) return (bytes: 0, truncated: false);
    var bytes = 0;
    var count = 0;
    try {
      for (final entity in directory.listSync(
        recursive: true,
        followLinks: false,
      )) {
        count += 1;
        if (count > maxWalkEntries) return (bytes: bytes, truncated: true);
        if (entity is! File) continue;
        try {
          bytes += entity.lengthSync();
        } catch (_) {
          // A file that vanished mid-walk contributes 0, never a crash.
        }
      }
    } catch (_) {
      return (bytes: bytes, truncated: true);
    }
    return (bytes: bytes, truncated: false);
  }

  /// Accepts only a real nameserver line; comments and placeholders do not
  /// count as working DNS.
  static bool _hasUsableNameserver(String text) {
    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('nameserver')) continue;
      final parts = trimmed.split(RegExp(r'\s+'));
      if (parts.length < 2) continue;
      final address = parts[1];
      if (address == '0.0.0.0' || address == '::') continue;
      if (!RegExp(r'^[0-9a-fA-F:.]+$').hasMatch(address)) continue;
      return true;
    }
    return false;
  }
}

/// Human-readable byte count for the health tiles. Keeps the value honest by
/// rounding down and never showing a fake precise number.
String formatHealthBytes(int bytes) {
  if (bytes < 0) return '未知';
  const kb = 1024;
  const mb = kb * 1024;
  const gb = mb * 1024;
  if (bytes >= gb) {
    final whole = bytes ~/ gb;
    final tenth = (bytes % gb) * 10 ~/ gb;
    return '$whole.$tenth GB';
  }
  if (bytes >= mb) {
    final whole = bytes ~/ mb;
    final tenth = (bytes % mb) * 10 ~/ mb;
    return '$whole.$tenth MB';
  }
  if (bytes >= kb) return '${bytes ~/ kb} KB';
  return '$bytes B';
}
