import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../models/chat_models.dart';
import '../models/workspace_import_receipt.dart';
import 'attachment_budget.dart';
import 'bounded_file_reader.dart';
import 'native_bridge.dart';

class PreparedAttachment {
  final MessageContent content;
  final String inputText;
  final bool includeAsContentBlock;
  final bool containsSensitiveText;
  final String? sensitiveWarning;
  final WorkspaceImportReceipt? workspaceImportReceipt;

  const PreparedAttachment({
    required this.content,
    required this.inputText,
    required this.includeAsContentBlock,
    this.containsSensitiveText = false,
    this.sensitiveWarning,
    this.workspaceImportReceipt,
  });
}

/// Service for picking files from device storage and importing them
/// into the proot workspace for use by the AI agent.
class FileAttachmentService {
  static const _attachmentBudget = AttachmentBudget();
  static BoundedFileStreamFactory? _inlineReadStreamForTesting;

  static const Set<String> _imageExtensions = {
    'jpg',
    'jpeg',
    'png',
    'gif',
    'webp',
  };

  static const Set<String> _textExtensions = {
    'txt',
    'md',
    'json',
    'yaml',
    'yml',
    'xml',
    'csv',
    'py',
    'js',
    'jsx',
    'ts',
    'tsx',
    'dart',
    'sh',
    'bash',
    'html',
    'css',
    'scss',
    'toml',
    'cfg',
    'ini',
    'log',
    'sql',
    'go',
    'rs',
    'rb',
    'php',
    'java',
    'kt',
    'kts',
    'swift',
    'c',
    'cc',
    'cpp',
    'h',
    'hpp',
    'gradle',
    'properties',
    'env',
    'pem',
    'key',
    'crt',
    'cer',
    'credential',
    'credentials',
  };

  static final RegExp _sensitiveTextFilePattern = RegExp(
    r'(^|[._-])env($|[._-])|\.env($|[._-])|'
    r'\.(pem|key|crt|cer)$|'
    r'credential|credentials|secret|token',
    caseSensitive: false,
  );

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
      throw Exception(
          'File path is null - file may not have been saved to disk');
    }

    final safeName = sanitizeFileName(file.name);
    final extension = _extensionFor(safeName);

    if (_imageExtensions.contains(extension)) {
      final bytes = await BoundedFileReader.readBytes(
        sourcePath,
        validateBytes: (byteLength) => _attachmentBudget.checkInlineImageBytes(
          byteLength,
          fileName: safeName,
        ),
        streamFactory: _inlineReadStreamForTesting,
      );
      final base64Content = base64Encode(bytes);
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
      final bytes = await BoundedFileReader.readBytes(
        sourcePath,
        validateBytes: (byteLength) => _attachmentBudget.checkInlineTextBytes(
          byteLength,
          fileName: safeName,
        ),
        streamFactory: _inlineReadStreamForTesting,
      );
      late final String text;
      try {
        text = utf8.decode(bytes);
      } on FormatException {
        throw const FormatException('Text attachment is not valid UTF-8.');
      }
      final fence = text.contains('```') ? '````' : '```';
      return PreparedAttachment(
        content: TextContent('File: $safeName\n$fence\n$text\n$fence'),
        inputText: 'File: $safeName\n$fence\n$text\n$fence',
        includeAsContentBlock: false,
        containsSensitiveText: requiresSensitiveTextConfirmation(file),
        sensitiveWarning: sensitiveTextWarning(file),
      );
    }

    final receipt = await importToWorkspace(file);
    final marker = receipt.marker;
    return PreparedAttachment(
      content: TextContent(marker),
      inputText: marker,
      includeAsContentBlock: false,
      workspaceImportReceipt: receipt,
    );
  }

  static bool requiresSensitiveTextConfirmation(PlatformFile file) {
    final safeName = sanitizeFileName(file.name);
    final extension = _extensionFor(safeName);
    if (!_textExtensions.contains(extension)) return false;
    return _sensitiveTextFilePattern.hasMatch(safeName);
  }

  static String? sensitiveTextWarning(PlatformFile file) {
    if (!requiresSensitiveTextConfirmation(file)) return null;
    return '文件 ${sanitizeFileName(file.name)} 看起来可能包含密钥或凭据。'
        '确认后才会把全文注入提示词。';
  }

  /// Copy a picked file into the proot workspace.
  /// Returns the path inside proot where the file was placed
  /// (e.g. /root/workspace/uploads/photo.jpg).
  static Future<WorkspaceImportReceipt> importToWorkspace(
    PlatformFile file,
  ) async {
    final sourcePath = file.path;
    if (sourcePath == null) {
      throw Exception(
          'File path is null - file may not have been saved to disk');
    }

    final safeName = sanitizeFileName(file.name);
    final sourceFile = File(sourcePath);
    final byteLength = await sourceFile.length();
    _attachmentBudget.checkWorkspaceImportBytes(
      byteLength,
      fileName: safeName,
    );
    return NativeBridge.importFileToWorkspace(sourcePath, safeName);
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

  @visibleForTesting
  static void setInlineReadStreamForTesting(
    BoundedFileStreamFactory streamFactory,
  ) {
    _inlineReadStreamForTesting = streamFactory;
  }

  @visibleForTesting
  static void resetInlineReadStreamForTesting() {
    _inlineReadStreamForTesting = null;
  }
}
