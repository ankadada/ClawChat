import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

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

/// A picker failure without exposing provider paths, URI contents, or native
/// exception details to the UI.
class FilePickerException implements Exception {
  final String reason;

  const FilePickerException(this.reason);

  String get userMessage {
    switch (reason) {
      case 'no_activity':
        return '文件选择器暂不可用，请返回应用后重试。';
      case 'unknown_path':
      case 'path_missing':
      case 'path_unreadable':
      case 'content_stage_failed':
        return '无法读取所选文件，请换一个文件或重新选择。';
      case 'oversized':
        return '所选文件超过应用允许的大小上限。';
      default:
        return '无法打开文件选择器，请重试。';
    }
  }

  @override
  String toString() => userMessage;
}

typedef FilePickerInvoker = Future<FilePickerResult?> Function({
  required FileType type,
  required bool allowMultiple,
  required List<String>? allowedExtensions,
});

/// Service for picking files from device storage and importing them
/// into the proot workspace for use by the AI agent.
class FileAttachmentService {
  static const _attachmentBudget = AttachmentBudget();
  static BoundedFileStreamFactory? _inlineReadStreamForTesting;
  static FilePickerInvoker? _pickerForTesting;
  static int _materializedFileCounter = 0;
  static final Set<String> _nativeStagedPaths = <String>{};
  static final Set<String> _dartStagedPaths = <String>{};

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
    List<String>? allowedExtensions,
  }) async {
    try {
      final result = _pickerForTesting == null
          ? await FilePicker.platform.pickFiles(
              type: type,
              allowedExtensions: allowedExtensions,
              allowMultiple: allowMultiple,
              withData: false,
              withReadStream: false,
            )
          : await _pickerForTesting!(
              type: type,
              allowMultiple: allowMultiple,
              allowedExtensions: allowedExtensions,
            );
      if (result == null) return const [];
      return Future.wait(result.files.map(_materializeIfNeeded));
    } on PlatformException catch (error) {
      if (_isCancellationCode(error.code)) return const [];
      throw FilePickerException(error.code);
    } on MissingPluginException {
      throw const FilePickerException('missing_plugin');
    } on FileSystemException {
      throw const FilePickerException('path_unreadable');
    } on AttachmentBudgetException {
      throw const FilePickerException('oversized');
    }
  }

  static bool _isCancellationCode(String code) {
    final normalized = code.trim().toLowerCase();
    return normalized == 'cancelled' ||
        normalized == 'canceled' ||
        normalized == 'user_cancelled' ||
        normalized == 'file_picker_cancelled';
  }

  /// Pick images specifically.
  static Future<List<PlatformFile>> pickImages({
    bool allowMultiple = false,
  }) async {
    return pickFiles(type: FileType.image, allowMultiple: allowMultiple);
  }

  /// Android document providers do not consistently map tgz/tar.gz suffixes
  /// to MIME filters. Pick broadly, then apply the exact host-owned suffix
  /// allowlist before any archive inspection or extraction.
  static Future<PlatformFile?> pickSkillArchive() async {
    final files = await pickFiles(type: FileType.any);
    if (files.isEmpty) return null;
    final selected = files.single;
    if (!isSkillArchiveName(selected.name)) {
      throw const FilePickerException('unsupported_archive');
    }
    return selected;
  }

  /// Prepare a picked file for inclusion in a user message.
  ///
  /// Images are sent as multimodal content blocks. Text files are inlined as
  /// fenced code with filename context. Other binaries are copied into the
  /// workspace and represented by their workspace path.
  static Future<PreparedAttachment> prepareForMessage(PlatformFile file) async {
    final sourcePath = await _localPathFor(file);
    try {
      return await _prepareForMessageAtPath(file, sourcePath);
    } finally {
      await cleanupLocalPath(sourcePath);
    }
  }

  static Future<PreparedAttachment> _prepareForMessageAtPath(
    PlatformFile file,
    String sourcePath,
  ) async {
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

    final receipt = await _importToWorkspaceAtPath(file, sourcePath);
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
    final sourcePath = await _localPathFor(file);
    try {
      return await _importToWorkspaceAtPath(file, sourcePath);
    } finally {
      await cleanupLocalPath(sourcePath);
    }
  }

  static Future<WorkspaceImportReceipt> _importToWorkspaceAtPath(
    PlatformFile file,
    String sourcePath,
  ) async {
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

  static bool isSkillArchiveName(String name) {
    final lower = name.trim().toLowerCase();
    return lower.endsWith('.zip') ||
        lower.endsWith('.tar.gz') ||
        lower.endsWith('.tgz');
  }

  /// Resolves a picker result to an app-readable local path. Some platforms
  /// can provide bounded bytes without a filesystem path; stage those bytes in
  /// the app cache so the existing native import broker can still verify and
  /// receipt them. A missing path and missing bytes fail closed.
  static Future<String> localPathFor(PlatformFile file) => _localPathFor(file);

  static Future<String> _localPathFor(PlatformFile file) async {
    final path = file.path;
    final bytes = file.bytes;
    if (path != null && path.isNotEmpty) {
      try {
        final handle = await File(path).open();
        await handle.close();
        return path;
      } catch (_) {
        final staged = await _stageContentIdentifier(
          file,
          failClosed: bytes == null,
        );
        if (staged != null) return staged;
        if (bytes == null) throw const FilePickerException('path_unreadable');
      }
    }
    final staged = await _stageContentIdentifier(
      file,
      failClosed: bytes == null,
    );
    if (staged != null) return staged;
    if (bytes == null) {
      throw const FilePickerException('path_missing');
    }
    _attachmentBudget.checkWorkspaceImportBytes(
      bytes.length,
      fileName: sanitizeFileName(file.name),
    );
    final cache = await _temporaryDirectory();
    final directory = Directory('${cache.path}/clawchat-picked-files');
    await directory.create(recursive: true);
    final counter = ++_materializedFileCounter;
    final target = File(
      '${directory.path}/$counter-${sanitizeFileName(file.name)}',
    );
    await target.writeAsBytes(bytes, flush: true);
    _dartStagedPaths.add(target.path);
    return target.path;
  }

  static Future<String?> _stageContentIdentifier(
    PlatformFile file, {
    required bool failClosed,
  }) async {
    final identifier = file.identifier;
    if (identifier == null || !identifier.startsWith('content://')) {
      return null;
    }
    try {
      final path = await NativeBridge.stagePickedContentUri(
        contentUri: identifier,
        displayName: sanitizeFileName(file.name),
      );
      _nativeStagedPaths.add(path);
      return path;
    } catch (_) {
      if (!failClosed) return null;
      throw const FilePickerException('content_stage_failed');
    }
  }

  /// Removes only cache files created by this service/native URI staging.
  /// Provider-owned picker cache paths are never deleted here.
  static Future<void> cleanupLocalPath(String path) async {
    if (_nativeStagedPaths.remove(path)) {
      try {
        await NativeBridge.discardPickedContentCache(path);
      } catch (_) {}
      return;
    }
    if (_dartStagedPaths.remove(path)) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }

  static Future<Directory> _temporaryDirectory() async {
    try {
      return await getTemporaryDirectory();
    } on MissingPluginException {
      // Headless/unit-test embedders may not register path_provider. The
      // process temp directory remains app-private and is still bounded by
      // the byte budget above.
      return Directory.systemTemp;
    }
  }

  static Future<PlatformFile> _materializeIfNeeded(PlatformFile file) async {
    if (file.path != null && file.path!.isNotEmpty) return file;
    if (file.bytes == null &&
        !(file.identifier?.startsWith('content://') ?? false)) {
      throw const FilePickerException('path_missing');
    }
    final path = await _localPathFor(file);
    return PlatformFile(
      name: file.name,
      size: file.size,
      path: path,
      bytes: file.bytes,
      identifier: file.identifier,
      readStream: file.readStream,
    );
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

  @visibleForTesting
  static void setPickerForTesting(FilePickerInvoker picker) {
    _pickerForTesting = picker;
  }

  @visibleForTesting
  static void resetPickerForTesting() {
    _pickerForTesting = null;
  }
}
