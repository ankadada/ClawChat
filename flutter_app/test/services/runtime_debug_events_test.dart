import 'package:clawchat/services/runtime_debug_events.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RuntimeDebugEventService', () {
    test('keeps only the newest events inside the ring buffer', () {
      final service = RuntimeDebugEventService(capacity: 3);

      for (var i = 0; i < 5; i++) {
        service.record(RuntimeDebugEvent(
          type: 'event.$i',
          sessionId: 's1',
          data: {'index': i},
        ));
      }

      expect(service.recent().map((event) => event.type), [
        'event.2',
        'event.3',
        'event.4',
      ]);
    });

    test('filters recent events by session id and limit', () {
      final service = RuntimeDebugEventService();

      service.record(RuntimeDebugEvent(type: 'a', sessionId: 's1'));
      service.record(RuntimeDebugEvent(type: 'b', sessionId: 's2'));
      service.record(RuntimeDebugEvent(type: 'c', sessionId: 's1'));

      expect(
        service.recent(sessionId: 's1').map((event) => event.type),
        ['a', 'c'],
      );
      expect(
        service.recent(limit: 2).map((event) => event.type),
        ['b', 'c'],
      );
    });

    test('clears all events or a single session', () {
      final service = RuntimeDebugEventService();

      service.record(RuntimeDebugEvent(type: 'a', sessionId: 's1'));
      service.record(RuntimeDebugEvent(type: 'b', sessionId: 's2'));
      service.clear(sessionId: 's1');

      expect(service.recent().map((event) => event.sessionId), ['s2']);

      service.clear();
      expect(service.recent(), isEmpty);
    });

    test('truncates long strings and redacts sensitive keys recursively', () {
      final service = RuntimeDebugEventService();
      final longValue = 'x' * 260;

      service.record(RuntimeDebugEvent(
        type: 'safe',
        sessionId: 's1',
        data: {
          'note': longValue,
          'api_key': 'sk-secret',
          'nested': {
            'authorization': 'Bearer token',
            'image': {
              'data': 'base64data',
            },
          },
        },
      ));

      final data = service.recent().single.data;
      expect(data['note'], '${'x' * 200}...');
      expect(data['api_key'], '[redacted]');
      final nested = data['nested'] as Map;
      expect(nested['authorization'], '[redacted]');
      expect((nested['image'] as Map)['data'], '[redacted]');
    });

    test('non-positive capacity stores no events', () {
      final service = RuntimeDebugEventService(capacity: 0);

      service.record(RuntimeDebugEvent(type: 'ignored', sessionId: 's1'));

      expect(service.recent(), isEmpty);
    });
  });
}
