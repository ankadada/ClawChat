import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../models/chat_models.dart';
import 'tool_registry.dart';
import 'tool_result_formatter.dart';
import '../app_http.dart';
import '../api_validator.dart';
import '../preferences_service.dart';

class ImageGenTool extends Tool {
  final PreferencesService _prefs;
  final AppHttpClient? _injectedClient;
  ImageGenTool(this._prefs, {AppHttpClient? httpClient})
      : _injectedClient = httpClient;

  AppHttpClient get _client =>
      _injectedClient ?? AppHttpClientRegistry.instance.client;

  @override
  String get name => 'generate_image';

  @override
  String get description =>
      'Generate an image from a text description using DALL-E or compatible API. '
      'Returns the image URL. Only works with OpenAI-compatible API providers.';

  @override
  Map<String, dynamic> get inputSchema => {
        'type': 'object',
        'properties': {
          'prompt': {
            'type': 'string',
            'description': 'Detailed description of the image to generate',
          },
          'size': {
            'type': 'string',
            'enum': ['1024x1024', '1024x1792', '1792x1024'],
            'description': 'Image size (default: 1024x1024)',
          },
        },
        'required': ['prompt'],
      };

  @override
  Future<String> execute(Map<String, dynamic> input) async {
    return _execute(input, cancellationSignal: null);
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
      cancellationSignal: cancellationSignal,
    );
    return ToolResultFormatter.format(
      toolName: name,
      input: input,
      output: output,
      isError: output.startsWith('Error') ||
          output.startsWith('Image generation failed'),
    );
  }

  Future<String> _execute(
    Map<String, dynamic> input, {
    required ToolCancellationSignal? cancellationSignal,
  }) async {
    cancellationSignal?.throwIfCancellationRequested();
    final prompt = input['prompt'] as String;
    final size = input['size'] as String? ?? '1024x1024';

    final apiKey = _prefs.apiKey;
    if (apiKey == null || apiKey.isEmpty) {
      return 'Error: No API key configured';
    }

    final baseUrl = _prefs.baseUrl ?? 'https://api.openai.com';
    final url = '$baseUrl/v1/images/generations';

    try {
      final uri =
          ApiValidator.validateBearerUrl(url, context: 'Image API endpoint');
      final abort = Completer<void>();
      final timer = Timer(const Duration(seconds: 60), abort.complete);
      if (cancellationSignal != null) {
        unawaited(cancellationSignal.whenCancelled.then((_) {
          if (!abort.isCompleted) abort.complete();
        }));
      }
      final request = http.AbortableRequest(
        'POST',
        uri,
        abortTrigger: abort.future,
      )
        ..followRedirects = false
        ..headers['Authorization'] = 'Bearer $apiKey'
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode({
          'prompt': prompt,
          'n': 1,
          'size': size,
          'model': 'dall-e-3',
        });

      late final http.Response response;
      var dispatched = false;
      try {
        dispatched = true;
        response = await http.Response.fromStream(await _client.send(request));
        if (cancellationSignal?.isCancellationRequested == true) {
          throw ToolExecutionCancelledException(
            sideEffectsPrevented: !dispatched,
          );
        }
      } catch (_) {
        if (cancellationSignal?.isCancellationRequested == true) {
          throw ToolExecutionCancelledException(
            sideEffectsPrevented: !dispatched,
          );
        }
        rethrow;
      } finally {
        timer.cancel();
      }
      final body = response.body;

      if (response.statusCode != 200) {
        return 'Image generation failed (${response.statusCode}): $body';
      }

      final data = jsonDecode(body);
      final imageUrl = data['data']?[0]?['url'] as String?;
      if (imageUrl == null) return 'No image URL in response';

      return 'Image generated successfully!\n\n![Generated Image]($imageUrl)\n\nURL: $imageUrl';
    } on ToolExecutionCancelledException {
      rethrow;
    } catch (e) {
      return 'Image generation failed: $e';
    }
  }
}
