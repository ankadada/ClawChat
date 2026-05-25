package com.anka.clawbot

import android.animation.ObjectAnimator
import android.animation.ValueAnimator
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
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
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import io.flutter.plugin.common.MethodChannel

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
        private const val ACTION_UPDATE = "com.anka.clawbot.agent.UPDATE"
        private const val ACTION_STOP_AGENT = "com.anka.clawbot.agent.STOP"
        private const val DEFAULT_TEXT = "AI 正在执行任务..."
        private const val DEFAULT_STATUS = "thinking"
        private const val WAKE_LOCK_TIMEOUT_MS = 60 * 60 * 1000L
        private const val WAKE_LOCK_RENEWAL_MS = 55 * 60 * 1000L
        private const val NOTIFICATION_THROTTLE_MS = 500L
        private const val OVERLAY_PREFS = "agent_overlay"
        private const val OVERLAY_PROMPTED = "overlay_prompted"

        var isRunning = false
            private set

        private var instance: AgentTaskService? = null
        private var callbackChannel: MethodChannel? = null

        fun setCallbackChannel(channel: MethodChannel) {
            callbackChannel = channel
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
            instance?.clearAllSessionNotifications()
            instance?.hideOverlay()
            context.stopService(Intent(context, AgentTaskService::class.java))
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
                service.removeSessionNotification(sessionId)
                return
            }
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.cancel(notificationIdFor(sessionId))
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
            callbackChannel?.invokeMethod(
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
        val notificationId: Int
    )

    private var wakeLock: PowerManager.WakeLock? = null
    private val activeSessions = mutableMapOf<String, AgentSessionNotification>()
    private var foregroundSessionId: String? = null
    private var overlaySessionId: String? = null
    private var overlayShouldBeVisible = false
    private val mainHandler = Handler(Looper.getMainLooper())
    private val wakeLockHandler = Handler(Looper.getMainLooper())
    private val pendingNotificationSessionIds = mutableSetOf<String>()
    private var lastNotificationUpdateMs = 0L
    private var notificationUpdateScheduled = false
    private var overlay: AgentIslandOverlay? = null
    private val renewWakeLock = object : Runnable {
        override fun run() {
            if (!isRunning) return
            acquireWakeLock()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP_AGENT) {
            val sessionId = intent.getStringExtra(EXTRA_SESSION_ID)
            requestStopFromNotification(sessionId)
            mainHandler.postDelayed({
                if (activeSessions.isEmpty()) stopSelf()
            }, 1000)
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
        val state = upsertAgentSessionState(sessionId, sessionTitle, status, preview, toolName)

        if (!isRunning || foregroundSessionId == null) {
            foregroundSessionId = state.sessionId
            startForeground(state.notificationId, buildNotification(state))
        } else {
            val manager = getSystemService(NotificationManager::class.java)
            manager.notify(state.notificationId, buildNotification(state))
        }
        isRunning = activeSessions.isNotEmpty()
        acquireWakeLock()
        updateSummaryNotification()
        updateOverlay()
        return START_STICKY
    }

    override fun onDestroy() {
        clearAllSessionNotifications()
        isRunning = false
        instance = null
        mainHandler.removeCallbacksAndMessages(null)
        wakeLockHandler.removeCallbacks(renewWakeLock)
        hideOverlay()
        releaseWakeLock()
        super.onDestroy()
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

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, MainActivity.CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }

        val ongoing = state.status != "complete" && state.status != "error"
        val preview = compactPreview(state)
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
            .addAction(R.mipmap.ic_launcher, "查看", openPendingIntent)
        if (ongoing) {
            builder
                .addAction(R.mipmap.ic_launcher, "停止", stopPendingIntent)
                .setProgress(0, 0, state.status == "thinking")
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

    private fun removeSessionNotification(sessionId: String) {
        val state = activeSessions.remove(sessionId) ?: return
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
            stopSelf()
        }
    }

    private fun clearAllSessionNotifications() {
        val manager = getSystemService(NotificationManager::class.java)
        for (state in activeSessions.values) {
            manager.cancel(state.notificationId)
        }
        manager.cancel(SUMMARY_NOTIFICATION_ID)
        activeSessions.clear()
        pendingNotificationSessionIds.clear()
        foregroundSessionId = null
        overlaySessionId = null
        isRunning = false
    }

    private fun updateOverlay() {
        val state = overlaySessionId?.let { activeSessions[it] } ?: activeSessions.values.lastOrNull()
        if (!overlayShouldBeVisible || state == null || state.status == "error") {
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
            overlay?.showOrUpdate(state.status, statusTitle(state), compactPreview(state, 140))
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

    private fun acquireWakeLock() {
        releaseWakeLock()
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "ClawChat::AgentTaskWakeLock"
        )
        wakeLock?.acquire(WAKE_LOCK_TIMEOUT_MS)
        wakeLockHandler.removeCallbacks(renewWakeLock)
        if (isRunning) {
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
        private var breathing: ObjectAnimator? = null

        private val islandWidth = dp(200)
        private val collapsedHeight = dp(36)
        private val collapsedCornerRadius = dp(18).toFloat()

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
            titleView.gravity = Gravity.CENTER_VERTICAL
            headerRow.addView(
                titleView,
                LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
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
                openApp()
            }
        }

        fun showOrUpdate(status: String, title: String, preview: String) {
            val statusChanged = lastStatus != status
            lastStatus = status
            titleView.text = compactTitle(status, title)
            previewView.text = preview
            progress.visibility = if (status == "complete") View.GONE else View.VISIBLE
            headerRow.gravity = if (expanded) Gravity.CENTER_VERTICAL else Gravity.CENTER
            root.background = roundedBackground(
                if (status == "complete") Color.rgb(37, 99, 235)
                else Color.BLACK,
                if (expanded) dp(22).toFloat() else collapsedCornerRadius
            )
            if (!added) add()
            updateAnimation(status)
            if (status == "complete") {
                expand()
                handler.postDelayed({ hide() }, 2000)
            } else if (statusChanged && preview.isNotBlank()) {
                expand()
            }
        }

        fun hide() {
            handler.removeCallbacksAndMessages(null)
            breathing?.cancel()
            breathing = null
            previewView.animate().cancel()
            expanded = false
            lastStatus = null
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
                if (lastStatus == "complete") Color.rgb(37, 99, 235) else Color.BLACK,
                dp(22).toFloat()
            )
            handler.removeCallbacksAndMessages(null)
            previewView.animate().alpha(1f).setDuration(200).start()
            handler.postDelayed({ collapse() }, 3000)
        }

        private fun collapse() {
            expanded = false
            previewView.animate().cancel()
            previewView.animate().alpha(0f).setDuration(200).withEndAction {
                previewView.visibility = View.GONE
                headerRow.gravity = Gravity.CENTER
                root.setPadding(dp(14), dp(7), dp(14), dp(7))
                root.background = roundedBackground(
                    if (lastStatus == "complete") Color.rgb(37, 99, 235) else Color.BLACK,
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
            return when (status) {
                "thinking" -> "思考中..."
                "streaming" -> "回复中..."
                "tooling" -> title.replace("AI 正在", "")
                "complete" -> "完成"
                else -> title
            }
        }

        private fun openApp() {
            val intent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
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
