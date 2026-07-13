package com.anka.clawbot

import java.io.File
import java.nio.ByteBuffer
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.attribute.PosixFilePermission
import java.util.ArrayDeque
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.zip.CRC32
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CommandCleanupCoordinatorTest {
    private fun CommandCleanupCoordinator.register(
        key: CommandOwnerKey,
        candidateId: String?,
        processId: Int,
        startTimeTicks: Long,
        deadlineEpochMs: Long,
    ): Boolean {
        val preparation = prepareLaunch(key, candidateId, deadlineEpochMs)
        if (preparation.outcome !=
            DurableLaunchRegistrationOutcome.DURABLY_REGISTERED_BACKSTOP_SCHEDULED) return false
        stageLaunch(preparation, processId, startTimeTicks)
        val activated = activateWaitingLaunch(
            key,
            candidateId,
            requireNotNull(preparation.attemptId),
            requireNotNull(preparation.launchToken),
            processId,
            PidProcessProbe { PidProbeResult.Present(startTimeTicks) },
        )
        return activated != null
    }

    @Test
    fun ownershipAttachIsBlockedUntilDurableRegistrationSucceeds() {
        val registry = CommandContinuationRegistry(nowEpochMs = { 1_000L })
        val key = terminalKey("durable-session", "durable-operation")
        val process = FakeOwnedProcess("durable-pid")
        assertEquals(CommandReserveOutcome.NEW, registry.reserveTerminal(key, "candidate", 60_000L))
        assertEquals(
            CandidateReceipt.UNKNOWN,
            registry.attachTerminal(key, "candidate", process) { false },
        )
        assertTrue(registry.isActiveCandidate(key, "candidate"))
        assertEquals(
            CandidateReceipt.NATIVE_OWNS,
            registry.attachTerminal(key, "candidate", process) { true },
        )
    }

    @Test
    fun rejectedFgsRestartAndMissingServiceIntentStillLeaveCoordinatorCleanup() {
        val ledger = FakeLedger()
        val scheduler = FakeImmediateScheduler()
        val backstop = FakeBackstop()
        val disposals = ArrayDeque(
            listOf(
                ProcessDisposalResult.RETRYABLE_UNKNOWN,
                ProcessDisposalResult.DISPOSED,
            )
        )
        val coordinator = coordinator(ledger, scheduler, backstop) { disposals.removeFirst() }
        coordinator.initialize()
        val key = terminalKey("fgs-rejected", "operation")
        assertTrue(coordinator.register(key, "candidate", 101, 11L, 60_000L))

        // Service onDestroy hands off before a best-effort FGS restart. The
        // restart is deliberately never delivered in this test.
        coordinator.requestCleanup(key, "candidate")
        assertEquals(CleanupDisposalState.SIGNAL_INTENT, ledger.records.single().disposalState)
        assertTrue(backstop.scheduledDelays.isNotEmpty())
        scheduler.runNext()
        assertEquals(1, ledger.records.size)
        scheduler.runNext()
        assertTrue(ledger.records.isEmpty())
        assertTrue(backstop.cancelCount > 0)
    }

    @Test
    fun freshProcessBlocksSameSessionUntilGenerationAwareCleanupCompletes() {
        val directory = Files.createTempDirectory("cleanup-recreate").toFile()
        val file = File(directory, "ledger.bin")
        val firstLedger = AtomicCommandCleanupLedger(file)
        val first = coordinator(firstLedger, FakeImmediateScheduler(), FakeBackstop()) {
            ProcessDisposalResult.RETRYABLE_UNKNOWN
        }
        first.initialize()
        val key = terminalKey("recreated-session", "old-operation")
        assertTrue(first.register(key, "old-candidate", 202, 22L, 60_000L))

        val results = ArrayDeque(
            listOf(
                ProcessDisposalResult.RETRYABLE_UNKNOWN,
                ProcessDisposalResult.DISPOSED,
            )
        )
        val recreated = coordinator(
            AtomicCommandCleanupLedger(file),
            FakeImmediateScheduler(),
            FakeBackstop(),
        ) { results.removeFirst() }
        recreated.initialize()
        assertFalse(recreated.canAdmit(CommandContinuationOwner.TERMINAL, "recreated-session"))
        assertEquals(CleanupDisposalState.SIGNAL_INTENT, recreated.recordsForTest().single().disposalState)
        recreated.reconcile()
        assertTrue(recreated.canAdmit(CommandContinuationOwner.TERMINAL, "recreated-session"))
    }

    @Test
    fun multipleOwnersAndSessionsAreBlockedIndependently() {
        val coordinator = coordinator(FakeLedger(), FakeImmediateScheduler(), FakeBackstop()) {
            ProcessDisposalResult.RETRYABLE_UNKNOWN
        }
        coordinator.initialize()
        assertTrue(coordinator.register(terminalKey("terminal-a", "op-a"), "candidate-a", 301, 31L, 60_000L))
        assertTrue(coordinator.register(agentKey("agent-a", "op-b"), null, 302, 32L, 60_000L))
        assertTrue(coordinator.register(agentKey("agent-b", "op-c"), null, 303, 33L, 60_000L))
        assertFalse(coordinator.canAdmit(CommandContinuationOwner.TERMINAL, "terminal-a"))
        assertFalse(coordinator.canAdmit(CommandContinuationOwner.AGENT_BASH, "agent-a"))
        assertFalse(coordinator.canAdmit(CommandContinuationOwner.AGENT_BASH, "agent-b"))
        assertTrue(coordinator.canAdmit(CommandContinuationOwner.TERMINAL, "terminal-b"))
    }

    @Test
    fun pidReuseProbeFailureSignalFailureAndRetryAreGenerationSafe() {
        val signalCount = AtomicInteger()
        val probes = ArrayDeque<PidProbeResult>(
            listOf(
                PidProbeResult.RetryableUnknown,
                PidProbeResult.Present(99L),
                PidProbeResult.Present(44L),
                PidProbeResult.Present(44L),
                PidProbeResult.Missing,
            )
        )
        var failSignal = true
        val disposer = CleanupProcessDisposer { record ->
            val process = PidOwnedCommandProcess.fromGeneration(
                record.processId,
                record.startTimeTicks,
                PidProcessProbe { probes.removeFirst() },
                PidProcessSignaler {
                    signalCount.incrementAndGet()
                    if (failSignal) {
                        failSignal = false
                        throw IllegalStateException("signal failed")
                    }
                },
            )
            CleanupDisposalAttempt(process.dispose())
        }

        val unknownRecord = record("unknown", 401, 44L)
        assertEquals(ProcessDisposalResult.RETRYABLE_UNKNOWN, disposer.dispose(unknownRecord).result)
        val reusedRecord = record("reused", 401, 44L)
        assertEquals(
            ProcessDisposalResult.VERIFIED_GONE_OR_REUSED,
            disposer.dispose(reusedRecord).result,
        )
        assertEquals(0, signalCount.get())
        val retryRecord = record("retry", 401, 44L)
        assertEquals(ProcessDisposalResult.RETRYABLE_UNKNOWN, disposer.dispose(retryRecord).result)
        assertEquals(1, signalCount.get())
        assertEquals(ProcessDisposalResult.DISPOSED, disposer.dispose(retryRecord).result)
        assertEquals(2, signalCount.get())
    }

    @Test
    fun ledgerRoundTripMigratesSchemaOneAndRejectsCorruptionAndTruncation() {
        val directory = Files.createTempDirectory("cleanup-ledger").toFile()
        val file = File(directory, "ledger.bin")
        val expected = listOf(record("roundtrip", 501, 51L))
        val v1 = AtomicCommandCleanupLedger(file, writeSchemaVersion = 1)
        assertTrue(v1.write(expected))
        val migrated = AtomicCommandCleanupLedger(file).read() as CleanupLedgerRead.Success
        assertEquals(1L, migrated.records.single().disposalVersion)
        assertTrue(AtomicCommandCleanupLedger(file).write(migrated.records))
        assertEquals(
            expected.single().copy(launchExpiresEpochMs = expected.single().deadlineEpochMs),
            (AtomicCommandCleanupLedger(file).read() as CleanupLedgerRead.Success).records.single(),
        )

        val bytes = file.readBytes()
        file.writeBytes(bytes.copyOf().apply { this[lastIndex] = (this[lastIndex].toInt() xor 1).toByte() })
        assertTrue(AtomicCommandCleanupLedger(file).read() is CleanupLedgerRead.Corrupt)
        file.writeBytes(bytes.copyOf(7))
        assertTrue(AtomicCommandCleanupLedger(file).read() is CleanupLedgerRead.Corrupt)
    }

    @Test
    fun corruptLedgerFailsClosedWithoutCallingDisposer() {
        val calls = AtomicInteger()
        val coordinator = coordinator(
            FakeLedger(CleanupLedgerRead.Corrupt("injected")),
            FakeImmediateScheduler(),
            FakeBackstop(),
        ) {
            calls.incrementAndGet()
            ProcessDisposalResult.DISPOSED
        }
        coordinator.initialize()
        assertTrue(coordinator.isCorruptForTest())
        assertFalse(coordinator.canAdmit(CommandContinuationOwner.TERMINAL, "blocked"))
        assertEquals(0, calls.get())
    }

    @Test
    fun fullDurableLedgerFailsNewAdmissionClosedWithoutEviction() {
        val directory = Files.createTempDirectory("cleanup-capacity").toFile()
        val ledger = AtomicCommandCleanupLedger(File(directory, "ledger.bin"))
        val full = List(512) { index -> record("capacity-$index", 10_000 + index, index.toLong()) }
        assertTrue(ledger.write(full))
        val coordinator = coordinator(ledger, FakeImmediateScheduler(), FakeBackstop()) {
            ProcessDisposalResult.RETRYABLE_UNKNOWN
        }
        coordinator.initialize()

        assertFalse(
            coordinator.register(
                terminalKey("overflow-session", "overflow-operation"),
                "overflow-candidate",
                20_000,
                20_000L,
                60_000L,
            ),
        )
        assertEquals(512, coordinator.recordsForTest().size)
    }

    @Test
    fun ledgerContainsOnlyHashedSessionAndNoCommandUrlOrSecret() {
        val directory = Files.createTempDirectory("cleanup-privacy").toFile()
        val file = File(directory, "ledger.bin")
        val ledger = AtomicCommandCleanupLedger(file)
        val coordinator = coordinator(ledger, FakeImmediateScheduler(), FakeBackstop()) {
            ProcessDisposalResult.RETRYABLE_UNKNOWN
        }
        coordinator.initialize()
        val rawSession = "private-session-title"
        val operationId = "opaque-operation"
        val candidateId = "opaque-candidate"
        val forbidden = listOf(
            "curl https://secret.example/callback",
            "TOKEN=super-secret",
            operationId,
            candidateId,
        )
        assertTrue(coordinator.register(terminalKey(rawSession, operationId), candidateId, 601, 61L, 60_000L))
        val persisted = file.readBytes().toString(Charsets.ISO_8859_1)
        assertFalse(persisted.contains(rawSession))
        forbidden.forEach { assertFalse(persisted.contains(it)) }
        assertEquals(
            CommandCleanupCoordinator.sessionHash(CommandContinuationOwner.TERMINAL, rawSession),
            (ledger.read() as CleanupLedgerRead.Success).records.single().sessionHash,
        )
    }

    @Test
    fun issuedCapabilityLedgerRoundTripsExactParentGenerationWithoutRawIdentity() {
        val directory = Files.createTempDirectory("issued-parent-ledger").toFile()
        val ledgerFile = File(directory, "ledger.bin")
        val coordinator = CommandCleanupCoordinator(
            ledger = AtomicCommandCleanupLedger(ledgerFile),
            disposer = CleanupProcessDisposer {
                CleanupDisposalAttempt(ProcessDisposalResult.RETRYABLE_UNKNOWN)
            },
            immediateScheduler = FakeImmediateScheduler(),
            backstop = FakeBackstop(),
            launchDirectory = File(directory, "launch"),
            recoveryProbe = PidProcessProbe { PidProbeResult.Present(777L) },
            parentProcessId = { 12_345 },
            nowEpochMs = { 1_000L },
        )
        coordinator.initialize()
        val launch = coordinator.prepareLaunch(
            terminalKey("private-parent-session", "operation"),
            "candidate",
            60_000L,
        )
        val persisted = (AtomicCommandCleanupLedger(ledgerFile).read() as CleanupLedgerRead.Success)
            .records.single()
        assertEquals(12_345, persisted.parentProcessId)
        assertEquals(777L, persisted.parentStartTimeTicks)
        assertTrue(persisted.attemptHash != null)
        assertTrue(persisted.launchTokenHash != null)
        val bytes = ledgerFile.readBytes().toString(Charsets.ISO_8859_1)
        assertFalse(bytes.contains("private-parent-session"))
        assertFalse(bytes.contains(requireNotNull(launch.launchToken)))
    }

    @Test
    fun concurrentServiceAndJobCleanupShareOneInFlightAttempt() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val signals = AtomicInteger()
        val coordinator = coordinator(FakeLedger(), FakeImmediateScheduler(), FakeBackstop()) {
            signals.incrementAndGet()
            entered.countDown()
            assertTrue(release.await(5, TimeUnit.SECONDS))
            ProcessDisposalResult.DISPOSED
        }
        coordinator.initialize()
        val key = terminalKey("concurrent", "operation")
        assertTrue(coordinator.register(key, "candidate", 701, 71L, 60_000L))
        coordinator.requestCleanup(key, "candidate")
        val first = Thread { coordinator.reconcile() }.apply { start() }
        assertTrue(entered.await(5, TimeUnit.SECONDS))
        val second = Thread { coordinator.reconcile() }.apply { start() }
        second.join(5_000L)
        release.countDown()
        first.join(5_000L)
        assertEquals(1, signals.get())
        assertTrue(coordinator.recordsForTest().isEmpty())
    }

    @Test
    fun durableSignalIntentAllowsSafeRepeatForSameGeneration() {
        val ledger = FakeLedger()
        val scheduler = FakeImmediateScheduler()
        val backstop = FakeBackstop()
        val signals = AtomicInteger()
        var first = true
        val coordinator = CommandCleanupCoordinator(
            ledger = ledger,
            disposer = CleanupProcessDisposer {
                signals.incrementAndGet()
                if (first) {
                    first = false
                    CleanupDisposalAttempt(ProcessDisposalResult.RETRYABLE_UNKNOWN)
                } else {
                    CleanupDisposalAttempt(ProcessDisposalResult.DISPOSED)
                }
            },
            immediateScheduler = scheduler,
            backstop = backstop,
            launchDirectory = Files.createTempDirectory("signal-launch").toFile(),
            recoveryProbe = PidProcessProbe { PidProbeResult.Present(75L) },
            parentProcessId = ::currentProcessId,
            nowEpochMs = { 1_000L },
        )
        coordinator.initialize()
        val key = terminalKey("safe-repeat", "operation")
        assertTrue(coordinator.register(key, "candidate", 751, 75L, 60_000L))
        assertTrue(coordinator.requestCleanup(key, "candidate"))

        scheduler.runNext()
        assertEquals(CleanupDisposalState.SIGNAL_INTENT, ledger.records.single().disposalState)
        scheduler.runNext()
        assertEquals(2, signals.get())
        assertTrue(ledger.records.isEmpty())
    }

    @Test
    fun backstopUsesBoundedRetryAndCancelsWhenLedgerBecomesEmpty() {
        val scheduler = FakeImmediateScheduler()
        val backstop = FakeBackstop()
        val coordinator = coordinator(FakeLedger(), scheduler, backstop) {
            ProcessDisposalResult.DISPOSED
        }
        coordinator.initialize()
        val key = agentKey("job-session", "job-operation")
        assertTrue(coordinator.register(key, null, 801, 81L, 60_000L))
        assertTrue(backstop.scheduledDelays.single() in 500L..60_000L)
        coordinator.requestCleanup(key)
        assertEquals(0L, backstop.scheduledDelays.last())
        scheduler.runNext()
        assertTrue(backstop.cancelCount > 0)
    }

    @Test
    fun initialBackstopRejectionRetainsDurableBlockAndFailsOwnershipClosed() {
        val ledger = FakeLedger()
        val backstop = FakeBackstop(acceptSchedules = false)
        val coordinator = coordinator(ledger, FakeImmediateScheduler(), backstop) {
            ProcessDisposalResult.DISPOSED
        }
        coordinator.initialize()

        assertFalse(
            coordinator.register(
                terminalKey("backstop-rejected", "operation"),
                "candidate",
                901,
                91L,
                60_000L,
            ),
        )
        assertEquals(1, ledger.records.size)
        assertEquals(
            CleanupDisposalState.BACKSTOP_PENDING,
            ledger.records.single().disposalState,
        )
        assertFalse(
            coordinator.canAdmit(
                CommandContinuationOwner.TERMINAL,
                "backstop-rejected",
            ),
        )
    }

    @Test
    fun crashSafeEnvelopePromotesImmediateSuccessorAndRejectsUnprovenMissingMain() {
        val directory = Files.createTempDirectory("ledger-recovery").toFile()
        val main = File(directory, "ledger.bin")
        val next = File(directory, "ledger.bin.next")
        val first = record("generation-one", 1_001, 101L)
        val second = record("generation-two", 1_002, 102L)
        val ledger = AtomicCommandCleanupLedger(main)
        assertTrue(ledger.write(listOf(first)))
        val generationOne = main.readBytes()
        assertTrue(ledger.write(listOf(first, second)))
        val generationTwo = main.readBytes()

        main.writeBytes(generationOne)
        next.writeBytes(generationTwo)
        val promoted = AtomicCommandCleanupLedger(main).read() as CleanupLedgerRead.Success
        assertEquals(2, promoted.records.size)
        assertEquals(2L, promoted.generation)
        assertFalse(next.exists())

        Files.move(
            main.toPath(),
            next.toPath(),
            StandardCopyOption.REPLACE_EXISTING,
        )
        assertTrue(AtomicCommandCleanupLedger(main).read() is CleanupLedgerRead.Corrupt)
        assertFalse(main.exists())
        assertTrue(next.exists())
    }

    @Test
    fun envelopeRejectsHeaderFlipTrailingBytesDuplicatesAndCorruptMain() {
        val directory = Files.createTempDirectory("ledger-corruption").toFile()
        val main = File(directory, "ledger.bin")
        val next = File(directory, "ledger.bin.next")
        val item = record("strict", 1_101, 111L)
        assertTrue(AtomicCommandCleanupLedger(main).write(listOf(item)))
        val valid = main.readBytes()

        next.writeBytes(valid.copyOf(7))
        assertEquals(
            listOf(item),
            (AtomicCommandCleanupLedger(main).read() as CleanupLedgerRead.Success).records,
        )
        assertFalse(next.exists())

        main.writeBytes(valid.copyOf().apply { this[4] = (this[4].toInt() xor 1).toByte() })
        assertTrue(AtomicCommandCleanupLedger(main).read() is CleanupLedgerRead.Corrupt)
        main.writeBytes(valid + byteArrayOf(0))
        assertTrue(AtomicCommandCleanupLedger(main).read() is CleanupLedgerRead.Corrupt)
        main.writeBytes(rewriteSchemaWithValidCrc(valid, 1))
        assertTrue(AtomicCommandCleanupLedger(main).read() is CleanupLedgerRead.Corrupt)
        assertFalse(AtomicCommandCleanupLedger(main).write(listOf(item, item)))
    }

    @Test
    fun envelopeRejectsUnknownCorruptMainEvenWhenNextLooksNewerOrOlder() {
        val directory = Files.createTempDirectory("ledger-generation-recovery").toFile()
        val main = File(directory, "ledger.bin")
        val next = File(directory, "ledger.bin.next")
        val first = record("generation-old", 1_151, 115L)
        val second = record("generation-new", 1_152, 116L)
        val writer = AtomicCommandCleanupLedger(main)
        assertTrue(writer.write(listOf(first)))
        val older = main.readBytes()
        assertTrue(writer.write(listOf(first, second)))
        val newer = main.readBytes()

        main.writeBytes(newer.copyOf(9))
        next.writeBytes(newer)
        assertTrue(AtomicCommandCleanupLedger(main).read() is CleanupLedgerRead.Corrupt)
        assertTrue(next.exists())

        main.writeBytes(newer)
        next.writeBytes(older)
        val noRollback = AtomicCommandCleanupLedger(main).read() as CleanupLedgerRead.Success
        assertEquals(2L, noRollback.generation)
        assertEquals(listOf(first, second), noRollback.records)
        assertFalse(next.exists())

        main.writeBytes(newer.copyOf().apply {
            this[lastIndex] = (this[lastIndex].toInt() xor 1).toByte()
        })
        next.writeBytes(older)
        assertTrue(AtomicCommandCleanupLedger(main).read() is CleanupLedgerRead.Corrupt)
        assertTrue(next.exists())
    }

    @Test
    fun ledgerWriteSyncsNextThenRenameThenParentDirectory() {
        val directory = Files.createTempDirectory("ledger-durability").toFile()
        val operations = mutableListOf<String>()
        val ops = object : CleanupLedgerFileOps {
            override fun exists(file: File) = NioCleanupLedgerFileOps.exists(file)
            override fun read(file: File) = NioCleanupLedgerFileOps.read(file)
            override fun writeAndSync(file: File, bytes: ByteArray) {
                operations.add("write-sync-next")
                NioCleanupLedgerFileOps.writeAndSync(file, bytes)
            }
            override fun atomicReplace(source: File, destination: File) {
                operations.add("atomic-rename")
                NioCleanupLedgerFileOps.atomicReplace(source, destination)
            }
            override fun syncParent(directory: File) {
                operations.add("fsync-parent")
                NioCleanupLedgerFileOps.syncParent(directory)
            }
            override fun delete(file: File) = NioCleanupLedgerFileOps.delete(file)
        }
        assertTrue(
            AtomicCommandCleanupLedger(
                File(directory, "ledger.bin"),
                fileOps = ops,
            ).write(listOf(record("durable-order", 1_201, 121L))),
        )
        assertEquals(
            listOf("write-sync-next", "atomic-rename", "fsync-parent"),
            operations,
        )
    }

    @Test
    fun interruptedRenameRetainsRecoverableNextEnvelope() {
        val directory = Files.createTempDirectory("ledger-interrupted-rename").toFile()
        val main = File(directory, "ledger.bin")
        val ops = object : CleanupLedgerFileOps by NioCleanupLedgerFileOps {
            override fun atomicReplace(source: File, destination: File) {
                throw IllegalStateException("injected rename crash")
            }
        }
        assertFalse(
            AtomicCommandCleanupLedger(main, fileOps = ops)
                .write(listOf(record("rename-crash", 1_251, 125L))),
        )
        assertFalse(main.exists())
        assertTrue(File(directory, "ledger.bin.next").exists())
        val recovered = AtomicCommandCleanupLedger(main).read() as CleanupLedgerRead.Success
        assertEquals(1L, recovered.generation)
        assertEquals(1, recovered.records.size)
    }

    @Test
    fun realLaunchWrapperCannotExecuteBeforeGoAndPreservesArgv() {
        val directory = Files.createTempDirectory("launch-gate-real").toFile()
        val ledger = FakeLedger()
        val coordinator = CommandCleanupCoordinator(
            ledger = ledger,
            disposer = CleanupProcessDisposer {
                CleanupDisposalAttempt(ProcessDisposalResult.RETRYABLE_UNKNOWN)
            },
            immediateScheduler = FakeImmediateScheduler(),
            backstop = FakeBackstop(),
            launchDirectory = directory,
            recoveryProbe = PidProcessProbe { PidProbeResult.Present(131L) },
            parentProcessId = ::currentProcessId,
            nowEpochMs = { 1_000L },
        )
        coordinator.initialize()
        val key = terminalKey("real-wrapper", "operation")
        val launch = coordinator.prepareLaunch(key, "candidate", 60_000L)
        assertEquals(
            DurableLaunchRegistrationOutcome.DURABLY_REGISTERED_BACKSTOP_SCHEDULED,
            launch.outcome,
        )
        val marker = File(directory, "real-command-marker")
        val process = ProcessBuilder(
            "/bin/sh",
            launch.wrapperPath,
            launch.attemptDirectoryPath,
            launch.launchToken,
            launch.parentProcessId.toString(),
            launch.appUid.toString(),
            "--",
            "/usr/bin/touch",
            marker.absolutePath,
        ).start()
        waitForPidFile(File(requireNotNull(launch.stagingPath)), process)
        assertFalse(marker.exists())
        assertEquals(processPid(process), File(launch.stagingPath).readLines()[1].toInt())
        val token = coordinator.activateWaitingLaunch(
            key,
            "candidate",
            requireNotNull(launch.attemptId),
            requireNotNull(launch.launchToken),
            processPid(process),
            PidProcessProbe { PidProbeResult.Present(stagedGeneration(launch)) },
        )
        assertTrue(token != null)
        assertTrue(ledger.writeStates.contains(CleanupDisposalState.CLAIMED))
        assertTrue(ledger.writeStates.contains(CleanupDisposalState.PID_STAGED))
        val claimed = ledger.writeSnapshots.flatten().single {
            it.disposalState == CleanupDisposalState.CLAIMED
        }
        assertEquals(processPid(process), claimed.processId)
        assertEquals(stagedGeneration(launch), claimed.startTimeTicks)
        assertEquals(CleanupDisposalState.ACTIVE, ledger.records.single().disposalState)
        assertFalse(marker.exists())
        assertTrue(
            coordinator.releaseLaunch(
                key,
                "candidate",
                requireNotNull(launch.attemptId),
                requireNotNull(launch.launchToken),
                requireNotNull(token),
            )
        )
        assertTrue(process.waitFor(5, TimeUnit.SECONDS))
        assertTrue(marker.exists())
        val permissions = Files.getPosixFilePermissions(directory.toPath())
        assertEquals(
            setOf(
                PosixFilePermission.OWNER_READ,
                PosixFilePermission.OWNER_WRITE,
                PosixFilePermission.OWNER_EXECUTE,
            ),
            permissions,
        )
    }

    @Test
    fun replayedLaunchCapabilityLetsExactlyOneConcurrentWrapperClaimAndExecute() {
        val directory = Files.createTempDirectory("launch-one-shot").toFile()
        val coordinator = CommandCleanupCoordinator(
            ledger = FakeLedger(),
            disposer = CleanupProcessDisposer {
                CleanupDisposalAttempt(ProcessDisposalResult.RETRYABLE_UNKNOWN)
            },
            immediateScheduler = FakeImmediateScheduler(),
            backstop = FakeBackstop(),
            launchDirectory = directory,
            recoveryProbe = PidProcessProbe { PidProbeResult.Present(1L) },
            parentProcessId = ::currentProcessId,
            nowEpochMs = { 1_000L },
        )
        coordinator.initialize()
        val key = terminalKey("one-shot", "operation")
        val launch = coordinator.prepareLaunch(key, "candidate", 60_000L)
        val marker = File(directory, "executions")
        fun spawn() = ProcessBuilder(
            "/bin/sh",
            launch.wrapperPath,
            launch.attemptDirectoryPath,
            launch.launchToken,
            launch.parentProcessId.toString(),
            launch.appUid.toString(),
            "--",
            "/bin/sh",
            "-c",
            "printf 'executed\\n' >> \"${marker.absolutePath}\"",
        ).start()

        val first = spawn()
        val second = spawn()
        waitForPidFile(File(requireNotNull(launch.stagingPath)))
        val stagedPid = File(launch.stagingPath).readLines()[1].toInt()
        val winner = listOf(first, second).single { processPid(it) == stagedPid }
        val loser = listOf(first, second).single { it !== winner }
        val generation = stagedGeneration(launch)
        var token: PidGenerationToken? = null
        for (attempt in 0 until 50) {
            token = coordinator.activateWaitingLaunch(
                key,
                "candidate",
                requireNotNull(launch.attemptId),
                requireNotNull(launch.launchToken),
                stagedPid,
                PidProcessProbe { PidProbeResult.Present(generation) },
            )
            if (token != null) break
            Thread.sleep(20L)
        }
        assertTrue(
            coordinator.releaseLaunch(
                key,
                "candidate",
                requireNotNull(launch.attemptId),
                requireNotNull(launch.launchToken),
                requireNotNull(token),
            )
        )
        assertTrue(first.waitFor(5, TimeUnit.SECONDS))
        assertTrue(second.waitFor(5, TimeUnit.SECONDS))
        assertEquals(120, loser.exitValue())
        assertEquals(0, winner.exitValue())
        assertEquals(listOf("executed"), marker.readLines())
    }

    @Test
    fun cancellationBeforePidStageRevokesLateWrapperAndRetainsTombstone() {
        val directory = Files.createTempDirectory("launch-cancel-pre-stage").toFile()
        val ledger = FakeLedger()
        val coordinator = CommandCleanupCoordinator(
            ledger = ledger,
            disposer = CleanupProcessDisposer {
                CleanupDisposalAttempt(ProcessDisposalResult.RETRYABLE_UNKNOWN)
            },
            immediateScheduler = FakeImmediateScheduler(),
            backstop = FakeBackstop(),
            launchDirectory = directory,
            recoveryProbe = PidProcessProbe { PidProbeResult.Present(1L) },
            parentProcessId = ::currentProcessId,
            nowEpochMs = { 1_000L },
        )
        coordinator.initialize()
        val key = agentKey("cancel-before-stage", "operation")
        val launch = coordinator.prepareLaunch(key, null, 60_000L)
        assertTrue(coordinator.requestCleanup(key))
        assertEquals(CleanupDisposalState.CANCEL_REQUESTED, ledger.records.single().disposalState)
        assertTrue(File(requireNotNull(launch.attemptDirectoryPath), "revoked").isFile)

        val marker = File(directory, "must-not-execute")
        val late = ProcessBuilder(
            "/bin/sh",
            launch.wrapperPath,
            launch.attemptDirectoryPath,
            launch.launchToken,
            launch.parentProcessId.toString(),
            launch.appUid.toString(),
            "--",
            "/usr/bin/touch",
            marker.absolutePath,
        ).start()
        assertTrue(late.waitFor(5, TimeUnit.SECONDS))
        assertEquals(121, late.exitValue())
        assertFalse(marker.exists())
        assertEquals(CleanupDisposalState.CANCEL_REQUESTED, ledger.records.single().disposalState)
    }

    @Test
    fun publishedClaimIsCompleteAndGoneClaimantClearsDurableBlock() {
        val directory = Files.createTempDirectory("claimant-gone").toFile()
        val ledger = FakeLedger()
        var claimantGone = false
        val coordinator = CommandCleanupCoordinator(
            ledger = ledger,
            disposer = CleanupProcessDisposer {
                throw AssertionError("gone prelaunch claimant must not be signalled")
            },
            immediateScheduler = FakeImmediateScheduler(),
            backstop = FakeBackstop(),
            launchDirectory = directory,
            recoveryProbe = PidProcessProbe { processId ->
                if (claimantGone && processId == 801) {
                    PidProbeResult.Missing
                } else {
                    PidProbeResult.Present(if (processId == 801) 81L else 1L)
                }
            },
            parentProcessId = ::currentProcessId,
            nowEpochMs = { 1_000L },
        )
        coordinator.initialize()
        val key = terminalKey("claimant-gone", "operation")
        val launch = coordinator.prepareLaunch(key, "candidate", 60_000L)
        stageLaunch(launch, 801, 81L)
        assertEquals(
            listOf(requireNotNull(launch.launchToken), "801", "81"),
            File(requireNotNull(launch.stagingPath)).readLines(),
        )
        claimantGone = true
        assertTrue(coordinator.requestCleanup(key, "candidate"))
        coordinator.reconcile()
        assertTrue(ledger.records.isEmpty())
        assertTrue(coordinator.canAdmit(CommandContinuationOwner.TERMINAL, "claimant-gone"))
    }

    @Test
    fun wrapperDeathAfterAtomicClaimUsesClaimIdentityToClearLedger() {
        val directory = Files.createTempDirectory("wrapper-dies-after-claim").toFile()
        val ledger = FakeLedger()
        var claimantPid = -1
        var claimantGone = false
        val coordinator = CommandCleanupCoordinator(
            ledger = ledger,
            disposer = CleanupProcessDisposer {
                throw AssertionError("already-gone wrapper must not be signalled")
            },
            immediateScheduler = FakeImmediateScheduler(),
            backstop = FakeBackstop(),
            launchDirectory = directory,
            recoveryProbe = PidProcessProbe { processId ->
                if (claimantGone && processId == claimantPid) {
                    PidProbeResult.Missing
                } else {
                    PidProbeResult.Present(1L)
                }
            },
            parentProcessId = ::currentProcessId,
            nowEpochMs = { 1_000L },
        )
        coordinator.initialize()
        val key = terminalKey("wrapper-dies", "operation")
        val launch = coordinator.prepareLaunch(key, "candidate", 60_000L)
        val marker = File(directory, "must-not-exec")
        val wrapper = ProcessBuilder(
            "/bin/sh",
            launch.wrapperPath,
            launch.attemptDirectoryPath,
            launch.launchToken,
            launch.parentProcessId.toString(),
            launch.appUid.toString(),
            "--",
            "/usr/bin/touch",
            marker.absolutePath,
        ).start()
        waitForPidFile(File(requireNotNull(launch.stagingPath)), wrapper)
        claimantPid = File(launch.stagingPath).readLines()[1].toInt()
        assertEquals(processPid(wrapper), claimantPid)
        wrapper.destroyForcibly()
        assertTrue(wrapper.waitFor(5, TimeUnit.SECONDS))
        claimantGone = true

        assertTrue(coordinator.requestCleanup(key, "candidate"))
        coordinator.reconcile()

        assertTrue(ledger.records.isEmpty())
        assertFalse(marker.exists())
    }

    @Test
    fun aliveSlowClaimantAndUnknownProbeRetainUntilDefinitiveExit() {
        val ledger = FakeLedger()
        var claimantGone = false
        var probeUnknown = true
        val coordinator = CommandCleanupCoordinator(
            ledger = ledger,
            disposer = CleanupProcessDisposer {
                CleanupDisposalAttempt(
                    if (claimantGone) ProcessDisposalResult.VERIFIED_GONE_OR_REUSED
                    else ProcessDisposalResult.RETRYABLE_UNKNOWN
                )
            },
            immediateScheduler = FakeImmediateScheduler(),
            backstop = FakeBackstop(),
            launchDirectory = Files.createTempDirectory("claimant-slow").toFile(),
            recoveryProbe = PidProcessProbe { processId ->
                when {
                    processId == 802 && probeUnknown -> PidProbeResult.RetryableUnknown
                    processId == 802 -> PidProbeResult.Present(82L)
                    else -> PidProbeResult.Present(1L)
                }
            },
            parentProcessId = ::currentProcessId,
            nowEpochMs = { 1_000L },
        )
        coordinator.initialize()
        val key = agentKey("claimant-slow", "operation")
        val launch = coordinator.prepareLaunch(key, null, 60_000L)
        stageLaunch(launch, 802, 82L)
        assertTrue(coordinator.requestCleanup(key))
        coordinator.reconcile()
        assertEquals(CleanupDisposalState.CANCEL_REQUESTED, ledger.records.single().disposalState)
        probeUnknown = false
        coordinator.reconcile()
        assertEquals(CleanupDisposalState.SIGNAL_INTENT, ledger.records.single().disposalState)
        claimantGone = true
        coordinator.reconcile()
        assertTrue(ledger.records.isEmpty())
    }

    @Test
    fun hardLinkCrashTwinIsNormalizedBeforeClaimOwnership() {
        val directory = Files.createTempDirectory("claim-hard-link-crash").toFile()
        val coordinator = CommandCleanupCoordinator(
            ledger = FakeLedger(),
            disposer = CleanupProcessDisposer {
                CleanupDisposalAttempt(ProcessDisposalResult.RETRYABLE_UNKNOWN)
            },
            immediateScheduler = FakeImmediateScheduler(),
            backstop = FakeBackstop(),
            launchDirectory = directory,
            recoveryProbe = PidProcessProbe { PidProbeResult.Present(1L) },
            parentProcessId = ::currentProcessId,
            nowEpochMs = { 1_000L },
        )
        coordinator.initialize()
        val key = terminalKey("claim-hard-link", "operation")
        val launch = coordinator.prepareLaunch(key, "candidate", 60_000L)
        val claim = File(requireNotNull(launch.stagingPath))
        val temporary = File(requireNotNull(launch.attemptDirectoryPath), "claim.tmp.803")
        writePrivate(temporary, "${launch.launchToken}\n803\n83\n".toByteArray())
        Files.createLink(claim.toPath(), temporary.toPath())
        assertEquals(2, (Files.getAttribute(claim.toPath(), "unix:nlink") as Number).toInt())

        val token = coordinator.activateWaitingLaunch(
            key,
            "candidate",
            requireNotNull(launch.attemptId),
            requireNotNull(launch.launchToken),
            803,
            PidProcessProbe { PidProbeResult.Present(83L) },
        )

        assertTrue(token != null)
        assertFalse(temporary.exists())
        assertEquals(1, (Files.getAttribute(claim.toPath(), "unix:nlink") as Number).toInt())
    }

    @Test
    fun wrapperTempUnlinkRaceReplaysCompletePublishedClaim() {
        val directory = Files.createTempDirectory("claim-wrapper-unlink-race").toFile()
        var temporary: File? = null
        val fileOps = object : LaunchSecureFileOps by NioLaunchSecureFileOps {
            override fun sameFile(first: File, second: File): Boolean {
                Files.deleteIfExists(second.toPath())
                temporary = second
                return false
            }
        }
        val coordinator = CommandCleanupCoordinator(
            ledger = FakeLedger(),
            disposer = CleanupProcessDisposer {
                CleanupDisposalAttempt(ProcessDisposalResult.RETRYABLE_UNKNOWN)
            },
            immediateScheduler = FakeImmediateScheduler(),
            backstop = FakeBackstop(),
            launchDirectory = directory,
            launchFileOps = fileOps,
            recoveryProbe = PidProcessProbe { PidProbeResult.Present(1L) },
            parentProcessId = ::currentProcessId,
            nowEpochMs = { 1_000L },
        )
        coordinator.initialize()
        val key = terminalKey("claim-wrapper-unlink-race", "operation")
        val launch = coordinator.prepareLaunch(key, "candidate", 60_000L)
        val claim = File(requireNotNull(launch.stagingPath))
        val linkedTemp = File(requireNotNull(launch.attemptDirectoryPath), "claim.tmp.806")
        writePrivate(linkedTemp, "${launch.launchToken}\n806\n86\n".toByteArray())
        Files.createLink(claim.toPath(), linkedTemp.toPath())

        val token = coordinator.activateWaitingLaunch(
            key,
            "candidate",
            requireNotNull(launch.attemptId),
            requireNotNull(launch.launchToken),
            806,
            PidProcessProbe { PidProbeResult.Present(86L) },
        )

        assertTrue(token != null)
        assertEquals(linkedTemp, temporary)
        assertFalse(linkedTemp.exists())
        assertEquals(1, (Files.getAttribute(claim.toPath(), "unix:nlink") as Number).toInt())
    }

    @Test
    fun rebootMalformedMatchingTwinsUseOnlyParentGenerationForRecovery() {
        val payloads = mapOf(
            "zero" to byteArrayOf(),
            "truncated" to "broken\n".toByteArray(),
            "partial" to "${"a".repeat(64)}\n901\n".toByteArray(),
            "corrupt" to "not-a-token\n901\n91\n".toByteArray(),
            "oversize" to ByteArray(257) { 'x'.code.toByte() },
        )
        for ((name, payload) in payloads) {
            val directory = Files.createTempDirectory("claim-reboot-$name").toFile()
            val ledgerFile = File(directory, "cleanup-ledger")
            val parentPid = currentProcessId()
            var parent: PidProbeResult = PidProbeResult.Present(501L)
            var disposeCalls = 0
            val backstop = FakeBackstop()
            fun coordinator(now: Long) = CommandCleanupCoordinator(
                ledger = AtomicCommandCleanupLedger(ledgerFile),
                disposer = CleanupProcessDisposer {
                    disposeCalls++
                    CleanupDisposalAttempt(ProcessDisposalResult.DISPOSED)
                },
                immediateScheduler = FakeImmediateScheduler(),
                backstop = backstop,
                launchDirectory = directory,
                recoveryProbe = PidProcessProbe { parent },
                parentProcessId = { parentPid },
                nowEpochMs = { now },
            )
            val original = coordinator(1_000L)
            original.initialize()
            val key = terminalKey("malformed-$name", "operation")
            val launch = original.prepareLaunch(key, "candidate", 60_000L)
            val attempt = File(requireNotNull(launch.attemptDirectoryPath))
            val claim = File(requireNotNull(launch.stagingPath))
            val temporary = File(attempt, "claim.tmp.901")
            writePrivate(temporary, payload)
            Files.createLink(claim.toPath(), temporary.toPath())

            val recovered = coordinator(40_000L)
            recovered.initialize()
            recovered.reconcile()
            assertEquals(
                "$name must remain blocked while parent is alive",
                1,
                persistedRecords(ledgerFile).size,
            )
            assertEquals(0, disposeCalls)
            assertFalse(File(attempt, "go").exists())
            if (payload.size <= 256) {
                assertFalse("$name matching twin must normalize", temporary.exists())
                assertEquals(
                    1,
                    (Files.getAttribute(claim.toPath(), "unix:nlink") as Number).toInt(),
                )
            }

            parent = PidProbeResult.RetryableUnknown
            recovered.reconcile()
            assertEquals(1, persistedRecords(ledgerFile).size)
            parent = PidProbeResult.Missing
            recovered.reconcile()
            assertTrue(persistedRecords(ledgerFile).isEmpty())
            assertTrue(attempt.exists())
            assertTrue(backstop.cancelCount > 0)
            assertTrue(recovered.canAdmit(CommandContinuationOwner.TERMINAL, "malformed-$name"))
            assertEquals(0, disposeCalls)
        }
    }

    @Test
    fun rebootMalformedAndAmbiguousClaimStatesRemainNonAuthoritative() {
        val variants = listOf("singleton", "temp-only", "different-inode", "multiple")
        for (variant in variants) {
            val directory = Files.createTempDirectory("claim-state-$variant").toFile()
            val ledgerFile = File(directory, "cleanup-ledger")
            val parentPid = currentProcessId()
            var parent: PidProbeResult = PidProbeResult.Present(601L)
            var disposeCalls = 0
            fun coordinator(now: Long) = CommandCleanupCoordinator(
                ledger = AtomicCommandCleanupLedger(ledgerFile),
                disposer = CleanupProcessDisposer {
                    disposeCalls++
                    CleanupDisposalAttempt(ProcessDisposalResult.DISPOSED)
                },
                immediateScheduler = FakeImmediateScheduler(),
                backstop = FakeBackstop(),
                launchDirectory = directory,
                recoveryProbe = PidProcessProbe { parent },
                parentProcessId = { parentPid },
                nowEpochMs = { now },
            )
            val original = coordinator(1_000L)
            original.initialize()
            val key = agentKey("malformed-$variant", "operation")
            val launch = original.prepareLaunch(key, null, 60_000L)
            val attempt = File(requireNotNull(launch.attemptDirectoryPath))
            val claim = File(requireNotNull(launch.stagingPath))
            val malformed = "broken-$variant\n".toByteArray()
            when (variant) {
                "singleton" -> writePrivate(claim, malformed)
                "temp-only" -> writePrivate(File(attempt, "claim.tmp.902"), malformed)
                "different-inode" -> {
                    writePrivate(claim, malformed)
                    Files.createLink(File(attempt, "other-link").toPath(), claim.toPath())
                    writePrivate(File(attempt, "claim.tmp.902"), "different\n".toByteArray())
                }
                "multiple" -> {
                    val first = File(attempt, "claim.tmp.902")
                    writePrivate(first, malformed)
                    Files.createLink(claim.toPath(), first.toPath())
                    writePrivate(File(attempt, "claim.tmp.903"), "other\n".toByteArray())
                }
            }

            val recovered = coordinator(40_000L)
            recovered.initialize()
            recovered.reconcile()
            assertEquals(
                "$variant must remain blocked while parent is alive",
                1,
                persistedRecords(ledgerFile).size,
            )
            assertEquals(0, disposeCalls)
            parent = PidProbeResult.RetryableUnknown
            recovered.reconcile()
            assertEquals(1, persistedRecords(ledgerFile).size)
            parent = PidProbeResult.Present(602L)
            recovered.reconcile()
            assertTrue(persistedRecords(ledgerFile).isEmpty())
            assertTrue(attempt.exists())
            assertTrue(recovered.canAdmit(CommandContinuationOwner.AGENT_BASH, "malformed-$variant"))
            assertEquals(0, disposeCalls)
        }
    }

    @Test
    fun unsafeMalformedTwinMetadataNeverBecomesPidAuthority() {
        val variants = listOf(
            "symlink",
            "fifo",
            "device",
            "wrong-owner",
            "wrong-mode",
            "wrong-links",
            "oversize",
        )
        for (variant in variants) {
            val directory = Files.createTempDirectory("claim-unsafe-$variant").toFile()
            val ledger = FakeLedger()
            var parent: PidProbeResult = PidProbeResult.Present(651L)
            var injectInvalidMetadata = false
            var disposeCalls = 0
            val fileOps = object : LaunchSecureFileOps by NioLaunchSecureFileOps {
                override fun metadata(path: File): LaunchEntryMetadata? {
                    val actual = NioLaunchSecureFileOps.metadata(path) ?: return null
                    if (!injectInvalidMetadata || path.name != "claim.tmp.905") return actual
                    return when (variant) {
                        "symlink" -> actual.copy(isRegularFile = false, isSymbolicLink = true)
                        "fifo" -> actual.copy(isRegularFile = false)
                        "device" -> actual.copy(isRegularFile = false)
                        "wrong-owner" -> actual.copy(uid = actual.uid + 1)
                        "wrong-mode" -> actual.copy(permissions = 0x1a0)
                        "wrong-links" -> actual.copy(linkCount = 1)
                        "oversize" -> actual.copy(size = 257L)
                        else -> actual
                    }
                }
            }
            fun coordinator(now: Long) = CommandCleanupCoordinator(
                ledger = ledger,
                disposer = CleanupProcessDisposer {
                    disposeCalls++
                    CleanupDisposalAttempt(ProcessDisposalResult.DISPOSED)
                },
                immediateScheduler = FakeImmediateScheduler(),
                backstop = FakeBackstop(),
                launchDirectory = directory,
                launchFileOps = fileOps,
                recoveryProbe = PidProcessProbe { parent },
                parentProcessId = ::currentProcessId,
                nowEpochMs = { now },
            )
            val original = coordinator(1_000L)
            original.initialize()
            val key = terminalKey("unsafe-$variant", "operation")
            val launch = original.prepareLaunch(key, "candidate", 60_000L)
            val attempt = File(requireNotNull(launch.attemptDirectoryPath))
            val claim = File(requireNotNull(launch.stagingPath))
            writePrivate(claim, "broken\n".toByteArray())
            Files.createLink(File(attempt, "other-link").toPath(), claim.toPath())
            val temporary = File(attempt, "claim.tmp.905")
            writePrivate(temporary, "different\n".toByteArray())
            Files.createLink(File(attempt, "temp-other-link").toPath(), temporary.toPath())
            injectInvalidMetadata = true

            val recovered = coordinator(40_000L)
            recovered.initialize()
            recovered.reconcile()
            assertEquals(1, ledger.records.size)
            assertTrue(temporary.exists())
            assertEquals(0, disposeCalls)
            parent = PidProbeResult.Missing
            recovered.reconcile()
            assertTrue(ledger.records.isEmpty())
            assertTrue(attempt.exists())
            assertEquals(0, disposeCalls)
        }
    }

    @Test
    fun freshLoadHostileAttemptNodesNeverReceiveChildrenAndConvergeSafely() {
        val variants = listOf(
            "in-root-symlink",
            "outside-symlink",
            "broken-symlink",
            "fifo",
            "socket",
            "regular",
            "device-metadata",
            "wrong-mode-directory",
            "hostile-nonempty-directory",
            "missing",
        )

        fun runCase(
            variant: String,
            finalParent: PidProbeResult,
            exactAbandon: Boolean,
        ) {
            val base = Files.createTempDirectory(File("/tmp").toPath(), "ha-").toFile()
            val root = base
            val ledgerFile = File(requireNotNull(base.parentFile), "${base.name}.ledger")
            val parentPid = currentProcessId()
            var parent: PidProbeResult = PidProbeResult.Present(801L)
            var injectDeviceMetadata = false
            var disposeCalls = 0
            val backstop = FakeBackstop()
            lateinit var attempt: File
            val fileOps = object : LaunchSecureFileOps by NioLaunchSecureFileOps {
                override fun metadata(path: File): LaunchEntryMetadata? {
                    val actual = NioLaunchSecureFileOps.metadata(path) ?: return null
                    if (injectDeviceMetadata && path.absoluteFile == attempt.absoluteFile) {
                        return actual.copy(isDirectory = false, isRegularFile = false)
                    }
                    return actual
                }
            }
            fun coordinator() = CommandCleanupCoordinator(
                ledger = AtomicCommandCleanupLedger(ledgerFile),
                disposer = CleanupProcessDisposer {
                    disposeCalls++
                    CleanupDisposalAttempt(ProcessDisposalResult.DISPOSED)
                },
                immediateScheduler = FakeImmediateScheduler(),
                backstop = backstop,
                launchDirectory = root,
                launchFileOps = fileOps,
                recoveryProbe = PidProcessProbe { parent },
                parentProcessId = { parentPid },
                nowEpochMs = { 40_000L },
            )

            val original = coordinator()
            original.initialize()
            val key = terminalKey(
                "hostile-$variant-${finalParent::class.simpleName}-$exactAbandon",
                "operation",
            )
            val launch = original.prepareLaunch(key, "candidate", 60_000L)
            attempt = File(requireNotNull(launch.attemptDirectoryPath))
            assertTrue(attempt.deleteRecursively())
            var protectedTarget: File? = null
            var protectedMarker: File? = null
            var socketProcess: Process? = null
            when (variant) {
                "in-root-symlink" -> {
                    protectedTarget = File(root, "writable-target").apply { mkdir() }
                    setPrivateDirectory(protectedTarget)
                    protectedMarker = File(protectedTarget, "keep").apply { writeText("keep") }
                    Files.createSymbolicLink(attempt.toPath(), protectedTarget.toPath())
                }
                "outside-symlink" -> {
                    protectedTarget = Files.createTempDirectory("outside-attempt-target").toFile()
                    protectedMarker = File(protectedTarget, "keep").apply { writeText("keep") }
                    Files.createSymbolicLink(attempt.toPath(), protectedTarget.toPath())
                }
                "broken-symlink" -> Files.createSymbolicLink(
                    attempt.toPath(),
                    File(base, "missing-target").toPath(),
                )
                "fifo" -> assertEquals(
                    0,
                    ProcessBuilder("mkfifo", attempt.absolutePath).start().waitFor(),
                )
                "socket" -> {
                    socketProcess = ProcessBuilder(
                        "/usr/bin/python3",
                        "-c",
                        "import socket,sys,time; s=socket.socket(socket.AF_UNIX); " +
                            "s.bind(sys.argv[1]); time.sleep(30)",
                        attempt.absolutePath,
                    ).start()
                    var waitAttempts = 0
                    while (!Files.exists(
                            attempt.toPath(),
                            java.nio.file.LinkOption.NOFOLLOW_LINKS,
                        ) && waitAttempts < 100) {
                        Thread.sleep(10L)
                        waitAttempts++
                    }
                    assertTrue(Files.exists(attempt.toPath(), java.nio.file.LinkOption.NOFOLLOW_LINKS))
                }
                "regular" -> attempt.writeText("hostile")
                "device-metadata" -> {
                    attempt.writeText("simulated-device")
                    injectDeviceMetadata = true
                }
                "wrong-mode-directory" -> {
                    assertTrue(attempt.mkdir())
                    Files.setPosixFilePermissions(
                        attempt.toPath(),
                        setOf(
                            PosixFilePermission.OWNER_READ,
                            PosixFilePermission.OWNER_WRITE,
                            PosixFilePermission.OWNER_EXECUTE,
                            PosixFilePermission.GROUP_READ,
                        ),
                    )
                }
                "hostile-nonempty-directory" -> {
                    assertTrue(attempt.mkdir())
                    setPrivateDirectory(attempt)
                    protectedMarker = File(attempt, "hostile-child").apply { writeText("keep") }
                }
                "missing" -> Unit
            }
            val retirementCollision = File(root, "retired-${attempt.name}").apply {
                writeText("must-not-block-or-change")
            }

            val recovered = coordinator()
            recovered.initialize()
            if (exactAbandon) {
                assertFalse(
                    recovered.acknowledgeLaunchAbandoned(
                        key,
                        "candidate",
                        requireNotNull(launch.attemptId),
                        "0".repeat(64),
                    )
                )
                assertEquals(1, persistedRecords(ledgerFile).size)
                assertTrue(
                    recovered.acknowledgeLaunchAbandoned(
                        key,
                        "candidate",
                        requireNotNull(launch.attemptId),
                        requireNotNull(launch.launchToken),
                    )
                )
            } else {
                recovered.reconcile()
                assertEquals(1, persistedRecords(ledgerFile).size)
                assertFalse(recovered.canAdmit(CommandContinuationOwner.TERMINAL, key.sessionId))
                assertEquals(0, disposeCalls)
                assertFalse(protectedTarget?.let { File(it, "revoked").exists() } ?: false)
                parent = PidProbeResult.RetryableUnknown
                recovered.reconcile()
                assertEquals(1, persistedRecords(ledgerFile).size)
                parent = finalParent
                recovered.reconcile()
            }

            assertTrue(persistedRecords(ledgerFile).isEmpty())
            assertFalse(
                recovered.acknowledgeLaunchAbandoned(
                    key,
                    "candidate",
                    requireNotNull(launch.attemptId),
                    requireNotNull(launch.launchToken),
                )
            )
            assertEquals(
                variant != "missing",
                Files.exists(attempt.toPath(), java.nio.file.LinkOption.NOFOLLOW_LINKS),
            )
            assertFalse(protectedTarget?.let { File(it, "revoked").exists() } ?: false)
            assertEquals("must-not-block-or-change", retirementCollision.readText())
            protectedMarker?.let { marker ->
                assertTrue(marker.exists())
            }
            assertTrue(recovered.canAdmit(CommandContinuationOwner.TERMINAL, key.sessionId))
            assertTrue(backstop.cancelCount > 0)
            assertEquals(0, disposeCalls)
            parent = PidProbeResult.Present(801L)
            val replacementKey = terminalKey(key.sessionId, "replacement-operation")
            val replacement = recovered.prepareLaunch(replacementKey, "replacement", 60_000L)
            assertEquals(
                variant,
                DurableLaunchRegistrationOutcome.DURABLY_REGISTERED_BACKSTOP_SCHEDULED,
                replacement.outcome,
            )
            assertTrue(replacement.attemptDirectoryPath != attempt.absolutePath)
            assertEquals("must-not-block-or-change", retirementCollision.readText())
            assertTrue(
                recovered.acknowledgeLaunchAbandoned(
                    replacementKey,
                    "replacement",
                    requireNotNull(replacement.attemptId),
                    requireNotNull(replacement.launchToken),
                )
            )
            socketProcess?.destroyForcibly()
            socketProcess?.waitFor(5, TimeUnit.SECONDS)
        }

        for (variant in variants) {
            runCase(variant, PidProbeResult.Missing, exactAbandon = false)
            runCase(variant, PidProbeResult.Present(802L), exactAbandon = false)
            runCase(variant, PidProbeResult.Present(801L), exactAbandon = true)
        }
    }

    @Test
    fun definitiveRetirementNeverDeletesAPathSubstitutedAfterSelection() {
        val variants = listOf(
            "attempt-symlink",
            "attempt-directory",
            "attempt-fifo",
            "attempt-socket",
            "attempt-regular",
            "root-symlink",
        )
        for (variant in variants) {
            val root = Files.createTempDirectory(File("/tmp").toPath(), "sr-").toFile()
            val ledger = FakeLedger()
            val backstop = FakeBackstop()
            var substitute: () -> Unit = {}
            var socketProcess: Process? = null
            val coordinator = CommandCleanupCoordinator(
                ledger = ledger,
                disposer = CleanupProcessDisposer {
                    substitute()
                    CleanupDisposalAttempt(ProcessDisposalResult.VERIFIED_GONE_OR_REUSED)
                },
                immediateScheduler = FakeImmediateScheduler(),
                backstop = backstop,
                launchDirectory = root,
                recoveryProbe = PidProcessProbe { PidProbeResult.Present(1001L) },
                parentProcessId = ::currentProcessId,
                nowEpochMs = { 1_000L },
            )
            coordinator.initialize()
            val key = terminalKey("substitution-$variant", "operation")
            assertTrue(coordinator.register(key, "candidate", 1001, 1001L, 60_000L))
            val attemptHash = requireNotNull(coordinator.recordsForTest().single().attemptHash)
            val attempt = File(root, "attempt-$attemptHash")
            val outside = Files.createTempDirectory("substitution-target").toFile()
            val outsideMarker = File(outside, "keep").apply { writeText("keep") }
            val collision = File(root, "retired-${attempt.name}").apply { writeText("collision") }
            substitute = {
                if (variant == "root-symlink") {
                    assertTrue(root.deleteRecursively())
                    Files.createSymbolicLink(root.toPath(), outside.toPath())
                } else {
                    assertTrue(attempt.deleteRecursively())
                    when (variant) {
                        "attempt-symlink" -> Files.createSymbolicLink(
                            attempt.toPath(),
                            outside.toPath(),
                        )
                        "attempt-directory" -> {
                            assertTrue(attempt.mkdir())
                            setPrivateDirectory(attempt)
                            File(attempt, "keep").writeText("keep")
                        }
                        "attempt-fifo" -> assertEquals(
                            0,
                            ProcessBuilder("mkfifo", attempt.absolutePath).start().waitFor(),
                        )
                        "attempt-socket" -> {
                            socketProcess = ProcessBuilder(
                                "/usr/bin/python3",
                                "-c",
                                "import socket,sys,time; s=socket.socket(socket.AF_UNIX); " +
                                    "s.bind(sys.argv[1]); time.sleep(30)",
                                attempt.absolutePath,
                            ).start()
                            var waits = 0
                            while (!Files.exists(
                                    attempt.toPath(),
                                    java.nio.file.LinkOption.NOFOLLOW_LINKS,
                                ) && waits < 100) {
                                Thread.sleep(10L)
                                waits++
                            }
                        }
                        "attempt-regular" -> attempt.writeText("keep")
                    }
                }
            }

            assertTrue(coordinator.requestCleanup(key, "candidate"))
            coordinator.reconcile()

            assertTrue(ledger.records.isEmpty())
            assertTrue(outsideMarker.exists())
            assertFalse(File(outside, "revoked").exists())
            if (variant == "root-symlink") {
                assertTrue(Files.isSymbolicLink(root.toPath()))
            } else {
                assertTrue(Files.exists(attempt.toPath(), java.nio.file.LinkOption.NOFOLLOW_LINKS))
                assertEquals("collision", collision.readText())
            }
            assertTrue(coordinator.canAdmit(CommandContinuationOwner.TERMINAL, key.sessionId))
            assertTrue(backstop.cancelCount > 0)
            socketProcess?.destroyForcibly()
            socketProcess?.waitFor(5, TimeUnit.SECONDS)
        }
    }

    @Test
    fun hostileAttemptsRootFailsClosedWithoutFollowingTargets() {
        val variants = listOf("symlink", "broken-symlink", "regular", "wrong-mode", "missing")
        for (variant in variants) {
            val base = Files.createTempDirectory("hostile-attempt-root").toFile()
            val root = File(base, "attempts")
            val ledgerFile = File(base, "ledger")
            var parent: PidProbeResult = PidProbeResult.Present(901L)
            var disposeCalls = 0
            val backstop = FakeBackstop()
            fun coordinator() = CommandCleanupCoordinator(
                ledger = AtomicCommandCleanupLedger(ledgerFile),
                disposer = CleanupProcessDisposer {
                    disposeCalls++
                    CleanupDisposalAttempt(ProcessDisposalResult.DISPOSED)
                },
                immediateScheduler = FakeImmediateScheduler(),
                backstop = backstop,
                launchDirectory = root,
                recoveryProbe = PidProcessProbe { parent },
                parentProcessId = ::currentProcessId,
                nowEpochMs = { 40_000L },
            )
            val original = coordinator()
            original.initialize()
            val key = agentKey("hostile-root-$variant", "operation")
            val launch = original.prepareLaunch(key, null, 60_000L)
            val attemptName = File(requireNotNull(launch.attemptDirectoryPath)).name
            assertTrue(root.deleteRecursively())
            var protectedTarget: File? = null
            var protectedMarker: File? = null
            when (variant) {
                "symlink" -> {
                    protectedTarget = Files.createTempDirectory("hostile-root-target").toFile()
                    val targetAttempt = File(protectedTarget, attemptName).apply { mkdir() }
                    setPrivateDirectory(targetAttempt)
                    protectedMarker = File(targetAttempt, "keep").apply { writeText("keep") }
                    Files.createSymbolicLink(root.toPath(), protectedTarget.toPath())
                }
                "broken-symlink" -> Files.createSymbolicLink(
                    root.toPath(),
                    File(base, "missing-root-target").toPath(),
                )
                "regular" -> root.writeText("hostile-root")
                "wrong-mode" -> {
                    assertTrue(root.mkdir())
                    Files.setPosixFilePermissions(
                        root.toPath(),
                        setOf(
                            PosixFilePermission.OWNER_READ,
                            PosixFilePermission.OWNER_WRITE,
                            PosixFilePermission.OWNER_EXECUTE,
                            PosixFilePermission.GROUP_READ,
                        ),
                    )
                    protectedMarker = File(root, "keep").apply { writeText("keep") }
                }
                "missing" -> Unit
            }

            val recovered = coordinator()
            recovered.initialize()
            recovered.reconcile()
            assertEquals(1, persistedRecords(ledgerFile).size)
            assertFalse(
                protectedTarget?.let { File(it, "$attemptName/revoked").exists() } ?: false,
            )
            parent = PidProbeResult.RetryableUnknown
            recovered.reconcile()
            assertEquals(1, persistedRecords(ledgerFile).size)
            parent = PidProbeResult.Missing
            recovered.reconcile()

            assertTrue(persistedRecords(ledgerFile).isEmpty())
            assertEquals(
                variant != "missing",
                Files.exists(root.toPath(), java.nio.file.LinkOption.NOFOLLOW_LINKS),
            )
            protectedTarget?.let { target ->
                assertTrue(protectedMarker?.exists() == true)
                assertFalse(File(target, "$attemptName/revoked").exists())
            }
            if (variant == "wrong-mode") {
                assertTrue(File(root, "keep").exists())
                assertFalse(File(base, "attempts.retired-command-cleanup").exists())
            }
            assertTrue(recovered.canAdmit(CommandContinuationOwner.AGENT_BASH, key.sessionId))
            assertTrue(backstop.cancelCount > 0)
            assertEquals(0, disposeCalls)
            parent = PidProbeResult.Present(901L)
            val replacement = recovered.prepareLaunch(
                agentKey(key.sessionId, "replacement-operation"),
                null,
                60_000L,
            )
            if (variant == "missing") {
                assertEquals(
                    variant,
                    DurableLaunchRegistrationOutcome.DURABLY_REGISTERED_BACKSTOP_SCHEDULED,
                    replacement.outcome,
                )
            } else {
                assertEquals(
                    DurableLaunchRegistrationOutcome.FAILED_OR_CORRUPT,
                    replacement.outcome,
                )
            }
        }
    }

    @Test
    fun exactAbandonRetiresWithoutMutatingInvalidRoot() {
        val variants = listOf(
            "writable-symlink",
            "broken-symlink",
            "regular",
            "fifo",
            "socket",
            "device-metadata",
            "wrong-owner",
            "wrong-mode",
            "wrong-link-count",
            "valid-mode-nonempty",
            "missing",
        )
        for (variant in variants) {
            val root = Files.createTempDirectory(File("/tmp").toPath(), "er-").toFile()
            val ledgerFile = File(requireNotNull(root.parentFile), "${root.name}.ledger")
            var injectRootMetadata = false
            var socketProcess: Process? = null
            val backstop = FakeBackstop()
            val fileOps = object : LaunchSecureFileOps by NioLaunchSecureFileOps {
                override fun metadata(path: File): LaunchEntryMetadata? {
                    val actual = NioLaunchSecureFileOps.metadata(path) ?: return null
                    if (!injectRootMetadata || path.absoluteFile != root.absoluteFile) return actual
                    return when (variant) {
                        "device-metadata" -> actual.copy(isDirectory = false, isRegularFile = false)
                        "wrong-owner" -> actual.copy(uid = actual.uid + 1)
                        "wrong-link-count" -> actual.copy(linkCount = 99)
                        else -> actual
                    }
                }
            }
            fun coordinator() = CommandCleanupCoordinator(
                ledger = AtomicCommandCleanupLedger(ledgerFile),
                disposer = CleanupProcessDisposer {
                    throw AssertionError("invalid root must not produce process authority")
                },
                immediateScheduler = FakeImmediateScheduler(),
                backstop = backstop,
                launchDirectory = root,
                launchFileOps = fileOps,
                recoveryProbe = PidProcessProbe { PidProbeResult.Present(1101L) },
                parentProcessId = ::currentProcessId,
                nowEpochMs = { 1_000L },
            )
            val original = coordinator()
            original.initialize()
            val key = terminalKey("exact-invalid-root-$variant", "operation")
            val launch = original.prepareLaunch(key, "candidate", 60_000L)
            assertTrue(root.deleteRecursively())
            var protectedMarker: File? = null
            when (variant) {
                "writable-symlink" -> {
                    val target = Files.createTempDirectory("exact-root-target").toFile()
                    protectedMarker = File(target, "keep").apply { writeText("keep") }
                    Files.createSymbolicLink(root.toPath(), target.toPath())
                }
                "broken-symlink" -> Files.createSymbolicLink(
                    root.toPath(),
                    File(requireNotNull(root.parentFile), "missing-${root.name}").toPath(),
                )
                "regular", "device-metadata", "wrong-owner" -> root.writeText("keep")
                "fifo" -> assertEquals(
                    0,
                    ProcessBuilder("mkfifo", root.absolutePath).start().waitFor(),
                )
                "socket" -> {
                    socketProcess = ProcessBuilder(
                        "/usr/bin/python3",
                        "-c",
                        "import socket,sys,time; s=socket.socket(socket.AF_UNIX); " +
                            "s.bind(sys.argv[1]); time.sleep(30)",
                        root.absolutePath,
                    ).start()
                    var waits = 0
                    while (!Files.exists(
                            root.toPath(),
                            java.nio.file.LinkOption.NOFOLLOW_LINKS,
                        ) && waits < 100) {
                        Thread.sleep(10L)
                        waits++
                    }
                }
                "wrong-mode", "wrong-link-count", "valid-mode-nonempty" -> {
                    assertTrue(root.mkdir())
                    setPrivateDirectory(root)
                    protectedMarker = File(root, "keep").apply { writeText("keep") }
                    if (variant == "wrong-mode") {
                        Files.setPosixFilePermissions(
                            root.toPath(),
                            setOf(
                                PosixFilePermission.OWNER_READ,
                                PosixFilePermission.OWNER_WRITE,
                                PosixFilePermission.OWNER_EXECUTE,
                                PosixFilePermission.GROUP_READ,
                            ),
                        )
                    }
                }
                "missing" -> Unit
            }
            injectRootMetadata = variant in setOf(
                "device-metadata",
                "wrong-owner",
                "wrong-link-count",
            )

            val recovered = coordinator()
            recovered.initialize()
            assertFalse(
                recovered.acknowledgeLaunchAbandoned(
                    key,
                    "candidate",
                    requireNotNull(launch.attemptId),
                    "0".repeat(64),
                )
            )
            assertEquals(1, persistedRecords(ledgerFile).size)
            assertTrue(
                recovered.acknowledgeLaunchAbandoned(
                    key,
                    "candidate",
                    requireNotNull(launch.attemptId),
                    requireNotNull(launch.launchToken),
                )
            )

            assertTrue(persistedRecords(ledgerFile).isEmpty())
            assertFalse(
                recovered.acknowledgeLaunchAbandoned(
                    key,
                    "candidate",
                    requireNotNull(launch.attemptId),
                    requireNotNull(launch.launchToken),
                )
            )
            assertEquals(
                variant != "missing",
                Files.exists(root.toPath(), java.nio.file.LinkOption.NOFOLLOW_LINKS),
            )
            protectedMarker?.let { assertTrue(it.exists()) }
            assertTrue(recovered.canAdmit(CommandContinuationOwner.TERMINAL, key.sessionId))
            assertTrue(backstop.cancelCount > 0)
            val replacement = recovered.prepareLaunch(
                terminalKey(key.sessionId, "replacement-operation"),
                "replacement",
                60_000L,
            )
            assertEquals(
                variant,
                if (variant == "missing") {
                    DurableLaunchRegistrationOutcome.DURABLY_REGISTERED_BACKSTOP_SCHEDULED
                } else {
                    DurableLaunchRegistrationOutcome.FAILED_OR_CORRUPT
                },
                replacement.outcome,
            )
            socketProcess?.destroyForcibly()
            socketProcess?.waitFor(5, TimeUnit.SECONDS)
        }
    }

    @Test
    fun exactAbandonConvergesMalformedTwinWithoutPidAuthority() {
        val directory = Files.createTempDirectory("claim-malformed-abandon").toFile()
        val ledger = FakeLedger()
        var disposeCalls = 0
        val coordinator = CommandCleanupCoordinator(
            ledger = ledger,
            disposer = CleanupProcessDisposer {
                disposeCalls++
                CleanupDisposalAttempt(ProcessDisposalResult.DISPOSED)
            },
            immediateScheduler = FakeImmediateScheduler(),
            backstop = FakeBackstop(),
            launchDirectory = directory,
            recoveryProbe = PidProcessProbe { PidProbeResult.Present(701L) },
            parentProcessId = ::currentProcessId,
            nowEpochMs = { 1_000L },
        )
        coordinator.initialize()
        val key = terminalKey("malformed-abandon", "operation")
        val launch = coordinator.prepareLaunch(key, "candidate", 60_000L)
        val attempt = File(requireNotNull(launch.attemptDirectoryPath))
        val temporary = File(attempt, "claim.tmp.904")
        writePrivate(temporary, "broken\n".toByteArray())
        Files.createLink(File(requireNotNull(launch.stagingPath)).toPath(), temporary.toPath())

        assertTrue(
            coordinator.acknowledgeLaunchAbandoned(
                key,
                "candidate",
                requireNotNull(launch.attemptId),
                requireNotNull(launch.launchToken),
            )
        )
        assertTrue(ledger.records.isEmpty())
        assertTrue(attempt.exists())
        assertEquals(0, disposeCalls)
    }

    @Test
    fun cancellationDuringClaimTempAndLinkCrashCannotLeaveAuthority() {
        val directory = Files.createTempDirectory("claim-cancel-barriers").toFile()
        var claimantGone = false
        val coordinator = CommandCleanupCoordinator(
            ledger = FakeLedger(),
            disposer = CleanupProcessDisposer {
                throw AssertionError("gone claim must clear without signal")
            },
            immediateScheduler = FakeImmediateScheduler(),
            backstop = FakeBackstop(),
            launchDirectory = directory,
            recoveryProbe = PidProcessProbe { processId ->
                if (claimantGone && processId == 805) PidProbeResult.Missing
                else PidProbeResult.Present(1L)
            },
            parentProcessId = ::currentProcessId,
            nowEpochMs = { 1_000L },
        )
        coordinator.initialize()
        val tempKey = terminalKey("claim-temp-cancel", "operation")
        val tempLaunch = coordinator.prepareLaunch(tempKey, "candidate", 60_000L)
        val temp = File(requireNotNull(tempLaunch.attemptDirectoryPath), "claim.tmp.804")
        writePrivate(temp, "${tempLaunch.launchToken}\n804\n84\n".toByteArray())
        assertTrue(
            coordinator.acknowledgeLaunchAbandoned(
                tempKey,
                "candidate",
                requireNotNull(tempLaunch.attemptId),
                requireNotNull(tempLaunch.launchToken),
            )
        )
        assertTrue(File(requireNotNull(tempLaunch.attemptDirectoryPath)).exists())

        val linkKey = terminalKey("claim-link-cancel", "operation")
        val linkLaunch = coordinator.prepareLaunch(linkKey, "candidate", 60_000L)
        val linkedTemp = File(requireNotNull(linkLaunch.attemptDirectoryPath), "claim.tmp.805")
        val claim = File(requireNotNull(linkLaunch.stagingPath))
        writePrivate(linkedTemp, "${linkLaunch.launchToken}\n805\n85\n".toByteArray())
        Files.createLink(claim.toPath(), linkedTemp.toPath())
        claimantGone = true
        assertTrue(coordinator.requestCleanup(linkKey, "candidate"))
        coordinator.reconcile()
        assertTrue(coordinator.recordsForTest().isEmpty())
    }

    @Test
    fun noClaimRequiresParentGoneOrExactCallerAbandonAcknowledgment() {
        val ledger = FakeLedger()
        var parent: PidProbeResult = PidProbeResult.Present(91L)
        val coordinator = CommandCleanupCoordinator(
            ledger = ledger,
            disposer = CleanupProcessDisposer {
                throw AssertionError("no claimant must never be signalled")
            },
            immediateScheduler = FakeImmediateScheduler(),
            backstop = FakeBackstop(),
            launchDirectory = Files.createTempDirectory("no-claim-parent").toFile(),
            recoveryProbe = PidProcessProbe { parent },
            parentProcessId = ::currentProcessId,
            nowEpochMs = { 1_000L },
        )
        coordinator.initialize()
        val key = terminalKey("no-claim-parent", "operation")
        coordinator.prepareLaunch(key, "candidate", 60_000L)
        assertTrue(coordinator.requestCleanup(key, "candidate"))
        coordinator.reconcile()
        assertEquals(1, ledger.records.size)
        parent = PidProbeResult.RetryableUnknown
        coordinator.reconcile()
        assertEquals(1, ledger.records.size)
        parent = PidProbeResult.Present(92L)
        coordinator.reconcile()
        assertTrue(ledger.records.isEmpty())

        parent = PidProbeResult.Present(91L)
        val goneKey = terminalKey("parent-gone", "operation")
        coordinator.prepareLaunch(goneKey, "candidate", 60_000L)
        assertTrue(coordinator.requestCleanup(goneKey, "candidate"))
        parent = PidProbeResult.Missing
        coordinator.reconcile()
        assertTrue(ledger.records.isEmpty())

        parent = PidProbeResult.Present(91L)
        val secondKey = terminalKey("caller-abandon", "operation")
        val second = coordinator.prepareLaunch(secondKey, "candidate", 60_000L)
        assertFalse(
            coordinator.acknowledgeLaunchAbandoned(
                secondKey,
                "candidate",
                requireNotNull(second.attemptId),
                "0".repeat(64),
            )
        )
        assertTrue(
            coordinator.acknowledgeLaunchAbandoned(
                secondKey,
                "candidate",
                requireNotNull(second.attemptId),
                requireNotNull(second.launchToken),
            )
        )
        assertTrue(ledger.records.isEmpty())
        assertFalse(
            coordinator.acknowledgeLaunchAbandoned(
                secondKey,
                "candidate",
                requireNotNull(second.attemptId),
                requireNotNull(second.launchToken),
            )
        )
    }

    @Test
    fun hostileGoSymlinkCannotReleaseInsideOrOutsideAttemptDirectory() {
        for (outside in listOf(false, true)) {
            val directory = Files.createTempDirectory("launch-hostile-go").toFile()
            val coordinator = CommandCleanupCoordinator(
                ledger = FakeLedger(),
                disposer = CleanupProcessDisposer {
                    CleanupDisposalAttempt(ProcessDisposalResult.RETRYABLE_UNKNOWN)
                },
                immediateScheduler = FakeImmediateScheduler(),
                backstop = FakeBackstop(),
                launchDirectory = directory,
                recoveryProbe = PidProcessProbe { PidProbeResult.Present(777L) },
                parentProcessId = ::currentProcessId,
                nowEpochMs = { 1_000L },
            )
            coordinator.initialize()
            val key = terminalKey("hostile-go-$outside", "operation")
            val launch = coordinator.prepareLaunch(key, "candidate", 60_000L)
            stageLaunch(launch, 777, 777L)
            val token = coordinator.activateWaitingLaunch(
                key,
                "candidate",
                requireNotNull(launch.attemptId),
                requireNotNull(launch.launchToken),
                777,
                PidProcessProbe { PidProbeResult.Present(777L) },
            )
            val target = if (outside) {
                File(directory.parentFile, "outside-go-target-${launch.attemptId}")
            } else {
                File(requireNotNull(launch.attemptDirectoryPath), "inside-go-target")
            }.apply { writeText("unchanged") }
            Files.createSymbolicLink(File(requireNotNull(launch.goPath)).toPath(), target.toPath())
            assertFalse(
                coordinator.releaseLaunch(
                    key,
                    "candidate",
                    requireNotNull(launch.attemptId),
                    requireNotNull(launch.launchToken),
                    requireNotNull(token),
                )
            )
            assertEquals("unchanged", target.readText())
        }
    }

    @Test
    fun wrapperRejectsHostileGoTypesModesLinksSizesAndIdentities() {
        val cases = listOf<(CommandLaunchPreparation) -> Unit>(
            { launch -> writePrivate(File(requireNotNull(launch.goPath)), byteArrayOf()) },
            { launch -> writePrivate(File(requireNotNull(launch.goPath)), ByteArray(257) { 1 }) },
            { launch ->
                writePrivate(
                    File(requireNotNull(launch.goPath)),
                    "${launch.launchToken}\n999999\n1\n".toByteArray(),
                )
            },
            { launch ->
                File(requireNotNull(launch.goPath)).apply {
                    writeText("${launch.launchToken}\n1\n1\n")
                    Files.setPosixFilePermissions(
                        toPath(),
                        setOf(PosixFilePermission.OWNER_READ),
                    )
                }
            },
            { launch ->
                val target = File(requireNotNull(launch.attemptDirectoryPath), "hard-link-target")
                writePrivate(target, "${launch.launchToken}\n1\n1\n".toByteArray())
                Files.createLink(File(requireNotNull(launch.goPath)).toPath(), target.toPath())
            },
            { launch ->
                val target = File(requireNotNull(launch.attemptDirectoryPath), "symlink-target")
                writePrivate(target, "${launch.launchToken}\n1\n1\n".toByteArray())
                Files.createSymbolicLink(File(requireNotNull(launch.goPath)).toPath(), target.toPath())
            },
            { launch ->
                val fifo = File(requireNotNull(launch.goPath))
                assertEquals(0, ProcessBuilder("mkfifo", fifo.absolutePath).start().waitFor())
            },
        )
        for ((index, installHostileGo) in cases.withIndex()) {
            val directory = Files.createTempDirectory("launch-hostile-matrix-$index").toFile()
            val coordinator = CommandCleanupCoordinator(
                ledger = FakeLedger(),
                disposer = CleanupProcessDisposer {
                    CleanupDisposalAttempt(ProcessDisposalResult.RETRYABLE_UNKNOWN)
                },
                immediateScheduler = FakeImmediateScheduler(),
                backstop = FakeBackstop(),
                launchDirectory = directory,
                recoveryProbe = PidProcessProbe { PidProbeResult.Present(1L) },
                parentProcessId = ::currentProcessId,
                nowEpochMs = { 1_000L },
            )
            coordinator.initialize()
            val launch = coordinator.prepareLaunch(
                terminalKey("hostile-matrix-$index", "operation"),
                "candidate",
                60_000L,
            )
            val marker = File(directory, "must-not-run")
            val wrapper = ProcessBuilder(
                "/bin/sh",
                launch.wrapperPath,
                launch.attemptDirectoryPath,
                launch.launchToken,
                launch.parentProcessId.toString(),
                launch.appUid.toString(),
                "--",
                "/usr/bin/touch",
                marker.absolutePath,
            ).start()
            waitForPidFile(File(requireNotNull(launch.stagingPath)))
            installHostileGo(launch)
            assertTrue("case $index did not exit", wrapper.waitFor(5, TimeUnit.SECONDS))
            assertTrue("case $index unexpectedly accepted GO", wrapper.exitValue() != 0)
            assertFalse(marker.exists())
        }
    }

    @Test
    fun launchWrapperRejectsStaleParentAndTreatsMetacharactersAsOpaqueArgv() {
        val directory = Files.createTempDirectory("launch-gate-argv").toFile()
        val coordinator = CommandCleanupCoordinator(
            ledger = FakeLedger(),
            disposer = CleanupProcessDisposer {
                CleanupDisposalAttempt(ProcessDisposalResult.RETRYABLE_UNKNOWN)
            },
            immediateScheduler = FakeImmediateScheduler(),
            backstop = FakeBackstop(),
            launchDirectory = directory,
            recoveryProbe = PidProcessProbe { PidProbeResult.Present(136L) },
            parentProcessId = ::currentProcessId,
            nowEpochMs = { 1_000L },
        )
        coordinator.initialize()

        val stale = coordinator.prepareLaunch(
            terminalKey("stale-parent", "operation"),
            "candidate",
            60_000L,
        )
        val staleMarker = File(directory, "stale-parent-marker")
        val staleProcess = ProcessBuilder(
            "/bin/sh",
            stale.wrapperPath,
            stale.attemptDirectoryPath,
            stale.launchToken,
            (requireNotNull(stale.parentProcessId) + 1).toString(),
            stale.appUid.toString(),
            "--",
            "/usr/bin/touch",
            staleMarker.absolutePath,
        ).start()
        assertTrue(staleProcess.waitFor(5, TimeUnit.SECONDS))
        assertEquals(123, staleProcess.exitValue())
        assertFalse(staleMarker.exists())
        assertFalse(File(requireNotNull(stale.stagingPath)).exists())

        val key = agentKey("opaque-argv", "operation")
        val launch = coordinator.prepareLaunch(key, null, 60_000L)
        val injectedMarker = File(directory, "must-not-be-injected")
        val output = File(directory, "literal-argument")
        val literal = "\$(touch ${injectedMarker.absolutePath}); still-data"
        val process = ProcessBuilder(
            "/bin/sh",
            launch.wrapperPath,
            launch.attemptDirectoryPath,
            launch.launchToken,
            launch.parentProcessId.toString(),
            launch.appUid.toString(),
            "--",
            "/bin/sh",
            "-c",
            "printf '%s' \"\$1\" > \"\$2\"",
            "argv0",
            literal,
            output.absolutePath,
        ).start()
        waitForPidFile(File(requireNotNull(launch.stagingPath)))
        assertFalse(output.exists())
        val token = coordinator.activateWaitingLaunch(
            key,
            null,
            requireNotNull(launch.attemptId),
            requireNotNull(launch.launchToken),
            processPid(process),
            PidProcessProbe { PidProbeResult.Present(stagedGeneration(launch)) },
        )
        assertTrue(
            coordinator.releaseLaunch(
                key,
                null,
                requireNotNull(launch.attemptId),
                requireNotNull(launch.launchToken),
                requireNotNull(token),
            )
        )
        assertTrue(process.waitFor(5, TimeUnit.SECONDS))
        assertEquals(literal, output.readText())
        assertFalse(injectedMarker.exists())
        assertEquals(
            setOf(PosixFilePermission.OWNER_READ, PosixFilePermission.OWNER_WRITE),
            Files.getPosixFilePermissions(File(launch.stagingPath).toPath()),
        )
    }

    @Test
    fun failedHandshakePersistsGenerationBeforeAnyCleanupSignal() {
        val ledger = FakeLedger()
        val attempts = AtomicInteger()
        val coordinator = CommandCleanupCoordinator(
            ledger = ledger,
            disposer = CleanupProcessDisposer { record ->
                attempts.incrementAndGet()
                assertEquals(CleanupDisposalState.SIGNAL_INTENT, record.disposalState)
                assertEquals(1_361, record.processId)
                assertEquals(136L, record.startTimeTicks)
                CleanupDisposalAttempt(ProcessDisposalResult.DISPOSED)
            },
            immediateScheduler = FakeImmediateScheduler(),
            backstop = FakeBackstop(),
            launchDirectory = Files.createTempDirectory("launch-handshake-cleanup").toFile(),
            recoveryProbe = PidProcessProbe { PidProbeResult.Present(136L) },
            parentProcessId = ::currentProcessId,
            nowEpochMs = { 1_000L },
        )
        coordinator.initialize()
        val key = agentKey("handshake", "operation")
        val launch = coordinator.prepareLaunch(key, null, 60_000L)
        assertEquals(
            DurableLaunchRegistrationOutcome.DURABLY_REGISTERED_BACKSTOP_SCHEDULED,
            launch.outcome,
        )
        stageLaunch(launch, 1_361, 136L)
        assertFalse(
            coordinator.requestWaitingLaunchCleanup(
                key,
                null,
                requireNotNull(launch.attemptId),
                requireNotNull(launch.launchToken),
                1_361,
                PidProcessProbe { PidProbeResult.RetryableUnknown },
            ),
        )
        assertEquals(CleanupDisposalState.CANCEL_REQUESTED, ledger.records.single().disposalState)
        assertEquals(0, attempts.get())
        assertTrue(
            coordinator.requestWaitingLaunchCleanup(
                key,
                null,
                requireNotNull(launch.attemptId),
                requireNotNull(launch.launchToken),
                1_361,
                PidProcessProbe { PidProbeResult.Present(136L) },
            ),
        )
        assertEquals(CleanupDisposalState.SIGNAL_INTENT, ledger.records.single().disposalState)
        coordinator.reconcile()
        assertEquals(1, attempts.get())
        assertTrue(ledger.records.isEmpty())
    }

    @Test
    fun freshProcessCleansWaitingWrapperBeforeSameSessionAdmission() {
        val directory = Files.createTempDirectory("launch-gate-recreate").toFile()
        val ledgerFile = File(directory, "ledger.bin")
        val launchDirectory = File(directory, "launch")
        val first = CommandCleanupCoordinator(
            ledger = AtomicCommandCleanupLedger(ledgerFile),
            disposer = CleanupProcessDisposer {
                CleanupDisposalAttempt(ProcessDisposalResult.RETRYABLE_UNKNOWN)
            },
            immediateScheduler = FakeImmediateScheduler(),
            backstop = FakeBackstop(),
            launchDirectory = launchDirectory,
            recoveryProbe = PidProcessProbe { processId ->
                PidProbeResult.Present(stagedGenerationForPid(launchDirectory, processId))
            },
            parentProcessId = ::currentProcessId,
            nowEpochMs = { 1_000L },
        )
        first.initialize()
        val key = terminalKey("waiting-recreate", "operation")
        val launch = first.prepareLaunch(key, "candidate", 60_000L)
        val marker = File(directory, "must-not-run")
        val wrapper = ProcessBuilder(
            "/bin/sh",
            launch.wrapperPath,
            launch.attemptDirectoryPath,
            launch.launchToken,
            launch.parentProcessId.toString(),
            launch.appUid.toString(),
            "--",
            "/usr/bin/touch",
            marker.absolutePath,
        ).start()
        waitForPidFile(File(requireNotNull(launch.stagingPath)))

        var firstCleanupAttempt = true
        val recreated = CommandCleanupCoordinator(
            ledger = AtomicCommandCleanupLedger(ledgerFile),
            disposer = CleanupProcessDisposer {
                if (firstCleanupAttempt) {
                    firstCleanupAttempt = false
                    return@CleanupProcessDisposer CleanupDisposalAttempt(
                        ProcessDisposalResult.RETRYABLE_UNKNOWN,
                    )
                }
                wrapper.destroyForcibly()
                wrapper.waitFor(5, TimeUnit.SECONDS)
                CleanupDisposalAttempt(ProcessDisposalResult.DISPOSED)
            },
            immediateScheduler = FakeImmediateScheduler(),
            backstop = FakeBackstop(),
            launchDirectory = launchDirectory,
            recoveryProbe = PidProcessProbe { processId ->
                PidProbeResult.Present(stagedGenerationForPid(launchDirectory, processId))
            },
            parentProcessId = ::currentProcessId,
            nowEpochMs = { 2_000L },
        )
        recreated.initialize()
        assertFalse(
            recreated.canAdmit(
                CommandContinuationOwner.TERMINAL,
                "waiting-recreate",
            ),
        )
        recreated.reconcile()
        assertTrue(
            recreated.canAdmit(
                CommandContinuationOwner.TERMINAL,
                "waiting-recreate",
            ),
        )
        assertFalse(marker.exists())
        assertFalse(wrapper.isAlive)
        assertFalse(File(requireNotNull(launch.attemptDirectoryPath)).exists())
    }

    @Test
    fun stagingSymlinkAndBackstopFailureFailLaunchClosed() {
        val directory = Files.createTempDirectory("launch-gate-symlink").toFile()
        val ledger = FakeLedger()
        val coordinator = CommandCleanupCoordinator(
            ledger = ledger,
            disposer = CleanupProcessDisposer {
                CleanupDisposalAttempt(ProcessDisposalResult.RETRYABLE_UNKNOWN)
            },
            immediateScheduler = FakeImmediateScheduler(),
            backstop = FakeBackstop(acceptSchedules = false),
            launchDirectory = directory,
            recoveryProbe = PidProcessProbe { PidProbeResult.Present(151L) },
            parentProcessId = ::currentProcessId,
            nowEpochMs = { 1_000L },
        )
        coordinator.initialize()
        val key = terminalKey("scheduler-failed", "operation")
        val rejected = coordinator.prepareLaunch(key, "candidate", 60_000L)
        assertEquals(
            DurableLaunchRegistrationOutcome.DURABLY_REGISTERED_BACKSTOP_PENDING,
            rejected.outcome,
        )
        assertTrue(rejected.wrapperPath == null)
        assertEquals(CleanupDisposalState.BACKSTOP_PENDING, ledger.records.single().disposalState)

        val accepted = coordinator(
            FakeLedger(),
            FakeImmediateScheduler(),
            FakeBackstop(),
        ) { ProcessDisposalResult.RETRYABLE_UNKNOWN }
        accepted.initialize()
        val acceptedLaunch = accepted.prepareLaunch(
            terminalKey("symlink", "operation"),
            "candidate",
            60_000L,
        )
        val staging = File(requireNotNull(acceptedLaunch.stagingPath))
        val target = File(staging.parentFile, "attacker-target").apply { writeText("999\n") }
        Files.createSymbolicLink(staging.toPath(), target.toPath())
        assertTrue(
            accepted.activateWaitingLaunch(
                terminalKey("symlink", "operation"),
                "candidate",
                requireNotNull(acceptedLaunch.attemptId),
                requireNotNull(acceptedLaunch.launchToken),
                999,
                PidProcessProbe { PidProbeResult.Present(151L) },
            ) == null,
        )

        val wrapperDirectory = Files.createTempDirectory("launch-wrapper-symlink").toFile()
        val outside = File(wrapperDirectory.parentFile, "outside-wrapper").apply {
            writeText("exit 0\n")
        }
        Files.createSymbolicLink(
            File(wrapperDirectory, "command_launch_gate.sh").toPath(),
            outside.toPath(),
        )
        val wrapperSymlink = CommandCleanupCoordinator(
            ledger = FakeLedger(),
            disposer = CleanupProcessDisposer {
                CleanupDisposalAttempt(ProcessDisposalResult.RETRYABLE_UNKNOWN)
            },
            immediateScheduler = FakeImmediateScheduler(),
            backstop = FakeBackstop(),
            launchDirectory = wrapperDirectory,
            recoveryProbe = PidProcessProbe { PidProbeResult.Present(151L) },
            parentProcessId = ::currentProcessId,
            nowEpochMs = { 1_000L },
        )
        wrapperSymlink.initialize()
        assertEquals(
            DurableLaunchRegistrationOutcome.FAILED_OR_CORRUPT,
            wrapperSymlink.prepareLaunch(
                terminalKey("wrapper-symlink", "operation"),
                "candidate",
                60_000L,
            ).outcome,
        )
    }

    @Test
    fun ledgerFailureAndSchedulerExceptionExposeNoSpawnCapability() {
        val failedLedger = FakeLedger().apply { failWrites = true }
        val failedCoordinator = coordinator(
            failedLedger,
            FakeImmediateScheduler(),
            FakeBackstop(),
        ) { ProcessDisposalResult.RETRYABLE_UNKNOWN }
        failedCoordinator.initialize()
        val failed = failedCoordinator.prepareLaunch(
            terminalKey("ledger-failed", "operation"),
            "candidate",
            60_000L,
        )
        assertEquals(DurableLaunchRegistrationOutcome.FAILED_OR_CORRUPT, failed.outcome)
        assertTrue(failed.wrapperPath == null)

        val throwingLedger = FakeLedger()
        val throwingCoordinator = coordinator(
            throwingLedger,
            FakeImmediateScheduler(),
            FakeBackstop(throwSchedules = true),
        ) { ProcessDisposalResult.RETRYABLE_UNKNOWN }
        throwingCoordinator.initialize()
        val pending = throwingCoordinator.prepareLaunch(
            terminalKey("scheduler-throws", "operation"),
            "candidate",
            60_000L,
        )
        assertEquals(
            DurableLaunchRegistrationOutcome.DURABLY_REGISTERED_BACKSTOP_PENDING,
            pending.outcome,
        )
        assertTrue(pending.wrapperPath == null)
        assertEquals(CleanupDisposalState.BACKSTOP_PENDING, throwingLedger.records.single().disposalState)
    }

    @Test
    fun ordinaryExactAbandonCyclesKeepAttemptDirectoryCountBounded() {
        val root = Files.createTempDirectory("cleanup-abandon-stress").toFile()
        val ledger = FakeLedger()
        val backstop = FakeBackstop()
        val coordinator = CommandCleanupCoordinator(
            ledger = ledger,
            disposer = CleanupProcessDisposer {
                throw AssertionError("abandoned capability has no process authority")
            },
            immediateScheduler = FakeImmediateScheduler(),
            backstop = backstop,
            launchDirectory = root,
            recoveryProbe = PidProcessProbe { PidProbeResult.Present(1L) },
            parentProcessId = ::currentProcessId,
            nowEpochMs = { 1_000L },
        )
        coordinator.initialize()

        repeat(100) { index ->
            val key = terminalKey("bounded-abandon", "operation-$index")
            val launch = coordinator.prepareLaunch(key, "candidate-$index", 60_000L)
            val attempt = File(requireNotNull(launch.attemptDirectoryPath))
            assertTrue(attempt.exists())
            assertTrue(
                coordinator.acknowledgeLaunchAbandoned(
                    key,
                    "candidate-$index",
                    requireNotNull(launch.attemptId),
                    requireNotNull(launch.launchToken),
                )
            )
            assertFalse(attempt.exists())
            assertTrue(ledger.records.isEmpty())
            assertTrue(coordinator.canAdmit(CommandContinuationOwner.TERMINAL, key.sessionId))
            assertEquals(
                0,
                root.listFiles().orEmpty().count { it.name.startsWith("attempt-") },
            )
        }
        assertTrue(backstop.cancelCount >= 100)
    }

    @Test
    fun completeAndDefinitiveDisposalCyclesReclaimConsumedLaunchArtifacts() {
        val root = Files.createTempDirectory("cleanup-complete-stress").toFile()
        val ledger = FakeLedger()
        val backstop = FakeBackstop()
        var childGeneration = 0L
        var childAlive = true
        val parentPid = currentProcessId()
        val coordinator = CommandCleanupCoordinator(
            ledger = ledger,
            disposer = CleanupProcessDisposer {
                CleanupDisposalAttempt(ProcessDisposalResult.DISPOSED)
            },
            immediateScheduler = FakeImmediateScheduler(),
            backstop = backstop,
            launchDirectory = root,
            recoveryProbe = PidProcessProbe { processId ->
                when {
                    processId == parentPid -> PidProbeResult.Present(1L)
                    childAlive -> PidProbeResult.Present(childGeneration)
                    else -> PidProbeResult.Missing
                }
            },
            parentProcessId = { parentPid },
            nowEpochMs = { 1_000L },
        )
        coordinator.initialize()

        repeat(60) { index ->
            val key = agentKey("bounded-active", "operation-$index")
            val processId = 20_000 + index
            childGeneration = 30_000L + index
            childAlive = true
            val launch = coordinator.prepareLaunch(key, null, 60_000L)
            stageLaunch(launch, processId, childGeneration)
            val token = requireNotNull(
                coordinator.activateWaitingLaunch(
                    key,
                    null,
                    requireNotNull(launch.attemptId),
                    requireNotNull(launch.launchToken),
                    processId,
                    PidProcessProbe { PidProbeResult.Present(childGeneration) },
                )
            )
            assertTrue(
                coordinator.releaseLaunch(
                    key,
                    null,
                    requireNotNull(launch.attemptId),
                    requireNotNull(launch.launchToken),
                    token,
                )
            )
            val attempt = File(requireNotNull(launch.attemptDirectoryPath))
            Files.createDirectory(File(attempt, "release-claim").toPath())
            setPrivateDirectory(File(attempt, "release-claim"))
            Files.move(File(attempt, "go").toPath(), File(attempt, "go.consumed").toPath())
            childAlive = false
            if (index % 2 == 0) {
                assertTrue(coordinator.complete(key, null))
            } else {
                assertTrue(coordinator.requestCleanup(key, null))
                coordinator.reconcile()
            }
            assertFalse(attempt.exists())
            assertTrue(ledger.records.isEmpty())
            assertEquals(
                0,
                root.listFiles().orEmpty().count { it.name.startsWith("attempt-") },
            )
        }
        assertTrue(backstop.cancelCount >= 60)
    }

    @Test
    fun validAttemptCleanupAbortsOnSubstitutionWithoutRestoringAuthority() {
        for (variant in listOf("before-enumeration", "before-delete", "before-rmdir", "root")) {
            val root = Files.createTempDirectory("cleanup-substitution-$variant").toFile()
            val outside = Files.createTempDirectory("cleanup-outside-$variant").toFile()
            val marker = File(outside, "marker").apply { writeText("untouched") }
            var attempt: File? = null
            var armed = false
            var fired = false
            val fileOps = object : LaunchSecureFileOps by NioLaunchSecureFileOps {
                private fun substitute() {
                    if (!armed || fired) return
                    fired = true
                    val exactAttempt = requireNotNull(attempt)
                    when (variant) {
                        "before-enumeration", "before-rmdir" -> {
                            Files.move(
                                exactAttempt.toPath(),
                                File(root, "saved-attempt").toPath(),
                            )
                            Files.createSymbolicLink(exactAttempt.toPath(), outside.toPath())
                        }
                        "before-delete" -> {
                            val revoked = File(exactAttempt, "revoked")
                            Files.delete(revoked.toPath())
                            writePrivate(revoked, "hostile replacement".toByteArray())
                        }
                        "root" -> {
                            val savedRoot = File(root.parentFile, "${root.name}.saved")
                            Files.move(root.toPath(), savedRoot.toPath())
                            Files.createSymbolicLink(root.toPath(), outside.toPath())
                        }
                    }
                }

                override fun listEntriesIfSame(
                    path: File,
                    expected: LaunchEntryMetadata,
                ): List<File>? {
                    if (variant == "before-enumeration" && path == attempt) substitute()
                    return NioLaunchSecureFileOps.listEntriesIfSame(path, expected)
                }

                override fun deleteFileIfSame(
                    path: File,
                    expected: LaunchEntryMetadata,
                ): Boolean {
                    if (variant == "before-delete") substitute()
                    if (variant == "root") substitute()
                    return NioLaunchSecureFileOps.deleteFileIfSame(path, expected)
                }

                override fun deleteEmptyDirectoryIfSame(
                    path: File,
                    expected: LaunchEntryMetadata,
                ): Boolean {
                    if (variant == "before-rmdir" && path == attempt) substitute()
                    return NioLaunchSecureFileOps.deleteEmptyDirectoryIfSame(path, expected)
                }
            }
            val ledger = FakeLedger()
            val backstop = FakeBackstop()
            val coordinator = CommandCleanupCoordinator(
                ledger = ledger,
                disposer = CleanupProcessDisposer {
                    throw AssertionError("abandoned capability has no process authority")
                },
                immediateScheduler = FakeImmediateScheduler(),
                backstop = backstop,
                launchDirectory = root,
                launchFileOps = fileOps,
                recoveryProbe = PidProcessProbe { PidProbeResult.Present(1L) },
                parentProcessId = ::currentProcessId,
                nowEpochMs = { 1_000L },
            )
            coordinator.initialize()
            val key = terminalKey("substitution-$variant", "operation")
            val launch = coordinator.prepareLaunch(key, "candidate", 60_000L)
            attempt = File(requireNotNull(launch.attemptDirectoryPath))
            armed = true
            assertTrue(
                coordinator.acknowledgeLaunchAbandoned(
                    key,
                    "candidate",
                    requireNotNull(launch.attemptId),
                    requireNotNull(launch.launchToken),
                )
            )
            assertTrue(fired)
            assertEquals("untouched", marker.readText())
            assertTrue(ledger.records.isEmpty())
            assertTrue(backstop.cancelCount > 0)
            assertTrue(coordinator.canAdmit(CommandContinuationOwner.TERMINAL, key.sessionId))
        }
    }

    @Test
    fun cleanupIdentityMismatchBetweenKnownChildDeletesLeavesOnlyResidual() {
        val root = Files.createTempDirectory("cleanup-between-deletes").toFile()
        var deleteCalls = 0
        var replacement: File? = null
        val fileOps = object : LaunchSecureFileOps by NioLaunchSecureFileOps {
            override fun deleteFileIfSame(
                path: File,
                expected: LaunchEntryMetadata,
            ): Boolean {
                if (deleteCalls++ == 1) {
                    Files.delete(path.toPath())
                    writePrivate(path, "same name, different inode".toByteArray())
                    replacement = path
                }
                return NioLaunchSecureFileOps.deleteFileIfSame(path, expected)
            }
        }
        val ledger = FakeLedger()
        var childAlive = true
        val parentPid = currentProcessId()
        val coordinator = CommandCleanupCoordinator(
            ledger = ledger,
            disposer = CleanupProcessDisposer {
                CleanupDisposalAttempt(ProcessDisposalResult.DISPOSED)
            },
            immediateScheduler = FakeImmediateScheduler(),
            backstop = FakeBackstop(),
            launchDirectory = root,
            launchFileOps = fileOps,
            recoveryProbe = PidProcessProbe { processId ->
                if (processId == parentPid) PidProbeResult.Present(1L)
                else if (childAlive) PidProbeResult.Present(77L) else PidProbeResult.Missing
            },
            parentProcessId = { parentPid },
            nowEpochMs = { 1_000L },
        )
        coordinator.initialize()
        val key = terminalKey("between-child-delete", "operation")
        val launch = coordinator.prepareLaunch(key, "candidate", 60_000L)
        stageLaunch(launch, 77, 77L)
        val token = requireNotNull(
            coordinator.activateWaitingLaunch(
                key,
                "candidate",
                requireNotNull(launch.attemptId),
                requireNotNull(launch.launchToken),
                77,
                PidProcessProbe { PidProbeResult.Present(77L) },
            )
        )
        assertTrue(
            coordinator.releaseLaunch(
                key,
                "candidate",
                requireNotNull(launch.attemptId),
                requireNotNull(launch.launchToken),
                token,
            )
        )
        val attempt = File(requireNotNull(launch.attemptDirectoryPath))
        childAlive = false
        assertTrue(coordinator.complete(key, "candidate"))
        assertTrue(ledger.records.isEmpty())
        assertTrue(attempt.exists())
        assertEquals("same name, different inode", requireNotNull(replacement).readText())
        assertTrue(coordinator.canAdmit(CommandContinuationOwner.TERMINAL, key.sessionId))
    }

    private fun rewriteSchemaWithValidCrc(bytes: ByteArray, schema: Int): ByteArray {
        val rewritten = bytes.copyOf()
        ByteBuffer.wrap(rewritten, 4, 4).putInt(schema)
        val bodySize = rewritten.size - 8
        val crc = CRC32().apply { update(rewritten, 0, bodySize) }.value
        ByteBuffer.wrap(rewritten, bodySize, 8).putLong(crc)
        return rewritten
    }

    private fun waitForPidFile(file: File, process: Process? = null) {
        repeat(100) {
            if (file.exists() && file.length() > 0L) return
            if (process?.isAlive == false) {
                val error = process.errorStream.bufferedReader().readText()
                throw AssertionError(
                    "wrapper exited ${process.exitValue()} before ${file.name}: $error"
                )
            }
            Thread.sleep(20L)
        }
        throw AssertionError("timed out waiting for ${file.name}")
    }

    private fun stageLaunch(
        preparation: CommandLaunchPreparation,
        processId: Int,
        startTimeTicks: Long,
    ) {
        val staging = File(requireNotNull(preparation.stagingPath))
        staging.writeText(
            "${requireNotNull(preparation.launchToken)}\n$processId\n$startTimeTicks\n"
        )
        Files.setPosixFilePermissions(
            staging.toPath(),
            setOf(PosixFilePermission.OWNER_READ, PosixFilePermission.OWNER_WRITE),
        )
    }

    private fun stagedGeneration(preparation: CommandLaunchPreparation): Long =
        File(requireNotNull(preparation.stagingPath)).readLines()[2].toLong()

    private fun stagedGenerationForPid(directory: File, processId: Int): Long {
        val staged = directory.listFiles().orEmpty()
            .filter { it.isDirectory && it.name.startsWith("attempt-") }
            .map { File(it, "pid") }
            .firstOrNull { file ->
                file.isFile && file.readLines().getOrNull(1)?.toIntOrNull() == processId
            } ?: return 1L
        return staged.readLines()[2].toLong()
    }

    private fun writePrivate(file: File, bytes: ByteArray) {
        file.writeBytes(bytes)
        Files.setPosixFilePermissions(
            file.toPath(),
            setOf(PosixFilePermission.OWNER_READ, PosixFilePermission.OWNER_WRITE),
        )
    }

    private fun setPrivateDirectory(directory: File) {
        Files.setPosixFilePermissions(
            directory.toPath(),
            setOf(
                PosixFilePermission.OWNER_READ,
                PosixFilePermission.OWNER_WRITE,
                PosixFilePermission.OWNER_EXECUTE,
            ),
        )
    }

    private fun persistedRecords(file: File): List<CommandCleanupRecord> =
        (AtomicCommandCleanupLedger(file).read() as CleanupLedgerRead.Success).records

    private fun processPid(process: Process): Int =
        (Process::class.java.getMethod("pid").invoke(process) as Long).toInt()

    private fun coordinator(
        ledger: CommandCleanupLedger,
        scheduler: FakeImmediateScheduler,
        backstop: FakeBackstop,
        disposer: (CommandCleanupRecord) -> ProcessDisposalResult,
    ) = CommandCleanupCoordinator(
        ledger = ledger,
        disposer = CleanupProcessDisposer { record ->
            CleanupDisposalAttempt(disposer(record))
        },
        immediateScheduler = scheduler,
        backstop = backstop,
        launchDirectory = Files.createTempDirectory("cleanup-launch").toFile(),
        recoveryProbe = PidProcessProbe { PidProbeResult.Present(1L) },
        parentProcessId = ::currentProcessId,
        nowEpochMs = { 1_000L },
    )

    private fun currentProcessId(): Int {
        val type = Class.forName("java.lang.ProcessHandle")
        val current = type.getMethod("current").invoke(null)
        return (type.getMethod("pid").invoke(current) as Long).toInt()
    }

    private fun record(name: String, pid: Int, start: Long): CommandCleanupRecord {
        val owner = CommandContinuationOwner.TERMINAL
        val sessionHash = CommandCleanupCoordinator.sessionHash(owner, "session-$name")
        return CommandCleanupRecord(
            recordId = CommandCleanupCoordinator.recordId(owner, sessionHash, "operation-$name", "candidate-$name"),
            owner = owner,
            sessionHash = sessionHash,
            operationHash = CommandCleanupCoordinator.opaqueIdHash("operation", "operation-$name"),
            candidateHash = CommandCleanupCoordinator.opaqueIdHash("candidate", "candidate-$name"),
            attemptHash = null,
            launchTokenHash = null,
            parentProcessId = 0,
            parentStartTimeTicks = 0L,
            processId = pid,
            startTimeTicks = start,
            deadlineEpochMs = 60_000L,
            launchExpiresEpochMs = 30_000L,
            disposalState = CleanupDisposalState.CLEANUP_REQUESTED,
            disposalVersion = 1L,
        )
    }

    private fun terminalKey(session: String, operation: String) = CommandOwnerKey(
        CommandContinuationOwner.TERMINAL,
        session,
        operation,
    )

    private fun agentKey(session: String, operation: String) = CommandOwnerKey(
        CommandContinuationOwner.AGENT_BASH,
        session,
        operation,
    )

    private class FakeLedger(
        private val initialRead: CleanupLedgerRead = CleanupLedgerRead.Success(emptyList()),
    ) : CommandCleanupLedger {
        var records = (initialRead as? CleanupLedgerRead.Success)?.records.orEmpty()
        var failWrites = false
        val writeStates = mutableListOf<CleanupDisposalState>()
        val writeSnapshots = mutableListOf<List<CommandCleanupRecord>>()

        override fun read(): CleanupLedgerRead = when (initialRead) {
            is CleanupLedgerRead.Corrupt -> initialRead
            is CleanupLedgerRead.Success -> CleanupLedgerRead.Success(records)
        }

        override fun write(records: List<CommandCleanupRecord>): Boolean {
            if (failWrites) return false
            this.records = records.toList()
            writeSnapshots.add(this.records)
            records.singleOrNull()?.disposalState?.let(writeStates::add)
            return true
        }
    }

    private class FakeImmediateScheduler : CleanupImmediateScheduler {
        private val actions = ArrayDeque<() -> Unit>()

        override fun schedule(delayMs: Long, action: () -> Unit) {
            actions.addLast(action)
        }

        fun runNext() {
            actions.removeFirst().invoke()
        }
    }

    private class FakeBackstop(
        private val acceptSchedules: Boolean = true,
        private val throwSchedules: Boolean = false,
    ) : CleanupBackstop {
        val scheduledDelays = mutableListOf<Long>()
        var cancelCount = 0

        override fun schedule(minimumLatencyMs: Long): Boolean {
            if (throwSchedules) throw IllegalStateException("injected scheduler failure")
            scheduledDelays.add(minimumLatencyMs)
            return acceptSchedules
        }

        override fun cancel() {
            cancelCount++
        }
    }

    private class FakeOwnedProcess(
        override val identityToken: Any,
    ) : OwnedCommandProcess() {
        override fun disposeProcess(signal: Boolean) = ProcessDisposalResult.DISPOSED
    }
}
