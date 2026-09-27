import 'dart:convert';

import 'package:clawchat/constants.dart';
import 'package:clawchat/services/preferences_service.dart';
import 'package:clawchat/services/tools/phone_tools.dart';
import 'package:clawchat/services/tools/tool_registry.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

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
    PhoneSendTool.resetRateLimitForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (call) async => null);
  });

  Map<String, dynamic> decode(String output) =>
      Map<String, dynamic>.from(jsonDecode(output) as Map);

  group('phone_read calendar', () {
    test('uses the start of today and caps the default limit', () async {
      Map<String, dynamic>? captured;
      final tool = PhoneReadTool(
        transport: (action, params, {required allowed}) async {
          captured = {'action': action, 'params': params};
          return {'ok': true, 'events': const []};
        },
      );

      final result =
          decode(await tool.execute({'action': 'listCalendarEvents'}));

      expect(result['ok'], true);
      expect(captured!['action'], 'listCalendarEvents');
      final params = captured!['params'] as Map;
      expect(params['startMillis'], PhoneReadTool.startOfTodayMillis());
      expect(
        params['endMillis'],
        PhoneReadTool.startOfTodayMillis() +
            const Duration(days: 7).inMilliseconds,
      );
      expect(params['limit'], PhoneReadTool.defaultCalendarLimit);
    });

    test('caps an oversized limit at the max', () async {
      Map<String, dynamic>? captured;
      final tool = PhoneReadTool(
        transport: (action, params, {required allowed}) async {
          captured = params;
          return {'ok': true, 'events': const []};
        },
      );
      await tool.execute({
        'action': 'listCalendarEvents',
        'params': {'limit': 999},
      });
      expect(captured!['limit'], PhoneReadTool.maxCalendarLimit);
    });

    test('redacts description URLs, emails and tel values', () async {
      final tool = PhoneReadTool(
        transport: (action, params, {required allowed}) async => {
          'ok': true,
          'events': [
            {
              'id': 1,
              'title': 'Standup',
              'beginMillis': 1000,
              'endMillis': 2000,
              'location': 'Zoom',
              'description':
                  'Join https://zoom.us/j/123 or mail a@b.com tel:+123456789',
              'allDay': false,
            },
          ],
        },
      );
      final result =
          decode(await tool.execute({'action': 'listCalendarEvents'}));
      final event = (result['events'] as List).single as Map;
      final description = event['description'] as String;
      expect(description, contains('[redacted-url]'));
      expect(description, contains('[redacted-email]'));
      expect(description, contains('[redacted-phone]'));
      expect(description, isNot(contains('zoom.us')));
      expect(description, isNot(contains('a@b.com')));
      expect(event['beginIso'], isA<String>());
    });

    test('query for a value only in the raw description does not match',
        () async {
      final tool = PhoneReadTool(
        transport: (action, params, {required allowed}) async => {
          'ok': true,
          'events': [
            {
              'id': 1,
              'title': 'Standup',
              'beginMillis': 1,
              'endMillis': 2,
              'location': 'Room 4',
              'description': 'Join https://zoom.us/j/secret-token',
            },
          ],
        },
      );
      // The URL is redacted from the result, so it must not be a query oracle.
      final byUrl = decode(await tool.execute({
        'action': 'listCalendarEvents',
        'params': {'query': 'secret-token'},
      }));
      expect((byUrl['events'] as List), isEmpty);
      final byHost = decode(await tool.execute({
        'action': 'listCalendarEvents',
        'params': {'query': 'zoom.us'},
      }));
      expect((byHost['events'] as List), isEmpty);
      // Title/location still match.
      final byTitle = decode(await tool.execute({
        'action': 'listCalendarEvents',
        'params': {'query': 'standup'},
      }));
      expect((byTitle['events'] as List).length, 1);
    });

    test('redacts scheme-less meeting hosts', () async {
      final tool = PhoneReadTool(
        transport: (action, params, {required allowed}) async => {
          'ok': true,
          'events': [
            {
              'id': 1,
              'title': 'Sync',
              'beginMillis': 1,
              'endMillis': 2,
              'description': 'Join zoom.us/j/123 or meet.google.com/abc-defg or '
                  'teams.microsoft.com/l/meetup-join/x or teams.live.com/meet/9',
            },
          ],
        },
      );
      final result =
          decode(await tool.execute({'action': 'listCalendarEvents'}));
      final description =
          ((result['events'] as List).single as Map)['description'] as String;
      expect(description, isNot(contains('zoom.us')));
      expect(description, isNot(contains('meet.google.com')));
      expect(description, isNot(contains('teams.microsoft.com')));
      expect(description, isNot(contains('teams.live.com')));
      expect(description, contains('[redacted-url]'));
    });

    test('a denied permission is a stable actionable error', () async {
      var calls = 0;
      final tool = PhoneReadTool(
        transport: (action, params, {required allowed}) async {
          calls += 1;
          return {
            'ok': false,
            'error': 'permission_required',
            'permission': 'READ_SMS',
          };
        },
      );
      final first = decode(await tool.execute({'action': 'listSms'}));
      final second = decode(await tool.execute({'action': 'listSms'}));
      expect(first['error'], 'permission_required');
      expect(first['permission'], 'READ_SMS');
      expect(first['fix'], contains('短信读取'));
      expect(second['error'], 'permission_required');
      expect(calls, 2);
    });

    test('every calendar, sms and contacts denial returns labelled guidance',
        () async {
      final prefs = await initPrefs(allowSms: true, allowPhoneCall: true);
      Future<Map<String, dynamic>> denied(
        String permission,
        Map<String, dynamic> input,
      ) async {
        final tool = input['action'] == 'listCalendarEvents' ||
                input['action'] == 'listSms' ||
                input['action'] == 'getSms' ||
                input['action'] == 'listContacts'
            ? PhoneReadTool(
                transport: (action, params, {required allowed}) async => {
                  'ok': false,
                  'error': 'permission_required',
                  'permission': permission,
                },
              )
            : input['action'] == 'callPhone' || input['action'] == 'sendSms'
                ? PhoneSendTool(
                    prefs,
                    transport: (action, params, {required allowed}) async => {
                      'ok': false,
                      'error': 'permission_required',
                      'permission': permission,
                    },
                  )
                : PhoneActTool(
                    transport: (action, params, {required allowed}) async => {
                      'ok': false,
                      'error': 'permission_required',
                      'permission': permission,
                    },
                  );
        return decode(await tool.execute(input));
      }

      const cases = <(Map<String, dynamic>, String, String)>[
        (
          {'action': 'listCalendarEvents'},
          'READ_CALENDAR',
          '日历读取',
        ),
        (
          {
            'action': 'insertCalendarEvent',
            'params': {'title': 'x', 'beginMillis': 1},
          },
          'WRITE_CALENDAR',
          '日历写入',
        ),
        (
          {'action': 'listSms'},
          'READ_SMS',
          '短信读取',
        ),
        (
          {
            'action': 'getSms',
            'params': {'id': 1},
          },
          'READ_SMS',
          '短信读取',
        ),
        (
          {'action': 'listContacts'},
          'READ_CONTACTS',
          '联系人读取',
        ),
        (
          {
            'action': 'callPhone',
            'params': {'number': '10086'},
          },
          'CALL_PHONE',
          '电话',
        ),
        (
          {
            'action': 'sendSms',
            'params': {'number': '10086', 'body': 'hi'},
          },
          'SEND_SMS',
          '短信发送',
        ),
      ];

      for (final (input, permission, label) in cases) {
        final result = await denied(permission, input);
        expect(result['error'], 'permission_required',
            reason: '${input['action']} must stay a permission error');
        expect(result['permission'], permission);
        expect(result['fix'], contains(label),
            reason: '${input['action']} must name the $label permission');
        expect(result['fix'], contains('系统设置'));
        expect(result['message'], contains('本次运行不再重复请求'));
      }
    });

    test('a permanently denied permission points at Settings', () async {
      final tool = PhoneReadTool(
        transport: (action, params, {required allowed}) async {
          return {
            'ok': false,
            'error': 'permission_permanently_denied',
            'permission': 'READ_CONTACTS',
            'settingsRequired': true,
          };
        },
      );
      final result = decode(await tool.execute({'action': 'listContacts'}));
      expect(result['error'], 'permission_permanently_denied');
      expect(result['settingsRequired'], isTrue);
      expect(result['fix'], contains('系统不会再弹出授权窗口'));
      expect(result['fix'], contains('联系人读取'));
      expect(result['message'], contains('永久拒绝'));
      expect(result['message'], contains('系统设置'));
    });

    test('filters by query and fetches the full window for filtering',
        () async {
      Map<String, dynamic>? captured;
      final tool = PhoneReadTool(
        transport: (action, params, {required allowed}) async {
          captured = params;
          return {
            'ok': true,
            'events': [
              {'id': 1, 'title': 'Standup', 'beginMillis': 1, 'endMillis': 2},
              {'id': 2, 'title': 'Lunch', 'beginMillis': 3, 'endMillis': 4},
            ],
          };
        },
      );
      final result = decode(await tool.execute({
        'action': 'listCalendarEvents',
        'params': {'query': 'standup'},
      }));
      expect((result['events'] as List).length, 1);
      expect(captured!['limit'], PhoneReadTool.maxCalendarLimit);
    });
  });

  group('phone_read contacts', () {
    test('caps the limit at 10 when no query is given', () async {
      Map<String, dynamic>? captured;
      final tool = PhoneReadTool(
        transport: (action, params, {required allowed}) async {
          captured = params;
          return {'ok': true, 'contacts': const []};
        },
      );
      await tool.execute({
        'action': 'listContacts',
        'params': {'limit': 999},
      });
      expect(captured!['limit'], PhoneReadTool.defaultContactsLimit);
      expect(captured!.containsKey('query'), false);
    });

    test('uses the queried default and max', () async {
      final limits = <int>[];
      final tool = PhoneReadTool(
        transport: (action, params, {required allowed}) async {
          limits.add(params['limit'] as int);
          expect(params['query'], 'ann');
          return {'ok': true, 'contacts': const []};
        },
      );
      await tool.execute({
        'action': 'listContacts',
        'params': {'query': 'ann'},
      });
      await tool.execute({
        'action': 'listContacts',
        'params': {'query': 'ann', 'limit': 999},
      });
      expect(limits, [
        PhoneReadTool.queriedContactsDefaultLimit,
        PhoneReadTool.queriedContactsMaxLimit,
      ]);
    });
  });

  group('phone_read sms', () {
    test('defaults and caps the limit and normalizes box', () async {
      Map<String, dynamic>? captured;
      final tool = PhoneReadTool(
        transport: (action, params, {required allowed}) async {
          captured = params;
          return {'ok': true, 'messages': const []};
        },
      );
      await tool.execute({
        'action': 'listSms',
        'params': {'limit': 999, 'box': 'sent', 'query': 'hi'},
      });
      expect(captured!['limit'], PhoneReadTool.maxSmsLimit);
      expect(captured!['box'], 'sent');
      expect(captured!['query'], 'hi');
    });

    test('getSms requires an id', () async {
      var called = false;
      final tool = PhoneReadTool(
        transport: (action, params, {required allowed}) async {
          called = true;
          return {'ok': true};
        },
      );
      final result = decode(await tool.execute({'action': 'getSms'}));
      expect(result['ok'], false);
      expect(result['error'], 'invalid_args');
      expect(called, false);
    });

    test('rejects unknown actions', () async {
      final tool = PhoneReadTool(
        transport: (action, params, {required allowed}) async => {'ok': true},
      );
      final result = decode(await tool.execute({'action': 'sendSms'}));
      expect(result['error'], 'invalid_args');
    });
  });

  group('phone_send', () {
    test('is disabled by default and never reaches native', () async {
      final prefs = await initPrefs();
      var called = false;
      final tool = PhoneSendTool(
        prefs,
        transport: (action, params, {required allowed}) async {
          called = true;
          return {'ok': true};
        },
      );
      final result = decode(await tool.execute({
        'action': 'sendSms',
        'params': {'number': '10086', 'body': 'hi'},
      }));
      expect(result['ok'], false);
      expect(result['error'], 'disabled_by_user');
      expect(called, false);
    });

    test('passes allowed:true once the setting is on', () async {
      final prefs = await initPrefs(allowSms: true);
      bool? allowedSeen;
      final tool = PhoneSendTool(
        prefs,
        transport: (action, params, {required allowed}) async {
          allowedSeen = allowed;
          return {'ok': true};
        },
      );
      final result = decode(await tool.execute({
        'action': 'sendSms',
        'params': {'number': '10086', 'body': 'hi'},
      }));
      expect(result['ok'], true);
      expect(allowedSeen, true);
    });

    test('a cancelled confirmation fails closed, not as success', () async {
      final prefs = await initPrefs(allowSms: true);
      final tool = PhoneSendTool(
        prefs,
        transport: (action, params, {required allowed}) async => {
          'ok': false,
          'error': 'cancelled',
          'message': 'SMS send cancelled by user',
        },
      );
      final output = await tool.execute({
        'action': 'sendSms',
        'params': {'number': '10086', 'body': 'hi'},
      });
      final result = decode(output);
      expect(result['ok'], false);
      expect(result['error'], 'cancelled');
      expect(PhoneToolBase.isFailureOutput(output), true);
    });
  });

  test('phone_act never gates on outbound settings', () async {
    var allowedSeen = true;
    final tool = PhoneActTool(
      transport: (action, params, {required allowed}) async {
        allowedSeen = allowed;
        return {'ok': true};
      },
    );
    await tool.execute({
      'action': 'setAlarm',
      'params': {'hour': 7}
    });
    expect(allowedSeen, false);
  });

  test('registry advertises the split tools and hides phone_intent', () async {
    final prefs = await initPrefs();
    final registry = ToolRegistry.withDefaults(prefs: prefs);
    final names = registry.getToolDefinitions().map((t) => t.name).toList();
    expect(names, contains('phone_read'));
    expect(names, contains('phone_act'));
    // §7.5: send is omitted while both outbound settings are off.
    expect(names, isNot(contains('phone_send')));
    expect(names, isNot(contains('phone_intent')));
    expect(registry.hasTool('phone_intent'), true);
    expect(registry.isHidden('phone_intent'), true);
    // Hidden tools stay resolvable for a replayed transcript.
    expect(registry.hasTool('phone_send'), true);
    expect(registry.availableTools, isNot(contains('phone_intent')));
    expect(registry.availableTools, isNot(contains('phone_send')));
  });

  test('registry advertises phone_send once one outbound setting is on',
      () async {
    final prefs = await initPrefs(allowSms: true);
    final registry = ToolRegistry.withDefaults(prefs: prefs);
    final names = registry.getToolDefinitions().map((t) => t.name).toList();
    expect(names, contains('phone_send'));
    // The other action still fails closed at call time.
    expect(prefs.allowPhoneCall, false);
  });

  test('PhoneIntentTool still carries the app channel name', () {
    expect(AppConstants.channelName, isNotEmpty);
  });
}
