import 'dart:convert';

import '../../models/chat_models.dart';
import 'tool_policy.dart';

/// Where an untrusted value came from. The deny rules differ by source.
/// Tools whose results are attacker-controlled text.
///
/// `phone_read` carries SMS/calendar/contact bodies, `web_fetch`/
/// `web_search` carry remote page text, and every `mcp_*` tool carries
/// third-party server output. Phone *act*/*send* results are local
/// acknowledgements and stay trusted.
const Set<String> untrustedResultToolNames = {
  'phone_read',
  'web_fetch',
  'web_search',
};

bool isUntrustedResultTool(String toolName) =>
    untrustedResultToolNames.contains(toolName) || toolName.startsWith('mcp_');

String resultTrustForTool(String toolName) => isUntrustedResultTool(toolName)
    ? ToolResultTrust.untrusted
    : ToolResultTrust.trusted;

UntrustedSource resultSourceForTool(String toolName) {
  if (toolName == 'phone_read') return UntrustedSource.phone;
  if (toolName.startsWith('mcp_')) return UntrustedSource.mcp;
  return UntrustedSource.web;
}

enum UntrustedSource {
  phone,
  web,
  mcp,
}

/// What a tainted extracted value is, so the matcher can tell a destination
/// (URL or host) from a bare phone number or email address.
enum UntrustedValueKind {
  url,
  host,
  email,
  phone,
}

/// Run-scoped set of exact values (URLs, hosts, emails, phone numbers)
/// extracted from untrusted tool results in the current agent run.
///
/// It is deliberately a small mutable object held beside the run, not a new
/// field on `ToolApprovalRequest`.
class RunTaintSet {
  final Map<String, UntrustedSource> _values = {};
  final Map<String, UntrustedValueKind> _kinds = {};
  final Set<String> _userTyped = {};

  /// Workspace paths written from untrusted content in this run only.
  final Map<String, UntrustedSource> _taintedPaths = {};

  bool get isEmpty => _values.isEmpty && _taintedPaths.isEmpty;

  int get length => _values.length;

  Map<String, UntrustedSource> get values => Map.unmodifiable(_values);

  Map<String, UntrustedSource> get taintedPaths =>
      Map.unmodifiable(_taintedPaths);

  /// Record that [path] now holds content from untrusted tool data.
  ///
  /// Path taint is run-scoped: a new run starts from an empty set, so a file
  /// written in an earlier run is not automatically untrusted later.
  void markPathTainted(String path, UntrustedSource source) {
    final normalized = normalizeWorkspacePath(path);
    if (normalized == null) return;
    final existing = _taintedPaths[normalized];
    if (existing == null || _strictness(source) > _strictness(existing)) {
      _taintedPaths[normalized] = source;
    }
  }

  /// The source for a tainted workspace [path], or null when it is clean.
  UntrustedSource? sourceForPath(String path) {
    final normalized = normalizeWorkspacePath(path);
    if (normalized == null) return null;
    return _taintedPaths[normalized];
  }

  /// Whether [command] reads a workspace path tainted in this run.
  bool commandReadsTaintedPath(String command) {
    if (_taintedPaths.isEmpty) return false;
    final haystack = command.replaceAll(RegExp(r'''["']'''), '');
    return _taintedPaths.keys.any(haystack.contains);
  }

  /// Values the user typed themselves; these clear taint for the run.
  void addUserTypedText(String text) {
    _userTyped.addAll(extractValues(text));
  }

  /// Extract values from one untrusted tool result and record them.
  ///
  /// A value the user already typed is not tainted. The first source wins so a
  /// later web result cannot downgrade a phone-sourced value.
  void addPayload(String text, {required UntrustedSource source}) {
    for (final entry in extractValuesWithKinds(text).entries) {
      final value = entry.key;
      if (_userTyped.contains(value)) continue;
      final existing = _values[value];
      if (existing == null || _strictness(source) > _strictness(existing)) {
        _values[value] = source;
      }
      final existingKind = _kinds[value];
      if (existingKind == null ||
          _kindStrictness(entry.value) > _kindStrictness(existingKind)) {
        _kinds[value] = entry.value;
      }
    }
  }

  /// Source for [value] when it is tainted and not user-typed.
  UntrustedSource? sourceFor(String value) {
    final key = value.toLowerCase();
    if (_userTyped.contains(key)) return null;
    return _values[key];
  }

  /// Source for the first tainted value contained in [candidate].
  ///
  /// Substring matching is the 2.9.0 bar: an SMS that says `go to evil.example`
  /// blocks a later `https://evil.example` argument because the extracted host
  /// is contained in it.
  UntrustedSource? matchIn(String candidate) {
    if (candidate.isEmpty) return null;
    final haystack = canonicalize(candidate).toLowerCase();
    UntrustedSource? found;
    for (final entry in _values.entries) {
      if (entry.key.isEmpty) continue;
      if (haystack.contains(entry.key)) {
        // phone and mcp are the stricter sources: keep the strictest match.
        if (found == null || _strictness(entry.value) > _strictness(found)) {
          found = entry.value;
        }
      }
    }
    return found;
  }

  /// Source for the first tainted value contained in [candidate] that is a
  /// destination (a URL or a hostname).
  ///
  /// Used for the 2.9.0 "unknown binary" rule: a command that is not one of the
  /// named network programs fails closed only when its arguments carry a tainted
  /// URL or host. A bare tainted phone number or email in an unrelated command
  /// is not by itself treated as an outbound destination.
  UntrustedSource? matchUrlOrHostIn(String candidate) {
    if (candidate.isEmpty) return null;
    final haystack = canonicalize(candidate).toLowerCase();
    UntrustedSource? found;
    for (final entry in _values.entries) {
      if (entry.key.isEmpty) continue;
      final kind = _kinds[entry.key];
      if (kind != UntrustedValueKind.url && kind != UntrustedValueKind.host) {
        continue;
      }
      if (haystack.contains(entry.key)) {
        if (found == null || _strictness(entry.value) > _strictness(found)) {
          found = entry.value;
        }
      }
    }
    return found;
  }

  /// Clear one confirmed value (an Ask card that showed the exact value).
  void clearValue(String value) {
    final key = value.toLowerCase();
    _values.remove(key);
    _kinds.remove(key);
  }

  /// Clear web-sourced tainted values contained in a user-confirmed value.
  ///
  /// Called when the user approves the web→web Ask card that shows the exact
  /// URL, so the confirmed destination is usable for the rest of the run.
  void clearWebContainedIn(String candidate) {
    final haystack = candidate.toLowerCase();
    _values.removeWhere(
      (key, source) =>
          source == UntrustedSource.web && haystack.contains(key),
    );
    _kinds.removeWhere((key, _) => !_values.containsKey(key));
  }

  void clear() {
    _values.clear();
    _kinds.clear();
    _userTyped.clear();
    _taintedPaths.clear();
  }

  static int _kindStrictness(UntrustedValueKind kind) => switch (kind) {
        UntrustedValueKind.url => 4,
        UntrustedValueKind.host => 3,
        UntrustedValueKind.email => 2,
        UntrustedValueKind.phone => 1,
      };

  static int _strictness(UntrustedSource source) => switch (source) {
        UntrustedSource.phone => 2,
        UntrustedSource.mcp => 2,
        UntrustedSource.web => 1,
      };

  static final RegExp _urlPattern = RegExp(
    r'''(?:https?|intent)://[^\s"'<>()\[\]{}]+''',
    caseSensitive: false,
  );
  static final RegExp _emailPattern =
      RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}');
  static final RegExp _phonePattern =
      RegExp(r'(?:\+?\d[\d\s\-()]{6,}\d)');
  static final RegExp _hostPattern =
      RegExp(r'\b(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}\b');
  static final RegExp _trailingPunctuation = RegExp(r'''[.,;:!?)\]}"'']+$''');

  /// Extract the comparable value set from [text]: full URLs, hosts, emails,
  /// `tel:` numbers and bare phone numbers.
  static Set<String> extractValues(String text) =>
      extractValuesWithKinds(text).keys.toSet();

  /// Extract the comparable value set from [text] along with what each value is
  /// (URL, host, email, or phone number).
  static Map<String, UntrustedValueKind> extractValuesWithKinds(String text) {
    final values = <String, UntrustedValueKind>{};
    void add(String value, UntrustedValueKind kind) {
      final key = value.toLowerCase();
      if (key.length < 3) return;
      final existing = values[key];
      if (existing == null || _kindStrictness(kind) > _kindStrictness(existing)) {
        values[key] = kind;
      }
    }

    for (final match in _urlPattern.allMatches(text)) {
      final raw = _trim(match.group(0)!);
      if (raw.isEmpty) continue;
      add(raw, UntrustedValueKind.url);
      final host = Uri.tryParse(raw)?.host.toLowerCase() ?? '';
      if (host.isNotEmpty) add(host, UntrustedValueKind.host);
    }
    for (final match in _emailPattern.allMatches(text)) {
      add(_trim(match.group(0)!), UntrustedValueKind.email);
    }
    for (final match in _phonePattern.allMatches(text)) {
      final raw = _trim(match.group(0)!);
      final digits = _digits(raw);
      if (digits.length >= 7) {
        add(digits, UntrustedValueKind.phone);
        add(raw, UntrustedValueKind.phone);
      }
    }
    for (final match in _hostPattern.allMatches(text.toLowerCase())) {
      add(_trim(match.group(0)!), UntrustedValueKind.host);
    }
    return values;
  }

  static String _digits(String value) =>
      value.replaceAll(RegExp(r'\D'), '');

  /// Canonicalize a tool-argument string before matching.
  ///
  /// 2.9.0 closes three cheap obfuscations of the *same* value:
  /// - percent-encoding (`https%3A%2F%2Fevil.example`)
  /// - one base64 layer: an argument passed to `base64 -d` / `--decode`, or a
  ///   single argument that decodes to text containing a URL, host, email, or
  ///   phone number
  /// - quote-splitting that removes empty strings (`evil.exam""ple`)
  ///
  /// Only **one** layer is decoded. Nested encoding is out of scope and is not
  /// claimed to be covered.
  static String canonicalize(String candidate) {
    final variants = <String>{candidate};
    final percent = _decodePercent(candidate);
    if (percent != null) variants.add(percent);
    final unsplit = candidate.replaceAll(RegExp(r'''(""|'')'''), '');
    if (unsplit != candidate) {
      variants.add(unsplit);
      final unsplitPercent = _decodePercent(unsplit);
      if (unsplitPercent != null) variants.add(unsplitPercent);
    }
    for (final source in variants.toList()) {
      for (final decoded in _decodeBase64Candidates(source)) {
        variants.add(decoded);
      }
    }
    return variants.join('\n');
  }

  static String? _decodePercent(String value) {
    if (!value.contains('%')) return null;
    try {
      final decoded = Uri.decodeComponent(value);
      return decoded == value ? null : decoded;
    } catch (_) {
      return null;
    }
  }

  static final RegExp _base64Token = RegExp(r'[A-Za-z0-9+/_=-]{12,}');

  /// One base64 layer from [value], only when it decodes to something that
  /// actually contains a URL, host, email, or phone number.
  static Iterable<String> _decodeBase64Candidates(String value) sync* {
    for (final match in _base64Token.allMatches(value)) {
      final token = match.group(0)!;
      final decoded = _tryDecodeBase64(token);
      if (decoded == null || decoded.isEmpty) continue;
      if (extractValuesWithKinds(decoded).isEmpty) continue;
      yield decoded;
    }
  }

  static String? _tryDecodeBase64(String token) {
    final normalized = token.replaceAll('-', '+').replaceAll('_', '/');
    final padded = normalized.padRight(
        (normalized.length + 3) & ~3, '=');
    for (final decoder in [base64.decode, base64Url.decode]) {
      try {
        final bytes = decoder(padded);
        if (bytes.isEmpty || bytes.length > 4096) continue;
        final text = utf8.decode(bytes, allowMalformed: true);
        // Reject binary noise: keep only mostly-printable decodes.
        final printable = text.runes
            .where((rune) => rune >= 0x20 && rune != 0x7f)
            .length;
        if (text.isEmpty || printable / text.runes.length < 0.9) continue;
        return text;
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  /// Normalize a workspace path the same way the file tools resolve it.
  ///
  /// Returns null when the path escapes `/root/workspace`.
  static String? normalizeWorkspacePath(String path) {
    const allowedRoot = '/root/workspace';
    if (path.isEmpty) return null;
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    final resolved = <String>[];
    for (final segment in segments) {
      if (segment == '.') continue;
      if (segment == '..') {
        if (resolved.isEmpty) return null;
        resolved.removeLast();
        continue;
      }
      resolved.add(segment);
    }
    final normalized = '/${resolved.join('/')}';
    if (normalized != allowedRoot &&
        !normalized.startsWith('$allowedRoot/')) {
      return null;
    }
    return normalized;
  }

  static String _trim(String value) {
    var result = value.trim();
    // Tolerate markdown/HTML wrapping and sentence punctuation.
    while (result.isNotEmpty &&
        _trailingPunctuation.hasMatch(result)) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }
}

/// One untrusted tool-result entry read back from a stored transcript.
class UntrustedTranscriptEntry {
  const UntrustedTranscriptEntry({
    required this.toolName,
    required this.text,
    this.source,
  });

  final String toolName;
  final String text;

  /// The original provenance when the entry reported it (for example an
  /// untrusted memory fact). Null means derive it from [toolName].
  final UntrustedSource? source;
}

/// Loads every untrusted tool-result entry stored in chat sessions.
///
/// Background tasks run under a dedicated pseudo-session, so this scans the
/// stored chat sessions rather than trusting the task's session id.
typedef BackgroundUntrustedTranscriptLoader
    = Future<List<UntrustedTranscriptEntry>> Function();

/// Host-side hard-deny rules for tainted destinations.
///
/// It is composed into `ToolPolicy.additionalDenyCheck`; it never replaces the
/// global deny, skill capability deny, or approval order. Web→web follow is not
/// hard-denied here: it falls through to the normal approval (Ask) path.
class UntrustedDataPolicy {
  UntrustedDataPolicy(this.taint);

  final RunTaintSet taint;

  static const Set<String> phoneActSinks = {
    'openWeb',
    'share',
    'composeEmail',
    'mapsNavigate',
    'dialPad',
  };

  static const Set<String> phoneSendActions = {'callPhone', 'sendSms'};

  /// Network programs that 2.9.0 hard-denies on a tainted destination.
  static const Set<String> bashNetworkPrograms = {'curl', 'wget', 'nc'};

  /// Python network APIs. Every Python interpreter calling one of these on a
  /// tainted value is outbound exfil even though the binary is not `curl`.
  static const Set<String> pythonNetworkMarkers = {
    'urllib',
    'http.client',
    'requests',
  };

  /// `git` subcommands that contact a remote.
  static const Set<String> gitRemoteSubcommands = {
    'clone',
    'fetch',
    'push',
    'ls-remote',
  };

  /// The JavaScript runtimes. They are a deny class like python: not installed in
  /// the Alpine baseline, but a command that uses one against a tainted
  /// destination is outbound exfil.
  static const Set<String> nodePrograms = {'node', 'nodejs', 'bun'};

  /// Flags that let a JavaScript runtime evaluate code the model supplied.
  static const Set<String> nodeEvalFlags = {
    '-e',
    '--eval',
    '-p',
    '--print',
  };

  /// Extract every untrusted tool-result entry from a stored transcript.
  ///
  /// Used to seed a run's taint set from earlier turns (history replay) and to
  /// check a background share payload against the session transcript. Old
  /// transcripts have no `trust` field and read back as trusted.
  static List<UntrustedTranscriptEntry> untrustedEntriesFromMessages(
    List<ChatMessage> messages,
  ) {
    final entries = <UntrustedTranscriptEntry>[];
    for (final message in messages) {
      for (final content in message.content) {
        if (content is! ToolResultContent) continue;
        if (content.trust != ToolResultTrust.untrusted) continue;
        final toolName =
            content.metadata['toolName']?.toString() ?? 'web_fetch';
        final reported = reportedUntrustedValues(content.metadata);
        if (reported != null) {
          // `memory_get` reports exactly which stored facts are untrusted; taint
          // only those, with the source they were written from.
          for (final item in reported) {
            entries.add(UntrustedTranscriptEntry(
              toolName: toolName,
              text: item.text,
              source: item.source,
            ));
          }
          continue;
        }
        entries.add(UntrustedTranscriptEntry(
          toolName: toolName,
          // A `read_file` of a path written from untrusted data records its
          // original source so a replay keeps the same strictness.
          source: content.metadata['untrustedSource'] == null
              ? null
              : _sourceFromName(content.metadata['untrustedSource']),
          text: content.forLlm ?? content.output,
        ));
      }
    }
    return entries;
  }

  /// Untrusted values a tool result explicitly reported in its metadata.
  ///
  /// `memory_get` uses this to name the stored facts that are untrusted (and
  /// the source each was written from) so taint re-seeds exactly those values
  /// instead of the whole payload. Returns null when the tool reported nothing.
  static List<({String text, UntrustedSource source})>? reportedUntrustedValues(
    Map<String, dynamic> metadata,
  ) {
    final raw = metadata['untrustedValues'];
    if (raw is! List || raw.isEmpty) return null;
    final values = <({String text, UntrustedSource source})>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final text = item['text']?.toString();
      if (text == null || text.isEmpty) continue;
      values.add((text: text, source: _sourceFromName(item['source'])));
    }
    return values.isEmpty ? null : values;
  }

  /// Unknown provenance fails closed at the strictest source.
  static UntrustedSource _sourceFromName(Object? value) {
    final name = value?.toString();
    for (final source in UntrustedSource.values) {
      if (source.name == name) return source;
    }
    return UntrustedSource.phone;
  }

  /// The exact destination a background approval must display for a web tool.
  ///
  /// This is the value the user confirms, so web taint may only be cleared when
  /// this exact string was on the approval surface they approved.
  static String? approvalDetailFor(ToolApprovalRequest request) {
    if (request.toolName != 'web_fetch' && request.toolName != 'web_search') {
      return null;
    }
    final target = request.arguments['url'] ?? request.arguments['query'];
    return target is String && target.isNotEmpty ? target : null;
  }

  ToolDenyDecision? denyFor(ToolApprovalRequest request) {
    if (taint.isEmpty) return null;
    switch (request.toolName) {
      // phone_send / phone_act / phone_intent all carry actions from the same
      // legacy surface. The hidden `phone_intent` alias must not bypass the
      // deny engine, including the background-task executor.
      case 'phone_send':
      case 'phone_act':
      case 'phone_intent':
        return _denyPhoneSink(request, request.toolName);
      case 'bash':
        final command = _firstString(request.arguments, 'command');
        if (command == null) return null;
        if (taint.matchIn(command) == null) return null;
        if (_invokesNamedNetworkProgram(command, taint)) {
          return _decision(
            ruleId: 'untrusted_bash_network',
            message: 'Blocked: this command sends a value that arrived from '
                'untrusted tool data. Ask the user to type the destination.',
          );
        }
        // A command that reads a workspace file written from untrusted data in
        // this run and also carries a tainted destination is exfil.
        if (taint.commandReadsTaintedPath(command)) {
          return _decision(
            ruleId: 'untrusted_bash_tainted_read',
            message: 'Blocked: this command reads a file written from untrusted '
                'tool data and carries a value from that data. Ask the user to '
                'type the destination.',
          );
        }
        // An unknown binary fails closed only when its arguments carry a
        // tainted URL or host. A full default-deny outbound firewall is not
        // part of 2.9.0.
        if (taint.matchUrlOrHostIn(command) != null) {
          return _decision(
            ruleId: 'untrusted_bash_unknown_binary',
            message: 'Blocked: this command carries a URL or host that arrived '
                'from untrusted tool data. Ask the user to type the '
                'destination.',
          );
        }
        return null;
      case 'web_fetch':
      case 'web_search':
        final target = _firstString(request.arguments, 'url') ??
            _firstString(request.arguments, 'query');
        if (target == null) return null;
        final source = taint.matchIn(target);
        if (source == UntrustedSource.phone || source == UntrustedSource.mcp) {
          return _decision(
            ruleId: 'untrusted_phone_to_web',
            message: 'Blocked: this destination came from phone data or an MCP '
                'result. Ask the user to type it explicitly.',
          );
        }
        // web → web is Ask, handled by the normal approval callback.
        return null;
      default:
        return null;
    }
  }

  ToolDenyDecision? _denyPhoneSink(
    ToolApprovalRequest request,
    String toolName,
  ) {
    final action = _firstString(request.arguments, 'action');
    if (action == null) return null;
    if (!phoneActSinks.contains(action) &&
        !phoneSendActions.contains(action)) {
      return null;
    }
    return _denyIfTainted(request, '$toolName.$action');
  }

  ToolDenyDecision? _denyIfTainted(
    ToolApprovalRequest request,
    String sink,
  ) {
    for (final value in _stringValues(request.arguments)) {
      if (taint.matchIn(value) != null) {
        return _decision(
          ruleId: 'untrusted_to_$sink',
          message: 'Blocked: `$sink` would use a value that arrived from '
              'untrusted tool data. The user must type or confirm it.',
        );
      }
    }
    return null;
  }

  /// Whether [command] invokes one of the named network programs from the
  /// 2.9.0 I2 slice: `curl` / `wget` / `nc`, `busybox wget`, Python network
  /// APIs (`urllib`, `http.client`, `requests`), `git` against a remote, and
  /// the JavaScript runtimes `node` / `nodejs` / `bun` when they carry a tainted
  /// URL or host (or are used with `-e` on any tainted value).
  ///
  /// `node` is **not** installed into the Alpine baseline; this is a deny rule
  /// only.
  bool _invokesNamedNetworkProgram(String command, RunTaintSet taint) {
    final tokens = command
        .split(RegExp(r'''[\s|;&()<>'"]+'''))
        .map((token) => token.split('/').last.toLowerCase())
        .where((token) => token.isNotEmpty)
        .toList();
    final tokenSet = tokens.toSet();
    for (final program in bashNetworkPrograms) {
      if (tokenSet.contains(program)) return true;
    }
    if (tokenSet.contains('busybox') && tokenSet.contains('wget')) {
      return true;
    }
    final isPython = tokens.any((token) =>
        token == 'python' ||
        token.startsWith('python2') ||
        token.startsWith('python3'));
    if (isPython) {
      final lower = command.toLowerCase();
      if (pythonNetworkMarkers.any(lower.contains)) return true;
    }
    if (tokenSet.contains('git') &&
        tokens.any(gitRemoteSubcommands.contains)) {
      return true;
    }
    final isJavaScriptRuntime = tokens.any(nodePrograms.contains);
    if (isJavaScriptRuntime) {
      if (taint.matchUrlOrHostIn(command) != null) return true;
      // An eval flag can reconstruct a destination from any tainted value.
      final hasEvalFlag = tokens.any((token) =>
          nodeEvalFlags.contains(token) ||
          nodeEvalFlags.any((flag) => token.startsWith('$flag=')));
      if (hasEvalFlag && taint.matchIn(command) != null) {
        return true;
      }
    }
    return false;
  }

  ToolDenyDecision _decision({
    required String ruleId,
    required String message,
  }) =>
      ToolDenyDecision(
        ruleType: 'untrusted_data',
        ruleId: ruleId,
        message: message,
      );

  static String? _firstString(Map<String, dynamic> map, String key) {
    final value = map[key];
    return value is String && value.isNotEmpty ? value : null;
  }

  static List<String> _stringValues(Object? value) {
    final output = <String>[];
    void walk(Object? node) {
      if (node is String) {
        if (node.isNotEmpty) output.add(node);
      } else if (node is Map) {
        for (final item in node.values) {
          walk(item);
        }
      } else if (node is Iterable) {
        for (final item in node) {
          walk(item);
        }
      }
    }

    walk(value);
    return output;
  }
}
