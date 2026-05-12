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
          if (_isPrivateIP(addr)) {
            throw SocketException(
              'Blocked connection to private IP ${addr.address} (SSRF protection)',
            );
          }
        }
        return Socket.startConnect(addresses.first, uri.port);
      };
    return IOClient(ioClient);
  }

  static bool _isPrivateIP(InternetAddress addr) {
    if (addr.isLoopback) return true;

    if (addr.type == InternetAddressType.IPv4) {
      final parts = addr.address.split('.');
      if (parts.length != 4) return false;
      final a = int.parse(parts[0]);
      final b = int.parse(parts[1]);
      if (a == 10) return true;
      if (a == 172 && b >= 16 && b <= 31) return true;
      if (a == 192 && b == 168) return true;
      if (a == 127) return true;
      if (a == 169 && b == 254) return true;
      return false;
    }

    if (addr.type == InternetAddressType.IPv6) {
      final raw = addr.rawAddress;
      if (raw.length == 16) {
        // IPv4-mapped IPv6 (::ffff:x.x.x.x) — extract IPv4 and check
        bool isMapped = true;
        for (int i = 0; i < 10; i++) { if (raw[i] != 0) { isMapped = false; break; } }
        if (isMapped && raw[10] == 0xff && raw[11] == 0xff) {
          final a = raw[12], b = raw[13];
          if (a == 10 || (a == 172 && b >= 16 && b <= 31) ||
              (a == 192 && b == 168) || a == 127 || (a == 169 && b == 254)) return true;
        }
        if (raw[0] == 0xfc || raw[0] == 0xfd) return true;
        if (raw[0] == 0xfe && (raw[1] & 0xc0) == 0x80) return true;
      }
      if (addr.address.startsWith('[') && addr.address.contains('%')) return true;
      return false;
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

    if (_isPrivateOrInternalHost(uri.host)) {
      return 'Error: Access to private/internal IP addresses is blocked for security (SSRF protection).';
    }

    final reqHeaders = headers?.map((k, v) => MapEntry(k, v.toString())) ?? {};

    final client = _createSecureClient();
    try {
      http.Response response;
      if (method == 'POST') {
        response = await client
            .post(uri, headers: reqHeaders, body: body)
            .timeout(_timeout);
      } else {
        response = await client
            .get(uri, headers: reqHeaders)
            .timeout(_timeout);
      }

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

  static bool _isPrivateOrInternalHost(String host) {
    final lowerHost = host.toLowerCase();
    if (lowerHost == 'localhost' ||
        lowerHost.endsWith('.local') ||
        lowerHost.endsWith('.internal') ||
        lowerHost == 'metadata.google.internal' ||
        lowerHost == '169.254.169.254') {
      return true;
    }

    final ipv4Match = RegExp(r'^(\d+)\.(\d+)\.(\d+)\.(\d+)$').firstMatch(host);
    if (ipv4Match != null) {
      final a = int.parse(ipv4Match.group(1)!);
      final b = int.parse(ipv4Match.group(2)!);
      if (a == 10) return true;
      if (a == 172 && b >= 16 && b <= 31) return true;
      if (a == 192 && b == 168) return true;
      if (a == 127) return true;
      if (a == 169 && b == 254) return true;
      return false;
    }

    if (host.contains(':')) {
      if (host == '::1') return true;
      try {
        final addr = InternetAddress(host);
        if (addr.type == InternetAddressType.IPv6) {
          final raw = addr.rawAddress;
          if (raw[0] == 0xfc || raw[0] == 0xfd) return true;
          if (raw[0] == 0xfe && (raw[1] & 0xc0) == 0x80) return true;
        }
      } catch (_) {
        // Address parsing failed — not a valid IPv6, skip
      }
    }

    return false;
  }
}
