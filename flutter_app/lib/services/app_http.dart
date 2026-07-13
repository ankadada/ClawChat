import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../constants.dart';

/// Fixed product identity for app-owned Android native HTTP requests.
abstract final class AppUserAgent {
  static String forAndroidVersion(String semanticVersion) =>
      'ClawChat/$semanticVersion (Android)';
}

/// Immutable application metadata loaded once during app startup.
final class AppRuntimeInfo {
  const AppRuntimeInfo._({required this.version});

  final String version;

  String get userAgent => AppUserAgent.forAndroidVersion(version);

  static Future<AppRuntimeInfo> load() async {
    return fromPackageInfo(await PackageInfo.fromPlatform());
  }

  static AppRuntimeInfo fromPackageInfo(
    PackageInfo packageInfo, {
    bool? isAndroidForTesting,
  }) {
    final isAndroid = isAndroidForTesting ?? Platform.isAndroid;
    if (!isAndroid) {
      throw UnsupportedError(
        'ClawChat native HTTP transport is supported only on Android',
      );
    }

    final version = packageInfo.version.trim();
    if (!_semanticVersion.hasMatch(version)) {
      throw const FormatException('Invalid application semantic version');
    }
    return AppRuntimeInfo._(version: version);
  }

  static AppRuntimeInfo forTesting({
    String version = AppConstants.version,
    bool isAndroid = true,
  }) {
    return fromPackageInfo(
      PackageInfo(
        appName: 'ClawChat',
        packageName: AppConstants.packageName,
        version: version,
        buildNumber: 'test-build-number-must-not-appear',
      ),
      isAndroidForTesting: isAndroid,
    );
  }

  static final RegExp _semanticVersion = RegExp(
    r'^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$',
  );
}

/// Removes any caller-supplied User-Agent spelling and appends the fixed value.
abstract final class AppHttpHeaders {
  static void enforceUserAgent(
    Map<String, String> headers,
    String userAgent,
  ) {
    headers.removeWhere(
      (name, _) => name.toLowerCase() == HttpHeaders.userAgentHeader,
    );
    headers[HttpHeaders.userAgentHeader] = userAgent;
  }
}

/// Installs a defense-in-depth default for raw native Dart HTTP clients.
///
/// A pre-existing override is retained as the client factory delegate. Calling
/// it directly avoids recursively consulting [HttpOverrides.current].
final class AppHttpOverrides extends HttpOverrides {
  AppHttpOverrides._(this._userAgent, this._delegate);

  final String _userAgent;
  final HttpOverrides? _delegate;

  static AppHttpOverrideInstallation install(AppRuntimeInfo runtimeInfo) {
    final previous = HttpOverrides.current;
    final override = AppHttpOverrides._(runtimeInfo.userAgent, previous);
    HttpOverrides.global = override;
    return AppHttpOverrideInstallation._(override, previous);
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client =
        _delegate?.createHttpClient(context) ?? super.createHttpClient(context);
    client.userAgent = _userAgent;
    return client;
  }
}

/// Restore token used by tests that temporarily install the global override.
final class AppHttpOverrideInstallation {
  AppHttpOverrideInstallation._(this._installed, this._previous);

  final HttpOverrides _installed;
  final HttpOverrides? _previous;
  bool _restored = false;

  void restore() {
    if (_restored) return;
    _restored = true;
    if (identical(HttpOverrides.current, _installed)) {
      HttpOverrides.global = _previous;
    }
  }
}

typedef AppNativeHttpClientFactory = HttpClient Function();

/// The single app-scoped HTTP client and connection pool.
///
/// Every request passes through [send], which makes the fixed product UA the
/// final header value after all caller header merges. Only the root registry
/// closes this client; services cancel individual abortable requests instead.
final class AppHttpClient extends http.BaseClient {
  AppHttpClient(
    AppRuntimeInfo runtimeInfo, {
    AppNativeHttpClientFactory? createNativeClient,
  }) : this._(
          runtimeInfo,
          (createNativeClient ?? HttpClient.new)(),
        );

  AppHttpClient._(this.runtimeInfo, HttpClient nativeClient)
      : _nativeClient = nativeClient,
        _inner = IOClient(nativeClient) {
    _configureNativeClient();
  }

  final AppRuntimeInfo runtimeInfo;
  final HttpClient _nativeClient;
  final IOClient _inner;
  bool _closed = false;

  String get userAgent => runtimeInfo.userAgent;
  bool get isClosed => _closed;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (_closed) {
      throw StateError('AppHttpClient is closed');
    }
    AppHttpHeaders.enforceUserAgent(request.headers, userAgent);
    return _inner.send(request);
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _inner.close();
  }

  void _configureNativeClient() {
    _nativeClient.idleTimeout = const Duration(seconds: 120);
    _nativeClient.badCertificateCallback =
        (X509Certificate certificate, String host, int port) => false;
    _nativeClient.userAgent = runtimeInfo.userAgent;
  }
}

typedef AppHostResolver = Future<List<InternetAddress>> Function(String host);
typedef AppSocketConnector = Future<ConnectionTask<Socket>> Function(
  InternetAddress address,
  int port,
);

/// Bounds DNS/policy resolver work that cannot be cancelled by the platform.
///
/// Callers detach promptly when [abortError] completes, while the underlying
/// resolver retains only its limiter lease until it eventually settles. This
/// prevents repeated cancelled lookups from creating unbounded native DNS
/// work. Late results are consumed and cannot resume the cancelled caller.
final class AppResolverLimiter {
  AppResolverLimiter({this.maxConcurrent = 4}) {
    if (maxConcurrent < 1) {
      throw ArgumentError.value(maxConcurrent, 'maxConcurrent');
    }
  }

  static final shared = AppResolverLimiter();

  final int maxConcurrent;
  final Queue<_AppResolverWaiter> _waiters = Queue<_AppResolverWaiter>();
  int _active = 0;

  @visibleForTesting
  int get activeCount => _active;

  @visibleForTesting
  int get pendingCount => _waiters.where((waiter) => !waiter.cancelled).length;

  Future<T> run<T>(
    Future<T> Function() operation, {
    required Future<Object> abortError,
  }) async {
    final lease = await _acquire(abortError);
    late final Future<T> work;
    try {
      work = Future<T>.sync(operation);
    } catch (_) {
      lease.release();
      rethrow;
    }

    work.then<void>(
      (_) => lease.release(),
      onError: (Object _, StackTrace __) => lease.release(),
    );

    final outcome = await Future.any<_AppResolverOutcome<T>>([
      work.then<_AppResolverOutcome<T>>(
        _AppResolverOutcome<T>.value,
        onError: (Object error, StackTrace stackTrace) =>
            _AppResolverOutcome<T>.error(error, stackTrace),
      ),
      abortError.then<_AppResolverOutcome<T>>(
        _AppResolverOutcome<T>.aborted,
      ),
    ]);
    return outcome.unwrap();
  }

  Future<_AppResolverLease> _acquire(Future<Object> abortError) async {
    if (_active < maxConcurrent) {
      _active += 1;
      return _AppResolverLease(_release);
    }

    final waiter = _AppResolverWaiter();
    _waiters.add(waiter);
    final outcome = await Future.any<_AppResolverAcquireOutcome>([
      waiter.ready.future.then(_AppResolverAcquireOutcome.acquired),
      abortError.then(_AppResolverAcquireOutcome.aborted),
    ]);
    if (outcome.error case final error?) {
      waiter.cancelled = true;
      _waiters.remove(waiter);
      waiter.grantedLease?.release();
      Error.throwWithStackTrace(error, StackTrace.current);
    }
    return outcome.lease!;
  }

  void _release() {
    if (_active == 0) return;
    _active -= 1;
    while (_waiters.isNotEmpty) {
      final waiter = _waiters.removeFirst();
      if (waiter.cancelled) continue;
      _active += 1;
      final lease = _AppResolverLease(_release);
      waiter.grantedLease = lease;
      waiter.ready.complete(lease);
      break;
    }
  }
}

final class _AppResolverLease {
  _AppResolverLease(this._onRelease);

  final void Function() _onRelease;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _onRelease();
  }
}

final class _AppResolverWaiter {
  final ready = Completer<_AppResolverLease>();
  bool cancelled = false;
  _AppResolverLease? grantedLease;
}

final class _AppResolverAcquireOutcome {
  const _AppResolverAcquireOutcome._({this.lease, this.error});

  factory _AppResolverAcquireOutcome.acquired(_AppResolverLease lease) =>
      _AppResolverAcquireOutcome._(lease: lease);

  factory _AppResolverAcquireOutcome.aborted(Object error) =>
      _AppResolverAcquireOutcome._(error: error);

  final _AppResolverLease? lease;
  final Object? error;
}

final class _AppResolverOutcome<T> {
  const _AppResolverOutcome._({
    this.value,
    this.error,
    this.stackTrace,
    this.hasValue = false,
  });

  factory _AppResolverOutcome.value(T value) =>
      _AppResolverOutcome._(value: value, hasValue: true);

  factory _AppResolverOutcome.error(Object error, StackTrace stackTrace) =>
      _AppResolverOutcome._(error: error, stackTrace: stackTrace);

  factory _AppResolverOutcome.aborted(Object error) =>
      _AppResolverOutcome._(error: error, stackTrace: StackTrace.current);

  final T? value;
  final Object? error;
  final StackTrace? stackTrace;
  final bool hasValue;

  T unwrap() {
    if (hasValue) return value as T;
    Error.throwWithStackTrace(error!, stackTrace!);
  }
}

/// Security-specialized WebFetch transport owned by the app HTTP registry.
///
/// It deliberately does not share the general app connection pool. Each hop
/// resolves and validates its target into request-local state, then uses a
/// fresh native client connected directly to that validated address. HTTPS
/// upgrades that pinned TCP socket with the original hostname so platform
/// trust, SNI, and certificate hostname verification remain intact. This
/// prevents an idle same-authority connection or a previous DNS resolution
/// from bypassing WebFetch SSRF policy.
final class AppWebFetchClient extends http.BaseClient {
  AppWebFetchClient(
    AppRuntimeInfo runtimeInfo, {
    AppNativeHttpClientFactory? createNativeClient,
    AppHostResolver? resolveHost,
    AppSocketConnector? connectSocket,
    @visibleForTesting AppResolverLimiter? resolverLimiter,
    Duration connectionTimeout = const Duration(seconds: 30),
  }) : this._(
          runtimeInfo,
          createNativeClient: createNativeClient,
          resolveHost: resolveHost,
          connectSocket: connectSocket,
          resolverLimiter: resolverLimiter,
          connectionTimeout: connectionTimeout,
        );

  @visibleForTesting
  factory AppWebFetchClient.forTesting(
    AppRuntimeInfo runtimeInfo, {
    required SecurityContext tlsSecurityContext,
    AppNativeHttpClientFactory? createNativeClient,
    AppHostResolver? resolveHost,
    AppSocketConnector? connectSocket,
    AppResolverLimiter? resolverLimiter,
    Duration connectionTimeout = const Duration(seconds: 30),
  }) {
    return AppWebFetchClient._(
      runtimeInfo,
      createNativeClient: createNativeClient,
      resolveHost: resolveHost,
      connectSocket: connectSocket,
      resolverLimiter: resolverLimiter,
      tlsSecurityContext: tlsSecurityContext,
      connectionTimeout: connectionTimeout,
    );
  }

  AppWebFetchClient._(
    this.runtimeInfo, {
    AppNativeHttpClientFactory? createNativeClient,
    AppHostResolver? resolveHost,
    AppSocketConnector? connectSocket,
    AppResolverLimiter? resolverLimiter,
    SecurityContext? tlsSecurityContext,
    required Duration connectionTimeout,
  })  : _createNativeClient = createNativeClient ?? HttpClient.new,
        _resolveHost = resolveHost ?? InternetAddress.lookup,
        _connectSocket = connectSocket ??
            ((address, port) => Socket.startConnect(address, port)),
        _resolverLimiter = resolverLimiter ?? AppResolverLimiter.shared,
        _tlsSecurityContext = tlsSecurityContext,
        _connectionTimeout = connectionTimeout;

  final AppRuntimeInfo runtimeInfo;
  final AppNativeHttpClientFactory _createNativeClient;
  final AppHostResolver _resolveHost;
  final AppSocketConnector _connectSocket;
  final AppResolverLimiter _resolverLimiter;
  final SecurityContext? _tlsSecurityContext;
  final Duration _connectionTimeout;
  final Set<IOClient> _activeClients = <IOClient>{};
  final Set<Completer<Object>> _pendingResolverAborts = <Completer<Object>>{};
  bool _closed = false;

  String get userAgent => runtimeInfo.userAgent;
  bool get isClosed => _closed;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      sendWithDeadline(request, remainingTimeout: _connectionTimeout);

  /// Sends one already-policy-validated WebFetch hop within the caller's
  /// remaining logical operation budget.
  Future<http.StreamedResponse> sendWithDeadline(
    http.BaseRequest request, {
    required Duration remainingTimeout,
  }) =>
      _sendWithNetworkPolicy(
        request,
        remainingTimeout: remainingTimeout,
        allowUserAuthorizedPrivateNetwork: false,
      );

  /// Sends to the exact HTTPS authority the user configured as an OpenClaw
  /// Gateway. Unlike ordinary WebFetch, this permits RFC1918, CGNAT/Tailscale,
  /// and IPv6 ULA targets while retaining DNS pinning, TLS hostname checks,
  /// link-local/loopback rejection, and the caller's cancellation budget.
  Future<http.StreamedResponse> sendToUserAuthorizedGateway(
    http.BaseRequest request, {
    required Uri authorizedEndpoint,
    required Duration remainingTimeout,
  }) {
    if (authorizedEndpoint.scheme.toLowerCase() != 'https' ||
        !_sameAuthority(request.url, authorizedEndpoint)) {
      throw const SocketException(
        'Remote Gateway request does not match the authorized HTTPS target',
      );
    }
    return _sendWithNetworkPolicy(
      request,
      remainingTimeout: remainingTimeout,
      allowUserAuthorizedPrivateNetwork: true,
    );
  }

  Future<http.StreamedResponse> _sendWithNetworkPolicy(
    http.BaseRequest request, {
    required Duration remainingTimeout,
    required bool allowUserAuthorizedPrivateNetwork,
  }) async {
    if (_closed) throw StateError('AppWebFetchClient is closed');
    if (remainingTimeout <= Duration.zero) {
      throw http.RequestAbortedException(request.url);
    }
    final target = request.url;
    if ((target.scheme != 'http' && target.scheme != 'https') ||
        target.host.isEmpty) {
      throw const SocketException('Only HTTP and HTTPS URLs are allowed');
    }
    if (_isBlockedHostname(target.host)) {
      throw SocketException(
        'Blocked connection to private/internal host ${target.host} '
        '(SSRF protection)',
      );
    }

    final resolverTimeout = remainingTimeout < _connectionTimeout
        ? remainingTimeout
        : _connectionTimeout;
    final resolverAbort = Completer<Object>();

    void abortResolver(Object error) {
      if (!resolverAbort.isCompleted) resolverAbort.complete(error);
    }

    _pendingResolverAborts.add(resolverAbort);
    final timeoutTimer = Timer(resolverTimeout, () {
      abortResolver(const SocketException('DNS resolution timed out'));
    });
    if (request case http.Abortable(:final abortTrigger?)) {
      unawaited(abortTrigger.then((_) {
        abortResolver(http.RequestAbortedException());
      }));
    }

    late final List<InternetAddress> addresses;
    try {
      addresses = await _resolverLimiter.run(
        () => _resolveHost(target.host),
        abortError: resolverAbort.future,
      );
    } finally {
      timeoutTimer.cancel();
      _pendingResolverAborts.remove(resolverAbort);
      abortResolver(StateError('Resolver wait finished'));
    }
    if (_closed) throw StateError('AppWebFetchClient is closed');
    if (addresses.isEmpty) {
      throw SocketException('Could not resolve host: ${target.host}');
    }
    for (final address in addresses) {
      final allowed = allowUserAuthorizedPrivateNetwork
          ? _isAllowedExplicitGatewayIp(address)
          : _isPublicIp(address);
      if (!allowed) {
        throw SocketException(
          'Blocked connection to disallowed IP ${address.address} '
          '(SSRF protection)',
        );
      }
    }

    final selectedAddress = addresses.first;
    final nativeClient = _createNativeClient();
    nativeClient.userAgent = userAgent;
    nativeClient.idleTimeout = Duration.zero;
    nativeClient.connectionTimeout = _connectionTimeout;
    nativeClient.findProxy = (_) => 'DIRECT';
    nativeClient.badCertificateCallback =
        (X509Certificate certificate, String host, int port) => false;
    nativeClient.connectionFactory = (uri, proxyHost, proxyPort) async {
      if (!_sameAuthority(uri, target)) {
        throw SocketException(
          'Blocked unexpected connection target ${uri.host} '
          '(SSRF protection)',
        );
      }
      return _createPinnedConnectionTask(target, selectedAddress);
    };

    final inner = IOClient(nativeClient);
    _activeClients.add(inner);
    request
      ..followRedirects = false
      ..persistentConnection = false;
    request.headers.removeWhere(
      (name, _) => name.toLowerCase() == HttpHeaders.hostHeader,
    );
    AppHttpHeaders.enforceUserAgent(request.headers, userAgent);

    try {
      final response = await inner.send(request);
      return _responseWithOwnedStream(response, inner);
    } catch (_) {
      _release(inner);
      rethrow;
    }
  }

  Future<ConnectionTask<Socket>> _createPinnedConnectionTask(
    Uri target,
    InternetAddress selectedAddress,
  ) async {
    final tcpTask = await _connectSocket(selectedAddress, target.port);
    final result = Completer<Socket>();
    Socket? activeSocket;
    var cancelled = false;

    void cancel() {
      if (cancelled) return;
      cancelled = true;
      tcpTask.cancel();
      activeSocket?.destroy();
      if (!result.isCompleted) {
        result.completeError(
          const SocketException('Connection cancelled'),
        );
      }
    }

    unawaited(() async {
      try {
        final tcpSocket = await tcpTask.socket.timeout(
          _connectionTimeout,
          onTimeout: () {
            cancel();
            throw const SocketException('Connection timed out');
          },
        );
        activeSocket = tcpSocket;
        if (cancelled) {
          tcpSocket.destroy();
          return;
        }

        Socket connectedSocket = tcpSocket;
        if (target.scheme.toLowerCase() == 'https') {
          connectedSocket = await SecureSocket.secure(
            tcpSocket,
            host: target.host,
            context: _tlsSecurityContext,
            supportedProtocols: const ['http/1.1'],
          ).timeout(
            _connectionTimeout,
            onTimeout: () {
              cancel();
              throw const SocketException('TLS handshake timed out');
            },
          );
          activeSocket = connectedSocket;
        }

        if (cancelled) {
          connectedSocket.destroy();
          return;
        }
        if (!result.isCompleted) result.complete(connectedSocket);
      } catch (_) {
        activeSocket?.destroy();
        if (!result.isCompleted) {
          result.completeError(
            SocketException(
              target.scheme.toLowerCase() == 'https'
                  ? 'Secure connection failed'
                  : 'Connection failed',
            ),
          );
        }
      }
    }());

    return ConnectionTask.fromSocket<Socket>(result.future, cancel);
  }

  http.StreamedResponse _responseWithOwnedStream(
    http.StreamedResponse response,
    IOClient inner,
  ) {
    late final StreamController<List<int>> controller;
    StreamSubscription<List<int>>? subscription;
    controller = StreamController<List<int>>(
      sync: true,
      onListen: () {
        subscription = response.stream.listen(
          controller.add,
          onError: (Object error, StackTrace stackTrace) {
            controller.addError(error, stackTrace);
            unawaited(controller.close());
            _release(inner);
          },
          onDone: () {
            unawaited(controller.close());
            _release(inner);
          },
        );
      },
      onCancel: () => _cancelOwnedStream(
        () => subscription?.cancel() ?? Future<void>.value(),
        () => _release(inner),
      ),
    );

    return http.StreamedResponse(
      controller.stream,
      response.statusCode,
      contentLength: response.contentLength,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: false,
      reasonPhrase: response.reasonPhrase,
    );
  }

  void _release(IOClient inner) {
    if (_activeClients.remove(inner)) inner.close();
  }

  static Future<void> _cancelOwnedStream(
    Future<void> Function() cancel,
    void Function() release,
  ) async {
    try {
      await cancel().timeout(const Duration(milliseconds: 250));
    } catch (_) {
      // Upstream cancellation is best effort; ownership release is mandatory.
    } finally {
      release();
    }
  }

  @visibleForTesting
  static Future<void> cancelOwnedStreamForTesting(
    Future<void> Function() cancel,
    void Function() release,
  ) =>
      _cancelOwnedStream(cancel, release);

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    final pendingResolvers = _pendingResolverAborts.toList(growable: false);
    _pendingResolverAborts.clear();
    for (final abort in pendingResolvers) {
      if (!abort.isCompleted) {
        abort.complete(StateError('AppWebFetchClient is closed'));
      }
    }
    final active = _activeClients.toList(growable: false);
    _activeClients.clear();
    for (final client in active) {
      client.close();
    }
  }

  static bool _sameAuthority(Uri actual, Uri expected) =>
      actual.scheme.toLowerCase() == expected.scheme.toLowerCase() &&
      actual.host.toLowerCase() == expected.host.toLowerCase() &&
      actual.port == expected.port;

  static bool _isBlockedHostname(String host) {
    final normalized = host.toLowerCase();
    return normalized == 'localhost' ||
        normalized.endsWith('.local') ||
        normalized.endsWith('.internal') ||
        normalized == 'metadata.google.internal';
  }

  static bool _isPublicIp(InternetAddress address) {
    if (address.isLoopback || address.isLinkLocal) return false;
    final raw = address.rawAddress;
    if (address.type == InternetAddressType.IPv4 && raw.length == 4) {
      final a = raw[0];
      final b = raw[1];
      final c = raw[2];
      if (a == 0 || a == 10 || a == 127 || a >= 224) return false;
      if (a == 100 && b >= 64 && b <= 127) return false;
      if (a == 169 && b == 254) return false;
      if (a == 172 && b >= 16 && b <= 31) return false;
      if (a == 192 && b == 168) return false;
      if (a == 192 && b == 0 && (c == 0 || c == 2)) return false;
      if (a == 198 && (b == 18 || b == 19)) return false;
      if (a == 198 && b == 51 && c == 100) return false;
      if (a == 203 && b == 0 && c == 113) return false;
      return true;
    }
    if (address.type == InternetAddressType.IPv6 && raw.length == 16) {
      if (raw.every((byte) => byte == 0)) return false;
      if ((raw[0] & 0xfe) == 0xfc) return false;
      if (raw[0] == 0xfe && (raw[1] & 0xc0) == 0x80) return false;
      if (raw[0] == 0xff) return false;
      if (raw[0] == 0x20 &&
          raw[1] == 0x01 &&
          raw[2] == 0x0d &&
          raw[3] == 0xb8) {
        return false;
      }
      if (_isIpv4MappedIpv6(raw)) {
        return _isPublicIp(InternetAddress.fromRawAddress(raw.sublist(12)));
      }
      return true;
    }
    return false;
  }

  static bool _isAllowedExplicitGatewayIp(InternetAddress address) {
    if (_isPublicIp(address)) return true;
    if (address.isLoopback || address.isLinkLocal) return false;
    final raw = address.rawAddress;
    if (address.type == InternetAddressType.IPv4 && raw.length == 4) {
      final a = raw[0];
      final b = raw[1];
      return a == 10 ||
          (a == 100 && b >= 64 && b <= 127) ||
          (a == 172 && b >= 16 && b <= 31) ||
          (a == 192 && b == 168);
    }
    if (address.type == InternetAddressType.IPv6 && raw.length == 16) {
      return (raw[0] & 0xfe) == 0xfc;
    }
    return false;
  }

  static bool _isIpv4MappedIpv6(List<int> raw) {
    for (var index = 0; index < 10; index += 1) {
      if (raw[index] != 0) return false;
    }
    return raw[10] == 0xff && raw[11] == 0xff;
  }
}

/// Root-owned lifecycle and temporary integration lookup for Phase 1.
///
/// The app Provider tree owns exactly one registry. UA-owned services accept an
/// injected client where practical and otherwise use [instance] until the
/// concurrent Phase 1 lanes merge. Final integration must review replacing the
/// lookup with constructor DI through ChatProvider/AgentService/ToolRegistry.
/// TODO(network-final-integration): after Phase 1 merges, review replacing the
/// registry lookup seam with constructor DI through those shared ownership
/// files without reintroducing per-service transports.
final class AppHttpClientRegistry {
  AppHttpClientRegistry({
    required AppRuntimeInfo runtimeInfo,
    AppNativeHttpClientFactory? createNativeClient,
    AppHostResolver? resolveWebFetchHost,
    AppSocketConnector? connectWebFetchSocket,
  })  : client = AppHttpClient(
          runtimeInfo,
          createNativeClient: createNativeClient,
        ),
        webFetchClient = AppWebFetchClient(
          runtimeInfo,
          createNativeClient: createNativeClient,
          resolveHost: resolveWebFetchHost,
          connectSocket: connectWebFetchSocket,
        );

  final AppHttpClient client;
  final AppWebFetchClient webFetchClient;
  bool _disposed = false;

  static AppHttpClientRegistry? _instance;

  static AppHttpClientRegistry get instance {
    final current = _instance;
    if (current != null) return current;
    if (Platform.environment['FLUTTER_TEST'] == 'true') {
      return _instance = AppHttpClientRegistry(
        runtimeInfo: AppRuntimeInfo.forTesting(),
      );
    }
    throw StateError(
        'App HTTP registry has not been installed by the app root');
  }

  static void installForApp(AppHttpClientRegistry registry) {
    final current = _instance;
    if (current != null && !identical(current, registry)) {
      throw StateError('A different app HTTP registry is already installed');
    }
    _instance = registry;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    webFetchClient.close();
    client.close();
    if (identical(_instance, this)) {
      _instance = null;
    }
  }

  static void resetForTesting() {
    _instance?.dispose();
    _instance = null;
  }
}
