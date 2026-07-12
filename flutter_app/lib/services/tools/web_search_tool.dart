import 'dart:async';
import 'package:http/http.dart' as http;
import '../../models/chat_models.dart';
import '../app_http.dart';
import 'tool_registry.dart';
import 'tool_result_formatter.dart';

class WebSearchTool extends Tool {
  WebSearchTool({Uri? endpoint, AppHttpClient? httpClient})
      : _endpoint = endpoint ?? Uri.parse('https://html.duckduckgo.com/html/'),
        _injectedClient = httpClient;

  final Uri _endpoint;
  final AppHttpClient? _injectedClient;

  AppHttpClient get _client =>
      _injectedClient ?? AppHttpClientRegistry.instance.client;

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
    return _execute(input, followRedirects: true, cancellationSignal: null);
  }

  Future<String> executeForSkill(
    Map<String, dynamic> input, {
    ToolCancellationSignal? cancellationSignal,
  }) {
    return _execute(
      input,
      followRedirects: false,
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
      followRedirects: true,
      cancellationSignal: cancellationSignal,
    );
    return ToolResultFormatter.format(
      toolName: name,
      input: input,
      output: output,
      isError: output.startsWith('Search failed:'),
    );
  }

  Future<String> _execute(
    Map<String, dynamic> input, {
    required bool followRedirects,
    required ToolCancellationSignal? cancellationSignal,
  }) async {
    cancellationSignal?.throwIfCancellationRequested();
    final query = input['query'] as String;
    final numResults =
        (input['num_results'] as num?)?.toInt().clamp(1, 10) ?? 5;

    try {
      final abort = Completer<void>();
      final timer = Timer(const Duration(seconds: 15), abort.complete);
      if (cancellationSignal != null) {
        unawaited(cancellationSignal.whenCancelled.then((_) {
          if (!abort.isCompleted) abort.complete();
        }));
      }
      final request = http.AbortableRequest(
        'GET',
        _endpoint.replace(queryParameters: {'q': query}),
        abortTrigger: abort.future,
      )..followRedirects = followRedirects;
      late final http.Response response;
      try {
        response = await http.Response.fromStream(await _client.send(request));
        if (cancellationSignal?.isCancellationRequested == true) {
          throw const ToolExecutionCancelledException(
            sideEffectsPrevented: true,
          );
        }
      } finally {
        timer.cancel();
      }
      final body = response.body;

      final results = _parseResults(body, numResults);
      if (results.isEmpty) return 'No results found for: $query';
      return results
          .map((r) => '${r['title']}\n${r['snippet']}\n${r['url']}')
          .join('\n\n---\n\n');
    } on ToolExecutionCancelledException {
      rethrow;
    } catch (e) {
      if (cancellationSignal?.isCancellationRequested == true) {
        throw const ToolExecutionCancelledException(
          sideEffectsPrevented: true,
        );
      }
      return 'Search failed: $e';
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

    for (int i = 0;
        i < titleMatches.length && results.length < maxResults;
        i++) {
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
