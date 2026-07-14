package com.anka.clawbot

import java.util.concurrent.TimeUnit

internal enum class CommandContinuationOwner {
    TERMINAL,
    AGENT_BASH,
}

internal data class CommandOwnerKey(
    val owner: CommandContinuationOwner,
    val sessionId: String,
    val operationId: String,
)

internal data class TerminalCandidateKey(
    val ownerKey: CommandOwnerKey,
    val candidateId: String,
)

internal enum class CommandReserveOutcome {
    NEW,
    ALREADY_ACTIVE,
    RETIRED,
    ACKNOWLEDGED,
    RETRYABLE_UNKNOWN,
    CONFLICT,
}

/** ACKNOWLEDGED/UNKNOWN/CONFLICT never grant process disposal authority. */
internal enum class CandidateReceipt {
    NATIVE_OWNS,
    NATIVE_DISPOSED,
    CALLER_OWNS,
    ACKNOWLEDGED,
    UNKNOWN,
    CONFLICT,
}

internal enum class CommandRetireOutcome {
    RETIRED,
    ALREADY_RETIRED,
    RETRYABLE_UNKNOWN,
    CONFLICT,
}

internal enum class ProcessDisposalResult {
    DISPOSED,
    VERIFIED_GONE_OR_REUSED,
    RETRYABLE_UNKNOWN,
}

/** The exact native cancellation capability owned by one command lease. */
internal abstract class OwnedCommandProcess {
    private var definitiveResult: ProcessDisposalResult? = null

    abstract val identityToken: Any
    open val hasIssuedSignal: Boolean get() = false

    @Synchronized
    fun dispose(signal: Boolean = true): ProcessDisposalResult {
        definitiveResult?.let { return it }
        val result = disposeProcess(signal)
        if (result != ProcessDisposalResult.RETRYABLE_UNKNOWN) {
            definitiveResult = result
        }
        return result
    }

    protected abstract fun disposeProcess(signal: Boolean): ProcessDisposalResult
}

/** Owns the real Java process used by an Agent/Bash continuation. */
internal class JavaOwnedCommandProcess(val process: Process) : OwnedCommandProcess() {
    override val identityToken: Any = process
    override var hasIssuedSignal = false
        private set

    override fun disposeProcess(signal: Boolean): ProcessDisposalResult {
        if (!process.isAlive) return ProcessDisposalResult.VERIFIED_GONE_OR_REUSED
        if (!signal) return ProcessDisposalResult.RETRYABLE_UNKNOWN
        if (hasIssuedSignal) {
            return if (process.isAlive) ProcessDisposalResult.RETRYABLE_UNKNOWN
            else ProcessDisposalResult.DISPOSED
        }
        try {
            process.destroyForcibly()
            hasIssuedSignal = true
        } catch (_: Exception) {
            return ProcessDisposalResult.RETRYABLE_UNKNOWN
        }
        return try {
            if (process.waitFor(100L, TimeUnit.MILLISECONDS) || !process.isAlive) {
                ProcessDisposalResult.DISPOSED
            } else {
                ProcessDisposalResult.RETRYABLE_UNKNOWN
            }
        } catch (_: Exception) {
            ProcessDisposalResult.RETRYABLE_UNKNOWN
        }
    }
}

internal sealed interface PidProbeResult {
    data class Present(val startTimeTicks: Long) : PidProbeResult
    data object Missing : PidProbeResult
    data object RetryableUnknown : PidProbeResult
}

internal fun interface PidProcessProbe {
    fun read(processId: Int): PidProbeResult
}

internal fun interface PidProcessSignaler {
    fun signal(processId: Int)
}

internal data class PidGenerationToken(
    val processId: Int,
    val startTimeTicks: Long,
)

internal class PidOwnedCommandProcess private constructor(
    private val processId: Int,
    override val identityToken: PidGenerationToken,
    private val probe: PidProcessProbe,
    private val signaler: PidProcessSignaler,
) : OwnedCommandProcess() {
    override var hasIssuedSignal = false
        private set

    override fun disposeProcess(signal: Boolean): ProcessDisposalResult {
        when (val before = probe.read(processId)) {
            PidProbeResult.Missing -> return ProcessDisposalResult.VERIFIED_GONE_OR_REUSED
            PidProbeResult.RetryableUnknown -> return ProcessDisposalResult.RETRYABLE_UNKNOWN
            is PidProbeResult.Present -> if (before.startTimeTicks != identityToken.startTimeTicks) {
                return ProcessDisposalResult.VERIFIED_GONE_OR_REUSED
            }
        }
        if (!signal) return ProcessDisposalResult.RETRYABLE_UNKNOWN
        if (!hasIssuedSignal) {
            try {
                signaler.signal(processId)
                hasIssuedSignal = true
            } catch (_: Exception) {
                return ProcessDisposalResult.RETRYABLE_UNKNOWN
            }
        }
        return when (val after = probe.read(processId)) {
            PidProbeResult.Missing -> ProcessDisposalResult.DISPOSED
            PidProbeResult.RetryableUnknown -> ProcessDisposalResult.RETRYABLE_UNKNOWN
            is PidProbeResult.Present -> if (after.startTimeTicks == identityToken.startTimeTicks) {
                ProcessDisposalResult.RETRYABLE_UNKNOWN
            } else {
                ProcessDisposalResult.VERIFIED_GONE_OR_REUSED
            }
        }
    }

    companion object {
        fun create(
            processId: Int,
            probe: PidProcessProbe,
            signaler: PidProcessSignaler,
        ): PidOwnedCommandProcess? {
            val initial = probe.read(processId) as? PidProbeResult.Present ?: return null
            return PidOwnedCommandProcess(
                processId,
                PidGenerationToken(processId, initial.startTimeTicks),
                probe,
                signaler,
            )
        }

        fun fromGeneration(
            processId: Int,
            startTimeTicks: Long,
            probe: PidProcessProbe,
            signaler: PidProcessSignaler,
        ): PidOwnedCommandProcess = PidOwnedCommandProcess(
            processId,
            PidGenerationToken(processId, startTimeTicks),
            probe,
            signaler,
        )

        fun currentToken(processId: Int, probe: PidProcessProbe): Any =
            when (val current = probe.read(processId)) {
                is PidProbeResult.Present -> PidGenerationToken(processId, current.startTimeTicks)
                PidProbeResult.Missing -> PidMissingToken(processId)
                PidProbeResult.RetryableUnknown -> PidUnknownToken(processId)
            }
    }
}

private data class PidMissingToken(val processId: Int)
private data class PidUnknownToken(val processId: Int)

internal data class CommandRetireResult(
    val outcome: CommandRetireOutcome,
    val key: CommandOwnerKey,
)

internal data class TerminalSessionReplacementResult(
    val outcome: CommandReserveOutcome,
    val candidate: TerminalCandidateKey,
    val retiredCandidates: List<TerminalCandidateKey> = emptyList(),
    val reason: CommandAdmissionReason? = when (outcome) {
        CommandReserveOutcome.RETRYABLE_UNKNOWN -> CommandAdmissionReason.REGISTRY_RETRY
        CommandReserveOutcome.CONFLICT -> CommandAdmissionReason.REGISTRY_CONFLICT
        else -> null
    },
)

private enum class CommandLeasePhase {
    STARTING,
    RUNNING,
}

private data class CommandLease(
    val key: CommandOwnerKey,
    val deadlineEpochMs: Long,
    val candidateId: String? = null,
    var phase: CommandLeasePhase = CommandLeasePhase.STARTING,
    var process: OwnedCommandProcess? = null,
    var pendingRetirement: Boolean = false,
    var signalRequested: Boolean = false,
) {
    val terminalCandidate: TerminalCandidateKey?
        get() = candidateId?.let { TerminalCandidateKey(key, it) }
}

private data class RetiredRecord(
    val key: CommandOwnerKey,
    val expiresEpochMs: Long,
)

private enum class ReceiptPhase {
    ACTIVE,
    UNACKNOWLEDGED_FINAL,
    ACKNOWLEDGED_FINAL,
}

private data class ReceiptRecord(
    var receipt: CandidateReceipt,
    var phase: ReceiptPhase,
)

/**
 * Single native SSOT for command leases and terminal candidate receipts.
 *
 * Terminal candidates use a high-entropy ID as authority; PID is only data
 * checked after the candidate is matched. Final receipts remain authoritative
 * until an exact consumer acknowledgment. Acknowledged receipts remain compact
 * no-authority tombstones for process lifetime so ack retries can replay the
 * original final while ordinary stale calls receive only ACKNOWLEDGED. No
 * terminal receipt phase is capacity-evicted; admission fails closed at
 * [receiptCapacity].
 */
internal class CommandContinuationRegistry(
    private val nowEpochMs: () -> Long = System::currentTimeMillis,
    private val beforeAttachLock: (() -> Unit)? = null,
    private val afterAcknowledgeLocked: (() -> Unit)? = null,
    private val receiptGraceMs: Long = 5 * 60 * 1000L,
    private val receiptCapacity: Int = 512,
    private val retiredCapacity: Int = 512,
) {
    private val lock = Any()
    private val active = linkedMapOf<String, CommandLease>()
    private val retired = linkedMapOf<String, RetiredRecord>()
    private val receipts = linkedMapOf<TerminalCandidateKey, ReceiptRecord>()

    /** Agent/Bash reservation. Terminal reservations require a candidate ID. */
    fun reserve(key: CommandOwnerKey, timeoutMs: Long): CommandReserveOutcome {
        if (key.owner == CommandContinuationOwner.TERMINAL) {
            return CommandReserveOutcome.CONFLICT
        }
        return reserveInternal(key, candidateId = null, timeoutMs = timeoutMs)
    }

    fun reserveTerminal(
        key: CommandOwnerKey,
        candidateId: String,
        timeoutMs: Long,
    ): CommandReserveOutcome {
        if (!validTerminalCandidate(key, candidateId)) return CommandReserveOutcome.CONFLICT
        return reserveInternal(key, candidateId, timeoutMs)
    }

    private fun reserveInternal(
        key: CommandOwnerKey,
        candidateId: String?,
        timeoutMs: Long,
    ): CommandReserveOutcome {
        if (key.operationId.isBlank() || key.sessionId.isBlank() || timeoutMs <= 0L) {
            return CommandReserveOutcome.CONFLICT
        }
        return synchronized(lock) {
            val now = nowEpochMs()
            pruneLocked(now)
            expireMatchingLocked(key, now)
            val live = active[key.operationId]
            if (live != null) {
                return@synchronized if (live.key == key && live.candidateId == candidateId) {
                    CommandReserveOutcome.ALREADY_ACTIVE
                } else {
                    CommandReserveOutcome.CONFLICT
                }
            }
            if (candidateId != null) {
                val candidate = TerminalCandidateKey(key, candidateId)
                val receipt = receipts[candidate]
                if (receipt != null) {
                    return@synchronized if (receipt.phase == ReceiptPhase.ACKNOWLEDGED_FINAL) {
                        CommandReserveOutcome.ACKNOWLEDGED
                    } else {
                        CommandReserveOutcome.RETIRED
                    }
                }
                if (receipts.keys.any { it.ownerKey.operationId == key.operationId }) {
                    return@synchronized CommandReserveOutcome.CONFLICT
                }
            }
            val tombstone = retired[key.operationId]
            if (tombstone != null) {
                return@synchronized if (tombstone.key == key &&
                    (candidateId == null || receipts.containsKey(TerminalCandidateKey(key, candidateId)))) {
                    CommandReserveOutcome.RETIRED
                } else {
                    CommandReserveOutcome.CONFLICT
                }
            }
            if (key.owner == CommandContinuationOwner.TERMINAL &&
                active.values.any { it.key.owner == key.owner && it.key.sessionId == key.sessionId }) {
                return@synchronized CommandReserveOutcome.CONFLICT
            }
            if (candidateId != null && !canTrackNewCandidateLocked()) {
                return@synchronized CommandReserveOutcome.CONFLICT
            }
            active[key.operationId] = CommandLease(
                key = key,
                candidateId = candidateId,
                deadlineEpochMs = now + timeoutMs,
            )
            CommandReserveOutcome.NEW
        }
    }

    /** Atomically retires the old terminal PID and installs one replacement. */
    fun replaceTerminalSession(
        key: CommandOwnerKey,
        candidateId: String,
        timeoutMs: Long,
    ): TerminalSessionReplacementResult {
        val candidate = TerminalCandidateKey(key, candidateId)
        if (!validTerminalCandidate(key, candidateId) || timeoutMs <= 0L) {
            return TerminalSessionReplacementResult(CommandReserveOutcome.CONFLICT, candidate)
        }
        return synchronized(lock) {
            val now = nowEpochMs()
            pruneLocked(now)
            expireMatchingLocked(key, now)
            val sameOperation = active[key.operationId]
            if (sameOperation != null) {
                val outcome = if (sameOperation.key == key &&
                    sameOperation.candidateId == candidateId) {
                    CommandReserveOutcome.ALREADY_ACTIVE
                } else {
                    CommandReserveOutcome.CONFLICT
                }
                return@synchronized TerminalSessionReplacementResult(outcome, candidate)
            }
            val existingReceipt = receipts[candidate]
            if (existingReceipt != null) {
                return@synchronized TerminalSessionReplacementResult(
                    if (existingReceipt.phase == ReceiptPhase.ACKNOWLEDGED_FINAL) {
                        CommandReserveOutcome.ACKNOWLEDGED
                    } else {
                        CommandReserveOutcome.RETIRED
                    },
                    candidate,
                )
            }
            if (receipts.keys.any { it.ownerKey.operationId == key.operationId }) {
                return@synchronized TerminalSessionReplacementResult(
                    CommandReserveOutcome.CONFLICT,
                    candidate,
                )
            }
            val tombstone = retired[key.operationId]
            if (tombstone != null) {
                val outcome = if (tombstone.key == key && receipts.containsKey(candidate)) {
                    CommandReserveOutcome.RETIRED
                } else {
                    CommandReserveOutcome.CONFLICT
                }
                return@synchronized TerminalSessionReplacementResult(outcome, candidate)
            }
            val previous = active.values.filter {
                it.key.owner == CommandContinuationOwner.TERMINAL &&
                    it.key.sessionId == key.sessionId
            }.toList()
            if (!canTrackNewCandidateLocked()) {
                return@synchronized TerminalSessionReplacementResult(
                    CommandReserveOutcome.CONFLICT,
                    candidate,
                )
            }
            for (lease in previous) {
                if (retireTerminalLeaseLocked(lease, signal = true) ==
                    CandidateReceipt.UNKNOWN) {
                    return@synchronized TerminalSessionReplacementResult(
                        CommandReserveOutcome.RETRYABLE_UNKNOWN,
                        candidate,
                    )
                }
            }
            active[key.operationId] = CommandLease(
                key = key,
                candidateId = candidateId,
                deadlineEpochMs = now + timeoutMs,
            )
            TerminalSessionReplacementResult(
                CommandReserveOutcome.NEW,
                candidate,
                previous.mapNotNull { it.terminalCandidate },
            )
        }
    }

    /** Agent/Bash attach: native disposes every rejected Java Process. */
    fun attachAgent(
        key: CommandOwnerKey,
        process: OwnedCommandProcess,
        beforeSignal: (() -> Boolean)? = null,
        beforeNativeOwnership: ((deadlineEpochMs: Long) -> Boolean)? = null,
    ): CandidateReceipt {
        beforeAttachLock?.invoke()
        return synchronized(lock) {
            val now = nowEpochMs()
            pruneLocked(now)
            val lease = active[key.operationId]
            if (lease == null || lease.key != key || lease.candidateId != null) {
                if (beforeSignal?.invoke() == false) {
                    return@synchronized CandidateReceipt.UNKNOWN
                }
                return@synchronized when (process.dispose(signal = true)) {
                    ProcessDisposalResult.DISPOSED,
                    ProcessDisposalResult.VERIFIED_GONE_OR_REUSED,
                    -> CandidateReceipt.NATIVE_DISPOSED
                    ProcessDisposalResult.RETRYABLE_UNKNOWN -> CandidateReceipt.UNKNOWN
                }
            }
            if (lease.deadlineEpochMs <= now) {
                if (lease.process == null) {
                    lease.process = process
                    lease.phase = CommandLeasePhase.RUNNING
                }
                val outcome = retireAgentLeaseLocked(
                    lease,
                    signal = true,
                    now = now,
                    beforeSignal = beforeSignal,
                ).outcome
                return@synchronized if (outcome == CommandRetireOutcome.RETRYABLE_UNKNOWN) {
                    CandidateReceipt.UNKNOWN
                } else {
                    CandidateReceipt.NATIVE_DISPOSED
                }
            }
            if (lease.phase == CommandLeasePhase.RUNNING) {
                if (lease.process?.identityToken == process.identityToken) {
                    CandidateReceipt.NATIVE_OWNS
                } else {
                    if (beforeSignal?.invoke() == false) {
                        return@synchronized CandidateReceipt.UNKNOWN
                    }
                    when (process.dispose(signal = true)) {
                        ProcessDisposalResult.DISPOSED,
                        ProcessDisposalResult.VERIFIED_GONE_OR_REUSED,
                        -> CandidateReceipt.NATIVE_DISPOSED
                        ProcessDisposalResult.RETRYABLE_UNKNOWN -> CandidateReceipt.UNKNOWN
                    }
                }
            } else {
                if (beforeNativeOwnership?.invoke(lease.deadlineEpochMs) == false) {
                    return@synchronized CandidateReceipt.UNKNOWN
                }
                lease.phase = CommandLeasePhase.RUNNING
                lease.process = process
                CandidateReceipt.NATIVE_OWNS
            }
        }
    }

    fun attachTerminal(
        key: CommandOwnerKey,
        candidateId: String,
        process: OwnedCommandProcess,
        beforeSignal: (() -> Boolean)? = null,
        beforeNativeOwnership: ((deadlineEpochMs: Long) -> Boolean)? = null,
    ): CandidateReceipt {
        if (!validTerminalCandidate(key, candidateId)) return CandidateReceipt.CONFLICT
        beforeAttachLock?.invoke()
        return synchronized(lock) {
            val now = nowEpochMs()
            pruneLocked(now)
            val candidate = TerminalCandidateKey(key, candidateId)
            receipts[candidate]?.let { record ->
                if (record.phase == ReceiptPhase.ACKNOWLEDGED_FINAL) {
                    return@synchronized CandidateReceipt.ACKNOWLEDGED
                }
                if (record.receipt != CandidateReceipt.NATIVE_OWNS) {
                    return@synchronized record.receipt
                }
                val owned = active[key.operationId]
                return@synchronized if (owned?.key == key &&
                    owned.candidateId == candidateId &&
                    owned.process?.identityToken == process.identityToken) {
                    CandidateReceipt.NATIVE_OWNS
                } else {
                    CandidateReceipt.CONFLICT
                }
            }
            val lease = active[key.operationId]
            if (lease == null) return@synchronized terminalMissingReceiptLocked(candidate)
            if (lease.key != key || lease.candidateId != candidateId) {
                return@synchronized CandidateReceipt.CONFLICT
            }
            if (lease.deadlineEpochMs <= now) {
                return@synchronized retireTerminalLeaseLocked(
                    lease,
                    signal = true,
                    beforeSignal = beforeSignal,
                )
            }
            if (lease.phase == CommandLeasePhase.RUNNING) {
                return@synchronized if (lease.process?.identityToken == process.identityToken) {
                    CandidateReceipt.NATIVE_OWNS
                } else {
                    CandidateReceipt.CONFLICT
                }
            }
            if (beforeNativeOwnership?.invoke(lease.deadlineEpochMs) == false) {
                return@synchronized CandidateReceipt.UNKNOWN
            }
            lease.phase = CommandLeasePhase.RUNNING
            lease.process = process
            putReceiptLocked(candidate, CandidateReceipt.NATIVE_OWNS)
            CandidateReceipt.NATIVE_OWNS
        }
    }

    fun terminalReceipt(
        key: CommandOwnerKey,
        candidateId: String,
        identityToken: Any,
        beforeSignal: (() -> Boolean)? = null,
    ): CandidateReceipt {
        if (!validTerminalCandidate(key, candidateId)) return CandidateReceipt.CONFLICT
        return synchronized(lock) {
            val now = nowEpochMs()
            pruneLocked(now)
            val candidate = TerminalCandidateKey(key, candidateId)
            receipts[candidate]?.let { record ->
                if (record.phase == ReceiptPhase.ACKNOWLEDGED_FINAL) {
                    return@synchronized CandidateReceipt.ACKNOWLEDGED
                }
                if (record.receipt != CandidateReceipt.NATIVE_OWNS) {
                    return@synchronized record.receipt
                }
                val owned = active[key.operationId]
                return@synchronized if (owned?.key == key &&
                    owned.candidateId == candidateId &&
                    owned.process?.identityToken == identityToken) {
                    CandidateReceipt.NATIVE_OWNS
                } else {
                    CandidateReceipt.CONFLICT
                }
            }
            val lease = active[key.operationId]
            if (lease == null) return@synchronized terminalMissingReceiptLocked(candidate)
            if (lease.key != key || lease.candidateId != candidateId) {
                return@synchronized CandidateReceipt.CONFLICT
            }
            if (lease.deadlineEpochMs <= now) {
                return@synchronized retireTerminalLeaseLocked(
                    lease,
                    signal = true,
                    beforeSignal = beforeSignal,
                )
            }
            if (lease.phase == CommandLeasePhase.STARTING) {
                CandidateReceipt.UNKNOWN
            } else if (lease.process?.identityToken == identityToken) {
                CandidateReceipt.NATIVE_OWNS
            } else {
                CandidateReceipt.CONFLICT
            }
        }
    }

    /** Idempotently transfers an exact reserved candidate to native disposal. */
    fun disposeTerminalCandidate(
        key: CommandOwnerKey,
        candidateId: String,
        candidateProcess: OwnedCommandProcess,
        beforeSignal: (() -> Boolean)? = null,
    ): CandidateReceipt {
        if (!validTerminalCandidate(key, candidateId)) return CandidateReceipt.CONFLICT
        return synchronized(lock) {
            val now = nowEpochMs()
            pruneLocked(now)
            val candidate = TerminalCandidateKey(key, candidateId)
            receipts[candidate]?.let { record ->
                if (record.phase == ReceiptPhase.ACKNOWLEDGED_FINAL) {
                    return@synchronized CandidateReceipt.ACKNOWLEDGED
                }
                if (record.receipt == CandidateReceipt.NATIVE_OWNS) {
                    val lease = active[key.operationId]
                    if (lease == null || lease.key != key || lease.candidateId != candidateId ||
                        lease.process?.identityToken != candidateProcess.identityToken) {
                        return@synchronized CandidateReceipt.CONFLICT
                    }
                    return@synchronized retireTerminalLeaseLocked(
                        lease,
                        signal = true,
                        beforeSignal = beforeSignal,
                    )
                }
                return@synchronized record.receipt
            }
            val lease = active[key.operationId]
            if (lease == null) return@synchronized terminalMissingReceiptLocked(candidate)
            if (lease.key != key || lease.candidateId != candidateId) {
                return@synchronized CandidateReceipt.CONFLICT
            }
            if (lease.phase == CommandLeasePhase.RUNNING &&
                lease.process?.identityToken != candidateProcess.identityToken) {
                return@synchronized CandidateReceipt.CONFLICT
            }
            if (lease.process == null) {
                lease.process = candidateProcess
                lease.phase = CommandLeasePhase.RUNNING
                putReceiptLocked(candidate, CandidateReceipt.NATIVE_OWNS)
            }
            retireTerminalLeaseLocked(
                lease,
                signal = true,
                beforeSignal = beforeSignal,
            )
        }
    }

    fun finishTerminal(key: CommandOwnerKey, candidateId: String): CandidateReceipt =
        retireTerminal(key, candidateId, signal = false)

    fun cancelTerminal(
        key: CommandOwnerKey,
        candidateId: String,
        beforeSignal: (() -> Boolean)? = null,
    ): CandidateReceipt = retireTerminal(
        key,
        candidateId,
        signal = true,
        beforeSignal = beforeSignal,
    )

    fun acknowledgeFinalReceipt(
        key: CommandOwnerKey,
        candidateId: String,
        expectedReceipt: CandidateReceipt,
    ): CandidateReceipt {
        if (!validTerminalCandidate(key, candidateId) ||
            (expectedReceipt != CandidateReceipt.CALLER_OWNS &&
                expectedReceipt != CandidateReceipt.NATIVE_DISPOSED)) {
            return CandidateReceipt.CONFLICT
        }
        return synchronized(lock) {
            val candidate = TerminalCandidateKey(key, candidateId)
            val record = receipts[candidate] ?: return@synchronized terminalMissingReceiptLocked(candidate)
            if (record.receipt != expectedReceipt || record.phase == ReceiptPhase.ACTIVE) {
                return@synchronized CandidateReceipt.CONFLICT
            }
            if (record.phase == ReceiptPhase.UNACKNOWLEDGED_FINAL) {
                record.phase = ReceiptPhase.ACKNOWLEDGED_FINAL
                afterAcknowledgeLocked?.invoke()
            }
            record.receipt
        }
    }

    private fun retireTerminal(
        key: CommandOwnerKey,
        candidateId: String,
        signal: Boolean,
        beforeSignal: (() -> Boolean)? = null,
    ): CandidateReceipt {
        if (!validTerminalCandidate(key, candidateId)) return CandidateReceipt.CONFLICT
        return synchronized(lock) {
            val now = nowEpochMs()
            pruneLocked(now)
            val candidate = TerminalCandidateKey(key, candidateId)
            receipts[candidate]?.let { record ->
                if (record.phase == ReceiptPhase.ACKNOWLEDGED_FINAL) {
                    return@synchronized CandidateReceipt.ACKNOWLEDGED
                }
                if (record.receipt != CandidateReceipt.NATIVE_OWNS) {
                    return@synchronized record.receipt
                }
            }
            val lease = active[key.operationId]
            if (lease != null) {
                if (lease.key != key || lease.candidateId != candidateId) {
                    return@synchronized CandidateReceipt.CONFLICT
                }
                return@synchronized retireTerminalLeaseLocked(
                    lease,
                    signal,
                    beforeSignal,
                )
            }
            val tombstone = retired[key.operationId]
            if (tombstone != null && tombstone.key != key) {
                return@synchronized CandidateReceipt.CONFLICT
            }
            if (tombstone != null) return@synchronized terminalMissingReceiptLocked(candidate)
            // A terminal cancel without a reservation cannot prove that Dart
            // owns a live process. Returning CALLER_OWNS here would recreate
            // kill authority for a stale, already acknowledged candidate.
            CandidateReceipt.UNKNOWN
        }
    }

    fun finish(key: CommandOwnerKey): CommandRetireResult = retireAgent(key, signal = false)

    fun cancel(
        key: CommandOwnerKey,
        beforeSignal: (() -> Boolean)? = null,
    ): CommandRetireResult = retireAgent(key, signal = true, beforeSignal = beforeSignal)

    private fun retireAgent(
        key: CommandOwnerKey,
        signal: Boolean,
        beforeSignal: (() -> Boolean)? = null,
    ): CommandRetireResult {
        return synchronized(lock) {
            val now = nowEpochMs()
            pruneLocked(now)
            val lease = active[key.operationId]
            if (lease != null) {
                if (lease.key != key || lease.candidateId != null) {
                    return@synchronized CommandRetireResult(CommandRetireOutcome.CONFLICT, key)
                }
                return@synchronized retireAgentLeaseLocked(
                    lease,
                    signal,
                    now,
                    beforeSignal,
                )
            }
            val tombstone = retired[key.operationId]
            if (tombstone == null) {
                putRetiredLocked(key, now + receiptGraceMs)
                CommandRetireResult(CommandRetireOutcome.RETIRED, key)
            } else if (tombstone.key == key) {
                CommandRetireResult(CommandRetireOutcome.ALREADY_RETIRED, key)
            } else {
                CommandRetireResult(CommandRetireOutcome.CONFLICT, key)
            }
        }
    }

    fun cancelSession(
        owner: CommandContinuationOwner,
        sessionId: String,
        beforeSignal: ((CommandOwnerKey, String?) -> Boolean)? = null,
    ): List<CommandOwnerKey> = retireMatches(
        predicate = { it.key.owner == owner && it.key.sessionId == sessionId },
        beforeSignal = beforeSignal,
    )

    fun expire(
        owner: CommandContinuationOwner? = null,
        beforeSignal: ((CommandOwnerKey, String?) -> Boolean)? = null,
    ): List<CommandOwnerKey> {
        val now = nowEpochMs()
        return retireMatches(
            predicate = {
                it.deadlineEpochMs <= now && (owner == null || it.key.owner == owner)
            },
            beforeSignal = beforeSignal,
        )
    }

    fun destroy(
        beforeSignal: ((CommandOwnerKey, String?) -> Boolean)? = null,
    ): List<CommandOwnerKey> = retireMatches({ true }, beforeSignal)

    fun destroyOwner(
        owner: CommandContinuationOwner,
        beforeSignal: ((CommandOwnerKey, String?) -> Boolean)? = null,
    ): List<CommandOwnerKey> = retireMatches(
        predicate = { it.key.owner == owner },
        beforeSignal = beforeSignal,
    )

    private fun retireMatches(
        predicate: (CommandLease) -> Boolean,
        beforeSignal: ((CommandOwnerKey, String?) -> Boolean)? = null,
    ): List<CommandOwnerKey> =
        synchronized(lock) {
            val now = nowEpochMs()
            pruneLocked(now)
            val leases = active.values.filter(predicate).toList()
            val retiredKeys = mutableListOf<CommandOwnerKey>()
            for (lease in leases) {
                val retired = if (lease.key.owner == CommandContinuationOwner.TERMINAL) {
                    retireTerminalLeaseLocked(
                        lease,
                        signal = true,
                        beforeSignal = beforeSignal?.let { callback ->
                            { callback(lease.key, lease.candidateId) }
                        },
                    ) !=
                        CandidateReceipt.UNKNOWN
                } else {
                    retireAgentLeaseLocked(
                        lease,
                        signal = true,
                        now = now,
                        beforeSignal = beforeSignal?.let { callback ->
                            { callback(lease.key, null) }
                        },
                    ).outcome !=
                        CommandRetireOutcome.RETRYABLE_UNKNOWN
                }
                if (retired) retiredKeys.add(lease.key)
            }
            retiredKeys
        }

    fun retryPending(owner: CommandContinuationOwner? = null): List<CommandOwnerKey> =
        synchronized(lock) {
            val now = nowEpochMs()
            val completed = mutableListOf<CommandOwnerKey>()
            val pending = active.values.filter {
                it.pendingRetirement && (owner == null || it.key.owner == owner)
            }.toList()
            for (lease in pending) {
                val done = if (lease.key.owner == CommandContinuationOwner.TERMINAL) {
                    retireTerminalLeaseLocked(
                        lease,
                        signal = lease.signalRequested,
                    ) != CandidateReceipt.UNKNOWN
                } else {
                    retireAgentLeaseLocked(
                        lease,
                        signal = lease.signalRequested,
                        now = now,
                    ).outcome != CommandRetireOutcome.RETRYABLE_UNKNOWN
                }
                if (done) completed.add(lease.key)
            }
            completed
        }

    fun isActive(key: CommandOwnerKey): Boolean = synchronized(lock) {
        active[key.operationId]?.key == key
    }

    fun isActiveCandidate(key: CommandOwnerKey, candidateId: String): Boolean = synchronized(lock) {
        val lease = active[key.operationId]
        lease?.key == key && lease.candidateId == candidateId
    }

    fun hasSession(owner: CommandContinuationOwner, sessionId: String): Boolean =
        synchronized(lock) {
            active.values.any { it.key.owner == owner && it.key.sessionId == sessionId }
        }

    fun hasPendingRetirement(owner: CommandContinuationOwner): Boolean = synchronized(lock) {
        active.values.any { it.key.owner == owner && it.pendingRetirement }
    }

    fun activeKeyForSession(
        owner: CommandContinuationOwner,
        sessionId: String,
    ): CommandOwnerKey? = synchronized(lock) {
        active.values.firstOrNull {
            it.key.owner == owner && it.key.sessionId == sessionId
        }?.key
    }

    fun activeCandidateForSession(sessionId: String): TerminalCandidateKey? = synchronized(lock) {
        active.values.firstOrNull {
            it.key.owner == CommandContinuationOwner.TERMINAL && it.key.sessionId == sessionId
        }?.terminalCandidate
    }

    fun activeKeys(owner: CommandContinuationOwner): List<CommandOwnerKey> = synchronized(lock) {
        active.values.filter { it.key.owner == owner }.map { it.key }
    }

    fun activeTerminalCandidates(): List<TerminalCandidateKey> = synchronized(lock) {
        active.values.mapNotNull { lease ->
            lease.terminalCandidate?.takeIf {
                lease.key.owner == CommandContinuationOwner.TERMINAL
            }
        }
    }

    fun nextDeadlineEpochMs(owner: CommandContinuationOwner? = null): Long? =
        synchronized(lock) {
            active.values
                .filter { owner == null || it.key.owner == owner }
                .minOfOrNull { it.deadlineEpochMs }
        }

    fun deadlineEpochMs(key: CommandOwnerKey): Long? = synchronized(lock) {
        active[key.operationId]?.takeIf { it.key == key }?.deadlineEpochMs
    }

    fun activeCount(owner: CommandContinuationOwner? = null): Int = synchronized(lock) {
        active.values.count { owner == null || it.key.owner == owner }
    }

    internal fun receiptCountForTest(): Int = synchronized(lock) {
        pruneLocked(nowEpochMs())
        receipts.size
    }

    internal fun retiredCountForTest(): Int = synchronized(lock) {
        pruneLocked(nowEpochMs())
        retired.size
    }

    private fun validTerminalCandidate(key: CommandOwnerKey, candidateId: String): Boolean =
        key.owner == CommandContinuationOwner.TERMINAL && key.sessionId.isNotBlank() &&
            key.operationId.isNotBlank() && candidateId.isNotBlank()

    private fun expireMatchingLocked(key: CommandOwnerKey, now: Long) {
        val expired = active.values.filter { lease ->
            lease.deadlineEpochMs <= now &&
                (lease.key.operationId == key.operationId ||
                    (key.owner == CommandContinuationOwner.TERMINAL &&
                        lease.key.owner == key.owner && lease.key.sessionId == key.sessionId))
        }.toList()
        for (lease in expired) {
            if (lease.key.owner == CommandContinuationOwner.TERMINAL) {
                retireTerminalLeaseLocked(lease, signal = true)
            } else {
                retireAgentLeaseLocked(lease, signal = true, now = now)
            }
        }
    }

    private fun retireTerminalLeaseLocked(
        lease: CommandLease,
        signal: Boolean,
        beforeSignal: (() -> Boolean)? = null,
    ): CandidateReceipt {
        val candidate = requireNotNull(lease.terminalCandidate)
        val process = lease.process
        if (process == null) {
            active.remove(lease.key.operationId)
            putReceiptLocked(
                candidate,
                CandidateReceipt.CALLER_OWNS,
            )
            return CandidateReceipt.CALLER_OWNS
        }
        if (signal && beforeSignal?.invoke() == false) {
            lease.pendingRetirement = true
            // A failed durable intent write must never be converted into a
            // later unregistered signal by retryPending(). The coordinator
            // remains the only crash-recovery cleanup path in this state.
            lease.signalRequested = false
            return CandidateReceipt.UNKNOWN
        }
        return when (process.dispose(signal)) {
            ProcessDisposalResult.DISPOSED,
            ProcessDisposalResult.VERIFIED_GONE_OR_REUSED,
            -> {
                putReceiptLocked(
                    candidate,
                    CandidateReceipt.NATIVE_DISPOSED,
                )
                active.remove(lease.key.operationId)
                CandidateReceipt.NATIVE_DISPOSED
            }
            ProcessDisposalResult.RETRYABLE_UNKNOWN -> {
                lease.pendingRetirement = true
                lease.signalRequested = lease.signalRequested || signal
                CandidateReceipt.UNKNOWN
            }
        }
    }

    private fun retireAgentLeaseLocked(
        lease: CommandLease,
        signal: Boolean,
        now: Long,
        beforeSignal: (() -> Boolean)? = null,
    ): CommandRetireResult {
        val process = lease.process
        if (process == null) {
            active.remove(lease.key.operationId)
            putRetiredLocked(lease.key, lease.deadlineEpochMs.coerceAtLeast(now))
            return CommandRetireResult(CommandRetireOutcome.RETIRED, lease.key)
        }
        if (signal && beforeSignal?.invoke() == false) {
            lease.pendingRetirement = true
            lease.signalRequested = false
            return CommandRetireResult(CommandRetireOutcome.RETRYABLE_UNKNOWN, lease.key)
        }
        return when (process.dispose(signal)) {
            ProcessDisposalResult.DISPOSED,
            ProcessDisposalResult.VERIFIED_GONE_OR_REUSED,
            -> {
                active.remove(lease.key.operationId)
                putRetiredLocked(lease.key, lease.deadlineEpochMs.coerceAtLeast(now))
                CommandRetireResult(CommandRetireOutcome.RETIRED, lease.key)
            }
            ProcessDisposalResult.RETRYABLE_UNKNOWN -> {
                lease.pendingRetirement = true
                lease.signalRequested = lease.signalRequested || signal
                CommandRetireResult(CommandRetireOutcome.RETRYABLE_UNKNOWN, lease.key)
            }
        }
    }

    private fun terminalMissingReceiptLocked(candidate: TerminalCandidateKey): CandidateReceipt {
        if (receipts.keys.any { it.ownerKey.operationId == candidate.ownerKey.operationId }) {
            return CandidateReceipt.CONFLICT
        }
        val tombstone = retired[candidate.ownerKey.operationId]
        return if (tombstone != null) CandidateReceipt.CONFLICT else CandidateReceipt.UNKNOWN
    }

    private fun putReceiptLocked(
        candidate: TerminalCandidateKey,
        receipt: CandidateReceipt,
    ) {
        require(
            receipt == CandidateReceipt.NATIVE_OWNS ||
                receipt == CandidateReceipt.NATIVE_DISPOSED ||
                receipt == CandidateReceipt.CALLER_OWNS
        )
        val existing = receipts[candidate]
        if (existing == null) {
            receipts[candidate] = ReceiptRecord(
                receipt,
                phase = if (receipt == CandidateReceipt.NATIVE_OWNS) {
                    ReceiptPhase.ACTIVE
                } else {
                    ReceiptPhase.UNACKNOWLEDGED_FINAL
                },
            )
        } else {
            check(existing.phase != ReceiptPhase.ACKNOWLEDGED_FINAL) {
                "acknowledged candidate cannot regain disposal authority"
            }
            existing.receipt = receipt
            existing.phase = if (receipt == CandidateReceipt.NATIVE_OWNS) {
                ReceiptPhase.ACTIVE
            } else {
                ReceiptPhase.UNACKNOWLEDGED_FINAL
            }
        }
        pruneLocked(nowEpochMs())
    }

    private fun putRetiredLocked(key: CommandOwnerKey, deadlineEpochMs: Long) {
        // Terminal candidate receipts are the sole retirement authority.
        if (key.owner == CommandContinuationOwner.TERMINAL) return
        retired[key.operationId] = RetiredRecord(key, deadlineEpochMs + receiptGraceMs)
        pruneLocked(nowEpochMs())
    }

    private fun pruneLocked(now: Long) {
        // Acknowledged terminal records are compact no-authority tombstones.
        // They intentionally remain for process lifetime so stale ordinary
        // calls can never recreate disposal authority after a lost ack reply.
        retired.entries.removeAll { (operationId, record) ->
            operationId !in active && record.expiresEpochMs <= now
        }
        while (retired.size > retiredCapacity) {
            val removable = retired.keys.firstOrNull { it !in active } ?: break
            retired.remove(removable)
        }
    }

    private fun canTrackNewCandidateLocked(): Boolean {
        val tracked = receipts.keys.toMutableSet()
        tracked.addAll(active.values.mapNotNull { it.terminalCandidate })
        if (tracked.size < receiptCapacity) return true
        pruneLocked(nowEpochMs())
        tracked.clear()
        tracked.addAll(receipts.keys)
        tracked.addAll(active.values.mapNotNull { it.terminalCandidate })
        return tracked.size < receiptCapacity
    }
}

internal object NativeCommandContinuationOwner {
    val registry = CommandContinuationRegistry()
}
