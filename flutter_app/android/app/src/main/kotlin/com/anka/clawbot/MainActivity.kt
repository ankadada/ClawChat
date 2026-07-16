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
import android.provider.OpenableColumns
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
import java.io.ByteArrayInputStream
import java.security.MessageDigest
import java.security.Signature as CryptoSignature
import java.security.cert.CertificateFactory
import android.util.Base64
import java.util.UUID
import java.util.IdentityHashMap
import java.util.concurrent.Executors

private val LARK_CLI_ENVIRONMENT_KEYS = setOf(
    "LARKSUITE_CLI_APP_ID",
    "LARKSUITE_CLI_APP_SECRET",
)

internal fun parseScopedLarkEnvironment(
    rawScope: Any?,
    rawEnvironment: Any?,
): MutableMap<String, String>? {
    val scopeEnabled = when (rawScope) {
        null, false -> false
        true -> true
        else -> return null
    }
    if (!scopeEnabled) {
        return if (rawEnvironment == null) mutableMapOf() else null
    }

    val map = rawEnvironment as? Map<*, *> ?: return null
    if (map.keys.filterIsInstance<String>().toSet() != LARK_CLI_ENVIRONMENT_KEYS) {
        return null
    }
    val values = mutableMapOf<String, String>()
    for ((key, value) in map) {
        if (key !is String || value !is String) return null
        values[key] = value
    }
    if (!validScopedLarkValue(values["LARKSUITE_CLI_APP_ID"], 256) ||
        !validScopedLarkValue(values["LARKSUITE_CLI_APP_SECRET"], 512)) {
        return null
    }
    return values
}

private fun validScopedLarkValue(value: String?, maxLength: Int): Boolean =
    value != null && value.isNotEmpty() && value.length <= maxLength &&
        value.none { it.code < 0x20 || it.code == 0x7f }

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.anka.clawbot/native"

    private lateinit var bootstrapManager: BootstrapManager
    private lateinit var processManager: ProcessManager
    private lateinit var phoneIntentManager: PhoneIntentManager
    private val setupDone = java.util.concurrent.atomic.AtomicBoolean(false)
    private val secureImportExecutor = Executors.newFixedThreadPool(2) { task ->
        Thread(task, "clawchat-secure-import").apply { isDaemon = true }
    }
    private var pendingSpeechResult: MethodChannel.Result? = null
    private var mediaRecorder: MediaRecorder? = null
    private var recordingPath: String? = null
    private var recordingOperationId: String? = null
    private var pendingNavigateToSessionId: String? = null
    private var pendingShareIntent: Map<String, Any?>? = null
    private var shareCallbackChannel: MethodChannel? = null
    private val agentCallbackOwners =
        IdentityHashMap<FlutterEngine, Pair<MethodChannel, Long>>()
    private var mediaPlayer: MediaPlayer? = null
    private var mediaPlaybackPath: String? = null
    private var mediaPlaybackOperationId: String? = null
    private var activityResumed = false
    private val pickedContentCacheDirName = "clawchat_picked_content"
    private val pickedContentMaxAgeMs = 24L * 60L * 60L * 1000L

    private fun safeRunOnUiThread(action: () -> Unit) {
        if (isDestroyed || isFinishing) return
        runOnUiThread {
            if (!isDestroyed && !isFinishing) action()
        }
    }

    private fun deleteTtsPlaybackCache(path: String?) {
        if (path == null) return
        try {
            val cacheRoot = applicationContext.cacheDir.canonicalFile
            val candidate = File(path).canonicalFile
            val insideCache = candidate.path.startsWith(cacheRoot.path + File.separator)
            if (insideCache && candidate.name.startsWith("tts_") && candidate.name.endsWith(".mp3")) {
                candidate.delete()
            }
        } catch (_: Exception) {
            // Cache deletion is best effort and must not mask playback state.
        }
    }

    private fun cleanupPickedContentCache() {
        try {
            val directory = File(cacheDir, pickedContentCacheDirName)
            val cutoff = System.currentTimeMillis() - pickedContentMaxAgeMs
            directory.listFiles()?.forEach { file ->
                if (file.isFile && file.name.startsWith("picked_") &&
                    file.lastModified() < cutoff) {
                    file.delete()
                }
            }
        } catch (_: Exception) {
            // Cache cleanup is best effort and must not block app startup.
        }
    }

    private fun deletePickedContentCache(path: String?) {
        if (path == null) return
        try {
            val root = File(cacheDir, pickedContentCacheDirName).canonicalFile
            val candidate = File(path).canonicalFile
            if (candidate.path.startsWith(root.path + File.separator) &&
                candidate.name.startsWith("picked_") && candidate.isFile) {
                candidate.delete()
            }
        } catch (_: Exception) {
            // Never allow an invalid caller path to escape the cache root.
        }
    }

    private fun stagePickedContentUri(
        rawUri: String,
        displayName: String,
        maxBytes: Long,
    ): String {
        val uri = Uri.parse(rawUri)
        if (uri.scheme != "content" || uri.authority.isNullOrBlank() ||
            rawUri.length > 4096) {
            throw SecurityException("content URI required")
        }
        if (maxBytes <= 0L || maxBytes > 50L * 1024L * 1024L) {
            throw IllegalArgumentException("invalid content limit")
        }
        val safeName = sanitizeSharedFileName(displayName).take(120)
        val declaredSize = queryOpenableLong(uri, OpenableColumns.SIZE)
        if (declaredSize != null && declaredSize > maxBytes) {
            throw IllegalArgumentException("content exceeds bounded limit")
        }
        val directory = File(cacheDir, pickedContentCacheDirName).apply {
            mkdirs()
        }
        val destination = File.createTempFile("picked_", "_$safeName", directory)
        var total = 0L
        try {
            val input = contentResolver.openInputStream(uri)
                ?: throw IllegalArgumentException("content cannot be opened")
            input.use { source ->
                destination.outputStream().use { target ->
                    val buffer = ByteArray(16 * 1024)
                    while (true) {
                        val read = source.read(buffer)
                        if (read < 0) break
                        if (read == 0) continue
                        total += read.toLong()
                        if (total > maxBytes) {
                            throw IllegalArgumentException("content exceeds bounded limit")
                        }
                        target.write(buffer, 0, read)
                    }
                }
            }
            return destination.absolutePath
        } catch (error: Throwable) {
            destination.delete()
            throw error
        }
    }

    private fun deleteWhisperRecordingCache(path: String?) {
        if (path == null) return
        try {
            val cacheRoot = applicationContext.cacheDir.canonicalFile
            val candidate = File(path).canonicalFile
            val insideCache = candidate.path.startsWith(cacheRoot.path + File.separator)
            if (insideCache && candidate.name.startsWith("whisper_") && candidate.name.endsWith(".m4a")) {
                candidate.delete()
            }
        } catch (_: Exception) {
            // Recording cleanup is best effort and restricted to app-owned files.
        }
    }

    private fun cleanupOldWhisperRecordingCache() {
        val activePath = try { recordingPath?.let { File(it).canonicalPath } } catch (_: Exception) { null }
        val cutoff = System.currentTimeMillis() - WHISPER_ORPHAN_MAX_AGE_MS
        try {
            applicationContext.cacheDir.listFiles()?.forEach { candidate ->
                if (!candidate.name.startsWith("whisper_") || !candidate.name.endsWith(".m4a")) return@forEach
                val canonical = try { candidate.canonicalPath } catch (_: Exception) { return@forEach }
                if (canonical == activePath || candidate.lastModified() <= 0L || candidate.lastModified() > cutoff) {
                    return@forEach
                }
                deleteWhisperRecordingCache(canonical)
            }
        } catch (_: Exception) {
            // Orphan cleanup must not interfere with recording startup.
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val filesDir = applicationContext.filesDir.absolutePath
        val nativeLibDir = applicationContext.applicationInfo.nativeLibraryDir
        val cleanupCoordinator = try {
            CommandCleanupCoordinatorProvider.get(applicationContext)
        } catch (error: Exception) {
            // Legacy cleanup is best effort for direct commands. Explicit
            // continuation still fails closed through its typed unavailable path.
            Log.w("ClawChat", "Legacy command cleanup coordinator unavailable", error)
            null
        }
        TerminalSessionService.initializeCleanupCoordinator(cleanupCoordinator)
        AgentTaskService.initializeCleanupCoordinator(cleanupCoordinator)

        bootstrapManager = BootstrapManager(applicationContext, filesDir, nativeLibDir)
        processManager = ProcessManager(filesDir, nativeLibDir, cleanupCoordinator)
        phoneIntentManager = PhoneIntentManager(this) { activityResumed }
        cleanupPickedContentCache()

        if (setupDone.compareAndSet(false, true)) {
            // Reconcile a few bounded journal batches off the UI thread. Each
            // native call advances its process-local cursor and caps work.
            secureImportExecutor.execute {
                try { bootstrapManager.setupDirectories() } catch (e: Exception) { Log.e("ClawChat", "setupDirectories failed", e) }
                try { bootstrapManager.writeResolvConf() } catch (e: Exception) { Log.e("ClawChat", "writeResolvConf failed", e) }
                try {
                    val uploadsPath = bootstrapManager.prepareWorkspaceUploadsDirectory()
                    repeat(4) { SecureImportNative.reconcileImports(uploadsPath) }
                } catch (_: Throwable) {
                    Log.w("ClawChat", "secure import reconciliation unavailable")
                }
            }
        }

        val mainChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        shareCallbackChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SHARE_CALLBACK_CHANNEL
        )

        mainChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getProotPath" -> result.success(processManager.getProotPath())
                "getArch" -> result.success(ArchUtils.getArch())
                "getFilesDir" -> result.success(filesDir)
                "stagePickedContentUri" -> {
                    val uri = call.argument<String>("uri")
                    val displayName = call.argument<String>("displayName")
                    val maxBytes = call.argument<Number>("maxBytes")?.toLong()
                    if (uri == null || displayName == null || maxBytes == null ||
                        !uri.startsWith("content://") || displayName.isBlank() ||
                        displayName.length > 256 || maxBytes <= 0L ||
                        maxBytes > 50L * 1024L * 1024L) {
                        result.error("INVALID_ARGS", "picked content arguments required", null)
                    } else {
                        secureImportExecutor.execute {
                            try {
                                val path = stagePickedContentUri(uri, displayName, maxBytes)
                                safeRunOnUiThread { result.success(path) }
                            } catch (_: Throwable) {
                                safeRunOnUiThread {
                                    result.error("PICKED_CONTENT_ERROR", "unable to stage picked content", null)
                                }
                            }
                        }
                    }
                }
                "discardPickedContentCache" -> {
                    deletePickedContentCache(call.argument<String>("path"))
                    result.success(true)
                }
                "importHostFileToWorkspace" -> {
                    val path = call.argument<String>("path")
                    val destinationPath = call.argument<String>("destinationPath")
                    val allowedRoot = call.argument<String>("allowedRoot")
                    val operationId = call.argument<String>("operationId")
                    val requestedMaxBytes = call.argument<Number>("maxBytes")?.toLong()
                    val maxBytes = requestedMaxBytes?.coerceAtMost(50L * 1024L * 1024L)
                    if (path == null || destinationPath == null || allowedRoot == null ||
                        operationId == null || !operationId.matches(Regex("^[a-f0-9]{32}$")) ||
                        maxBytes == null || maxBytes < 0L) {
                        result.error("INVALID_ARGS", "secure import arguments required", null)
                    } else {
                        secureImportExecutor.execute {
                            try {
                                if (allowedRoot != "/root/workspace/uploads" ||
                                    !destinationPath.startsWith("root/workspace/uploads/")) {
                                    throw SecurityException("invalid workspace import destination")
                                }
                                val finalName = destinationPath.removePrefix("root/workspace/uploads/")
                                if (finalName.isEmpty() || finalName.contains('/')) {
                                    throw SecurityException("invalid workspace import filename")
                                }
                                val uploadsPath = bootstrapManager.prepareWorkspaceUploadsDirectory()
                                val metadata = SecureImportNative.importHostFile(
                                    path,
                                    uploadsPath,
                                    finalName,
                                    operationId,
                                    maxBytes
                                )
                                safeRunOnUiThread {
                                    result.success(
                                        mapOf(
                                            "storedPath" to "/$destinationPath",
                                            "size" to metadata[0].toLong(),
                                            "sha256" to metadata[1],
                                            "sourceIdentity" to metadata[2]
                                        )
                                    )
                                }
                            } catch (_: Throwable) {
                                safeRunOnUiThread {
                                    result.error("FILE_IMPORT_ERROR", "unable to securely import source", null)
                                }
                            }
                        }
                    }
                }
                "cancelImportOperation" -> {
                    val operationId = call.argument<String>("operationId")
                    if (operationId == null) {
                        result.error("INVALID_ARGS", "operationId required", null)
                    } else {
                        try { SecureImportNative.cancelOperation(operationId) } catch (_: Throwable) {}
                        processManager.cancelOperation(operationId)
                        result.success(true)
                    }
                }
                "finishImportOperation" -> {
                    val operationId = call.argument<String>("operationId")
                    if (operationId == null) {
                        result.error("INVALID_ARGS", "operationId required", null)
                    } else {
                        try { SecureImportNative.finishOperation(operationId) } catch (_: Throwable) {}
                        processManager.finishOperation(operationId)
                        result.success(true)
                    }
                }
                "acknowledgeHostFileImport" -> {
                    val operationId = call.argument<String>("operationId")
                    val storedPath = call.argument<String>("storedPath")
                    val expectedSize = call.argument<Number>("size")?.toLong()
                    val expectedSha256 = call.argument<String>("sha256")
                    if (operationId == null || storedPath == null ||
                        expectedSize == null || expectedSha256 == null ||
                        !storedPath.startsWith("/root/workspace/uploads/")) {
                        result.error("INVALID_ARGS", "import acknowledgement required", null)
                    } else {
                        secureImportExecutor.execute {
                            try {
                                val finalName = storedPath.removePrefix("/root/workspace/uploads/")
                                if (finalName.isEmpty() || finalName.contains('/')) {
                                    throw SecurityException("invalid acknowledgement filename")
                                }
                                val uploadsPath = bootstrapManager.prepareWorkspaceUploadsDirectory()
                                SecureImportNative.acknowledgeImport(
                                    uploadsPath,
                                    finalName,
                                    operationId,
                                    expectedSize,
                                    expectedSha256
                                )
                                safeRunOnUiThread { result.success(true) }
                            } catch (_: Throwable) {
                                safeRunOnUiThread {
                                    result.error("IMPORT_ACK_ERROR", "unable to acknowledge import", null)
                                }
                            }
                        }
                    }
                }
                "discardHostFileImport" -> {
                    val operationId = call.argument<String>("operationId")
                    val storedPath = call.argument<String>("storedPath")
                    val expectedSize = call.argument<Number>("size")?.toLong()
                    val expectedSha256 = call.argument<String>("sha256")
                    if (operationId == null || storedPath == null || expectedSize == null ||
                        expectedSha256 == null ||
                        !storedPath.startsWith("/root/workspace/uploads/")) {
                        result.error("INVALID_ARGS", "import discard receipt required", null)
                    } else {
                        secureImportExecutor.execute {
                            try {
                                val finalName = storedPath.removePrefix("/root/workspace/uploads/")
                                if (finalName.isEmpty() || finalName.contains('/')) {
                                    throw SecurityException("invalid discard filename")
                                }
                                val uploadsPath = bootstrapManager.prepareWorkspaceUploadsDirectory()
                                SecureImportNative.discardImport(
                                    uploadsPath,
                                    finalName,
                                    operationId,
                                    expectedSize,
                                    expectedSha256
                                )
                                safeRunOnUiThread { result.success(true) }
                            } catch (_: Throwable) {
                                safeRunOnUiThread {
                                    result.error("IMPORT_DISCARD_ERROR", "unable to discard import", null)
                                }
                            }
                        }
                    }
                }
                "listPendingWorkspaceImports" -> {
                    val requestedLimit = call.argument<Number>("limit")?.toInt() ?: 64
                    val limit = requestedLimit.coerceIn(1, 64)
                    secureImportExecutor.execute {
                        try {
                            val uploadsPath = bootstrapManager.prepareWorkspaceUploadsDirectory()
                            val pending = SecureImportNative.listPendingImports(uploadsPath, limit)
                                .mapNotNull { encoded ->
                                    val fields = encoded.split('\n')
                                    if (fields.size != 4) return@mapNotNull null
                                    val size = fields[2].toLongOrNull() ?: return@mapNotNull null
                                    mapOf(
                                        "operationId" to fields[0],
                                        "storedPath" to "/root/workspace/uploads/${fields[1]}",
                                        "size" to size,
                                        "sha256" to fields[3]
                                    )
                                }
                            safeRunOnUiThread { result.success(pending) }
                        } catch (_: Throwable) {
                            safeRunOnUiThread {
                                result.error("IMPORT_LIST_ERROR", "unable to list pending imports", null)
                            }
                        }
                    }
                }
                "readRootfsFileBounded" -> {
                    val path = call.argument<String>("path")
                    val allowedRoot = call.argument<String>("allowedRoot")
                    val operationId = call.argument<String>("operationId")
                    val requestedMax = call.argument<Number>("maxBytes")?.toLong()
                    val maxBytes = requestedMax?.coerceAtMost(1024L * 1024L)
                    if (path == null || allowedRoot == null || operationId == null ||
                        maxBytes == null || maxBytes < 0L) {
                        result.error("INVALID_ARGS", "bounded read arguments required", null)
                    } else {
                        secureImportExecutor.execute {
                            try {
                                val location = bootstrapManager.resolveStagedImportReadPath(
                                    path,
                                    allowedRoot
                                )
                                val bytes = SecureImportNative.readFileBounded(
                                    location.rootPath,
                                    location.relativePath,
                                    operationId,
                                    maxBytes
                                )
                                safeRunOnUiThread { result.success(bytes) }
                            } catch (_: Throwable) {
                                safeRunOnUiThread {
                                    result.error("BOUNDED_READ_ERROR", "unable to securely read staged file", null)
                                }
                            }
                        }
                    }
                }
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
                    val operationId = call.argument<String>("operationId")
                    val continuationSessionId = call.argument<String>("continuationSessionId")
                    val requireBackgroundContinuation =
                        call.argument<Boolean>("requireBackgroundContinuation") ?: false
                    val rawLarkCliCredentialScope =
                        call.argument<Any?>("larkCliCredentialScope")
                    val rawScopedEnvironment = call.argument<Any?>("scopedEnvironment")
                    val scopedEnvironment = parseScopedLarkEnvironment(
                        rawLarkCliCredentialScope,
                        rawScopedEnvironment,
                    )
                    if (command == null) {
                        scopedEnvironment?.clear()
                        result.error("INVALID_ARGS", "command required", null)
                    } else if (scopedEnvironment == null) {
                        result.error(
                            "PROOT_LARK_CREDENTIAL_SCOPE_INVALID",
                            "lark-cli credential scope unavailable: LARK_CREDENTIAL_SCOPE_INVALID",
                            mapOf("reason" to "LARK_CREDENTIAL_SCOPE_INVALID"),
                        )
                    } else if (requireBackgroundContinuation &&
                        (operationId.isNullOrBlank() || continuationSessionId.isNullOrBlank())) {
                        scopedEnvironment.clear()
                        result.error(
                            "INVALID_ARGS",
                            "background continuation identity required",
                            null,
                        )
                    } else {
                        val continuationKey = if (requireBackgroundContinuation) {
                            AgentTaskService.commandKey(continuationSessionId!!, operationId!!)
                        } else {
                            null
                        }
                        val reservation = if (continuationKey != null) {
                            AgentTaskService.reserveCommand(
                                continuationKey.sessionId,
                                continuationKey.operationId,
                                timeout * 1000L,
                            )
                        } else {
                            CommandReservationDecision(
                                CommandReserveOutcome.NEW,
                                CommandAdmissionReason.ADMITTED,
                            )
                        }
                        val reserveOutcome = reservation.outcome
                        if (reserveOutcome != CommandReserveOutcome.NEW) {
                            scopedEnvironment.clear()
                            val reason = if (
                                reservation.admissionReason == CommandAdmissionReason.ADMITTED
                            ) {
                                "REGISTRY_${reserveOutcome.name}"
                            } else {
                                reservation.admissionReason.name
                            }
                            result.error(
                                "PROOT_${reserveOutcome.name}",
                                "command continuation not started: ${reserveOutcome.name} ($reason)",
                                null,
                            )
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                if (continuationKey != null) {
                                    val continuationReady =
                                        AgentTaskService.startReservedCommandAndAwaitReady(
                                            applicationContext,
                                            continuationKey.sessionId,
                                            continuationKey.operationId,
                                        )
                                    if (!continuationReady) {
                                        safeRunOnUiThread {
                                            result.error(
                                                "PROOT_SERVICE_NOT_READY",
                                                "command continuation not started: SERVICE_NOT_READY",
                                                mapOf(
                                                    "reason" to
                                                        CommandAdmissionReason.SERVICE_NOT_READY.name,
                                                ),
                                            )
                                        }
                                        return@Thread
                                    }
                                }
                                val output = processManager.runInProotSync(
                                    command,
                                    timeout,
                                    mountStorage,
                                    operationId,
                                    continuationKey,
                                    scopedEnvironment,
                                )
                                safeRunOnUiThread { result.success(output) }
                            } catch (e: Exception) {
                                safeRunOnUiThread { result.error("PROOT_ERROR", e.message, null) }
                            } finally {
                                if (continuationKey != null) {
                                    AgentTaskService.finishCommand(
                                        continuationKey.sessionId,
                                        continuationKey.operationId,
                                    )
                                }
                                scopedEnvironment.clear()
                            }
                        }.start()
                    }
                }
                "cancelProotOperation" -> {
                    val operationId = call.argument<String>("operationId")
                    val sessionId = call.argument<String>("sessionId")
                    val requireBackgroundContinuation =
                        call.argument<Boolean>("requireBackgroundContinuation") ?: false
                    if (operationId.isNullOrBlank() ||
                        (requireBackgroundContinuation && sessionId.isNullOrBlank())) {
                        result.error("INVALID_ARGS", "command operation identity required", null)
                    } else {
                        if (requireBackgroundContinuation) {
                            val outcome = AgentTaskService.cancelCommand(sessionId!!, operationId)
                            result.success(
                                outcome == CommandRetireOutcome.RETIRED ||
                                    outcome == CommandRetireOutcome.ALREADY_RETIRED
                            )
                        } else {
                            processManager.cancelOperation(operationId)
                            result.success(true)
                        }
                    }
                }
                "replaceTerminalSession" -> {
                    val operationId = call.argument<String>("operationId")
                    val sessionId = call.argument<String>("sessionId")
                    val candidateId = call.argument<String>("candidateId")
                    val timeoutSeconds = call.argument<Number>("timeoutSeconds")?.toLong()
                    if (operationId.isNullOrBlank() || sessionId.isNullOrBlank() ||
                        candidateId.isNullOrBlank() ||
                        timeoutSeconds == null || timeoutSeconds <= 0L) {
                        result.error("INVALID_ARGS", "terminal continuation identity required", null)
                    } else {
                        val replacement = TerminalSessionService.replaceSession(
                            operationId,
                            sessionId,
                            candidateId,
                            timeoutSeconds * 1000L,
                        )
                        val outcome = replacement.outcome
                        if (outcome != CommandReserveOutcome.NEW &&
                            outcome != CommandReserveOutcome.ALREADY_ACTIVE) {
                            result.success(
                                mapOf(
                                    "outcome" to outcome.name,
                                    "reason" to replacement.reason?.name,
                                )
                            )
                        } else {
                            Thread {
                                val ready = TerminalSessionService.startReservedAndAwaitReady(
                                    applicationContext,
                                    operationId,
                                    sessionId,
                                    candidateId,
                                )
                                safeRunOnUiThread {
                                    result.success(
                                        mapOf(
                                            "outcome" to if (ready) {
                                                outcome.name
                                            } else {
                                                CommandReserveOutcome.RETIRED.name
                                            },
                                            "reason" to if (ready) {
                                                replacement.reason?.name
                                            } else {
                                                CommandAdmissionReason.SERVICE_NOT_READY.name
                                            },
                                        )
                                    )
                                }
                            }.start()
                        }
                    }
                }
                "attachTerminalProcess" -> {
                    val operationId = call.argument<String>("operationId")
                    val sessionId = call.argument<String>("sessionId")
                    val candidateId = call.argument<String>("candidateId")
                    val attemptId = call.argument<String>("attemptId")
                    val launchToken = call.argument<String>("launchToken")
                    val processId = call.argument<Number>("processId")?.toInt()
                    if (operationId == null || sessionId == null || candidateId == null ||
                        attemptId.isNullOrBlank() || launchToken.isNullOrBlank() ||
                        processId == null) {
                        result.error("INVALID_ARGS", "terminal process identity required", null)
                    } else {
                        val attachResult = TerminalSessionService.attachProcess(
                            operationId,
                            sessionId,
                            candidateId,
                            attemptId,
                            launchToken,
                            processId,
                        )
                        result.success(attachResult.name)
                    }
                }
                "prepareTerminalLaunch" -> {
                    val operationId = call.argument<String>("operationId")
                    val sessionId = call.argument<String>("sessionId")
                    val candidateId = call.argument<String>("candidateId")
                    if (operationId.isNullOrBlank() || sessionId.isNullOrBlank() ||
                        candidateId.isNullOrBlank()) {
                        result.error("INVALID_ARGS", "terminal launch identity required", null)
                    } else {
                        val launch = TerminalSessionService.prepareLaunch(
                            operationId,
                            sessionId,
                            candidateId,
                        )
                        result.success(
                            mapOf(
                                "outcome" to launch.outcome.name,
                                "failureReason" to launch.failureReason?.name,
                                "wrapperPath" to launch.wrapperPath,
                                "attemptDirectoryPath" to launch.attemptDirectoryPath,
                                "stagingPath" to launch.stagingPath,
                                "goPath" to launch.goPath,
                                "parentProcessId" to launch.parentProcessId,
                                "appUid" to launch.appUid,
                                "attemptId" to launch.attemptId,
                                "launchToken" to launch.launchToken,
                            ),
                        )
                    }
                }
                "validateTerminalLaunchCapability" -> {
                    val operationId = call.argument<String>("operationId")
                    val sessionId = call.argument<String>("sessionId")
                    val candidateId = call.argument<String>("candidateId")
                    val attemptId = call.argument<String>("attemptId")
                    val launchToken = call.argument<String>("launchToken")
                    result.success(
                        !operationId.isNullOrBlank() && !sessionId.isNullOrBlank() &&
                            !candidateId.isNullOrBlank() && !attemptId.isNullOrBlank() &&
                            !launchToken.isNullOrBlank() &&
                            TerminalSessionService.validateLaunchCapability(
                                operationId,
                                sessionId,
                                candidateId,
                                attemptId,
                                launchToken,
                            )
                    )
                }
                "acknowledgeTerminalLaunchAbandoned" -> {
                    val operationId = call.argument<String>("operationId")
                    val sessionId = call.argument<String>("sessionId")
                    val candidateId = call.argument<String>("candidateId")
                    val attemptId = call.argument<String>("attemptId")
                    val launchToken = call.argument<String>("launchToken")
                    result.success(
                        !operationId.isNullOrBlank() && !sessionId.isNullOrBlank() &&
                            !candidateId.isNullOrBlank() && !attemptId.isNullOrBlank() &&
                            !launchToken.isNullOrBlank() &&
                            TerminalSessionService.acknowledgeLaunchAbandoned(
                                operationId,
                                sessionId,
                                candidateId,
                                attemptId,
                                launchToken,
                            )
                    )
                }
                "isTerminalOperationCurrent" -> {
                    val operationId = call.argument<String>("operationId")
                    val sessionId = call.argument<String>("sessionId")
                    val candidateId = call.argument<String>("candidateId")
                    result.success(
                        operationId != null && sessionId != null && candidateId != null &&
                            TerminalSessionService.isCurrent(operationId, sessionId, candidateId)
                    )
                }
                "terminalCandidateReceipt" -> {
                    val operationId = call.argument<String>("operationId")
                    val sessionId = call.argument<String>("sessionId")
                    val candidateId = call.argument<String>("candidateId")
                    val processId = call.argument<Number>("processId")?.toInt()
                    if (operationId == null || sessionId == null || candidateId == null ||
                        processId == null) {
                        result.error("INVALID_ARGS", "terminal process identity required", null)
                    } else {
                        result.success(
                            TerminalSessionService.candidateReceipt(
                                operationId,
                                sessionId,
                                candidateId,
                                processId,
                            ).name
                        )
                    }
                }
                "disposeTerminalProcessCandidate" -> {
                    val operationId = call.argument<String>("operationId")
                    val sessionId = call.argument<String>("sessionId")
                    val candidateId = call.argument<String>("candidateId")
                    val processId = call.argument<Number>("processId")?.toInt()
                    if (operationId == null || sessionId == null || candidateId == null ||
                        processId == null) {
                        result.error("INVALID_ARGS", "terminal process identity required", null)
                    } else {
                        result.success(
                            TerminalSessionService.disposeCandidate(
                                operationId,
                                sessionId,
                                candidateId,
                                processId,
                            ).name
                        )
                    }
                }
                "finishTerminalService" -> {
                    val operationId = call.argument<String>("operationId")
                    val sessionId = call.argument<String>("sessionId")
                    val candidateId = call.argument<String>("candidateId")
                    if (operationId == null || sessionId == null || candidateId == null) {
                        result.error("INVALID_ARGS", "terminal candidate identity required", null)
                    } else {
                        result.success(
                            TerminalSessionService.finish(
                                operationId,
                                sessionId,
                                candidateId,
                            ).name
                        )
                    }
                }
                "cancelTerminalService" -> {
                    val operationId = call.argument<String>("operationId")
                    val sessionId = call.argument<String>("sessionId")
                    val candidateId = call.argument<String>("candidateId")
                    if (operationId == null || sessionId == null || candidateId == null) {
                        result.error("INVALID_ARGS", "terminal candidate identity required", null)
                    } else {
                        result.success(
                            TerminalSessionService.cancel(
                                operationId,
                                sessionId,
                                candidateId,
                            ).name
                        )
                    }
                }
                "acknowledgeTerminalFinalReceipt" -> {
                    val operationId = call.argument<String>("operationId")
                    val sessionId = call.argument<String>("sessionId")
                    val candidateId = call.argument<String>("candidateId")
                    val expectedReceipt = call.argument<String>("expectedReceipt")?.let {
                        runCatching { CandidateReceipt.valueOf(it) }.getOrNull()
                    }
                    if (operationId == null || sessionId == null || candidateId == null ||
                        expectedReceipt == null) {
                        result.error("INVALID_ARGS", "terminal candidate identity required", null)
                    } else {
                        result.success(
                            TerminalSessionService.acknowledgeFinalReceipt(
                                operationId,
                                sessionId,
                                candidateId,
                                expectedReceipt,
                            ).name
                        )
                    }
                }
                "startTerminalService" -> {
                    try {
                        TerminalSessionService.startHelper(applicationContext)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SERVICE_ERROR", e.message, null)
                    }
                }
                "stopTerminalService" -> {
                    val sessionId = call.argument<String>("sessionId")
                    try {
                        if (sessionId.isNullOrBlank()) {
                            TerminalSessionService.stopHelper(applicationContext)
                        } else {
                            TerminalSessionService.stop(applicationContext, sessionId)
                        }
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
                "startBackgroundTaskLease" -> {
                    val taskId = call.argument<String>("taskId")
                    val executionOwnerId = call.argument<String>("executionOwnerId")
                    val sessionId = call.argument<String>("sessionId")
                    val ownerKind = call.argument<String>("ownerKind")
                    if (taskId.isNullOrBlank() || sessionId.isNullOrBlank() ||
                        executionOwnerId != taskId || ownerKind != "backgroundTask") {
                        result.error("INVALID_ARGS", "task lease identity required", null)
                    } else {
                        Thread {
                            val established = try {
                                AgentTaskService.startBackgroundTaskLeaseAndAwaitReady(
                                    applicationContext,
                                    taskId,
                                    sessionId,
                                )
                            } catch (_: Exception) {
                                false
                            }
                            safeRunOnUiThread { result.success(established) }
                        }.start()
                    }
                }
                "updateBackgroundTaskLease" -> {
                    val taskId = call.argument<String>("taskId")
                    val executionOwnerId = call.argument<String>("executionOwnerId")
                    val sessionId = call.argument<String>("sessionId")
                    val status = call.argument<String>("status")
                    val ownerKind = call.argument<String>("ownerKind")
                    if (taskId.isNullOrBlank() || sessionId.isNullOrBlank() ||
                        executionOwnerId != taskId || ownerKind != "backgroundTask" ||
                        (status != "working" && status != "needs_review")) {
                        result.error("INVALID_ARGS", "task lease update invalid", null)
                    } else {
                        try {
                            result.success(
                                AgentTaskService.updateBackgroundTaskLease(
                                    taskId,
                                    sessionId,
                                    status,
                                )
                            )
                        } catch (e: Exception) {
                            result.error("SERVICE_ERROR", e.message, null)
                        }
                    }
                }
                "stopBackgroundTaskLease" -> {
                    val taskId = call.argument<String>("taskId")
                    val executionOwnerId = call.argument<String>("executionOwnerId")
                    val sessionId = call.argument<String>("sessionId")
                    val ownerKind = call.argument<String>("ownerKind")
                    if (taskId.isNullOrBlank() || sessionId.isNullOrBlank() ||
                        executionOwnerId != taskId || ownerKind != "backgroundTask") {
                        result.error("INVALID_ARGS", "task lease identity required", null)
                    } else {
                        try {
                            result.success(
                                AgentTaskService.stopBackgroundTaskLease(
                                    taskId,
                                    sessionId,
                                )
                            )
                        } catch (e: Exception) {
                            result.error("SERVICE_ERROR", e.message, null)
                        }
                    }
                }
                "showToolApprovalNotification" -> {
                    val sessionId = call.argument<String>("sessionId")
                    val sessionTitle = call.argument<String>("sessionTitle")
                    val approvalId = call.argument<String>("approvalId")
                    val toolName = call.argument<String>("toolName")
                    val risk = call.argument<String>("risk")
                    if (sessionId.isNullOrBlank() || approvalId.isNullOrBlank() ||
                        toolName.isNullOrBlank() || risk.isNullOrBlank()) {
                        result.error("INVALID_ARGS", "approval metadata required", null)
                    } else {
                        val shown = AgentTaskService.showToolApproval(
                            applicationContext,
                            sessionId,
                            sessionTitle ?: "ClawChat",
                            approvalId,
                            toolName,
                            risk
                        )
                        result.success(shown)
                    }
                }
                "clearToolApprovalNotification" -> {
                    val sessionId = call.argument<String>("sessionId")
                    val approvalId = call.argument<String>("approvalId")
                    if (sessionId.isNullOrBlank() || approvalId.isNullOrBlank()) {
                        result.error("INVALID_ARGS", "approval identity required", null)
                    } else {
                        AgentTaskService.clearToolApproval(
                            sessionId,
                            approvalId
                        )
                        result.success(true)
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
                    val allowedRoots = call.argument<List<String>>("allowedRoots") ?: listOf("/")
                    if (path != null) {
                        Thread {
                            try {
                                val content = bootstrapManager.readRootfsFile(path, allowedRoots)
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
                    val allowedRoots = call.argument<List<String>>("allowedRoots") ?: listOf("/")
                    val createNew = call.argument<Boolean>("createNew") ?: false
                    if (path != null && content != null) {
                        Thread {
                            try {
                                bootstrapManager.writeRootfsFile(path, content, allowedRoots, createNew)
                                safeRunOnUiThread { result.success(true) }
                            } catch (e: Exception) {
                                safeRunOnUiThread { result.error("ROOTFS_WRITE_ERROR", e.message, null) }
                            }
                        }.start()
                    } else {
                        result.error("INVALID_ARGS", "path and content required", null)
                    }
                }
                "writeRootfsBytes" -> {
                    val path = call.argument<String>("path")
                    val bytes = call.argument<ByteArray>("bytes")
                    val allowedRoots = call.argument<List<String>>("allowedRoots") ?: listOf("/")
                    val createNew = call.argument<Boolean>("createNew") ?: false
                    if (path != null && bytes != null) {
                        Thread {
                            try {
                                bootstrapManager.writeRootfsBytes(path, bytes, allowedRoots, createNew)
                                safeRunOnUiThread { result.success(true) }
                            } catch (e: Exception) {
                                safeRunOnUiThread { result.error("ROOTFS_WRITE_ERROR", e.message, null) }
                            }
                        }.start()
                    } else {
                        result.error("INVALID_ARGS", "path and bytes required", null)
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
                    } else if (action in setOf("listCalendarEvents", "listContacts", "insertCalendarEvent", "sendSms")) {
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
                    val operationId = call.argument<String>("operationId")
                    if (operationId.isNullOrBlank()) {
                        result.error("INVALID_ARGS", "operationId required", null)
                        return@setMethodCallHandler
                    }
                    var recorder: MediaRecorder? = null
                    var path: String? = null
                    try {
                        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
                            != PackageManager.PERMISSION_GRANTED
                        ) {
                            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.RECORD_AUDIO), AUDIO_PERMISSION_REQUEST)
                            result.error("PERMISSION_DENIED", "Audio permission not granted", null)
                            return@setMethodCallHandler
                        }
                        if (mediaRecorder != null || recordingOperationId != null) {
                            result.error("RECORD_BUSY", "A recording is already active", null)
                            return@setMethodCallHandler
                        }
                        cleanupOldWhisperRecordingCache()
                        val uniquePath = File(
                            applicationContext.cacheDir,
                            "whisper_${UUID.randomUUID()}.m4a"
                        ).canonicalPath
                        path = uniquePath
                        @Suppress("DEPRECATION")
                        val createdRecorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            MediaRecorder(this)
                        } else {
                            MediaRecorder()
                        }
                        recorder = createdRecorder
                        createdRecorder.setAudioSource(MediaRecorder.AudioSource.MIC)
                        createdRecorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                        createdRecorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                        createdRecorder.setAudioSamplingRate(16000)
                        createdRecorder.setAudioEncodingBitRate(64000)
                        createdRecorder.setAudioChannels(1)
                        createdRecorder.setOutputFile(uniquePath)
                        createdRecorder.prepare()
                        createdRecorder.start()
                        mediaRecorder = createdRecorder
                        recordingPath = uniquePath
                        recordingOperationId = operationId
                        result.success(mapOf("operationId" to operationId, "path" to uniquePath))
                    } catch (e: Exception) {
                        try { recorder?.release() } catch (_: Exception) {}
                        if (mediaRecorder === recorder) mediaRecorder = null
                        if (recordingOperationId == operationId) recordingOperationId = null
                        if (recordingPath == path) recordingPath = null
                        deleteWhisperRecordingCache(path)
                        result.error("RECORD_ERROR", "Recording failed", null)
                    }
                }
                "stopRecording" -> {
                    val operationId = call.argument<String>("operationId")
                    if (operationId.isNullOrBlank()) {
                        result.error("INVALID_ARGS", "operationId required", null)
                        return@setMethodCallHandler
                    }
                    if (operationId != recordingOperationId) {
                        result.success(mapOf("operationId" to operationId, "path" to null, "stopped" to false))
                        return@setMethodCallHandler
                    }
                    val recorder = mediaRecorder
                    val path = recordingPath
                    mediaRecorder = null
                    recordingPath = null
                    recordingOperationId = null
                    try {
                        recorder?.stop()
                        recorder?.release()
                        result.success(mapOf("operationId" to operationId, "path" to path, "stopped" to true))
                    } catch (e: Exception) {
                        try { recorder?.release() } catch (_: Exception) {}
                        deleteWhisperRecordingCache(path)
                        result.error("RECORD_ERROR", "Recording stop failed", null)
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
                "verifyUpdateSignature" -> {
                    val payload = call.argument<String>("payload")
                    val encodedSignature = call.argument<String>("signature")
                    val algorithm = call.argument<String>("algorithm")
                    val keyId = call.argument<String>("keyId")
                    if (payload == null || encodedSignature == null ||
                        algorithm == null || keyId == null) {
                        result.error("INVALID_ARGS", "signed update metadata required", null)
                    } else {
                        result.success(
                            verifyUpdateSignature(payload, encodedSignature, algorithm, keyId)
                        )
                    }
                }
                "handoffVerifiedApk" -> {
                    val path = call.argument<String>("path")
                    val expectedSize = call.argument<Number>("size")?.toLong()
                    val expectedSha256 = call.argument<String>("sha256")
                    if (path == null || expectedSize == null || expectedSha256 == null) {
                        result.error("INVALID_ARGS", "verified APK metadata required", null)
                    } else {
                        try {
                            val file = verifiedUpdateApk(path, expectedSize, expectedSha256)
                            val intentPlan = VerifiedApkUpdate.intentPlan(
                                applicationContext.packageName
                            )
                            val uri = FileProvider.getUriForFile(
                                this,
                                intentPlan.authority,
                                file
                            )
                            val installIntent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, intentPlan.mimeType)
                                if (intentPlan.grantReadPermission) {
                                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                }
                            }
                            if (installIntent.resolveActivity(packageManager) == null) {
                                throw IllegalStateException("system package installer unavailable")
                            }
                            startActivity(installIntent)
                            result.success(true)
                        } catch (_: Throwable) {
                            result.error("APK_HANDOFF_ERROR", "unable to hand off verified APK", null)
                        }
                    }
                }
                "playAudio" -> {
                    val path = call.argument<String>("path")
                    val operationId = call.argument<String>("operationId")
                    if (path == null || operationId == null) {
                        result.error("INVALID_ARGS", "path and operationId required", null)
                    } else if (!isAppOwnedPath(path)) {
                        result.error("INVALID_PATH", "path must be in app cache or files dir", null)
                    } else {
                        var attemptedPlayer: MediaPlayer? = null
                        try {
                            mediaPlayer?.release()
                            mediaPlayer = null
                            deleteTtsPlaybackCache(mediaPlaybackPath)
                            mediaPlaybackOperationId = null
                            mediaPlaybackPath = path
                            val player = MediaPlayer()
                            attemptedPlayer = player
                            mediaPlayer = player
                            mediaPlaybackOperationId = operationId
                            player.apply {
                                setAudioAttributes(
                                    android.media.AudioAttributes.Builder()
                                        .setUsage(android.media.AudioAttributes.USAGE_MEDIA)
                                        .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SPEECH)
                                        .build()
                                )
                                setVolume(1.0f, 1.0f)
                                setDataSource(path)
                                setOnCompletionListener { completedPlayer ->
                                    safeRunOnUiThread {
                                        MethodChannel(
                                            flutterEngine.dartExecutor.binaryMessenger,
                                            CHANNEL
                                        ).invokeMethod(
                                            "onAudioComplete",
                                            mapOf(
                                                "operationId" to operationId,
                                                "event" to "complete"
                                            )
                                        )
                                    }
                                    deleteTtsPlaybackCache(path)
                                    try { completedPlayer.release() } catch (_: Exception) {}
                                    if (mediaPlayer === completedPlayer && mediaPlaybackOperationId == operationId) {
                                        mediaPlayer = null
                                        mediaPlaybackPath = null
                                        mediaPlaybackOperationId = null
                                    }
                                }
                                setOnErrorListener { failedPlayer, what, _ ->
                                    Log.e("ClawChat", "MediaPlayer playback error code=$what")
                                    safeRunOnUiThread {
                                        MethodChannel(
                                            flutterEngine.dartExecutor.binaryMessenger,
                                            CHANNEL
                                        ).invokeMethod(
                                            "onAudioComplete",
                                            mapOf(
                                                "operationId" to operationId,
                                                "event" to "error"
                                            )
                                        )
                                    }
                                    deleteTtsPlaybackCache(path)
                                    try { failedPlayer.release() } catch (_: Exception) {}
                                    if (mediaPlayer === failedPlayer && mediaPlaybackOperationId == operationId) {
                                        mediaPlayer = null
                                        mediaPlaybackPath = null
                                        mediaPlaybackOperationId = null
                                    }
                                    true
                                }
                                prepare()
                                start()
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            try { attemptedPlayer?.release() } catch (_: Exception) {}
                            if (mediaPlayer === attemptedPlayer && mediaPlaybackOperationId == operationId) {
                                mediaPlayer = null
                                mediaPlaybackPath = null
                                mediaPlaybackOperationId = null
                            }
                            deleteTtsPlaybackCache(path)
                            result.error("PLAY_ERROR", "Playback failed", null)
                        }
                    }
                }
                "stopAudio" -> {
                    val operationId = call.argument<String>("operationId")
                    if (operationId.isNullOrBlank() || operationId != mediaPlaybackOperationId) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    val player = mediaPlayer
                    val path = mediaPlaybackPath
                    mediaPlayer = null
                    mediaPlaybackPath = null
                    mediaPlaybackOperationId = null
                    var stopFailed = false
                    try { player?.stop() } catch (_: Exception) { stopFailed = true }
                    try { player?.release() } catch (_: Exception) { stopFailed = true }
                    deleteTtsPlaybackCache(path)
                    if (stopFailed) {
                        result.error("STOP_ERROR", "Playback stop failed", null)
                    } else {
                        result.success(true)
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
                "consumePendingNavigateToSession" -> {
                    result.success(pendingNavigateToSessionId)
                    pendingNavigateToSessionId = null
                }
                "consumePendingShareIntent" -> {
                    result.success(pendingShareIntent)
                    pendingShareIntent = null
                }
                else -> result.notImplemented()
            }
        }

        val callbackChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AGENT_CALLBACK_CHANNEL
        )
        detachAgentCallbackChannel(flutterEngine)
        val callbackGeneration = AgentTaskService.attachCallbackChannel(callbackChannel)
        agentCallbackOwners[flutterEngine] = callbackChannel to callbackGeneration
        createNotificationChannel()
        createAgentCompleteNotificationChannel()
        requestNotificationPermission()
        handleNavigateToSession(intent)
        handleShareIntent(intent)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        detachAgentCallbackChannel(flutterEngine)
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun detachAgentCallbackChannel(flutterEngine: FlutterEngine) {
        val owner = agentCallbackOwners.remove(flutterEngine) ?: return
        AgentTaskService.detachCallbackChannel(owner.first, owner.second)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleNavigateToSession(intent)
        handleShareIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        activityResumed = true
    }

    override fun onPause() {
        activityResumed = false
        super.onPause()
    }

    private fun handleShareIntent(intent: Intent?) {
        if (intent == null || intent.getBooleanExtra(SHARE_CONSUMED_EXTRA, false)) return
        val action = intent.action ?: return
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) return

        val shareIntent = Intent(intent)
        intent.putExtra(SHARE_CONSUMED_EXTRA, true)
        Thread {
            cleanupOldSharedIntentCache()
            val payload = try {
                parseShareIntent(shareIntent)
            } catch (_: Exception) {
                mapOf(
                    "text" to "",
                    "subject" to null,
                    "images" to emptyList<Map<String, Any?>>(),
                    "errors" to listOf("Unable to import shared content")
                )
            }
            safeRunOnUiThread {
                deliverSharePayload(payload)
            }
        }.start()
    }

    private fun deliverSharePayload(payload: Map<String, Any?>) {
        val hasText = (payload["text"] as? String)?.isNotBlank() == true
        val hasImages = (payload["images"] as? List<*>)?.isNotEmpty() == true
        val hasErrors = (payload["errors"] as? List<*>)?.isNotEmpty() == true
        if (!hasText && !hasImages && !hasErrors) return

        pendingShareIntent = payload
        shareCallbackChannel?.invokeMethod(
            "onShareIntent",
            payload,
            object : MethodChannel.Result {
                override fun success(result: Any?) {
                    if (result == true) pendingShareIntent = null
                }

                override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                }

                override fun notImplemented() {
                }
            }
        )
    }

    private fun parseShareIntent(intent: Intent): Map<String, Any?> {
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()?.trim().orEmpty()
        val subject = intent.getCharSequenceExtra(Intent.EXTRA_SUBJECT)?.toString()?.trim()
        val images = mutableListOf<Map<String, Any?>>()
        val errors = mutableListOf<String>()
        val seenUris = mutableSetOf<String>()
        var imageCandidates = 0
        var skippedImageCount = 0

        for (uri in sharedStreamUris(intent)) {
            if (!seenUris.add(uri.toString())) continue
            val mimeType = contentResolver.getType(uri) ?: intent.type.orEmpty()
            if (!mimeType.startsWith("image/")) {
                errors.add("Unsupported shared file type: ${mimeType.ifBlank { "unknown" }}")
                continue
            }
            if (imageCandidates >= MAX_SHARED_IMAGES) {
                skippedImageCount += 1
                continue
            }
            val imageIndex = imageCandidates
            imageCandidates += 1
            try {
                images.add(copySharedImageToCache(uri, imageIndex, mimeType))
            } catch (e: Exception) {
                errors.add(e.message ?: "Unable to import shared image")
            }
        }
        if (skippedImageCount > 0) {
            errors.add(
                "Shared image limit is $MAX_SHARED_IMAGES; skipped $skippedImageCount extra image(s)"
            )
        }

        return mapOf(
            "text" to text,
            "subject" to subject,
            "images" to images,
            "errors" to errors
        )
    }

    @Suppress("DEPRECATION")
    private fun sharedStreamUris(intent: Intent): List<Uri> {
        val uris = mutableListOf<Uri>()
        val single = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
        if (single != null) uris.add(single)
        val multiple = intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
        if (multiple != null) uris.addAll(multiple)
        val clipData = intent.clipData
        if (clipData != null) {
            for (i in 0 until clipData.itemCount) {
                clipData.getItemAt(i).uri?.let { uris.add(it) }
            }
        }
        return uris
    }

    private fun copySharedImageToCache(
        uri: Uri,
        index: Int,
        mimeType: String
    ): Map<String, Any?> {
        val declaredSize = queryOpenableLong(uri, OpenableColumns.SIZE)
        if (declaredSize != null && declaredSize > MAX_SHARED_IMAGE_BYTES) {
            throw IllegalArgumentException(
                "Shared image is too large (${declaredSize} bytes)"
            )
        }

        val displayName = queryOpenableString(uri, OpenableColumns.DISPLAY_NAME)
            ?: "shared-image-$index${extensionForMime(mimeType)}"
        val safeName = sanitizeSharedFileName(displayName)
        val dir = File(cacheDir, SHARED_INTENT_CACHE_DIR).apply { mkdirs() }
        val dest = File(dir, "${System.currentTimeMillis()}-$index-$safeName")
        var total = 0L

        val input = contentResolver.openInputStream(uri)
            ?: throw IllegalArgumentException("Unable to open shared image")
        input.use { source ->
            dest.outputStream().use { target ->
                val buffer = ByteArray(16 * 1024)
                while (true) {
                    val read = source.read(buffer)
                    if (read < 0) break
                    total += read.toLong()
                    if (total > MAX_SHARED_IMAGE_BYTES) {
                        target.close()
                        dest.delete()
                        throw IllegalArgumentException("Shared image is too large")
                    }
                    target.write(buffer, 0, read)
                }
            }
        }

        return mapOf(
            "path" to dest.absolutePath,
            "name" to safeName,
            "size" to total,
            "mimeType" to mimeType
        )
    }

    private fun queryOpenableString(uri: Uri, column: String): String? {
        return try {
            contentResolver.query(uri, arrayOf(column), null, null, null)?.use { cursor ->
                val index = cursor.getColumnIndex(column)
                if (index >= 0 && cursor.moveToFirst()) cursor.getString(index) else null
            }
        } catch (_: Exception) { null }
    }

    private fun queryOpenableLong(uri: Uri, column: String): Long? {
        return try {
            contentResolver.query(uri, arrayOf(column), null, null, null)?.use { cursor ->
                val index = cursor.getColumnIndex(column)
                if (index < 0 || !cursor.moveToFirst()) return@use null
                if (cursor.isNull(index)) null else cursor.getLong(index)
            }
        } catch (_: Exception) { null }
    }

    private fun sanitizeSharedFileName(name: String): String {
        val sanitized = name.replace(Regex("[^A-Za-z0-9._-]"), "_")
            .trim('_', '.', '-')
        return sanitized.ifBlank { "shared-image" }
    }

    private fun extensionForMime(mimeType: String): String {
        return when (mimeType.lowercase()) {
            "image/jpeg", "image/jpg" -> ".jpg"
            "image/gif" -> ".gif"
            "image/webp" -> ".webp"
            else -> ".png"
        }
    }

    private fun cleanupOldSharedIntentCache() {
        val cutoff = System.currentTimeMillis() - SHARED_INTENT_CACHE_TTL_MS
        val dir = File(cacheDir, SHARED_INTENT_CACHE_DIR)
        if (!dir.exists()) return
        try {
            dir.listFiles()?.forEach { file ->
                val modified = file.lastModified()
                if (file.isFile && modified > 0 && modified < cutoff) {
                    file.delete()
                }
            }
        } catch (_: Exception) {
        }
    }

    private fun handleNavigateToSession(intent: Intent?) {
        val sessionId = intent?.getStringExtra("navigateToSession") ?: return
        pendingNavigateToSessionId = sessionId
        val messenger = flutterEngine?.dartExecutor?.binaryMessenger ?: return
        MethodChannel(messenger, AGENT_CALLBACK_CHANNEL).invokeMethod(
            "navigateToSession",
            mapOf("sessionId" to sessionId),
            object : MethodChannel.Result {
                override fun success(result: Any?) {
                    if (pendingNavigateToSessionId == sessionId) {
                        pendingNavigateToSessionId = null
                    }
                }

                override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                }

                override fun notImplemented() {
                }
            }
        )
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

    private fun verifyUpdateSignature(
        payload: String,
        encodedSignature: String,
        algorithm: String,
        keyId: String
    ): Boolean {
        if (algorithm != "SHA256withRSA" && algorithm != "SHA256withECDSA") return false
        if (!keyId.matches(Regex("^[a-f0-9]{64}$"))) return false
        return try {
            val payloadBytes = Base64.decode(payload, Base64.NO_WRAP)
            val signatureBytes = Base64.decode(encodedSignature, Base64.NO_WRAP)
            if (payloadBytes.isEmpty() || signatureBytes.isEmpty()) return false
            val certificateBytes = currentSigningCertificateBytes() ?: return false
            val actualKeyId = MessageDigest.getInstance("SHA-256")
                .digest(certificateBytes)
                .joinToString("") { "%02x".format(it.toInt() and 0xff) }
            if (actualKeyId != keyId) return false
            val certificate = CertificateFactory.getInstance("X.509")
                .generateCertificate(ByteArrayInputStream(certificateBytes))
            val verifier = CryptoSignature.getInstance(algorithm)
            verifier.initVerify(certificate.publicKey)
            verifier.update(payloadBytes)
            verifier.verify(signatureBytes)
        } catch (_: Throwable) {
            false
        }
    }

    @Suppress("DEPRECATION")
    private fun currentSigningCertificateBytes(): ByteArray? {
        val packageInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            packageManager.getPackageInfo(
                packageName,
                PackageManager.GET_SIGNING_CERTIFICATES
            )
        } else {
            packageManager.getPackageInfo(packageName, PackageManager.GET_SIGNATURES)
        }
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            packageInfo.signingInfo?.apkContentsSigners
        } else {
            packageInfo.signatures
        }
        return signatures?.singleOrNull()?.toByteArray()
    }

    private fun verifiedUpdateApk(
        path: String,
        expectedSize: Long,
        expectedSha256: String
    ): File {
        return VerifiedApkUpdate.verify(
            path,
            File(cacheDir, "updates"),
            expectedSize,
            expectedSha256
        )
    }

    override fun onDestroy() {
        for (engine in agentCallbackOwners.keys.toList()) {
            detachAgentCallbackChannel(engine)
        }
        try { pendingSpeechResult?.success("") } catch (_: Exception) {}
        pendingSpeechResult = null
        val abandonedRecordingPath = recordingPath
        try { mediaRecorder?.stop() } catch (_: Exception) {}
        try { mediaRecorder?.release() } catch (_: Exception) {}
        mediaRecorder = null
        recordingPath = null
        recordingOperationId = null
        deleteWhisperRecordingCache(abandonedRecordingPath)
        cleanupOldWhisperRecordingCache()
        try { mediaPlayer?.stop() } catch (_: Exception) {}
        try { mediaPlayer?.release() } catch (_: Exception) {}
        mediaPlayer = null
        deleteTtsPlaybackCache(mediaPlaybackPath)
        mediaPlaybackPath = null
        mediaPlaybackOperationId = null
        secureImportExecutor.shutdownNow()
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
        const val SHARE_CALLBACK_CHANNEL = "com.anka.clawbot/native/share_callbacks"
        const val AGENT_COMPLETE_CHANNEL_ID = "clawchat_agent_complete_v2"
        const val NOTIFICATION_PERMISSION_REQUEST = 1001
        const val STORAGE_PERMISSION_REQUEST = 1003
        const val AUDIO_PERMISSION_REQUEST = 1004
        const val SPEECH_REQUEST = 1005
        const val TOOL_AUTO_APPROVED_NOTIFICATION_ID = 2001
        const val AGENT_COMPLETE_NOTIFICATION_ID = 2002
        const val WHISPER_ORPHAN_MAX_AGE_MS = 24L * 60L * 60L * 1000L
        const val SHARE_CONSUMED_EXTRA = "com.anka.clawbot.SHARE_CONSUMED"
        const val MAX_SHARED_IMAGE_BYTES = 3L * 1024L * 1024L
        const val MAX_SHARED_IMAGES = 9
        const val SHARED_INTENT_CACHE_DIR = "shared_intents"
        const val SHARED_INTENT_CACHE_TTL_MS = 7L * 24L * 60L * 60L * 1000L
    }
}
