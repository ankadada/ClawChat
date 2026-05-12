import '../native_bridge.dart';
import 'tool_registry.dart';

class ReadFileTool extends Tool {
  @override
  String get name => 'read_file';

  @override
  String get description =>
      'Read the contents of a file from the Alpine Linux filesystem. '
      'Provide the absolute path inside the proot environment (e.g., /root/workspace/main.py). '
      'Supports optional line range with offset and limit.';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'path': {
        'type': 'string',
        'description': 'Absolute path to the file (inside proot)',
      },
      'offset': {
        'type': 'integer',
        'description': 'Start reading from this line number (1-based, default: 1)',
      },
      'limit': {
        'type': 'integer',
        'description': 'Maximum number of lines to read (default: 2000)',
      },
    },
    'required': ['path'],
  };

  @override
  Future<String> execute(Map<String, dynamic> input) async {
    final path = input['path'] as String;
    final offset = input['offset'] as int? ?? 1;
    final limit = input['limit'] as int? ?? 2000;

    final resolved = _resolvePath(path);
    if (resolved == null) {
      return 'Error: Path traversal detected. Paths must stay within /root/workspace.';
    }

    try {
      final rootfsPath = resolved.startsWith('/') ? resolved.substring(1) : resolved;
      final content = await NativeBridge.readRootfsFile(rootfsPath);

      if (content == null) return 'Error: File not found: $path';

      final lines = content.split('\n');
      final startLine = (offset - 1).clamp(0, lines.length);
      final endLine = (startLine + limit).clamp(0, lines.length);
      final selectedLines = lines.sublist(startLine, endLine);

      final buffer = StringBuffer();
      for (int i = 0; i < selectedLines.length; i++) {
        buffer.writeln('${startLine + i + 1}\t${selectedLines[i]}');
      }

      final result = buffer.toString();
      if (result.length > 100000) {
        return '${result.substring(0, 100000)}\n\n[File truncated]';
      }
      return result;
    } catch (e) {
      return 'Error reading file: $e';
    }
  }

  static const _allowedRoot = '/root/workspace';

  String? _resolvePath(String path) {
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
    if (normalized != _allowedRoot && !normalized.startsWith('$_allowedRoot/')) return null;
    return normalized;
  }
}
