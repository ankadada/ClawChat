import 'package:clawchat/services/storage_budget.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('StorageBudget', () {
    test('allows the operation when free space is above the headroom',
        () async {
      final budget = StorageBudget(
        availableBytesReader: () async => StorageBudget.minimumFreeBytes + 1,
      );
      final decision = await budget.ensureCapacity(operation: '导出备份');
      expect(decision.allowed, isTrue);
      expect(decision.reason, StorageBudgetReason.ok);
      expect(decision.availableBytes, StorageBudget.minimumFreeBytes + 1);
    });

    test('blocks the operation and explains the shortfall', () async {
      final budget = StorageBudget(
        availableBytesReader: () async => 1024 * 1024,
      );
      final decision = await budget.ensureCapacity(operation: '导出备份');
      expect(decision.allowed, isFalse);
      expect(decision.reason, StorageBudgetReason.insufficient);
      expect(decision.message, contains('导出备份'));
      expect(decision.message, contains('1.0MB'));
      expect(decision.message, contains('存储空间'));
    });

    test('counts the caller-requested bytes on top of the base headroom',
        () async {
      final budget = StorageBudget(
        availableBytesReader: () async => StorageBudget.minimumFreeBytes,
      );
      final decision = await budget.ensureCapacity(
        operation: '导入技能包',
        requiredBytes: 8 * 1024 * 1024,
      );
      expect(decision.allowed, isFalse);
      expect(decision.requiredBytes,
          StorageBudget.minimumFreeBytes + 8 * 1024 * 1024);
    });

    test('an unreported free-space value does not block the write', () async {
      final budget = StorageBudget(availableBytesReader: () async => null);
      final decision = await budget.ensureCapacity(operation: '导入技能包');
      expect(decision.allowed, isTrue);
      expect(decision.reason, StorageBudgetReason.unknown);
      expect(decision.message, isNull);
    });

    test('a reader failure is treated as unknown, not as a full disk',
        () async {
      final budget = StorageBudget(
        availableBytesReader: () async => throw StateError('no platform call'),
      );
      final decision = await budget.ensureCapacity(operation: '导出备份');
      expect(decision.allowed, isTrue);
      expect(decision.reason, StorageBudgetReason.unknown);
    });

    test('formats the prompt in compact units', () {
      expect(StorageBudget.formatBytes(512), '512B');
      expect(StorageBudget.formatBytes(2048), '2.0KB');
      expect(StorageBudget.formatBytes(3 * 1024 * 1024), '3.0MB');
      expect(StorageBudget.formatBytes(2 * 1024 * 1024 * 1024), '2.0GB');
    });
  });
}
