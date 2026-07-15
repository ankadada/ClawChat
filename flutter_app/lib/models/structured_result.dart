import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../services/strict_json_decoder.dart';

const _structuredResultMaxBytes = 16 * 1024;
const _structuredActionPayloadMaxBytes = 2 * 1024;
final _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
final _actionIdPattern = RegExp(r'^[a-z0-9._-]{1,96}$');
final _receiptCodePattern = RegExp(r'^[a-z0-9._-]{1,64}$');

class StructuredResultParseException implements Exception {
  final String reasonCode;

  const StructuredResultParseException(this.reasonCode);

  @override
  String toString() => 'Invalid structured result: $reasonCode';
}

class WireTimestamp {
  static final _pattern = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})\.(\d{3})Z$',
  );

  static String format(DateTime value) {
    final utc = value.toUtc();
    String two(int number) => number.toString().padLeft(2, '0');
    String three(int number) => number.toString().padLeft(3, '0');
    return '${utc.year.toString().padLeft(4, '0')}-'
        '${two(utc.month)}-${two(utc.day)}T${two(utc.hour)}:'
        '${two(utc.minute)}:${two(utc.second)}.${three(utc.millisecond)}Z';
  }

  static DateTime parse(Object? raw) {
    if (raw is! String) throw const FormatException('invalid_timestamp');
    final match = _pattern.firstMatch(raw);
    if (match == null) throw const FormatException('invalid_timestamp');
    final values = [for (var i = 1; i <= 7; i++) int.parse(match.group(i)!)];
    final value = DateTime.utc(
      values[0],
      values[1],
      values[2],
      values[3],
      values[4],
      values[5],
      values[6],
    );
    if (format(value) != raw) {
      throw const FormatException('invalid_timestamp');
    }
    return value;
  }
}

enum StructuredNoticeLevel { info, warning, error }

sealed class StructuredResultBlock {
  const StructuredResultBlock();

  String get kind;
  Map<String, Object?> toJson();
}

final class StructuredNoticeBlock extends StructuredResultBlock {
  final StructuredNoticeLevel level;
  final String text;

  const StructuredNoticeBlock({required this.level, required this.text});

  @override
  String get kind => 'notice';

  @override
  Map<String, Object?> toJson() => {
        'kind': kind,
        'level': level.name,
        'text': text,
      };
}

final class StructuredKeyValueBlock extends StructuredResultBlock {
  final List<StructuredKeyValueItem> items;

  const StructuredKeyValueBlock({required this.items});

  @override
  String get kind => 'key_value';

  @override
  Map<String, Object?> toJson() => {
        'kind': kind,
        'items': items.map((item) => item.toJson()).toList(growable: false),
      };
}

final class StructuredKeyValueItem {
  final String key;
  final String value;

  const StructuredKeyValueItem({required this.key, required this.value});

  Map<String, Object?> toJson() => {'key': key, 'value': value};
}

final class StructuredItemListBlock extends StructuredResultBlock {
  final String? title;
  final List<String> items;

  const StructuredItemListBlock({this.title, required this.items});

  @override
  String get kind => 'item_list';

  @override
  Map<String, Object?> toJson() => {
        'kind': kind,
        if (title != null) 'title': title,
        'items': items,
      };
}

final class StructuredActionListBlock extends StructuredResultBlock {
  final List<StructuredResultAction> actions;

  const StructuredActionListBlock({required this.actions});

  @override
  String get kind => 'action_list';

  @override
  Map<String, Object?> toJson() => {
        'kind': kind,
        'actions': actions.map((action) => action.toJson()).toList(),
      };
}

final class StructuredResultAction {
  final String actionId;
  final String label;
  final String kind;
  final Map<String, Object?> payload;

  const StructuredResultAction({
    required this.actionId,
    required this.label,
    required this.kind,
    required this.payload,
  });

  Map<String, Object?> toJson() => {
        'actionId': actionId,
        'label': label,
        'kind': kind,
        'payload': payload,
      };
}

/// App-owned proof that a presentation was emitted while one verified skill
/// capability context was active.  It is never accepted from model tool input;
/// it is written only by the AgentService-to-ChatProvider handoff and is
/// re-verified before a later action can run.
final class StructuredResultSkillProvenance {
  static final _skillIdPattern = RegExp(r'^[A-Za-z0-9._-]{1,120}$');
  static final _digestPattern = RegExp(r'^[a-f0-9]{64}$');

  const StructuredResultSkillProvenance({
    required this.skillId,
    required this.trustDigest,
  });

  final String skillId;
  final String trustDigest;

  factory StructuredResultSkillProvenance.fromJson(Object? raw) {
    if (raw is! Map ||
        raw.length != 2 ||
        raw.keys.any((key) => key is! String)) {
      throw const FormatException('invalid_structured_skill_provenance');
    }
    final value = Map<String, Object?>.from(raw);
    final skillId = value['skillId'];
    final trustDigest = value['trustDigest'];
    if (!value.keys.toSet().containsAll(const {'skillId', 'trustDigest'}) ||
        skillId is! String ||
        trustDigest is! String ||
        !_skillIdPattern.hasMatch(skillId) ||
        !_digestPattern.hasMatch(trustDigest)) {
      throw const FormatException('invalid_structured_skill_provenance');
    }
    return StructuredResultSkillProvenance(
      skillId: skillId,
      trustDigest: trustDigest,
    );
  }

  Map<String, String> toJson() => {
        'skillId': skillId,
        'trustDigest': trustDigest,
      };
}

/// The exact outer data accepted by the app-owned presentation tool.
///
/// Provider SDKs supply this outer envelope as a map, so duplicate outer keys
/// cannot be proven after provider decoding. The security-significant inner
/// [documentJson] remains a raw string and is decoded strictly below.
final class StructuredResultIngress {
  static const toolName = 'present_structured_result';

  const StructuredResultIngress({
    required this.documentJson,
    required this.document,
  });

  final String documentJson;
  final StructuredResultDocument document;

  static StructuredResultIngress parseOuter(Object? raw) {
    if (raw is! Map || raw.keys.any((key) => key is! String)) {
      throw const StructuredResultParseException('outer_shape');
    }
    final outer = Map<String, Object?>.from(raw);
    StructuredResultDocument._exactKeys(
      outer,
      const {'documentJson'},
    );
    final documentJson = outer['documentJson'];
    if (documentJson is! String) {
      throw const StructuredResultParseException('outer_document_json');
    }
    return StructuredResultIngress(
      documentJson: documentJson,
      document: StructuredResultDocument.parseJson(documentJson),
    );
  }
}

final class StructuredResultDocument {
  final int schemaVersion;
  final String resultId;
  final List<StructuredResultBlock> blocks;

  const StructuredResultDocument({
    required this.schemaVersion,
    required this.resultId,
    required this.blocks,
  });

  static StructuredResultDocument parseJson(String documentJson) {
    if (documentJson.isEmpty) {
      throw const StructuredResultParseException('oversize_or_empty');
    }
    try {
      final decoded = const StrictJsonDecoder(
        maxUtf8Bytes: _structuredResultMaxBytes,
        maxNestingDepth: 32,
      ).decodeString(documentJson);
      return parseDecoded(decoded);
    } on StructuredResultParseException {
      rethrow;
    } on StrictJsonDecodeException catch (error) {
      throw StructuredResultParseException(error.reasonCode);
    } on FormatException {
      throw const StructuredResultParseException('invalid_json');
    }
  }

  static StructuredResultDocument parseDecoded(Object? decoded) {
    if (decoded is! Map<String, Object?>) {
      throw const StructuredResultParseException('root_not_object');
    }
    _exactKeys(decoded, const {'schemaVersion', 'resultId', 'blocks'});
    if (decoded['schemaVersion'] != 1) {
      throw const StructuredResultParseException('schema_version');
    }
    final resultId = decoded['resultId'];
    if (resultId is! String || !_uuidPattern.hasMatch(resultId)) {
      throw const StructuredResultParseException('result_id');
    }
    final rawBlocks = decoded['blocks'];
    if (rawBlocks is! List || rawBlocks.isEmpty || rawBlocks.length > 32) {
      throw const StructuredResultParseException('blocks_bounds');
    }
    final blocks = <StructuredResultBlock>[];
    final actionIds = <String>{};
    for (final raw in rawBlocks) {
      blocks.add(_parseBlock(raw, actionIds));
    }
    return StructuredResultDocument(
      schemaVersion: 1,
      resultId: resultId,
      blocks: List.unmodifiable(blocks),
    );
  }

  static StructuredResultBlock _parseBlock(
    Object? raw,
    Set<String> actionIds,
  ) {
    if (raw is! Map<String, Object?> || raw['kind'] is! String) {
      throw const StructuredResultParseException('block_shape');
    }
    final kind = raw['kind'] as String;
    switch (kind) {
      case 'notice':
        _exactKeys(raw, const {'kind', 'level', 'text'});
        final level = raw['level'];
        final text = raw['text'];
        if (level is! String ||
            text is! String ||
            !StructuredText.isBounded(text, 1, 2000)) {
          throw const StructuredResultParseException('notice_fields');
        }
        final parsedLevel = StructuredNoticeLevel.values
            .where((value) => value.name == level)
            .firstOrNull;
        if (parsedLevel == null) {
          throw const StructuredResultParseException('notice_level');
        }
        return StructuredNoticeBlock(level: parsedLevel, text: text);
      case 'key_value':
        _exactKeys(raw, const {'kind', 'items'});
        final rawItems = raw['items'];
        if (rawItems is! List || rawItems.isEmpty || rawItems.length > 32) {
          throw const StructuredResultParseException('key_value_bounds');
        }
        final items = <StructuredKeyValueItem>[];
        for (final item in rawItems) {
          if (item is! Map<String, Object?>) {
            throw const StructuredResultParseException('key_value_item');
          }
          _exactKeys(item, const {'key', 'value'});
          final key = item['key'];
          final value = item['value'];
          if (key is! String ||
              value is! String ||
              !StructuredText.isBounded(key, 1, 256) ||
              !StructuredText.isBounded(value, 1, 256)) {
            throw const StructuredResultParseException('key_value_fields');
          }
          items.add(StructuredKeyValueItem(key: key, value: value));
        }
        return StructuredKeyValueBlock(items: List.unmodifiable(items));
      case 'item_list':
        _exactKeys(raw, const {'kind', 'items'}, optional: const {'title'});
        final title = raw['title'];
        if (title != null &&
            (title is! String || !StructuredText.isBounded(title, 1, 160))) {
          throw const StructuredResultParseException('item_list_title');
        }
        final rawItems = raw['items'];
        if (rawItems is! List ||
            rawItems.isEmpty ||
            rawItems.length > 64 ||
            rawItems.any((item) =>
                item is! String || !StructuredText.isBounded(item, 1, 512))) {
          throw const StructuredResultParseException('item_list_items');
        }
        return StructuredItemListBlock(
          title: title == null ? null : title as String,
          items: List.unmodifiable(rawItems.cast<String>()),
        );
      case 'action_list':
        _exactKeys(raw, const {'kind', 'actions'});
        final rawActions = raw['actions'];
        if (rawActions is! List ||
            rawActions.isEmpty ||
            rawActions.length > 16) {
          throw const StructuredResultParseException('action_list_bounds');
        }
        final actions = <StructuredResultAction>[];
        for (final item in rawActions) {
          if (item is! Map<String, Object?>) {
            throw const StructuredResultParseException('action_shape');
          }
          _exactKeys(item, const {'actionId', 'label', 'kind', 'payload'});
          final actionId = item['actionId'];
          final label = item['label'];
          final actionKind = item['kind'];
          final payload = item['payload'];
          if (actionId is! String ||
              !_actionIdPattern.hasMatch(actionId) ||
              label is! String ||
              !StructuredText.isBounded(label, 1, 160) ||
              actionKind != 'save_to_memory' ||
              payload is! Map<String, Object?> ||
              !actionIds.add(actionId)) {
            throw const StructuredResultParseException('action_fields');
          }
          _exactKeys(payload, const {'fact'});
          final fact = payload['fact'];
          if (fact is! String || !StructuredText.isBounded(fact, 1, 2000)) {
            throw const StructuredResultParseException('action_payload');
          }
          if (utf8.encode(jsonEncode(payload)).length >
              _structuredActionPayloadMaxBytes) {
            throw const StructuredResultParseException('action_payload_size');
          }
          actions.add(StructuredResultAction(
            actionId: actionId,
            label: label,
            kind: actionKind as String,
            payload: Map.unmodifiable(payload),
          ));
        }
        return StructuredActionListBlock(actions: List.unmodifiable(actions));
      default:
        throw const StructuredResultParseException('unknown_block_kind');
    }
  }

  static void _exactKeys(
    Map<String, Object?> value,
    Set<String> required, {
    Set<String> optional = const {},
  }) {
    final expected = {...required, ...optional};
    if (!value.keys.toSet().containsAll(required) ||
        value.keys.toSet().difference(expected).isNotEmpty) {
      throw const StructuredResultParseException('unknown_or_missing_field');
    }
  }

  String get canonicalJson => _canonicalJson(toJson());

  String get projection {
    final output = StringBuffer();
    for (final block in blocks) {
      if (output.isNotEmpty) output.writeln();
      switch (block) {
        case StructuredNoticeBlock(:final level, :final text):
          output.writeln(
              'NOTICE [${level.name}]: ${StructuredText.display(text)}');
        case StructuredKeyValueBlock(:final items):
          output.writeln('DETAILS:');
          for (final item in items) {
            output.writeln('- ${StructuredText.display(item.key)}: '
                '${StructuredText.display(item.value)}');
          }
        case StructuredItemListBlock(:final title, :final items):
          output.writeln(
              '${title == null ? 'ITEMS' : StructuredText.display(title).toUpperCase()}:');
          for (final item in items) {
            output.writeln('- ${StructuredText.display(item)}');
          }
        case StructuredActionListBlock(:final actions):
          output.writeln('ACTIONS:');
          for (final action in actions) {
            output.writeln('- ${StructuredText.display(action.label)}');
          }
      }
    }
    return output.toString().trimRight();
  }

  Map<String, Object?> toJson() => {
        'schemaVersion': schemaVersion,
        'resultId': resultId,
        'blocks': blocks.map((block) => block.toJson()).toList(),
      };

  static StructuredResultDocument invalid() => const StructuredResultDocument(
        schemaVersion: 1,
        resultId: '00000000-0000-4000-8000-000000000000',
        blocks: [
          StructuredNoticeBlock(
            level: StructuredNoticeLevel.error,
            text: 'Structured result could not be displayed safely.',
          ),
        ],
      );
}

class StructuredText {
  static bool isBounded(String value, int min, int max) {
    final length = value.runes.length;
    return length >= min && length <= max;
  }

  static String display(String value) {
    return value
        .replaceAll(
            RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]'), '\uFFFD')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}

final class StructuredActionReceipt {
  static const maxSafeSummaryLength = 256;
  final int schemaVersion;
  final String receiptId;
  final String operationId;
  final String sourceKind;
  final String resultId;
  final String actionId;
  final String actionKind;
  final String toolName;
  final String canonicalInputDigest;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String hardDeny;
  final String skillDeny;
  final String approval;
  final String state;
  final String outcome;
  final bool outcomeKnown;
  final String safeSummary;

  const StructuredActionReceipt({
    required this.schemaVersion,
    required this.receiptId,
    required this.operationId,
    required this.sourceKind,
    required this.resultId,
    required this.actionId,
    required this.actionKind,
    required this.toolName,
    required this.canonicalInputDigest,
    required this.createdAt,
    required this.updatedAt,
    required this.hardDeny,
    required this.skillDeny,
    required this.approval,
    required this.state,
    required this.outcome,
    required this.outcomeKnown,
    required this.safeSummary,
  });

  factory StructuredActionReceipt.fromJson(Map<String, dynamic> json) {
    const expected = {
      'schemaVersion',
      'receiptId',
      'operationId',
      'source',
      'actionKind',
      'toolName',
      'canonicalInputDigest',
      'createdAt',
      'updatedAt',
      'policy',
      'state',
      'outcome',
      'outcomeKnown',
      'safeSummary',
    };
    if (json.keys.toSet().difference(expected).isNotEmpty ||
        expected.difference(json.keys.toSet()).isNotEmpty ||
        json['schemaVersion'] != 1) {
      throw const FormatException('invalid_structured_receipt');
    }
    final source = _strictMap(json['source']);
    final policy = _strictMap(json['policy']);
    _requireExactKeys(source, const {'kind', 'resultId', 'actionId'});
    _requireExactKeys(policy, const {'hardDeny', 'skillDeny', 'approval'});
    String stringField(String key, {int max = 160}) {
      final value = json[key];
      if (value is! String || value.isEmpty || value.length > max) {
        throw const FormatException('invalid_structured_receipt');
      }
      return value;
    }

    final receiptId = stringField('receiptId');
    final operationId = stringField('operationId');
    final resultId = source['resultId'];
    final actionId = source['actionId'];
    final sourceKind = source['kind'];
    if (!_uuidPattern.hasMatch(receiptId) ||
        !_uuidPattern.hasMatch(operationId) ||
        sourceKind is! String ||
        sourceKind != 'structured_result' ||
        resultId is! String ||
        !_uuidPattern.hasMatch(resultId) ||
        actionId is! String ||
        !_actionIdPattern.hasMatch(actionId)) {
      throw const FormatException('invalid_structured_receipt');
    }
    final digest = json['canonicalInputDigest'];
    if (digest is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
      throw const FormatException('invalid_structured_receipt');
    }
    final outcomeKnown = json['outcomeKnown'];
    if (outcomeKnown is! bool) {
      throw const FormatException('invalid_structured_receipt');
    }
    final safeSummary = json['safeSummary'];
    if (safeSummary is! String ||
        !StructuredText.isBounded(safeSummary, 1, maxSafeSummaryLength)) {
      throw const FormatException('invalid_structured_receipt');
    }
    final actionKind = stringField('actionKind');
    final toolName = stringField('toolName', max: 80);
    final state = stringField('state', max: 64);
    final outcome = stringField('outcome', max: 64);
    final hardDeny = _policyString(policy, 'hardDeny');
    final skillDeny = _policyString(policy, 'skillDeny');
    final approval = _policyString(policy, 'approval');
    if (actionKind != 'save_to_memory' ||
        toolName != 'memory_write' ||
        !_receiptCodePattern.hasMatch(outcome) ||
        !_receiptStates.contains(state) ||
        !_receiptOutcomes.contains(outcome) ||
        !_validReceiptTransition(
          hardDeny: hardDeny,
          skillDeny: skillDeny,
          approval: approval,
          state: state,
          outcome: outcome,
          outcomeKnown: outcomeKnown,
        )) {
      throw const FormatException('invalid_structured_receipt');
    }
    final createdAt = WireTimestamp.parse(json['createdAt']);
    final updatedAt = WireTimestamp.parse(json['updatedAt']);
    if (updatedAt.isBefore(createdAt)) {
      throw const FormatException('invalid_structured_receipt');
    }
    return StructuredActionReceipt(
      schemaVersion: 1,
      receiptId: receiptId,
      operationId: operationId,
      sourceKind: sourceKind,
      resultId: resultId,
      actionId: actionId,
      actionKind: actionKind,
      toolName: toolName,
      canonicalInputDigest: digest,
      createdAt: createdAt,
      updatedAt: updatedAt,
      hardDeny: hardDeny,
      skillDeny: skillDeny,
      approval: approval,
      state: state,
      outcome: outcome,
      outcomeKnown: outcomeKnown,
      safeSummary: safeSummary,
    );
  }

  Map<String, Object?> toJson() => {
        'schemaVersion': schemaVersion,
        'receiptId': receiptId,
        'operationId': operationId,
        'source': {
          'kind': sourceKind,
          'resultId': resultId,
          'actionId': actionId,
        },
        'actionKind': actionKind,
        'toolName': toolName,
        'canonicalInputDigest': canonicalInputDigest,
        'createdAt': WireTimestamp.format(createdAt),
        'updatedAt': WireTimestamp.format(updatedAt),
        'policy': {
          'hardDeny': hardDeny,
          'skillDeny': skillDeny,
          'approval': approval,
        },
        'state': state,
        'outcome': outcome,
        'outcomeKnown': outcomeKnown,
        'safeSummary': safeSummary,
      };

  StructuredActionReceipt copyWith({
    DateTime? updatedAt,
    String? hardDeny,
    String? skillDeny,
    String? approval,
    String? state,
    String? outcome,
    bool? outcomeKnown,
    String? safeSummary,
  }) =>
      StructuredActionReceipt(
        schemaVersion: schemaVersion,
        receiptId: receiptId,
        operationId: operationId,
        sourceKind: sourceKind,
        resultId: resultId,
        actionId: actionId,
        actionKind: actionKind,
        toolName: toolName,
        canonicalInputDigest: canonicalInputDigest,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        hardDeny: hardDeny ?? this.hardDeny,
        skillDeny: skillDeny ?? this.skillDeny,
        approval: approval ?? this.approval,
        state: state ?? this.state,
        outcome: outcome ?? this.outcome,
        outcomeKnown: outcomeKnown ?? this.outcomeKnown,
        safeSummary: safeSummary ?? this.safeSummary,
      );

  /// Converts a durable-but-incomplete attempt into inspect-only recovery
  /// evidence. Reload never resumes or retries a structured action.
  StructuredActionReceipt reconcileAfterRestart() {
    if (state == 'resultPersisted' || state == 'interruptedUnknown') {
      return this;
    }
    return copyWith(
      approval: approval == 'not_requested' ? 'not_requested' : 'stale',
      state: 'interruptedUnknown',
      outcome: 'unknown_outcome',
      outcomeKnown: false,
      safeSummary:
          'Local memory action was interrupted and will not be retried automatically.',
    );
  }

  static String _policyString(Map<String, Object?> policy, String key) {
    final value = policy[key];
    if (value is! String || !_receiptCodePattern.hasMatch(value)) {
      throw const FormatException('invalid_structured_receipt');
    }
    return value;
  }

  static bool _validReceiptTransition({
    required String hardDeny,
    required String skillDeny,
    required String approval,
    required String state,
    required String outcome,
    required bool outcomeKnown,
  }) {
    if (!_receiptHardDenyCodes.contains(hardDeny) ||
        !_receiptSkillDenyCodes.contains(skillDeny) ||
        !_receiptApprovalCodes.contains(approval)) {
      return false;
    }
    final expectedOutcomeKnown = switch (outcome) {
      'pending' || 'unknown_outcome' => false,
      _ => true,
    };
    if (outcomeKnown != expectedOutcomeKnown) return false;

    if (state == 'interruptedUnknown') {
      return outcome == 'unknown_outcome' &&
          !outcomeKnown &&
          hardDeny != 'denied' &&
          skillDeny != 'denied' &&
          const {
            'not_requested',
            'stale',
            'approved',
            'auto_allowed',
          }.contains(approval);
    }

    final stateMatchesOutcome = switch (state) {
      'proposed' ||
      'approvalPending' ||
      'approvedNotStarted' ||
      'started' =>
        outcome == 'pending',
      'completed' => outcome == 'success' && outcomeKnown,
      'failed' => outcome == 'failed' && outcomeKnown,
      'interruptedUnknown' => false,
      'resultPersisted' =>
        const {'success', 'denied', 'cancelled', 'failed'}.contains(outcome) &&
            outcomeKnown,
      _ => false,
    };
    if (!stateMatchesOutcome) return false;

    if (hardDeny == 'denied') {
      return state == 'resultPersisted' &&
          outcome == 'denied' &&
          const {'not_requested', 'stale'}.contains(approval) &&
          skillDeny != 'denied';
    }
    if (skillDeny == 'denied') {
      return hardDeny == 'not_denied' &&
          state == 'resultPersisted' &&
          outcome == 'denied' &&
          const {'not_requested', 'stale'}.contains(approval);
    }
    if (outcome == 'denied') return false;

    return switch (approval) {
      'pending' => state == 'approvalPending',
      'denied' => hardDeny == 'not_denied' &&
          state == 'resultPersisted' &&
          outcome == 'cancelled',
      'approved' || 'auto_allowed' => hardDeny == 'not_denied' &&
          const {'not_applicable', 'not_denied'}.contains(skillDeny) &&
          const {
            'approvedNotStarted',
            'started',
            'completed',
            'failed',
            'interruptedUnknown',
            'resultPersisted',
          }.contains(state) &&
          !const {'denied', 'cancelled'}.contains(outcome),
      'stale' => state == 'resultPersisted' &&
          outcome == 'cancelled' &&
          hardDeny != 'denied' &&
          skillDeny != 'denied',
      'not_requested' => (state == 'proposed' && outcome == 'pending') ||
          (state == 'resultPersisted' && outcome == 'cancelled'),
      _ => false,
    };
  }

  static Map<String, Object?> _strictMap(Object? value) {
    if (value is! Map) {
      throw const FormatException('invalid_structured_receipt');
    }
    return Map<String, Object?>.from(value);
  }

  static void _requireExactKeys(
    Map<String, Object?> value,
    Set<String> expected,
  ) {
    if (value.length != expected.length ||
        value.keys.toSet().difference(expected).isNotEmpty ||
        expected.difference(value.keys.toSet()).isNotEmpty) {
      throw const FormatException('invalid_structured_receipt');
    }
  }
}

String structuredActionInputDigest(StructuredResultAction action) {
  return structuredActionInputDigestForInput(action.kind, action.payload);
}

/// Returns the sole app-owned execution input for a fixed structured action.
/// Registry dispatch, receipt creation, and restart ownership validation must
/// all use this function so persisted evidence hashes exactly what executes.
Map<String, Object?>? canonicalStructuredActionInput(
  String actionKind,
  Map<String, Object?> input,
) {
  if (actionKind != 'save_to_memory' ||
      input.length != 1 ||
      !input.containsKey('fact')) {
    return null;
  }
  final fact = input['fact'];
  if (fact is! String || !StructuredText.isBounded(fact, 1, 2000)) return null;
  final canonicalFact = fact.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (!StructuredText.isBounded(canonicalFact, 1, 2000)) return null;
  return Map<String, Object?>.unmodifiable({'fact': canonicalFact});
}

String structuredActionInputDigestForInput(
  String actionKind,
  Map<String, Object?> input,
) {
  final canonicalInput = canonicalStructuredActionInput(actionKind, input);
  if (canonicalInput == null) {
    throw const StructuredResultParseException('action_input');
  }
  return sha256
      .convert(utf8.encode(_canonicalJson({
        'kind': actionKind,
        'payload': canonicalInput,
      })))
      .toString();
}

const _receiptStates = {
  'proposed',
  'approvalPending',
  'approvedNotStarted',
  'started',
  'completed',
  'failed',
  'interruptedUnknown',
  'resultPersisted',
};

const _receiptOutcomes = {
  'pending',
  'success',
  'denied',
  'cancelled',
  'failed',
  'unknown_outcome',
};

const _receiptHardDenyCodes = {'not_checked', 'not_denied', 'denied'};
const _receiptSkillDenyCodes = {
  'not_checked',
  'not_applicable',
  'not_denied',
  'denied',
};
const _receiptApprovalCodes = {
  'not_requested',
  'pending',
  'approved',
  'auto_allowed',
  'denied',
  'stale',
};

String _canonicalJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.whereType<String>().toList()..sort();
    if (keys.length != value.length) {
      throw const StructuredResultParseException('canonical_value');
    }
    return '{${keys.map((key) => '${jsonEncode(key)}:${_canonicalJson(value[key])}').join(',')}}';
  }
  if (value is List) {
    return '[${value.map(_canonicalJson).join(',')}]';
  }
  return jsonEncode(value);
}
