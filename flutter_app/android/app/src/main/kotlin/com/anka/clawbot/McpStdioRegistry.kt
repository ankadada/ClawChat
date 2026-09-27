package com.anka.clawbot

import android.util.Log
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** Outcome of [McpStdioRegistry.register]. */
internal enum class McpRegisterResult {
    REGISTERED,

    /** Another live child already owns this (runId, serverId). */
    ALREADY_RUNNING,

    /**
     * A teardown (or a closed Flutter engine) belongs to a later epoch than the
     * child being registered, so the child must not be adopted.
     */
    TEARDOWN,
}

/**
 * I5 — process-wide registry of live MCP stdio children.
 *
 * MCP children are run-scoped: one child per (runId, serverId). The registry is
 * shared between [MainActivity] (which starts and pipes them) and
 * [AgentTaskService] (which must take every child down when the foreground
 * service lease drops). There is no MCP supervisor: the registry only exists so
 * a service teardown can kill what a run left behind.
 *
 * Registration and teardown are serialized through one lock over an epoch
 * counter. A start captures the epoch before it spawns anything; a teardown
 * bumps the epoch and drains, so a child whose start overlapped the teardown can
 * never register afterwards and leak past it.
 */
internal object McpStdioRegistry {
    private const val TAG = "ClawChat"

    /** How long a killed child may take to run its own exit path. */
    private const val REAP_TIMEOUT_MS = 1500L

    private val lock = Any()
    private var epoch = 1L
    private var closed = false

    internal class Child(
        val runId: String,
        val serverId: String,
        val process: Process,
        val script: McpLaunchScript?,
        /**
         * Identifies this one start. Events carry it so a delayed line or exit
         * from a previous child can never be attributed to a later child that
         * reuses the same (runId, serverId).
         */
        val sessionToken: String,
        /** Registry epoch this child was spawned in; see [currentEpoch]. */
        val epoch: Long = McpStdioRegistry.currentEpoch(),
        /**
         * Delivers one event to Dart. The caller wraps this so a torn-down
         * engine can never make a teardown path throw.
         */
        private val emit: (Map<String, Any>) -> Unit,
    ) {
        /** True once this child's lifecycle is over; writers and readers stop. */
        @Volatile
        var finished = false
            private set

        /**
         * True once this child proved it is alive inside its readiness window by
         * producing output. A ready child is never killed for being slow.
         */
        @Volatile
        var ready = false
            private set

        private val terminal = AtomicBoolean(false)

        /**
         * Serializes stdin writes for this child. Two JSON-RPC frames written
         * concurrently would interleave bytes and corrupt the stream, so every
         * writer takes this lock around the whole frame.
         */
        val stdinLock = Any()

        fun markReady() {
            ready = true
        }

        /**
         * Publishes the single terminal event for this child.
         *
         * A child's exit can be observed by several paths at once (the exit
         * watcher, a stop request, a stream guard, the readiness budget). Each
         * of them races to be the one that tells Dart the child is gone; this
         * CAS makes sure exactly one event is emitted and that no path can
         * silently drop it. [finished] is set either way, so writers stop and
         * readers unwind even when another path won the race.
         */
        fun terminateOnce(reason: String?, exitCode: Int): Boolean {
            finished = true
            if (!terminal.compareAndSet(false, true)) return false
            McpStdioRegistry.removeIfCurrent(this)
            val event = mutableMapOf<String, Any>(
                "event" to "exit",
                "runId" to runId,
                "serverId" to serverId,
                "sessionToken" to sessionToken,
                "exitCode" to exitCode,
            )
            if (reason != null) event["reason"] = reason
            emit(event)
            return true
        }

        /** The real exit code when the child is already gone, else -1. */
        internal fun exitCodeIfExited(): Int = try {
            if (process.isAlive) -1 else process.exitValue()
        } catch (_: Exception) {
            -1
        }
    }

    private val children = ConcurrentHashMap<String, Child>()

    private fun key(runId: String, serverId: String) = "$runId\u0000$serverId"

    /** Epoch a start should stamp on the child it is about to spawn. */
    fun currentEpoch(): Long = synchronized(lock) { epoch }

    /**
     * A Flutter engine (and with it a Dart side that may start MCP children) is
     * up: the next epoch accepts registrations again.
     */
    fun openEpoch(): Long = synchronized(lock) {
        closed = false
        epoch += 1
        epoch
    }

    /**
     * The Dart side is gone (engine detached or activity destroyed). No child
     * may register until a new engine opens the next epoch, and everything that
     * is live now is stopped.
     */
    fun closeEpoch(reason: String?): Int {
        synchronized(lock) {
            closed = true
            epoch += 1
        }
        return stopAll(reason, bumpEpoch = false)
    }

    /**
     * Adopts [child] unless its epoch was superseded by a teardown (or the
     * engine is closed), in which case the caller must destroy the process it
     * already spawned.
     */
    fun register(child: Child): McpRegisterResult = synchronized(lock) {
        if (closed || child.epoch != epoch) return McpRegisterResult.TEARDOWN
        val previous = children.putIfAbsent(key(child.runId, child.serverId), child)
        if (previous != null) return McpRegisterResult.ALREADY_RUNNING
        McpRegisterResult.REGISTERED
    }

    fun remove(runId: String, serverId: String): Child? =
        children.remove(key(runId, serverId))

    /**
     * Removes [child] only while it is still the live child for its key, so a
     * terminal event from a stopped child cannot unregister the fresh child a
     * later start registered under the same key.
     */
    internal fun removeIfCurrent(child: Child): Boolean =
        children.remove(key(child.runId, child.serverId), child)

    fun get(runId: String, serverId: String): Child? =
        children[key(runId, serverId)]

    /**
     * The live child for [runId]/[serverId], but only when [sessionToken]
     * identifies that exact start. A stale token (a previous child of the same
     * key) never reaches the new child.
     */
    fun getIfTokenMatches(
        runId: String,
        serverId: String,
        sessionToken: String?,
    ): Child? {
        val child = children[key(runId, serverId)] ?: return null
        if (sessionToken == null) return child
        return if (child.sessionToken == sessionToken) child else null
    }

    fun stopServer(runId: String, serverId: String, reason: String? = null) {
        val child = remove(runId, serverId) ?: return
        kill(child, reason)
    }

    fun stopServerIfTokenMatches(
        runId: String,
        serverId: String,
        sessionToken: String?,
        reason: String? = null,
    ) {
        val child = getIfTokenMatches(runId, serverId, sessionToken) ?: return
        if (removeIfCurrent(child)) kill(child, reason)
    }

    /**
     * Stops the children of one run.
     *
     * [expectedSessionTokens] is what the caller owns. When it is given, only
     * those starts are stopped: a delayed stop from an earlier lifecycle must
     * never take down the child that replaced the same (runId, serverId) since
     * the caller last looked. Whichever way the filter decides, the removal is
     * instance-scoped, so a child that replaced a snapshot entry survives.
     *
     * A null filter keeps the historical behaviour of stopping the whole run
     * (used by teardown paths and tests that genuinely mean every child).
     */
    fun stopRun(
        runId: String,
        reason: String? = null,
        expectedSessionTokens: Set<String>? = null,
    ) {
        val prefix = "$runId\u0000"
        for ((entryKey, child) in children.entries.toList()) {
            if (!entryKey.startsWith(prefix)) continue
            if (expectedSessionTokens != null &&
                !expectedSessionTokens.contains(child.sessionToken)
            ) {
                // This key holds a start the caller does not own: leave it.
                continue
            }
            if (removeIfCurrent(child)) kill(child, reason)
        }
    }

    /** Used when the foreground service is torn down: no run may outlive it. */
    fun stopAll(reason: String? = null): Int = stopAll(reason, bumpEpoch = true)

    private fun stopAll(reason: String?, bumpEpoch: Boolean): Int {
        if (bumpEpoch) {
            // A start that is still spawning when the teardown happens holds the
            // previous epoch: it will be refused instead of outliving the run.
            synchronized(lock) { epoch += 1 }
        }
        var stopped = 0
        for ((entryKey, child) in children.entries.toList()) {
            // Instance-scoped: whatever else moved into this key meanwhile is
            // not part of the state this teardown is draining.
            if (removeIfCurrent(child)) {
                kill(child, reason)
                stopped++
            }
        }
        return stopped
    }

    /**
     * Launch directories owned by live children, as native identities. The
     * sweep matches on identity (device:inode) instead of a path, so a renamed
     * or re-linked directory can never make it delete a live child's script.
     */
    fun liveLaunchIdentities(): Set<String> = children.values
        .mapNotNull { it.script?.identity }
        .toSet()

    internal fun activeCount(): Int = children.size

    private fun kill(child: Child, reason: String?) {
        if (child.finished) return
        // Publish the terminal event before any teardown work, so Dart settles
        // its pending request even when the child ignores every kill signal.
        child.terminateOnce(reason, child.exitCodeIfExited())
        try {
            child.process.outputStream?.close()
        } catch (_: Exception) {
            // stdin may already be closed; the kill below still applies.
        }
        try {
            if (child.process.isAlive) child.process.destroy()
        } catch (error: Exception) {
            Log.w(TAG, "MCP child destroy failed", error)
        }
        // The reap happens off the caller's thread: a foreground-service
        // teardown must not block the main thread while proot unwinds.
        Thread { reap(child) }
            .apply { isDaemon = true; name = "mcp-reap-${child.serverId}" }
            .start()
    }

    /** Gives proot a moment to run its --kill-on-exit path, then forces it. */
    private fun reap(child: Child) {
        try {
            if (!child.process.waitFor(REAP_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
                child.process.destroyForcibly()
            }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            child.process.destroyForcibly()
        } catch (error: Exception) {
            Log.w(TAG, "MCP child reap failed", error)
        }
        child.script?.let { ProcessManager.deleteMcpLaunchScript(it) }
    }
}