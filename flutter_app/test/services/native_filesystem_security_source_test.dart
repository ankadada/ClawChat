import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('skill filesystem capability fails closed before pathname native I/O',
      () {
    final source =
        File('lib/services/skill_capability_policy.dart').readAsStringSync();

    expect(source, contains("'read_file' || 'write_file'"));
    expect(source, contains("'skill_filesystem_unenforceable'"));
    expect(source, contains('concurrent proot filesystem mutation'));
  });

  test('native normal file broker rejects symlinks and hard-link aliases', () {
    final source = File(
      'android/app/src/main/kotlin/com/anka/clawbot/BootstrapManager.kt',
    ).readAsStringSync();

    expect(source, contains('Files.isSymbolicLink(root)'));
    expect(source, contains('rejectSymlinkComponents(target)'));
    expect(source, contains('"unix:nlink"'));
    expect(source, contains('Hard-linked files are not allowed'));
    expect(source, contains('LinkOption.NOFOLLOW_LINKS'));
  });

  test('workspace import binds bytes to one native descriptor before write',
      () {
    final nativeSource = File(
      'android/app/src/main/cpp/secure_import.cpp',
    ).readAsStringSync();
    final bridgeSource =
        File('lib/services/native_bridge.dart').readAsStringSync();
    expect(nativeSource, contains('O_RDONLY | O_DIRECTORY | O_NOFOLLOW'));
    expect(nativeSource, contains('openat('));
    expect(nativeSource, contains('O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW'));
    expect(nativeSource, contains('read(source.get()'));
    expect(nativeSource, contains('write_all(destination.get()'));
    expect(nativeSource, contains('fsync(destination.get())'));
    expect(nativeSource, contains('fstatat(directory_fd'));
    expect(nativeSource, contains('AT_SYMLINK_NOFOLLOW'));
    expect(nativeSource, isNot(contains('ByteArrayOutputStream')));
    expect(RegExp(r'\blinkat\(').hasMatch(nativeSource), isFalse);
    expect(bridgeSource, contains("'importHostFileToWorkspace'"));
    expect(bridgeSource, contains("'acknowledgeHostFileImport'"));
    expect(bridgeSource, contains("'discardHostFileImport'"));
    final importStart = bridgeSource
        .indexOf('static Future<WorkspaceImportReceipt> importFileToWorkspace');
    expect(bridgeSource.indexOf("'destinationPath': destPath", importStart),
        greaterThan(importStart));
    expect(bridgeSource.indexOf("'bytes'", importStart), -1);
    expect(nativeSource, contains('is_safe_component(final_name, 212U)'));
    expect(nativeSource, contains('is_hex_operation(operation_id)'));
  });

  test('workspace source uses full initial and final snapshots', () {
    final source =
        File('android/app/src/main/cpp/secure_import.cpp').readAsStringSync();

    expect(source,
        contains('same_full_snapshot(source_path_before, source_before)'));
    expect(source, contains('same_full_snapshot(source_before, source_after)'));
    expect(source,
        contains('same_full_snapshot(source_after, source_path_after)'));
    expect(source, contains('left.st_nlink == right.st_nlink'));
    expect(source, contains('left.st_mode == right.st_mode'));
    expect(source, contains('left.st_size == right.st_size'));
    expect(source, contains('left.st_ctim.tv_sec == right.st_ctim.tv_sec'));
    expect(source, contains('left.st_ctim.tv_nsec == right.st_ctim.tv_nsec'));
  });

  test('native import cancellation owns copy and extraction processes', () {
    final activity = File(
      'android/app/src/main/kotlin/com/anka/clawbot/MainActivity.kt',
    ).readAsStringSync();
    final process = File(
      'android/app/src/main/kotlin/com/anka/clawbot/ProcessManager.kt',
    ).readAsStringSync();
    final secureImport =
        File('android/app/src/main/cpp/secure_import.cpp').readAsStringSync();

    expect(activity, contains('"cancelImportOperation"'));
    expect(
        activity, contains('SecureImportNative.cancelOperation(operationId)'));
    expect(activity, contains('processManager.cancelOperation(operationId)'));
    expect(secureImport, contains('require_not_cancelled(operation_id)'));
    expect(process,
        contains('activeOperations.putIfAbsent(operationId, process)'));
    expect(process, contains('if (existing != null)'));
    expect(process, contains('requestWaitingLaunchCleanup('));
    expect(process,
        contains('activeOperations[operationId]?.let { destroyDirectProcess'));
  });

  test('retryable command cleanup renews wake locks and restarts exact owners',
      () {
    final terminal = File(
      'android/app/src/main/kotlin/com/anka/clawbot/TerminalSessionService.kt',
    ).readAsStringSync();
    final agent = File(
      'android/app/src/main/kotlin/com/anka/clawbot/AgentTaskService.kt',
    ).readAsStringSync();

    expect(terminal, contains('renewCleanupWakeLock()'));
    expect(terminal, contains('acquireWakeLock(CLEANUP_WAKE_LOCK_HOLD_MS)'));
    expect(terminal, contains('owner.activeTerminalCandidates()'));
    expect(terminal, contains('restartPendingCleanup(candidate)'));
    expect(
        agent,
        contains(
            'acquireWakeLock(COMMAND_CLEANUP_WAKE_LOCK_MS, scheduleRenewal = false)'));
    expect(agent, contains('commandContinuations.activeKeys('));
    expect(agent, contains('restartPendingCommandCleanup(pendingCleanup)'));
  });

  test('durable command cleanup is shared, private, and job backed', () {
    final coordinator = File(
      'android/app/src/main/kotlin/com/anka/clawbot/CommandCleanupCoordinator.kt',
    ).readAsStringSync();
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    final activity = File(
      'android/app/src/main/kotlin/com/anka/clawbot/MainActivity.kt',
    ).readAsStringSync();
    final processManager = File(
      'android/app/src/main/kotlin/com/anka/clawbot/ProcessManager.kt',
    ).readAsStringSync();
    final agent = File(
      'android/app/src/main/kotlin/com/anka/clawbot/AgentTaskService.kt',
    ).readAsStringSync();
    final terminalRuntime =
        File('lib/services/terminal_runtime_session.dart').readAsStringSync();
    final terminalScreen =
        File('lib/screens/terminal_screen.dart').readAsStringSync();

    expect(coordinator, contains('AtomicCommandCleanupLedger'));
    expect(coordinator, contains('context.noBackupFilesDir'));
    expect(coordinator, contains('output.fd.sync()'));
    expect(coordinator, contains('StandardCopyOption.ATOMIC_MOVE'));
    expect(coordinator, contains('CRC32()'));
    expect(coordinator, contains('sessionHash'));
    expect(coordinator, contains('operationHash'));
    expect(coordinator, contains('candidateHash'));
    expect(coordinator, contains('setPersisted(true)'));
    expect(coordinator, contains('setBackoffCriteria'));
    expect(coordinator, contains('PidOwnedCommandProcess.fromGeneration'));
    expect(coordinator, contains('ProcessDisposalResult.RETRYABLE_UNKNOWN'));
    expect(coordinator, contains('MAX_RECORDS = 512'));
    expect(coordinator, contains('SPAWN_CAPABILITY_ISSUED'));
    expect(coordinator, contains('CANCEL_REQUESTED'));
    expect(coordinator, contains('launchTokenHash'));
    expect(coordinator, contains('parentStartTimeTicks'));
    expect(coordinator, contains('createDirectoryExclusive'));
    expect(coordinator, contains('createFileExclusive'));
    expect(coordinator, contains('claim.tmp.'));
    expect(coordinator, contains(r'''ln "${'$'}claim_temp"'''));
    expect(coordinator, contains('/system/bin/sync'));
    expect(coordinator, contains('normalizePublishedClaim'));
    expect(coordinator, contains('acknowledgeLaunchAbandoned'));
    expect(coordinator, contains('AttemptNodeClassification'));
    expect(coordinator, contains('classifyAttemptNode'));
    expect(coordinator, contains('isSafeAttemptEntry'));
    expect(coordinator, contains('recoverInvalidAttemptLocked'));
    expect(coordinator, contains('retireRecordLocked'));
    expect(coordinator, contains('bestEffortCleanupKnownValidAttempt'));
    expect(coordinator, contains('deviceId'));
    expect(coordinator, contains('inode'));
    expect(coordinator, contains('listEntriesIfSame'));
    expect(coordinator, contains('deleteFileIfSame'));
    expect(coordinator, contains('deleteEmptyDirectoryIfSame'));
    expect(coordinator, contains('AndroidLaunchSecureFileOps'));
    expect(coordinator, contains('Os.lstat'));
    expect(coordinator, contains('CommandAdmissionReason'));
    expect(coordinator, contains('BACKSTOP_SCHEDULE_REJECTED'));
    expect(
      coordinator,
      contains('launchFileOps = AndroidLaunchSecureFileOps()'),
    );
    expect(agent, contains('reserveAgentCommand'));
    expect(agent, contains('CommandReservationDecision'));
    expect(activity, contains('"PROOT_SERVICE_NOT_READY"'));
    expect(
      activity,
      contains('CommandAdmissionReason.SERVICE_NOT_READY.name'),
    );
    expect(coordinator, isNot(contains('moveNodeNoReplace')));
    expect(coordinator, isNot(contains('deleteTree')));
    expect(coordinator, isNot(contains('Files.walkFileTree')));
    expect(coordinator, isNot(contains('retired-command-cleanup')));
    expect(coordinator, isNot(contains('cleanupClassifiedAttemptNode')));
    expect(coordinator, isNot(contains('cleanupLaunchArtifacts')));
    expect(coordinator, isNot(contains('removeOrRetireNodeNoFollow')));
    final retireStart = coordinator.indexOf(
      'private fun retireRecordLocked',
    );
    final retireEnd = coordinator.indexOf(
      'private fun setPrivateFilePermissions',
      retireStart,
    );
    expect(retireStart, greaterThanOrEqualTo(0));
    expect(retireEnd, greaterThan(retireStart));
    expect(
      coordinator.substring(retireStart, retireEnd),
      isNot(contains('bestEffortCleanupKnownValidAttempt')),
    );
    expect(coordinator, contains('validateLaunchRoot'));
    expect(coordinator, isNot(contains('.canonicalFile')));
    expect(coordinator, contains('go.consumed'));
    expect(coordinator, isNot(contains(r'''mkdir "${'$'}attempt/claim"''')));
    expect(coordinator, isNot(contains("cut -d ' ' -f 22")));
    expect(coordinator, isNot(contains('awk ')));
    expect(coordinator, contains('BACKSTOP_PENDING'));
    expect(coordinator, contains('SIGNAL_INTENT'));
    expect(coordinator, contains('expected_parent'));
    expect(coordinator, contains('exec "\${\'\$\'}@"'));
    expect(coordinator, contains('LinkOption.NOFOLLOW_LINKS'));
    expect(coordinator, contains('fileOps.syncParent'));
    expect(coordinator, contains('input.available() != 0'));
    expect(coordinator, contains('duplicate record'));
    expect(coordinator, isNot(contains('command: String')));
    expect(coordinator, isNot(contains('environment:')));
    expect(coordinator, isNot(contains('callbackPayload')));
    expect(coordinator, isNot(contains('output: String')));
    final claimWrite = coordinator.indexOf('(set -C; printf');
    final claimSync = coordinator.indexOf(
      r'''durable_sync "${'$'}claim_temp"''',
      claimWrite,
    );
    final claimLink = coordinator.indexOf(
      r'''ln "${'$'}claim_temp" "${'$'}attempt/claim"''',
      claimSync,
    );
    final linkedDirectorySync = coordinator.indexOf(
      r'''durable_sync "${'$'}attempt"''',
      claimLink,
    );
    final unlinkBarrier = coordinator.indexOf(
      'Durable publication barrier:',
      linkedDirectorySync,
    );
    final tempUnlink = coordinator.indexOf(
      r'''rm -f "${'$'}claim_temp" || exit 118''',
      unlinkBarrier,
    );
    final unlinkedDirectorySync = coordinator.indexOf(
      r'''durable_sync "${'$'}attempt"''',
      tempUnlink,
    );
    expect(claimWrite, greaterThanOrEqualTo(0));
    expect(claimWrite, lessThan(claimSync));
    expect(claimSync, lessThan(claimLink));
    expect(claimLink, lessThan(linkedDirectorySync));
    expect(linkedDirectorySync, lessThan(unlinkBarrier));
    expect(linkedDirectorySync, lessThan(tempUnlink));
    expect(tempUnlink, lessThan(unlinkedDirectorySync));
    final normalizeStart = coordinator.indexOf(
      'private fun normalizePublishedClaim',
    );
    final normalizeValidation = coordinator.indexOf(
      'validateAttemptDirectory(paths, claimed = true)',
      normalizeStart,
    );
    final normalizeChildRead = coordinator.indexOf(
      'launchFileOps.metadata(paths.claimFile)',
      normalizeStart,
    );
    expect(normalizeStart, lessThan(normalizeValidation));
    expect(normalizeValidation, lessThan(normalizeChildRead));
    final revocationStart = coordinator.indexOf(
      'private fun createRevocationLocked',
    );
    final revocationValidation = coordinator.indexOf(
      'validateAttemptDirectory(paths, claimed = true)',
      revocationStart,
    );
    final revocationChildRead = coordinator.indexOf(
      'launchFileOps.metadata(paths.revokedFile)',
      revocationStart,
    );
    expect(revocationStart, lessThan(revocationValidation));
    expect(revocationValidation, lessThan(revocationChildRead));
    expect(manifest, contains('android.permission.RECEIVE_BOOT_COMPLETED'));
    expect(manifest, contains('.CommandCleanupJobService'));
    expect(manifest, contains('android.permission.BIND_JOB_SERVICE'));
    expect(activity, contains('CommandCleanupCoordinatorProvider.get'));
    expect(activity, contains('"prepareTerminalLaunch"'));
    expect(activity, contains('"validateTerminalLaunchCapability"'));
    expect(processManager, contains('coordinator.prepareLaunch('));
    expect(
        processManager, contains('startDirectCommand(cmd, env, operationId)'));
    final directStart =
        processManager.indexOf('private fun startDirectCommand');
    final continuationStart =
        processManager.indexOf('private fun startContinuationCommand');
    final directPath = processManager.substring(directStart, continuationStart);
    expect(
        directPath, contains('configuredProcessBuilder(command, environment)'));
    expect(directPath, isNot(contains('cleanupCoordinator')));
    expect(directPath, isNot(contains('NativeCommandContinuationOwner')));
    expect(directPath, isNot(contains('prepareLaunch')));
    expect(directPath, isNot(contains('/system/bin/sh')));
    expect(
      processManager.indexOf('coordinator.prepareLaunch('),
      lessThan(processManager
          .indexOf('configuredProcessBuilder(gatedCommand, env)')),
    );
    expect(
      processManager.indexOf('coordinator.validateLaunchCapability('),
      lessThan(processManager.indexOf('val process = try')),
    );
    expect(
      processManager.indexOf('coordinator.acknowledgeLaunchAbandoned('),
      lessThan(processManager.indexOf('val process = try')),
    );
    expect(terminalRuntime, contains("Pty.start(\n      '/system/bin/sh'"));
    expect(terminalRuntime, contains('launchGate.parentProcessId.toString()'));
    expect(
      terminalRuntime.indexOf('.prepareLaunch('),
      lessThan(terminalRuntime.indexOf('final process = _processLauncher(')),
    );
    expect(
      terminalRuntime.indexOf('.validateLaunchCapability('),
      lessThan(terminalRuntime.indexOf('final process = _processLauncher(')),
    );
    expect(
        terminalScreen, contains("Pty.start(\n        config['executable']!"));
    expect(terminalScreen, contains('_pty?.kill();'));
    expect(terminalScreen,
        contains('NativeBridge.stopTerminalService().ignore()'));
    expect(terminalScreen, isNot(contains('TerminalRuntimeSession.shared')));
    expect(terminalScreen, isNot(contains('prepareTerminalLaunch')));
  });

  test('native workspace publication rolls back every incomplete outcome', () {
    final source =
        File('android/app/src/main/cpp/secure_import.cpp').readAsStringSync();

    expect(source, contains('SYS_renameat2'));
    expect(source, contains('RENAME_NOREPLACE'));
    expect(source, contains('"PUBLISHING", temporary, final_name'));
    expect(source, contains('"PUBLISHED", temporary, final_name'));
    expect(source, contains('if (fsync(directory_fd) != 0)'));
    expect(source, contains('cleanup_failed_import('));
    expect(source, contains('"CLEANUP_REQUIRED"'));
    expect(source, contains('unlink_and_verify('));
    expect(source, contains('cleanup_final'));
    expect(source, contains('destination_digest != copied_digest'));
    expect(source, contains('same_full_snapshot(destination_before_publish'));
    expect(source, contains('published_digest != destination_digest'));
  });

  test('startup reconciliation retains uncertain finals and removes temps', () {
    final source =
        File('android/app/src/main/cpp/secure_import.cpp').readAsStringSync();

    expect(
      source,
      contains(
        'reconcile_directory(directory.get(), journal_directory.get())',
      ),
    );
    expect(source, contains('record.state == "PREPARED"'));
    expect(source, contains('record.state == "PUBLISHING"'));
    expect(source, contains('operation_active(operation_id)'));
    expect(source, contains('std::mutex g_journal_scan_mutex'));
    expect(source, contains('g_journal_mutexes'));
    expect(source, contains('journal_mutex_for(operation_id)'));
    expect(source, isNot(contains('std::mutex g_journal_mutex;')));
    expect(source, contains('if (!final_exists)'));
    expect(source, contains('cleanup_record_locked('));
    expect(source, contains('kReconcileWorkLimit'));
    expect(source, contains('g_reconcile_offsets'));
    expect(source, contains('g_pending_list_offsets'));
    expect(source, contains('list_pending_records'));
    expect(source, contains('kJournalDirectory = ".clawchat-import-journals"'));
    expect(source, contains('mkdirat(uploads_fd, kJournalDirectory, 0700)'));
    expect(source, contains('fdopendir(duplicate)'));
    expect(
      source,
      contains('const int duplicate = dup(journal_fd)'),
    );
    expect(source, contains('std::vector<std::string> operations'));
    final reconciliation = source.substring(
      source.indexOf('void reconcile_directory'),
      source.indexOf(
        'int rename_noreplace',
        source.indexOf('void reconcile_directory'),
      ),
    );
    expect(
      reconciliation,
      isNot(contains('record.cleanup_final = true')),
    );
    expect(
      reconciliation.indexOf('for (const std::string& operation_id'),
      greaterThan(reconciliation.indexOf('closedir(stream.release())')),
    );
  });

  test('journal scans bound junk entries and advance an opaque cursor', () {
    final source =
        File('android/app/src/main/cpp/secure_import.cpp').readAsStringSync();
    final scanStart =
        source.indexOf('JournalScanBatch scan_journal_directory_bounded');
    final scanEnd = source.indexOf(
      'void retain_corrupt_journal_evidence_locked',
      scanStart,
    );
    final scan = source.substring(scanStart, scanEnd);

    final budgetCheck = scan.indexOf('batch.read_steps < max_read_steps');
    final stepIncrement = scan.indexOf('++batch.read_steps');
    final read = scan.indexOf('readdir(stream)');
    final cookie = scan.indexOf('batch.next_cookie = cookie_after_entry');
    final nameFilter = scan.indexOf('if (!journal_filename(name)');
    expect(budgetCheck, greaterThan(0));
    expect(stepIncrement, greaterThan(budgetCheck));
    expect(read, greaterThan(stepIncrement));
    expect(cookie, greaterThan(read));
    expect(nameFilter, greaterThan(cookie));
    expect(scan, contains('std::chrono::steady_clock::now() < deadline'));
    expect(scan, contains('require_not_cancelled(*cancellation_operation)'));
    expect(source, isNot(contains('std::sort(')));

    final reconciliationStart = source.indexOf('void reconcile_directory');
    final reconciliation = source.substring(
      reconciliationStart,
      source.indexOf('int rename_noreplace', reconciliationStart),
    );
    final pending = source.substring(
      source.indexOf('std::vector<std::string> list_pending_records'),
      source.indexOf('jobjectArray string_array'),
    );
    expect(reconciliation, contains('scan_journal_directory_bounded('));
    expect(
        reconciliation, contains('batch.reached_end ? 0L : batch.next_cookie'));
    expect(pending, contains('scan_journal_directory_bounded('));
    expect(pending, contains('batch.reached_end ? 0L : batch.next_cookie'));

    const cap = 64;
    final entries = <String>[
      for (var index = 0; index < 2048; index++) '000-junk-$index',
      '.clawchat-import-${'a' * 32}.journal',
      for (var index = 0; index < 2048; index++) 'mid-junk-$index',
      '.clawchat-import-${'b' * 32}.journal',
    ];
    var cursor = 0;
    var passes = 0;
    final found = <String>[];
    while (cursor < entries.length) {
      final end = (cursor + cap).clamp(0, entries.length);
      final batch = entries.sublist(cursor, end);
      expect(batch.length, lessThanOrEqualTo(cap));
      found.addAll(batch.where((name) => name.endsWith('.journal')));
      cursor = end;
      passes++;
    }
    expect(passes, greaterThan(64));
    expect(found, hasLength(2));

    final cookieOrdered = <String>[
      for (var index = 0; index < 128; index++) 'junk-$index',
      '.clawchat-import-${'c' * 32}.journal',
    ];
    cursor = 0;
    var foundAfterLexicalJunk = false;
    for (var pass = 0; pass < 4; pass++) {
      final end = (cursor + cap).clamp(0, cookieOrdered.length);
      final batch = cookieOrdered.sublist(cursor, end);
      foundAfterLexicalJunk |= batch.any((name) => name.endsWith('.journal'));
      cursor = end;
      cookieOrdered.add('000-lexically-earlier-attacker-$pass');
    }
    expect(foundAfterLexicalJunk, isTrue);
  });

  test('journals are checksumed atomic replacements and never truncated', () {
    final source =
        File('android/app/src/main/cpp/secure_import.cpp').readAsStringSync();
    final writeStart = source.indexOf('void write_journal_atomic_locked');
    final writeEnd = source.indexOf('void write_journal_atomic(', writeStart);
    final writer = source.substring(writeStart, writeEnd);

    expect(source, contains('CLAWCHAT_IMPORT_JOURNAL_V1'));
    expect(source, contains('length='));
    expect(source, contains('checksum='));
    expect(source, contains('content.size() - offset != body_length'));
    expect(source, contains('hash_string(body) != checksum'));
    expect(source, contains('count <= 0) return JournalReadStatus::corrupt'));
    expect(writer, contains('O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW'));
    expect(writer, contains('fsync(replacement.get())'));
    expect(writer, contains('replacement.close_checked'));
    expect(writer, contains('renameat(directory_fd, next.c_str()'));
    expect(writer, contains('fsync(directory_fd)'));
    expect(writer, isNot(contains('ftruncate')));
    expect(source, contains('JournalReadStatus::corrupt'));
    expect(source, contains('journal_evidence_name'));
    expect(source, contains('retain_corrupt_journal_evidence_locked'));
  });

  test('journal transition crash boundaries have idempotent recovery paths',
      () {
    final source =
        File('android/app/src/main/cpp/secure_import.cpp').readAsStringSync();
    final recoverStart =
        source.indexOf('void recover_pending_replacement_locked');
    final recoverEnd =
        source.indexOf('void write_journal_atomic_locked', recoverStart);
    final recovery = source.substring(recoverStart, recoverEnd);
    final writerStart = source.indexOf('void write_journal_atomic_locked');
    final writerEnd = source.indexOf('void write_journal_atomic(', writerStart);
    final writer = source.substring(writerStart, writerEnd);

    final writeIndex = writer.indexOf('write_all(');
    final fileSyncIndex = writer.indexOf('fsync(replacement.get())');
    final closeIndex = writer.indexOf('replacement.close_checked');
    final renameIndex = writer.indexOf('renameat(directory_fd, next.c_str()');
    final parentSyncIndex = writer.indexOf('fsync(directory_fd)');
    expect(writeIndex, greaterThan(0));
    expect(fileSyncIndex, greaterThan(writeIndex));
    expect(closeIndex, greaterThan(fileSyncIndex));
    expect(renameIndex, greaterThan(closeIndex));
    expect(parentSyncIndex, greaterThan(renameIndex));

    expect(recovery, contains('JournalReadStatus::missing'));
    expect(recovery, contains('JournalReadStatus::corrupt'));
    expect(recovery, contains('quarantine_next_locked'));
    expect(recovery, contains('renameat(directory_fd, next.c_str()'));
    expect(recovery, contains('fsync(directory_fd)'));
    expect(source, contains('record.state == "PUBLISHING"'));
    expect(source, contains('verify_receipt_file(uploads_fd, record'));
    expect(source, contains('record.state = "PUBLISHED"'));
  });

  test('repeated torn replacements merge into bounded durable evidence', () {
    final source =
        File('android/app/src/main/cpp/secure_import.cpp').readAsStringSync();
    final quarantineStart = source.indexOf('struct CorruptEvidenceSummary');
    final quarantineEnd = source.indexOf(
      'void recover_pending_replacement_locked',
      quarantineStart,
    );
    final quarantine = source.substring(quarantineStart, quarantineEnd);

    expect(source, contains('kCorruptEvidenceSlotBytes = 256U'));
    expect(source, contains('kCorruptEvidenceFileBytes = 2U *'));
    expect(source, contains('.journal.corrupt.summary'));
    expect(quarantine, contains('CLAWCHAT_CORRUPT_EVIDENCE_V1'));
    expect(quarantine, contains('std::array<std::string, 2> slots'));
    expect(quarantine, contains('candidate.generation > current.generation'));
    expect(
        quarantine, contains('updated.generation = current.generation + 1U'));
    expect(quarantine, contains('updated.count = current.count + 1U'));
    expect(
        quarantine,
        contains(
            'updated.chain = hash_string(current.chain + ":" + fingerprint)'));
    expect(quarantine,
        contains('const int target_slot = current.active_slot == 0 ? 1 : 0'));

    final quarantineFunction = quarantine.substring(
      quarantine.indexOf('void quarantine_next_locked'),
    );
    final evidenceWrite = quarantineFunction.indexOf('pwrite_all(');
    final evidenceFsync =
        quarantineFunction.indexOf('fsync(summary.get())', evidenceWrite);
    final evidenceClose =
        quarantineFunction.indexOf('summary.close_checked', evidenceFsync);
    final evidenceDirFsync =
        quarantineFunction.indexOf('fsync(directory_fd)', evidenceClose);
    final removeNext = quarantineFunction.indexOf(
        'unlinkat(directory_fd, next.c_str()', evidenceDirFsync);
    final verifyAbsent = quarantineFunction.indexOf(
        'fstatat(directory_fd, next.c_str()', removeNext);
    final removalFsync =
        quarantineFunction.indexOf('fsync(directory_fd)', verifyAbsent);
    expect(evidenceWrite, greaterThan(0));
    expect(evidenceFsync, greaterThan(evidenceWrite));
    expect(evidenceClose, greaterThan(evidenceFsync));
    expect(evidenceDirFsync, greaterThan(evidenceClose));
    expect(removeNext, greaterThan(evidenceDirFsync));
    expect(verifyAbsent, greaterThan(removeNext));
    expect(removalFsync, greaterThan(verifyAbsent));
    expect(
      quarantineFunction,
      isNot(contains('unlinkat(directory_fd, evidence.c_str()')),
    );

    var chain = '0' * 64;
    var count = 0;
    for (final torn in const ['partial-one', 'partial-two', 'partial-three']) {
      final sampleHash = sha256.convert(utf8.encode(torn)).toString();
      final fingerprint = '${torn.length}:$sampleHash';
      chain = sha256.convert(utf8.encode('$chain:$fingerprint')).toString();
      count++;
    }
    expect(count, 3);
    expect(chain, hasLength(64));
    expect(chain, isNot('0' * 64));
  });

  test('cleanup retains durable evidence until absence is proven', () {
    final source =
        File('android/app/src/main/cpp/secure_import.cpp').readAsStringSync();
    final cleanupStart = source.indexOf('bool retain_cleanup_evidence_locked');
    final cleanupEnd = source.indexOf('bool verify_receipt_file', cleanupStart);
    final cleanup = source.substring(cleanupStart, cleanupEnd);

    expect(cleanup, contains('unlink_and_verify'));
    expect(cleanup, contains('record.state = "CLEANUP_REQUIRED"'));
    expect(cleanup,
        contains('record.error = errno_class(error == 0 ? EIO : error)'));
    expect(cleanup, contains('write_journal_atomic_locked'));
    expect(cleanup.indexOf('fsync(uploads_fd)'),
        lessThan(cleanup.indexOf('journal_name(operation_id)')));
    expect(cleanup, contains('if (!unlink_and_verify'));
    expect(cleanup, contains('if (fsync(journal_fd) != 0)'));
    expect(cleanup, contains('retain_cleanup_evidence_locked'));
  });

  test('JNI paths use standard UTF-8 conversion and ACK runs off UI thread',
      () {
    final source =
        File('android/app/src/main/cpp/secure_import.cpp').readAsStringSync();
    final activity = File(
      'android/app/src/main/kotlin/com/anka/clawbot/MainActivity.kt',
    ).readAsStringSync();

    expect(source, contains('GetStringChars'));
    expect(source, contains('ReleaseStringChars'));
    expect(source, contains('0x10000U'));
    expect(source, contains('0xf0U | (code_point >> 18U)'));
    expect(source, isNot(contains('GetStringUTFChars')));
    expect(activity, contains('secureImportExecutor.execute'));
    expect(activity, contains('SecureImportNative.acknowledgeImport('));
    expect(activity, contains('SecureImportNative.discardImport('));
    expect(activity, contains('secureImportExecutor.shutdownNow()'));
  });

  test('staged reads reject oversized snapshots before bounded allocation', () {
    final source =
        File('android/app/src/main/cpp/secure_import.cpp').readAsStringSync();
    final sizeCheck =
        source.indexOf('source.descriptor_before.st_size > max_bytes_value');
    final allocation = source.indexOf('bytes.reserve(');

    expect(sizeCheck, greaterThan(0));
    expect(allocation, greaterThan(sizeCheck));
    expect(source, contains('bytes.size() + static_cast<size_t>(count)'));
    expect(
        source, contains('same_full_snapshot(descriptor_after, path_after)'));
    expect(
        source, contains('open_relative_regular(root.get(), relative_path)'));
    expect(source, contains('O_RDONLY | O_DIRECTORY | O_NOFOLLOW'));
    expect(source, contains('fstatat('));
  });

  test('JNI helper is required and pathname destination fallback is absent',
      () {
    final gradle = File('android/app/build.gradle').readAsStringSync();
    final kotlin = File(
      'android/app/src/main/kotlin/com/anka/clawbot/SecureImportNative.kt',
    ).readAsStringSync();
    final activity = File(
      'android/app/src/main/kotlin/com/anka/clawbot/MainActivity.kt',
    ).readAsStringSync();

    expect(gradle, contains('externalNativeBuild'));
    expect(gradle, contains('src/main/cpp/CMakeLists.txt'));
    expect(kotlin, contains('System.loadLibrary("secure_import")'));
    expect(kotlin, contains('external fun importHostFile'));
    expect(kotlin, contains('external fun readFileBounded'));
    expect(activity, contains('SecureImportNative.importHostFile('));
    expect(activity, isNot(contains('Files.move(')));
    expect(activity, isNot(contains('Os.link(')));
  });
}
