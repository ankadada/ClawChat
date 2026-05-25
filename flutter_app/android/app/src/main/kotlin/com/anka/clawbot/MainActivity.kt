package com.anka.clawbot

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.BatteryManager
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import android.app.Activity
import android.content.Context
import android.os.Environment
import android.util.Log
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.speech.RecognizerIntent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.anka.clawbot/native"

    private lateinit var bootstrapManager: BootstrapManager
    private lateinit var processManager: ProcessManager
    private lateinit var phoneIntentManager: PhoneIntentManager
    private val setupDone = java.util.concurrent.atomic.AtomicBoolean(false)
    private var pendingSpeechResult: MethodChannel.Result? = null
    private var mediaRecorder: MediaRecorder? = null
    private var recordingPath: String? = null
    private var mediaPlayer: MediaPlayer? = null

    private fun safeRunOnUiThread(action: () -> Unit) {
        if (isDestroyed || isFinishing) return
        runOnUiThread {
            if (!isDestroyed && !isFinishing) action()
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val filesDir = applicationContext.filesDir.absolutePath
        val nativeLibDir = applicationContext.applicationInfo.nativeLibraryDir

        bootstrapManager = BootstrapManager(applicationContext, filesDir, nativeLibDir)
        processManager = ProcessManager(filesDir, nativeLibDir)
        phoneIntentManager = PhoneIntentManager(this)

        if (setupDone.compareAndSet(false, true)) {
            // Keep bootstrap preflight on a plain background thread to avoid
            // adding lifecycle coroutine dependencies for this small startup task.
            Thread {
                try { bootstrapManager.setupDirectories() } catch (e: Exception) { Log.e("ClawChat", "setupDirectories failed", e) }
                try { bootstrapManager.writeResolvConf() } catch (e: Exception) { Log.e("ClawChat", "writeResolvConf failed", e) }
            }.start()
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getProotPath" -> result.success(processManager.getProotPath())
                "getArch" -> result.success(ArchUtils.getArch())
                "getFilesDir" -> result.success(filesDir)
                "getNativeLibDir" -> result.success(nativeLibDir)
                "isBootstrapComplete" -> result.success(bootstrapManager.isBootstrapComplete())
                "getBootstrapStatus" -> result.success(bootstrapManager.getBootstrapStatus())
                "extractRootfs" -> {
                    val tarPath = call.argument<String>("tarPath")
                    if (tarPath != null) {
                        Thread {
                            try {
                                bootstrapManager.extractRootfs(tarPath)
                                safeRunOnUiThread { result.success(true) }
                            } catch (e: Exception) {
                                safeRunOnUiThread { result.error("EXTRACT_ERROR", e.message, null) }
                            }
                        }.start()
                    } else {
                        result.error("INVALID_ARGS", "tarPath required", null)
                    }
                }
                "runInProot" -> {
                    val command = call.argument<String>("command")
                    val timeout = call.argument<Int>("timeout")?.toLong() ?: 900L
                    val mountStorage = call.argument<Boolean>("mountStorage") ?: false
                    if (command != null) {
                        Thread {
                            try {
                                val output = processManager.runInProotSync(
                                    command,
                                    timeout,
                                    mountStorage
                                )
                                safeRunOnUiThread { result.success(output) }
                            } catch (e: Exception) {
                                safeRunOnUiThread { result.error("PROOT_ERROR", e.message, null) }
                            }
                        }.start()
                    } else {
                        result.error("INVALID_ARGS", "command required", null)
                    }
                }
                "startTerminalService" -> {
                    try {
                        TerminalSessionService.start(applicationContext)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SERVICE_ERROR", e.message, null)
                    }
                }
                "stopTerminalService" -> {
                    try {
                        TerminalSessionService.stop(applicationContext)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SERVICE_ERROR", e.message, null)
                    }
                }
                "isTerminalServiceRunning" -> result.success(TerminalSessionService.isRunning)
                "startAgentService" -> {
                    try {
                        AgentTaskService.start(
                            applicationContext,
                            call.argument<String>("sessionId") ?: "default",
                            call.argument<String>("sessionTitle") ?: "ClawChat",
                            call.argument<String>("text") ?: "AI 正在执行任务..."
                        )
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SERVICE_ERROR", e.message, null)
                    }
                }
                "updateAgentNotification" -> {
                    try {
                        AgentTaskService.updateNotification(
                            applicationContext,
                            call.argument<String>("sessionId") ?: "default",
                            call.argument<String>("sessionTitle") ?: "ClawChat",
                            call.argument<String>("status") ?: "thinking",
                            call.argument<String>("previewText") ?: "",
                            call.argument<String>("toolName"),
                            call.argument<Boolean>("overlayVisible") ?: false
                        )
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SERVICE_ERROR", e.message, null)
                    }
                }
                "stopAgentService" -> {
                    try {
                        AgentTaskService.stop(applicationContext)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SERVICE_ERROR", e.message, null)
                    }
                }
                "stopAgentServiceForSession" -> {
                    try {
                        val sessionId = call.argument<String>("sessionId")
                        if (sessionId.isNullOrBlank()) {
                            result.error("INVALID_ARGS", "sessionId required", null)
                        } else {
                            AgentTaskService.stopSession(applicationContext, sessionId)
                            result.success(true)
                        }
                    } catch (e: Exception) {
                        result.error("SERVICE_ERROR", e.message, null)
                    }
                }
                "hasAgentOverlayPermission" -> {
                    result.success(AgentTaskService.hasOverlayPermission(applicationContext))
                }
                "requestAgentOverlayPermissionIfNeeded" -> {
                    result.success(AgentTaskService.requestOverlayPermissionIfNeeded(this))
                }
                "setAgentOverlayVisible" -> {
                    try {
                        AgentTaskService.setOverlayVisible(
                            applicationContext,
                            call.argument<Boolean>("visible") ?: false
                        )
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("OVERLAY_ERROR", e.message, null)
                    }
                }
                "requestBatteryOptimization" -> {
                    try {
                        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                            data = Uri.parse("package:${packageName}")
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("BATTERY_ERROR", e.message, null)
                    }
                }
                "isBatteryOptimized" -> {
                    val pm = getSystemService(POWER_SERVICE) as PowerManager
                    result.success(!pm.isIgnoringBatteryOptimizations(packageName))
                }
                "getBatteryStatus" -> {
                    try {
                        val batteryIntent = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                        if (batteryIntent == null) {
                            result.error("BATTERY_ERROR", "Battery status unavailable", null)
                            return@setMethodCallHandler
                        }
                        val level = batteryIntent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
                        val scale = batteryIntent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
                        val temperature = batteryIntent.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, -1)
                        val voltage = batteryIntent.getIntExtra(BatteryManager.EXTRA_VOLTAGE, -1)
                        val status = batteryIntent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
                        val plugged = batteryIntent.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0)
                        val percentage = if (level >= 0 && scale > 0) ((level * 100f) / scale).toInt() else -1
                        val statusText = when (status) {
                            BatteryManager.BATTERY_STATUS_CHARGING -> "CHARGING"
                            BatteryManager.BATTERY_STATUS_DISCHARGING -> "DISCHARGING"
                            BatteryManager.BATTERY_STATUS_FULL -> "FULL"
                            BatteryManager.BATTERY_STATUS_NOT_CHARGING -> "NOT_CHARGING"
                            else -> "UNKNOWN"
                        }
                        val pluggedText = when {
                            (plugged and BatteryManager.BATTERY_PLUGGED_AC) != 0 -> "AC"
                            (plugged and BatteryManager.BATTERY_PLUGGED_USB) != 0 -> "USB"
                            (plugged and BatteryManager.BATTERY_PLUGGED_WIRELESS) != 0 -> "WIRELESS"
                            else -> "UNPLUGGED"
                        }
                        val data = hashMapOf<String, Any>(
                            "percentage" to percentage, "level" to level, "scale" to scale,
                            "status" to statusText, "plugged" to pluggedText,
                            "isCharging" to (status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL),
                            "temperatureC" to if (temperature >= 0) temperature / 10.0 else -1.0,
                            "voltageMv" to voltage,
                        )
                        result.success(data)
                    } catch (e: Exception) {
                        result.error("BATTERY_ERROR", e.message, null)
                    }
                }
                "setupDirs" -> {
                    Thread {
                        try {
                            bootstrapManager.setupDirectories()
                            safeRunOnUiThread { result.success(true) }
                        } catch (e: Exception) {
                            safeRunOnUiThread { result.error("SETUP_ERROR", e.message, null) }
                        }
                    }.start()
                }
                "writeResolv" -> {
                    Thread {
                        try {
                            bootstrapManager.writeResolvConf()
                            safeRunOnUiThread { result.success(true) }
                        } catch (e: Exception) {
                            safeRunOnUiThread { result.error("RESOLV_ERROR", e.message, null) }
                        }
                    }.start()
                }
                "startSetupService" -> {
                    try {
                        SetupService.start(applicationContext)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SERVICE_ERROR", e.message, null)
                    }
                }
                "updateSetupNotification" -> {
                    val text = call.argument<String>("text")
                    val progress = call.argument<Int>("progress") ?: -1
                    if (text != null) {
                        SetupService.updateNotification(text, progress)
                        result.success(true)
                    } else {
                        result.error("INVALID_ARGS", "text required", null)
                    }
                }
                "showToolAutoApprovedNotification" -> {
                    val toolName = call.argument<String>("toolName")
                    if (toolName.isNullOrBlank()) {
                        result.error("INVALID_ARGS", "toolName required", null)
                    } else {
                        showToolAutoApprovedNotification(toolName)
                        result.success(true)
                    }
                }
                "showAgentCompleteNotification" -> {
                    val sessionId = call.argument<String>("sessionId") ?: "default"
                    val sessionTitle = call.argument<String>("sessionTitle") ?: "ClawChat"
                    val preview = call.argument<String>("preview")
                        ?: call.argument<String>("summary")
                        ?: ""
                    AgentTaskService.showCompletionNotification(
                        applicationContext,
                        sessionId,
                        sessionTitle,
                        preview
                    )
                    result.success(true)
                }
                "stopSetupService" -> {
                    try {
                        SetupService.stop(applicationContext)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SERVICE_ERROR", e.message, null)
                    }
                }
                "requestStoragePermission" -> {
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                            if (!Environment.isExternalStorageManager()) {
                                val intent = Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                                startActivity(intent)
                            }
                        } else {
                            ActivityCompat.requestPermissions(
                                this,
                                arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE, Manifest.permission.WRITE_EXTERNAL_STORAGE),
                                STORAGE_PERMISSION_REQUEST
                            )
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("STORAGE_ERROR", e.message, null)
                    }
                }
                "hasStoragePermission" -> {
                    val hasPermission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        Environment.isExternalStorageManager()
                    } else {
                        ContextCompat.checkSelfPermission(this, Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
                    }
                    result.success(hasPermission)
                }
                "getExternalStoragePath" -> {
                    try {
                        val extDir = getExternalFilesDir(null)
                        result.success(extDir?.absolutePath ?: Environment.getExternalStorageDirectory().absolutePath)
                    } catch (e: Exception) {
                        Log.w("ClawChat", "getExternalFilesDir failed, using fallback", e)
                        result.success(Environment.getExternalStorageDirectory().absolutePath)
                    }
                }
                "readRootfsFile" -> {
                    val path = call.argument<String>("path")
                    if (path != null) {
                        Thread {
                            try {
                                val content = bootstrapManager.readRootfsFile(path)
                                safeRunOnUiThread { result.success(content) }
                            } catch (e: Exception) {
                                safeRunOnUiThread { result.error("ROOTFS_READ_ERROR", e.message, null) }
                            }
                        }.start()
                    } else {
                        result.error("INVALID_ARGS", "path required", null)
                    }
                }
                "writeRootfsFile" -> {
                    val path = call.argument<String>("path")
                    val content = call.argument<String>("content")
                    if (path != null && content != null) {
                        Thread {
                            try {
                                bootstrapManager.writeRootfsFile(path, content)
                                safeRunOnUiThread { result.success(true) }
                            } catch (e: Exception) {
                                safeRunOnUiThread { result.error("ROOTFS_WRITE_ERROR", e.message, null) }
                            }
                        }.start()
                    } else {
                        result.error("INVALID_ARGS", "path and content required", null)
                    }
                }
                "phoneIntent" -> {
                    val action = call.argument<String>("action")
                    @Suppress("UNCHECKED_CAST")
                    val params = (call.argument<Map<String, Any?>>("params") ?: emptyMap())
                    val allowed = call.argument<Boolean>("allowed") ?: false
                    if (action == null) {
                        result.error("INVALID_ARGS", "action required", null)
                    } else if (action in setOf("callPhone", "sendSms") && !allowed) {
                        result.error("DISABLED", "Action $action is disabled by user setting", null)
                    } else if (action in setOf("listCalendarEvents", "listContacts", "insertCalendarEvent")) {
                        // Content provider queries run off the main thread
                        Thread {
                            try {
                                val data = phoneIntentManager.dispatch(action, params)
                                safeRunOnUiThread { result.success(data) }
                            } catch (e: Exception) {
                                safeRunOnUiThread { result.error("PHONE_INTENT_ERROR", e.message, null) }
                            }
                        }.start()
                    } else {
                        try {
                            result.success(phoneIntentManager.dispatch(action, params))
                        } catch (e: Exception) {
                            result.error("PHONE_INTENT_ERROR", e.message, null)
                        }
                    }
                }
                "hasAudioPermission" -> {
                    result.success(
                        ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
                    )
                }
                "requestAudioPermission" -> {
                    try {
                        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
                            != PackageManager.PERMISSION_GRANTED
                        ) {
                            ActivityCompat.requestPermissions(
                                this,
                                arrayOf(Manifest.permission.RECORD_AUDIO),
                                AUDIO_PERMISSION_REQUEST
                            )
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("AUDIO_ERROR", e.message, null)
                    }
                }
                "startRecording" -> {
                    try {
                        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
                            != PackageManager.PERMISSION_GRANTED
                        ) {
                            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.RECORD_AUDIO), AUDIO_PERMISSION_REQUEST)
                            result.error("PERMISSION_DENIED", "Audio permission not granted", null)
                            return@setMethodCallHandler
                        }
                        val path = "${applicationContext.cacheDir.absolutePath}/whisper_recording.m4a"
                        @Suppress("DEPRECATION")
                        val recorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            MediaRecorder(this)
                        } else {
                            MediaRecorder()
                        }
                        recorder.setAudioSource(MediaRecorder.AudioSource.MIC)
                        recorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                        recorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                        recorder.setAudioSamplingRate(16000)
                        recorder.setAudioEncodingBitRate(64000)
                        recorder.setAudioChannels(1)
                        recorder.setOutputFile(path)
                        recorder.prepare()
                        recorder.start()
                        mediaRecorder = recorder
                        recordingPath = path
                        result.success(path)
                    } catch (e: Exception) {
                        result.error("RECORD_ERROR", e.message, null)
                    }
                }
                "stopRecording" -> {
                    try {
                        mediaRecorder?.stop()
                        mediaRecorder?.release()
                        mediaRecorder = null
                        result.success(recordingPath ?: "")
                    } catch (e: Exception) {
                        mediaRecorder?.release()
                        mediaRecorder = null
                        result.error("RECORD_ERROR", e.message, null)
                    }
                }
                "startSpeechRecognition" -> {
                    try {
                        if (pendingSpeechResult != null) {
                            result.error("SPEECH_BUSY", "Speech recognition already in progress", null)
                            return@setMethodCallHandler
                        }
                        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                            putExtra(RecognizerIntent.EXTRA_LANGUAGE, call.argument<String>("language") ?: "zh-CN")
                            putExtra(RecognizerIntent.EXTRA_PROMPT, "请说话...")
                        }
                        if (intent.resolveActivity(packageManager) != null) {
                            pendingSpeechResult = result
                            try {
                                startActivityForResult(intent, SPEECH_REQUEST)
                            } catch (e: Exception) {
                                pendingSpeechResult = null
                                result.error("SPEECH_ERROR", e.message, null)
                            }
                        } else {
                            result.error("SPEECH_UNAVAILABLE", "No speech recognition available", null)
                        }
                    } catch (e: Exception) {
                        pendingSpeechResult = null
                        result.error("SPEECH_ERROR", e.message, null)
                    }
                }
                "cancelSpeechRecognition" -> {
                    try {
                        pendingSpeechResult?.success("")
                        pendingSpeechResult = null
                        result.success(true)
                    } catch (e: Exception) {
                        pendingSpeechResult = null
                        result.error("SPEECH_CANCEL_ERROR", e.message, null)
                    }
                }
                "shareText" -> {
                    val text = call.argument<String>("text") ?: ""
                    val subject = call.argument<String>("subject") ?: "ClawChat"
                    if (text.isBlank()) {
                        result.error("INVALID_ARGS", "text required", null)
                    } else {
                        try {
                            val sendIntent = Intent(Intent.ACTION_SEND).apply {
                                type = "text/plain"
                                putExtra(Intent.EXTRA_TEXT, text)
                                putExtra(Intent.EXTRA_SUBJECT, subject)
                            }
                            startActivity(Intent.createChooser(sendIntent, subject))
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SHARE_ERROR", e.message, null)
                        }
                    }
                }
                "openHtmlFile" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("INVALID_ARGS", "path required", null)
                    } else if (!isAppOwnedPath(path)) {
                        result.error("INVALID_PATH", "path must be in app cache or files dir", null)
                    } else {
                        try {
                            val file = File(path)
                            val uri = FileProvider.getUriForFile(
                                this,
                                "${applicationContext.packageName}.fileprovider",
                                file
                            )
                            val viewIntent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, "text/html")
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }
                            startActivity(Intent.createChooser(viewIntent, "Open HTML"))
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("OPEN_HTML_ERROR", e.message, null)
                        }
                    }
                }
                "playAudio" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("INVALID_ARGS", "path required", null)
                    } else if (!isAppOwnedPath(path)) {
                        result.error("INVALID_PATH", "path must be in app cache or files dir", null)
                    } else {
                        try {
                            mediaPlayer?.release()
                            mediaPlayer = MediaPlayer().apply {
                                setAudioAttributes(
                                    android.media.AudioAttributes.Builder()
                                        .setUsage(android.media.AudioAttributes.USAGE_MEDIA)
                                        .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SPEECH)
                                        .build()
                                )
                                setVolume(1.0f, 1.0f)
                                setDataSource(path)
                                setOnCompletionListener {
                                    safeRunOnUiThread {
                                        flutterEngine?.dartExecutor?.binaryMessenger?.let { messenger ->
                                            MethodChannel(messenger, CHANNEL)
                                                .invokeMethod("onAudioComplete", null)
                                        }
                                    }
                                    release()
                                    mediaPlayer = null
                                }
                                setOnErrorListener { _, what, extra ->
                                    Log.e("ClawChat", "MediaPlayer error: what=$what extra=$extra")
                                    safeRunOnUiThread {
                                        flutterEngine?.dartExecutor?.binaryMessenger?.let { messenger ->
                                            MethodChannel(messenger, CHANNEL)
                                                .invokeMethod("onAudioComplete", null)
                                        }
                                    }
                                    release()
                                    mediaPlayer = null
                                    true
                                }
                                prepare()
                                start()
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("PLAY_ERROR", e.message, null)
                        }
                    }
                }
                "stopAudio" -> {
                    try {
                        mediaPlayer?.stop()
                        mediaPlayer?.release()
                        mediaPlayer = null
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("STOP_ERROR", e.message, null)
                    }
                }
                "bringToForeground" -> {
                    try {
                        val intent = Intent(applicationContext, MainActivity::class.java).apply {
                            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
                        }
                        applicationContext.startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("FOREGROUND_ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        AgentTaskService.setCallbackChannel(
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AGENT_CALLBACK_CHANNEL)
        )
        createNotificationChannel()
        createAgentCompleteNotificationChannel()
        requestNotificationPermission()
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED
            ) {
                ActivityCompat.requestPermissions(
                    this,
                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                    NOTIFICATION_PERMISSION_REQUEST
                )
            }
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID, "ClawChat", NotificationManager.IMPORTANCE_LOW
            ).apply { description = "ClawChat notifications" }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    private fun createAgentCompleteNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            manager.deleteNotificationChannel("clawchat_agent_complete")
            val channel = NotificationChannel(
                AGENT_COMPLETE_CHANNEL_ID,
                "ClawChat Agent",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "AI task completion notifications"
                enableVibration(true)
            }
            manager.createNotificationChannel(channel)
        }
    }

    private fun showToolAutoApprovedNotification(toolName: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
            != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }

        val launchIntent = Intent(applicationContext, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
        }
        val pendingFlags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE
            } else {
                0
            }
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            pendingFlags
        )
        val text = "ClawChat 已自动允许 $toolName 执行"
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("ClawChat")
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .build()

        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(TOOL_AUTO_APPROVED_NOTIFICATION_ID, notification)
    }

    @Suppress("DEPRECATION")
    private fun showAgentCompleteNotification(preview: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
            != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }

        val launchIntent = Intent(applicationContext, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
        }
        val pendingFlags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE
            } else {
                0
            }
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            pendingFlags
        )
        val text = preview.ifBlank { "点击查看回复" }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, AGENT_COMPLETE_CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
        val notification = builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("AI 回复完成")
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setPriority(Notification.PRIORITY_HIGH)
            .setDefaults(Notification.DEFAULT_ALL)
            .build()

        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(AGENT_COMPLETE_NOTIFICATION_ID, notification)
    }

    private fun isAppOwnedPath(path: String): Boolean {
        return try {
            val canonical = File(path).canonicalPath
            val cacheRoot = applicationContext.cacheDir.canonicalPath
            val filesRoot = applicationContext.filesDir.canonicalPath
            canonical == cacheRoot ||
                canonical.startsWith(cacheRoot + File.separator) ||
                canonical == filesRoot ||
                canonical.startsWith(filesRoot + File.separator)
        } catch (_: Exception) { false }
    }

    override fun onDestroy() {
        try { pendingSpeechResult?.success("") } catch (_: Exception) {}
        pendingSpeechResult = null
        try { mediaRecorder?.stop() } catch (_: Exception) {}
        try { mediaRecorder?.release() } catch (_: Exception) {}
        mediaRecorder = null
        try { mediaPlayer?.stop() } catch (_: Exception) {}
        try { mediaPlayer?.release() } catch (_: Exception) {}
        mediaPlayer = null
        super.onDestroy()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == SPEECH_REQUEST) {
            val pending = pendingSpeechResult
            pendingSpeechResult = null
            if (resultCode == Activity.RESULT_OK && data != null) {
                val results = data.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)
                pending?.success(results?.firstOrNull() ?: "")
            } else {
                pending?.success("")
            }
        }
    }

    companion object {
        const val CHANNEL_ID = "clawchat_main"
        const val AGENT_CALLBACK_CHANNEL = "com.anka.clawbot/native/agent_callbacks"
        const val AGENT_COMPLETE_CHANNEL_ID = "clawchat_agent_complete_v2"
        const val NOTIFICATION_PERMISSION_REQUEST = 1001
        const val STORAGE_PERMISSION_REQUEST = 1003
        const val AUDIO_PERMISSION_REQUEST = 1004
        const val SPEECH_REQUEST = 1005
        const val TOOL_AUTO_APPROVED_NOTIFICATION_ID = 2001
        const val AGENT_COMPLETE_NOTIFICATION_ID = 2002
    }
}
