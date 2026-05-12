import 'dart:convert';

import '../native_bridge.dart';
import '../preferences_service.dart';
import 'tool_registry.dart';

class PhoneIntentTool extends Tool {
  final PreferencesService _prefs;

  PhoneIntentTool(this._prefs);

  @override
  String get name => 'phone_intent';

  @override
  String get description =>
      'Interact with the host Android phone. Use this to set alarms, add calendar events, '
      'open URLs, share text, navigate maps, compose email, dial, list contacts/calendar, etc. '
      'Pick the right `action`; pass parameters in `params`.\n\n'
      'Available actions:\n'
      '- setAlarm {hour:int, minutes:int, message?:str, skipUi?:bool}\n'
      '- openWeb {url:str}\n'
      '- dialPad {number:str}                 # opens dialer, does NOT auto-call\n'
      '- share {text:str, subject?:str}\n'
      '- mapsNavigate {query:str}\n'
      '- composeEmail {to?:str, subject?:str, body?:str}\n'
      '- openCamera {}\n'
      '- addCalendarEventIntent {title:str, beginMillis?:int, endMillis?:int, location?:str, description?:str}  # opens calendar UI\n'
      '- insertCalendarEvent {title:str, beginMillis:int, endMillis?:int, location?:str, description?:str}      # writes directly (asks WRITE_CALENDAR)\n'
      '- listCalendarEvents {startMillis?:int, endMillis?:int, limit?:int}                                       # asks READ_CALENDAR\n'
      '- listContacts {query?:str, limit?:int}                                                                   # asks READ_CONTACTS\n'
      '- callPhone {number:str}    # gated by user setting; off by default\n'
      '- sendSms {number:str, body:str}    # gated by user setting; off by default\n\n'
      'All time values are unix epoch milliseconds (Asia/Shanghai-aware via system tz). '
      'Returns JSON with `ok` (bool) and either result fields or `error`/`message`.';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'action': {
        'type': 'string',
        'description': 'The action to perform (see tool description for the full list).',
      },
      'params': {
        'type': 'object',
        'description': 'Action-specific parameters.',
      },
    },
    'required': ['action'],
  };

  static const _restrictedActions = {'callPhone', 'sendSms'};

  @override
  Future<String> execute(Map<String, dynamic> input) async {
    final action = input['action'] as String?;
    if (action == null || action.isEmpty) {
      return jsonEncode({'ok': false, 'error': 'invalid_args', 'message': 'action required'});
    }
    if (_restrictedActions.contains(action)) {
      final allowed = (action == 'callPhone' && _prefs.allowPhoneCall) ||
          (action == 'sendSms' && _prefs.allowSms);
      if (!allowed) {
        return jsonEncode({
          'ok': false,
          'error': 'disabled_by_user',
          'message': 'Action `$action` is disabled. The user must enable it in '
              'Settings → Phone integration before this can be used.',
        });
      }
    }
    final params = (input['params'] as Map?)?.cast<String, dynamic>() ?? const {};
    try {
      final result = await NativeBridge.phoneIntent(action, params);
      return jsonEncode(result);
    } catch (e) {
      return jsonEncode({'ok': false, 'error': 'exception', 'message': e.toString()});
    }
  }
}
