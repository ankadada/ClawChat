package com.anka.clawbot

import android.Manifest
import android.animation.ObjectAnimator
import android.animation.ValueAnimator
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.text.TextUtils
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import io.flutter.plugin.common.MethodChannel
import androidx.core.content.ContextCompat
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

class AgentTaskService : Service() {
    companion object {
        private const val SUMMARY_NOTIFICATION_ID = 9999
        private const val AGENT_GROUP_KEY = "com.anka.clawbot.AGENT_GROUP"
        private const val EXTRA_TEXT = "text"
        private const val EXTRA_SESSION_ID = "sessionId"
        private const val EXTRA_SESSION_TITLE = "sessionTitle"
        private const val EXTRA_STATUS = "status"
        private const val EXTRA_PREVIEW = "previewText"
        private const val EXTRA_TOOL_NAME = "toolName"
        private const val EXTRA_OVERLAY_VISIBLE = "overlayVisible"
        private const val EXTRA_APPROVAL_ID = "approvalId"
        private const val EXTRA_APPROVAL_RISK = "approvalRisk"
        private const val EXTRA_APPROVED = "approved"
        private const val EXTRA_COMMAND_OPERATION_ID = "commandOperationId"
        private const val EXTRA_COMMAND_READY_REQUEST_ID = "commandReadyRequestId"
        private const val ACTION_UPDATE = "com.anka.clawbot.agent.UPDATE"
        private const val ACTION_STOP_AGENT = "com.anka.clawbot.agent.STOP"
        private const val ACTION_TOOL_APPROVAL_UPDATE = "com.anka.clawbot.agent.APPROVAL_UPDATE"
        private const val ACTION_TOOL_APPROVAL_DECISION = "com.anka.clawbot.agent.APPROVAL_DECISION"
        private const val DEFAULT_TEXT = "AI 正在执行任务..."
        private const val DEFAULT_STATUS = "thinking"
        private const val WAKE_LOCK_TIMEOUT_MS = 60 * 60 * 1000L
        private const val WAKE_LOCK_RENEWAL_MS = 55 * 60 * 1000L
        private const val NOTIFICATION_THROTTLE_MS = 500L
        private const val APPROVAL_DELIVERY_TIMEOUT_MS = 5_000L
        private const val OVERLAY_PREFS = "agent_overlay"
        private const val OVERLAY_PROMPTED = "overlay_prompted"
        private const val COMMAND_READY_TIMEOUT_SECONDS = 5L
        private const val COMMAND_DISPOSAL_RETRY_MS = 500L
        private const val COMMAND_CLEANUP_WAKE_LOCK_MS = 60_000L
        // This caps the caller-requested command runtime; it is not an orphan
        // grace period. Normal commands use BashTool's 120-second default.
        private const val MAX_REQUESTED_COMMAND_RUNTIME_MS = 12 * 60 * 60 * 1000L

        var isRunning = false
            private set

        private var instance: AgentTaskService? = null
        private val commandContinuations get() = NativeCommandContinuationOwner.registry
        @Volatile
        private var cleanupCoordinator: CommandCleanupCoordinator? = null

        internal fun initializeCleanupCoordinator(context: Context) {
            cleanupCoordinator = CommandCleanupCoordinatorProvider.get(context.applicationContext)
        }
        private val commandReadiness =
            ConcurrentHashMap<String, CompletableFuture<Boolean>>()
        private val callbackOwnership =
            ToolApprovalCallbackOwnership<MethodChannel>()

        fun attachCallbackChannel(channel: MethodChannel): Long {
            val attachment = callbackOwnership.attach(channel)
            val invalidated = attachment.invalidatedGeneration
            if (invalidated != null) {
                instance?.invalidateCallbackOwner(invalidated)
            }
            return attachment.owner.generation
        }

        fun detachCallbackChannel(channel: MethodChannel, generation: Long) {
            val invalidated = callbackOwnership.detach(channel, generation) ?: return
            instance?.invalidateCallbackOwner(invalidated)
        }

        fun start(
            context: Context,
            sessionId: String,
            sessionTitle: String,
            text: String = DEFAULT_TEXT
        ) {
            val intent = Intent(context, AgentTaskService::class.java).apply {
                putExtra(EXTRA_SESSION_ID, sessionId.ifBlank { "default" })
                putExtra(EXTRA_SESSION_TITLE, sessionTitle.ifBlank { "ClawChat" })
                putExtra(EXTRA_TEXT, text.ifBlank { DEFAULT_TEXT })
                putExtra(EXTRA_STATUS, DEFAULT_STATUS)
            }
            startServiceCompat(context, intent)
        }

        fun stop(context: Context) {
            val service = instance
            if (service != null) {
                service.retireAllBaseSessions()
            } else if (commandContinuations.activeCount(CommandContinuationOwner.AGENT_BASH) == 0) {
                context.stopService(Intent(context, AgentTaskService::class.java))
            }
        }

        fun updateNotification(
            context: Context,
            sessionId: String,
            sessionTitle: String,
            status: String,
            previewText: String,
            toolName: String?,
            overlayVisible: Boolean
        ) {
            val service = instance
            if (service != null) {
                service.updateAgentSessionState(
                    sessionId,
                    sessionTitle,
                    status,
                    previewText,
                    toolName,
                    overlayVisible
                )
                return
            }
            val intent = Intent(context, AgentTaskService::class.java).apply {
                action = ACTION_UPDATE
                putExtra(EXTRA_SESSION_ID, sessionId.ifBlank { "default" })
                putExtra(EXTRA_SESSION_TITLE, sessionTitle.ifBlank { "ClawChat" })
                putExtra(EXTRA_STATUS, status)
                putExtra(EXTRA_PREVIEW, previewText)
                putExtra(EXTRA_TOOL_NAME, toolName)
                putExtra(EXTRA_OVERLAY_VISIBLE, overlayVisible)
            }
            startServiceCompat(context, intent)
        }

        fun stopSession(context: Context, sessionId: String) {
            val service = instance
            if (service != null) {
                service.retireBaseSession(sessionId)
                return
            }
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.cancel(notificationIdFor(sessionId))
            manager.cancel(SUMMARY_NOTIFICATION_ID)
        }

        internal fun reserveCommand(
            sessionId: String,
            operationId: String,
            timeoutMs: Long,
        ): CommandReserveOutcome {
            val coordinator = cleanupCoordinator ?: return CommandReserveOutcome.RETRYABLE_UNKNOWN
            if (!coordinator.canAdmit(CommandContinuationOwner.AGENT_BASH, sessionId)) {
                return CommandReserveOutcome.RETRYABLE_UNKNOWN
            }
            return commandContinuations.reserve(
                commandKey(sessionId, operationId),
                timeoutMs.coerceIn(1L, MAX_REQUESTED_COMMAND_RUNTIME_MS),
            )
        }

        internal fun startReservedCommandAndAwaitReady(
            context: Context,
            sessionId: String,
            operationId: String,
        ): Boolean {
            val key = commandKey(sessionId, operationId)
            if (!commandContinuations.isActive(key)) return false
            val requestId = UUID.randomUUID().toString()
            val ready = CompletableFuture<Boolean>()
            commandReadiness[requestId] = ready
            val intent = Intent(context, AgentTaskService::class.java).apply {
                putExtra(EXTRA_SESSION_ID, key.sessionId)
                putExtra(EXTRA_SESSION_TITLE, "ClawChat")
                putExtra(EXTRA_TEXT, "命令正在后台运行...")
                putExtra(EXTRA_STATUS, "tooling")
                putExtra(EXTRA_TOOL_NAME, "bash")
                putExtra(EXTRA_COMMAND_OPERATION_ID, key.operationId)
                putExtra(EXTRA_COMMAND_READY_REQUEST_ID, requestId)
            }
            try {
                startServiceCompat(context, intent)
                val established = ready.get(COMMAND_READY_TIMEOUT_SECONDS, TimeUnit.SECONDS) == true
                if (!established) cancelCommand(sessionId, operationId)
                return established
            } catch (e: Exception) {
                cancelCommand(sessionId, operationId)
                Log.w("ClawChat", "Agent command foreground continuation failed", e)
                return false
            } finally {
                commandReadiness.remove(requestId)
            }
        }

        internal fun finishCommand(
            sessionId: String,
            operationId: String,
        ): CommandRetireOutcome {
            val retired = commandContinuations.finish(commandKey(sessionId, operationId))
            if (retired.outcome == CommandRetireOutcome.RETIRED ||
                retired.outcome == CommandRetireOutcome.ALREADY_RETIRED) {
                cleanupCoordinator?.complete(retired.key)
                instance?.onCommandKeyRetired(retired.key)
            } else if (retired.outcome == CommandRetireOutcome.RETRYABLE_UNKNOWN) {
                cleanupCoordinator?.requestCleanup(retired.key)
                instance?.scheduleCommandDisposalRetry()
            }
            return retired.outcome
        }

        internal fun cancelCommand(
            sessionId: String,
            operationId: String,
        ): CommandRetireOutcome {
            val key = commandKey(sessionId, operationId)
            val retired = commandContinuations.cancel(
                key,
                beforeSignal = { cleanupCoordinator?.requestCleanup(key) == true },
            )
            if (retired.outcome == CommandRetireOutcome.RETIRED ||
                retired.outcome == CommandRetireOutcome.ALREADY_RETIRED) {
                cleanupCoordinator?.complete(retired.key)
                instance?.onCommandKeyRetired(retired.key)
            } else if (retired.outcome == CommandRetireOutcome.RETRYABLE_UNKNOWN) {
                cleanupCoordinator?.requestCleanup(retired.key)
                instance?.scheduleCommandDisposalRetry()
            }
            return retired.outcome
        }

        internal fun commandKey(sessionId: String, operationId: String) =
            CommandOwnerKey(CommandContinuationOwner.AGENT_BASH, sessionId, operationId)

        internal fun coordinator(): CommandCleanupCoordinator? = cleanupCoordinator

        internal fun onCoordinatorCleanup(key: CommandOwnerKey) {
            instance?.onCommandKeyRetired(key)
        }

        private fun completeCommandReadiness(requestId: String?, ready: Boolean) {
            if (requestId == null) return
            commandReadiness.remove(requestId)?.complete(ready)
        }

        fun showToolApproval(
            context: Context,
            sessionId: String,
            sessionTitle: String,
            approvalId: String,
            toolName: String,
            risk: String
        ): Boolean {
            if (!canShowApprovalNotification(context)) return false
            val service = instance
            if (service != null) {
                service.showToolApproval(
                    sessionId,
                    sessionTitle,
                    approvalId,
                    toolName,
                    risk
                )
                return true
            }
            val intent = Intent(context, AgentTaskService::class.java).apply {
                action = ACTION_TOOL_APPROVAL_UPDATE
                putExtra(EXTRA_SESSION_ID, sessionId)
                putExtra(EXTRA_SESSION_TITLE, sessionTitle)
                putExtra(EXTRA_APPROVAL_ID, approvalId)
                putExtra(EXTRA_TOOL_NAME, toolName)
                putExtra(EXTRA_APPROVAL_RISK, risk)
                putExtra(EXTRA_STATUS, "tooling")
            }
            startServiceCompat(context, intent)
            return true
        }

        private fun canShowApprovalNotification(context: Context): Boolean {
            val permissionGranted = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
                ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.POST_NOTIFICATIONS
                ) == PackageManager.PERMISSION_GRANTED
            val manager = context.getSystemService(NotificationManager::class.java)
            val notificationsEnabled = Build.VERSION.SDK_INT < Build.VERSION_CODES.N ||
                manager.areNotificationsEnabled()
            val channel = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                manager.getNotificationChannel(MainActivity.CHANNEL_ID)
            } else {
                null
            }
            return ToolApprovalNotificationCapability.isVisible(
                permissionGranted = permissionGranted,
                notificationsEnabled = notificationsEnabled,
                channelExists = Build.VERSION.SDK_INT < Build.VERSION_CODES.O || channel != null,
                channelEnabled = Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                    channel?.importance != NotificationManager.IMPORTANCE_NONE
            )
        }

        fun clearToolApproval(sessionId: String, approvalId: String) {
            instance?.clearToolApproval(sessionId, approvalId)
        }

        fun showCompletionNotification(
            context: Context,
            sessionId: String,
            sessionTitle: String,
            summary: String
        ) {
            val manager = context.getSystemService(NotificationManager::class.java)
            val launchIntent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
            }
            val pendingIntent = PendingIntent.getActivity(
                context,
                3002,
                launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            val text = summary.ifBlank { "点击查看回复" }
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, MainActivity.AGENT_COMPLETE_CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }
            val notification = builder
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle("${sessionTitle.ifBlank { "ClawChat" }} - AI 任务完成")
                .setContentText(text)
                .setStyle(Notification.BigTextStyle().bigText(text))
                .setContentIntent(pendingIntent)
                .setAutoCancel(true)
                .setPriority(Notification.PRIORITY_HIGH)
                .setDefaults(Notification.DEFAULT_ALL)
                .build()
            manager.notify(completionNotificationIdFor(sessionId), notification)
        }

        fun hasOverlayPermission(context: Context): Boolean {
            return Settings.canDrawOverlays(context)
        }

        fun requestOverlayPermissionIfNeeded(context: Context): Boolean {
            if (Settings.canDrawOverlays(context)) return true
            val prefs = context.getSharedPreferences(OVERLAY_PREFS, Context.MODE_PRIVATE)
            if (prefs.getBoolean(OVERLAY_PROMPTED, false)) return false
            prefs.edit().putBoolean(OVERLAY_PROMPTED, true).apply()
            return try {
                val intent = overlaySettingsIntent(context).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                context.startActivity(intent)
                true
            } catch (e: Exception) {
                Log.w("ClawChat", "Open overlay settings failed", e)
                false
            }
        }

        fun setOverlayVisible(context: Context, visible: Boolean) {
            instance?.setOverlayVisible(visible)
        }

        private fun startServiceCompat(context: Context, intent: Intent) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        private fun overlaySettingsIntent(context: Context): Intent {
            val packageUri = Uri.parse("package:${context.packageName}")
            val candidates = listOf(
                Intent("miui.intent.action.APP_PERM_EDITOR").apply {
                    setClassName(
                        "com.miui.securitycenter",
                        "com.miui.permcenter.permissions.PermissionsEditorActivity"
                    )
                    putExtra("extra_pkgname", context.packageName)
                },
                Intent("miui.intent.action.APP_PERM_EDITOR").apply {
                    setClassName(
                        "com.miui.securitycenter",
                        "com.miui.permcenter.permissions.AppPermissionsEditorActivity"
                    )
                    putExtra("extra_pkgname", context.packageName)
                },
                Intent().apply {
                    setClassName(
                        "com.huawei.systemmanager",
                        "com.huawei.permissionmanager.ui.MainActivity"
                    )
                },
                Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, packageUri)
            )
            return candidates.firstOrNull {
                it.resolveActivity(context.packageManager) != null
            } ?: Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, packageUri)
        }

        private fun requestStopFromNotification(sessionId: String?) {
            callbackOwnership.current?.value?.invokeMethod(
                "onAgentStopRequested",
                sessionId?.let { mapOf("sessionId" to it) }
            )
        }

        private fun notificationIdFor(sessionId: String): Int {
            return (sessionId.hashCode() and 0x7FFFFFFF) % 100000 + 10000
        }

        private fun completionNotificationIdFor(sessionId: String): Int {
            return (sessionId.hashCode() and 0x7FFFFFFF) % 100000 + 110000
        }
    }

    private data class AgentSessionNotification(
        val sessionId: String,
        var sessionTitle: String,
        var status: String,
        var preview: String,
        var toolName: String?,
        val notificationId: Int,
        var approval: ToolApprovalNotificationState? = null
    )

    private var wakeLock: PowerManager.WakeLock? = null
    private var retiringNormally = false
    private val activeSessions = mutableMapOf<String, AgentSessionNotification>()
    private var foregroundSessionId: String? = null
    private var overlaySessionId: String? = null
    private var overlayShouldBeVisible = false
    private val retiredBaseSessions = mutableSetOf<String>()
    private val commandOnlySessions = mutableSetOf<String>()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val wakeLockHandler = Handler(Looper.getMainLooper())
    private val pendingNotificationSessionIds = mutableSetOf<String>()
    private var lastNotificationUpdateMs = 0L
    private var notificationUpdateScheduled = false
    private var overlay: AgentIslandOverlay? = null
    private val expireCommandContinuations = Runnable {
        commandContinuations.expire(
            CommandContinuationOwner.AGENT_BASH,
            beforeSignal = { key, _ -> cleanupCoordinator?.requestCleanup(key) == true },
        )
            .forEach(::onCommandKeyRetired)
        commandContinuations.retryPending(CommandContinuationOwner.AGENT_BASH)
            .forEach(::onCommandKeyRetired)
        if (commandContinuations.hasPendingRetirement(CommandContinuationOwner.AGENT_BASH)) {
            scheduleCommandDisposalRetry()
        } else {
            scheduleNextCommandTimeout()
        }
    }
    private val renewWakeLock = object : Runnable {
        override fun run() {
            if (!isRunning) return
            acquireWakeLock()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        cleanupCoordinator = CommandCleanupCoordinatorProvider.get(applicationContext)
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            clearAllSessionNotifications()
            stopSelf()
            return START_NOT_STICKY
        }
        retiringNormally = false
        if (intent?.action == ACTION_STOP_AGENT) {
            val sessionId = intent.getStringExtra(EXTRA_SESSION_ID)
            if (!sessionId.isNullOrBlank()) {
                commandContinuations.cancelSession(
                    CommandContinuationOwner.AGENT_BASH,
                    sessionId,
                    beforeSignal = { key, _ ->
                        cleanupCoordinator?.requestCleanup(key) == true
                    },
                ).forEach(::onCommandKeyRetired)
                commandContinuations.activeKeys(CommandContinuationOwner.AGENT_BASH)
                    .filter { it.sessionId == sessionId }
                    .forEach {
                        cleanupCoordinator?.requestCleanup(it)
                    }
                if (commandContinuations.hasSession(
                        CommandContinuationOwner.AGENT_BASH,
                        sessionId,
                    )) {
                    scheduleCommandDisposalRetry()
                } else {
                    removeSessionNotification(sessionId)
                }
            }
            requestStopFromNotification(sessionId)
            mainHandler.postDelayed({
                if (activeSessions.isEmpty()) stopSelfNormally()
            }, 1000)
            return START_NOT_STICKY
        }
        if (intent?.action?.startsWith(ACTION_TOOL_APPROVAL_DECISION) == true) {
            handleToolApprovalDecision(intent)
            return START_NOT_STICKY
        }

        val fallbackText = intent?.getStringExtra(EXTRA_TEXT)?.takeIf { it.isNotBlank() }
            ?: DEFAULT_TEXT
        val sessionId = intent?.getStringExtra(EXTRA_SESSION_ID)?.takeIf { it.isNotBlank() }
            ?: "default"
        val sessionTitle = intent?.getStringExtra(EXTRA_SESSION_TITLE)?.takeIf { it.isNotBlank() }
            ?: "ClawChat"
        val status = intent?.getStringExtra(EXTRA_STATUS) ?: statusFromText(fallbackText)
        val preview = intent?.getStringExtra(EXTRA_PREVIEW) ?: ""
        val toolName = intent?.getStringExtra(EXTRA_TOOL_NAME)?.takeIf { it.isNotBlank() }
        overlayShouldBeVisible = intent?.getBooleanExtra(EXTRA_OVERLAY_VISIBLE, overlayShouldBeVisible)
            ?: overlayShouldBeVisible
        val commandOperationId = intent.getStringExtra(EXTRA_COMMAND_OPERATION_ID)
        val commandReadyRequestId = intent.getStringExtra(EXTRA_COMMAND_READY_REQUEST_ID)
        if (commandOperationId == null) {
            commandOnlySessions.remove(sessionId)
        } else if (!activeSessions.containsKey(sessionId)) {
            commandOnlySessions.add(sessionId)
        }
        val state = upsertAgentSessionState(sessionId, sessionTitle, status, preview, toolName)
        if (intent?.action == ACTION_TOOL_APPROVAL_UPDATE) {
            val approvalId = intent.getStringExtra(EXTRA_APPROVAL_ID)
            val approvalRisk = intent.getStringExtra(EXTRA_APPROVAL_RISK)
            if (!approvalId.isNullOrBlank() && !toolName.isNullOrBlank() && !approvalRisk.isNullOrBlank()) {
                state.approval = ToolApprovalNotificationState(
                    sessionId = state.sessionId,
                    approvalId = approvalId,
                    toolName = toolName,
                    risk = approvalRisk
                )
            }
        }

        return try {
            if (!isRunning || foregroundSessionId == null) {
                foregroundSessionId = state.sessionId
                startForeground(state.notificationId, buildNotification(state))
            } else {
                val manager = getSystemService(NotificationManager::class.java)
                manager.notify(state.notificationId, buildNotification(state))
            }
            isRunning = activeSessions.isNotEmpty()
            acquireWakeLock()
            val commandReady = commandOperationId == null ||
                (wakeLock?.isHeld == true &&
                    canShowApprovalNotification(this) &&
                    commandContinuations.isActive(
                        commandKey(sessionId, commandOperationId)
                    ))
            completeCommandReadiness(commandReadyRequestId, commandReady)
            if (!commandReady && commandOperationId != null) {
                cancelCommand(sessionId, commandOperationId)
                if (commandOnlySessions.remove(sessionId)) {
                    removeSessionNotification(sessionId)
                }
            }
            if (commandContinuations.hasPendingRetirement(
                    CommandContinuationOwner.AGENT_BASH
                )) {
                scheduleCommandDisposalRetry()
            } else {
                scheduleNextCommandTimeout()
            }
            updateSummaryNotification()
            updateOverlay()
            START_NOT_STICKY
        } catch (e: Exception) {
            if (commandOperationId != null) {
                cancelCommand(sessionId, commandOperationId)
            }
            completeCommandReadiness(commandReadyRequestId, false)
            Log.e("ClawChat", "Unable to establish agent foreground continuation", e)
            retireBaseSession(sessionId)
            START_NOT_STICKY
        }
    }

    override fun onDestroy() {
        val pendingCleanup = if (!retiringNormally) {
            val before = commandContinuations.activeKeys(CommandContinuationOwner.AGENT_BASH)
            commandContinuations.destroyOwner(
                CommandContinuationOwner.AGENT_BASH,
                beforeSignal = { key, _ -> cleanupCoordinator?.requestCleanup(key) == true },
            )
            val pending = commandContinuations.activeKeys(CommandContinuationOwner.AGENT_BASH)
            for (key in before) {
                if (key in pending) {
                    cleanupCoordinator?.requestCleanup(key)
                } else {
                    cleanupCoordinator?.complete(key)
                }
            }
            pending
        } else {
            emptyList()
        }
        clearAllSessionNotifications()
        isRunning = false
        instance = null
        mainHandler.removeCallbacksAndMessages(null)
        mainHandler.removeCallbacks(expireCommandContinuations)
        wakeLockHandler.removeCallbacks(renewWakeLock)
        hideOverlay()
        releaseWakeLock()
        restartPendingCommandCleanup(pendingCleanup)
        super.onDestroy()
    }

    private fun restartPendingCommandCleanup(keys: List<CommandOwnerKey>) {
        for (key in keys) {
            val intent = Intent(applicationContext, AgentTaskService::class.java).apply {
                putExtra(EXTRA_SESSION_ID, key.sessionId)
                putExtra(EXTRA_SESSION_TITLE, "ClawChat")
                putExtra(EXTRA_TEXT, "命令清理中...")
                putExtra(EXTRA_STATUS, "tooling")
                putExtra(EXTRA_TOOL_NAME, "bash")
                putExtra(EXTRA_COMMAND_OPERATION_ID, key.operationId)
            }
            try {
                startServiceCompat(applicationContext, intent)
            } catch (e: Exception) {
                // The registry keeps the exact process owner pending; a later
                // service/runtime reconciliation retries without false dispose.
                Log.w("ClawChat", "Unable to restart pending command cleanup", e)
            }
        }
    }


    private fun updateAgentSessionState(
        sessionId: String,
        sessionTitle: String,
        status: String,
        previewText: String,
        toolName: String?,
        overlayVisible: Boolean
    ) {
        val state = upsertAgentSessionState(
            sessionId,
            sessionTitle,
            status,
            previewText,
            toolName
        )
        overlayShouldBeVisible = overlayVisible
        if (!isRunning || foregroundSessionId == null) {
            foregroundSessionId = state.sessionId
            startForeground(state.notificationId, buildNotification(state))
            isRunning = true
            acquireWakeLock()
            updateSummaryNotification()
        } else {
            scheduleNotificationUpdate(state.sessionId)
        }
        updateOverlay()
    }

    private fun showToolApproval(
        sessionId: String,
        sessionTitle: String,
        approvalId: String,
        toolName: String,
        risk: String
    ) {
        val state = upsertAgentSessionState(
            sessionId,
            sessionTitle,
            "tooling",
            "",
            toolName
        )
        state.approval?.let { cancelApprovalPendingIntents(it) }
        state.approval = ToolApprovalNotificationState(
            sessionId = state.sessionId,
            approvalId = approvalId,
            toolName = toolName,
            risk = risk
        )
        if (!isRunning || foregroundSessionId == null) {
            foregroundSessionId = state.sessionId
            startForeground(state.notificationId, buildNotification(state))
            isRunning = true
            acquireWakeLock()
        } else {
            val manager = getSystemService(NotificationManager::class.java)
            manager.notify(state.notificationId, buildNotification(state))
        }
        updateSummaryNotification()
    }

    private fun clearToolApproval(sessionId: String, approvalId: String) {
        val state = activeSessions[sessionId] ?: return
        if (state.approval?.approvalId != approvalId) return
        state.approval?.let { cancelApprovalPendingIntents(it) }
        state.approval = null
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(state.notificationId, buildNotification(state))
    }

    private fun handleToolApprovalDecision(intent: Intent) {
        val sessionId = intent.getStringExtra(EXTRA_SESSION_ID) ?: return
        val approvalId = intent.getStringExtra(EXTRA_APPROVAL_ID) ?: return
        val approved = intent.getBooleanExtra(EXTRA_APPROVED, false)
        val state = activeSessions[sessionId] ?: return
        val approval = state.approval ?: return
        val owner = callbackOwnership.current ?: return
        if (!approval.beginDecision(sessionId, approvalId, owner.generation)) return
        getSystemService(NotificationManager::class.java)
            .notify(state.notificationId, buildNotification(state))
        val timeout = Runnable {
            if (approval.deliveryFailed(owner.generation)) {
                getSystemService(NotificationManager::class.java)
                    .notify(state.notificationId, buildNotification(state))
            }
        }
        mainHandler.postDelayed(timeout, APPROVAL_DELIVERY_TIMEOUT_MS)
        try {
            owner.value.invokeMethod(
                "onToolApprovalDecision",
                mapOf(
                    "sessionId" to sessionId,
                    "approvalId" to approvalId,
                    "approved" to approved
                ),
                object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        mainHandler.removeCallbacks(timeout)
                        val ownerStillCurrent =
                            callbackOwnership.current?.generation == owner.generation
                        val acknowledged = ownerStillCurrent &&
                            result == true &&
                            approval.acknowledge(owner.generation)
                        if (acknowledged && state.approval === approval) {
                            cancelApprovalPendingIntents(approval)
                            state.approval = null
                        } else {
                            approval.deliveryFailed(owner.generation)
                        }
                        getSystemService(NotificationManager::class.java)
                            .notify(state.notificationId, buildNotification(state))
                    }

                    override fun error(code: String, message: String?, details: Any?) {
                        failDelivery()
                    }

                    override fun notImplemented() {
                        failDelivery()
                    }

                    private fun failDelivery() {
                        mainHandler.removeCallbacks(timeout)
                        if (approval.deliveryFailed(owner.generation)) {
                            getSystemService(NotificationManager::class.java)
                                .notify(state.notificationId, buildNotification(state))
                        }
                    }
                }
            )
        } catch (_: Throwable) {
            mainHandler.removeCallbacks(timeout)
            if (approval.deliveryFailed(owner.generation)) {
                getSystemService(NotificationManager::class.java)
                    .notify(state.notificationId, buildNotification(state))
            }
        }
    }

    private fun invalidateCallbackOwner(generation: Long) {
        for (state in activeSessions.values) {
            val approval = state.approval ?: continue
            if (approval.deliveryFailed(generation)) {
                getSystemService(NotificationManager::class.java)
                    .notify(state.notificationId, buildNotification(state))
            }
        }
    }

    private fun approvalDecisionIntent(
        approval: ToolApprovalNotificationState,
        approved: Boolean
    ): Intent {
        val identity = ToolApprovalPendingIntentIdentity.create(
            ACTION_TOOL_APPROVAL_DECISION,
            approval.sessionId,
            approval.approvalId,
            approved
        )
        return Intent(this, AgentTaskService::class.java).apply {
            action = identity.action
            data = Uri.parse(identity.data)
            setPackage(packageName)
            putExtra(EXTRA_SESSION_ID, approval.sessionId)
            putExtra(EXTRA_APPROVAL_ID, approval.approvalId)
            putExtra(EXTRA_APPROVED, approved)
        }
    }

    private fun approvalPendingIntent(
        approval: ToolApprovalNotificationState,
        approved: Boolean
    ): PendingIntent = PendingIntent.getService(
        this,
        0,
        approvalDecisionIntent(approval, approved),
        PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_IMMUTABLE
    )

    private fun cancelApprovalPendingIntents(
        approval: ToolApprovalNotificationState
    ) {
        for (approved in listOf(false, true)) {
            PendingIntent.getService(
                this,
                0,
                approvalDecisionIntent(approval, approved),
                PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE
            )?.cancel()
        }
    }

    private fun upsertAgentSessionState(
        sessionId: String,
        sessionTitle: String,
        status: String,
        previewText: String,
        toolName: String?
    ): AgentSessionNotification {
        val normalizedSessionId = sessionId.ifBlank { "default" }
        val state = activeSessions.getOrPut(normalizedSessionId) {
            AgentSessionNotification(
                sessionId = normalizedSessionId,
                sessionTitle = sessionTitle.ifBlank { "ClawChat" },
                status = status,
                preview = "",
                toolName = null,
                notificationId = notificationIdFor(normalizedSessionId)
            )
        }
        state.sessionTitle = sessionTitle.ifBlank { state.sessionTitle.ifBlank { "ClawChat" } }
        state.status = status
        state.preview = previewText.takeLast(220)
        state.toolName = toolName?.takeIf { it.isNotBlank() }
        overlaySessionId = state.sessionId
        return state
    }

    private fun setOverlayVisible(visible: Boolean) {
        overlayShouldBeVisible = visible
        updateOverlay()
    }

    private fun scheduleNotificationUpdate(sessionId: String) {
        pendingNotificationSessionIds.add(sessionId)
        val now = System.currentTimeMillis()
        val elapsed = now - lastNotificationUpdateMs
        if (elapsed >= NOTIFICATION_THROTTLE_MS) {
            updateNotificationNow()
            return
        }
        if (notificationUpdateScheduled) return
        notificationUpdateScheduled = true
        mainHandler.postDelayed({
            notificationUpdateScheduled = false
            updateNotificationNow()
        }, NOTIFICATION_THROTTLE_MS - elapsed)
    }

    private fun updateNotificationNow() {
        lastNotificationUpdateMs = System.currentTimeMillis()
        val manager = getSystemService(NotificationManager::class.java)
        val sessionIds = pendingNotificationSessionIds.toList().ifEmpty {
            activeSessions.keys.toList()
        }
        pendingNotificationSessionIds.clear()
        for (sessionId in sessionIds) {
            val state = activeSessions[sessionId] ?: continue
            manager.notify(state.notificationId, buildNotification(state))
        }
        updateSummaryNotification()
    }

    private fun statusFromText(text: String): String {
        return when {
            text.contains("思考") -> "thinking"
            text.contains("执行") -> "tooling"
            text.contains("生成") || text.contains("回复") -> "streaming"
            else -> DEFAULT_STATUS
        }
    }

    private fun statusTitle(state: AgentSessionNotification): String {
        val statusText = when (state.status) {
            "thinking" -> "AI 正在思考..."
            "streaming" -> "AI 正在回复..."
            "tooling" -> if (state.toolName.isNullOrBlank()) {
                "AI 正在执行工具..."
            } else {
                "AI 正在执行工具: ${state.toolName}..."
            }
            "complete" -> "AI 任务完成"
            "error" -> "AI 任务出错"
            else -> "AI 正在执行任务..."
        }
        return "${state.sessionTitle} - $statusText"
    }

    private fun compactPreview(state: AgentSessionNotification, limit: Int = 100): String {
        return state.preview.replace(Regex("\\s+"), " ").trim().takeLast(limit)
            .ifBlank { statusTitle(state) }
    }

    @Suppress("DEPRECATION")
    private fun buildNotification(state: AgentSessionNotification): Notification {
        val openIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
        }
        val openPendingIntent = PendingIntent.getActivity(
            this,
            state.notificationId,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val stopIntent = Intent(this, AgentTaskService::class.java).apply {
            action = ACTION_STOP_AGENT
            putExtra(EXTRA_SESSION_ID, state.sessionId)
        }
        val stopPendingIntent = PendingIntent.getService(
            this,
            state.notificationId + 1,
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val approval = state.approval
        val approvePendingIntent = approval?.let { approvalPendingIntent(it, true) }
        val denyPendingIntent = approval?.let { approvalPendingIntent(it, false) }

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, MainActivity.CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }

        val ongoing = state.status != "complete" && state.status != "error"
        val preview = when {
            approval?.decisionInFlight == true -> "正在提交工具审批决定..."
            approval != null -> "${approval.toolName} (${approval.risk}) 等待你的明确批准"
            else -> compactPreview(state)
        }
        builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(statusTitle(state))
            .setContentText(preview)
            .setStyle(Notification.BigTextStyle().bigText(state.preview.ifBlank { preview }))
            .setContentIntent(openPendingIntent)
            .setOngoing(ongoing)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setPriority(Notification.PRIORITY_LOW)
            .setGroup(AGENT_GROUP_KEY)
        if (approval == null) {
            builder.addAction(R.mipmap.ic_launcher, "查看", openPendingIntent)
        }
        if (ongoing && approval == null) {
            builder
                .addAction(R.mipmap.ic_launcher, "停止", stopPendingIntent)
                .setProgress(0, 0, state.status == "thinking")
        }
        if (approval != null && !approval.decisionInFlight &&
            approvePendingIntent != null && denyPendingIntent != null) {
            builder
                .addAction(R.mipmap.ic_launcher, "拒绝", denyPendingIntent)
                .addAction(R.mipmap.ic_launcher, "允许一次", approvePendingIntent)
                .addAction(R.mipmap.ic_launcher, "停止", stopPendingIntent)
        }
        return builder.build()
    }

    @Suppress("DEPRECATION")
    private fun updateSummaryNotification() {
        val manager = getSystemService(NotificationManager::class.java)
        if (activeSessions.size <= 1) {
            manager.cancel(SUMMARY_NOTIFICATION_ID)
            return
        }
        val title = "${activeSessions.size} 个 AI 任务运行中"
        val text = activeSessions.values.joinToString(", ") { it.sessionTitle }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, MainActivity.CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
        val notification = builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setGroup(AGENT_GROUP_KEY)
            .setGroupSummary(true)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setPriority(Notification.PRIORITY_LOW)
            .build()
        manager.notify(SUMMARY_NOTIFICATION_ID, notification)
    }

    private fun retireBaseSession(sessionId: String) {
        if (commandContinuations.hasSession(CommandContinuationOwner.AGENT_BASH, sessionId)) {
            retiredBaseSessions.add(sessionId)
            activeSessions[sessionId]?.let { state ->
                state.status = "tooling"
                state.preview = "命令正在后台运行..."
                state.toolName = "bash"
                val manager = getSystemService(NotificationManager::class.java)
                manager.notify(state.notificationId, buildNotification(state))
            }
            return
        }
        removeSessionNotification(sessionId)
    }

    private fun retireAllBaseSessions() {
        for (sessionId in activeSessions.keys.toList()) {
            retireBaseSession(sessionId)
        }
        if (activeSessions.isEmpty()) hideOverlay()
    }

    private fun onCommandKeyRetired(key: CommandOwnerKey) {
        if (key.owner != CommandContinuationOwner.AGENT_BASH) return
        cleanupCoordinator?.complete(key)
        if ((retiredBaseSessions.contains(key.sessionId) ||
                commandOnlySessions.contains(key.sessionId)) &&
            !commandContinuations.hasSession(CommandContinuationOwner.AGENT_BASH, key.sessionId)) {
            retiredBaseSessions.remove(key.sessionId)
            commandOnlySessions.remove(key.sessionId)
            removeSessionNotification(key.sessionId)
        }
        scheduleNextCommandTimeout()
    }

    private fun scheduleNextCommandTimeout() {
        mainHandler.removeCallbacks(expireCommandContinuations)
        val deadline = commandContinuations.nextDeadlineEpochMs(
            CommandContinuationOwner.AGENT_BASH
        ) ?: return
        mainHandler.postDelayed(
            expireCommandContinuations,
            if (deadline <= System.currentTimeMillis()) COMMAND_DISPOSAL_RETRY_MS
            else deadline - System.currentTimeMillis(),
        )
    }

    private fun scheduleCommandDisposalRetry() {
        mainHandler.removeCallbacks(expireCommandContinuations)
        acquireWakeLock(COMMAND_CLEANUP_WAKE_LOCK_MS, scheduleRenewal = false)
        mainHandler.postDelayed(expireCommandContinuations, COMMAND_DISPOSAL_RETRY_MS)
    }

    private fun removeSessionNotification(sessionId: String) {
        if (commandContinuations.hasSession(CommandContinuationOwner.AGENT_BASH, sessionId)) {
            retiredBaseSessions.add(sessionId)
            return
        }
        val state = activeSessions.remove(sessionId) ?: return
        state.approval?.let { cancelApprovalPendingIntents(it) }
        pendingNotificationSessionIds.remove(sessionId)
        if (overlaySessionId == sessionId) {
            overlaySessionId = activeSessions.keys.lastOrNull()
        }
        val manager = getSystemService(NotificationManager::class.java)
        val nextState = activeSessions.values.firstOrNull()
        if (foregroundSessionId == sessionId) {
            if (nextState != null) {
                foregroundSessionId = nextState.sessionId
                startForeground(nextState.notificationId, buildNotification(nextState))
            } else {
                foregroundSessionId = null
            }
        }
        manager.cancel(state.notificationId)
        updateSummaryNotification()
        isRunning = activeSessions.isNotEmpty()
        updateOverlay()
        if (activeSessions.isEmpty()) {
            hideOverlay()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
            releaseWakeLock()
            stopSelfNormally()
        }
    }

    private fun stopSelfNormally() {
        retiringNormally = true
        stopSelf()
    }

    private fun clearAllSessionNotifications() {
        val manager = getSystemService(NotificationManager::class.java)
        for (state in activeSessions.values) {
            state.approval?.let { cancelApprovalPendingIntents(it) }
            manager.cancel(state.notificationId)
        }
        manager.cancel(SUMMARY_NOTIFICATION_ID)
        activeSessions.clear()
        retiredBaseSessions.clear()
        commandOnlySessions.clear()
        pendingNotificationSessionIds.clear()
        foregroundSessionId = null
        overlaySessionId = null
        isRunning = false
    }

    private fun updateOverlay() {
        val activeList = activeSessions.values.filter { it.status != "error" }
        if (!overlayShouldBeVisible || activeList.isEmpty()) {
            hideOverlay()
            return
        }
        if (!Settings.canDrawOverlays(this)) {
            hideOverlay()
            return
        }
        try {
            if (overlay == null) {
                overlay = AgentIslandOverlay(this)
            }
            overlay?.showOrUpdate(activeList)
        } catch (e: Exception) {
            Log.w("ClawChat", "Agent overlay update failed", e)
            hideOverlay()
        }
    }

    private fun hideOverlay() {
        try {
            overlay?.hide()
        } catch (e: Exception) {
            Log.w("ClawChat", "Agent overlay hide failed", e)
        }
        overlay = null
    }

    private fun acquireWakeLock(
        timeoutMs: Long = WAKE_LOCK_TIMEOUT_MS,
        scheduleRenewal: Boolean = true,
    ) {
        releaseWakeLock()
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "ClawChat::AgentTaskWakeLock"
        )
        wakeLock?.acquire(timeoutMs)
        wakeLockHandler.removeCallbacks(renewWakeLock)
        if (isRunning && scheduleRenewal) {
            wakeLockHandler.postDelayed(renewWakeLock, WAKE_LOCK_RENEWAL_MS)
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let {
            if (it.isHeld) {
                try {
                    it.release()
                } catch (e: Exception) {
                    Log.w("ClawChat", "AgentTask wake lock release failed", e)
                }
            }
        }
        wakeLock = null
    }

    private class AgentIslandOverlay(private val context: Context) {
        private val windowManager =
            context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        private val root = LinearLayout(context)
        private val headerRow = LinearLayout(context)
        private val titleView = TextView(context)
        private val previewView = TextView(context)
        private val progress = ProgressBar(context)
        private val handler = Handler(Looper.getMainLooper())
        private var layoutParams: WindowManager.LayoutParams? = null
        private var added = false
        private var expanded = false
        private var lastStatus: String? = null
        private var currentStatus: String? = null
        private var breathing: ObjectAnimator? = null
        private var carouselIndex = 0
        private var carouselTimer: Runnable? = null
        private var collapseTimer: Runnable? = null
        private var currentSessions: List<AgentSessionNotification> = emptyList()

        private val islandWidth = dp(200)
        private val collapsedHeight = dp(36)
        private val collapsedCornerRadius = dp(18).toFloat()
        private val carouselIntervalMs = 3000L

        init {
            root.orientation = LinearLayout.VERTICAL
            root.gravity = Gravity.CENTER_VERTICAL
            root.setPadding(dp(14), dp(7), dp(14), dp(7))
            root.background = roundedBackground(Color.BLACK, collapsedCornerRadius)
            root.elevation = dp(8).toFloat()

            headerRow.orientation = LinearLayout.HORIZONTAL
            headerRow.gravity = Gravity.CENTER
            progress.isIndeterminate = true
            headerRow.addView(progress, LinearLayout.LayoutParams(dp(16), dp(16)))

            titleView.setTextColor(Color.WHITE)
            titleView.textSize = 13f
            titleView.typeface = Typeface.DEFAULT_BOLD
            titleView.maxLines = 1
            titleView.ellipsize = TextUtils.TruncateAt.END
            titleView.gravity = Gravity.CENTER_VERTICAL
            headerRow.addView(
                titleView,
                LinearLayout.LayoutParams(
                    0,
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    1f
                ).apply {
                    leftMargin = dp(8)
                }
            )

            previewView.setTextColor(Color.argb(220, 255, 255, 255))
            previewView.textSize = 12f
            previewView.maxLines = 2
            previewView.visibility = View.GONE
            previewView.setPadding(0, dp(8), 0, 0)

            root.addView(
                headerRow,
                LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                )
            )
            root.addView(
                previewView,
                LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                )
            )

            root.setOnClickListener {
                val sessions = currentSessions
                if (sessions.isNotEmpty()) {
                    val current = sessions[carouselIndex % sessions.size]
                    openApp(current.sessionId)
                } else {
                    openApp()
                }
            }
        }

        fun showOrUpdate(sessions: List<AgentSessionNotification>) {
            if (sessions.isEmpty()) {
                hide()
                return
            }
            currentSessions = sessions
            if (carouselIndex >= currentSessions.size) carouselIndex = 0
            val current = currentSessions[carouselIndex]
            val statusKey = "${current.sessionId}:${current.status}"
            val statusChanged = lastStatus != statusKey
            lastStatus = statusKey
            currentStatus = current.status
            val indicator = if (currentSessions.size > 1) {
                "[${carouselIndex + 1}/${currentSessions.size}] "
            } else {
                ""
            }
            titleView.text = indicator + compactTitle(current.status, current.sessionTitle)
            previewView.text = current.preview
            progress.visibility = if (current.status == "complete") View.GONE else View.VISIBLE
            headerRow.gravity = if (expanded) Gravity.CENTER_VERTICAL else Gravity.CENTER
            root.background = roundedBackground(
                if (current.status == "complete") Color.rgb(37, 99, 235)
                else Color.BLACK,
                if (expanded) dp(22).toFloat() else collapsedCornerRadius
            )
            if (!added) add()
            updateAnimation(current.status)
            if (current.status == "complete") {
                expand()
                if (currentSessions.size == 1) {
                    handler.postDelayed({ hide() }, 2000)
                }
            } else if (statusChanged && current.preview.isNotBlank()) {
                expand()
            }
            scheduleCarousel()
        }

        fun hide() {
            handler.removeCallbacksAndMessages(null)
            carouselTimer = null
            collapseTimer = null
            carouselIndex = 0
            currentSessions = emptyList()
            breathing?.cancel()
            breathing = null
            previewView.animate().cancel()
            expanded = false
            lastStatus = null
            currentStatus = null
            previewView.visibility = View.GONE
            headerRow.gravity = Gravity.CENTER
            root.setPadding(dp(14), dp(7), dp(14), dp(7))
            root.background = roundedBackground(Color.BLACK, collapsedCornerRadius)
            if (!added) return
            try {
                windowManager.removeView(root)
            } catch (_: Exception) {
            } finally {
                added = false
            }
        }

        private fun add() {
            val params = WindowManager.LayoutParams(
                islandWidth,
                collapsedHeight,
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT
            ).apply {
                gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
                y = getCutoutTopPosition()
            }
            layoutParams = params
            windowManager.addView(root, params)
            added = true
        }

        private fun expand() {
            expanded = true
            layoutParams?.let {
                it.height = WindowManager.LayoutParams.WRAP_CONTENT
                try {
                    windowManager.updateViewLayout(root, it)
                } catch (_: Exception) {
                }
            }
            headerRow.gravity = Gravity.CENTER_VERTICAL
            previewView.animate().cancel()
            previewView.alpha = 0f
            previewView.visibility = View.VISIBLE
            root.setPadding(dp(18), dp(12), dp(18), dp(14))
            root.background = roundedBackground(
                if (currentStatus == "complete") Color.rgb(37, 99, 235) else Color.BLACK,
                dp(22).toFloat()
            )
            collapseTimer?.let { handler.removeCallbacks(it) }
            previewView.animate().alpha(1f).setDuration(200).start()
            val runnable = Runnable { collapse() }
            collapseTimer = runnable
            handler.postDelayed(runnable, carouselIntervalMs)
        }

        private fun collapse() {
            expanded = false
            previewView.animate().cancel()
            previewView.animate().alpha(0f).setDuration(200).withEndAction {
                previewView.visibility = View.GONE
                headerRow.gravity = Gravity.CENTER
                root.setPadding(dp(14), dp(7), dp(14), dp(7))
                root.background = roundedBackground(
                    if (currentStatus == "complete") Color.rgb(37, 99, 235) else Color.BLACK,
                    collapsedCornerRadius
                )
                layoutParams?.let {
                    it.height = collapsedHeight
                    try {
                        windowManager.updateViewLayout(root, it)
                    } catch (_: Exception) {
                    }
                }
            }.start()
        }

        private fun updateAnimation(status: String) {
            breathing?.cancel()
            breathing = null
            progress.alpha = 1f
            if (status == "thinking") {
                breathing = ObjectAnimator.ofFloat(progress, View.ALPHA, 0.35f, 1f).apply {
                    duration = 800
                    repeatMode = ValueAnimator.REVERSE
                    repeatCount = ValueAnimator.INFINITE
                    start()
                }
            }
        }

        private fun compactTitle(status: String, title: String): String {
            val sessionTitle = title.ifBlank { "ClawChat" }
            val suffix = when (status) {
                "thinking" -> "思考中..."
                "streaming" -> "回复中..."
                "tooling" -> "工具中..."
                "complete" -> "完成"
                else -> "运行中..."
            }
            return "$sessionTitle $suffix"
        }

        private fun scheduleCarousel() {
            carouselTimer?.let { handler.removeCallbacks(it) }
            carouselTimer = null
            if (currentSessions.size <= 1 || !added) return
            val runnable = Runnable {
                if (currentSessions.isNotEmpty()) {
                    carouselIndex = (carouselIndex + 1) % currentSessions.size
                    showOrUpdate(currentSessions)
                }
            }
            carouselTimer = runnable
            handler.postDelayed(runnable, carouselIntervalMs)
        }

        private fun openApp(sessionId: String? = null) {
            val intent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
                if (sessionId != null) {
                    putExtra("navigateToSession", sessionId)
                }
            }
            context.startActivity(intent)
        }

        private fun getCutoutTopPosition(): Int {
            val centeredY = (getStatusBarHeight() - collapsedHeight) / 2
            return maxOf(centeredY, 0)
        }

        private fun getStatusBarHeight(): Int {
            val resourceId = context.resources.getIdentifier(
                "status_bar_height",
                "dimen",
                "android"
            )
            return if (resourceId > 0) {
                context.resources.getDimensionPixelSize(resourceId)
            } else {
                dp(24)
            }
        }

        private fun roundedBackground(color: Int, radius: Float): GradientDrawable {
            return GradientDrawable().apply {
                setColor(color)
                cornerRadius = radius
            }
        }

        private fun dp(value: Int): Int {
            return (value * context.resources.displayMetrics.density).toInt()
        }
    }
}
