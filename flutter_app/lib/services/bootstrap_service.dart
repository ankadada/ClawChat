import 'dart:async';
import 'dart:io';
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../constants.dart';
import '../models/setup_state.dart';
import 'app_http.dart';
import 'native_bridge.dart';

class BootstrapService {
  BootstrapService({AppHttpClient? httpClient}) : _injectedClient = httpClient;

  final AppHttpClient? _injectedClient;

  AppHttpClient get _client =>
      _injectedClient ?? AppHttpClientRegistry.instance.client;

  // SHA256 hashes for Alpine 3.21.3 minirootfs tarballs
  static const Map<String, String> _rootfsSha256 = {
    'aarch64':
        'ead8a4b37867bd19e7417dd078748e2312c0aea364403d96758d63ea8ff261ea',
    'arm': '28b2a97374cccd96646e32ab2ebcbd52fa507f1e456620e86a7b227bc2ab3bd3',
    'x86_64':
        '1a694899e406ce55d32334c47ac0b2efb6c06d7e878102d1840892ad44cd5239',
  };
  static const int requiredFreeBytes = 256 * 1024 * 1024;

  Future<BootstrapPreflight> preflight() async {
    final status = await NativeBridge.getBootstrapStatus();
    final available = status['availableBytes'];
    final cached = status['cachedArchiveBytes'];
    return BootstrapPreflight(
      bootstrapComplete: status['complete'] == true,
      rootfsPresent: status['rootfsExists'] == true,
      availableBytes: available is num ? available.toInt() : null,
      cachedArchiveBytes: cached is num ? cached.toInt() : 0,
      networkConnected: status['networkConnected'] as bool?,
      networkValidated: status['networkValidated'] as bool?,
    );
  }

  void _updateSetupNotification(String text, {int progress = -1}) {
    try {
      NativeBridge.updateSetupNotification(text, progress: progress);
    } catch (_) {
      // Non-critical: notification may not be available in all contexts
    }
  }

  void _stopSetupService() {
    try {
      NativeBridge.stopSetupService();
    } catch (_) {
      // Non-critical: service may already be stopped
    }
  }

  Future<SetupState> checkStatus() async {
    try {
      final complete = await NativeBridge.isBootstrapComplete();
      if (complete) {
        return const SetupState(
          step: SetupStep.complete,
          progress: 1.0,
          message: '环境就绪',
        );
      }
      return const SetupState(
        step: SetupStep.checkingStatus,
        progress: 0.0,
        message: '需要初始化环境',
      );
    } catch (_) {
      return const SetupState(
        step: SetupStep.error,
        error: 'status unavailable',
        failureCategory: SetupFailureCategory.status,
      );
    }
  }

  Future<void> runFullSetup({
    required void Function(SetupState) onProgress,
  }) async {
    try {
      final readiness = await preflight();
      if (!readiness.hasEnoughStorage) {
        onProgress(const SetupState(
          step: SetupStep.error,
          error: 'insufficient storage',
          failureCategory: SetupFailureCategory.storage,
        ));
        return;
      }
      if (readiness.networkConnected == false) {
        onProgress(const SetupState(
          step: SetupStep.error,
          error: 'network unavailable',
          failureCategory: SetupFailureCategory.network,
        ));
        return;
      }
      try {
        await NativeBridge.startSetupService();
      } catch (e) {
        stderr.writeln(
            '[BootstrapService] startSetupService failed (non-fatal): $e');
      }

      // Step 0: 初始化目录
      onProgress(const SetupState(
        step: SetupStep.checkingStatus,
        progress: 0.0,
        message: '创建目录...',
      ));
      _updateSetupNotification('创建目录...', progress: 2);
      try {
        await NativeBridge.setupDirs();
      } catch (e) {
        stderr.writeln('[BootstrapService] setupDirs failed: $e');
      }
      try {
        await NativeBridge.writeResolv();
      } catch (e) {
        stderr.writeln('[BootstrapService] writeResolv failed: $e');
      }

      // Step 1: 下载 Alpine rootfs (~3MB, 非常快)
      final arch = await NativeBridge.getArch();
      final rootfsUrl = AppConstants.getRootfsUrl(arch);
      final filesDir = await NativeBridge.getFilesDir();
      final tarPath = '$filesDir/tmp/alpine-rootfs.tar.gz';
      final tarFile = File(tarPath);

      _updateSetupNotification('下载 Alpine rootfs...', progress: 5);
      onProgress(const SetupState(
        step: SetupStep.downloadingRootfs,
        progress: 0.0,
        message: '下载 Alpine Linux 根文件系统...',
      ));

      final cachedArchiveValid = await _hasValidCachedArchive(tarFile, arch);
      if (!cachedArchiveValid) {
        try {
          await _downloadFile(
            Uri.parse(rootfsUrl),
            tarFile,
            onProgress: (received, total) {
              if (total > 0) {
                final progress = received / total;
                final mb = (received / 1024 / 1024).toStringAsFixed(1);
                final totalMb = (total / 1024 / 1024).toStringAsFixed(1);
                final notifProgress = 5 + (progress * 25).round();
                _updateSetupNotification('下载 rootfs: $mb / $totalMb MB',
                    progress: notifProgress);
                onProgress(SetupState(
                  step: SetupStep.downloadingRootfs,
                  progress: progress,
                  message: '下载中: $mb MB / $totalMb MB',
                ));
              }
            },
          );
        } catch (e) {
          stderr.writeln('[BootstrapService] rootfs download failed');
          throw BootstrapDownloadException(e);
        }
      } else {
        onProgress(const SetupState(
          step: SetupStep.downloadingRootfs,
          progress: 1.0,
          message: '使用已校验的本地下载',
        ));
      }

      // Verify SHA256 integrity using streaming hash to avoid loading
      // the entire file into memory at once.
      _updateSetupNotification('校验文件完整性...', progress: 30);
      try {
        final output = AccumulatorSink<Digest>();
        final input = sha256.startChunkedConversion(output);
        await for (final chunk in File(tarPath).openRead()) {
          input.add(chunk);
        }
        input.close();
        final actualHash = output.events.single.toString();
        final expectedHash = _rootfsSha256[arch];
        if (expectedHash == null || actualHash != expectedHash) {
          stderr.writeln(
              '[BootstrapService] SHA256 mismatch: expected=$expectedHash actual=$actualHash');
          await File(tarPath).delete();
          throw const BootstrapIntegrityException();
        }
      } on FileSystemException catch (e) {
        stderr.writeln('[BootstrapService] Failed to read downloaded file: $e');
        rethrow;
      }

      // Step 2: 解压 rootfs (30-50%)
      _updateSetupNotification('解压 rootfs...', progress: 30);
      onProgress(const SetupState(
        step: SetupStep.extractingRootfs,
        progress: 0.0,
        message: '解压根文件系统...',
      ));
      try {
        await NativeBridge.extractRootfs(tarPath);
      } catch (e) {
        stderr.writeln('[BootstrapService] extractRootfs failed: $e');
        rethrow;
      }

      // Step 3: 安装基础软件包 (50-95%)
      _updateSetupNotification('安装软件包...', progress: 50);
      onProgress(const SetupState(
        step: SetupStep.installingPackages,
        progress: 0.0,
        message: '安装基础软件包 (bash, python3, curl, git, jq)...',
      ));

      await NativeBridge.runInProot('apk update');

      onProgress(const SetupState(
        step: SetupStep.installingPackages,
        progress: 0.3,
        message: '安装 bash...',
      ));
      _updateSetupNotification('安装 bash...', progress: 60);
      await NativeBridge.runInProot('apk add --no-cache bash coreutils');

      onProgress(const SetupState(
        step: SetupStep.installingPackages,
        progress: 0.5,
        message: '安装开发工具...',
      ));
      _updateSetupNotification('安装开发工具...', progress: 70);
      await NativeBridge.runInProot(
        'apk add --no-cache python3 py3-pip curl wget git jq ca-certificates',
      );

      onProgress(const SetupState(
        step: SetupStep.installingPackages,
        progress: 0.8,
        message: '安装编译工具...',
      ));
      _updateSetupNotification('安装编译工具...', progress: 80);
      await NativeBridge.runInProot('apk add --no-cache build-base');

      await NativeBridge.runInProot(
        'mkdir -p /root/workspace && echo "setup_complete"',
      );

      // 完成
      _updateSetupNotification('初始化完成!', progress: 100);
      _stopSetupService();
      onProgress(const SetupState(
        step: SetupStep.complete,
        progress: 1.0,
        message: '环境初始化完成! 可以开始聊天了。',
      ));
    } on BootstrapDownloadException {
      _stopSetupService();
      stderr.writeln('[BootstrapService] Setup download failed');
      onProgress(const SetupState(
        step: SetupStep.error,
        error: 'download unavailable',
        failureCategory: SetupFailureCategory.network,
      ));
    } on BootstrapIntegrityException {
      _stopSetupService();
      stderr.writeln('[BootstrapService] Setup integrity verification failed');
      onProgress(const SetupState(
        step: SetupStep.error,
        error: 'integrity verification failed',
        failureCategory: SetupFailureCategory.integrity,
      ));
    } catch (_) {
      _stopSetupService();
      stderr.writeln('[BootstrapService] Setup failed');
      onProgress(const SetupState(
        step: SetupStep.error,
        error: 'environment setup failed',
        failureCategory: SetupFailureCategory.environment,
      ));
    }
  }

  @visibleForTesting
  Future<void> downloadFileForTesting(
    Uri uri,
    File destination, {
    void Function(int received, int total)? onProgress,
    Duration timeout = const Duration(seconds: 30),
  }) {
    return _downloadFile(
      uri,
      destination,
      onProgress: onProgress,
      timeout: timeout,
    );
  }

  Future<void> _downloadFile(
    Uri uri,
    File destination, {
    void Function(int received, int total)? onProgress,
    Duration timeout = const Duration(minutes: 2),
  }) async {
    final abort = Completer<void>();
    var timedOut = false;
    final timer = Timer(timeout, () {
      timedOut = true;
      if (!abort.isCompleted) abort.complete();
    });
    IOSink? sink;
    try {
      final request = http.AbortableRequest(
        'GET',
        uri,
        abortTrigger: abort.future,
      );
      final response = await _client.send(request);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'Download failed with HTTP ${response.statusCode}',
          uri: uri,
        );
      }

      final total = response.contentLength ?? -1;
      var received = 0;
      sink = destination.openWrite();
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
      await sink.close();
      sink = null;
    } on http.RequestAbortedException {
      if (sink != null) {
        await sink.close();
        sink = null;
      }
      if (await destination.exists()) await destination.delete();
      if (timedOut) {
        throw TimeoutException('Download timed out', timeout);
      }
      rethrow;
    } catch (_) {
      if (sink != null) {
        await sink.close();
        sink = null;
      }
      if (await destination.exists()) await destination.delete();
      rethrow;
    } finally {
      timer.cancel();
      if (sink != null) await sink.close();
    }
  }

  Future<bool> _hasValidCachedArchive(File file, String arch) async {
    if (!await file.exists()) return false;
    final expected = _rootfsSha256[arch];
    if (expected == null) return false;
    try {
      final output = AccumulatorSink<Digest>();
      final input = sha256.startChunkedConversion(output);
      await for (final chunk in file.openRead()) {
        input.add(chunk);
      }
      input.close();
      if (output.events.single.toString() == expected) return true;
    } catch (_) {
      // Invalid or unreadable cache is removed below and downloaded again.
    }
    try {
      await file.delete();
    } catch (_) {}
    return false;
  }
}

final class BootstrapPreflight {
  const BootstrapPreflight({
    required this.bootstrapComplete,
    required this.rootfsPresent,
    required this.availableBytes,
    required this.cachedArchiveBytes,
    required this.networkConnected,
    required this.networkValidated,
  });

  final bool bootstrapComplete;
  final bool rootfsPresent;
  final int? availableBytes;
  final int cachedArchiveBytes;
  final bool? networkConnected;
  final bool? networkValidated;

  bool get hasEnoughStorage =>
      availableBytes == null ||
      availableBytes! >= BootstrapService.requiredFreeBytes;
  bool get canStart => hasEnoughStorage && networkConnected != false;
}

final class BootstrapDownloadException implements Exception {
  const BootstrapDownloadException(this.cause);

  final Object cause;
}

final class BootstrapIntegrityException implements Exception {
  const BootstrapIntegrityException();
}
