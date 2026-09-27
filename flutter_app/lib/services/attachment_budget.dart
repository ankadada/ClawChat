import 'dart:convert';

import '../models/chat_models.dart';

class AttachmentBudgetException implements Exception {
  final String message;

  /// Size facts for the workspace-import limit, so a caller can rethrow the
  /// same failure as a picker error without re-parsing the message.
  final String? fileName;
  final int? actualBytes;
  final int? limitBytes;

  const AttachmentBudgetException(
    this.message, {
    this.fileName,
    this.actualBytes,
    this.limitBytes,
  });

  @override
  String toString() => message;
}

class AttachmentBudget {
  static const maxInlineImageBytes = 3 * 1024 * 1024;
  static const maxInlineImageBase64Chars = 4 * 1024 * 1024;
  static const maxInlineTextBytes = 100 * 1024;
  static const maxWorkspaceImportBytes = 50 * 1024 * 1024;
  static const maxMessageAttachmentBytes = 8 * 1024 * 1024;

  const AttachmentBudget();

  void checkInlineImageBytes(int byteLength, {String? fileName}) {
    if (byteLength > maxInlineImageBytes) {
      throw AttachmentBudgetException(
        '图片过大，无法直接发送：${_label(fileName)}'
        '（${formatBytes(byteLength)}，上限 ${formatBytes(maxInlineImageBytes)}）',
        fileName: _label(fileName),
        actualBytes: byteLength,
        limitBytes: maxInlineImageBytes,
      );
    }
  }

  void checkInlineTextBytes(int byteLength, {String? fileName}) {
    if (byteLength > maxInlineTextBytes) {
      throw AttachmentBudgetException(
        '文本文件过大，无法直接内联：${_label(fileName)}'
        '（${formatBytes(byteLength)}，上限 ${formatBytes(maxInlineTextBytes)}）',
        fileName: _label(fileName),
        actualBytes: byteLength,
        limitBytes: maxInlineTextBytes,
      );
    }
  }

  void checkWorkspaceImportBytes(int byteLength, {String? fileName}) {
    if (byteLength > maxWorkspaceImportBytes) {
      throw AttachmentBudgetException(
        workspaceImportTooLargeMessage(
          fileName: fileName,
          actualBytes: byteLength,
        ),
        fileName: _label(fileName),
        actualBytes: byteLength,
        limitBytes: maxWorkspaceImportBytes,
      );
    }
  }

  /// The one actionable, size-specific import message.
  ///
  /// Every oversized SAF/workspace import path returns this text (or the same
  /// numbers through [FilePickerException]) so the user always sees the file,
  /// the actual size and the limit instead of a generic failure.
  static String workspaceImportTooLargeMessage({
    String? fileName,
    required int actualBytes,
    int? limitBytes,
  }) {
    final limit = limitBytes ?? maxWorkspaceImportBytes;
    return '文件过大，未导入：${_labelStatic(fileName)}'
        '（${formatBytes(actualBytes)}，上限 ${formatBytes(limit)}）。'
        '请选择不超过 ${formatBytes(limit)} 的文件，或先在设备上压缩后再试。';
  }

  static String _labelStatic(String? fileName) {
    final safe = fileName?.trim();
    return safe == null || safe.isEmpty ? '未命名文件' : safe;
  }

  void checkMessageAttachments(List<MessageContent> attachments) {
    var total = 0;
    for (final attachment in attachments) {
      total += estimatedContentBytes(attachment);
    }
    if (total > maxMessageAttachmentBytes) {
      throw AttachmentBudgetException(
        '附件总量过大，无法发送：${formatBytes(total)}，'
        '上限 ${formatBytes(maxMessageAttachmentBytes)}',
      );
    }
  }

  int estimatedContentBytes(MessageContent content) {
    if (content is ImageContent) {
      return _base64DecodedLength(content.data);
    }
    if (content is TextContent) {
      return utf8.encode(content.text).length;
    }
    return utf8.encode(jsonEncode(content.toJson())).length;
  }

  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  int _base64DecodedLength(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) return 0;
    if (normalized.length > maxInlineImageBase64Chars) {
      throw const AttachmentBudgetException(
        '图片数据过大，无法发送（base64 超过 4 MB）',
      );
    }
    final padding = normalized.endsWith('==')
        ? 2
        : normalized.endsWith('=')
            ? 1
            : 0;
    return ((normalized.length * 3) ~/ 4) - padding;
  }

  String _label(String? fileName) {
    final safe = fileName?.trim();
    return safe == null || safe.isEmpty ? 'attachment' : safe;
  }
}
