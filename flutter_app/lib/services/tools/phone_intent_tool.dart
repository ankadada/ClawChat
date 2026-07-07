import 'dart:convert';

import '../../models/chat_models.dart';
import '../native_bridge.dart';
import '../preferences_service.dart';
import 'tool_registry.dart';
import 'tool_result_formatter.dart';

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
            'description':
                'The action to perform (see tool description for the full list).',
          },
          'params': {
            'type': 'object',
            'description': 'Action-specific parameters.',
          },
        },
        'required': ['action'],
      };

  static const _restrictedActions = {'callPhone', 'sendSms'};
  static final Map<String, DateTime> _lastCallTime = {};
  static const _minInterval = Duration(seconds: 30);

  static void resetRateLimitForTesting() {
    _lastCallTime.clear();
  }

  @override
  Future<String> execute(Map<String, dynamic> input) async {
    final action = input['action'] as String?;
    if (action == null || action.isEmpty) {
      return jsonEncode(
          {'ok': false, 'error': 'invalid_args', 'message': 'action required'});
    }

    final isRestricted = _restrictedActions.contains(action);

    if (isRestricted) {
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

      // Rate limit restricted actions
      final now = DateTime.now();
      final lastCall = _lastCallTime[action];
      if (lastCall != null && now.difference(lastCall) < _minInterval) {
        final remaining = _minInterval - now.difference(lastCall);
        return jsonEncode({
          'ok': false,
          'error': 'rate_limited',
          'message': 'Action `$action` was called too recently. '
              'Please wait ${remaining.inSeconds} seconds before retrying.',
        });
      }
      _lastCallTime[action] = now;
    }

    final params =
        (input['params'] as Map?)?.cast<String, dynamic>() ?? const {};
    try {
      final result =
          await NativeBridge.phoneIntent(action, params, allowed: isRestricted);
      return jsonEncode(result);
    } catch (e) {
      return jsonEncode(
          {'ok': false, 'error': 'exception', 'message': e.toString()});
    }
  }

  @override
  Future<ToolResultPayload> executeResult(
    Map<String, dynamic> input, {
    String? sessionId,
  }) async {
    final output = await executeWithContext(input, sessionId: sessionId);
    return ToolResultFormatter.format(
      toolName: name,
      input: input,
      output: output,
      isError: _isFailureOutput(output),
    );
  }

  static bool _isFailureOutput(String output) {
    try {
      final decoded = jsonDecode(output);
      if (decoded is Map<String, dynamic>) {
        if (decoded['ok'] == false) return true;
        return decoded['ok'] != true && decoded['error'] != null;
      }
    } catch (_) {
      return false;
    }
    return false;
  }
}
