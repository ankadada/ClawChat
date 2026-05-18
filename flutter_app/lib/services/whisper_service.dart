import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'api_validator.dart';
import 'preferences_service.dart';

class WhisperService {
  static final WhisperService _instance = WhisperService._();
  factory WhisperService() => _instance;
  WhisperService._();

  static const _channel = MethodChannel('com.anka.clawbot/native');
  bool isRecording = false;
  String? _filePath;

  Future<void> startRecording() async {
    if (isRecording) return;
    try {
      final path = await _channel.invokeMethod<String>('startRecording');
      _filePath = path;
      isRecording = true;
    } catch (e) {
      debugPrint('WhisperService: startRecording failed: $e');
      isRecording = false;
    }
  }

  Future<String?> stopAndTranscribe() async {
    if (!isRecording) return null;
    isRecording = false;

    try {
      await _channel.invokeMethod<String>('stopRecording');
    } catch (e) {
      debugPrint('WhisperService: stopRecording failed: $e');
      return null;
    }

    if (_filePath == null) return null;

    final file = File(_filePath!);
    if (!await file.exists()) {
      debugPrint('WhisperService: file not found');
      return null;
    }
    final fileSize = await file.length();
    if (fileSize < 100) {
      debugPrint('WhisperService: file too small ($fileSize bytes)');
      return null;
    }

    final prefs = PreferencesService();
    final apiKey = prefs.apiKey;
    if (apiKey == null || apiKey.isEmpty) {
      debugPrint('WhisperService: no API key');
      return null;
    }

    final model = prefs.whisperModel ?? 'whisper-1';
    final baseUrl = prefs.baseUrl ?? 'https://api.openai.com';
    final url = '$baseUrl/v1/audio/transcriptions';

    try {
      final uri = ApiValidator.validateBearerUrl(url, context: 'Whisper API endpoint');
      debugPrint('WhisperService: POST $url model=$model fileSize=$fileSize');

      final request = http.MultipartRequest('POST', uri);
      request.headers['Authorization'] = 'Bearer $apiKey';
      request.fields['model'] = model;
      request.fields['language'] = 'zh';
      request.files.add(await http.MultipartFile.fromPath(
        'file',
        _filePath!,
        contentType: MediaType('audio', 'mp4'),
      ));

      final response = await request.send().timeout(const Duration(seconds: 30));
      final body = await response.stream.bytesToString();
      debugPrint('WhisperService: ${response.statusCode} ${body.length > 200 ? body.substring(0, 200) : body}');

      try { await file.delete(); } catch (_) {}

      if (response.statusCode == 200) {
        final data = jsonDecode(body);
        return data['text'] as String?;
      }
      return null;
    } catch (e) {
      debugPrint('WhisperService: exception $e');
      return null;
    }
  }

  Future<void> cancelRecording() async {
    if (!isRecording) return;
    try { await _channel.invokeMethod<String>('stopRecording'); } catch (_) {}
    isRecording = false;
    if (_filePath != null) {
      try { await File(_filePath!).delete(); } catch (_) {}
    }
  }
}
