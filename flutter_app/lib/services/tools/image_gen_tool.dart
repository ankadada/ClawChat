import 'dart:convert';
import 'dart:io';
import 'tool_registry.dart';
import '../preferences_service.dart';

class ImageGenTool extends Tool {
  final PreferencesService _prefs;
  ImageGenTool(this._prefs);

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
    final prompt = input['prompt'] as String;
    final size = input['size'] as String? ?? '1024x1024';

    final apiKey = _prefs.apiKey;
    if (apiKey == null || apiKey.isEmpty) {
      return 'Error: No API key configured';
    }

    final baseUrl = _prefs.baseUrl ?? 'https://api.openai.com';
    final url = '$baseUrl/v1/images/generations';

    final client = HttpClient();
    try {
      final request = await client.postUrl(Uri.parse(url));
      request.headers.set('Authorization', 'Bearer $apiKey');
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({
        'prompt': prompt,
        'n': 1,
        'size': size,
        'model': 'dall-e-3',
      }));

      final response = await request.close().timeout(const Duration(seconds: 60));
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode != 200) {
        return 'Image generation failed (${response.statusCode}): $body';
      }

      final data = jsonDecode(body);
      final imageUrl = data['data']?[0]?['url'] as String?;
      if (imageUrl == null) return 'No image URL in response';

      return 'Image generated successfully!\n\n![Generated Image]($imageUrl)\n\nURL: $imageUrl';
    } catch (e) {
      return 'Image generation failed: $e';
    } finally {
      client.close();
    }
  }
}
