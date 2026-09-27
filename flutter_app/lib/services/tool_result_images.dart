import 'dart:convert';
import 'dart:typed_data';

import 'native_bridge.dart';

/// Where an image reference in a tool result points.
enum ToolResultImageKind { data, network, path }

class ToolResultImage {
  final ToolResultImageKind kind;
  final String value;

  const ToolResultImage(this.kind, this.value);
}

/// Finds image references in a tool result: inline data URLs, image URLs, and
/// workspace image paths. Order follows first appearance; duplicates collapse.
List<ToolResultImage> extractToolResultImages(
  String? output, {
  int limit = 4,
}) {
  if (output == null || output.trim().isEmpty) return const [];
  final found = <String, ToolResultImage>{};

  final dataPattern = RegExp(
    r'data:image/(?:png|jpe?g|gif|webp|bmp);base64,[A-Za-z0-9+/=]+',
    caseSensitive: false,
  );
  for (final match in dataPattern.allMatches(output)) {
    final value = match.group(0)!;
    found.putIfAbsent(
      value,
      () => ToolResultImage(ToolResultImageKind.data, value),
    );
  }

  final urlPattern = RegExp(
    r'https?://[^\s\x22\x27`)<>\]]+\.(?:png|jpe?g|gif|webp|bmp)(?:\?[^\s\x22\x27`)<>\]]*)?',
    caseSensitive: false,
  );
  for (final match in urlPattern.allMatches(output)) {
    final value = match.group(0)!;
    found.putIfAbsent(
      value,
      () => ToolResultImage(ToolResultImageKind.network, value),
    );
  }

  final pathPattern = RegExp(
    r'(?:^|[\s\x22\x27`(=])((?:/root/workspace|/storage|/sdcard)/[^\s\x22\x27`)<>\]]+\.(?:png|jpe?g|gif|webp|bmp))',
    caseSensitive: false,
  );
  for (final match in pathPattern.allMatches(output)) {
    final value = match.group(1)!;
    found.putIfAbsent(
      value,
      () => ToolResultImage(ToolResultImageKind.path, value),
    );
  }

  return found.values.take(limit).toList(growable: false);
}

/// Turns an image reference into the canonical provider image block.
///
/// Data URLs are decoded in place. A workspace path is read with a bounded
/// size and only when the bytes really are a PNG, JPEG, or WEBP; a missing or
/// oversized file resolves to null and stays text. Network URLs are never
/// downloaded, so they always stay text.
class ToolResultImageResolver {
  ToolResultImageResolver._();

  /// The largest image the app will send to a model.
  static const int maxBytes = 2 * 1024 * 1024;

  /// The most images taken from one tool result.
  static const int maxImages = 4;

  /// The workspace root a tool-result image path may live under.
  static const String allowedRoot = '/root/workspace';

  static const Map<String, String> _mimeByExtension = {
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'webp': 'image/webp',
  };

  static const Map<String, String> _extensionByMime = {
    'image/png': 'png',
    'image/jpeg': 'jpg',
    'image/webp': 'webp',
  };

  /// The media type the bytes actually are, from their magic number.
  static String? detectMediaType(Uint8List bytes) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0D &&
        bytes[5] == 0x0A &&
        bytes[6] == 0x1A &&
        bytes[7] == 0x0A) {
      return 'image/png';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'image/jpeg';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'image/webp';
    }
    return null;
  }

  /// The canonical image block for already-decoded bytes, or null when the
  /// bytes are not a supported image or exceed [maxBytes].
  static Map<String, dynamic>? blockForBytes(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > maxBytes) return null;
    final mediaType = detectMediaType(bytes);
    if (mediaType == null) return null;
    return {
      'type': 'image',
      'source': {
        'type': 'base64',
        'media_type': mediaType,
        'data': base64Encode(bytes),
      },
    };
  }

  /// The canonical image block for a `data:image/...;base64,...` URL.
  static Map<String, dynamic>? blockForDataUrl(String dataUrl) {
    final match =
        RegExp(r'^data:(image/[a-z0-9.+-]+);base64,(.*)$', caseSensitive: false)
            .firstMatch(dataUrl.trim());
    if (match == null) return null;
    final mediaType = match.group(1)!.toLowerCase();
    final normalized = switch (mediaType) {
      'image/jpg' => 'image/jpeg',
      _ => mediaType,
    };
    if (!_extensionByMime.containsKey(normalized)) return null;
    final Uint8List bytes;
    try {
      bytes = base64Decode(match.group(2)!);
    } catch (_) {
      return null;
    }
    if (bytes.isEmpty || bytes.length > maxBytes) return null;
    // Trust the declared type only when it is one we send.
    return {
      'type': 'image',
      'source': {
        'type': 'base64',
        'media_type': normalized,
        'data': base64Encode(bytes),
      },
    };
  }

  static bool _isAllowedPath(String path) {
    if (!path.startsWith('$allowedRoot/')) return false;
    if (path.contains('/../') || path.endsWith('/..')) return false;
    final extension = path.split('.').last.toLowerCase();
    return _mimeByExtension.containsKey(extension);
  }

  /// The canonical image block for [image], or null when it must stay text.
  static Future<Map<String, dynamic>?> resolve(ToolResultImage image) async {
    switch (image.kind) {
      case ToolResultImageKind.data:
        return blockForDataUrl(image.value);
      case ToolResultImageKind.network:
        // Never downloaded: the network stays text.
        return null;
      case ToolResultImageKind.path:
        if (!_isAllowedPath(image.value)) return null;
        final bytes = await readWorkspaceBytes(image.value);
        if (bytes == null) return null;
        return blockForBytes(bytes);
    }
  }

  /// Bounded read of a workspace file; null when it is missing or too large.
  static Future<Uint8List?> readWorkspaceBytes(String path) async {
    if (!_isAllowedPath(path)) return null;
    try {
      final bytes = await NativeBridge.readRootfsFileBytes(
        path.startsWith('/') ? path.substring(1) : path,
        allowedRoots: const [allowedRoot],
        maxBytes: maxBytes,
      );
      if (bytes == null || bytes.isEmpty || bytes.length > maxBytes) {
        return null;
      }
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// Every resolved image block in [text], in order.
  static Future<List<Map<String, dynamic>>> resolveBlocks(
    String? text, {
    int limit = maxImages,
  }) async {
    final blocks = <Map<String, dynamic>>[];
    for (final image in extractToolResultImages(text, limit: limit)) {
      final block = await resolve(image);
      if (block != null) blocks.add(block);
    }
    return blocks;
  }

  /// Every image block for one tool result: the pre-resolved metadata entries
  /// plus any inline data URL still present in [text]. Network URLs are not
  /// downloaded, so they contribute nothing here.
  static List<Map<String, dynamic>> imageBlocksFor(
    String? text,
    Map<String, dynamic> metadata,
  ) {
    final blocks = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final block in blocksFromMetadata(metadata)) {
      final key = _blockKey(block);
      if (key != null && seen.add(key)) blocks.add(block);
    }
    for (final image in extractToolResultImages(text, limit: maxImages)) {
      if (image.kind != ToolResultImageKind.data) continue;
      final block = blockForDataUrl(image.value);
      if (block == null) continue;
      final key = _blockKey(block);
      if (key != null && seen.add(key)) blocks.add(block);
    }
    return blocks.take(maxImages).toList(growable: false);
  }

  static String? _blockKey(Map<String, dynamic> block) {
    final source = block['source'];
    if (source is! Map) return null;
    return source['data']?.toString();
  }

  /// Image blocks a tool result already carries in its metadata.
  ///
  /// The agent loop resolves local paths once and stores the result here, so
  /// `toApiJson`, transcript replay, and the provider transform all see the
  /// same decoded bytes without re-reading the filesystem.
  static List<Map<String, dynamic>> blocksFromMetadata(Map<String, dynamic> metadata) {
    final raw = metadata['toolResultImages'];
    if (raw is! List) return const [];
    final blocks = <Map<String, dynamic>>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final block = blockForStoredEntry(item);
      if (block != null) blocks.add(block);
    }
    return blocks;
  }

  /// Re-validate one stored `{media_type, data}` entry.
  static Map<String, dynamic>? blockForStoredEntry(Map<dynamic, dynamic> entry) {
    final mediaType = entry['media_type']?.toString().toLowerCase();
    final data = entry['data']?.toString();
    if (mediaType == null || data == null || data.isEmpty) return null;
    final normalized = switch (mediaType) {
      'image/jpg' => 'image/jpeg',
      _ => mediaType,
    };
    if (!_extensionByMime.containsKey(normalized)) return null;
    final Uint8List bytes;
    try {
      bytes = base64Decode(data);
    } catch (_) {
      return null;
    }
    if (bytes.isEmpty || bytes.length > maxBytes) return null;
    return {
      'type': 'image',
      'source': {
        'type': 'base64',
        'media_type': normalized,
        'data': base64Encode(bytes),
      },
    };
  }

  /// The stored metadata entry for [block] (media type plus base64 payload).
  static Map<String, dynamic>? metadataEntryFor(Map<String, dynamic> block) {
    final source = block['source'];
    if (source is! Map) return null;
    final mediaType = source['media_type']?.toString();
    final data = source['data']?.toString();
    if (mediaType == null || data == null) return null;
    return {'media_type': mediaType, 'data': data};
  }
}
