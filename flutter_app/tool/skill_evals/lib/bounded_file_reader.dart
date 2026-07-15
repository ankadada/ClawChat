import 'dart:io';

import 'package:crypto/crypto.dart';

/// Single physical-file, bounded read primitive for the host corpus.
///
/// It samples physical type and length before allocation, then validates the
/// returned byte count too. Links and wrong types are never followed/read.
final class HostBoundedFileReader {
  const HostBoundedFileReader._();

  static List<int> read(File file, int maximumBytes) {
    if (maximumBytes < 0 ||
        FileSystemEntity.typeSync(file.path, followLinks: false) !=
            FileSystemEntityType.file) {
      throw const BoundedFileReadException.notPhysicalFile();
    }
    try {
      if (file.lengthSync() > maximumBytes) {
        throw const BoundedFileReadException.tooLarge();
      }
      final bytes = file.readAsBytesSync();
      if (bytes.length > maximumBytes) {
        throw const BoundedFileReadException.tooLarge();
      }
      return bytes;
    } on BoundedFileReadException {
      rethrow;
    } on FileSystemException {
      throw const BoundedFileReadException.unreadable();
    }
  }

  static String sha256Hex(File file, int maximumBytes) =>
      sha256.convert(read(file, maximumBytes)).toString();
}

enum BoundedFileReadFailure { notPhysicalFile, tooLarge, unreadable }

final class BoundedFileReadException implements Exception {
  const BoundedFileReadException._(this.failure);
  const BoundedFileReadException.notPhysicalFile()
      : this._(BoundedFileReadFailure.notPhysicalFile);
  const BoundedFileReadException.tooLarge()
      : this._(BoundedFileReadFailure.tooLarge);
  const BoundedFileReadException.unreadable()
      : this._(BoundedFileReadFailure.unreadable);

  final BoundedFileReadFailure failure;
}
