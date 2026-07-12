import 'dart:io';
import 'dart:typed_data';

typedef BoundedFileStreamFactory = Stream<List<int>> Function(String path);
typedef BoundedFileIdentityProbe = Future<Object?> Function(String path);

final class _PathSnapshot {
  const _PathSnapshot({
    required this.path,
    required this.canonicalPath,
    required this.stat,
    required this.identity,
  });

  final String path;
  final String canonicalPath;
  final FileStat stat;
  final Object? identity;
}

/// Reads host files without trusting a metadata-only size check.
///
/// The validator is called for the initial metadata size and for every
/// cumulative chunk count before that chunk is retained or written. A stable
/// regular-file snapshot is required across the operation, and the observed
/// stream length must match the initial snapshot.
abstract final class BoundedFileReader {
  static Future<Uint8List> readBytes(
    String path, {
    required void Function(int byteLength) validateBytes,
    BoundedFileStreamFactory? streamFactory,
    BoundedFileIdentityProbe? identityProbe,
  }) async {
    final source = await _canonicalRegularFile(path);
    final ancestors = await _snapshotAncestors(source);
    final before = await _validatedSnapshot(
      source,
      validateBytes,
      identityProbe: identityProbe,
    );
    final chunks = BytesBuilder(copy: false);
    var actualBytes = 0;
    final stream =
        streamFactory?.call(source.path) ?? _openStableStream(source);
    await for (final chunk in stream) {
      final nextBytes = actualBytes + chunk.length;
      validateBytes(nextBytes);
      actualBytes = nextBytes;
      chunks.add(chunk);
    }
    await _verifyStable(
      source,
      before,
      actualBytes,
      ancestors,
      identityProbe: identityProbe,
    );
    return chunks.takeBytes();
  }

  /// Copies to a caller-provided operation-scoped path and removes any
  /// partial destination on limit, mutation, or read/write failure.
  static Future<int> copyToFile(
    String sourcePath,
    String destinationPath, {
    required void Function(int byteLength) validateBytes,
    BoundedFileStreamFactory? streamFactory,
    BoundedFileIdentityProbe? identityProbe,
  }) async {
    final source = await _canonicalRegularFile(sourcePath);
    final ancestors = await _snapshotAncestors(source);
    final before = await _validatedSnapshot(
      source,
      validateBytes,
      identityProbe: identityProbe,
    );
    final destination = File(destinationPath);
    IOSink? sink;
    var completed = false;
    var actualBytes = 0;
    try {
      sink = destination.openWrite(mode: FileMode.writeOnly);
      final stream =
          streamFactory?.call(source.path) ?? _openStableStream(source);
      await for (final chunk in stream) {
        final nextBytes = actualBytes + chunk.length;
        validateBytes(nextBytes);
        actualBytes = nextBytes;
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      await _verifyStable(
        source,
        before,
        actualBytes,
        ancestors,
        identityProbe: identityProbe,
      );
      completed = true;
      return actualBytes;
    } finally {
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {}
      }
      if (!completed) {
        try {
          if (await destination.exists()) await destination.delete();
        } catch (_) {}
      }
    }
  }

  static Future<_PathSnapshot> _validatedSnapshot(
    File source,
    void Function(int byteLength) validateBytes, {
    BoundedFileIdentityProbe? identityProbe,
  }) async {
    final pathType = await FileSystemEntity.type(
      source.path,
      followLinks: false,
    );
    if (pathType != FileSystemEntityType.file) {
      throw FileSystemException('Source is not a regular file', source.path);
    }
    final snapshot = await source.stat();
    if (snapshot.type != FileSystemEntityType.file) {
      throw FileSystemException('Source is not a regular file', source.path);
    }
    validateBytes(snapshot.size);
    final canonicalPath = await source.resolveSymbolicLinks();
    if (canonicalPath != source.absolute.path) {
      throw FileSystemException('Source path contains a symlink', source.path);
    }
    return _PathSnapshot(
      path: source.absolute.path,
      canonicalPath: canonicalPath,
      stat: snapshot,
      identity: await identityProbe?.call(source.path),
    );
  }

  static Future<File> _canonicalRegularFile(String path) async {
    final requestedType = await FileSystemEntity.type(path, followLinks: false);
    if (requestedType != FileSystemEntityType.file) {
      throw FileSystemException('Source is not a regular file', path);
    }
    final canonicalPath = await File(path).resolveSymbolicLinks();
    return File(canonicalPath);
  }

  static Future<void> _verifyStable(
    File source,
    _PathSnapshot before,
    int actualBytes,
    List<_PathSnapshot> ancestors, {
    BoundedFileIdentityProbe? identityProbe,
  }) async {
    final pathType = await FileSystemEntity.type(
      source.path,
      followLinks: false,
    );
    final after = await source.stat();
    String? canonicalPath;
    try {
      canonicalPath = await source.resolveSymbolicLinks();
    } catch (_) {}
    final identity = await identityProbe?.call(source.path);
    final stable = pathType == FileSystemEntityType.file &&
        after.type == FileSystemEntityType.file &&
        source.absolute.path == before.path &&
        canonicalPath == before.canonicalPath &&
        actualBytes == before.stat.size &&
        after.size == before.stat.size &&
        after.modified == before.stat.modified &&
        after.changed == before.stat.changed &&
        identity == before.identity &&
        await _ancestorsStable(ancestors);
    if (!stable) {
      throw FileSystemException(
        'Source changed while it was being read',
        source.path,
      );
    }
  }

  static Stream<List<int>> _openStableStream(File source) async* {
    final handle = await source.open(mode: FileMode.read);
    try {
      const chunkBytes = 64 * 1024;
      while (true) {
        final chunk = await handle.read(chunkBytes);
        if (chunk.isEmpty) break;
        yield chunk;
      }
    } finally {
      await handle.close();
    }
  }

  static Future<List<_PathSnapshot>> _snapshotAncestors(File source) async {
    final snapshots = <_PathSnapshot>[];
    var current = source.absolute.parent;
    while (true) {
      final type =
          await FileSystemEntity.type(current.path, followLinks: false);
      if (type != FileSystemEntityType.directory) {
        throw FileSystemException(
          'Source parent is not a regular directory',
          current.path,
        );
      }
      final canonicalPath = await current.resolveSymbolicLinks();
      if (canonicalPath != current.absolute.path) {
        throw FileSystemException(
          'Source path contains a symlink',
          current.path,
        );
      }
      snapshots.add(_PathSnapshot(
        path: current.absolute.path,
        canonicalPath: canonicalPath,
        stat: await current.stat(),
        identity: null,
      ));
      final parent = current.parent;
      if (parent.path == current.path) break;
      current = parent;
    }
    return snapshots;
  }

  static Future<bool> _ancestorsStable(
    List<_PathSnapshot> snapshots,
  ) async {
    for (final before in snapshots) {
      final type = await FileSystemEntity.type(before.path, followLinks: false);
      if (type != FileSystemEntityType.directory) return false;
      final directory = Directory(before.path);
      final after = await directory.stat();
      String canonicalPath;
      try {
        canonicalPath = await directory.resolveSymbolicLinks();
      } catch (_) {
        return false;
      }
      if (canonicalPath != before.canonicalPath ||
          after.type != before.stat.type) {
        return false;
      }
    }
    return true;
  }
}
