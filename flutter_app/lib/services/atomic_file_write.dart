import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

/// Renames a completed temporary file onto its final path.
///
/// Injectable so tests can drive the rename-failure branch without depending on
/// filesystem permissions.
typedef AtomicRename = Future<void> Function(String from, String to);

/// Writes a partial file body, for tests that must fail mid-write.
typedef AtomicPartWriter = Future<void> Function(File part, List<int> bytes);

Future<void> _defaultRename(String from, String to) async {
  await File(from).rename(to);
}

/// §5 AND-3 / AND-6: a file appears at its final path only when it is complete.
///
/// The bytes go to a random sibling `<target>.<random>.part` on the same
/// filesystem, are flushed (fsync) and closed, and only then is the file renamed
/// onto [targetPath]. A failure, a cancellation, or a full-disk race at any
/// step removes the partial file and leaves [targetPath] untouched, so a reader
/// never sees a half-written export or backup.
Future<void> writeFileAtomically(
  String targetPath,
  List<int> bytes, {
  AtomicRename? rename,
  AtomicPartWriter? writePart,
  String? suffix,
}) async {
  if (targetPath.trim().isEmpty || !targetPath.startsWith('/')) {
    throw ArgumentError.value(
        targetPath, 'targetPath', 'absolute path required');
  }
  final target = File(targetPath);
  final directory = target.parent;
  final partPath = '$targetPath.${suffix ?? _randomSuffix()}.part';
  final part = File(partPath);
  var published = false;
  try {
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    final writer = writePart ?? _defaultWritePart;
    await writer(part, bytes);
    await (rename ?? _defaultRename)(partPath, targetPath);
    published = true;
  } finally {
    if (!published) {
      // Leave no partial file behind: a retry starts from a clean directory.
      try {
        if (await part.exists()) {
          await part.delete();
        }
      } catch (_) {
        // Cleanup is best effort; the caller still sees the original failure.
      }
    }
  }
}

Future<void> _defaultWritePart(File part, List<int> bytes) async {
  final handle = await part.open(mode: FileMode.writeOnly);
  try {
    await handle.writeFrom(bytes);
    // fsync so the rename cannot publish bytes that are still in the cache.
    await handle.flush();
  } finally {
    await handle.close();
  }
}

String _randomSuffix() {
  final random = _random;
  final buffer = StringBuffer();
  for (var i = 0; i < 4; i++) {
    buffer.write(random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0'));
  }
  return buffer.toString();
}

final _random = Random();

/// Test seam: the suffix generator stays private, but tests may pin it.
@visibleForTesting
String debugAtomicSuffix() => _randomSuffix();
