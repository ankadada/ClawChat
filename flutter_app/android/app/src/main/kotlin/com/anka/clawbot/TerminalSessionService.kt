package com.anka.clawbot

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import androidx.core.content.ContextCompat
import java.io.File
import java.io.FileNotFoundException
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

internal fun terminalSessionAdmissionReason(
    coordinator: CommandCleanupCoordinator?,
    sessionId: String,
): CommandAdmissionReason {
    coordinator ?: return CommandAdmissionReason.COORDINATOR_UNAVAILABLE
    val cleanupAccepted = coordinator.requestSessionCleanup(
        CommandContinuationOwner.TERMINAL,
        sessionId,
    )
    val admission = coordinator.admissionReason(
        CommandContinuationOwner.TERMINAL,
        sessionId,
    )
    return if (!cleanupAccepted && admission == CommandAdmissionReason.ADMITTED) {
        CommandAdmissionReason.CLEANUP_REJECTED
    } else {
        admission
    }
}

class TerminalSessionService : Service() {
    companion object {
        private const val CHANNEL_ID = "clawchat_terminal"
        private const val ACTION_START = "com.anka.clawbot.terminal.START"
        private const val ACTION_HELPER_START = "com.anka.clawbot.terminal.HELPER_START"
        private const val ACTION_STOP = "com.anka.clawbot.terminal.STOP"
        private const val EXTRA_OPERATION_ID = "operationId"
        private const val EXTRA_SESSION_ID = "sessionId"
        private const val EXTRA_CANDIDATE_ID = "candidateId"
        private const val EXTRA_READY_REQUEST_ID = "readyRequestId"
        private const val READY_TIMEOUT_SECONDS = 5L
        private const val DISPOSAL_RETRY_MS = 500L
        private const val CLEANUP_WAKE_LOCK_HOLD_MS = 60_000L
        private const val MAX_TERMINAL_TIMEOUT_MS = 30 * 60 * 1000L
        const val NOTIFICATION_ID = 2

        private val owner get() = NativeCommandContinuationOwner.registry
        @Volatile
        private var cleanupCoordinator: CommandCleanupCoordinator? = null
        @Volatile
        private var helperRequested = false

        internal fun initializeCleanupCoordinator(coordinator: CommandCleanupCoordinator?) {
            cleanupCoordinator = coordinator
        }
        private val readiness = ConcurrentHashMap<String, CompletableFuture<Boolean>>()
        private var instance: TerminalSessionService? = null

        @Volatile
        var isRunning = false
            private set

        fun startHelper(context: Context) {
            helperRequested = true
            val intent = Intent(context, TerminalSessionService::class.java).apply {
                action = ACTION_HELPER_START
            }
            try {
                startServiceCompat(context, intent)
            } catch (error: Exception) {
                helperRequested = false
                throw error
            }
        }

        fun stopHelper(context: Context) {
            helperRequested = false
            if (owner.activeCount(CommandContinuationOwner.TERMINAL) == 0) {
                instance?.retireForegroundSynchronously()
                    ?: context.stopService(Intent(context, TerminalSessionService::class.java))
            }
        }

        internal fun replaceSession(
            operationId: String,
            sessionId: String,
            candidateId: String,
            timeoutMs: Long,
        ): TerminalSessionReplacementResult {
            val key = terminalKey(operationId, sessionId)
            val coordinator = cleanupCoordinator
            val admission = terminalSessionAdmissionReason(coordinator, sessionId)
            if (admission != CommandAdmissionReason.ADMITTED) {
                return TerminalSessionReplacementResult(
                    CommandReserveOutcome.RETRYABLE_UNKNOWN,
                    TerminalCandidateKey(key, candidateId),
                    reason = admission,
                )
            }
            val result = owner.replaceTerminalSession(
                key,
                candidateId,
                timeoutMs.coerceIn(1L, MAX_TERMINAL_TIMEOUT_MS),
            )
            if (result.retiredCandidates.isNotEmpty()) {
                instance?.retireForegroundForReplacement()
            } else if (result.outcome == CommandReserveOutcome.RETRYABLE_UNKNOWN) {
                instance?.scheduleDisposalRetry()
            }
            return result
        }

        internal fun startReservedAndAwaitReady(
            context: Context,
            operationId: String,
            sessionId: String,
            candidateId: String,
        ): Boolean {
            val key = terminalKey(operationId, sessionId)
            if (!owner.isActiveCandidate(key, candidateId)) return false
            val requestId = UUID.randomUUID().toString()
            val ready = CompletableFuture<Boolean>()
            readiness[requestId] = ready
            val intent = Intent(context, TerminalSessionService::class.java).apply {
                action = ACTION_START
                putExactCandidate(TerminalCandidateKey(key, candidateId))
                putExtra(EXTRA_READY_REQUEST_ID, requestId)
            }
            try {
                startServiceCompat(context, intent)
                val established = ready.get(READY_TIMEOUT_SECONDS, TimeUnit.SECONDS) == true
                if (!established) cancel(operationId, sessionId, candidateId)
                return established
            } catch (e: Exception) {
                cancel(operationId, sessionId, candidateId)
                Log.w("ClawChat", "Terminal foreground continuation failed", e)
                return false
            } finally {
                readiness.remove(requestId)
            }
        }

        internal fun attachProcess(
            operationId: String,
            sessionId: String,
            candidateId: String,
            attemptId: String,
            launchToken: String,
            processId: Int,
        ): CandidateReceipt {
            if (processId <= 0) return CandidateReceipt.CONFLICT
            val key = terminalKey(operationId, sessionId)
            if (!owner.isActiveCandidate(key, candidateId)) return CandidateReceipt.CONFLICT
            val coordinator = cleanupCoordinator ?: return CandidateReceipt.UNKNOWN
            var token: PidGenerationToken? = null
            for (attempt in 0 until 50) {
                token = coordinator.activateWaitingLaunch(
                    key,
                    candidateId,
                    attemptId,
                    launchToken,
                    processId,
                    AndroidCleanupPidAccess.probe,
                )
                if (token != null) break
                Thread.sleep(20L)
            }
            val activeToken = token ?: return CandidateReceipt.UNKNOWN
            val process = PidOwnedCommandProcess.fromGeneration(
                activeToken.processId,
                activeToken.startTimeTicks,
                AndroidCleanupPidAccess.probe,
                AndroidCleanupPidAccess.signaler,
            )
            val receipt = owner.attachTerminal(
                key,
                candidateId,
                process,
                beforeNativeOwnership = {
                    coordinator.isActiveLaunch(
                        key,
                        candidateId,
                        attemptId,
                        launchToken,
                        activeToken,
                    )
                },
                beforeSignal = { coordinator.requestCleanup(key, candidateId) },
            )
            if (receipt == CandidateReceipt.NATIVE_OWNS) {
                if (coordinator.releaseLaunch(
                        key,
                        candidateId,
                        attemptId,
                        launchToken,
                        activeToken,
                    )) return receipt
                owner.cancelTerminal(
                    key,
                    candidateId,
                    beforeSignal = { coordinator.requestCleanup(key, candidateId) },
                )
                return CandidateReceipt.UNKNOWN
            }
            if (receipt != CandidateReceipt.CALLER_OWNS) {
                coordinator.requestCleanup(key, candidateId)
            }
            return receipt
        }

        internal fun prepareLaunch(
            operationId: String,
            sessionId: String,
            candidateId: String,
        ): CommandLaunchPreparation {
            val key = terminalKey(operationId, sessionId)
            val deadline = owner.deadlineEpochMs(key)
                ?: return CommandLaunchPreparation(
                    DurableLaunchRegistrationOutcome.FAILED_OR_CORRUPT,
                    CommandLaunchFailureReason.STALE_EXACT_RECORD,
                )
            return cleanupCoordinator?.prepareLaunch(key, candidateId, deadline)
                ?: CommandLaunchPreparation(
                    DurableLaunchRegistrationOutcome.FAILED_OR_CORRUPT,
                    CommandLaunchFailureReason.COORDINATOR_UNAVAILABLE,
                )
        }

        internal fun validateLaunchCapability(
            operationId: String,
            sessionId: String,
            candidateId: String,
            attemptId: String,
            launchToken: String,
        ): Boolean = cleanupCoordinator?.validateLaunchCapability(
            terminalKey(operationId, sessionId),
            candidateId,
            attemptId,
            launchToken,
        ) == true

        internal fun acknowledgeLaunchAbandoned(
            operationId: String,
            sessionId: String,
            candidateId: String,
            attemptId: String,
            launchToken: String,
        ): Boolean = cleanupCoordinator?.acknowledgeLaunchAbandoned(
            terminalKey(operationId, sessionId),
            candidateId,
            attemptId,
            launchToken,
        ) == true

        internal fun candidateReceipt(
            operationId: String,
            sessionId: String,
            candidateId: String,
            processId: Int,
        ): CandidateReceipt = if (processId <= 0) {
            CandidateReceipt.CONFLICT
        } else {
            owner.terminalReceipt(
                terminalKey(operationId, sessionId),
                candidateId,
                PidOwnedCommandProcess.currentToken(processId, AndroidCleanupPidAccess.probe),
                beforeSignal = {
                    cleanupCoordinator?.requestCleanup(
                        terminalKey(operationId, sessionId),
                        candidateId,
                    ) == true
                },
            )
        }

        internal fun isCurrent(
            operationId: String,
            sessionId: String,
            candidateId: String,
        ): Boolean = owner.isActiveCandidate(terminalKey(operationId, sessionId), candidateId)

        internal fun disposeCandidate(
            operationId: String,
            sessionId: String,
            candidateId: String,
            processId: Int,
        ): CandidateReceipt {
            if (processId <= 0) return CandidateReceipt.CONFLICT
            val process = PidOwnedCommandProcess.create(
                processId,
                AndroidCleanupPidAccess.probe,
                AndroidCleanupPidAccess.signaler,
            )
                ?: return CandidateReceipt.UNKNOWN
            val outcome = owner.disposeTerminalCandidate(
                terminalKey(operationId, sessionId),
                candidateId,
                process,
                beforeSignal = {
                    cleanupCoordinator?.requestCleanup(
                        terminalKey(operationId, sessionId),
                        candidateId,
                    ) == true
                },
            )
            if (outcome == CandidateReceipt.NATIVE_DISPOSED) {
                cleanupCoordinator?.requestCleanup(
                    terminalKey(operationId, sessionId), candidateId,
                )
                instance?.retireIfIdle()
            } else if (outcome == CandidateReceipt.CALLER_OWNS) {
                instance?.retireIfIdle()
            } else if (outcome == CandidateReceipt.UNKNOWN) {
                cleanupCoordinator?.requestCleanup(
                    terminalKey(operationId, sessionId),
                    candidateId,
                )
                instance?.scheduleDisposalRetry()
            }
            return outcome
        }

        internal fun finish(
            operationId: String,
            sessionId: String,
            candidateId: String,
        ): CandidateReceipt {
            val receipt = owner.finishTerminal(
                terminalKey(operationId, sessionId),
                candidateId,
            )
            if (receipt != CandidateReceipt.CONFLICT && receipt != CandidateReceipt.UNKNOWN) {
                cleanupCoordinator?.requestCleanup(
                    terminalKey(operationId, sessionId), candidateId,
                )
                instance?.retireIfIdle()
            } else if (receipt == CandidateReceipt.UNKNOWN) {
                cleanupCoordinator?.requestCleanup(
                    terminalKey(operationId, sessionId),
                    candidateId,
                )
                instance?.scheduleDisposalRetry()
            }
            return receipt
        }

        internal fun cancel(
            operationId: String,
            sessionId: String,
            candidateId: String,
        ): CandidateReceipt {
            val key = terminalKey(operationId, sessionId)
            val receipt = owner.cancelTerminal(
                key,
                candidateId,
                beforeSignal = {
                    cleanupCoordinator?.requestCleanup(key, candidateId) == true
                },
            )
            if (receipt == CandidateReceipt.NATIVE_DISPOSED) {
                cleanupCoordinator?.requestCleanup(
                    terminalKey(operationId, sessionId), candidateId,
                )
                instance?.retireIfIdle()
            } else if (receipt == CandidateReceipt.CALLER_OWNS) {
                instance?.retireIfIdle()
            } else if (receipt == CandidateReceipt.UNKNOWN) {
                cleanupCoordinator?.requestCleanup(
                    terminalKey(operationId, sessionId),
                    candidateId,
                )
                instance?.scheduleDisposalRetry()
            }
            return receipt
        }

        internal fun acknowledgeFinalReceipt(
            operationId: String,
            sessionId: String,
            candidateId: String,
            expectedReceipt: CandidateReceipt,
        ): CandidateReceipt {
            val key = terminalKey(operationId, sessionId)
            val receipt = owner.acknowledgeFinalReceipt(
                key,
                candidateId,
                expectedReceipt,
            )
            if (receipt == expectedReceipt) {
                cleanupCoordinator?.requestCleanup(key, candidateId)
                cleanupCoordinator?.reconcile()
            }
            return receipt
        }

        fun stop(context: Context, sessionId: String) {
            val candidates = owner.activeTerminalCandidates().filter {
                it.ownerKey.sessionId == sessionId
            }
            owner.cancelSession(
                CommandContinuationOwner.TERMINAL,
                sessionId,
                beforeSignal = { key, candidateId ->
                    candidateId != null &&
                        cleanupCoordinator?.requestCleanup(key, candidateId) == true
                },
            )
            for (candidate in candidates) {
                if (owner.isActiveCandidate(candidate.ownerKey, candidate.candidateId)) {
                    cleanupCoordinator?.requestCleanup(
                        candidate.ownerKey,
                        candidate.candidateId,
                    )
                } else {
                    cleanupCoordinator?.complete(
                        candidate.ownerKey,
                        candidate.candidateId,
                    )
                }
            }
            val service = instance
            if (owner.hasSession(CommandContinuationOwner.TERMINAL, sessionId)) {
                service?.scheduleDisposalRetry()
            } else {
                service?.retireForegroundSynchronously()
                    ?: context.stopService(Intent(context, TerminalSessionService::class.java))
            }
        }

        private fun terminalKey(operationId: String, sessionId: String) =
            CommandOwnerKey(CommandContinuationOwner.TERMINAL, sessionId, operationId)

        private fun Intent.putExactCandidate(candidate: TerminalCandidateKey) {
            putExtra(EXTRA_OPERATION_ID, candidate.ownerKey.operationId)
            putExtra(EXTRA_SESSION_ID, candidate.ownerKey.sessionId)
            putExtra(EXTRA_CANDIDATE_ID, candidate.candidateId)
        }

        private fun Intent.exactCandidateOrNull(): TerminalCandidateKey? {
            val operationId = getStringExtra(EXTRA_OPERATION_ID)?.takeIf { it.isNotBlank() }
                ?: return null
            val sessionId = getStringExtra(EXTRA_SESSION_ID)?.takeIf { it.isNotBlank() }
                ?: return null
            val candidateId = getStringExtra(EXTRA_CANDIDATE_ID)?.takeIf { it.isNotBlank() }
                ?: return null
            return TerminalCandidateKey(terminalKey(operationId, sessionId), candidateId)
        }

        private fun startServiceCompat(context: Context, intent: Intent) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        private fun completeReadiness(requestId: String?, ready: Boolean) {
            if (requestId == null) return
            readiness.remove(requestId)?.complete(ready)
        }

        internal fun onCoordinatorCleanup() {
            instance?.retireIfIdle()
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var retiringNormally = false
    private val timeoutHandler = Handler(Looper.getMainLooper())
    private val expireContinuations = Runnable {
        owner.expire(
            CommandContinuationOwner.TERMINAL,
            beforeSignal = { key, candidateId ->
                candidateId != null && cleanupCoordinator?.requestCleanup(key, candidateId) == true
            },
        )
        owner.retryPending(CommandContinuationOwner.TERMINAL)
        if (owner.activeCount(CommandContinuationOwner.TERMINAL) == 0) {
            retireForegroundSynchronously()
        } else if (owner.hasPendingRetirement(CommandContinuationOwner.TERMINAL)) {
            scheduleDisposalRetry()
        } else {
            scheduleNextTimeout()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        cleanupCoordinator = cleanupCoordinator ?: runCatching {
            CommandCleanupCoordinatorProvider.get(applicationContext)
        }.getOrNull()
        instance = this
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        retiringNormally = false
        val candidate = intent?.exactCandidateOrNull()
        val requestId = intent?.getStringExtra(EXTRA_READY_REQUEST_ID)
        if (intent?.action == ACTION_HELPER_START) {
            return try {
                startForeground(NOTIFICATION_ID, buildNotification(null))
                acquireWakeLock()
                isRunning = wakeLock?.isHeld == true
                START_STICKY
            } catch (e: Exception) {
                Log.w("ClawChat", "Unable to start terminal helper service", e)
                helperRequested = false
                isRunning = false
                releaseWakeLock()
                stopSelf()
                START_NOT_STICKY
            }
        }
        if (intent?.action == ACTION_STOP) {
            if (candidate != null) {
                val key = candidate.ownerKey
                cancel(key.operationId, key.sessionId, candidate.candidateId)
            }
            retireIfIdle()
            return START_NOT_STICKY
        }
        if (intent?.action != ACTION_START || candidate == null ||
            !owner.isActiveCandidate(candidate.ownerKey, candidate.candidateId)) {
            completeReadiness(requestId, false)
            retireIfIdle()
            return START_NOT_STICKY
        }
        val key = candidate.ownerKey
        return try {
            startForeground(NOTIFICATION_ID, buildNotification(candidate))
            acquireWakeLock()
            isRunning = wakeLock?.isHeld == true && hasVisibleNotification()
            completeReadiness(requestId, isRunning)
            if (!isRunning) {
                cancel(key.operationId, key.sessionId, candidate.candidateId)
                retireIfIdle()
            } else if (owner.hasPendingRetirement(CommandContinuationOwner.TERMINAL)) {
                scheduleDisposalRetry()
            } else {
                scheduleNextTimeout()
            }
            START_NOT_STICKY
        } catch (e: Exception) {
            cancel(key.operationId, key.sessionId, candidate.candidateId)
            completeReadiness(requestId, false)
            Log.e("ClawChat", "Unable to establish terminal foreground continuation", e)
            retireIfIdle()
            START_NOT_STICKY
        }
    }

    override fun onDestroy() {
        timeoutHandler.removeCallbacks(expireContinuations)
        val pendingCleanup = if (!retiringNormally) {
            val before = owner.activeTerminalCandidates()
            owner.destroyOwner(
                CommandContinuationOwner.TERMINAL,
                beforeSignal = { key, candidateId ->
                    candidateId != null &&
                        cleanupCoordinator?.requestCleanup(key, candidateId) == true
                },
            )
            val pending = owner.activeTerminalCandidates()
            for (candidate in before) {
                if (candidate in pending) {
                    cleanupCoordinator?.requestCleanup(
                        candidate.ownerKey,
                        candidate.candidateId,
                    )
                } else {
                    cleanupCoordinator?.complete(
                        candidate.ownerKey,
                        candidate.candidateId,
                    )
                }
            }
            pending
        } else {
            emptyList()
        }
        isRunning = false
        helperRequested = false
        instance = null
        releaseWakeLock()
        for (candidate in pendingCleanup) {
            restartPendingCleanup(candidate)
        }
        super.onDestroy()
    }

    private fun retireIfIdle() {
        if (owner.activeCount(CommandContinuationOwner.TERMINAL) == 0 && !helperRequested) {
            retireForegroundSynchronously()
        } else {
            scheduleNextTimeout()
        }
    }

    private fun retireForegroundSynchronously() {
        retiringNormally = true
        timeoutHandler.removeCallbacks(expireContinuations)
        getSystemService(NotificationManager::class.java).cancel(NOTIFICATION_ID)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        isRunning = false
        releaseWakeLock()
        stopSelf()
    }

    private fun retireForegroundForReplacement() {
        timeoutHandler.removeCallbacks(expireContinuations)
        getSystemService(NotificationManager::class.java).cancel(NOTIFICATION_ID)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        isRunning = false
        releaseWakeLock()
    }

    private fun scheduleNextTimeout() {
        timeoutHandler.removeCallbacks(expireContinuations)
        val deadline = owner.nextDeadlineEpochMs(CommandContinuationOwner.TERMINAL) ?: return
        if (deadline <= System.currentTimeMillis()) {
            scheduleDisposalRetry()
            return
        }
        timeoutHandler.postDelayed(
            expireContinuations,
            deadline - System.currentTimeMillis(),
        )
    }

    private fun scheduleDisposalRetry() {
        timeoutHandler.removeCallbacks(expireContinuations)
        renewCleanupWakeLock()
        timeoutHandler.postDelayed(expireContinuations, DISPOSAL_RETRY_MS)
    }

    private fun renewCleanupWakeLock() {
        if (wakeLock?.isHeld == true) releaseWakeLock()
        acquireWakeLock(CLEANUP_WAKE_LOCK_HOLD_MS)
    }

    private fun acquireWakeLock(timeoutMs: Long = MAX_TERMINAL_TIMEOUT_MS) {
        if (wakeLock?.isHeld == true) return
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "ClawChat::TerminalWakeLock",
        ).apply {
            setReferenceCounted(false)
            acquire(timeoutMs)
        }
    }

    private fun restartPendingCleanup(candidate: TerminalCandidateKey) {
        val intent = Intent(applicationContext, TerminalSessionService::class.java).apply {
            action = ACTION_START
            putExactCandidate(candidate)
        }
        try {
            startServiceCompat(applicationContext, intent)
        } catch (e: Exception) {
            // Registry ownership remains truthful. A later runtime/service
            // reconciliation will resume the same exact candidate cleanup.
            Log.w("ClawChat", "Unable to restart pending terminal cleanup", e)
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let {
            if (it.isHeld) {
                try {
                    it.release()
                } catch (e: Exception) {
                    Log.w("ClawChat", "Terminal wake lock release failed", e)
                }
            }
        }
        wakeLock = null
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "ClawChat Terminal",
                NotificationManager.IMPORTANCE_LOW,
            ).apply { description = "Terminal session active" }
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    private fun hasVisibleNotification(): Boolean {
        val permissionGranted = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED
        val manager = getSystemService(NotificationManager::class.java)
        val notificationsEnabled = Build.VERSION.SDK_INT < Build.VERSION_CODES.N ||
            manager.areNotificationsEnabled()
        val channelEnabled = Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            manager.getNotificationChannel(CHANNEL_ID)?.importance !=
            NotificationManager.IMPORTANCE_NONE
        return permissionGranted && notificationsEnabled && channelEnabled
    }

    @Suppress("DEPRECATION")
    private fun buildNotification(candidate: TerminalCandidateKey?): Notification {
        val openIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
        }
        val openPendingIntent = PendingIntent.getActivity(
            this,
            0,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
        builder
            .setContentTitle("ClawChat Terminal")
            .setContentText("Terminal session is active in the background")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(openPendingIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setPriority(Notification.PRIORITY_LOW)
        if (candidate != null) {
            val stopIntent = Intent(this, TerminalSessionService::class.java).apply {
                action = ACTION_STOP
                putExactCandidate(candidate)
            }
            val stopPendingIntent = PendingIntent.getService(
                this,
                candidate.hashCode(),
                stopIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            builder.addAction(R.mipmap.ic_launcher, "停止", stopPendingIntent)
        }
        return builder.build()
    }
}
