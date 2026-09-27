import 'native_bridge.dart';

/// Why a storage pre-flight did not allow the write.
enum StorageBudgetReason {
  /// Free space is known and above the headroom.
  ok,

  /// The platform did not report free space; the write proceeds and any real
  /// failure still surfaces from the write itself.
  unknown,

  /// Free space is known and below the required headroom.
  insufficient,
}

/// Decision returned by [StorageBudget.ensureCapacity].
class StorageBudgetDecision {
  const StorageBudgetDecision({
    required this.allowed,
    required this.reason,
    this.availableBytes,
    this.requiredBytes = 0,
    this.message,
  });

  final bool allowed;
  final StorageBudgetReason reason;

  /// Free bytes reported by the platform, when known.
  final int? availableBytes;

  /// Headroom the caller asked for (on top of [StorageBudget.minimumFreeBytes]).
  final int requiredBytes;

  /// User-readable explanation; only set when [allowed] is false.
  final String? message;
}

/// §5 AND-6: bounded, explainable disk checks for import/backup/share.
///
/// The goal is that a nearly full device produces one clear, actionable message
/// instead of a half-written export or a silent import failure. The check is a
/// pre-flight only: it never replaces the write's own error handling, and an
/// unreported free-space value does not block the operation (a false block
/// would be worse than letting the write report its own failure).
class StorageBudget {
  StorageBudget({Future<int?> Function()? availableBytesReader})
      : _readAvailableBytes =
            availableBytesReader ?? _defaultAvailableBytesReader;

  /// Kept below [BootstrapService.requiredFreeBytes] (256 MiB): installing the
  /// runtime is a one-off, imports and backups only need working headroom.
  static const int minimumFreeBytes = 64 * 1024 * 1024;

  final Future<int?> Function() _readAvailableBytes;

  static Future<int?> _defaultAvailableBytesReader() async {
    final status = await NativeBridge.getBootstrapStatus();
    final available = status['availableBytes'];
    return available is num ? available.toInt() : null;
  }

  /// Returns whether [operation] may start, given the current free space.
  Future<StorageBudgetDecision> ensureCapacity({
    required String operation,
    int requiredBytes = 0,
  }) async {
    final headroom = minimumFreeBytes + (requiredBytes > 0 ? requiredBytes : 0);
    int? available;
    try {
      available = await _readAvailableBytes();
    } catch (_) {
      // A read failure is not a disk condition: keep going and let the write
      // report its own error.
      available = null;
    }
    if (available == null) {
      return StorageBudgetDecision(
        allowed: true,
        reason: StorageBudgetReason.unknown,
        requiredBytes: headroom,
      );
    }
    if (available < headroom) {
      return StorageBudgetDecision(
        allowed: false,
        reason: StorageBudgetReason.insufficient,
        availableBytes: available,
        requiredBytes: headroom,
        message: lowStorageMessage(
          operation: operation,
          availableBytes: available,
          requiredBytes: headroom,
        ),
      );
    }
    return StorageBudgetDecision(
      allowed: true,
      reason: StorageBudgetReason.ok,
      availableBytes: available,
      requiredBytes: headroom,
    );
  }

  /// The one user-readable low-storage prompt used by every caller.
  static String lowStorageMessage({
    required String operation,
    required int availableBytes,
    required int requiredBytes,
  }) {
    return '$operation 已暂停：设备可用存储不足'
        '（可用 ${formatBytes(availableBytes)}，至少需要 ${formatBytes(requiredBytes)}）。'
        '请清理存储空间后重试。';
  }

  /// Compact, locale-neutral byte formatting for the prompt.
  static String formatBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)}GB';
  }
}
