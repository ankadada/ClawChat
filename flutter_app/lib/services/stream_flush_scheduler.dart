import 'dart:async';

class StreamFlushScheduler {
  static const defaultMaxDelay = Duration(milliseconds: 80);

  final Duration maxDelay;
  Timer? _timer;

  StreamFlushScheduler({this.maxDelay = defaultMaxDelay});

  bool get isScheduled => _timer != null;

  void schedule({
    required String delta,
    required void Function() flush,
  }) {
    if (_isBoundaryDelta(delta)) {
      flushNow(flush);
      return;
    }
    _timer ??= Timer(maxDelay, () {
      _timer = null;
      flush();
    });
  }

  void flushNow(void Function() flush) {
    _timer?.cancel();
    _timer = null;
    flush();
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  static bool _isBoundaryDelta(String delta) {
    return delta.contains('\n') || delta.contains('\r');
  }
}
