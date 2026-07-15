import 'native_bridge.dart';

abstract interface class BackgroundTaskForegroundLease {
  Future<bool> acquire({
    required String taskId,
    required String sessionId,
  });

  Future<bool> update({
    required String taskId,
    required String sessionId,
    required BackgroundTaskLeaseStatus status,
  });

  Future<bool> release({
    required String taskId,
    required String sessionId,
  });
}

abstract interface class BackgroundTaskLeaseInterruptionSource {
  void setInterruptedHandler(
    Future<bool> Function({
      required String taskId,
      required String sessionId,
      required String reasonCode,
    })? handler,
  );
}

enum BackgroundTaskLeaseStatus { working, needsReview }

extension BackgroundTaskLeaseStatusWire on BackgroundTaskLeaseStatus {
  String get wireValue => switch (this) {
        BackgroundTaskLeaseStatus.working => 'working',
        BackgroundTaskLeaseStatus.needsReview => 'needs_review',
      };
}

/// Native is an owner-scoped foreground-service lease only. It receives a task
/// ID, session routing ID, and a fixed status; it never receives task payload,
/// preview, target, model output, receipt, or task-state mutation authority.
final class NativeBackgroundTaskForegroundLease
    implements
        BackgroundTaskForegroundLease,
        BackgroundTaskLeaseInterruptionSource {
  @override
  Future<bool> acquire({
    required String taskId,
    required String sessionId,
  }) =>
      NativeBridge.startBackgroundTaskLease(
        taskId: taskId,
        sessionId: sessionId,
      );

  @override
  Future<bool> update({
    required String taskId,
    required String sessionId,
    required BackgroundTaskLeaseStatus status,
  }) =>
      NativeBridge.updateBackgroundTaskLease(
        taskId: taskId,
        sessionId: sessionId,
        status: status.wireValue,
      );

  @override
  Future<bool> release({
    required String taskId,
    required String sessionId,
  }) =>
      NativeBridge.stopBackgroundTaskLease(
        taskId: taskId,
        sessionId: sessionId,
      );

  @override
  void setInterruptedHandler(
    Future<bool> Function({
      required String taskId,
      required String sessionId,
      required String reasonCode,
    })? handler,
  ) {
    NativeBridge.setBackgroundTaskLeaseInterruptedHandler(handler);
  }
}
