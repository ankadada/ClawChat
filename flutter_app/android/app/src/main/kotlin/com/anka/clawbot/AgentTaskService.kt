package com.anka.clawbot

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log

class AgentTaskService : Service() {
    companion object {
        const val NOTIFICATION_ID = 5
        private const val EXTRA_TEXT = "text"
        private const val DEFAULT_TEXT = "AI 正在执行任务..."
        private const val WAKE_LOCK_TIMEOUT_MS = 60 * 60 * 1000L
        private const val WAKE_LOCK_RENEWAL_MS = 55 * 60 * 1000L

        var isRunning = false
            private set

        fun start(context: Context, text: String = DEFAULT_TEXT) {
            val intent = Intent(context, AgentTaskService::class.java).apply {
                putExtra(EXTRA_TEXT, text.ifBlank { DEFAULT_TEXT })
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, AgentTaskService::class.java))
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var currentText = DEFAULT_TEXT
    private val wakeLockHandler = Handler(Looper.getMainLooper())
    private val renewWakeLock = object : Runnable {
        override fun run() {
            if (!isRunning) return
            acquireWakeLock()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        currentText = intent?.getStringExtra(EXTRA_TEXT)?.takeIf { it.isNotBlank() }
            ?: currentText
        startForeground(NOTIFICATION_ID, buildNotification(currentText))
        isRunning = true
        acquireWakeLock()
        return START_STICKY
    }

    override fun onDestroy() {
        isRunning = false
        wakeLockHandler.removeCallbacks(renewWakeLock)
        releaseWakeLock()
        super.onDestroy()
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

    @Suppress("DEPRECATION")
    private fun buildNotification(text: String): Notification {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, MainActivity.CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }

        return builder
            .setContentTitle("ClawChat")
            .setContentText(text)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setPriority(Notification.PRIORITY_LOW)
            .build()
    }
}
