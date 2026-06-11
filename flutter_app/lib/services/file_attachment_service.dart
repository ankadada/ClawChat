import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';

import '../models/chat_models.dart';
import 'native_bridge.dart';

class PreparedAttachment {
  final MessageContent content;
  final String inputText;
  final bool includeAsContentBlock;

  const PreparedAttachment({
    required this.content,
    required this.inputText,
    required this.includeAsContentBlock,
  });
}

/// Service for picking files from device storage and importing them
/// into the proot workspace for use by the AI agent.
class FileAttachmentService {
  static const int _maxInlineImageBase64Bytes = 5 * 1024 * 1024;
  static const int _maxInlineTextBytes = 100 * 1024;

  static const Set<String> _imageExtensions = {
    'jpg', 'jpeg', 'png', 'gif', 'webp',
  };

  static const Set<String> _textExtensions = {
    'txt', 'md', 'json', 'yaml', 'yml', 'xml', 'csv',
    'py', 'js', 'jsx', 'ts', 'tsx', 'dart', 'sh', 'bash',
    'html', 'css', 'scss', 'toml', 'cfg', 'ini', 'log', 'sql',
    'go', 'rs', 'rb', 'php', 'java', 'kt', 'kts', 'swift',
    'c', 'cc', 'cpp', 'h', 'hpp', 'gradle', 'properties', 'env',
  };

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

  /// Prepare a picked file for inclusion in a user message.
  ///
  /// Images are sent as multimodal content blocks. Text files are inlined as
  /// fenced code with filename context. Other binaries are copied into the
  /// workspace and represented by their workspace path.
  static Future<PreparedAttachment> prepareForMessage(PlatformFile file) async {
    final sourcePath = file.path;
    if (sourcePath == null) {
      throw Exception('File path is null - file may not have been saved to disk');
    }

    final safeName = sanitizeFileName(file.name);
    final extension = _extensionFor(safeName);

    if (_imageExtensions.contains(extension)) {
      final bytes = await File(sourcePath).readAsBytes();
      final base64Content = base64Encode(bytes);
      if (base64Content.length > _maxInlineImageBase64Bytes) {
        throw Exception('Image is too large to inline after base64 encoding (5 MB limit)');
      }
      return PreparedAttachment(
        content: ImageContent(
          data: base64Content,
          mediaType: _mediaTypeForImage(extension),
          filename: safeName,
        ),
        inputText: '[Image attached: $safeName]',
        includeAsContentBlock: true,
      );
    }

    if (_textExtensions.contains(extension)) {
      final bytes = await File(sourcePath).readAsBytes();
      if (bytes.length > _maxInlineTextBytes) {
        throw Exception('Text file is too large to inline (100 KB limit)');
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      final fence = text.contains('```') ? '````' : '```';
      return PreparedAttachment(
        content: TextContent('File: $safeName\n$fence\n$text\n$fence'),
        inputText: 'File: $safeName\n$fence\n$text\n$fence',
        includeAsContentBlock: false,
      );
    }

    final path = await importToWorkspace(file);
    final size = formatFileSize(file.size);
    final marker = '[Attached: $path ($size)]';
    return PreparedAttachment(
      content: TextContent(marker),
      inputText: marker,
      includeAsContentBlock: false,
    );
  }

  /// Copy a picked file into the proot workspace.
  /// Returns the path inside proot where the file was placed
  /// (e.g. /root/workspace/uploads/photo.jpg).
  static Future<String> importToWorkspace(PlatformFile file) async {
    final sourcePath = file.path;
    if (sourcePath == null) {
      throw Exception('File path is null - file may not have been saved to disk');
    }

    final safeName = sanitizeFileName(file.name);
    final extension = _extensionFor(safeName);

    const destDir = 'root/workspace/uploads';
    final destPath = '$destDir/$safeName';

    if (_textExtensions.contains(extension)) {
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

  static String sanitizeFileName(String name) {
    final safeName = name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    return safeName.isEmpty ? 'attachment' : safeName;
  }

  static String _extensionFor(String name) {
    final lower = name.toLowerCase();
    final index = lower.lastIndexOf('.');
    if (index < 0 || index == lower.length - 1) return '';
    return lower.substring(index + 1);
  }

  static String _mediaTypeForImage(String extension) {
    if (extension == 'jpg' || extension == 'jpeg') return 'image/jpeg';
    if (extension == 'gif') return 'image/gif';
    if (extension == 'webp') return 'image/webp';
    return 'image/png';
  }
}
