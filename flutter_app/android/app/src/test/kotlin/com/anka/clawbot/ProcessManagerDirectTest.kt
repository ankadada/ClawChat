package com.anka.clawbot

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class ProcessManagerDirectTest {
    @Test
    fun freshDirectEchoStartsRealProotWithoutCoordinator() = withManager { manager, starts ->
        val output = manager.runInProotSync(
            command = "echo ok",
            timeoutSeconds = 30,
            operationId = "echo-operation",
            continuationKey = null,
        )

        assertEquals("ok\n", output)
        assertEquals(1, starts.size)
        assertTrue(starts.single().first().endsWith("/libproot.so"))
        assertFalse(starts.single().contains("/system/bin/sh"))
    }

    @Test
    fun oneHundredDirectCommandsCreateNoDurableLaunches() = withManager { manager, starts ->
        repeat(100) { index ->
            assertEquals(
                "ok\n",
                manager.runInProotSync(
                    command = "echo $index",
                    timeoutSeconds = 30,
                    operationId = "operation-$index",
                ),
            )
        }

        assertEquals(100, starts.size)
        assertTrue(starts.all { it.first().endsWith("/libproot.so") })
        assertTrue(starts.none { it.contains("/system/bin/sh") })
    }

    @Test
    fun corruptLegacyLedgerIsNotConsultedByDirectCommand() {
        val root = Files.createTempDirectory("direct-legacy-ledger").toFile()
        val ledgerReads = AtomicInteger()
        val coordinator = CommandCleanupCoordinator(
            ledger = object : CommandCleanupLedger {
                override fun read(): CleanupLedgerRead {
                    ledgerReads.incrementAndGet()
                    return CleanupLedgerRead.Corrupt("legacy-corrupt")
                }

                override fun write(records: List<CommandCleanupRecord>): Boolean = false
            },
            disposer = CleanupProcessDisposer {
                CleanupDisposalAttempt(ProcessDisposalResult.RETRYABLE_UNKNOWN)
            },
            immediateScheduler = CleanupImmediateScheduler { _, _ -> },
            backstop = object : CleanupBackstop {
                override fun schedule(minimumLatencyMs: Long): Boolean = false
                override fun cancel() = Unit
            },
        )
        val manager = ProcessManager(
            filesDir = root.absolutePath,
            nativeLibDir = File(root, "lib").absolutePath,
            cleanupCoordinator = coordinator,
            processStarter = { CompletedProcess("ok\n") },
        )

        assertEquals("ok\n", manager.runInProotSync("echo ok", operationId = "direct"))
        assertEquals(0, ledgerReads.get())
        root.deleteRecursively()
    }

    @Test
    fun unresolvedLegacyStatesRemainCleanupOnlyForDirectCommands() {
        for (state in listOf(
            CleanupDisposalState.ACTIVE,
            CleanupDisposalState.BACKSTOP_PENDING,
        )) {
            val root = Files.createTempDirectory("direct-legacy-state").toFile()
            val record = CommandCleanupRecord(
                recordId = "legacy-${state.name}",
                owner = CommandContinuationOwner.AGENT_BASH,
                sessionHash = "session-hash",
                operationHash = "operation-hash",
                candidateHash = null,
                attemptHash = "attempt-hash",
                launchTokenHash = "token-hash",
                parentProcessId = 41,
                parentStartTimeTicks = 410L,
                processId = if (state == CleanupDisposalState.ACTIVE) 42 else 0,
                startTimeTicks = if (state == CleanupDisposalState.ACTIVE) 420L else 0L,
                deadlineEpochMs = Long.MAX_VALUE,
                launchExpiresEpochMs = Long.MAX_VALUE,
                disposalState = state,
                disposalVersion = 1L,
            )
            val coordinator = CommandCleanupCoordinator(
                ledger = object : CommandCleanupLedger {
                    override fun read(): CleanupLedgerRead = CleanupLedgerRead.Success(listOf(record))
                    override fun write(records: List<CommandCleanupRecord>): Boolean = true
                },
                disposer = CleanupProcessDisposer {
                    CleanupDisposalAttempt(ProcessDisposalResult.RETRYABLE_UNKNOWN)
                },
                immediateScheduler = CleanupImmediateScheduler { _, _ -> },
                backstop = object : CleanupBackstop {
                    override fun schedule(minimumLatencyMs: Long): Boolean = true
                    override fun cancel() = Unit
                },
                launchDirectory = File(root, "invalid-or-stale-launch-root"),
                recoveryProbe = PidProcessProbe { PidProbeResult.RetryableUnknown },
            )
            coordinator.initialize()
            assertTrue(coordinator.reconcile())
            val manager = ProcessManager(
                filesDir = root.absolutePath,
                nativeLibDir = File(root, "lib").absolutePath,
                cleanupCoordinator = coordinator,
                processStarter = { CompletedProcess("ok\n") },
            )

            assertEquals(
                "ok\n",
                manager.runInProotSync("echo ok", operationId = "direct-${state.name}"),
            )
            assertTrue(coordinator.recordsForTest().isNotEmpty())
            root.deleteRecursively()
        }
    }

    @Test
    fun directCancellationDestroysExactChildOnce() {
        val root = Files.createTempDirectory("direct-cancel").toFile()
        val process = BlockingProcess()
        val manager = ProcessManager(
            filesDir = root.absolutePath,
            nativeLibDir = File(root, "lib").absolutePath,
            cleanupCoordinator = null,
            processStarter = { process },
        )
        val finished = CountDownLatch(1)
        val worker = Thread {
            try {
                manager.runInProotSync("echo ok", 30, operationId = "cancel-me")
            } catch (_: RuntimeException) {
                // A killed direct process reports its non-zero exit.
            } finally {
                finished.countDown()
            }
        }

        worker.start()
        assertTrue(process.waiting.await(5, TimeUnit.SECONDS))
        manager.cancelOperation("cancel-me")
        assertTrue(finished.await(5, TimeUnit.SECONDS))
        assertEquals(1, process.destroyCount.get())
        root.deleteRecursively()
    }

    @Test
    fun directTimeoutDestroysExactChildOnce() {
        val root = Files.createTempDirectory("direct-timeout").toFile()
        val process = TimeoutProcess()
        val manager = ProcessManager(
            filesDir = root.absolutePath,
            nativeLibDir = File(root, "lib").absolutePath,
            cleanupCoordinator = null,
            processStarter = { process },
        )

        assertThrows(RuntimeException::class.java) {
            manager.runInProotSync("echo ok", 1, operationId = "timeout")
        }
        assertEquals(1, process.destroyCount.get())
        root.deleteRecursively()
    }

    private fun withManager(block: (ProcessManager, MutableList<List<String>>) -> Unit) {
        val root = Files.createTempDirectory("direct-proot").toFile()
        val starts = mutableListOf<List<String>>()
        val manager = ProcessManager(
            filesDir = root.absolutePath,
            nativeLibDir = File(root, "lib").absolutePath,
            cleanupCoordinator = null,
            processStarter = { builder ->
                starts += builder.command().toList()
                CompletedProcess("ok\n")
            },
        )
        try {
            block(manager, starts)
        } finally {
            root.deleteRecursively()
        }
    }

    private open class CompletedProcess(output: String) : Process() {
        private val input = ByteArrayInputStream(output.toByteArray())
        private val error = ByteArrayInputStream(ByteArray(0))
        private val sink = ByteArrayOutputStream()
        protected var alive = false

        override fun getOutputStream(): OutputStream = sink
        override fun getInputStream(): InputStream = input
        override fun getErrorStream(): InputStream = error
        override fun waitFor(): Int = 0
        override fun waitFor(timeout: Long, unit: TimeUnit): Boolean = true
        override fun exitValue(): Int = if (alive) throw IllegalThreadStateException() else 0
        override fun destroy() {
            alive = false
        }
        override fun destroyForcibly(): Process {
            destroy()
            return this
        }
        override fun isAlive(): Boolean = alive
    }

    private class BlockingProcess : CompletedProcess("") {
        val waiting = CountDownLatch(1)
        val destroyCount = AtomicInteger()
        private val released = CountDownLatch(1)

        init {
            alive = true
        }

        override fun waitFor(timeout: Long, unit: TimeUnit): Boolean {
            waiting.countDown()
            released.await(timeout, unit)
            return !alive
        }

        override fun exitValue(): Int = if (alive) throw IllegalThreadStateException() else 143

        override fun destroyForcibly(): Process {
            destroyCount.incrementAndGet()
            alive = false
            released.countDown()
            return this
        }
    }

    private class TimeoutProcess : CompletedProcess("") {
        val destroyCount = AtomicInteger()

        init {
            alive = true
        }

        override fun waitFor(timeout: Long, unit: TimeUnit): Boolean = false

        override fun destroyForcibly(): Process {
            destroyCount.incrementAndGet()
            alive = false
            return this
        }
    }
}
