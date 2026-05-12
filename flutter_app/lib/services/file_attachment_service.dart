import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';

import 'native_bridge.dart';

/// Service for picking files from device storage and importing them
/// into the proot workspace for use by the AI agent.
class FileAttachmentService {
  /// Pick files from device storage.
  /// Returns list of picked files, or empty list if cancelled.
  static Future<List<PlatformFile>> pickFiles({
    FileType type = FileType.any,
    bool allowMultiple = false,
  }) async {
    final result = await FilePicker.platform.pickFiles(
      type: type,
      allowMultiple: allowMultiple,
      withData: false,
      withReadStream: false,
    );
    return result?.files ?? [];
  }

  /// Pick images specifically.
  static Future<List<PlatformFile>> pickImages({
    bool allowMultiple = false,
  }) async {
    return pickFiles(type: FileType.image, allowMultiple: allowMultiple);
  }

  /// Copy a picked file into the proot workspace.
  /// Returns the path inside proot where the file was placed
  /// (e.g. /root/workspace/uploads/photo.jpg).
  static Future<String> importToWorkspace(PlatformFile file) async {
    final sourcePath = file.path;
    if (sourcePath == null) {
      throw Exception('File path is null - file may not have been saved to disk');
    }

    final safeName = file.name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final extension = safeName.split('.').last.toLowerCase();

    const textExtensions = {
      'txt', 'md', 'json', 'yaml', 'yml', 'xml', 'csv',
      'py', 'js', 'ts', 'dart', 'sh', 'html', 'css',
      'toml', 'cfg', 'ini', 'log', 'sql',
    };

    final destDir = 'root/workspace/uploads';
    final destPath = '$destDir/$safeName';

    if (textExtensions.contains(extension)) {
      // Text file: read as string and write directly via rootfs
      final content = await File(sourcePath).readAsString();
      await NativeBridge.writeRootfsFile(destPath, content);
    } else {
      // Binary file: base64 encode, write to temp file, decode inside proot
      final bytes = await File(sourcePath).readAsBytes();
      final base64Content = base64Encode(bytes);
      await NativeBridge.writeRootfsFile('$destDir/.tmp_b64', base64Content);
      await NativeBridge.runInProot(
        'base64 -d /root/workspace/uploads/.tmp_b64 > "/root/workspace/uploads/$safeName" '
        '&& rm /root/workspace/uploads/.tmp_b64',
      );
    }

    return '/root/workspace/uploads/$safeName';
  }

  /// Get a human-readable file size string.
  static String formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
