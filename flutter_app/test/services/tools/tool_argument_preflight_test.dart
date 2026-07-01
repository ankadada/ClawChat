import 'package:clawchat/services/tools/tool_argument_preflight.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const preflight = ToolArgumentPreflight();
  const schema = {
    'type': 'object',
    'properties': {
      'command': {'type': 'string'},
      'timeoutMs': {'type': 'integer'},
      'dryRun': {'type': 'boolean'},
      'temperature': {'type': 'number'},
    },
  };

  test('closes obviously truncated JSON objects', () {
    final result = preflight.repair(
      '{"command":"echo ok","timeoutMs":"42"',
      schema,
    );

    expect(result.arguments['command'], 'echo ok');
    expect(result.arguments['timeoutMs'], 42);
    expect(result.repairCounts['json_closure'], 1);
    expect(result.repairCounts['type_coercion'], 1);
  });

  test('coerces only safe boolean and number strings', () {
    final result = preflight.repair({
      'dryRun': 'false',
      'temperature': '0.7',
      'timeoutMs': 'ten',
    }, schema);

    expect(result.arguments['dryRun'], isFalse);
    expect(result.arguments['temperature'], 0.7);
    expect(result.arguments['timeoutMs'], 'ten');
    expect(result.repairCounts['type_coercion'], 2);
  });

  test('repairs unique normalized field name matches', () {
    final result = preflight.repair({
      'timeout_ms': '1000',
      'dry-run': 'true',
    }, schema);

    expect(result.arguments, containsPair('timeoutMs', 1000));
    expect(result.arguments, containsPair('dryRun', true));
    expect(result.arguments, isNot(contains('timeout_ms')));
    expect(result.repairCounts['field_name'], 2);
  });

  test('leaves ambiguous field names untouched', () {
    final result = preflight.repair({
      'dry_run': 'true',
    }, const {
      'type': 'object',
      'properties': {
        'dryRun': {'type': 'boolean'},
        'dryrun': {'type': 'boolean'},
      },
    });

    expect(result.arguments, contains('dry_run'));
    expect(result.repairCounts, isEmpty);
  });
}
