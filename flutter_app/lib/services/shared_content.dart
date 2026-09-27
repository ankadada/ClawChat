import 'dart:convert';

import 'package:file_picker/file_picker.dart';

import 'file_attachment_service.dart';

/// Bounds applied to content that arrives from a native share Intent.
///
/// The native entry point already truncates, so this is the second line of
/// defence for a payload that a future caller (or a different platform
/// channel) hands over without the native cap.
class SharedContentLimits {
  const SharedContentLimits._();

  static const int maxTextBytes = 64 * 1024;
  static const int maxSubjectBytes = 1024;
  static const int maxImages = 9;
  static const int maxErrors = 32;

  /// Drops the bytes beyond [maxBytes] without splitting a code point.
  static String truncateUtf8(String value, int maxBytes) {
    if (maxBytes <= 0) return '';
    final bytes = utf8.encode(value);
    if (bytes.length <= maxBytes) return value;
    var end = maxBytes;
    while (end > 0 && (bytes[end] & 0xC0) == 0x80) {
      end--;
    }
    if (end == 0) return '';
    return utf8.decode(bytes.sublist(0, end));
  }
}

class SharedImage {
  final String path;
  final String name;
  final int size;
  final String? mimeType;

  const SharedImage({
    required this.path,
    required this.name,
    required this.size,
    this.mimeType,
  });

  factory SharedImage.fromNative(Map<dynamic, dynamic> json) {
    final name = json['name']?.toString().trim();
    return SharedImage(
      path: json['path']?.toString() ?? '',
      name: name == null || name.isEmpty ? 'shared-image' : name,
      size: _intValue(json['size']),
      mimeType: json['mimeType']?.toString(),
    );
  }

  PlatformFile toPlatformFile() => PlatformFile(
        name: name,
        size: size,
        path: path,
      );

  static int _intValue(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }
}

class SharedContent {
  final String text;
  final String? subject;
  final List<SharedImage> images;
  final List<String> errors;

  const SharedContent({
    this.text = '',
    this.subject,
    this.images = const [],
    this.errors = const [],
  });

  factory SharedContent.fromNative(Map<dynamic, dynamic>? json) {
    if (json == null) return const SharedContent();
    final rawImages = json['images'];
    final rawErrors = json['errors'];
    final rawSubject = json['subject']?.toString();
    return SharedContent(
      text: SharedContentLimits.truncateUtf8(
        json['text']?.toString() ?? '',
        SharedContentLimits.maxTextBytes,
      ),
      subject: rawSubject == null
          ? null
          : SharedContentLimits.truncateUtf8(
              rawSubject,
              SharedContentLimits.maxSubjectBytes,
            ),
      images: rawImages is Iterable
          ? rawImages
              .whereType<Map>()
              .map(SharedImage.fromNative)
              .where((image) => image.path.trim().isNotEmpty)
              .take(SharedContentLimits.maxImages)
              .toList(growable: false)
          : const [],
      errors: rawErrors is Iterable
          ? rawErrors
              .map((error) => error.toString())
              .take(SharedContentLimits.maxErrors)
              .toList(growable: false)
          : const [],
    );
  }

  bool get hasContent => text.trim().isNotEmpty || images.isNotEmpty;
  bool get hasFeedback => errors.isNotEmpty;
  bool get hasPayload => hasContent || hasFeedback;
}

class PreparedSharedContent {
  final String draftText;
  final List<PreparedAttachment> attachments;
  final List<String> warnings;

  const PreparedSharedContent({
    required this.draftText,
    this.attachments = const [],
    this.warnings = const [],
  });

  bool get hasContent => draftText.trim().isNotEmpty || attachments.isNotEmpty;
  bool get hasFeedback => warnings.isNotEmpty;
  bool get hasPayload => hasContent || hasFeedback;
}

class SharedContentImportPlan {
  final bool createDraft;
  final bool showFeedback;

  const SharedContentImportPlan({
    required this.createDraft,
    required this.showFeedback,
  });

  factory SharedContentImportPlan.fromPrepared(PreparedSharedContent content) {
    return SharedContentImportPlan(
      createDraft: content.hasContent,
      showFeedback: content.hasFeedback || content.hasContent,
    );
  }
}

class SharedContentPreparer {
  const SharedContentPreparer();

  Future<PreparedSharedContent> prepare(SharedContent content) async {
    final attachments = <PreparedAttachment>[];
    final warnings = <String>[...content.errors];

    for (final image in content.images) {
      try {
        attachments.add(
          await FileAttachmentService.prepareForMessage(
            image.toPlatformFile(),
          ),
        );
      } catch (e) {
        warnings.add('${image.name}: $e');
      }
    }

    return PreparedSharedContent(
      draftText: content.text.trim(),
      attachments: attachments,
      warnings: warnings,
    );
  }
}
