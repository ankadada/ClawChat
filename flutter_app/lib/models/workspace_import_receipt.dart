class WorkspaceImportReceipt {
  static const currentSchemaVersion = 1;
  static final _operationPattern = RegExp(r'^[a-f0-9]{32}$');
  static final _pathPattern = RegExp(
    r'^/root/workspace/uploads/[a-zA-Z0-9._-]{1,212}$',
  );
  static final _digestPattern = RegExp(r'^[a-f0-9]{64}$');
  static final _displayNamePattern = RegExp(r'^[a-zA-Z0-9._-]{1,180}$');

  final int schemaVersion;
  final String operationId;
  final String storedPath;
  final int size;
  final String sha256;
  final String displayName;

  const WorkspaceImportReceipt._({
    required this.schemaVersion,
    required this.operationId,
    required this.storedPath,
    required this.size,
    required this.sha256,
    required this.displayName,
  });

  factory WorkspaceImportReceipt({
    required String operationId,
    required String storedPath,
    required int size,
    required String sha256,
    required String displayName,
  }) {
    final receipt = WorkspaceImportReceipt._(
      schemaVersion: currentSchemaVersion,
      operationId: operationId,
      storedPath: storedPath,
      size: size,
      sha256: sha256,
      displayName: displayName,
    );
    receipt._validate();
    return receipt;
  }

  factory WorkspaceImportReceipt.fromJson(Map<String, dynamic> json) {
    const allowed = {
      'schemaVersion',
      'operationId',
      'storedPath',
      'size',
      'sha256',
      'displayName',
    };
    if (json.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException('Unknown workspace import receipt field.');
    }
    final receipt = WorkspaceImportReceipt._(
      schemaVersion: json['schemaVersion'] as int? ?? 0,
      operationId: json['operationId'] as String? ?? '',
      storedPath: json['storedPath'] as String? ?? '',
      size: json['size'] as int? ?? -1,
      sha256: json['sha256'] as String? ?? '',
      displayName: json['displayName'] as String? ?? '',
    );
    receipt._validate();
    return receipt;
  }

  String get marker =>
      '[Attached: $displayName -> $storedPath (${_formatSize(size)})]';

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'operationId': operationId,
        'storedPath': storedPath,
        'size': size,
        'sha256': sha256,
        'displayName': displayName,
      };

  void _validate() {
    if (schemaVersion != currentSchemaVersion ||
        !_operationPattern.hasMatch(operationId) ||
        !_pathPattern.hasMatch(storedPath) ||
        size < 0 ||
        size > 50 * 1024 * 1024 ||
        !_digestPattern.hasMatch(sha256) ||
        !_displayNamePattern.hasMatch(displayName)) {
      throw const FormatException('Invalid workspace import receipt.');
    }
  }

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
