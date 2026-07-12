import 'dart:convert';
import 'dart:typed_data';

enum UpdateArtifactKind { extension, androidApp }

/// Strict, signed metadata checked before any update artifact is downloaded.
final class SignedUpdateMetadata {
  static const currentSchemaVersion = 1;

  const SignedUpdateMetadata({
    required this.schemaVersion,
    required this.kind,
    required this.targetId,
    required this.version,
    required this.revision,
    required this.artifactUrl,
    required this.artifactSha256,
    required this.artifactSize,
    required this.signatureAlgorithm,
    required this.keyId,
    required this.signature,
  });

  final int schemaVersion;
  final UpdateArtifactKind kind;
  final String targetId;
  final String version;
  final int revision;
  final Uri artifactUrl;
  final String artifactSha256;
  final int artifactSize;
  final String signatureAlgorithm;
  final String keyId;
  final String signature;

  factory SignedUpdateMetadata.parse(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const FormatException('Update metadata must be an object.');
    }
    return SignedUpdateMetadata.fromJson(Map<String, dynamic>.from(decoded));
  }

  factory SignedUpdateMetadata.fromJson(Map<String, dynamic> json) {
    const keys = {
      'schemaVersion',
      'kind',
      'targetId',
      'version',
      'revision',
      'artifactUrl',
      'artifactSha256',
      'artifactSize',
      'signatureAlgorithm',
      'keyId',
      'signature',
    };
    if (json.keys.any((key) => !keys.contains(key)) ||
        !keys.every(json.containsKey)) {
      throw const FormatException('Update metadata fields are invalid.');
    }
    final schemaVersion = json['schemaVersion'];
    if (schemaVersion != currentSchemaVersion) {
      throw const FormatException('Update metadata schema is unsupported.');
    }
    final kind = switch (json['kind']) {
      'extension' => UpdateArtifactKind.extension,
      'androidApp' => UpdateArtifactKind.androidApp,
      _ => throw const FormatException('Update kind is invalid.'),
    };
    final targetId = _boundedString(json['targetId'], 128);
    if (!_targetId.hasMatch(targetId)) {
      throw const FormatException('Update target ID is invalid.');
    }
    final version = _boundedString(json['version'], 64);
    if (!_semanticVersion.hasMatch(version)) {
      throw const FormatException('Update version is invalid.');
    }
    final revision = json['revision'];
    if (revision is! int || revision <= 0) {
      throw const FormatException('Update revision is invalid.');
    }
    final artifactUrl = Uri.tryParse(_boundedString(json['artifactUrl'], 2048));
    if (artifactUrl == null ||
        artifactUrl.scheme.toLowerCase() != 'https' ||
        artifactUrl.host.isEmpty ||
        artifactUrl.userInfo.isNotEmpty ||
        artifactUrl.hasQuery ||
        artifactUrl.hasFragment) {
      throw const FormatException('Update artifact URL must be HTTPS.');
    }
    final artifactSha256 =
        _boundedString(json['artifactSha256'], 64).toLowerCase();
    if (!_sha256.hasMatch(artifactSha256)) {
      throw const FormatException('Update artifact SHA-256 is invalid.');
    }
    final artifactSize = json['artifactSize'];
    if (artifactSize is! int || artifactSize <= 0) {
      throw const FormatException('Update artifact size is invalid.');
    }
    final lowerPath = artifactUrl.path.toLowerCase();
    if (kind == UpdateArtifactKind.androidApp && !lowerPath.endsWith('.apk')) {
      throw const FormatException('Android update artifact must be an APK.');
    }
    if (kind == UpdateArtifactKind.extension &&
        !lowerPath.endsWith('.zip') &&
        !lowerPath.endsWith('.tgz') &&
        !lowerPath.endsWith('.tar.gz')) {
      throw const FormatException(
          'Extension update artifact must be an archive.');
    }
    final signatureAlgorithm = _boundedString(json['signatureAlgorithm'], 32);
    if (!const {'SHA256withRSA', 'SHA256withECDSA'}
        .contains(signatureAlgorithm)) {
      throw const FormatException('Update signature algorithm is unsupported.');
    }
    final keyId = _boundedString(json['keyId'], 64).toLowerCase();
    if (!_sha256.hasMatch(keyId)) {
      throw const FormatException('Update key ID is invalid.');
    }
    final signature = _boundedString(json['signature'], 4096);
    try {
      if (base64Decode(signature).isEmpty) {
        throw const FormatException('Update signature is empty.');
      }
    } on FormatException {
      throw const FormatException('Update signature is invalid.');
    }
    return SignedUpdateMetadata(
      schemaVersion: schemaVersion,
      kind: kind,
      targetId: targetId,
      version: version,
      revision: revision,
      artifactUrl: artifactUrl.replace(
        scheme: artifactUrl.scheme.toLowerCase(),
        host: artifactUrl.host.toLowerCase(),
      ),
      artifactSha256: artifactSha256,
      artifactSize: artifactSize,
      signatureAlgorithm: signatureAlgorithm,
      keyId: keyId,
      signature: signature,
    );
  }

  Map<String, dynamic> toJson({bool includeSignature = true}) => {
        'schemaVersion': schemaVersion,
        'kind': kind.name,
        'targetId': targetId,
        'version': version,
        'revision': revision,
        'artifactUrl': artifactUrl.toString(),
        'artifactSha256': artifactSha256,
        'artifactSize': artifactSize,
        'signatureAlgorithm': signatureAlgorithm,
        'keyId': keyId,
        if (includeSignature) 'signature': signature,
      };

  Uint8List get signedPayload => Uint8List.fromList(
        utf8.encode(_canonicalJson(toJson(includeSignature: false))),
      );

  static String _boundedString(Object? value, int max) {
    if (value is! String ||
        value.isEmpty ||
        value.length > max ||
        value.trim() != value) {
      throw const FormatException('Update metadata string is invalid.');
    }
    return value;
  }

  static final _targetId = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]{1,127}$');
  static final _semanticVersion = RegExp(
    r'^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$',
  );
  static final _sha256 = RegExp(r'^[a-f0-9]{64}$');
}

final class UpdateCheck {
  const UpdateCheck({
    required this.metadata,
    required this.sourceIdentity,
    required this.currentVersion,
    this.currentTrustDigest,
    this.appliedRevision = 0,
  });

  final SignedUpdateMetadata metadata;
  final String sourceIdentity;
  final String currentVersion;
  final String? currentTrustDigest;
  final int appliedRevision;
}

String canonicalUpdateJson(Object? value) => _canonicalJson(value);

int compareSemanticVersions(String left, String right) {
  List<Object?> parse(String value) {
    final separator = value.indexOf('-');
    final coreSource = separator < 0 ? value : value.substring(0, separator);
    final prerelease = separator < 0 ? null : value.substring(separator + 1);
    final core = coreSource.split('.').map(int.parse).toList(growable: false);
    return <Object?>[...core, prerelease];
  }

  final a = parse(left);
  final b = parse(right);
  for (var index = 0; index < 3; index += 1) {
    final compared = (a[index] as int).compareTo(b[index] as int);
    if (compared != 0) return compared;
  }
  final aPre = a[3] as String?;
  final bPre = b[3] as String?;
  if (aPre == null && bPre == null) return 0;
  if (aPre == null) return 1;
  if (bPre == null) return -1;
  final aParts = aPre.split('.');
  final bParts = bPre.split('.');
  final sharedLength =
      aParts.length < bParts.length ? aParts.length : bParts.length;
  for (var index = 0; index < sharedLength; index += 1) {
    final aNumber = int.tryParse(aParts[index]);
    final bNumber = int.tryParse(bParts[index]);
    if (aNumber != null && bNumber != null) {
      final compared = aNumber.compareTo(bNumber);
      if (compared != 0) return compared;
    } else if (aNumber != null) {
      return -1;
    } else if (bNumber != null) {
      return 1;
    } else {
      final compared = aParts[index].compareTo(bParts[index]);
      if (compared != 0) return compared;
    }
  }
  return aParts.length.compareTo(bParts.length);
}

String _canonicalJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return '{${keys.map((key) => '${jsonEncode(key)}:${_canonicalJson(value[key])}').join(',')}}';
  }
  if (value is List) {
    return '[${value.map(_canonicalJson).join(',')}]';
  }
  return jsonEncode(value);
}
