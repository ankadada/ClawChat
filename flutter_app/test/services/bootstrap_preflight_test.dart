import 'package:clawchat/constants.dart';
import 'package:clawchat/services/bootstrap_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(AppConstants.channelName);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('bootstrap preflight reports real native storage, cache and network',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getBootstrapStatus');
      return <String, Object>{
        'complete': false,
        'rootfsExists': true,
        'availableBytes': 512 * 1024 * 1024,
        'cachedArchiveBytes': 1024,
        'networkConnected': true,
        'networkValidated': false,
      };
    });
    final result = await BootstrapService().preflight();
    expect(result.rootfsPresent, isTrue);
    expect(result.cachedArchiveBytes, 1024);
    expect(result.hasEnoughStorage, isTrue);
    expect(result.canStart, isTrue);
    expect(result.networkValidated, isFalse);
  });

  test('known insufficient storage or disconnected network blocks start',
      () async {
    for (final values in [
      <String, Object>{
        'availableBytes': BootstrapService.requiredFreeBytes - 1,
        'networkConnected': true,
      },
      <String, Object>{
        'availableBytes': BootstrapService.requiredFreeBytes,
        'networkConnected': false,
      },
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              channel,
              (_) async => <String, Object>{
                    'complete': false,
                    'rootfsExists': false,
                    'cachedArchiveBytes': 0,
                    'networkValidated': false,
                    ...values,
                  });
      expect((await BootstrapService().preflight()).canStart, isFalse);
    }
  });
}
