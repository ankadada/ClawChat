package com.anka.clawbot

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CommandContinuationRegistryTest {
    @Test
    fun cancelBeforeReserveCreatesExactTombstoneAndRejectsLateStart() {
        val registry = CommandContinuationRegistry(nowEpochMs = { 1_000L })
        val key = agentKey("session", "cancel-before-reserve")
        assertEquals(CommandRetireOutcome.RETIRED, registry.cancel(key).outcome)
        assertEquals(CommandReserveOutcome.RETIRED, registry.reserve(key, 60_000L))
        assertEquals(0, registry.activeCount())
    }

    @Test
    fun cancelDuringReadinessAndAfterReadyLeaveNoLiveProcess() {
        val registry = CommandContinuationRegistry(nowEpochMs = { 1_000L })
        val during = agentKey("session", "during-readiness")
        assertEquals(CommandReserveOutcome.NEW, registry.reserve(during, 60_000L))
        assertEquals(CommandRetireOutcome.RETIRED, registry.cancel(during).outcome)

        val after = agentKey("session", "after-ready")
        val process = FakeOwnedProcess()
        assertEquals(CommandReserveOutcome.NEW, registry.reserve(after, 60_000L))
        assertEquals(CandidateReceipt.NATIVE_OWNS, registry.attachAgent(after, process))
        assertEquals(CommandRetireOutcome.RETIRED, registry.cancel(after).outcome)
        assertEquals(1, process.killCount.get())
        assertEquals(0, registry.activeCount())
    }

    @Test
    fun failedDurableSignalIntentNeverSignalsTerminalOrAgentProcess() {
        val registry = CommandContinuationRegistry(nowEpochMs = { 1_000L })
        val terminal = terminalKey("terminal", "intent-terminal")
        val terminalProcess = FakeOwnedProcess("terminal-pid")
        assertEquals(
            CommandReserveOutcome.NEW,
            registry.reserveTerminal(terminal, "candidate", 60_000L),
        )
        assertEquals(
            CandidateReceipt.NATIVE_OWNS,
            registry.attachTerminal(terminal, "candidate", terminalProcess),
        )
        assertEquals(
            CandidateReceipt.UNKNOWN,
            registry.cancelTerminal(terminal, "candidate", beforeSignal = { false }),
        )
        assertEquals(0, terminalProcess.killCount.get())
        assertEquals(
            CandidateReceipt.NATIVE_DISPOSED,
            registry.cancelTerminal(terminal, "candidate", beforeSignal = { true }),
        )
        assertEquals(1, terminalProcess.killCount.get())

        val agent = agentKey("agent", "intent-agent")
        val agentProcess = FakeOwnedProcess("agent-process")
        assertEquals(CommandReserveOutcome.NEW, registry.reserve(agent, 60_000L))
        assertEquals(CandidateReceipt.NATIVE_OWNS, registry.attachAgent(agent, agentProcess))
        assertEquals(
            CommandRetireOutcome.RETRYABLE_UNKNOWN,
            registry.cancel(agent, beforeSignal = { false }).outcome,
        )
        assertEquals(0, agentProcess.killCount.get())
        assertEquals(
            CommandRetireOutcome.RETIRED,
            registry.cancel(agent, beforeSignal = { true }).outcome,
        )
        assertEquals(1, agentProcess.killCount.get())

        val bulk = agentKey("agent-bulk", "intent-bulk")
        val bulkProcess = FakeOwnedProcess("bulk-process")
        assertEquals(CommandReserveOutcome.NEW, registry.reserve(bulk, 60_000L))
        assertEquals(CandidateReceipt.NATIVE_OWNS, registry.attachAgent(bulk, bulkProcess))
        assertTrue(
            registry.cancelSession(
                CommandContinuationOwner.AGENT_BASH,
                bulk.sessionId,
                beforeSignal = { _, _ -> false },
            ).isEmpty(),
        )
        assertEquals(0, bulkProcess.killCount.get())
        assertTrue(registry.isActive(bulk))
        assertEquals(
            listOf(bulk),
            registry.cancelSession(
                CommandContinuationOwner.AGENT_BASH,
                bulk.sessionId,
                beforeSignal = { _, _ -> true },
            ),
        )
        assertEquals(1, bulkProcess.killCount.get())
    }

    @Test
    fun duplicateExactDispatchStartsOneProcessAndCommitsOnce() {
        val registry = CommandContinuationRegistry(nowEpochMs = { 1_000L })
        val key = agentKey("chat-session", "duplicate-dispatch")
        val callbacks = AtomicInteger()
        val commits = AtomicInteger()
        val factoryCalls = AtomicInteger()
        fun dispatch() {
            if (registry.reserve(key, 60_000L) != CommandReserveOutcome.NEW) return
            factoryCalls.incrementAndGet()
            val process = FakeOwnedProcess()
            if (registry.attachAgent(key, process) == CandidateReceipt.NATIVE_OWNS) {
                callbacks.incrementAndGet()
                if (registry.finish(key).outcome == CommandRetireOutcome.RETIRED) commits.incrementAndGet()
            }
        }
        dispatch()
        dispatch()
        assertEquals(1, factoryCalls.get())
        assertEquals(1, callbacks.get())
        assertEquals(1, commits.get())
    }

    @Test
    fun wrongSessionCancelCannotKillLiveExactProcess() {
        val registry = CommandContinuationRegistry(nowEpochMs = { 1_000L })
        val key = agentKey("right", "operation")
        val process = FakeOwnedProcess()
        assertEquals(CommandReserveOutcome.NEW, registry.reserve(key, 60_000L))
        assertEquals(CandidateReceipt.NATIVE_OWNS, registry.attachAgent(key, process))
        assertEquals(CommandRetireOutcome.CONFLICT, registry.cancel(agentKey("wrong", "operation")).outcome)
        assertEquals(0, process.killCount.get())
        assertTrue(registry.isActive(key))
    }

    @Test
    fun nativeSessionStopWithoutDartKillsOnceAndDuplicateStopIsNoOp() {
        val registry = CommandContinuationRegistry(nowEpochMs = { 1_000L })
        val key = agentKey("session", "agent-stop")
        val process = FakeOwnedProcess()
        assertEquals(CommandReserveOutcome.NEW, registry.reserve(key, 60_000L))
        assertEquals(CandidateReceipt.NATIVE_OWNS, registry.attachAgent(key, process))
        assertEquals(listOf(key), registry.cancelSession(CommandContinuationOwner.AGENT_BASH, "session"))
        assertTrue(registry.cancelSession(CommandContinuationOwner.AGENT_BASH, "session").isEmpty())
        assertEquals(1, process.killCount.get())
    }

    @Test
    fun terminalExactStopWithoutDartPersistsDisposedReceiptAndKillsPidOnce() {
        val registry = CommandContinuationRegistry(nowEpochMs = { 1_000L })
        val key = terminalKey("interactive-terminal", "terminal-stop")
        val candidateId = "candidate-stop"
        val process = FakeOwnedProcess("pid-stop")
        assertEquals(CommandReserveOutcome.NEW, registry.reserveTerminal(key, candidateId, 60_000L))
        assertEquals(CandidateReceipt.NATIVE_OWNS, registry.attachTerminal(key, candidateId, process))
        assertEquals(CandidateReceipt.NATIVE_DISPOSED, registry.cancelTerminal(key, candidateId))
        assertEquals(CandidateReceipt.NATIVE_DISPOSED, registry.cancelTerminal(key, candidateId))
        assertEquals(
            CandidateReceipt.NATIVE_DISPOSED,
            registry.terminalReceipt(key, candidateId, "reused-pid-data"),
        )
        assertEquals(1, process.killCount.get())
    }

    @Test
    fun boundedTimeoutPersistsDisposedReceiptBeforeKillingRunningCandidate() {
        var now = 1_000L
        val registry = CommandContinuationRegistry(nowEpochMs = { now })
        val key = terminalKey("terminal", "timeout")
        val candidateId = "candidate-timeout"
        val process = FakeOwnedProcess("pid-timeout")
        assertEquals(CommandReserveOutcome.NEW, registry.reserveTerminal(key, candidateId, 10L))
        assertEquals(CandidateReceipt.NATIVE_OWNS, registry.attachTerminal(key, candidateId, process))
        now = 1_011L
        assertEquals(listOf(key), registry.expire(CommandContinuationOwner.TERMINAL))
        assertEquals(CandidateReceipt.NATIVE_DISPOSED, registry.terminalReceipt(key, candidateId, "other"))
        assertEquals(1, process.killCount.get())
    }

    @Test
    fun terminalAttachAfterConcurrentExpiryReplaysCallerOwnership() {
        var now = 1_000L
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val registry = CommandContinuationRegistry(
            nowEpochMs = { now },
            beforeAttachLock = {
                entered.countDown()
                assertTrue(release.await(5, TimeUnit.SECONDS))
            },
        )
        val key = terminalKey("terminal", "attach-expiry")
        val candidateId = "candidate-expiry"
        val process = FakeOwnedProcess("pid-expiry")
        assertEquals(CommandReserveOutcome.NEW, registry.reserveTerminal(key, candidateId, 10L))
        val receipt = arrayOfNulls<CandidateReceipt>(1)
        val thread = Thread { receipt[0] = registry.attachTerminal(key, candidateId, process) }
        thread.start()
        assertTrue(entered.await(5, TimeUnit.SECONDS))
        now = 1_011L
        registry.expire(CommandContinuationOwner.TERMINAL)
        release.countDown()
        thread.join(5_000L)
        assertEquals(CandidateReceipt.CALLER_OWNS, receipt[0])
        assertEquals(0, process.killCount.get())
        process.dispose()
        assertEquals(1, process.killCount.get())
    }

    @Test
    fun agentAttachAfterConcurrentDestroyKillsSuppliedProcessOnce() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val registry = CommandContinuationRegistry(
            beforeAttachLock = {
                entered.countDown()
                assertTrue(release.await(5, TimeUnit.SECONDS))
            },
        )
        val key = agentKey("session", "attach-destroy")
        val process = FakeOwnedProcess()
        assertEquals(CommandReserveOutcome.NEW, registry.reserve(key, 60_000L))
        val receipt = arrayOfNulls<CandidateReceipt>(1)
        val thread = Thread { receipt[0] = registry.attachAgent(key, process) }
        thread.start()
        assertTrue(entered.await(5, TimeUnit.SECONDS))
        registry.destroyOwner(CommandContinuationOwner.AGENT_BASH)
        release.countDown()
        thread.join(5_000L)
        assertEquals(CandidateReceipt.NATIVE_DISPOSED, receipt[0])
        assertEquals(1, process.killCount.get())
    }

    @Test
    fun freshEngineAtomicallyReplacesOldTerminalPidBeforeNewReservation() {
        val registry = CommandContinuationRegistry(nowEpochMs = { 1_000L })
        val oldKey = terminalKey("interactive-terminal", "old")
        val oldCandidate = "candidate-old"
        val oldProcess = FakeOwnedProcess("pid-old")
        assertEquals(CommandReserveOutcome.NEW, registry.reserveTerminal(oldKey, oldCandidate, 60_000L))
        assertEquals(CandidateReceipt.NATIVE_OWNS, registry.attachTerminal(oldKey, oldCandidate, oldProcess))
        val newKey = terminalKey("interactive-terminal", "new")
        val replacement = registry.replaceTerminalSession(newKey, "candidate-new", 60_000L)
        assertEquals(CommandReserveOutcome.NEW, replacement.outcome)
        assertEquals(listOf(TerminalCandidateKey(oldKey, oldCandidate)), replacement.retiredCandidates)
        assertEquals(1, oldProcess.killCount.get())
        assertEquals(CandidateReceipt.NATIVE_DISPOSED, registry.terminalReceipt(oldKey, oldCandidate, "pid-reused"))
        assertTrue(registry.isActiveCandidate(newKey, "candidate-new"))
    }

    @Test
    fun concurrentFreshEnginesLeaveOneTerminalCandidateAndSupersededReceipt() {
        val registry = CommandContinuationRegistry(nowEpochMs = { 1_000L })
        val ready = CountDownLatch(2)
        val go = CountDownLatch(1)
        val keys = listOf(
            terminalKey("interactive-terminal", "engine-one") to "candidate-one",
            terminalKey("interactive-terminal", "engine-two") to "candidate-two",
        )
        val threads = keys.map { (key, candidate) ->
            Thread {
                ready.countDown()
                assertTrue(go.await(5, TimeUnit.SECONDS))
                registry.replaceTerminalSession(key, candidate, 60_000L)
            }.apply { start() }
        }
        assertTrue(ready.await(5, TimeUnit.SECONDS))
        go.countDown()
        threads.forEach { it.join(5_000L) }
        assertEquals(1, registry.activeCount(CommandContinuationOwner.TERMINAL))
        val current = registry.activeCandidateForSession("interactive-terminal")!!
        val superseded = keys.map { TerminalCandidateKey(it.first, it.second) }.first { it != current }
        assertEquals(
            CandidateReceipt.CALLER_OWNS,
            registry.terminalReceipt(superseded.ownerKey, superseded.candidateId, "unused-pid"),
        )
    }

    @Test
    fun acceptedAttachReplyLostThenCancelReplaysNativeDisposedWithoutPidAuthority() {
        val registry = CommandContinuationRegistry(nowEpochMs = { 1_000L })
        val key = terminalKey("interactive-terminal", "lost-reply")
        val candidateId = "candidate-lost-reply"
        val process = FakeOwnedProcess("pid-accepted")
        assertEquals(CommandReserveOutcome.NEW, registry.reserveTerminal(key, candidateId, 60_000L))
        assertEquals(CandidateReceipt.NATIVE_OWNS, registry.attachTerminal(key, candidateId, process))
        assertEquals(CandidateReceipt.NATIVE_DISPOSED, registry.cancelTerminal(key, candidateId))
        assertEquals(
            CandidateReceipt.NATIVE_DISPOSED,
            registry.attachTerminal(key, candidateId, FakeOwnedProcess("reused-numeric-pid")),
        )
        assertEquals(1, process.killCount.get())
    }

    @Test
    fun disposeConflictNeverClaimsNativeDisposedOrKillsExistingOwner() {
        val registry = CommandContinuationRegistry(nowEpochMs = { 1_000L })
        val key = terminalKey("interactive-terminal", "dispose-conflict")
        val process = FakeOwnedProcess("owned-pid")
        assertEquals(CommandReserveOutcome.NEW, registry.reserveTerminal(key, "candidate-a", 60_000L))
        assertEquals(CandidateReceipt.NATIVE_OWNS, registry.attachTerminal(key, "candidate-a", process))
        assertEquals(
            CandidateReceipt.CONFLICT,
            registry.disposeTerminalCandidate(key, "candidate-b", FakeOwnedProcess("other-pid")),
        )
        assertEquals(0, process.killCount.get())
        assertTrue(registry.isActiveCandidate(key, "candidate-a"))
    }

    @Test
    fun sameOperationSameCandidateReplaysButDifferentCandidatePidAndSessionConflict() {
        val registry = CommandContinuationRegistry(nowEpochMs = { 1_000L })
        val key = terminalKey("right-session", "same-operation")
        val process = FakeOwnedProcess("pid-one")
        assertEquals(CommandReserveOutcome.NEW, registry.reserveTerminal(key, "candidate-one", 60_000L))
        assertEquals(CommandReserveOutcome.ALREADY_ACTIVE, registry.reserveTerminal(key, "candidate-one", 60_000L))
        assertEquals(CommandReserveOutcome.CONFLICT, registry.reserveTerminal(key, "candidate-two", 60_000L))
        assertEquals(CandidateReceipt.NATIVE_OWNS, registry.attachTerminal(key, "candidate-one", process))
        assertEquals(CandidateReceipt.NATIVE_OWNS, registry.attachTerminal(key, "candidate-one", FakeOwnedProcess("pid-one")))
        assertEquals(CandidateReceipt.CONFLICT, registry.attachTerminal(key, "candidate-one", FakeOwnedProcess("pid-two")))
        assertEquals(CandidateReceipt.CONFLICT, registry.terminalReceipt(key, "candidate-two", "pid-one"))
        assertEquals(
            CandidateReceipt.CONFLICT,
            registry.terminalReceipt(terminalKey("wrong-session", "same-operation"), "candidate-one", "pid-one"),
        )
        assertEquals(0, process.killCount.get())
    }

    @Test
    fun concurrentAttachQueryDisposeAndRetireConvergeToOneDurableReceipt() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val registry = CommandContinuationRegistry(
            nowEpochMs = { 1_000L },
            beforeAttachLock = {
                entered.countDown()
                assertTrue(release.await(5, TimeUnit.SECONDS))
            },
        )
        val key = terminalKey("terminal", "barrier")
        val candidate = "candidate-barrier"
        val process = FakeOwnedProcess("pid-barrier")
        assertEquals(CommandReserveOutcome.NEW, registry.reserveTerminal(key, candidate, 60_000L))
        val attachReceipt = arrayOfNulls<CandidateReceipt>(1)
        val thread = Thread { attachReceipt[0] = registry.attachTerminal(key, candidate, process) }
        thread.start()
        assertTrue(entered.await(5, TimeUnit.SECONDS))
        assertEquals(CandidateReceipt.CALLER_OWNS, registry.cancelTerminal(key, candidate))
        assertEquals(CandidateReceipt.CALLER_OWNS, registry.terminalReceipt(key, candidate, "pid-barrier"))
        assertEquals(
            CandidateReceipt.CALLER_OWNS,
            registry.disposeTerminalCandidate(key, candidate, FakeOwnedProcess("pid-barrier")),
        )
        release.countDown()
        thread.join(5_000L)
        assertEquals(CandidateReceipt.CALLER_OWNS, attachReceipt[0])
        assertEquals(0, process.killCount.get())
    }

    @Test
    fun acknowledgedReceiptsRemainBoundedNoAuthorityTombstones() {
        var now = 1_000L
        val registry = CommandContinuationRegistry(
            nowEpochMs = { now },
            receiptGraceMs = 10L,
            receiptCapacity = 2,
            retiredCapacity = 2,
        )
        val retiredCandidates = (0..1).map { index ->
            val key = terminalKey("session-$index", "operation-$index")
            assertEquals(CommandReserveOutcome.NEW, registry.reserveTerminal(key, "candidate-$index", 5L))
            assertEquals(CandidateReceipt.CALLER_OWNS, registry.cancelTerminal(key, "candidate-$index"))
            TerminalCandidateKey(key, "candidate-$index")
        }
        val overflow = terminalKey("active-session", "active-operation")
        assertEquals(
            CommandReserveOutcome.CONFLICT,
            registry.reserveTerminal(overflow, "active-candidate", 1_000L),
        )
        val acknowledged = retiredCandidates.first()
        assertEquals(
            CandidateReceipt.CALLER_OWNS,
            registry.acknowledgeFinalReceipt(
                acknowledged.ownerKey,
                acknowledged.candidateId,
                CandidateReceipt.CALLER_OWNS,
            ),
        )
        now = 1_016L
        assertEquals(2, registry.receiptCountForTest())
        assertEquals(
            CandidateReceipt.ACKNOWLEDGED,
            registry.cancelTerminal(acknowledged.ownerKey, acknowledged.candidateId),
        )
        assertEquals(
            CandidateReceipt.CALLER_OWNS,
            registry.acknowledgeFinalReceipt(
                acknowledged.ownerKey,
                acknowledged.candidateId,
                CandidateReceipt.CALLER_OWNS,
            ),
        )
        assertEquals(CommandReserveOutcome.CONFLICT, registry.reserveTerminal(overflow, "active-candidate", 1_000L))
        assertEquals(CommandReserveOutcome.ACKNOWLEDGED, registry.reserveTerminal(
            acknowledged.ownerKey,
            acknowledged.candidateId,
            1_000L,
        ))
        assertEquals(0, registry.retiredCountForTest())
    }

    @Test
    fun unreconciledReceiptIsSoleAuthorityWithoutTerminalTombstone() {
        val registry = CommandContinuationRegistry(
            nowEpochMs = { 1_000L },
            receiptCapacity = 2,
            retiredCapacity = 1,
        )
        val first = terminalKey("first-session", "first-operation")
        val second = terminalKey("second-session", "second-operation")
        assertEquals(CommandReserveOutcome.NEW, registry.reserveTerminal(first, "first-candidate", 60_000L))
        assertEquals(CandidateReceipt.CALLER_OWNS, registry.cancelTerminal(first, "first-candidate"))
        assertEquals(CommandReserveOutcome.NEW, registry.reserveTerminal(second, "second-candidate", 60_000L))
        assertEquals(CandidateReceipt.CALLER_OWNS, registry.cancelTerminal(second, "second-candidate"))
        assertEquals(0, registry.retiredCountForTest())
        assertEquals(CommandReserveOutcome.RETIRED, registry.reserveTerminal(first, "first-candidate", 60_000L))
        assertEquals(CommandReserveOutcome.CONFLICT, registry.reserveTerminal(first, "different-candidate", 60_000L))
    }

    @Test
    fun unacknowledgedNativeDisposedSurvivesDeadlineAndGraceForEveryRetirementPath() {
        for (path in RetirementPath.entries) {
            var now = 1_000L
            val registry = CommandContinuationRegistry(
                nowEpochMs = { now },
                receiptGraceMs = 5 * 60 * 1000L,
            )
            val key = terminalKey("session-${path.name}", "operation-${path.name}")
            val candidate = "candidate-${path.name}"
            val process = FakeOwnedProcess("pid-${path.name}")
            assertEquals(CommandReserveOutcome.NEW, registry.reserveTerminal(key, candidate, 10L))
            assertEquals(CandidateReceipt.NATIVE_OWNS, registry.attachTerminal(key, candidate, process))

            when (path) {
                RetirementPath.CANCEL -> assertEquals(
                    CandidateReceipt.NATIVE_DISPOSED,
                    registry.cancelTerminal(key, candidate),
                )
                RetirementPath.EXPIRY -> {
                    now = 1_011L
                    assertEquals(listOf(key), registry.expire(CommandContinuationOwner.TERMINAL))
                }
                RetirementPath.REPLACEMENT -> assertEquals(
                    CommandReserveOutcome.NEW,
                    registry.replaceTerminalSession(
                        terminalKey(key.sessionId, "replacement-${path.name}"),
                        "replacement-candidate-${path.name}",
                        60_000L,
                    ).outcome,
                )
                RetirementPath.DESTROY -> assertEquals(listOf(key), registry.destroyOwner(key.owner))
                RetirementPath.FINISH -> assertEquals(
                    CandidateReceipt.NATIVE_DISPOSED,
                    registry.finishTerminal(key, candidate),
                )
            }

            now = 10L + 5 * 60 * 1000L + 35 * 60 * 1000L
            assertEquals(
                "unobserved final receipt was pruned for $path",
                CandidateReceipt.NATIVE_DISPOSED,
                registry.terminalReceipt(key, candidate, "reused-pid"),
            )
            assertEquals(
                if (path == RetirementPath.FINISH) 0 else 1,
                process.killCount.get(),
            )
        }
    }

    @Test
    fun nativeDisposedAckRevokesEveryOrdinaryDisposalPathAndReplaysExactAck() {
        var now = 1_000L
        val registry = CommandContinuationRegistry(
            nowEpochMs = { now },
            receiptGraceMs = 10L,
        )
        val key = terminalKey("ack-session", "ack-operation")
        val candidate = "ack-candidate"
        val process = FakeOwnedProcess("ack-pid")
        assertEquals(CommandReserveOutcome.NEW, registry.reserveTerminal(key, candidate, 5L))
        assertEquals(CandidateReceipt.NATIVE_OWNS, registry.attachTerminal(key, candidate, process))
        assertEquals(CandidateReceipt.NATIVE_DISPOSED, registry.cancelTerminal(key, candidate))

        assertEquals(
            CandidateReceipt.CONFLICT,
            registry.acknowledgeFinalReceipt(key, candidate, CandidateReceipt.CALLER_OWNS),
        )
        assertEquals(
            CandidateReceipt.CONFLICT,
            registry.acknowledgeFinalReceipt(
                terminalKey("wrong-session", key.operationId),
                candidate,
                CandidateReceipt.NATIVE_DISPOSED,
            ),
        )
        assertEquals(
            CandidateReceipt.CONFLICT,
            registry.acknowledgeFinalReceipt(key, "wrong-candidate", CandidateReceipt.NATIVE_DISPOSED),
        )
        assertEquals(CandidateReceipt.NATIVE_DISPOSED, registry.terminalReceipt(key, candidate, "other"))

        assertEquals(
            CandidateReceipt.NATIVE_DISPOSED,
            registry.acknowledgeFinalReceipt(key, candidate, CandidateReceipt.NATIVE_DISPOSED),
        )
        assertEquals(
            CandidateReceipt.NATIVE_DISPOSED,
            registry.acknowledgeFinalReceipt(key, candidate, CandidateReceipt.NATIVE_DISPOSED),
        )
        now = 1_016L
        assertEquals(CandidateReceipt.ACKNOWLEDGED, registry.terminalReceipt(key, candidate, "reused-pid"))
        assertEquals(CandidateReceipt.ACKNOWLEDGED, registry.cancelTerminal(key, candidate))
        assertEquals(CandidateReceipt.ACKNOWLEDGED, registry.finishTerminal(key, candidate))
        assertEquals(
            CandidateReceipt.ACKNOWLEDGED,
            registry.attachTerminal(key, candidate, FakeOwnedProcess("reused-pid")),
        )
        val stale = FakeOwnedProcess("reused-pid")
        assertEquals(CandidateReceipt.ACKNOWLEDGED, registry.disposeTerminalCandidate(key, candidate, stale))
        assertEquals(0, stale.killCount.get())
        assertEquals(
            CommandReserveOutcome.ACKNOWLEDGED,
            registry.replaceTerminalSession(key, candidate, 60_000L).outcome,
        )
        assertEquals(
            CandidateReceipt.NATIVE_DISPOSED,
            registry.acknowledgeFinalReceipt(key, candidate, CandidateReceipt.NATIVE_DISPOSED),
        )
        assertEquals(1, registry.receiptCountForTest())
        assertEquals(1, process.killCount.get())
    }

    @Test
    fun callerOwnsAckFollowsOneCallerKillWithNoLaterDisposalAuthority() {
        val registry = CommandContinuationRegistry(nowEpochMs = { 1_000L })
        val key = terminalKey("caller-ack-session", "caller-ack-operation")
        val candidate = "caller-ack-candidate"
        assertEquals(CommandReserveOutcome.NEW, registry.reserveTerminal(key, candidate, 60_000L))
        assertEquals(CandidateReceipt.CALLER_OWNS, registry.cancelTerminal(key, candidate))
        val callerKillCount = AtomicInteger()
        callerKillCount.incrementAndGet()
        assertEquals(
            CandidateReceipt.CALLER_OWNS,
            registry.acknowledgeFinalReceipt(key, candidate, CandidateReceipt.CALLER_OWNS),
        )
        assertEquals(1, callerKillCount.get())
        assertEquals(CandidateReceipt.ACKNOWLEDGED, registry.cancelTerminal(key, candidate))
        assertEquals(CandidateReceipt.ACKNOWLEDGED, registry.terminalReceipt(key, candidate, "pid"))
        assertEquals(CandidateReceipt.CALLER_OWNS, registry.acknowledgeFinalReceipt(
            key,
            candidate,
            CandidateReceipt.CALLER_OWNS,
        ))
        assertEquals(1, callerKillCount.get())
    }

    @Test
    fun concurrentAckSerializesBeforeStaleCancelAndQuery() {
        val acknowledgedUnderLock = CountDownLatch(1)
        val releaseAck = CountDownLatch(1)
        val registry = CommandContinuationRegistry(
            nowEpochMs = { 1_000L },
            afterAcknowledgeLocked = {
                acknowledgedUnderLock.countDown()
                assertTrue(releaseAck.await(5, TimeUnit.SECONDS))
            },
        )
        val key = terminalKey("ack-barrier-session", "ack-barrier-operation")
        val candidate = "ack-barrier-candidate"
        assertEquals(CommandReserveOutcome.NEW, registry.reserveTerminal(key, candidate, 60_000L))
        assertEquals(CandidateReceipt.CALLER_OWNS, registry.cancelTerminal(key, candidate))
        val ackResult = arrayOfNulls<CandidateReceipt>(1)
        val cancelResult = arrayOfNulls<CandidateReceipt>(1)
        val queryResult = arrayOfNulls<CandidateReceipt>(1)
        val ackThread = Thread {
            ackResult[0] = registry.acknowledgeFinalReceipt(
                key,
                candidate,
                CandidateReceipt.CALLER_OWNS,
            )
        }.apply { start() }
        assertTrue(acknowledgedUnderLock.await(5, TimeUnit.SECONDS))
        val cancelThread = Thread { cancelResult[0] = registry.cancelTerminal(key, candidate) }.apply { start() }
        val queryThread = Thread {
            queryResult[0] = registry.terminalReceipt(key, candidate, "pid")
        }.apply { start() }
        releaseAck.countDown()
        listOf(ackThread, cancelThread, queryThread).forEach { it.join(5_000L) }
        assertEquals(CandidateReceipt.CALLER_OWNS, ackResult[0])
        assertEquals(CandidateReceipt.ACKNOWLEDGED, cancelResult[0])
        assertEquals(CandidateReceipt.ACKNOWLEDGED, queryResult[0])
    }

    @Test
    fun defaultCapacityFailsClosedForUnacknowledgedAndAcknowledgedReceipts() {
        var now = 1_000L
        val registry = CommandContinuationRegistry(nowEpochMs = { now })
        val candidates = (0 until 512).map { index ->
            val key = terminalKey("capacity-session-$index", "capacity-operation-$index")
            val candidate = "capacity-candidate-$index"
            assertEquals(CommandReserveOutcome.NEW, registry.reserveTerminal(key, candidate, 10L))
            assertEquals(CandidateReceipt.CALLER_OWNS, registry.cancelTerminal(key, candidate))
            TerminalCandidateKey(key, candidate)
        }
        now += 35 * 60 * 1000L
        val overflow = terminalKey("capacity-overflow", "capacity-overflow")
        assertEquals(
            CommandReserveOutcome.CONFLICT,
            registry.reserveTerminal(overflow, "capacity-overflow", 10L),
        )
        assertEquals(512, registry.receiptCountForTest())

        val acknowledged = candidates.first()
        assertEquals(
            CandidateReceipt.CALLER_OWNS,
            registry.acknowledgeFinalReceipt(
                acknowledged.ownerKey,
                acknowledged.candidateId,
                CandidateReceipt.CALLER_OWNS,
            ),
        )
        assertEquals(
            CommandReserveOutcome.CONFLICT,
            registry.reserveTerminal(overflow, "capacity-overflow", 10L),
        )
        assertEquals(512, registry.receiptCountForTest())
        assertFalse(registry.isActiveCandidate(overflow, "capacity-overflow"))
    }

    @Test
    fun pidDisposalDistinguishesGoneReuseTransientFailureAndLaterSuccess() {
        val unavailable = PlannedPidProbe(PidProbeResult.RetryableUnknown)
        assertEquals(null, PidOwnedCommandProcess.create(42, unavailable, CountingSignaler()))

        val missingProbe = PlannedPidProbe(PidProbeResult.Present(10L), PidProbeResult.Missing)
        val missingSignaler = CountingSignaler()
        val missing = requireNotNull(PidOwnedCommandProcess.create(42, missingProbe, missingSignaler))
        assertEquals(ProcessDisposalResult.VERIFIED_GONE_OR_REUSED, missing.dispose())
        assertEquals(0, missingSignaler.count.get())

        val reusedProbe = PlannedPidProbe(PidProbeResult.Present(10L), PidProbeResult.Present(11L))
        val reusedSignaler = CountingSignaler()
        val reused = requireNotNull(PidOwnedCommandProcess.create(42, reusedProbe, reusedSignaler))
        assertEquals(ProcessDisposalResult.VERIFIED_GONE_OR_REUSED, reused.dispose())
        assertEquals(0, reusedSignaler.count.get())

        val rereadUnavailable = PlannedPidProbe(
            PidProbeResult.Present(10L),
            PidProbeResult.Present(10L),
            PidProbeResult.RetryableUnknown,
        )
        val rereadSignaler = CountingSignaler()
        val reread = requireNotNull(PidOwnedCommandProcess.create(42, rereadUnavailable, rereadSignaler))
        assertEquals(ProcessDisposalResult.RETRYABLE_UNKNOWN, reread.dispose())
        assertEquals(1, rereadSignaler.count.get())

        val signalFailureProbe = PlannedPidProbe(
            PidProbeResult.Present(10L),
            PidProbeResult.Present(10L),
        )
        val signalFailure = CountingSignaler(fail = true)
        val failed = requireNotNull(PidOwnedCommandProcess.create(42, signalFailureProbe, signalFailure))
        assertEquals(ProcessDisposalResult.RETRYABLE_UNKNOWN, failed.dispose())
        assertEquals(1, signalFailure.count.get())

        val retryProbe = PlannedPidProbe(
            PidProbeResult.Present(10L),
            PidProbeResult.Present(10L),
            PidProbeResult.Present(10L),
            PidProbeResult.Missing,
        )
        val retrySignaler = CountingSignaler()
        val retry = requireNotNull(PidOwnedCommandProcess.create(42, retryProbe, retrySignaler))
        assertEquals(ProcessDisposalResult.RETRYABLE_UNKNOWN, retry.dispose())
        assertEquals(ProcessDisposalResult.VERIFIED_GONE_OR_REUSED, retry.dispose())
        assertEquals(1, retrySignaler.count.get())

        val exitedProbe = PlannedPidProbe(PidProbeResult.Present(10L), PidProbeResult.Missing)
        val exitedSignaler = CountingSignaler()
        val exited = requireNotNull(PidOwnedCommandProcess.create(42, exitedProbe, exitedSignaler))
        assertEquals(ProcessDisposalResult.VERIFIED_GONE_OR_REUSED, exited.dispose(signal = false))
        assertEquals(0, exitedSignaler.count.get())
    }

    @Test
    fun javaProcessDisposalRequiresVerifiedExitAndRetriesUnknown() {
        val alreadyExited = FakeJavaProcess(alive = false)
        assertEquals(
            ProcessDisposalResult.VERIFIED_GONE_OR_REUSED,
            JavaOwnedCommandProcess(alreadyExited).dispose(),
        )
        assertEquals(0, alreadyExited.destroyCount.get())

        val throwsOnDestroy = FakeJavaProcess(alive = true, destroyThrows = true)
        assertEquals(
            ProcessDisposalResult.RETRYABLE_UNKNOWN,
            JavaOwnedCommandProcess(throwsOnDestroy).dispose(),
        )
        assertEquals(1, throwsOnDestroy.destroyCount.get())

        val stillAlive = FakeJavaProcess(alive = true, exitsWhenDestroyed = false)
        val ownedStillAlive = JavaOwnedCommandProcess(stillAlive)
        assertEquals(ProcessDisposalResult.RETRYABLE_UNKNOWN, ownedStillAlive.dispose())
        assertEquals(ProcessDisposalResult.RETRYABLE_UNKNOWN, ownedStillAlive.dispose())
        assertEquals(1, stillAlive.destroyCount.get())
        stillAlive.alive = false
        assertEquals(ProcessDisposalResult.VERIFIED_GONE_OR_REUSED, ownedStillAlive.dispose())
        assertEquals(1, stillAlive.destroyCount.get())

        val exits = FakeJavaProcess(alive = true, exitsWhenDestroyed = true)
        val ownedExits = JavaOwnedCommandProcess(exits)
        assertEquals(ProcessDisposalResult.DISPOSED, ownedExits.dispose())
        assertEquals(ProcessDisposalResult.DISPOSED, ownedExits.dispose())
        assertEquals(1, exits.destroyCount.get())
    }

    @Test
    fun retryableUnknownKeepsExactOwnershipUntilEveryRetirementCallerConverges() {
        for (path in listOf(
            RetirementPath.CANCEL,
            RetirementPath.EXPIRY,
            RetirementPath.DESTROY,
            RetirementPath.FINISH,
        )) {
            var now = 1_000L
            val registry = CommandContinuationRegistry(nowEpochMs = { now })
            val key = terminalKey("retry-${path.name}", "retry-${path.name}")
            val candidate = "retry-candidate-${path.name}"
            val process = PlannedOwnedProcess(
                "retry-pid-${path.name}",
                ProcessDisposalResult.RETRYABLE_UNKNOWN,
                ProcessDisposalResult.DISPOSED,
            )
            assertEquals(CommandReserveOutcome.NEW, registry.reserveTerminal(key, candidate, 10L))
            assertEquals(CandidateReceipt.NATIVE_OWNS, registry.attachTerminal(key, candidate, process))
            when (path) {
                RetirementPath.CANCEL -> assertEquals(
                    CandidateReceipt.UNKNOWN,
                    registry.cancelTerminal(key, candidate),
                )
                RetirementPath.EXPIRY -> {
                    now = 1_011L
                    assertTrue(registry.expire(CommandContinuationOwner.TERMINAL).isEmpty())
                }
                RetirementPath.DESTROY -> assertTrue(registry.destroyOwner(key.owner).isEmpty())
                RetirementPath.FINISH -> assertEquals(
                    CandidateReceipt.UNKNOWN,
                    registry.finishTerminal(key, candidate),
                )
                RetirementPath.REPLACEMENT -> error("covered separately")
            }
            assertTrue(registry.isActiveCandidate(key, candidate))
            assertEquals(CandidateReceipt.NATIVE_OWNS, registry.terminalReceipt(key, candidate, process.identityToken))
            assertEquals(listOf(key), registry.retryPending(key.owner))
            assertFalse(registry.isActiveCandidate(key, candidate))
            assertEquals(CandidateReceipt.NATIVE_DISPOSED, registry.terminalReceipt(key, candidate, "other"))
            assertEquals(2, process.disposeCount.get())
        }

        val registry = CommandContinuationRegistry(nowEpochMs = { 1_000L })
        val oldKey = terminalKey("replacement-retry", "replacement-old")
        val oldCandidate = "replacement-old-candidate"
        val oldProcess = PlannedOwnedProcess(
            "replacement-old-pid",
            ProcessDisposalResult.RETRYABLE_UNKNOWN,
            ProcessDisposalResult.DISPOSED,
        )
        assertEquals(CommandReserveOutcome.NEW, registry.reserveTerminal(oldKey, oldCandidate, 60_000L))
        assertEquals(CandidateReceipt.NATIVE_OWNS, registry.attachTerminal(oldKey, oldCandidate, oldProcess))
        val newKey = terminalKey(oldKey.sessionId, "replacement-new")
        val retry = registry.replaceTerminalSession(
            newKey,
            "replacement-new-candidate",
            60_000L,
        )
        assertEquals(CommandReserveOutcome.RETRYABLE_UNKNOWN, retry.outcome)
        assertEquals(CommandAdmissionReason.REGISTRY_RETRY, retry.reason)
        assertTrue(registry.isActiveCandidate(oldKey, oldCandidate))
        assertFalse(registry.isActiveCandidate(newKey, "replacement-new-candidate"))
        assertEquals(listOf(oldKey), registry.retryPending(CommandContinuationOwner.TERMINAL))
        assertEquals(
            CommandReserveOutcome.NEW,
            registry.replaceTerminalSession(newKey, "replacement-new-candidate", 60_000L).outcome,
        )
        val conflict = registry.replaceTerminalSession(
            newKey,
            "replacement-conflict-candidate",
            60_000L,
        )
        assertEquals(CommandReserveOutcome.CONFLICT, conflict.outcome)
        assertEquals(CommandAdmissionReason.REGISTRY_CONFLICT, conflict.reason)
    }

    @Test
    fun agentRetirementCallersAlsoRetainProcessUntilTypedRetrySucceeds() {
        for (path in listOf(
            RetirementPath.CANCEL,
            RetirementPath.EXPIRY,
            RetirementPath.DESTROY,
            RetirementPath.FINISH,
        )) {
            var now = 1_000L
            val registry = CommandContinuationRegistry(nowEpochMs = { now })
            val key = agentKey("agent-${path.name}", "agent-${path.name}")
            val process = PlannedOwnedProcess(
                "agent-process-${path.name}",
                ProcessDisposalResult.RETRYABLE_UNKNOWN,
                ProcessDisposalResult.DISPOSED,
            )
            assertEquals(CommandReserveOutcome.NEW, registry.reserve(key, 10L))
            assertEquals(CandidateReceipt.NATIVE_OWNS, registry.attachAgent(key, process))
            when (path) {
                RetirementPath.CANCEL -> assertEquals(
                    CommandRetireOutcome.RETRYABLE_UNKNOWN,
                    registry.cancel(key).outcome,
                )
                RetirementPath.EXPIRY -> {
                    now = 1_011L
                    assertTrue(registry.expire(CommandContinuationOwner.AGENT_BASH).isEmpty())
                }
                RetirementPath.DESTROY -> assertTrue(registry.destroyOwner(key.owner).isEmpty())
                RetirementPath.FINISH -> assertEquals(
                    CommandRetireOutcome.RETRYABLE_UNKNOWN,
                    registry.finish(key).outcome,
                )
                RetirementPath.REPLACEMENT -> error("terminal only")
            }
            assertTrue(registry.isActive(key))
            assertEquals(listOf(key), registry.retryPending(CommandContinuationOwner.AGENT_BASH))
            assertFalse(registry.isActive(key))
            assertEquals(2, process.disposeCount.get())
        }
    }

    @Test
    fun onDestroyUnknownOwnershipRemainsDiscoverableForExactServiceRestart() {
        val registry = CommandContinuationRegistry(nowEpochMs = { 1_000L })
        val terminalKey = terminalKey("destroy-terminal", "destroy-terminal-operation")
        val terminalProcess = PlannedOwnedProcess(
            "destroy-terminal-pid",
            ProcessDisposalResult.RETRYABLE_UNKNOWN,
            ProcessDisposalResult.DISPOSED,
        )
        assertEquals(CommandReserveOutcome.NEW, registry.reserveTerminal(
            terminalKey,
            "destroy-terminal-candidate",
            60_000L,
        ))
        assertEquals(CandidateReceipt.NATIVE_OWNS, registry.attachTerminal(
            terminalKey,
            "destroy-terminal-candidate",
            terminalProcess,
        ))
        assertTrue(registry.destroyOwner(CommandContinuationOwner.TERMINAL).isEmpty())
        assertEquals(
            listOf(TerminalCandidateKey(terminalKey, "destroy-terminal-candidate")),
            registry.activeTerminalCandidates(),
        )
        assertTrue(registry.hasPendingRetirement(CommandContinuationOwner.TERMINAL))

        val agentKey = agentKey("destroy-agent", "destroy-agent-operation")
        val agentProcess = PlannedOwnedProcess(
            "destroy-agent-process",
            ProcessDisposalResult.RETRYABLE_UNKNOWN,
            ProcessDisposalResult.DISPOSED,
        )
        assertEquals(CommandReserveOutcome.NEW, registry.reserve(agentKey, 60_000L))
        assertEquals(CandidateReceipt.NATIVE_OWNS, registry.attachAgent(agentKey, agentProcess))
        assertTrue(registry.destroyOwner(CommandContinuationOwner.AGENT_BASH).isEmpty())
        assertEquals(listOf(agentKey), registry.activeKeys(CommandContinuationOwner.AGENT_BASH))
        assertTrue(registry.hasPendingRetirement(CommandContinuationOwner.AGENT_BASH))

        assertEquals(2, registry.retryPending().size)
        assertFalse(registry.hasPendingRetirement(CommandContinuationOwner.TERMINAL))
        assertFalse(registry.hasPendingRetirement(CommandContinuationOwner.AGENT_BASH))
    }

    @Test
    fun sameOperationDifferentOwnerOrSessionIsConflict() {
        val registry = CommandContinuationRegistry(nowEpochMs = { 1_000L })
        val terminal = terminalKey("terminal", "shared-id")
        val agent = agentKey("agent", "shared-id")
        assertEquals(CommandReserveOutcome.NEW, registry.reserveTerminal(terminal, "candidate", 60_000L))
        assertEquals(CommandReserveOutcome.CONFLICT, registry.reserve(agent, 60_000L))
        assertEquals(CommandRetireOutcome.CONFLICT, registry.cancel(agent).outcome)
        assertTrue(registry.isActiveCandidate(terminal, "candidate"))
    }

    private fun agentKey(sessionId: String, operationId: String) =
        CommandOwnerKey(CommandContinuationOwner.AGENT_BASH, sessionId, operationId)

    private fun terminalKey(sessionId: String, operationId: String) =
        CommandOwnerKey(CommandContinuationOwner.TERMINAL, sessionId, operationId)

    private enum class RetirementPath { CANCEL, EXPIRY, REPLACEMENT, DESTROY, FINISH }

    private class FakeOwnedProcess(
        override val identityToken: Any = Any(),
    ) : OwnedCommandProcess() {
        val killCount = AtomicInteger()

        override fun disposeProcess(signal: Boolean): ProcessDisposalResult {
            if (signal) killCount.incrementAndGet()
            return if (signal) ProcessDisposalResult.DISPOSED
            else ProcessDisposalResult.VERIFIED_GONE_OR_REUSED
        }
    }

    private class PlannedOwnedProcess(
        override val identityToken: Any,
        vararg results: ProcessDisposalResult,
    ) : OwnedCommandProcess() {
        private val results = results.toMutableList()
        val disposeCount = AtomicInteger()

        override fun disposeProcess(signal: Boolean): ProcessDisposalResult {
            disposeCount.incrementAndGet()
            return if (results.size > 1) results.removeAt(0) else results.single()
        }
    }

    private class PlannedPidProbe(vararg results: PidProbeResult) : PidProcessProbe {
        private val results = results.toMutableList()

        override fun read(processId: Int): PidProbeResult =
            if (results.size > 1) results.removeAt(0) else results.single()
    }

    private class CountingSignaler(private val fail: Boolean = false) : PidProcessSignaler {
        val count = AtomicInteger()

        override fun signal(processId: Int) {
            count.incrementAndGet()
            if (fail) throw IllegalStateException("signal failed")
        }
    }

    private class FakeJavaProcess(
        @Volatile var alive: Boolean,
        private val destroyThrows: Boolean = false,
        private val exitsWhenDestroyed: Boolean = false,
    ) : Process() {
        val destroyCount = AtomicInteger()

        override fun getOutputStream(): OutputStream = ByteArrayOutputStream()

        override fun getInputStream(): InputStream = ByteArrayInputStream(byteArrayOf())

        override fun getErrorStream(): InputStream = ByteArrayInputStream(byteArrayOf())

        override fun waitFor(): Int {
            alive = false
            return 0
        }

        override fun waitFor(timeout: Long, unit: TimeUnit): Boolean = !alive

        override fun exitValue(): Int = if (alive) throw IllegalThreadStateException() else 0

        override fun destroy() {
            destroyForcibly()
        }

        override fun destroyForcibly(): Process {
            destroyCount.incrementAndGet()
            if (destroyThrows) throw IllegalStateException("destroy failed")
            if (exitsWhenDestroyed) alive = false
            return this
        }

        override fun isAlive(): Boolean = alive
    }
}
