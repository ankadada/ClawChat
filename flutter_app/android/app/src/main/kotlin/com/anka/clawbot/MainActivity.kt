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
import android.app.Activity
import android.content.Context
import android.os.Environment
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.anka.clawbot/native"

    private lateinit var bootstrapManager: BootstrapManager
    private lateinit var processManager: ProcessManager
    private lateinit var phoneIntentManager: PhoneIntentManager
    @Volatile
    private var setupDone = false

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

        if (!setupDone) {
            setupDone = true
            // TODO: Replace Thread{} with coroutines (requires lifecycle-runtime-ktx dependency)
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
                    if (command != null) {
                        Thread {
                            try {
                                val output = processManager.runInProotSync(command, timeout)
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

        createNotificationChannel()
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

    companion object {
        const val CHANNEL_ID = "clawchat_main"
        const val NOTIFICATION_PERMISSION_REQUEST = 1001
        const val STORAGE_PERMISSION_REQUEST = 1003
    }
}
