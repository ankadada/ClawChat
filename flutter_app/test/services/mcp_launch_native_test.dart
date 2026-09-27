import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards and executes the descriptor-relative MCP launch I/O.
///
/// The device reaches this code through JNI, which a JVM unit test cannot call,
/// so the race and cleanup behaviour is executed by compiling the same
/// translation unit into a host harness (see mcp_launch_io_host_test.cpp) and
/// the source-level invariants are pinned here.
void main() {
  final root = _flutterRoot();

  String read(String relativePath) =>
      File('${root.path}/$relativePath').readAsStringSync();

  final native = read('android/app/src/main/cpp/mcp_launch_io.cpp');
  final harness = read('android/app/src/main/cpp/mcp_launch_io_host_test.cpp');
  final cmake = read('android/app/src/main/cpp/CMakeLists.txt');
  final processManager =
      read('android/app/src/main/kotlin/com/anka/clawbot/ProcessManager.kt');
  final registry =
      read('android/app/src/main/kotlin/com/anka/clawbot/McpStdioRegistry.kt');
  final bridge = read(
      'android/app/src/main/kotlin/com/anka/clawbot/SecureImportNative.kt');

  group('descriptor-relative launch broker', () {
    test('the native broker is built into the app library', () {
      expect(cmake, contains('secure_import.cpp'));
      expect(cmake, contains('mcp_launch_io.cpp'));
      expect(bridge, contains('external fun createMcpLaunchScript('));
      expect(bridge, contains('external fun deleteMcpLaunchDirectory('));
      expect(bridge, contains('external fun sweepMcpLaunchDirectories('));
    });

    test('every level is opened relative to its verified parent', () {
      expect(native, contains('openat('));
      expect(native, contains('mkdirat('));
      expect(native, contains('unlinkat('));
      expect(native, contains('fstatat('));
      expect(native, contains('AT_SYMLINK_NOFOLLOW'));
      expect(
          native, contains('O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC'));
      expect(native,
          contains('O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC'));
      expect(native, contains('same_directory('));
      expect(native, contains('directory_identity('));
      expect(native, contains('fdopendir('));
      // No pathname walk and no recursive path-based delete.
      expect(native, isNot(contains('std::filesystem')));
      expect(native, isNot(contains('remove_all')));
      expect(native,
          contains('symlink or a file planted at this level is never used'));
    });

    test('the Kotlin launch path never resolves the tree by pathname again',
        () {
      expect(processManager,
          contains('SecureImportNative.createMcpLaunchScript('));
      expect(processManager,
          contains('SecureImportNative.deleteMcpLaunchDirectory('));
      expect(processManager,
          contains('SecureImportNative.sweepMcpLaunchDirectories('));
      expect(
          processManager, contains('McpStdioRegistry.liveLaunchIdentities()'));
      expect(processManager, isNot(contains('createLaunchDirectoryChain')));
      expect(processManager, isNot(contains('createDirectories(')));
      expect(processManager,
          isNot(contains('deleteTreeWithoutFollowingSymlinks')));
      expect(
          processManager, isNot(contains('restrictLaunchScriptPermissions')));
      expect(registry, contains('ProcessManager.deleteMcpLaunchScript(it)'));
      expect(registry, contains('fun liveLaunchIdentities()'));
      expect(registry, isNot(contains('deleteRecursively')));
      expect(
        RegExp(r'launch[^\n]{0,40}\.deleteRecursively\(')
            .hasMatch(processManager),
        isFalse,
      );
    });

    test('cleanup is identity-checked and unlink-only', () {
      expect(native, contains('expected_identity'));
      expect(native, contains('AT_REMOVEDIR'));
      expect(native, contains('remove_directory_contents('));
      expect(native, contains('is_live'));
      // The final rmdir re-checks the parent-fd name against the opened
      // descriptor, so a replacement directory is never deleted.
      expect(native, contains('remove_directory_name('));
      expect(native, contains('set_before_final_rmdir_hook'));
      expect(native, contains('A different directory now owns the name'));
      expect(native, contains('unlinkat(parent_fd, name.c_str(), 0)'));
    });
  });

  group('host harness', () {
    test('compiles and executes the race / reaper / sweep scenarios', () {
      final compiler = _findCompiler();
      if (compiler == null) {
        // Hosts without a C++ toolchain keep the source guards above.
        return;
      }
      final workdir = Directory.systemTemp.createTempSync('mcp-launch-host-');
      try {
        final binary = File('${workdir.path}/mcp_launch_host_test');
        final compile = Process.runSync(
          compiler,
          [
            '-std=c++17',
            '-O1',
            '-Wall',
            '-Wextra',
            '-Werror',
            '-DMCP_LAUNCH_HOST_TEST',
            'mcp_launch_io_host_test.cpp',
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

    test('the harness covers the scenarios the reviewer asked for', () {
      expect(harness, contains('test_race_parent_swap_never_writes_outside'));
      expect(harness, contains('test_create_refuses_symlinked_levels'));
      expect(harness, contains('test_sweep_unlinks_and_spares'));
      expect(harness, contains('test_create_and_delete_round_trip'));
      expect(harness, contains('the link target never received a script'));
      expect(harness, contains('nothing behind a link was deleted'));
      // Mid-delete / mid-sweep replacement races.
      expect(harness, contains('test_delete_refuses_a_replaced_directory'));
      expect(harness, contains('test_delete_unlinks_a_replaced_symlink'));
      expect(harness, contains('test_sweep_refuses_a_replaced_directory'));
      expect(harness, contains('test_race_delete_never_unlinks_outside'));
      expect(harness, contains('arm_replacement_hook'));
    });
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
