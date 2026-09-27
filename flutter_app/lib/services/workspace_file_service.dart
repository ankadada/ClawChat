import 'dart:convert';
import 'dart:typed_data';

import '../models/workspace.dart';
import '../models/workspace_file.dart';
import 'native_bridge.dart';

/// A scoped file operation the browser refused or that failed.
class WorkspaceFileException implements Exception {
  final String code;
  final String message;

  const WorkspaceFileException(this.code, this.message);

  @override
  String toString() => 'WorkspaceFileException($code): $message';
}

typedef RootfsDirectoryLister = Future<Map<String, dynamic>> Function({
  required String path,
  required List<String> allowedRoots,
  required int maxEntries,
});
typedef RootfsBytesReader = Future<Uint8List?> Function(
  String path, {
  List<String>? allowedRoots,
  int maxBytes,
});
typedef RootfsEntryDeleter = Future<bool> Function(
  String path, {
  List<String>? allowedRoots,
});
typedef RootfsEntryWriter = Future<bool> Function(
  String path,
  String content, {
  List<String>? allowedRoots,

  /// Exclusive creation: the write must fail instead of replacing an existing
  /// name. The flag travels Dart -> MethodChannel -> JNI so the broker can
  /// enforce CREATE_NEW (and never truncate a hard-linked file).
  bool createNew,
});
typedef RootfsDirectoryCreator = Future<bool> Function(
  String path, {
  List<String>? allowedRoots,
});

/// Read-only-first file access inside one workspace.
///
/// Every call passes the workspace root as the only granted scope, and the
/// workspace containment check happens *before* the native call, so a path the
/// browser should never show is refused locally as well as natively. Deletes are
/// file-only in this MVP; a directory is refused with an explicit reason, and
/// text deletions can be undone because the caller already holds the content.
class WorkspaceFileService {
  static const int maxEntries = 200;
  static const int maxTextPreviewBytes = 64 * 1024;
  static const int maxImagePreviewBytes = 2 * 1024 * 1024;

  static const Set<String> imageExtensions = {
    'png',
    'jpg',
    'jpeg',
    'gif',
    'webp',
    'bmp',
    'heic',
  };

  final WorkspaceMetadata workspace;
  final RootfsDirectoryLister _list;
  final RootfsBytesReader _readBytes;
  final RootfsEntryDeleter _delete;
  final RootfsEntryWriter _write;
  final RootfsDirectoryCreator _createDirectory;

  WorkspaceFileService({
    required this.workspace,
    RootfsDirectoryLister? list,
    RootfsBytesReader? readBytes,
    RootfsEntryDeleter? delete,
    RootfsEntryWriter? write,
    RootfsDirectoryCreator? createDirectory,
  })  : _list = list ?? NativeBridge.listRootfsDirectory,
        // Every read goes through the bounded byte broker: it walks the tree
        // descriptor-relative with O_NOFOLLOW and an identity check, so a
        // swapped parent cannot redirect the preview either.
        _readBytes = readBytes ?? NativeBridge.readRootfsFileBytes,
        _delete = delete ?? NativeBridge.deleteRootfsFile,
        _write = write ?? NativeBridge.writeRootfsFile,
        // The destination of a saved share lives in a subdirectory of the
        // workspace (shared/); the broker creates it descriptor-relative so
        // the first save into a fresh workspace works.
        _createDirectory =
            createDirectory ?? NativeBridge.createRootfsDirectory;

  String get rootPath => workspace.rootPath;

  /// True when [guestPath] is inside this workspace.
  bool contains(String guestPath) => workspace.containsPath(guestPath);

  /// Path shown to the user: relative inside the workspace, otherwise the
  /// absolute guest path it refused.
  String displayPath(String guestPath) {
    final relative = workspace.relativePathOf(guestPath);
    if (relative == null) return guestPath;
    return relative.isEmpty ? workspace.name : relative;
  }

  String _requireInside(String guestPath) {
    final normalized = WorkspaceMetadata.normalizeGuestPath(guestPath);
    if (normalized == null || !workspace.containsPath(normalized)) {
      throw const WorkspaceFileException(
        'outside_scope',
        '该路径不在当前工作区内',
      );
    }
    return normalized;
  }

  /// Lists one directory inside the workspace.
  Future<WorkspaceFileListing> list(String directory) async {
    final target = _requireInside(directory);
    try {
      final result = await _list(
        path: target,
        allowedRoots: [rootPath],
        maxEntries: maxEntries,
      );
      return WorkspaceFileListing.fromNative(result);
    } on WorkspaceFileException {
      rethrow;
    } catch (error) {
      throw WorkspaceFileException('list_failed', '$error');
    }
  }

  /// Bounded preview: text files (UTF-8, NUL-free) or images by extension.
  Future<WorkspaceFilePreview> preview(WorkspaceFileEntry entry) async {
    final target = _requireInside(entry.path);
    final extension = entry.name.contains('.')
        ? entry.name.split('.').last.toLowerCase()
        : '';
    if (imageExtensions.contains(extension)) {
      if (entry.sizeBytes > maxImagePreviewBytes) {
        return const WorkspaceFilePreview.unsupported('图片过大，暂不预览');
      }
      try {
        final bytes = await _readBytes(
          target,
          allowedRoots: [rootPath],
          maxBytes: maxImagePreviewBytes,
        );
        if (bytes == null || bytes.isEmpty) {
          return const WorkspaceFilePreview.unsupported('无法读取该图片');
        }
        return WorkspaceFilePreview(
          kind: WorkspaceFilePreviewKind.image,
          bytes: bytes,
          mediaType: 'image/${extension == 'jpg' ? 'jpeg' : extension}',
        );
      } catch (error) {
        return WorkspaceFilePreview.unsupported('无法读取该图片：$error');
      }
    }

    if (entry.sizeBytes > maxTextPreviewBytes) {
      return const WorkspaceFilePreview.unsupported('文件较大，暂不预览');
    }
    try {
      final bytes = await _readBytes(
        target,
        allowedRoots: [rootPath],
        maxBytes: maxTextPreviewBytes,
      );
      if (bytes == null || bytes.isEmpty) {
        return const WorkspaceFilePreview.unsupported('无法读取该文件');
      }
      final text = decodeBoundedText(bytes);
      if (text == null) {
        return const WorkspaceFilePreview.unsupported('二进制文件，暂不预览');
      }
      return WorkspaceFilePreview(
        kind: WorkspaceFilePreviewKind.text,
        text: text,
      );
    } catch (error) {
      return WorkspaceFilePreview.unsupported('无法读取该文件：$error');
    }
  }

  /// Deletes one file inside the workspace. Directories are refused: the MVP
  /// has no recursive delete, so the browser cannot remove a tree by accident.
  Future<void> delete(WorkspaceFileEntry entry) async {
    final target = _requireInside(entry.path);
    if (entry.isDirectory) {
      throw const WorkspaceFileException(
        'directory_delete_unsupported',
        '这个版本只能删除文件，暂不支持删除文件夹',
      );
    }
    if (entry.isSymbolicLink) {
      throw const WorkspaceFileException(
        'symlink_delete_unsupported',
        '链接不会在这里删除',
      );
    }
    bool removed;
    try {
      removed = await _delete(target, allowedRoots: [rootPath]);
    } catch (error) {
      throw WorkspaceFileException('delete_failed', '$error');
    }
    if (!removed) {
      throw const WorkspaceFileException('delete_failed', '删除失败');
    }
  }

  /// Creates the parent directory of [guestPath] (every missing level) inside
  /// this workspace, through the descriptor-relative broker. An existing
  /// directory is a success; a linked or non-directory component fails closed.
  Future<void> ensureParentDirectory(String guestPath) async {
    final target = _requireInside(guestPath);
    final slash = target.lastIndexOf('/');
    if (slash <= 0) return;
    final parent = target.substring(0, slash);
    if (parent == rootPath || !workspace.containsPath(parent)) return;
    bool created;
    try {
      created = await _createDirectory(parent, allowedRoots: [rootPath]);
    } catch (error) {
      throw WorkspaceFileException('mkdir_failed', '$error');
    }
    if (!created) {
      throw const WorkspaceFileException('mkdir_failed', '无法创建工作区目录');
    }
  }

  /// Writes [body] to the first usable candidate path, never overwriting.
  ///
  /// Every attempt uses CREATE_NEW through the descriptor-relative broker, so a
  /// name that is already taken (another share in the same millisecond, or a
  /// file the user created) is refused and the next candidate is tried. Returns
  /// the path that was written, or null when none of them worked.
  Future<String?> saveTextWithRetry({
    required List<String> candidatePaths,
    required String body,
  }) async {
    final ensuredParents = <String>{};
    for (final candidate in candidatePaths) {
      final target = _requireInside(candidate);
      final slash = target.lastIndexOf('/');
      final parent = slash > 0 ? target.substring(0, slash) : '';
      if (parent.isNotEmpty && ensuredParents.add(parent)) {
        try {
          await ensureParentDirectory(target);
        } on WorkspaceFileException {
          // The destination directory cannot be created, so none of the
          // candidate names can land there: report failure instead of writing
          // into a directory that does not exist.
          return null;
        }
      }
      bool written;
      try {
        // Exclusive creation: a taken name is refused by the broker, which is
        // what makes the retry loop safe rather than silently overwriting.
        written = await _write(
          target,
          body,
          allowedRoots: [rootPath],
          createNew: true,
        );
      } catch (_) {
        written = false;
      }
      if (written) return target;
    }
    return null;
  }

  /// Restores text the caller still holds (undo for a text deletion). The name
  /// was just deleted, so exclusive creation is both safe and wanted.
  Future<void> restoreText(String guestPath, String text) async {
    final target = _requireInside(guestPath);
    bool written;
    try {
      written = await _write(
        target,
        text,
        allowedRoots: [rootPath],
        createNew: true,
      );
    } catch (error) {
      throw WorkspaceFileException('restore_failed', '$error');
    }
    if (!written) {
      throw const WorkspaceFileException('restore_failed', '撤销失败');
    }
  }

  /// What the composer receives when the user sends a file to the session.
  String sessionReference(WorkspaceFileEntry entry) {
    final normalized = _requireInside(entry.path);
    return '工作区文件：$normalized';
  }

  /// The UTF-8 text of a file the caller wants to keep for undo, or null when
  /// it is not decodable text.
  String? textForUndo(WorkspaceFilePreview preview) {
    if (preview.kind != WorkspaceFilePreviewKind.text) return null;
    return preview.text;
  }

  /// Decodes bounded bytes as UTF-8 text, refusing NUL-containing payloads.
  static String? decodeBoundedText(List<int> bytes) {
    if (bytes.contains(0)) return null;
    try {
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }
}
