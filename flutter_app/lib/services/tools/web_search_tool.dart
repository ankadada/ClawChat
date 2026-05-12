import 'dart:convert';
import 'dart:io';
import 'tool_registry.dart';

class WebSearchTool extends Tool {
  @override
  String get name => 'web_search';

  @override
  String get description =>
      'Search the web for current information. Returns search results with titles, '
      'snippets, and URLs. Use this when you need up-to-date information.';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'query': {
        'type': 'string',
        'description': 'The search query',
      },
      'num_results': {
        'type': 'integer',
        'description': 'Number of results to return (default: 5, max: 10)',
      },
    },
    'required': ['query'],
  };

  @override
  Future<String> execute(Map<String, dynamic> input) async {
    final query = input['query'] as String;
    final numResults = (input['num_results'] as num?)?.toInt().clamp(1, 10) ?? 5;

    final client = HttpClient();
    try {
      client.userAgent = 'Mozilla/5.0';
      final request = await client.getUrl(
        Uri.parse('https://html.duckduckgo.com/html/?q=${Uri.encodeComponent(query)}'),
      );
      final response = await request.close().timeout(const Duration(seconds: 15));
      final body = await response.transform(utf8.decoder).join();

      final results = _parseResults(body, numResults);
      if (results.isEmpty) return 'No results found for: $query';
      return results.map((r) => '${r['title']}\n${r['snippet']}\n${r['url']}').join('\n\n---\n\n');
    } catch (e) {
      return 'Search failed: $e';
    } finally {
      client.close();
    }
  }

  List<Map<String, String>> _parseResults(String html, int maxResults) {
    final results = <Map<String, String>>[];

    // DuckDuckGo HTML search results use class="result__a" for title links
    // and class="result__snippet" for snippets.
    // The snippet can be in either <a> or <span> tags depending on version.
    final resultBlockPattern = RegExp(
      r'class="result__a"[^>]*href="([^"]*)"[^>]*>(.*?)</a>',
      dotAll: true,
    );
    final snippetPattern = RegExp(
      r'class="result__snippet"[^>]*>(.*?)</(?:a|span)>',
      dotAll: true,
    );

    final titleMatches = resultBlockPattern.allMatches(html).toList();
    final snippetMatches = snippetPattern.allMatches(html).toList();

    for (int i = 0; i < titleMatches.length && results.length < maxResults; i++) {
      final titleMatch = titleMatches[i];
      final url = _decodeUrl(titleMatch.group(1) ?? '');
      final title = _stripHtml(titleMatch.group(2) ?? '');
      final snippet = i < snippetMatches.length
          ? _stripHtml(snippetMatches[i].group(1) ?? '')
          : '';

      if (url.isNotEmpty && title.isNotEmpty) {
        results.add({'title': title, 'snippet': snippet, 'url': url});
      }
    }
    return results;
  }

  String _stripHtml(String html) {
    return html
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#x27;', "'")
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _decodeUrl(String url) {
    // DuckDuckGo wraps URLs: //duckduckgo.com/l/?uddg=ENCODED_URL
    if (url.contains('uddg=')) {
      final match = RegExp(r'uddg=([^&]+)').firstMatch(url);
      if (match != null) return Uri.decodeComponent(match.group(1)!);
    }
    return url;
  }
}
