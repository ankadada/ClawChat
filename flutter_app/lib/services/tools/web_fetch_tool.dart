import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../../models/chat_models.dart';
import '../app_http.dart';
import 'tool_registry.dart';
import 'tool_result_formatter.dart';

class WebFetchTool extends Tool {
  WebFetchTool({
    AppWebFetchClient? client,
    Future<void> Function(Uri uri)? validateUrl,
    bool upgradeInsecureUrls = true,
    @visibleForTesting Duration operationTimeout = _timeout,
    @visibleForTesting AppResolverLimiter? resolverLimiter,
  })  : _client = client,
        _validateUrl = validateUrl ?? _validatePublicUrl,
        _upgradeInsecureUrls = upgradeInsecureUrls,
        _operationTimeout = operationTimeout,
        _resolverLimiter = resolverLimiter ?? AppResolverLimiter.shared;

  final AppWebFetchClient? _client;
  final Future<void> Function(Uri uri) _validateUrl;
  final bool _upgradeInsecureUrls;
  final Duration _operationTimeout;
  final AppResolverLimiter _resolverLimiter;

  @override
  String get name => 'web_fetch';

  @override
  String get description =>
      'Fetch content from a URL. Returns the response body as text. '
      'Useful for reading web pages, APIs, documentation, etc. '
      'Automatically upgrades HTTP to HTTPS. '
      'Blocks access to private/internal IPs (SSRF protection).';

  @override
  Map<String, dynamic> get inputSchema => {
        'type': 'object',
        'properties': {
          'url': {
            'type': 'string',
            'description':
                'The URL to fetch (will be upgraded to HTTPS if HTTP)',
          },
          'method': {
            'type': 'string',
            'enum': ['GET', 'POST'],
            'description': 'HTTP method (default: GET)',
          },
          'headers': {
            'type': 'object',
            'description': 'Optional HTTP headers',
          },
          'body': {
            'type': 'string',
            'description': 'Request body (for POST requests)',
          },
        },
        'required': ['url'],
      };

  static const _timeout = Duration(seconds: 30);
  static const _maxRedirectRequests = 5;
  static const _crossOriginHeaderAllowlist = <String>{
    'accept',
    'accept-language',
    'cache-control',
    'if-match',
    'if-modified-since',
    'if-none-match',
    'if-unmodified-since',
    'pragma',
    'range',
  };
  static const _hopByHopOrAuthorityHeaders = <String>{
    'connection',
    'host',
    'keep-alive',
    'proxy-authenticate',
    'proxy-authorization',
    'te',
    'trailer',
    'transfer-encoding',
    'upgrade',
  };
  static const _bodyHeaders = <String>{
    'content-encoding',
    'content-language',
    'content-length',
    'content-location',
    'content-type',
    'digest',
  };
  static const _credentialHeaders = <String>{
    'authorization',
    'cookie',
    'cookie2',
    'origin',
    'proxy-authorization',
    'x-api-key',
  };

  AppWebFetchClient get _pinnedClient =>
      _client ?? AppHttpClientRegistry.instance.webFetchClient;

  static bool _isPublicIp(InternetAddress addr) {
    if (addr.isLoopback || addr.isLinkLocal) return false;

    if (addr.type == InternetAddressType.IPv4) {
      return _isPublicIpv4Bytes(addr.rawAddress);
    }

    if (addr.type == InternetAddressType.IPv6) {
      final raw = addr.rawAddress;
      if (raw.length == 16) {
        if (raw.every((b) => b == 0)) return false; // unspecified ::
        if ((raw[0] & 0xfe) == 0xfc) return false; // unique local fc00::/7
        if (raw[0] == 0xfe && (raw[1] & 0xc0) == 0x80) {
          return false; // fe80::/10
        }
        if (raw[0] == 0xff) return false; // multicast ff00::/8
        if (raw[0] == 0x20 &&
            raw[1] == 0x01 &&
            raw[2] == 0x0d &&
            raw[3] == 0xb8) {
          return false; // documentation 2001:db8::/32
        }
        if (_isIpv4MappedIpv6(raw)) {
          return _isPublicIpv4Bytes(raw.sublist(12, 16));
        }
        return true;
      }
    }

    return false;
  }

  @override
  Future<String> execute(Map<String, dynamic> input) async {
    return _execute(
      input,
      allowedDomains: null,
      cancellationSignal: null,
    );
  }

  Future<String> executeWithAllowedDomains(
    Map<String, dynamic> input, {
    required Set<String> allowedDomains,
    ToolCancellationSignal? cancellationSignal,
  }) {
    return _execute(
      input,
      allowedDomains: allowedDomains,
      cancellationSignal: cancellationSignal,
    );
  }

  @override
  Future<ToolResultPayload> executeResultWithOperationAndCancellation(
    Map<String, dynamic> input, {
    String? sessionId,
    required String operationId,
    required ToolCancellationSignal cancellationSignal,
  }) async {
    final output = await _execute(
      input,
      allowedDomains: null,
      cancellationSignal: cancellationSignal,
    );
    return ToolResultFormatter.format(
      toolName: name,
      input: input,
      output: output,
      isError: output.startsWith('Error'),
    );
  }

  Future<String> _execute(
    Map<String, dynamic> input, {
    required Set<String>? allowedDomains,
    required ToolCancellationSignal? cancellationSignal,
  }) async {
    cancellationSignal?.throwIfCancellationRequested();
    var url = input['url'] as String;
    final method = input['method'] as String? ?? 'GET';
    final headers = input['headers'] as Map<String, dynamic>?;
    final body = input['body'] as String?;

    if (_upgradeInsecureUrls && url.startsWith('http://')) {
      url = 'https://${url.substring(7)}';
    }

    final uri = Uri.tryParse(url);
    if (uri == null || !_isBasicHttpTarget(uri)) {
      return 'Error: Invalid or disallowed URL.';
    }

    final reqHeaders = _sanitizeInitialHeaders(
      headers?.map((k, v) => MapEntry(k, v.toString())) ?? <String, String>{},
      hasBody: method.toUpperCase() == 'POST' && body != null,
    );

    final client = _pinnedClient;
    final operation = _WebFetchOperation(
      timeout: _operationTimeout,
      cancellationSignal: cancellationSignal,
    );
    try {
      final response = await _sendWithRedirects(
        client,
        uri,
        method,
        reqHeaders,
        body,
        allowedDomains,
        cancellationSignal,
        operation,
      );

      final result = StringBuffer();
      result.writeln('Status: ${response.statusCode}');
      result.writeln(
        'Content-Type: ${response.headers['content-type'] ?? 'unknown'}',
      );
      result.writeln('---');

      var responseBody = response.body;
      if (responseBody.length > 50000) {
        responseBody =
            '${responseBody.substring(0, 50000)}\n\n[Response truncated]';
      }
      result.write(responseBody);

      return result.toString();
    } on ToolExecutionCancelledException {
      rethrow;
    } on _WebFetchPolicyException catch (e) {
      return 'Error: ${e.publicMessage}';
    } on SocketException {
      return 'Error: Request blocked by network or SSRF policy.';
    } on http.ClientException {
      return 'Error: Request failed.';
    } catch (_) {
      return 'Error: Request failed.';
    } finally {
      operation.dispose();
    }
  }

  Future<http.Response> _sendWithRedirects(
    AppWebFetchClient client,
    Uri initialUri,
    String initialMethod,
    Map<String, String> headers,
    String? initialBody,
    Set<String>? allowedDomains,
    ToolCancellationSignal? cancellationSignal,
    _WebFetchOperation operation,
  ) async {
    var currentUri = initialUri;
    var currentMethod = initialMethod.toUpperCase() == 'POST' ? 'POST' : 'GET';
    var currentBody = currentMethod == 'POST' ? initialBody : null;
    var currentHeaders = Map<String, String>.from(headers);
    var sideEffectsMayHaveStarted = false;
    final visited = <String>{};

    for (var requestCount = 0;
        requestCount < _maxRedirectRequests;
        requestCount++) {
      operation.throwIfAborted(
        sideEffectsPrevented: !sideEffectsMayHaveStarted,
      );
      await _validateHop(
        currentUri,
        allowedDomains,
        operation,
        sideEffectsPrevented: !sideEffectsMayHaveStarted,
      );
      final visitKey = _redirectVisitKey(currentUri);
      if (!visited.add(visitKey)) {
        throw const _WebFetchPolicyException(
          'Redirect loop blocked.',
        );
      }
      operation.throwIfAborted(
        sideEffectsPrevented: !sideEffectsMayHaveStarted,
      );

      final request = http.AbortableRequest(
        currentMethod,
        currentUri,
        abortTrigger: operation.whenAborted,
      )
        ..headers.addAll(currentHeaders)
        ..followRedirects = false;
      if (currentBody != null) {
        request.body = currentBody;
      }

      late final http.Response response;
      try {
        if (!_isIdempotentMethod(currentMethod)) {
          sideEffectsMayHaveStarted = true;
        }
        response = await http.Response.fromStream(
          await client.sendWithDeadline(
            request,
            remainingTimeout: operation.remaining,
          ),
        );
        if (cancellationSignal?.isCancellationRequested == true) {
          throw ToolExecutionCancelledException(
            sideEffectsPrevented: !sideEffectsMayHaveStarted,
          );
        }
      } catch (_) {
        if (cancellationSignal?.isCancellationRequested == true) {
          throw ToolExecutionCancelledException(
            sideEffectsPrevented: !sideEffectsMayHaveStarted,
          );
        }
        rethrow;
      }

      if (!_isRedirect(response.statusCode)) return response;

      final location = response.headers['location'];
      if (location == null || location.isEmpty) return response;

      final nextUri = currentUri.resolve(location);
      if (!_isBasicHttpTarget(nextUri)) {
        throw const _WebFetchPolicyException(
          'Redirect target is invalid or disallowed.',
        );
      }
      if (currentUri.scheme == 'https' && nextUri.scheme == 'http') {
        throw const _WebFetchPolicyException(
          'HTTPS downgrade redirect blocked.',
        );
      }
      _ensureDomainAllowed(nextUri, allowedDomains);

      final crossesOrigin =
          _normalizedOrigin(currentUri) != _normalizedOrigin(nextUri);
      final preservesMethod =
          response.statusCode == 307 || response.statusCode == 308;
      if (crossesOrigin &&
          preservesMethod &&
          (!_isIdempotentMethod(currentMethod) ||
              currentBody != null ||
              _containsCredentialHeaders(currentHeaders))) {
        throw const _WebFetchPolicyException(
          'Unsafe cross-origin redirect blocked.',
        );
      }

      if ((response.statusCode == 301 ||
              response.statusCode == 302 ||
              response.statusCode == 303) &&
          currentMethod != 'GET') {
        currentMethod = 'GET';
        currentBody = null;
        currentHeaders = _withoutHeaders(currentHeaders, _bodyHeaders);
      }
      if (crossesOrigin) {
        currentHeaders = _headersSafeAcrossOrigins(currentHeaders);
      }
      if (currentBody == null) {
        currentHeaders = _withoutHeaders(currentHeaders, _bodyHeaders);
      }
      currentUri = nextUri;
    }

    throw const _WebFetchPolicyException('Redirect limit exceeded.');
  }

  static bool _isRedirect(int statusCode) =>
      statusCode == 301 ||
      statusCode == 302 ||
      statusCode == 303 ||
      statusCode == 307 ||
      statusCode == 308;

  static bool _domainAllowed(String domain, Set<String> scopes) {
    final normalized = domain.toLowerCase();
    return scopes.any((scope) {
      final allowed = scope.toLowerCase();
      if (allowed.startsWith('*.')) {
        final suffix = allowed.substring(1);
        return normalized.endsWith(suffix) && normalized != suffix.substring(1);
      }
      return normalized == allowed;
    });
  }

  Future<void> _validateHop(
    Uri uri,
    Set<String>? allowedDomains,
    _WebFetchOperation operation, {
    required bool sideEffectsPrevented,
  }) async {
    if (!_isBasicHttpTarget(uri)) {
      throw const _WebFetchPolicyException(
        'Request target is invalid or disallowed.',
      );
    }
    _ensureDomainAllowed(uri, allowedDomains);
    await _resolverLimiter.run(
      () => _validateUrl(uri),
      abortError: operation.abortError(
        sideEffectsPrevented: sideEffectsPrevented,
      ),
    );
  }

  static void _ensureDomainAllowed(
    Uri uri,
    Set<String>? allowedDomains,
  ) {
    if (allowedDomains != null && !_domainAllowed(uri.host, allowedDomains)) {
      throw const _WebFetchPolicyException(
        'Redirect target denied by the declared-domain policy.',
      );
    }
  }

  static bool _isBasicHttpTarget(Uri uri) =>
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty;

  static String _normalizedOrigin(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    final port = uri.hasPort
        ? uri.port
        : switch (scheme) {
            'http' => 80,
            'https' => 443,
            _ => -1,
          };
    return '$scheme://${uri.host.toLowerCase()}:$port';
  }

  static String _redirectVisitKey(Uri uri) {
    final pathAndQuery = uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
    return '${_normalizedOrigin(uri)}$pathAndQuery';
  }

  static bool _isIdempotentMethod(String method) =>
      method == 'GET' || method == 'HEAD';

  static Map<String, String> _sanitizeInitialHeaders(
    Map<String, String> headers, {
    required bool hasBody,
  }) {
    var sanitized = _withoutHeaders(headers, _hopByHopOrAuthorityHeaders);
    if (!hasBody) sanitized = _withoutHeaders(sanitized, _bodyHeaders);
    return sanitized;
  }

  static Map<String, String> _headersSafeAcrossOrigins(
    Map<String, String> headers,
  ) {
    return Map<String, String>.fromEntries(headers.entries.where(
      (entry) => _crossOriginHeaderAllowlist.contains(entry.key.toLowerCase()),
    ));
  }

  static Map<String, String> _withoutHeaders(
    Map<String, String> headers,
    Set<String> blockedNames,
  ) {
    return Map<String, String>.fromEntries(headers.entries.where(
      (entry) => !blockedNames.contains(entry.key.toLowerCase()),
    ));
  }

  static bool _containsCredentialHeaders(Map<String, String> headers) {
    return headers.keys.any((name) {
      final normalized = name.toLowerCase();
      if (_credentialHeaders.contains(normalized)) return true;
      return normalized.contains('auth') ||
          normalized.contains('cookie') ||
          normalized.contains('credential') ||
          normalized.contains('secret') ||
          normalized.contains('signature') ||
          normalized.contains('token') ||
          normalized.endsWith('-key') ||
          normalized.endsWith('_key');
    });
  }

  static Future<void> _validatePublicUrl(Uri uri) async {
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw const SocketException('Only HTTP and HTTPS URLs are allowed');
    }
    if (uri.host.isEmpty || _isInternalHostname(uri.host)) {
      throw SocketException(
        'Blocked connection to private/internal host ${uri.host} (SSRF protection)',
      );
    }

    final addresses = await InternetAddress.lookup(uri.host);
    if (addresses.isEmpty) {
      throw SocketException('Could not resolve host: ${uri.host}');
    }
    for (final addr in addresses) {
      if (!_isPublicIp(addr)) {
        throw SocketException(
          'Blocked connection to non-public IP ${addr.address} (SSRF protection)',
        );
      }
    }
  }

  static bool _isInternalHostname(String host) {
    final lowerHost = host.toLowerCase();
    if (lowerHost == 'localhost' ||
        lowerHost.endsWith('.local') ||
        lowerHost.endsWith('.internal') ||
        lowerHost == 'metadata.google.internal' ||
        lowerHost == '169.254.169.254') {
      return true;
    }

    return false;
  }

  static bool _isPublicIpv4Bytes(List<int> bytes) {
    if (bytes.length != 4) return false;

    final a = bytes[0];
    final b = bytes[1];
    final c = bytes[2];

    if (a == 0) return false; // 0.0.0.0/8
    if (a == 10) return false; // RFC1918 10/8
    if (a == 100 && b >= 64 && b <= 127) return false; // CGNAT 100.64/10
    if (a == 127) return false; // loopback
    if (a == 169 && b == 254) return false; // link-local
    if (a == 172 && b >= 16 && b <= 31) return false; // RFC1918 172.16/12
    if (a == 192 && b == 0 && c == 0) return false; // IETF protocol assignments
    if (a == 192 && b == 0 && c == 2) return false; // documentation
    if (a == 192 && b == 168) return false; // RFC1918 192.168/16
    if (a == 198 && (b == 18 || b == 19)) return false; // benchmarking
    if (a == 198 && b == 51 && c == 100) return false; // documentation
    if (a == 203 && b == 0 && c == 113) return false; // documentation
    if (a >= 224) return false; // multicast, reserved, broadcast

    return true;
  }

  static bool _isIpv4MappedIpv6(List<int> raw) {
    if (raw.length != 16) return false;
    for (var i = 0; i < 10; i++) {
      if (raw[i] != 0) return false;
    }
    return raw[10] == 0xff && raw[11] == 0xff;
  }
}

final class _WebFetchPolicyException implements Exception {
  const _WebFetchPolicyException(this.publicMessage);

  final String publicMessage;
}

final class _WebFetchOperation {
  _WebFetchOperation({
    required Duration timeout,
    required ToolCancellationSignal? cancellationSignal,
  })  : _timeout = timeout,
        _cancellationSignal = cancellationSignal,
        _clock = Stopwatch()..start() {
    _timer = Timer(timeout, () {
      _timedOut = true;
      _completeAbort();
    });
    if (cancellationSignal != null) {
      final abort = _abort;
      unawaited(cancellationSignal.whenCancelled.then((_) {
        if (!abort.isCompleted) abort.complete();
      }));
    }
  }

  final Duration _timeout;
  final ToolCancellationSignal? _cancellationSignal;
  final Stopwatch _clock;
  final Completer<void> _abort = Completer<void>();
  late final Timer _timer;
  bool _timedOut = false;

  Future<void> get whenAborted => _abort.future;

  Duration get remaining {
    final value = _timeout - _clock.elapsed;
    return value.isNegative ? Duration.zero : value;
  }

  Future<Object> abortError({required bool sideEffectsPrevented}) {
    return whenAborted.then<Object>((_) {
      if (_cancellationSignal?.isCancellationRequested == true) {
        return ToolExecutionCancelledException(
          sideEffectsPrevented: sideEffectsPrevented,
        );
      }
      return TimeoutException('WebFetch operation timed out', _timeout);
    });
  }

  void throwIfAborted({required bool sideEffectsPrevented}) {
    if (_cancellationSignal?.isCancellationRequested == true) {
      throw ToolExecutionCancelledException(
        sideEffectsPrevented: sideEffectsPrevented,
      );
    }
    if (_timedOut || remaining <= Duration.zero) {
      _timedOut = true;
      _completeAbort();
      throw TimeoutException('WebFetch operation timed out', _timeout);
    }
  }

  void _completeAbort() {
    if (!_abort.isCompleted) _abort.complete();
  }

  void dispose() {
    _timer.cancel();
    _clock.stop();
    _completeAbort();
  }
}
