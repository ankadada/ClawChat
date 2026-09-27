import 'package:flutter/foundation.dart';

/// One entry the file browser can show.
@immutable
class WorkspaceFileEntry {
  final String name;

  /// Guest (rootfs) path, the form every scoped API takes.
  final String path;
  final bool isDirectory;
  final bool isSymbolicLink;
  final int sizeBytes;
  final DateTime? modifiedAt;

  const WorkspaceFileEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.isSymbolicLink = false,
    this.sizeBytes = 0,
    this.modifiedAt,
  });

  static WorkspaceFileEntry? tryFromNative(Object? json) {
    if (json is! Map) return null;
    final name = json['name']?.toString() ?? '';
    final path = json['path']?.toString() ?? '';
    if (name.isEmpty || path.isEmpty) return null;
    final modified =
        (json['modifiedEpochMs'] is num && (json['modifiedEpochMs'] as num) > 0)
            ? DateTime.fromMillisecondsSinceEpoch(
                (json['modifiedEpochMs'] as num).toInt(),
              )
            : null;
    return WorkspaceFileEntry(
      name: name,
      path: path,
      isDirectory: json['isDirectory'] == true,
      isSymbolicLink: json['isSymbolicLink'] == true,
      sizeBytes:
          json['sizeBytes'] is num ? (json['sizeBytes'] as num).toInt() : 0,
      modifiedAt: modified,
    );
  }

  /// A link is never a folder to open: the browser does not follow it.
  bool get canOpen => isDirectory && !isSymbolicLink;
}

/// One listing page.
@immutable
class WorkspaceFileListing {
  final List<WorkspaceFileEntry> entries;
  final bool truncated;

  const WorkspaceFileListing({required this.entries, this.truncated = false});

  factory WorkspaceFileListing.fromNative(Object? json) {
    if (json is! Map) return const WorkspaceFileListing(entries: []);
    final raw = json['entries'];
    final entries = raw is Iterable
        ? raw
            .map(WorkspaceFileEntry.tryFromNative)
            .whereType<WorkspaceFileEntry>()
            .toList(growable: false)
        : const <WorkspaceFileEntry>[];
    return WorkspaceFileListing(
      entries: entries,
      truncated: json['truncated'] == true,
    );
  }

  bool get isEmpty => entries.isEmpty;
}

/// What the preview pane can render for one file.
enum WorkspaceFilePreviewKind { text, image, unsupported }

@immutable
class WorkspaceFilePreview {
  final WorkspaceFilePreviewKind kind;
  final String? text;
  final Uint8List? bytes;
  final String? mediaType;
  final String? note;

  const WorkspaceFilePreview({
    required this.kind,
    this.text,
    this.bytes,
    this.mediaType,
    this.note,
  });

  const WorkspaceFilePreview.unsupported(this.note)
      : kind = WorkspaceFilePreviewKind.unsupported,
        text = null,
        bytes = null,
        mediaType = null;
}
