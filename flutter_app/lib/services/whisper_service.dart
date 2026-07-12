import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'app_http.dart';
import 'api_validator.dart';
import 'preferences_service.dart';

class WhisperService {
  static final WhisperService _instance = WhisperService._();
  factory WhisperService({AppHttpClient? httpClient}) {
    if (httpClient != null) _instance._injectedClient = httpClient;
    return _instance;
  }
  WhisperService._();

  static const _channel = MethodChannel('com.anka.clawbot/native');
  bool isRecording = false;
  int _recordingSequence = 0;
  _WhisperRecordingOperation? _recording;
  AppHttpClient? _injectedClient;
  final List<_WhisperTranscriptionOperation> _activeTranscriptions = [];

  AppHttpClient get _client =>
      _injectedClient ?? AppHttpClientRegistry.instance.client;

  Future<void> startRecording() async {
    if (_recording != null) return;
    final operation = _WhisperRecordingOperation(
      'recording-${++_recordingSequence}',
    );
    _recording = operation;
    try {
      final response = await _channel.invokeMethod<Object?>(
        'startRecording',
        {'operationId': operation.id},
      );
      final started = _WhisperRecordingOperation.fromNative(response);
      if (started == null || started.id != operation.id) {
        throw const FormatException('Invalid recording operation response');
      }
      if (!identical(_recording, operation)) {
        await _stopNativeRecording(operation.id);
        await _deletePath(started.path);
        return;
      }
      operation.path = started.path;
      isRecording = true;
    } catch (e) {
      debugPrint('WhisperService: startRecording failed (${e.runtimeType})');
      if (identical(_recording, operation)) {
        _recording = null;
        isRecording = false;
      }
    }
  }

  Future<String?> stopAndTranscribe() async {
    if (!isRecording) return null;
    final operation = _takeRecording();
    final capturedPath = operation?.path;

    try {
      if (operation != null) await _stopNativeRecording(operation.id);
    } catch (e) {
      debugPrint('WhisperService: stopRecording failed (${e.runtimeType})');
      await _deletePath(capturedPath);
      return null;
    }

    if (capturedPath == null) return null;

    final file = File(capturedPath);
    try {
      if (!await file.exists()) {
        debugPrint('WhisperService: file not found');
        return null;
      }
      final fileSize = await file.length();
      if (fileSize < 100) {
        debugPrint('WhisperService: file too small ($fileSize bytes)');
        await _deleteFile(file);
        return null;
      }
    } catch (_) {
      await _deleteFile(file);
      return null;
    }

    late final String? apiKey;
    late final String model;
    late final String baseUrl;
    try {
      final prefs = PreferencesService();
      apiKey = prefs.apiKey;
      model = prefs.whisperModel ?? 'whisper-1';
      baseUrl = prefs.baseUrl ?? 'https://api.openai.com';
    } catch (_) {
      await _deleteFile(file);
      return null;
    }
    if (apiKey == null || apiKey.isEmpty) {
      debugPrint('WhisperService: no API key');
      await _deleteFile(file);
      return null;
    }

    return _transcribeFile(
      file: file,
      apiKey: apiKey,
      model: model,
      baseUrl: baseUrl,
    );
  }

  @visibleForTesting
  Future<String?> transcribeFileForTesting({
    required File file,
    required String apiKey,
    required String model,
    required String baseUrl,
    Duration timeout = const Duration(seconds: 30),
  }) {
    return _transcribeFile(
      file: file,
      apiKey: apiKey,
      model: model,
      baseUrl: baseUrl,
      timeout: timeout,
    );
  }

  Future<String?> _transcribeFile({
    required File file,
    required String apiKey,
    required String model,
    required String baseUrl,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final url = '$baseUrl/v1/audio/transcriptions';
    final operation = _WhisperTranscriptionOperation(file);
    _activeTranscriptions.add(operation);
    final timeoutTimer = Timer(timeout, operation.abort);

    try {
      final fileSize = await file.length();
      final uri =
          ApiValidator.validateBearerUrl(url, context: 'Whisper API endpoint');
      debugPrint('WhisperService: transcription started fileSize=$fileSize');

      final request = http.AbortableMultipartRequest(
        'POST',
        uri,
        abortTrigger: operation.abortTrigger,
      );
      request.headers['Authorization'] = 'Bearer $apiKey';
      request.fields['model'] = model;
      request.fields['language'] = 'zh';
      request.files.add(await http.MultipartFile.fromPath(
        'file',
        file.path,
        contentType: MediaType('audio', 'mp4'),
      ));

      final response = await _client.send(request);
      final body = await response.stream.bytesToString();
      debugPrint(
          'WhisperService: status=${response.statusCode} responseBytes=${body.length}');

      if (response.statusCode == 200) {
        final data = jsonDecode(body);
        return data['text'] as String?;
      }
      return null;
    } catch (e) {
      debugPrint('WhisperService: transcription failed (${e.runtimeType})');
      return null;
    } finally {
      timeoutTimer.cancel();
      _activeTranscriptions.remove(operation);
      await _deleteFile(operation.file);
      operation.complete();
    }
  }

  Future<void> cancelRecording() async {
    final recording = _recording;
    if (recording != null) {
      if (identical(_recording, recording)) {
        _recording = null;
        isRecording = false;
      }
      try {
        await _stopNativeRecording(recording.id);
      } catch (_) {}
      await _deletePath(recording.path);
      return;
    }

    final operation =
        _activeTranscriptions.isEmpty ? null : _activeTranscriptions.last;
    if (operation == null) return;
    operation.abort();
    await operation.done;
  }

  @visibleForTesting
  Future<void> resetForTesting() async {
    final operations = _activeTranscriptions.toList(growable: false);
    for (final operation in operations) {
      operation.abort();
    }
    await Future.wait(operations.map((operation) => operation.done));
    final recording = _recording;
    _recording = null;
    isRecording = false;
    _injectedClient = null;
    if (recording != null) {
      try {
        await _stopNativeRecording(recording.id);
      } catch (_) {}
      await _deletePath(recording.path);
    }
  }

  _WhisperRecordingOperation? _takeRecording() {
    final operation = _recording;
    _recording = null;
    isRecording = false;
    return operation;
  }

  static Future<Object?> _stopNativeRecording(String operationId) {
    return _channel.invokeMethod<Object?>(
      'stopRecording',
      {'operationId': operationId},
    );
  }

  static Future<void> _deletePath(String? path) async {
    if (path == null) return;
    await _deleteFile(File(path));
  }

  static Future<void> _deleteFile(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Cleanup is best effort; never mask the request result.
    }
  }
}

final class _WhisperRecordingOperation {
  _WhisperRecordingOperation(this.id, [this.path]);

  final String id;
  String? path;

  static _WhisperRecordingOperation? fromNative(Object? value) {
    if (value is! Map) return null;
    final operationId = value['operationId']?.toString();
    final path = value['path']?.toString();
    if (operationId == null ||
        operationId.isEmpty ||
        path == null ||
        path.isEmpty) {
      return null;
    }
    return _WhisperRecordingOperation(operationId, path);
  }
}

final class _WhisperTranscriptionOperation {
  _WhisperTranscriptionOperation(this.file);

  final File file;
  final Completer<void> _abort = Completer<void>();
  final Completer<void> _done = Completer<void>();

  Future<void> get abortTrigger => _abort.future;
  Future<void> get done => _done.future;

  void abort() {
    if (!_abort.isCompleted) _abort.complete();
  }

  void complete() {
    if (!_done.isCompleted) _done.complete();
  }
}
