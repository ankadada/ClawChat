import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'tool_registry.dart';

class WebFetchTool extends Tool {
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
        'description': 'The URL to fetch (will be upgraded to HTTPS if HTTP)',
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

  http.Client _createSecureClient() {
    final ioClient = HttpClient()
      ..connectionFactory = (uri, proxyHost, proxyPort) async {
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
        return Socket.startConnect(addresses.first, uri.port);
      };
    return IOClient(ioClient);
  }

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
        if (raw[0] == 0xfe && (raw[1] & 0xc0) == 0x80) return false; // fe80::/10
        if (raw[0] == 0xff) return false; // multicast ff00::/8
        if (raw[0] == 0x20 && raw[1] == 0x01 && raw[2] == 0x0d && raw[3] == 0xb8) {
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
    var url = input['url'] as String;
    final method = input['method'] as String? ?? 'GET';
    final headers = input['headers'] as Map<String, dynamic>?;
    final body = input['body'] as String?;

    if (url.startsWith('http://')) {
      url = 'https://${url.substring(7)}';
    }

    final uri = Uri.parse(url);

    try {
      await _validatePublicUrl(uri);
    } on SocketException catch (e) {
      return 'Error: $e';
    } catch (e) {
      return 'Error fetching URL: $e';
    }

    final reqHeaders = headers?.map((k, v) => MapEntry(k, v.toString())) ?? {};

    final client = _createSecureClient();
    try {
      final response = await _sendWithRedirects(
        client,
        uri,
        method,
        reqHeaders,
        body,
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
    } on http.ClientException catch (e) {
      if (e.message.contains('Redirect') || e.message.contains('redirect')) {
        return 'Error: Too many redirects. The URL may be redirecting in a loop.';
      }
      return 'Error fetching URL: $e';
    } on SocketException catch (e) {
      if (e.message.contains('SSRF protection')) {
        return 'Error: $e';
      }
      return 'Error: Could not connect to host: $e';
    } catch (e) {
      return 'Error fetching URL: $e';
    } finally {
      client.close();
    }
  }

  Future<http.Response> _sendWithRedirects(
    http.Client client,
    Uri initialUri,
    String initialMethod,
    Map<String, String> headers,
    String? initialBody,
  ) async {
    var currentUri = initialUri;
    var currentMethod = initialMethod.toUpperCase() == 'POST' ? 'POST' : 'GET';
    var currentBody = currentMethod == 'POST' ? initialBody : null;

    for (var redirectCount = 0; redirectCount < 5; redirectCount++) {
      await _validatePublicUrl(currentUri);

      final request = http.Request(currentMethod, currentUri)
        ..headers.addAll(headers)
        ..followRedirects = false;
      if (currentBody != null) {
        request.body = currentBody;
      }

      final streamedResponse = await client.send(request).timeout(_timeout);
      final response =
          await http.Response.fromStream(streamedResponse).timeout(_timeout);

      if (!_isRedirect(response.statusCode)) return response;

      final location = response.headers['location'];
      if (location == null || location.isEmpty) return response;

      final nextUri = currentUri.resolve(location);
      if (currentUri.scheme == 'https' && nextUri.scheme == 'http') {
        throw http.ClientException(
          'Blocked HTTPS-to-HTTP downgrade redirect',
          nextUri,
        );
      }
      await _validatePublicUrl(nextUri);
      currentUri = nextUri;

      if (response.statusCode == 303 ||
          ((response.statusCode == 301 || response.statusCode == 302) &&
              currentMethod == 'POST')) {
        currentMethod = 'GET';
        currentBody = null;
      }
    }

    throw http.ClientException('Too many redirects', currentUri);
  }

  static bool _isRedirect(int statusCode) =>
      statusCode == 301 ||
      statusCode == 302 ||
      statusCode == 303 ||
      statusCode == 307 ||
      statusCode == 308;

  static Future<void> _validatePublicUrl(Uri uri) async {
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw SocketException('Only HTTP and HTTPS URLs are allowed');
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
