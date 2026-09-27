import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins the file browser's security wiring at the source level, because the
/// native side runs on a device and the JVM tests only cover the lister itself.
void main() {
  final root = _flutterRoot();

  String read(String relativePath) =>
      File('${root.path}/$relativePath').readAsStringSync();

  final lister = read(
    'android/app/src/main/kotlin/com/anka/clawbot/RootfsDirectoryLister.kt',
  );
  final bootstrap = read(
    'android/app/src/main/kotlin/com/anka/clawbot/BootstrapManager.kt',
  );
  final activity = read(
    'android/app/src/main/kotlin/com/anka/clawbot/MainActivity.kt',
  );
  final bridge = read('lib/services/native_bridge.dart');
  final service = read('lib/services/workspace_file_service.dart');
  final screen = read('lib/screens/workspace_browser_screen.dart');
  final chat = read('lib/screens/chat_screen.dart');

  test('the lister keeps the scope policy and delegates the walk', () {
    expect(lister, contains('normalizeRootfsVirtualPath'));
    expect(lister, contains('isRootfsPathInsideScope'));
    expect(lister, contains('maxByOrNull { it.length }'));
    expect(lister, contains('MAX_ENTRIES'));
    // The filesystem walk is descriptor-relative in the native broker, not a
    // pathname check followed by a pathname use.
    expect(lister, contains('SecureImportNative.listRootfsDirectoryBounded'));
    expect(lister, isNot(contains('File(target)')));
    expect(lister, isNot(contains('listFiles()')));
    // The scope check itself still refuses to follow a link on every level it
    // walks before the broker is asked to open anything.
    expect(bootstrap, contains('LinkOption.NOFOLLOW_LINKS'));
    expect(bootstrap, contains('Symlink traversal is not allowed'));
  });

  test('exclusive creation travels Kotlin and the JNI broker', () {
    final native = read('android/app/src/main/cpp/rootfs_browser_io.cpp');
    // The broker receives the flag and never truncates before the link check.
    expect(native, contains('jboolean create_new'));
    expect(native, contains('if (create_new) {'));
    // An overwrite writes a fresh inode and replaces the directory entry: the
    // existing node is never opened, so no check-then-truncate window exists.
    expect(native, isNot(contains('ftruncate(')));
    expect(native, isNot(contains('| O_TRUNC')));
    expect(native, isNot(contains('O_TRUNC |')));
    expect(native, contains('renameat('));
    expect(native, contains('unlink_if_same('));
    // A special node is refused before anything is created, and the temp open
    // can never park on one.
    expect(native, contains('O_NONBLOCK'));
    expect(native, contains('!S_ISREG(existing.st_mode)'));
    expect(native, contains('existing.st_nlink != 1'));
    expect(native, contains('AT_SYMLINK_NOFOLLOW'));
    // MainActivity forwards the flag it received from Dart.
    expect(activity, contains('"createNew"'));
    expect(activity, contains('bootstrapManager.writeRootfsFile('));
    expect(bootstrap, contains('writeRootfsFileBounded('));
    expect(bootstrap, contains('createNew'));
    expect(
      read('lib/services/native_bridge.dart'),
      contains("'createNew': createNew"),
    );
    expect(service, contains('createNew: true'));
  });

  test('list, delete and write go through the descriptor-relative broker', () {
    final native = read(
      'android/app/src/main/cpp/rootfs_browser_io.cpp',
    );
    expect(native, contains('O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC'));
    expect(native, contains('AT_SYMLINK_NOFOLLOW'));
    expect(native, contains('unlinkat('));
    expect(
      native,
      contains('O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC'),
    );
    expect(native, contains('same_directory('));
    expect(native, contains('fdopendir('));
    expect(
      read('android/app/src/main/cpp/CMakeLists.txt'),
      contains('rootfs_browser_io.cpp'),
    );
    expect(bootstrap, contains('SecureImportNative.deleteRootfsFileBounded('));
    expect(bootstrap, contains('SecureImportNative.writeRootfsFileBounded('));
    expect(lister, contains('SecureImportNative.listRootfsDirectoryBounded('));
    // No pathname delete/write survives in the scoped API.
    expect(bootstrap, isNot(contains('Files.deleteIfExists(target)')));
  });

  test('file actions follow the workspace the session belongs to', () {
    // The browser and the share default must resolve the session's workspace
    // instead of waiting on the globally active one.
    expect(chat, contains('provider.workspaceForSession('));
    expect(
      chat,
      contains('WorkspaceBrowserScreen(workspace: workspace)'),
    );
    expect(
      chat,
      contains(
        'provider.workspaceForSession(provider.currentSession?.workspaceId).id',
      ),
    );
    // The empty state names that workspace before the first message.
    expect(chat, contains("'当前工作区'"));
    // Sending a file reference only fills the composer; the user still sends.
    expect(chat, contains('已把文件路径放进输入框；确认内容后再发送'));
  });

  test('a save creates its destination directory through the broker', () {
    // The documented save destination lives in <workspace>/shared, which a
    // fresh workspace does not have: the chain below creates it descriptor-
    // relative before the write, which is what made the device save fail.
    final native = read('android/app/src/main/cpp/rootfs_browser_io.cpp');
    expect(native, contains('createRootfsDirectoryBounded'));
    expect(native, contains('mkdirat('));
    expect(native, contains('create_directory_path('));
    expect(
      read('android/app/src/main/kotlin/com/anka/clawbot/BootstrapManager.kt'),
      contains('fun createRootfsDirectory('),
    );
    expect(
      read('android/app/src/main/kotlin/com/anka/clawbot/BootstrapManager.kt'),
      contains('SecureImportNative.createRootfsDirectoryBounded('),
    );
    expect(activity, contains('"createRootfsDirectory" ->'));
    expect(bridge, contains("'createRootfsDirectory'"));
    expect(service, contains('ensureParentDirectory'));
    expect(service, contains('NativeBridge.createRootfsDirectory'));
  });

  test('the platform call is scoped, bounded and wired end to end', () {
    expect(bootstrap, contains('fun listRootfsDirectory('));
    expect(bootstrap, contains('RootfsDirectoryLister.list('));
    expect(activity, contains('"listRootfsDirectory" ->'));
    expect(activity, contains('bootstrapManager.listRootfsDirectory('));
    expect(activity, contains('ROOTFS_LIST_ERROR'));
    expect(bridge, contains("'listRootfsDirectory'"));
  });

  test('the Dart service always passes the workspace root as the only scope',
      () {
    expect(service, contains('allowedRoots: [rootPath]'));
    expect(service, contains('maxEntries: maxEntries'));
    // Reads use the bounded descriptor-relative byte broker.
    expect(service, contains('NativeBridge.readRootfsFileBytes'));
    expect(service, contains('saveTextWithRetry'));
    expect(service, contains('static const int maxEntries = 200;'));
    expect(service, contains('directory_delete_unsupported'));
    expect(service, contains('outside_scope'));
    expect(service, contains('imageExtensions'));
    expect(service, contains('maxTextPreviewBytes'));
    expect(service, contains('maxImagePreviewBytes'));
    expect(
      RegExp(r'allowedRoots: \[\]').hasMatch(service),
      isFalse,
    );
  });

  test('the browser confirms deletion with scope wording and offers undo', () {
    expect(screen, contains('删除文件'));
    expect(screen, contains('工作区：'));
    expect(screen, contains('删除后无法恢复'));
    expect(screen, contains('删除后可以用撤销恢复内容'));
    expect(screen, contains("label: '撤销'"));
    expect(screen, contains('链接不会在这里打开'));
    expect(screen, contains('这个目录还是空的'));
    expect(screen, contains('无法读取这个目录'));
    expect(screen, contains('重试'));
    expect(screen, contains('插入输入框'));
    expect(screen, contains('复制路径'));
  });

  test('the chat screen reaches the browser without sending anything', () {
    expect(chat, contains("id: 'workspace_files'"));
    expect(chat, contains('WorkspaceBrowserScreen('));
    expect(chat, contains('provider.activeWorkspace'));
    expect(chat, contains('_inputController.text ='));
  });
}

Directory _flutterRoot() {
  final current = Directory.current;
  if (File('${current.path}/pubspec.yaml').existsSync()) return current;
  final candidate = Directory('${current.path}/flutter_app');
  if (File('${candidate.path}/pubspec.yaml').existsSync()) return candidate;
  throw StateError('flutter_app root not found from ${current.path}');
}
