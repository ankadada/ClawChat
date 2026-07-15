import 'dart:convert';

import 'package:clawchat/models/structured_result.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const validDocument = '''{
    "schemaVersion":1,
    "resultId":"123e4567-e89b-42d3-a456-426614174000",
    "blocks":[
      {"kind":"notice","level":"info","text":"Imported safely"},
      {"kind":"key_value","items":[{"key":"Skill","value":"weather"}]},
      {"kind":"item_list","title":"Checks","items":["Manifest v1"]},
      {"kind":"action_list","actions":[{"actionId":"save-1","label":"Save to local memory","kind":"save_to_memory","payload":{"fact":"Imported safely"}}]}
    ]
  }''';

  group('StructuredResultDocument', () {
    test('strictly parses all fixed blocks and projects deterministically', () {
      final document = StructuredResultDocument.parseJson(validDocument);

      expect(document.blocks, hasLength(4));
      expect(
        document.projection,
        'NOTICE [info]: Imported safely\n\n'
        'DETAILS:\n'
        '- Skill: weather\n\n'
        'CHECKS:\n'
        '- Manifest v1\n\n'
        'ACTIONS:\n'
        '- Save to local memory',
      );
      expect(
        StructuredResultDocument.parseJson(document.canonicalJson).projection,
        document.projection,
      );
    });

    test('accepts an item list without its optional title', () {
      final source = validDocument.replaceFirst(
        '"title":"Checks",',
        '',
      );

      final document = StructuredResultDocument.parseJson(source);

      expect(document.projection, contains('ITEMS:'));
    });

    test('rejects duplicate inner keys, unknown fields, kinds, and actions',
        () {
      final invalid = <String>[
        validDocument.replaceFirst(
            '"schemaVersion":1', '"schemaVersion":1,"schemaVersion":1'),
        validDocument.replaceFirst(
          '"level":"info",',
          '"level":"info","extra":true,',
        ),
        validDocument.replaceFirst('"kind":"notice"', '"kind":"custom"'),
        validDocument.replaceFirst(
          '"kind":"save_to_memory"',
          '"kind":"open_url"',
        ),
      ];

      for (final source in invalid) {
        expect(
          () => StructuredResultDocument.parseJson(source),
          throwsA(isA<StructuredResultParseException>()),
        );
      }
    });

    test('rejects duplicate action IDs across action-list blocks', () {
      final source = validDocument.replaceFirst(
        '    ]\n  }',
        '''      ,{"kind":"action_list","actions":[{"actionId":"save-1","label":"Again","kind":"save_to_memory","payload":{"fact":"Again"}}]}
    ]
  }''',
      );

      expect(
        () => StructuredResultDocument.parseJson(source),
        throwsA(isA<StructuredResultParseException>()),
      );
    });

    test('rejects oversize and invalid Unicode before projection', () {
      final oversize = List<String>.filled(17 * 1024, 'x').join();
      final invalidUnicode = String.fromCharCodes([
        ...'{"schemaVersion":1,"resultId":"'.codeUnits,
        ...'123e4567-e89b-42d3-a456-426614174000'.codeUnits,
        ...'","blocks":[{"kind":"notice","level":"info","text":"'.codeUnits,
        0xd800,
        ...'"}]}'.codeUnits,
      ]);

      expect(
        () => StructuredResultDocument.parseJson(oversize),
        throwsA(isA<StructuredResultParseException>()),
      );
      expect(
        () => StructuredResultDocument.parseJson(invalidUnicode),
        throwsA(isA<StructuredResultParseException>()),
      );
    });
  });

  group('StructuredResultIngress', () {
    test('requires exactly one un-repaired documentJson outer field', () {
      final ingress = StructuredResultIngress.parseOuter({
        'documentJson': validDocument,
      });
      expect(ingress.document.resultId, '123e4567-e89b-42d3-a456-426614174000');

      for (final raw in <Object?>[
        {'document_json': validDocument},
        {'documentJson': validDocument, 'extra': true},
        {'documentJson': 1},
        validDocument,
      ]) {
        expect(
          () => StructuredResultIngress.parseOuter(raw),
          throwsA(isA<StructuredResultParseException>()),
        );
      }
    });
  });

  group('StructuredActionReceipt', () {
    test('round-trips only canonical bounded receipt records', () {
      final json = <String, dynamic>{
        'schemaVersion': 1,
        'receiptId': '123e4567-e89b-42d3-a456-426614174001',
        'operationId': '123e4567-e89b-42d3-a456-426614174002',
        'source': {
          'kind': 'structured_result',
          'resultId': '123e4567-e89b-42d3-a456-426614174000',
          'actionId': 'save-1',
        },
        'actionKind': 'save_to_memory',
        'toolName': 'memory_write',
        'canonicalInputDigest': List.filled(64, 'a').join(),
        'createdAt': '2026-07-15T00:00:00.000Z',
        'updatedAt': '2026-07-15T00:00:01.000Z',
        'policy': {
          'hardDeny': 'not_denied',
          'skillDeny': 'not_applicable',
          'approval': 'approved',
        },
        'state': 'resultPersisted',
        'outcome': 'success',
        'outcomeKnown': true,
        'safeSummary': 'Saved local memory',
      };

      final receipt = StructuredActionReceipt.fromJson(json);

      expect(receipt.toJson(), json);
      expect(
        () => StructuredActionReceipt.fromJson(
          Map<String, dynamic>.from(json)..['extra'] = true,
        ),
        throwsFormatException,
      );
      expect(
        () => StructuredActionReceipt.fromJson(
          Map<String, dynamic>.from(json)..['operationId'] = 'not-a-uuid',
        ),
        throwsFormatException,
      );

      final impossible = <Map<String, dynamic>>[
        jsonDecode(jsonEncode(json)) as Map<String, dynamic>
          ..['outcomeKnown'] = false,
        jsonDecode(jsonEncode(json)) as Map<String, dynamic>
          ..['state'] = 'started',
        jsonDecode(jsonEncode(json)) as Map<String, dynamic>
          ..['outcome'] = 'denied',
        jsonDecode(jsonEncode(json)) as Map<String, dynamic>
          ..['policy'] = {
            'hardDeny': 'denied',
            'skillDeny': 'not_applicable',
            'approval': 'approved',
          },
        jsonDecode(jsonEncode(json)) as Map<String, dynamic>
          ..['policy'] = {
            'hardDeny': 'not_denied',
            'skillDeny': 'not_applicable',
            'approval': 'pending',
          },
      ];
      for (final value in impossible) {
        expect(
          () => StructuredActionReceipt.fromJson(value),
          throwsFormatException,
        );
      }
    });
  });

  test('action input digest is canonical for equivalent map ordering', () {
    const first = StructuredResultAction(
      actionId: 'save-1',
      label: 'Save',
      kind: 'save_to_memory',
      payload: {'fact': 'same'},
    );
    final second = StructuredResultAction(
      actionId: 'save-1',
      label: 'Save',
      kind: 'save_to_memory',
      payload: jsonDecode('{"fact":"same"}') as Map<String, Object?>,
    );

    expect(structuredActionInputDigest(first),
        structuredActionInputDigest(second));
  });

  test('skill provenance accepts only app-owned bounded identifiers', () {
    final provenance = StructuredResultSkillProvenance.fromJson({
      'skillId': 'local-skill.v1',
      'trustDigest': List.filled(64, 'a').join(),
    });

    expect(provenance.toJson()['skillId'], 'local-skill.v1');
    expect(
      () => StructuredResultSkillProvenance.fromJson({
        'skillId': '../untrusted',
        'trustDigest': List.filled(64, 'a').join(),
      }),
      throwsFormatException,
    );
  });
}
