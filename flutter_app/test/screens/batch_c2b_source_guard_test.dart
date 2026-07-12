import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('run center remains a local projection with no second store', () {
    final model = File('lib/models/agent_run_center.dart').readAsStringSync();
    final screen =
        File('lib/screens/agent_run_center_screen.dart').readAsStringSync();
    final source = '$model\n$screen';
    expect(source, isNot(contains('toJson(')));
    expect(source, isNot(contains('fromJson(')));
    expect(source, isNot(contains('SessionStorage')));
    expect(source, isNot(contains('http.')));
    expect(source, isNot(contains('telemetry')));
  });

  test('full response search and alternatives have explicit bounds', () {
    final workspace =
        File('lib/screens/full_response_screen.dart').readAsStringSync();
    final models = File('lib/models/chat_models.dart').readAsStringSync();
    expect(workspace, contains('maxQueryCharacters = 128'));
    expect(workspace, contains('maxMatches = 200'));
    expect(models, contains('maxAlternatives = 4'));
  });
}
