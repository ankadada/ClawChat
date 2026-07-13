import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'chat_models.dart';

const remoteAgentDisclosureVersion = 1;

enum RemoteAgentConnectorKind {
  openClawGateway,

  /// Read-only migration input for the mistakenly shipped 2.5.0 connector.
  /// New configuration must never be saved with this kind.
  cozeOpenApi,
  genericOpenApi,
}

extension RemoteAgentConnectorKindWire on RemoteAgentConnectorKind {
  String get wireName => switch (this) {
        RemoteAgentConnectorKind.openClawGateway => 'openclaw_gateway',
        RemoteAgentConnectorKind.cozeOpenApi => 'coze_openapi',
        RemoteAgentConnectorKind.genericOpenApi => 'generic_openapi',
      };

  static RemoteAgentConnectorKind parse(Object? value) => switch (value) {
        'openclaw_gateway' => RemoteAgentConnectorKind.openClawGateway,
        'coze_openapi' => RemoteAgentConnectorKind.cozeOpenApi,
        'generic_openapi' => RemoteAgentConnectorKind.genericOpenApi,
        _ => throw const FormatException('Invalid remote connector kind'),
      };
}

/// Store-issued opaque handle. Raw credentials cannot satisfy this format.
final class RemoteAgentCredentialReference {
  RemoteAgentCredentialReference._(this.value);

  static final RegExp _format = RegExp(r'^cred_[A-Za-z0-9_-]{24,96}$');
  static final RegExp _secretWords = RegExp(
    r'(?:secret|token|bearer|password|api[_-]?key|sk[-_]?(?:proj)?)',
    caseSensitive: false,
  );

  final String value;

  factory RemoteAgentCredentialReference.parse(Object? raw) {
    if (raw is! String ||
        !_format.hasMatch(raw) ||
        _secretWords.hasMatch(raw)) {
      throw const FormatException('Invalid credential reference');
    }
    return RemoteAgentCredentialReference._(raw);
  }

  @override
  bool operator ==(Object other) =>
      other is RemoteAgentCredentialReference && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'RemoteAgentCredentialReference([opaque])';
}

/// Persistable connector metadata. Credentials are referenced, never stored.
final class RemoteAgentConnectorConfig {
  RemoteAgentConnectorConfig({
    required this.kind,
    required String id,
    required String displayName,
    required String baseUrl,
    required this.credentialReference,
    required String remoteAgentId,
    this.enabled = false,
  })  : id = _validatedIdentifier(id, 'id'),
        displayName = _validatedDisplayName(displayName),
        baseUrl = canonicalizeRemoteAgentEndpoint(baseUrl),
        remoteAgentId = _validatedIdentifier(remoteAgentId, 'remote agent id');

  static const _jsonKeys = {
    'kind',
    'id',
    'display_name',
    'base_url',
    'credential_reference',
    'remote_agent_id',
    'enabled',
  };

  final RemoteAgentConnectorKind kind;
  final String id;
  final String displayName;
  final String baseUrl;
  final RemoteAgentCredentialReference credentialReference;
  final String remoteAgentId;
  final bool enabled;

  Map<String, Object?> toJson() => {
        'kind': kind.wireName,
        'id': id,
        'display_name': displayName,
        'base_url': baseUrl,
        'credential_reference': credentialReference.value,
        'remote_agent_id': remoteAgentId,
        'enabled': enabled,
      };

  factory RemoteAgentConnectorConfig.fromJson(Map<String, Object?> json) {
    _requireExactKeys(json, _jsonKeys, 'remote connector config');
    if (json['id'] is! String ||
        json['display_name'] is! String ||
        json['base_url'] is! String ||
        json['remote_agent_id'] is! String ||
        json['enabled'] is! bool) {
      throw const FormatException('Invalid remote connector config');
    }
    return RemoteAgentConnectorConfig(
      kind: RemoteAgentConnectorKindWire.parse(json['kind']),
      id: json['id']! as String,
      displayName: json['display_name']! as String,
      baseUrl: json['base_url']! as String,
      credentialReference:
          RemoteAgentCredentialReference.parse(json['credential_reference']),
      remoteAgentId: json['remote_agent_id']! as String,
      enabled: json['enabled']! as bool,
    );
  }

  /// Metadata safe for diagnostics and support exports.
  Map<String, Object?> toDiagnosticJson() => {
        'connector_kind': kind.wireName,
        'enabled': enabled,
        'has_credential_reference': true,
      };
}

/// Persistable proof that the user accepted external processing disclosure.
final class RemoteAgentConsent {
  RemoteAgentConsent._({
    required this.connectorId,
    required this.configurationBinding,
    required this.disclosureVersion,
    required this.acceptedAt,
    required this.accepted,
  });

  static const _jsonKeys = {
    'connector_id',
    'configuration_binding',
    'disclosure_version',
    'accepted_at',
    'accepted',
  };
  static final RegExp _digest = RegExp(r'^[a-f0-9]{64}$');

  final String connectorId;
  final String configurationBinding;
  final int disclosureVersion;
  final DateTime acceptedAt;
  final bool accepted;

  factory RemoteAgentConsent.grant(
    RemoteAgentConnectorConfig config, {
    required DateTime acceptedAt,
  }) {
    return RemoteAgentConsent._(
      connectorId: config.id,
      configurationBinding: bindingFor(config),
      disclosureVersion: remoteAgentDisclosureVersion,
      acceptedAt: acceptedAt.toUtc(),
      accepted: true,
    );
  }

  bool allows(RemoteAgentConnectorConfig config) =>
      accepted &&
      config.enabled &&
      connectorId == config.id &&
      disclosureVersion == remoteAgentDisclosureVersion &&
      configurationBinding == bindingFor(config);

  static String bindingFor(
    RemoteAgentConnectorConfig config, {
    int disclosureVersion = remoteAgentDisclosureVersion,
  }) {
    final canonical = jsonEncode({
      'base_url': config.baseUrl,
      'connector_id': config.id,
      'connector_kind': config.kind.wireName,
      'credential_reference': config.credentialReference.value,
      'disclosure_version': disclosureVersion,
      'remote_agent_id': config.remoteAgentId,
    });
    return sha256.convert(utf8.encode(canonical)).toString();
  }

  Map<String, Object?> toJson() => {
        'connector_id': connectorId,
        'configuration_binding': configurationBinding,
        'disclosure_version': disclosureVersion,
        'accepted_at': acceptedAt.toUtc().toIso8601String(),
        'accepted': accepted,
      };

  factory RemoteAgentConsent.fromJson(Map<String, Object?> json) {
    _requireExactKeys(json, _jsonKeys, 'remote connector consent');
    final connectorId = json['connector_id'];
    final binding = json['configuration_binding'];
    final version = json['disclosure_version'];
    final acceptedAtRaw = json['accepted_at'];
    final accepted = json['accepted'];
    final acceptedAt = acceptedAtRaw is String
        ? DateTime.tryParse(acceptedAtRaw)?.toUtc()
        : null;
    if (connectorId is! String ||
        _validatedIdentifierOrNull(connectorId) == null ||
        binding is! String ||
        !_digest.hasMatch(binding) ||
        version != remoteAgentDisclosureVersion ||
        acceptedAt == null ||
        acceptedAtRaw != acceptedAt.toIso8601String() ||
        accepted is! bool) {
      throw const FormatException('Invalid remote connector consent');
    }
    return RemoteAgentConsent._(
      connectorId: connectorId,
      configurationBinding: binding,
      disclosureVersion: remoteAgentDisclosureVersion,
      acceptedAt: acceptedAt,
      accepted: accepted,
    );
  }
}

abstract interface class RemoteAgentConsentStore {
  Future<RemoteAgentConsent?> read(String connectorId);
  Future<void> write(RemoteAgentConsent consent);
  Future<void> remove(String connectorId);
}

abstract interface class RemoteAgentCredentialResolver {
  /// Returns an ephemeral credential. Implementations must not log or persist it.
  Future<String?> resolve(RemoteAgentCredentialReference reference);
}

final class RemoteAgentMessage {
  RemoteAgentMessage({required String role, required String text})
      : role = _validatedRole(role),
        text = _validatedMessage(text);

  final String role;
  final String text;

  Map<String, String> toWireJson() => {'role': role, 'content': text};
}

/// In-memory request. It intentionally has no JSON/export method.
final class RemoteAgentRequest {
  RemoteAgentRequest({
    required String localSessionId,
    required List<RemoteAgentMessage> messages,
  })  : localSessionId = _validatedIdentifier(localSessionId, 'session id'),
        messages = List.unmodifiable(messages) {
    if (messages.isEmpty) {
      throw const FormatException('Remote agent messages are required');
    }
  }

  final String localSessionId;
  final List<RemoteAgentMessage> messages;
}

sealed class RemoteAgentEvent {
  const RemoteAgentEvent();
}

/// The only commit-eligible event; emitted after terminal validation succeeds.
final class RemoteAgentComplete extends RemoteAgentEvent {
  const RemoteAgentComplete({required this.text});
  final String text;
}

enum RemoteAgentErrorCode {
  consentRequired,
  invalidConfiguration,
  credentialUnavailable,
  cancelled,
  deadlineExceeded,
  redirectBlocked,
  responseTooLarge,
  unsupportedResponse,
  unsafeOutput,
  providerRejected,
  transportFailure,
}

final class RemoteAgentFailure implements Exception {
  const RemoteAgentFailure(this.code, {this.retryable = false});

  final RemoteAgentErrorCode code;
  final bool retryable;

  String get publicMessage => switch (code) {
        RemoteAgentErrorCode.consentRequired =>
          'External processing consent is required.',
        RemoteAgentErrorCode.invalidConfiguration =>
          'Remote connector configuration is invalid.',
        RemoteAgentErrorCode.credentialUnavailable =>
          'Remote connector credential is unavailable.',
        RemoteAgentErrorCode.cancelled => 'Remote request was cancelled.',
        RemoteAgentErrorCode.deadlineExceeded => 'Remote request timed out.',
        RemoteAgentErrorCode.redirectBlocked =>
          'Remote redirect was blocked by policy.',
        RemoteAgentErrorCode.responseTooLarge =>
          'Remote response exceeded the safety limit.',
        RemoteAgentErrorCode.unsupportedResponse =>
          'Remote response format is unsupported.',
        RemoteAgentErrorCode.unsafeOutput =>
          'Remote output failed privacy validation.',
        RemoteAgentErrorCode.providerRejected =>
          'Remote provider rejected the request.',
        RemoteAgentErrorCode.transportFailure => 'Remote request failed.',
      };

  AssistantErrorMetadata toAssistantError() => AssistantErrorMetadata(
        message: publicMessage,
        code: 'remote_agent_${code.name}',
        canRetry: retryable,
        source: 'remote_agent',
      );

  Map<String, Object?> toDiagnosticJson() => {
        'source': 'remote_agent',
        'code': code.name,
        'retryable': retryable,
      };

  @override
  String toString() => 'RemoteAgentFailure(${code.name})';
}

String canonicalizeRemoteAgentEndpoint(String raw) {
  if (raw != raw.trim() || raw.length > 2048) {
    throw const FormatException('Invalid remote connector endpoint');
  }
  final parsed = Uri.tryParse(raw);
  if (parsed == null ||
      parsed.scheme.toLowerCase() != 'https' ||
      parsed.host.isEmpty ||
      parsed.host.length > 253 ||
      parsed.userInfo.isNotEmpty ||
      parsed.query.isNotEmpty ||
      parsed.fragment.isNotEmpty) {
    throw const FormatException('Invalid remote connector endpoint');
  }
  final normalized = parsed.normalizePath();
  final rawPath = normalized.path.isEmpty || normalized.path == '/'
      ? ''
      : normalized.path.replaceFirst(RegExp(r'/+$'), '');
  final path = rawPath.endsWith('/v1/chat/completions')
      ? rawPath
      : rawPath.endsWith('/v1')
          ? '$rawPath/chat/completions'
          : '$rawPath/v1/chat/completions';
  if (path.length > 1024) {
    throw const FormatException('Invalid remote connector endpoint');
  }
  return Uri(
    scheme: 'https',
    host: normalized.host.toLowerCase(),
    port: normalized.hasPort && normalized.port != 443 ? normalized.port : null,
    path: path,
  ).toString();
}

void _requireExactKeys(
  Map<String, Object?> json,
  Set<String> expected,
  String label,
) {
  if (json.length != expected.length ||
      !json.keys.toSet().containsAll(expected)) {
    throw FormatException('Invalid $label schema');
  }
}

String _validatedIdentifier(String value, String label) {
  final result = _validatedIdentifierOrNull(value);
  if (result == null) throw FormatException('Invalid remote connector $label');
  return result;
}

String? _validatedIdentifierOrNull(String value) {
  if (value != value.trim() ||
      value.length > 128 ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(value)) {
    return null;
  }
  return value;
}

String _validatedDisplayName(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty ||
      trimmed.length > 80 ||
      value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
    throw const FormatException('Invalid remote connector display name');
  }
  return trimmed;
}

String _validatedRole(String role) {
  if (!const {'system', 'user', 'assistant'}.contains(role)) {
    throw const FormatException('Invalid remote agent role');
  }
  return role;
}

String _validatedMessage(String text) {
  if (text.trim().isEmpty) {
    throw const FormatException('Invalid remote agent message');
  }
  return text;
}
