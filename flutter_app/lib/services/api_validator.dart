class ApiValidator {
  static Uri validateBearerUrl(String url, {String context = 'API endpoint'}) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw Exception('$context must be a valid absolute URL');
    }

    if (uri.scheme == 'https') return uri;

    if (uri.scheme == 'http' && _isLocalDevelopmentHost(uri.host)) {
      return uri;
    }

    throw Exception('$context must use HTTPS');
  }

  static bool _isLocalDevelopmentHost(String host) {
    final normalized = host.toLowerCase();
    return normalized == 'localhost' ||
        normalized == '127.0.0.1' ||
        normalized == '::1';
  }
}
