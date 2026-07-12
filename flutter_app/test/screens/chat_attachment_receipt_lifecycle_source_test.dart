import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('chat draft owns unacknowledged workspace receipts until send', () {
    final screen = File('lib/screens/chat_screen.dart').readAsStringSync();
    final service =
        File('lib/services/file_attachment_service.dart').readAsStringSync();
    final bridge = File('lib/services/native_bridge.dart').readAsStringSync();

    expect(service, contains('workspaceImportReceipt: receipt'));
    expect(screen,
        contains('workspaceImportReceipt: prepared.workspaceImportReceipt'));
    expect(screen, contains('sendMessageWithWorkspaceImports'));
    expect(screen, contains('_workspaceImportsBeingCommitted'));
    expect(screen, contains('_discardPendingWorkspaceImports()'));
    expect(screen, contains('_draftWithoutWorkspaceImports()'));
    expect(screen, contains('NativeBridge.discardWorkspaceImport(receipt)'));

    final importStart = bridge.indexOf(
      'static Future<WorkspaceImportReceipt> importFileToWorkspace',
    );
    final acknowledgeStart = bridge.indexOf(
      'static Future<void> acknowledgeWorkspaceImport',
    );
    expect(importStart, greaterThan(0));
    expect(acknowledgeStart, greaterThan(importStart));
    expect(
      bridge.substring(importStart, acknowledgeStart),
      isNot(contains("'acknowledgeHostFileImport'")),
    );
  });

  test('provider persists pending receipt before ACK and recovers on reload',
      () {
    final provider =
        File('lib/providers/chat_provider.dart').readAsStringSync();
    final models = File('lib/models/chat_models.dart').readAsStringSync();

    final pendingReceiptMutation = provider.indexOf(
      'activeSession.pendingWorkspaceImports.add(receipt)',
    );
    final firstSave = provider.indexOf(
      'await _storage.saveSession(',
      pendingReceiptMutation,
    );
    final acknowledgement = provider.indexOf(
      'await NativeBridge.acknowledgeWorkspaceImport(receipt)',
      firstSave,
    );
    expect(pendingReceiptMutation, greaterThan(0));
    expect(firstSave, greaterThan(pendingReceiptMutation));
    expect(acknowledgement, greaterThan(firstSave));
    expect(
      provider.substring(firstSave, acknowledgement),
      allOf(
        contains('activeSession'),
        contains('expectedGeneration: runToken.storageGeneration'),
      ),
    );
    expect(provider, contains('_reconcileWorkspaceImportsOnReload'));
    expect(provider, contains('_reconcileUnclaimedWorkspaceImports'));
    expect(provider, contains('NativeBridge.listPendingWorkspaceImports()'));
    expect(provider, contains('NativeBridge.discardWorkspaceImport(receipt)'));
    expect(provider, contains('pendingWorkspaceImports.removeWhere'));
    expect(models, contains("'pendingWorkspaceImports'"));
    expect(models, contains('WorkspaceImportReceipt.fromJson'));
  });
}
