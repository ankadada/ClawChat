import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Executes the descriptor-relative browser I/O the device runs through JNI.
///
/// The JVM tests cover the Kotlin policy and the Dart tests cover the service,
/// but neither can run the walk itself; this compiles the same translation unit
/// into a host harness (see rootfs_browser_io_host_test.cpp) and runs it,
/// including the thread that keeps swapping a browsed parent for a symlink.
void main() {
  final root = _flutterRoot();

  test('compiles and runs the browser list/delete/write race harness', () {
    final compiler = _findCompiler();
    if (compiler == null) {
      return;
    }
    final workdir = Directory.systemTemp.createTempSync('rootfs-browser-host-');
    try {
      final binary = File('${workdir.path}/rootfs_browser_host_test');
      final compile = Process.runSync(
        compiler,
        [
          '-std=c++17',
          '-O1',
          '-Wall',
          '-Wextra',
          '-Werror',
          '-DROOTFS_BROWSER_HOST_TEST',
          'rootfs_browser_io_host_test.cpp',
          '-o',
          binary.path,
        ],
        workingDirectory: '${root.path}/android/app/src/main/cpp',
      );
      expect(
        compile.exitCode,
        0,
        reason: 'compile failed: ${compile.stdout}${compile.stderr}',
      );

      final run = Process.runSync(binary.path, const []);
      expect(
        run.exitCode,
        0,
        reason: 'harness failed: ${run.stdout}${run.stderr}',
      );
      expect('${run.stdout}', contains('OK'));
    } finally {
      workdir.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('the broker is built and wired for list, delete, write and reads', () {
    final cpp = Directory('${root.path}/android/app/src/main/cpp');
    final native = File('${cpp.path}/rootfs_browser_io.cpp').readAsStringSync();
    final cmake = File('${cpp.path}/CMakeLists.txt').readAsStringSync();
    final bridge = File(
      '${root.path}/android/app/src/main/kotlin/com/anka/clawbot/SecureImportNative.kt',
    ).readAsStringSync();
    final bootstrap = File(
      '${root.path}/android/app/src/main/kotlin/com/anka/clawbot/BootstrapManager.kt',
    ).readAsStringSync();
    final service = File(
      '${root.path}/lib/services/workspace_file_service.dart',
    ).readAsStringSync();

    expect(cmake, contains('rootfs_browser_io.cpp'));
    expect(native, contains('O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC'));
    expect(native, contains('AT_SYMLINK_NOFOLLOW'));
    expect(native, contains('unlinkat('));
    expect(
      native,
      contains('O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC'),
    );
    expect(native, contains('same_directory('));
    expect(native, contains('fdopendir('));
    expect(bridge, contains('external fun listRootfsDirectoryBounded('));
    expect(bridge, contains('external fun deleteRootfsFileBounded('));
    expect(bridge, contains('external fun writeRootfsFileBounded('));
    expect(bootstrap, contains('SecureImportNative.deleteRootfsFileBounded('));
    expect(bootstrap, contains('SecureImportNative.writeRootfsFileBounded('));
    // Reads go through the bounded descriptor-relative byte broker as well.
    expect(service, contains('NativeBridge.readRootfsFileBytes'));
    expect(service, contains('saveTextWithRetry'));
  });
}

String? _findCompiler() {
  for (final candidate in const ['clang++', 'g++', 'c++']) {
    try {
      final probe = Process.runSync(candidate, const ['--version']);
      if (probe.exitCode == 0) return candidate;
    } on ProcessException {
      continue;
    }
  }
  return null;
}

Directory _flutterRoot() {
  final current = Directory.current;
  if (File('${current.path}/pubspec.yaml').existsSync()) return current;
  final candidate = Directory('${current.path}/flutter_app');
  if (File('${candidate.path}/pubspec.yaml').existsSync()) return candidate;
  throw StateError('flutter_app root not found from ${current.path}');
}
