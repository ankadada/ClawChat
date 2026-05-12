enum SetupStep {
  checkingStatus,
  downloadingRootfs,
  extractingRootfs,
  installingPackages,
  complete,
  error,
}

class SetupState {
  final SetupStep step;
  final double progress;
  final String message;
  final String? error;

  const SetupState({
    this.step = SetupStep.checkingStatus,
    this.progress = 0.0,
    this.message = '',
    this.error,
  });

  SetupState copyWith({
    SetupStep? step,
    double? progress,
    String? message,
    String? error,
  }) {
    return SetupState(
      step: step ?? this.step,
      progress: progress ?? this.progress,
      message: message ?? this.message,
      error: error,
    );
  }

  bool get isComplete => step == SetupStep.complete;
  bool get hasError => step == SetupStep.error;

  String get stepLabel {
    switch (step) {
      case SetupStep.checkingStatus:
        return '检查状态...';
      case SetupStep.downloadingRootfs:
        return '下载 Alpine rootfs';
      case SetupStep.extractingRootfs:
        return '解压根文件系统';
      case SetupStep.installingPackages:
        return '安装软件包';
      case SetupStep.complete:
        return '初始化完成';
      case SetupStep.error:
        return '出错';
    }
  }

  int get stepNumber {
    switch (step) {
      case SetupStep.checkingStatus: return 0;
      case SetupStep.downloadingRootfs: return 1;
      case SetupStep.extractingRootfs: return 2;
      case SetupStep.installingPackages: return 3;
      case SetupStep.complete: return 4;
      case SetupStep.error: return -1;
    }
  }

  static const int totalSteps = 4;
}
