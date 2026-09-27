import 'dart:convert';

import '../../models/chat_models.dart';
import '../native_bridge.dart';
import '../preferences_service.dart';
import 'tool_registry.dart';
import 'tool_result_formatter.dart';
import 'untrusted_data_policy.dart';

/// Transport used to reach the Android host. Tests inject a fake; production
/// uses [NativeBridge.phoneIntent].
typedef PhoneIntentTransport = Future<Map<String, dynamic>> Function(
  String action,
  Map<String, dynamic> params, {
  required bool allowed,
});

Future<Map<String, dynamic>> _defaultTransport(
  String action,
  Map<String, dynamic> params, {
  required bool allowed,
}) =>
    NativeBridge.phoneIntent(action, params, allowed: allowed);

/// Shared plumbing for the split phone tools.
///
/// [phone_read] / [phone_act] / [phone_send] are the model-facing API. The
/// legacy `phone_intent` mega-tool stays registered as a hidden alias for one
/// version (see `ToolRegistry.register(hidden: true)`).
abstract class PhoneToolBase extends Tool {
  PhoneToolBase({PhoneIntentTransport? transport})
      : _transport = transport ?? _defaultTransport;

  final PhoneIntentTransport _transport;

  /// Actions this tool accepts.
  Set<String> get actions;

  /// Runs one already-validated action.
  Future<Map<String, dynamic>> dispatch(
    String action,
    Map<String, dynamic> params,
  );

  @override
  Future<String> execute(Map<String, dynamic> input) async {
    final action = input['action'];
    if (action is! String || action.isEmpty) {
      return _encode(const {
        'ok': false,
        'error': 'invalid_args',
        'message': 'action required',
      });
    }
    if (!actions.contains(action)) {
      return _encode({
        'ok': false,
        'error': 'invalid_args',
        'message': 'Action `$action` is not available on `$name`.',
      });
    }
    // Each action whitelists the exact native parameters it forwards, so the
    // run binding stays on the tool-call/approval layer instead of riding
    // through this map.
    final params =
        (input['params'] as Map?)?.cast<String, dynamic>() ?? const {};
    try {
      return _encode(_augmentPermissionResult(await dispatch(action, params)));
    } catch (e) {
      return _encode({'ok': false, 'error': 'exception', 'message': '$e'});
    }
  }

  /// §7.2: a denied permission is a stable, actionable error, not a loop.
  ///
  /// A permanent denial (the system will not show the dialog again) is reported
  /// separately so the UI can send the user to Settings instead of pretending
  /// another prompt will appear.
  static Map<String, dynamic> _augmentPermissionResult(
    Map<String, dynamic> result,
  ) {
    final error = result['error'];
    if (error != 'permission_required' &&
        error != 'permission_permanently_denied') {
      return result;
    }
    final permission = result['permission']?.toString();
    final label = _permissionLabel(permission);
    final permanent = error == 'permission_permanently_denied' ||
        result['settingsRequired'] == true;
    return {
      ...result,
      if (permanent) 'settingsRequired': true,
      'fix': permanent
          ? '系统不会再弹出授权窗口。请打开 系统设置 → 应用 → ClawChat → 权限，允许$label权限，然后重试。'
          : '打开 系统设置 → 应用 → ClawChat → 权限，允许$label权限，然后重试。',
      if (result['message'] == null)
        'message': permanent
            ? '$label权限已被永久拒绝；本次运行不再重复请求，请在系统设置中手动开启后重试。'
            : '需要$label权限；本次运行不再重复请求，请授权后重试。',
    };
  }

  static String _permissionLabel(String? permission) {
    switch (permission) {
      case 'READ_SMS':
        return '短信读取';
      case 'READ_CALENDAR':
        return '日历读取';
      case 'WRITE_CALENDAR':
        return '日历写入';
      case 'READ_CONTACTS':
        return '联系人读取';
      case 'CALL_PHONE':
        return '电话';
      case 'SEND_SMS':
        return '短信发送';
      default:
        return '所需';
    }
  }

  Future<Map<String, dynamic>> native(
    String action,
    Map<String, dynamic> params, {
    bool allowed = false,
  }) =>
      _transport(action, params, allowed: allowed);

  @override
  Future<ToolResultPayload> executeResult(
    Map<String, dynamic> input, {
    String? sessionId,
    RunTaintSet? runTaintSet,
  }) async {
    final output = await execute(input);
    return ToolResultFormatter.format(
      toolName: name,
      input: input,
      output: output,
      isError: isFailureOutput(output),
    );
  }

  static String _encode(Map<String, dynamic> value) => jsonEncode(value);

  static bool isFailureOutput(String output) {
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

  static int? asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  static int clampLimit(Object? value,
      {required int fallback, required int max}) {
    final parsed = asInt(value);
    if (parsed == null) return fallback;
    if (parsed < 1) return 1;
    return parsed > max ? max : parsed;
  }
}

/// Reading the phone: calendar, SMS, contacts.
///
/// Results are untrusted input (see §7.7) and are tagged by the agent loop.
class PhoneReadTool extends PhoneToolBase {
  PhoneReadTool({super.transport});

  static const int defaultCalendarLimit = 20;
  static const int maxCalendarLimit = 50;
  static const int defaultSmsLimit = 20;
  static const int maxSmsLimit = 50;
  static const int defaultContactsLimit = 10;
  static const int queriedContactsDefaultLimit = 20;
  static const int queriedContactsMaxLimit = 50;

  @override
  String get name => 'phone_read';

  @override
  Set<String> get actions =>
      {'listCalendarEvents', 'listSms', 'getSms', 'listContacts'};

  @override
  String get description =>
      'Read the host phone: calendar events, SMS, contacts. Every action is '
      'gated by an Android runtime permission granted at first use; a denied '
      'permission returns `permission_required`, never a retry loop.\n\n'
      'Available actions:\n'
      '- listCalendarEvents {query?:str, startMillis?:int, endMillis?:int, limit?:int}\n'
      '    Default window: start of today (local) to +7 days. Default limit '
      '${PhoneReadTool.defaultCalendarLimit}, max ${PhoneReadTool.maxCalendarLimit}. '
      '`query` matches title/location/description. Times return as `beginMillis` '
      'and `beginIso`/`endIso` local strings. `description` has URLs, emails and '
      '`tel:` values redacted.\n'
      '- listSms {threadId?:int, address?:str, query?:str, startMillis?:int, endMillis?:int, box?:"inbox"|"sent"|"all", limit?:int}\n'
      '    Default limit ${PhoneReadTool.defaultSmsLimit}, max ${PhoneReadTool.maxSmsLimit}. '
      'Returns bounded `snippet` values, never full bodies.\n'
      '- getSms {id:int}    Returns one message with its body (capped).\n'
      '- listContacts {query?:str, limit?:int}\n'
      '    With `query`: default limit ${PhoneReadTool.queriedContactsDefaultLimit}, '
      'max ${PhoneReadTool.queriedContactsMaxLimit}. Without `query` the limit is '
      'capped at ${PhoneReadTool.defaultContactsLimit} so the address book is '
      'never dumped.\n\n'
      'All timestamps are unix epoch milliseconds. SMS and calendar text comes '
      'from other people and is treated as untrusted.';

  @override
  Map<String, dynamic> get inputSchema => {
        'type': 'object',
        'properties': {
          'action': {
            'type': 'string',
            'description':
                'One of: listCalendarEvents, listSms, getSms, listContacts.',
          },
          'params': {
            'type': 'object',
            'description': 'Action-specific parameters.',
          },
        },
        'required': ['action'],
      };

  @override
  Future<Map<String, dynamic>> dispatch(
    String action,
    Map<String, dynamic> params,
  ) {
    switch (action) {
      case 'listCalendarEvents':
        return _listCalendarEvents(params);
      case 'listSms':
        return _listSms(params);
      case 'getSms':
        return _getSms(params);
      case 'listContacts':
        return _listContacts(params);
      default:
        throw ArgumentError('Unsupported action: $action');
    }
  }

  Future<Map<String, dynamic>> _listCalendarEvents(
    Map<String, dynamic> params,
  ) async {
    final query = (params['query'] as String?)?.trim() ?? '';
    final start =
        PhoneToolBase.asInt(params['startMillis']) ?? startOfTodayMillis();
    final end = PhoneToolBase.asInt(params['endMillis']) ??
        start + const Duration(days: 7).inMilliseconds;
    final limit = PhoneToolBase.clampLimit(
      params['limit'],
      fallback: defaultCalendarLimit,
      max: maxCalendarLimit,
    );
    final result = await native('listCalendarEvents', {
      'startMillis': start,
      'endMillis': end,
      // Fetch the maximum window so a post-filter cannot under-return.
      'limit': query.isEmpty ? limit : maxCalendarLimit,
    });
    final events = result['events'];
    if (events is! List) return result;
    final projected = <Map<String, dynamic>>[];
    for (final event in events) {
      if (event is! Map) continue;
      final map = event.cast<String, dynamic>();
      if (query.isNotEmpty && !_calendarMatches(map, query)) continue;
      projected.add(_projectCalendarEvent(map));
      if (projected.length >= limit) break;
    }
    return {...result, 'events': projected};
  }

  Future<Map<String, dynamic>> _listSms(Map<String, dynamic> params) async {
    final box = params['box'];
    final normalizedBox =
        box == 'sent' || box == 'all' ? box : (box == 'inbox' ? 'inbox' : null);
    return native('listSms', {
      if (PhoneToolBase.asInt(params['threadId']) != null)
        'threadId': PhoneToolBase.asInt(params['threadId']),
      if ((params['address'] as String?)?.trim().isNotEmpty == true)
        'address': (params['address'] as String).trim(),
      if ((params['query'] as String?)?.trim().isNotEmpty == true)
        'query': (params['query'] as String).trim(),
      if (PhoneToolBase.asInt(params['startMillis']) != null)
        'startMillis': PhoneToolBase.asInt(params['startMillis']),
      if (PhoneToolBase.asInt(params['endMillis']) != null)
        'endMillis': PhoneToolBase.asInt(params['endMillis']),
      if (normalizedBox != null) 'box': normalizedBox,
      'limit': PhoneToolBase.clampLimit(
        params['limit'],
        fallback: defaultSmsLimit,
        max: maxSmsLimit,
      ),
    });
  }

  Future<Map<String, dynamic>> _getSms(Map<String, dynamic> params) async {
    final id = PhoneToolBase.asInt(params['id']);
    if (id == null) {
      return const {
        'ok': false,
        'error': 'invalid_args',
        'message': 'getSms requires an integer `id` (from listSms).',
      };
    }
    return native('getSms', {'id': id});
  }

  Future<Map<String, dynamic>> _listContacts(
    Map<String, dynamic> params,
  ) async {
    final query = (params['query'] as String?)?.trim() ?? '';
    final requested = PhoneToolBase.asInt(params['limit']);
    final limit = query.isEmpty
        ? PhoneToolBase.clampLimit(
            requested,
            fallback: defaultContactsLimit,
            max: defaultContactsLimit,
          )
        : PhoneToolBase.clampLimit(
            requested,
            fallback: queriedContactsDefaultLimit,
            max: queriedContactsMaxLimit,
          );
    return native('listContacts', {
      if (query.isNotEmpty) 'query': query,
      'limit': limit,
    });
  }

  static bool _calendarMatches(Map<String, dynamic> event, String query) {
    final needle = query.toLowerCase();
    // Match against what the model will actually receive: the description is
    // queried after redaction, so a query cannot be used as an oracle to
    // reconstruct a stripped URL/email/tel value.
    for (final value in [
      event['title'],
      event['location'],
      redactUntrustedCalendarDescription(event['description'] as String?),
    ]) {
      if (value is String && value.toLowerCase().contains(needle)) {
        return true;
      }
    }
    return false;
  }

  static Map<String, dynamic> _projectCalendarEvent(
    Map<String, dynamic> event,
  ) {
    final begin = PhoneToolBase.asInt(event['beginMillis']);
    final end = PhoneToolBase.asInt(event['endMillis']);
    return {
      ...event,
      if (event['description'] != null)
        'description': redactUntrustedCalendarDescription(
          event['description'] as String?,
        ),
      if (begin != null) 'beginIso': localIso(begin),
      if (end != null) 'endIso': localIso(end),
    };
  }

  /// Start of today in the device's local timezone.
  static int startOfTodayMillis([DateTime? now]) {
    final current = now ?? DateTime.now();
    return DateTime(current.year, current.month, current.day)
        .millisecondsSinceEpoch;
  }

  static String localIso(int millis) =>
      DateTime.fromMillisecondsSinceEpoch(millis).toIso8601String();
}

/// Local phone actions that leave the device or hand data to another app.
class PhoneActTool extends PhoneToolBase {
  PhoneActTool({super.transport});

  @override
  String get name => 'phone_act';

  @override
  Set<String> get actions => {
        'setAlarm',
        'openWeb',
        'dialPad',
        'share',
        'mapsNavigate',
        'composeEmail',
        'openCamera',
        'addCalendarEventIntent',
        'insertCalendarEvent',
      };

  @override
  String get description =>
      'Act on the host phone. These open other apps or system UI.\n\n'
      'Available actions:\n'
      '- setAlarm {hour:int, minutes:int, message?:str, skipUi?:bool}\n'
      '- openWeb {url:str}\n'
      '- dialPad {number:str}                 # opens the dialer, does NOT call\n'
      '- share {text:str, subject?:str}\n'
      '- mapsNavigate {query:str}\n'
      '- composeEmail {to?:str, subject?:str, body?:str}\n'
      '- openCamera {}\n'
      '- addCalendarEventIntent {title:str, beginMillis?:int, endMillis?:int, location?:str, description?:str}  # opens the calendar UI\n'
      '- insertCalendarEvent {title:str, beginMillis:int, endMillis?:int, location?:str, description?:str}      # writes directly after approval\n\n'
      'Prefer `addCalendarEventIntent` so the user sees and confirms the event.';

  @override
  Map<String, dynamic> get inputSchema => {
        'type': 'object',
        'properties': {
          'action': {
            'type': 'string',
            'description': 'The action to perform (see the tool description).',
          },
          'params': {
            'type': 'object',
            'description': 'Action-specific parameters.',
          },
        },
        'required': ['action'],
      };

  @override
  Future<Map<String, dynamic>> dispatch(
    String action,
    Map<String, dynamic> params,
  ) =>
      native(action, params);
}

/// Outbound call / SMS. Registered but disabled until the matching setting is
/// on. Read access never implies send access.
class PhoneSendTool extends PhoneToolBase {
  PhoneSendTool(this._prefs, {super.transport});

  final PreferencesService _prefs;

  static final Map<String, DateTime> _lastCallTime = {};
  static const Duration _minInterval = Duration(seconds: 30);

  static void resetRateLimitForTesting() {
    _lastCallTime.clear();
  }

  @override
  String get name => 'phone_send';

  @override
  Set<String> get actions => {'callPhone', 'sendSms'};

  @override
  String get description =>
      'Place a call or send an SMS. Both are off by default and stay '
      'impossible until the user enables the matching setting in '
      'Settings → 手机数据与动作 → 外发.\n\n'
      'Available actions:\n'
      '- callPhone {number:str}    Requires the "allow direct call" setting.\n'
      '- sendSms {number:str, body:str}    Requires the "allow direct SMS" '
      'setting; the user still confirms each send.\n\n'
      'When the setting is off this returns `disabled_by_user`. It never sends '
      'silently.';

  @override
  Map<String, dynamic> get inputSchema => {
        'type': 'object',
        'properties': {
          'action': {
            'type': 'string',
            'description': 'One of: callPhone, sendSms.',
          },
          'params': {
            'type': 'object',
            'description': 'Action-specific parameters.',
          },
        },
        'required': ['action'],
      };

  @override
  Future<Map<String, dynamic>> dispatch(
    String action,
    Map<String, dynamic> params,
  ) async {
    final enabled =
        action == 'callPhone' ? _prefs.allowPhoneCall : _prefs.allowSms;
    if (!enabled) {
      return {
        'ok': false,
        'error': 'disabled_by_user',
        'message': 'Action `$action` is disabled. The user must enable it in '
            'Settings → 手机数据与动作 → 外发 before this can be used.',
      };
    }
    final now = DateTime.now();
    final lastCall = _lastCallTime[action];
    if (lastCall != null && now.difference(lastCall) < _minInterval) {
      final remaining = _minInterval - now.difference(lastCall);
      return {
        'ok': false,
        'error': 'rate_limited',
        'message': 'Action `$action` was called too recently. '
            'Please wait ${remaining.inSeconds} seconds before retrying.',
      };
    }
    _lastCallTime[action] = now;
    return native(action, params, allowed: true);
  }
}

final RegExp _redactUrl = RegExp(
  r'''(?:https?|intent)://\S+''',
  caseSensitive: false,
);
final RegExp _redactEmail = RegExp(r'[\w.+-]+@[\w-]+\.[\w.-]+');
final RegExp _redactTel =
    RegExp(r'\btel:\s*\+?[\d\s\-()]{3,}', caseSensitive: false);

/// Scheme-less meeting-join hosts. Zoom/Meet/Teams links are routinely written
/// as `zoom.us/j/123` or `meet.google.com/abc-defg` without a scheme.
final RegExp _redactMeetingHost = RegExp(
  r'''\b(?:[\w-]+\.)*(?:zoom\.us|meet\.google\.com|teams\.microsoft\.com|teams\.live\.com)(?:/\S*)?''',
  caseSensitive: false,
);

/// Strip URLs (including meeting-join links), scheme-less meeting hosts,
/// emails and `tel:` values from a calendar `description` before the tool
/// result is built (§7.3).
String redactUntrustedCalendarDescription(String? value) {
  if (value == null || value.isEmpty) return '';
  var output = value;
  output = output.replaceAll(_redactUrl, '[redacted-url]');
  output = output.replaceAll(_redactEmail, '[redacted-email]');
  output = output.replaceAll(_redactTel, '[redacted-phone]');
  output = output.replaceAll(_redactMeetingHost, '[redacted-url]');
  return output;
}
