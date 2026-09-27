import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins the descriptor-relative rootfs byte read:
///   * the JNI walk opens every component relative to its verified parent,
///   * the final file is opened with `O_NOFOLLOW | O_NONBLOCK`,
///   * type and link count come from `fstat` on the opened descriptor,
///   * the identity is re-checked after the bounded read,
///   * `BootstrapManager` no longer re-resolves the path after checking it.
///
/// The native walk itself runs on a device; these are source-level guards so a
/// future edit cannot quietly go back to a path-stat-then-open read.
void main() {
  final root = _flutterRoot();

  String read(String relativePath) =>
      File('${root.path}/$relativePath').readAsStringSync();

  final native = read('android/app/src/main/cpp/secure_import.cpp');
  final bridge = read('android/app/src/main/kotlin/com/anka/clawbot/SecureImportNative.kt');
  final bootstrap =
      read('android/app/src/main/kotlin/com/anka/clawbot/BootstrapManager.kt');
  final reader =
      read('android/app/src/main/kotlin/com/anka/clawbot/RootfsBytesReader.kt');

  test('native broker exposes a dedicated rootfs bounded read', () {
    expect(
      native,
      contains('Java_com_anka_clawbot_SecureImportNative_readRootfsBytesBounded'),
    );
    expect(bridge, contains('external fun readRootfsBytesBounded('));
    expect(bridge, contains('rootPath: String'));
    expect(bridge, contains('relativePath: String'));
    expect(bridge, contains('operationId: String'));
  });

  test('native walk never follows a component symlink', () {
    expect(native, contains('O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC'));
    expect(native, contains('is_safe_rootfs_component'));
    expect(native, contains('if (!validate(component))'));
  });

  test('final open cannot block on a swapped-in special node', () {
    expect(native, contains('O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC'));
    expect(native, contains('regular_single_link(path_before)'));
    expect(native, contains('same_full_snapshot(result.path_before, result.descriptor_before)'));
  });

  test('bounded read verifies identity again before returning bytes', () {
    expect(
      native,
      contains('same_full_snapshot(source.descriptor_before, descriptor_after)'),
    );
    expect(native, contains('same_full_snapshot(descriptor_after, path_after)'));
    expect(native, contains('same_directory_identity(source.parent_before, parent_after)'));
    expect(native, contains('verify_held_directory(root.get(), root_path, root_initial)'));
    expect(native, contains('max_bytes_value > 2LL * 1024LL * 1024LL'));
    expect(native, contains('bounded read actual size exceeded'));
  });

  test('BootstrapManager delegates the byte read to the broker', () {
    expect(bootstrap, contains('readScopedRootfsBytes('));
    expect(bootstrap, contains('rootfsBytesReader'));
    expect(bootstrap, isNot(contains('RootfsBoundedTextReader.readBytesNoFollow')));
    expect(bootstrap, isNot(contains('Files.readAllBytes')));
  });

  test('scope resolution rejects traversal and narrows to the deepest root', () {
    expect(reader, contains('Path traversal detected'));
    expect(reader, contains('Path is outside the granted filesystem scope'));
    expect(reader, contains('.maxByOrNull { it.length }'));
    expect(reader, contains('MAX_ROOTFS_BYTES_READ'));
  });
}

Directory _flutterRoot() {
  final current = Directory.current;
  if (File('${current.path}/pubspec.yaml').existsSync()) return current;
  final candidate = Directory('${current.path}/flutter_app');
  if (File('${candidate.path}/pubspec.yaml').existsSync()) return candidate;
  throw StateError('flutter_app root not found from ${current.path}');
}
