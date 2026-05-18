import '../native_bridge.dart';
import 'tool_registry.dart';

class WriteFileTool extends Tool {
  @override
  String get name => 'write_file';

  @override
  String get description =>
      'Write content to a file in the Alpine Linux filesystem. '
      'Creates the file if it doesn\'t exist, overwrites if it does. '
      'Parent directories are created automatically. '
      'Path must be within /root/workspace.';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'path': {
        'type': 'string',
        'description': 'Absolute path for the file (inside proot, under /root/workspace)',
      },
      'content': {
        'type': 'string',
        'description': 'The content to write to the file',
      },
    },
    'required': ['path', 'content'],
  };

  static const _allowedRoot = '/root/workspace';

  static final _shellMetacharacters = RegExp(r"[;|&`$(){}!<>*?\[\]~#\\']");

  static String? _resolvePath(String path) {
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    final resolved = <String>[];
    for (final seg in segments) {
      if (seg == '.') continue;
      if (seg == '..') {
        if (resolved.isEmpty) return null;
        resolved.removeLast();
      } else {
        resolved.add(seg);
      }
    }
    final normalized = '/${resolved.join('/')}';
    if (!normalized.startsWith('$_allowedRoot/')) return null;
    return normalized;
  }

  @override
  Future<String> execute(Map<String, dynamic> input) async {
    final path = input['path'] as String;
    final content = input['content'] as String;

    final resolved = _resolvePath(path);
    if (resolved == null) {
      return 'Error: Path must be within $_allowedRoot. Path traversal is not allowed.';
    }

    try {
      final rootfsPath = resolved.substring(1);
      if (_shellMetacharacters.hasMatch(resolved)) {
        return 'Error: Path contains invalid characters.';
      }
      final dir = resolved.substring(0, resolved.lastIndexOf('/'));
      await NativeBridge.runInProot("mkdir -p '$dir'", mountStorage: false);
      await NativeBridge.writeRootfsFile(rootfsPath, content);
      return 'Successfully wrote ${content.length} bytes to $resolved';
    } catch (e) {
      return 'Error writing file: $e';
    }
  }
}
