import 'package:flutter/foundation.dart';

/// The default workspace root inside the Alpine rootfs.
///
/// Agent commands already run with /root/workspace as their working directory,
/// so a workspace is a named view of that tree (or a directory below it) rather
/// than a new storage location.
const String kDefaultWorkspaceRoot = '/root/workspace';

/// A named, persisted workspace.
///
/// The workspace is the local-first container later routes hang off: skills
/// live under the workspace skills directory, share-sheet saves under its
/// shared directory, and the file browser lists exactly the subtree of
/// [rootPath]. Nothing here writes to storage: PreferencesService owns
/// persistence.
@immutable
class WorkspaceMetadata {
  static final _validIdPattern = RegExp(r'^[a-zA-Z0-9_-]{1,64}$');
  static const int maxNameLength = 60;
  static const int maxRootPathLength = 400;

  static const String defaultWorkspaceId = 'workspace-default';

  final String id;
  final String name;

  /// Guest (rootfs) path this workspace scopes to. Always kDefaultWorkspaceRoot
  /// or a directory below it, so every workspace stays inside the tree the
  /// agent already owns.
  final String rootPath;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// Extension point for later routes (skills, memory scope, scheduler).
  /// Only flat JSON values are accepted, so a future field cannot smuggle
  /// arbitrary objects through persistence.
  final Map<String, Object?> attributes;

  WorkspaceMetadata({
    required this.id,
    required String name,
    this.rootPath = kDefaultWorkspaceRoot,
    DateTime? createdAt,
    DateTime? updatedAt,
    Map<String, Object?>? attributes,
  })  : name = validateName(name) ?? '工作区',
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now(),
        attributes = Map.unmodifiable(_sanitizeAttributes(attributes));

  factory WorkspaceMetadata.defaultWorkspace({DateTime? now}) =>
      WorkspaceMetadata(
        id: defaultWorkspaceId,
        name: '工作区',
        rootPath: kDefaultWorkspaceRoot,
        createdAt: now,
        updatedAt: now,
      );

  bool get isDefault => id == defaultWorkspaceId;

  WorkspaceMetadata copyWith({
    String? name,
    String? rootPath,
    DateTime? updatedAt,
    Map<String, Object?>? attributes,
  }) =>
      WorkspaceMetadata(
        id: id,
        name: name ?? this.name,
        rootPath: rootPath ?? this.rootPath,
        createdAt: createdAt,
        updatedAt: updatedAt ?? DateTime.now(),
        attributes: attributes ?? this.attributes,
      );

  /// True when [guestPath] is this workspace's root or lives below it.
  ///
  /// Traversal and escapes are rejected before the native scope check ever sees
  /// the path.
  bool containsPath(String guestPath) {
    final normalized = normalizeGuestPath(guestPath);
    if (normalized == null) return false;
    return normalized == rootPath || normalized.startsWith('$rootPath/');
  }

  /// Relative path of [guestPath] inside this workspace, or null when outside.
  String? relativePathOf(String guestPath) {
    final normalized = normalizeGuestPath(guestPath);
    if (normalized == null || !containsPath(normalized)) return null;
    if (normalized == rootPath) return '';
    return normalized.substring(rootPath.length + 1);
  }

  /// Normalizes a guest path: no traversal, no empty segments, absolute, no
  /// trailing slash. Returns null when the path cannot be used safely.
  static String? normalizeGuestPath(String? value) {
    final raw = value?.trim() ?? '';
    if (raw.isEmpty || raw.length > maxRootPathLength) return null;
    final segments = <String>[];
    for (final segment in raw.split('/')) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') return null;
      if (segment.contains('\u0000')) return null;
      segments.add(segment);
    }
    if (segments.isEmpty) return null;
    return '/${segments.join('/')}';
  }

  /// Validates a workspace root: inside kDefaultWorkspaceRoot and normalized.
  static String? validateRootPath(String? value) {
    final normalized = normalizeGuestPath(value);
    if (normalized == null) return null;
    if (normalized != kDefaultWorkspaceRoot &&
        !normalized.startsWith('$kDefaultWorkspaceRoot/')) {
      return null;
    }
    return normalized;
  }

  /// The user-facing name, trimmed and bounded. Null when unusable.
  static String? validateName(String? value) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty) return null;
    if (trimmed.length > maxNameLength) {
      return trimmed.substring(0, maxNameLength);
    }
    return trimmed;
  }

  static bool isValidId(String value) => _validIdPattern.hasMatch(value);

  /// Builds a filesystem-safe name for artifacts saved into the workspace.
  /// Separators and control characters never survive.
  static String sanitizeFileSegment(String value, {int maxLength = 48}) {
    final buffer = StringBuffer();
    for (final rune in value.trim().runes) {
      final character = String.fromCharCode(rune);
      final allowed =
          RegExp(r'[A-Za-z0-9._-]').hasMatch(character) || rune > 0x7F;
      if (!allowed) {
        buffer.write('_');
      } else {
        buffer.write(character);
      }
    }
    final collapsed = buffer.toString().replaceAll(RegExp(r'_{2,}'), '_');
    final trimmed = collapsed.replaceAll(RegExp(r'^[._]+|[._]+$'), '');
    if (trimmed.isEmpty) return 'shared';
    return trimmed.length > maxLength
        ? trimmed.substring(0, maxLength)
        : trimmed;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'rootPath': rootPath,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        if (attributes.isNotEmpty) 'attributes': attributes,
      };

  /// Tolerant parse: an entry that cannot be trusted is dropped instead of
  /// poisoning the stored list.
  static WorkspaceMetadata? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id']?.toString() ?? '';
    if (!isValidId(id)) return null;
    final name = validateName(json['name']?.toString());
    if (name == null) return null;
    final rootPath =
        validateRootPath(json['rootPath']?.toString()) ?? kDefaultWorkspaceRoot;
    return WorkspaceMetadata(
      id: id,
      name: name,
      rootPath: rootPath,
      createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? ''),
      updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? ''),
      attributes: _sanitizeAttributes(json['attributes']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WorkspaceMetadata &&
      other.id == id &&
      other.name == name &&
      other.rootPath == rootPath;

  @override
  int get hashCode => Object.hash(id, name, rootPath);

  @override
  String toString() => 'WorkspaceMetadata($id, $name, $rootPath)';

  static Map<String, Object?> _sanitizeAttributes(Object? value) {
    if (value is! Map) return const {};
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      final key = entry.key.toString();
      if (key.isEmpty || key.length > 64) continue;
      final item = entry.value;
      if (item is String) {
        result[key] = item.length > 512 ? item.substring(0, 512) : item;
      } else if (item is num || item is bool) {
        result[key] = item;
      }
    }
    return result;
  }
}
