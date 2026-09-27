package com.anka.clawbot

import io.flutter.plugin.common.MethodChannel
import java.util.Collections
import java.util.IdentityHashMap
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Tracks platform-call results that have not been answered yet.
 *
 * A handler that hands work to another thread (safeRunOnUiThread) may find the
 * activity or Flutter engine gone before the work finishes. Dropping the
 * MethodChannel.Result in that case leaves the Dart await pending forever,
 * which stalls an agent run and its cleanup. Every result registered here is
 * failed with a platform error when the activity or engine is torn down, so the
 * Dart side always observes a definite outcome.
 *
 * The owner is torn down once. [close] drains what is in flight and latches the
 * cancellation reason; a result that is tracked afterwards is failed on the
 * spot instead of joining a set that nobody will ever drain again.
 */
internal class PendingPlatformCallRegistry {
    private val lock = Any()
    private val pending = Collections.newSetFromMap(
        IdentityHashMap<TrackedPlatformCall, Boolean>()
    )

    /** Set by [close]; holds the error reported to every later caller. */
    private var closed: ClosedReason? = null

    private class ClosedReason(val errorCode: String, val message: String)

    /**
     * Registers [result] unless the owner is already gone, in which case it is
     * failed immediately with the reason [close] latched.
     *
     * Tracking and draining share one lock, so a call can never be added to a
     * set that was just drained: it either lands inside the drained snapshot or
     * it observes the closed flag.
     */
    fun track(result: MethodChannel.Result): MethodChannel.Result {
        val tracked = TrackedPlatformCall(result, lock, pending)
        val rejection: ClosedReason?
        synchronized(lock) {
            rejection = closed
            if (rejection == null) pending.add(tracked)
        }
        if (rejection != null) {
            // A definite error is the only useful answer: the Dart future must
            // not stay pending on a teardown that will never be followed up.
            tracked.fail(rejection.errorCode, rejection.message)
        }
        return tracked
    }

    fun pendingCount(): Int = synchronized(lock) { pending.size }

    /**
     * Fails every unanswered result with [errorCode], latches that reason, and
     * refuses later tracks. Idempotent: the first reason wins.
     *
     * Returns the number of calls that were still pending.
     */
    fun close(errorCode: String, message: String): Int {
        val snapshot: List<TrackedPlatformCall>
        synchronized(lock) {
            if (closed == null) closed = ClosedReason(errorCode, message)
            snapshot = pending.toList()
            pending.clear()
        }
        var failed = 0
        for (tracked in snapshot) {
            if (tracked.fail(errorCode, message)) failed++
        }
        return failed
    }

    private class TrackedPlatformCall(
        private val delegate: MethodChannel.Result,
        private val lock: Any,
        private val registry: MutableSet<TrackedPlatformCall>
    ) : MethodChannel.Result {
        private val settled = AtomicBoolean(false)

        override fun success(result: Any?) {
            settle { delegate.success(result) }
        }

        override fun error(code: String, message: String?, details: Any?) {
            settle { delegate.error(code, message, details) }
        }

        override fun notImplemented() {
            settle { delegate.notImplemented() }
        }

        fun fail(code: String, message: String): Boolean =
            settle {
                try {
                    delegate.error(code, message, null)
                } catch (_: Exception) {
                    // The engine is already gone: the caller is being failed
                    // precisely because no answer can reach it any more, so a
                    // dead channel must not break the teardown that runs here.
                }
            }

        private inline fun settle(action: () -> Unit): Boolean {
            if (!settled.compareAndSet(false, true)) return false
            try {
                synchronized(lock) { registry.remove(this) }
            } finally {
                action()
            }
            return true
        }
    }
}
