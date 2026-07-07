import 'dart:convert';

import 'package:clawchat/constants.dart';
import 'package:clawchat/services/preferences_service.dart';
import 'package:clawchat/services/tools/phone_intent_tool.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const nativeChannel = MethodChannel(AppConstants.channelName);
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  late Map<String, String> secureStorage;

  Future<PreferencesService> initPrefs({
    bool allowSms = false,
    bool allowPhoneCall = false,
  }) async {
    SharedPreferences.setMockInitialValues({
      'allow_sms': allowSms,
      'allow_phone_call': allowPhoneCall,
    });
    PreferencesService.resetForTesting();
    final prefs = PreferencesService();
    await prefs.init();
    return prefs;
  }

  setUp(() {
    secureStorage = {};
    PhoneIntentTool.resetRateLimitForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
      final key = args['key']?.toString();
      switch (call.method) {
        case 'read':
          return key == null ? null : secureStorage[key];
        case 'write':
          if (key != null) {
            secureStorage[key] = args['value']?.toString() ?? '';
          }
          return null;
        case 'delete':
          if (key != null) secureStorage.remove(key);
          return null;
        case 'deleteAll':
          secureStorage.clear();
          return null;
        case 'containsKey':
          return key != null && secureStorage.containsKey(key);
        case 'readAll':
          return Map<String, String>.from(secureStorage);
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
    PhoneIntentTool.resetRateLimitForTesting();
    PreferencesService.resetForTesting();
  });

  test('sendSms is rejected by default without touching NativeBridge',
      () async {
    var nativeCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeChannel, (call) async {
      nativeCalls += 1;
      fail('NativeBridge should not be called when sendSms is disabled');
    });

    final tool = PhoneIntentTool(await initPrefs());
    final output = await tool.execute({
      'action': 'sendSms',
      'params': {'number': '+15551234567', 'body': 'hello'},
    });
    final decoded = jsonDecode(output) as Map<String, dynamic>;

    expect(decoded['ok'], isFalse);
    expect(decoded['error'], 'disabled_by_user');
    expect(nativeCalls, 0);
  });

  test('sendSms reaches NativeBridge only when allowSms is enabled', () async {
    MethodCall? recordedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeChannel, (call) async {
      recordedCall = call;
      return {'ok': true, 'parts': 1};
    });

    final tool = PhoneIntentTool(await initPrefs(allowSms: true));
    final output = await tool.execute({
      'action': 'sendSms',
      'params': {'number': '+15551234567', 'body': 'hello'},
    });
    final decoded = jsonDecode(output) as Map<String, dynamic>;
    final args = Map<String, dynamic>.from(recordedCall!.arguments as Map);
    final params = Map<String, dynamic>.from(args['params'] as Map);

    expect(decoded['ok'], isTrue);
    expect(recordedCall!.method, 'phoneIntent');
    expect(args['action'], 'sendSms');
    expect(args['allowed'], isTrue);
    expect(params['number'], '+15551234567');
    expect(params['body'], 'hello');
  });

  test('callPhone uses the same restricted-action gating', () async {
    var nativeCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeChannel, (call) async {
      nativeCalls += 1;
      return {'ok': true};
    });

    final deniedTool = PhoneIntentTool(await initPrefs());
    final deniedOutput = await deniedTool.execute({
      'action': 'callPhone',
      'params': {'number': '+15557654321'},
    });
    final denied = jsonDecode(deniedOutput) as Map<String, dynamic>;
    expect(denied['ok'], isFalse);
    expect(denied['error'], 'disabled_by_user');
    expect(nativeCalls, 0);

    PhoneIntentTool.resetRateLimitForTesting();
    final allowedTool = PhoneIntentTool(await initPrefs(allowPhoneCall: true));
    final allowedOutput = await allowedTool.execute({
      'action': 'callPhone',
      'params': {'number': '+15557654321'},
    });
    final allowed = jsonDecode(allowedOutput) as Map<String, dynamic>;
    expect(allowed['ok'], isTrue);
    expect(nativeCalls, 1);
  });

  test('cancelled SMS bridge result is model-facing failure', () async {
    // Native confirmation dialog behavior requires manual real-device
    // verification; this Dart test covers the bridge-result semantics.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeChannel, (call) async {
      return {
        'ok': false,
        'error': 'cancelled',
        'message': 'SMS send cancelled by user',
      };
    });

    final tool = PhoneIntentTool(await initPrefs(allowSms: true));
    final payload = await tool.executeResult({
      'action': 'sendSms',
      'params': {'number': '+15551234567', 'body': 'hello'},
    });
    final llmEnvelope = jsonDecode(payload.forLlm!) as Map<String, dynamic>;

    expect(payload.forUser, contains('"ok":false'));
    expect(payload.forUser, contains('"error":"cancelled"'));
    expect(llmEnvelope['status'], 'error');
    expect(llmEnvelope['output'], contains('"error":"cancelled"'));
  });
}
