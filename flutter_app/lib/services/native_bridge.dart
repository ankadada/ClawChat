import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/services.dart';
import '../constants.dart';

// Private aliases to keep dart:io usage contained
typedef _File = io.File;
final _base64 = base64;

class NativeBridge {
  static const _channel = MethodChannel(AppConstants.channelName);

  static Future<String> getProotPath() async {
    return (await _channel.invokeMethod<String>('getProotPath'))!;
  }

  static Future<String> getArch() async {
    return (await _channel.invokeMethod<String>('getArch'))!;
  }

  static Future<String> getFilesDir() async {
    return (await _channel.invokeMethod<String>('getFilesDir'))!;
  }

  static Future<String> getNativeLibDir() async {
    return (await _channel.invokeMethod<String>('getNativeLibDir'))!;
  }

  static Future<bool> isBootstrapComplete() async {
    return (await _channel.invokeMethod<bool>('isBootstrapComplete'))!;
  }

  static Future<Map<String, dynamic>> getBootstrapStatus() async {
    final result = await _channel.invokeMethod<Map>('getBootstrapStatus');
    return Map<String, dynamic>.from(result!);
  }

  static Future<bool> extractRootfs(String tarPath) async {
    return (await _channel.invokeMethod<bool>('extractRootfs', {'tarPath': tarPath}))!;
  }

  static Future<String> runInProot(
    String command, {
    int timeout = 900,
    bool mountStorage = false,
  }) async {
    return (await _channel.invokeMethod<String>('runInProot', {
      'command': command,
      'timeout': timeout,
      'mountStorage': mountStorage,
    }))!;
  }

  static Future<bool> setupDirs() async {
    return (await _channel.invokeMethod<bool>('setupDirs'))!;
  }

  static Future<bool> writeResolv() async {
    return (await _channel.invokeMethod<bool>('writeResolv'))!;
  }

  static Future<bool> startTerminalService() async {
    return (await _channel.invokeMethod<bool>('startTerminalService'))!;
  }

  static Future<bool> stopTerminalService() async {
    return (await _channel.invokeMethod<bool>('stopTerminalService'))!;
  }

  static Future<bool> isTerminalServiceRunning() async {
    return (await _channel.invokeMethod<bool>('isTerminalServiceRunning'))!;
  }

  static Future<Map<String, dynamic>> getBatteryStatus() async {
    final result = await _channel.invokeMethod<Map>('getBatteryStatus');
    return Map<String, dynamic>.from(result!);
  }

  static Future<bool> requestBatteryOptimization() async {
    return (await _channel.invokeMethod<bool>('requestBatteryOptimization'))!;
  }

  static Future<bool> isBatteryOptimized() async {
    return (await _channel.invokeMethod<bool>('isBatteryOptimized'))!;
  }

  static Future<bool> startSetupService() async {
    return (await _channel.invokeMethod<bool>('startSetupService'))!;
  }

  static Future<bool> updateSetupNotification(String text, {int progress = -1}) async {
    return (await _channel.invokeMethod<bool>('updateSetupNotification', {'text': text, 'progress': progress}))!;
  }

  static Future<bool> stopSetupService() async {
    return (await _channel.invokeMethod<bool>('stopSetupService'))!;
  }

  static Future<bool> requestStoragePermission() async {
    return (await _channel.invokeMethod<bool>('requestStoragePermission'))!;
  }

  static Future<bool> hasStoragePermission() async {
    return (await _channel.invokeMethod<bool>('hasStoragePermission'))!;
  }

  static Future<String> getExternalStoragePath() async {
    return (await _channel.invokeMethod<String>('getExternalStoragePath'))!;
  }

  static Future<String?> readRootfsFile(String path) async {
    return await _channel.invokeMethod<String?>('readRootfsFile', {'path': path});
  }

  static Future<bool> writeRootfsFile(String path, String content) async {
    return (await _channel.invokeMethod<bool>('writeRootfsFile', {'path': path, 'content': content}))!;
  }

  static Future<Map<String, dynamic>> phoneIntent(String action, Map<String, dynamic> params, {bool allowed = false}) async {
    final result = await _channel.invokeMethod<Map>('phoneIntent', {
      'action': action,
      'params': params,
      'allowed': allowed,
    });
    return Map<String, dynamic>.from(result ?? {});
  }

  static Future<bool> hasAudioPermission() async {
    return await _channel.invokeMethod<bool>('hasAudioPermission') ?? false;
  }

  static Future<bool> requestAudioPermission() async {
    return await _channel.invokeMethod<bool>('requestAudioPermission') ?? false;
  }

  static Future<String?> startSpeechRecognition({
    String language = 'zh-CN',
  }) async {
    return await _channel.invokeMethod<String>('startSpeechRecognition', {
      'language': language,
    });
  }

  static Future<bool> cancelSpeechRecognition() async {
    return await _channel.invokeMethod<bool>('cancelSpeechRecognition') ??
        false;
  }

  static Future<bool> shareText({
    required String text,
    String? subject,
  }) async {
    return await _channel.invokeMethod<bool>('shareText', {
          'text': text,
          if (subject != null) 'subject': subject,
        }) ??
        false;
  }

  static Future<bool> openHtmlFile(String path) async {
    return await _channel.invokeMethod<bool>('openHtmlFile', {'path': path}) ??
        false;
  }

  static Future<bool> bringToForeground() async {
    return (await _channel.invokeMethod<bool>('bringToForeground'))!;
  }

  /// Copy a host file into the proot workspace.
  ///
  /// For text files, reads content as string and writes via [writeRootfsFile].
  /// For binary files, encodes as base64, writes to a temp file, then decodes
  /// inside proot using `base64 -d`.
  ///
  /// [sourcePath] is the absolute path on the host filesystem (e.g. from file_picker cache).
  /// [destFilename] is the desired filename inside /root/workspace/uploads/.
  /// Returns the destination path inside proot.
  static Future<String> importFileToWorkspace(String sourcePath, String destFilename) async {
    final safeName = destFilename.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final destDir = 'root/workspace/uploads';
    final destPath = '$destDir/$safeName';

    final extension = safeName.split('.').last.toLowerCase();
    const textExtensions = {
      'txt', 'md', 'json', 'yaml', 'yml', 'xml', 'csv',
      'py', 'js', 'ts', 'dart', 'sh', 'html', 'css',
      'toml', 'cfg', 'ini', 'log', 'sql',
    };

    if (textExtensions.contains(extension)) {
      // Text file: read as string and write directly
      final file = await _readFileAsString(sourcePath);
      await writeRootfsFile(destPath, file);
    } else {
      // Binary file: base64 encode, write temp, decode in proot
      final bytes = await _readFileAsBytes(sourcePath);
      final base64Content = _base64Encode(bytes);
      await writeRootfsFile('$destDir/.tmp_b64', base64Content);
      await runInProot(
        'base64 -d /root/workspace/uploads/.tmp_b64 > "/root/workspace/uploads/$safeName" && rm /root/workspace/uploads/.tmp_b64',
      );
    }

    return '/root/workspace/uploads/$safeName';
  }

  // Helper: read file as string (isolates dart:io usage)
  static Future<String> _readFileAsString(String path) async {
    final file = _File(path);
    return await file.readAsString();
  }

  // Helper: read file as bytes
  static Future<List<int>> _readFileAsBytes(String path) async {
    final file = _File(path);
    return await file.readAsBytes();
  }

  // Helper: base64 encode bytes
  static String _base64Encode(List<int> bytes) {
    return _base64.encode(bytes);
  }
}
