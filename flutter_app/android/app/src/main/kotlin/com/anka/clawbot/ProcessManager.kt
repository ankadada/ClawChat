package com.anka.clawbot

import android.os.Build
import android.os.Environment
import android.util.Log
import java.io.BufferedInputStream
import java.io.BufferedReader
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStreamReader
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

/**
 * Manages proot process execution, matching Termux proot-distro as closely
 * as possible. Two command modes:
 *   - Install mode (buildInstallCommand): matches proot-distro's run_proot_cmd()
 *   - Gateway mode (buildGatewayCommand): matches proot-distro's command_login()
 */
/**
 * One MCP start's launch script.
 *
 * [identity] is the native device:inode of the start directory this launch
 * created. Cleanup passes it back to the broker, which refuses to delete a
 * directory that no longer has that identity: a substituted node is left alone
 * instead of being removed through.
 */
internal data class McpLaunchScript(
    val homeDir: String,
    val runSegment: String,
    val serverSegment: String,
    val startName: String,
    val identity: String,
    val hostPath: File,
    val guestPath: String,
)

internal class ProcessManager(
    private val filesDir: String,
    private val nativeLibDir: String,
    private val cleanupCoordinator: CommandCleanupCoordinator? = null,
    private val processStarter: (ProcessBuilder) -> Process = { it.start() },
) {
    private val activeOperations = ConcurrentHashMap<String, Process>()
    private val cancelledOperations = ConcurrentHashMap.newKeySet<String>()
    private val rootfsDir get() = "$filesDir/rootfs/alpine"
    private val tmpDir get() = "$filesDir/tmp"
    private val homeDir get() = "$filesDir/home"
    private val configDir get() = "$filesDir/config"
    private val libDir get() = "$filesDir/lib"

    companion object {
        // Match proot-distro v4.37.0 defaults
        const val FAKE_KERNEL_RELEASE = "6.17.0-PRoot-Distro"
        const val FAKE_KERNEL_VERSION =
            "#1 SMP PREEMPT_DYNAMIC Fri, 10 Oct 2025 00:00:00 +0000"
        private const val TAG = "ClawChat"
        /** Hard limit on one MCP stdio line, in UTF-8 bytes. */
        const val MCP_MAX_LINE_BYTES = 1024 * 1024
        /**
         * Hard limit on one MCP stdin frame, in UTF-8 bytes. The frame is the
         * payload plus its newline terminator, and this is the same bound the
         * Dart side applies before calling writeMcpStdioLine.
         */
        const val MCP_MAX_STDIN_LINE_BYTES = 1024 * 1024
        /**
         * How long a child whose stdout already closed may keep running before
         * it is treated as wedged and stopped.
         */
        private const val MCP_STDOUT_EOF_GRACE_MS = 2000L
        /**
         * Launch-script directories older than this are leftovers from a crash
         * or a kill and are swept on the next start or teardown.
         */
        internal const val MCP_LAUNCH_SCRIPT_STALE_MS = 60L * 60L * 1000L
        /** Hard limit on MCP stdio lines per second, per stream. */
        const val MCP_MAX_LINES_PER_SECOND = 200

        /**
         * Removes launch-script directories under [homeDir] that no live child
         * owns: leftovers from a crash, a kill, or a process that died before
         * its reap ran.
         *
         * A live child's directory is never touched, and neither is a directory
         * still inside the grace window, so a start that is in flight keeps its
         * script. Shared by the app (start and engine teardown) and by the agent
         * service (its own teardown), so both paths clean the same tree.
         */
        internal fun sweepStaleMcpLaunchScriptsIn(
            homeDir: File,
            maxAgeMs: Long = MCP_LAUNCH_SCRIPT_STALE_MS,
        ): Int = try {
            SecureImportNative.sweepMcpLaunchDirectories(
                homeDir.absolutePath,
                maxAgeMs,
                McpStdioRegistry.liveLaunchIdentities().toTypedArray(),
            )
        } catch (_: Throwable) {
            // No native broker, or a tree we refuse to touch: nothing is swept
            // here and the next start retries.
            0
        }

        /**
         * Removes one start's directory through the native broker, which only
         * deletes the directory whose identity matches the one that start
         * created and never follows a symlink inside it.
         */
        internal fun deleteMcpLaunchScript(script: McpLaunchScript) {
            try {
                SecureImportNative.deleteMcpLaunchDirectory(
                    script.homeDir,
                    script.runSegment,
                    script.serverSegment,
                    script.startName,
                    script.identity,
                )
            } catch (_: Throwable) {
                // Best effort: the sweep collects what is left later.
            }
        }

        private const val MCP_READ_CHUNK_BYTES = 8 * 1024
        private const val NANOS_PER_SECOND = 1_000_000_000L
        private val SCOPED_ENVIRONMENT_KEYS = setOf(
            "LARKSUITE_CLI_APP_ID",
            "LARKSUITE_CLI_APP_SECRET",
        )
        private const val SCOPED_GUEST_ENV_BOOTSTRAP =
            "unset PROOT_TMP_DIR PROOT_LOADER PROOT_LOADER_32 LD_LIBRARY_PATH; " +
                "export HOME=/root LANG=C.UTF-8 " +
                "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin " +
                "TERM=xterm-256color TMPDIR=/tmp; " +
                "exec /bin/sh -c \"\$1\""
    }

    fun getProotPath(): String = "$nativeLibDir/libproot.so"

    // ================================================================
    // Host-side environment for proot binary itself.
    // ONLY proot-specific vars — guest env is set via `env -i` inside
    // the command line, matching proot-distro's approach.
    // ================================================================
    private fun prootEnv(): Map<String, String> = mapOf(
        // proot temp directory for its internal use
        "PROOT_TMP_DIR" to tmpDir,
        // Loader executables for proot's execve interception
        "PROOT_LOADER" to "$nativeLibDir/libprootloader.so",
        "PROOT_LOADER_32" to "$nativeLibDir/libprootloader32.so",
        // LD_LIBRARY_PATH: proot itself needs libtalloc.so.2
        // This does NOT leak into the guest (env -i cleans it)
        "LD_LIBRARY_PATH" to "$libDir:$nativeLibDir",
        // NOTE: Do NOT set PROOT_NO_SECCOMP. proot-distro does NOT set it.
        // Seccomp BPF filter provides efficient syscall interception AND
        // proper fork/clone child process tracking.
        //
        // NOTE: Do NOT set PROOT_L2S_DIR. We extract with Java, not
        // `proot --link2symlink tar`, so no L2S metadata exists.
    )

    // ================================================================
    // Common proot flags shared by both install and gateway modes.
    // Matches proot-distro's bind mounts exactly.
    // ================================================================
    /**
     * Ensure resolv.conf exists before any proot invocation.
     * This is the single chokepoint — every proot operation flows through
     * commonProotFlags(), so resolv.conf is guaranteed for all callers.
     */
    private fun ensureResolvConf() {
        val content = "nameserver 8.8.8.8\nnameserver 8.8.4.4\n"

        // Primary: host-side file used by --bind mount
        try {
            val resolvFile = File(configDir, "resolv.conf")
            if (!resolvFile.exists() || resolvFile.length() == 0L) {
                resolvFile.parentFile?.mkdirs()
                resolvFile.writeText(content)
            }
        } catch (e: Exception) {
            Log.w("ClawChat", "ensureResolvConf: primary resolv.conf write failed", e)
        }

        // Fallback: write directly into rootfs /etc/resolv.conf
        // so DNS works even if the bind-mount fails
        try {
            val rootfsResolv = File(rootfsDir, "etc/resolv.conf")
            if (!rootfsResolv.exists() || rootfsResolv.length() == 0L) {
                rootfsResolv.parentFile?.mkdirs()
                rootfsResolv.writeText(content)
            }
        } catch (e: Exception) {
            Log.w("ClawChat", "ensureResolvConf: rootfs resolv.conf write failed", e)
        }
    }

    private fun commonProotFlags(mountStorage: Boolean): List<String> {
        // Guarantee resolv.conf exists before building the bind-mount list
        ensureResolvConf()

        val prootPath = getProotPath()
        val procFakes = "$configDir/proc_fakes"
        val sysFakes = "$configDir/sys_fakes"

        return listOf(
            prootPath,
            "--link2symlink",
            "-L",
            "--kill-on-exit",
            "--rootfs=$rootfsDir",
            "--cwd=/root",
            // Core device binds (matching proot-distro)
            "--bind=/dev",
            "--bind=/dev/urandom:/dev/random",
            "--bind=/proc",
            "--bind=/proc/self/fd:/dev/fd",
            "--bind=/proc/self/fd/0:/dev/stdin",
            "--bind=/proc/self/fd/1:/dev/stdout",
            "--bind=/proc/self/fd/2:/dev/stderr",
            "--bind=/sys",
            // Fake /proc entries — Android restricts most /proc access.
            // proot-distro's run_proot_cmd() binds these unconditionally.
            "--bind=$procFakes/loadavg:/proc/loadavg",
            "--bind=$procFakes/stat:/proc/stat",
            "--bind=$procFakes/uptime:/proc/uptime",
            "--bind=$procFakes/version:/proc/version",
            "--bind=$procFakes/vmstat:/proc/vmstat",
            "--bind=$procFakes/cap_last_cap:/proc/sys/kernel/cap_last_cap",
            "--bind=$procFakes/max_user_watches:/proc/sys/fs/inotify/max_user_watches",
            // Extra: libgcrypt reads this; missing causes apt SIGABRT
            "--bind=$procFakes/fips_enabled:/proc/sys/crypto/fips_enabled",
            // Shared memory — proot-distro binds rootfs/tmp to /dev/shm
            "--bind=$rootfsDir/tmp:/dev/shm",
            // SELinux override — empty dir disables SELinux checks
            "--bind=$sysFakes/empty:/sys/fs/selinux",
            // App-specific binds
            "--bind=$configDir/resolv.conf:/etc/resolv.conf",
            "--bind=$homeDir:/root/home",
        ).let { flags ->
            // Bind-mount shared storage into proot (Termux proot-distro style).
            // Bind the whole /storage tree so symlinks and sub-mounts resolve.
            // Then create /sdcard symlink inside rootfs pointing to the right path.
            val hasAccess = mountStorage && (
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    Environment.isExternalStorageManager()
                } else {
                    val sdcard = Environment.getExternalStorageDirectory()
                    sdcard.exists() && sdcard.canRead()
                }
            )

            if (hasAccess) {
                val storageDir = File("$rootfsDir/storage")
                storageDir.mkdirs()
                // Create /sdcard symlink → /storage/emulated/0 inside rootfs
                val sdcardLink = File("$rootfsDir/sdcard")
                if (!sdcardLink.exists()) {
                    try {
                        Runtime.getRuntime().exec(
                            arrayOf("ln", "-sf", "/storage/emulated/0", "$rootfsDir/sdcard")
                        ).waitFor()
                    } catch (e: Exception) {
                        Log.w("ClawChat", "sdcard symlink creation failed, using directory fallback", e)
                        // Fallback: create as directory if symlink fails
                        sdcardLink.mkdirs()
                    }
                }
                flags + listOf(
                    "--bind=/storage:/storage",
                    "--bind=/storage/emulated/0:/sdcard"
                )
            } else {
                flags
            }
        }
    }

    // ================================================================
    // INSTALL MODE — matches proot-distro's run_proot_cmd()
    // Used for: apt-get, dpkg, npm install, chmod, etc.
    // Simpler: no --sysvipc, simple kernel-release, minimal guest env.
    // ================================================================
    fun buildInstallCommand(
        command: String,
        mountStorage: Boolean = false,
        preserveScopedEnvironment: Boolean = false,
    ): List<String> {
        val flags = commonProotFlags(mountStorage).toMutableList()

        // --root-id: fake root identity (same as proot-distro run_proot_cmd)
        flags.add(1, "--root-id")
        // Simple kernel-release (proot-distro run_proot_cmd uses plain string)
        flags.add(2, "--kernel-release=$FAKE_KERNEL_RELEASE")
        // NOTE: --sysvipc is NOT used during install (matches proot-distro).
        // It causes SIGABRT when dpkg forks child processes.

        // Guest environment via env -i (matching proot-distro's run_proot_cmd)
        // Use /bin/sh instead of /bin/bash because Alpine minirootfs only has
        // busybox sh initially; bash is installed later via apk add.
        if (preserveScopedEnvironment) {
            // The ProcessBuilder environment was already cleared and contains
            // only PRoot loader variables plus the two approved Lark names.
            // A constant positional bootstrap removes loader variables without
            // ever placing credential values in argv or a file.
            flags.addAll(listOf(
                "/bin/sh", "-c",
                SCOPED_GUEST_ENV_BOOTSTRAP,
                "clawchat-scoped-env",
                command,
            ))
        } else {
            flags.addAll(listOf(
                "/usr/bin/env", "-i",
                "HOME=/root",
                "LANG=C.UTF-8",
                "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                "TERM=xterm-256color",
                "TMPDIR=/tmp",
                "/bin/sh", "-c",
                command,
            ))
        }

        return flags
    }

    // ================================================================
    // GATEWAY MODE — matches proot-distro's command_login()
    // Used for: running openclaw gateway (long-lived Node.js process).
    // Full featured: --sysvipc, full uname struct, more guest env vars.
    // ================================================================
    fun buildShellCommand(command: String, mountStorage: Boolean = false): List<String> {
        val flags = commonProotFlags(mountStorage).toMutableList()
        val arch = ArchUtils.getArch()
        val machine = when (arch) {
            "arm" -> "armv7l"
            else -> arch
        }

        flags.add(1, "--change-id=0:0")
        flags.add(2, "--sysvipc")
        val kernelRelease = "\\Linux\\localhost\\$FAKE_KERNEL_RELEASE" +
            "\\$FAKE_KERNEL_VERSION\\$machine\\localdomain\\-1\\"
        flags.add(3, "--kernel-release=$kernelRelease")

        // Use bash if available (installed via apk), fall back to sh.
        // Both /bin/sh and /bin/bash are symlinks to /bin/busybox inside the rootfs.
        // Java's File.exists() follows symlinks and sees them as dangling on the host
        // (they point to absolute paths like /bin/busybox which don't exist on Android).
        // Use Files.isSymbolicLink() to check the symlink node itself.
        val shell = if (java.nio.file.Files.isSymbolicLink(
            java.nio.file.Paths.get("$rootfsDir/bin/bash"))) "/bin/bash" else "/bin/sh"
        flags.addAll(listOf(
            "/usr/bin/env", "-i",
            "HOME=/root",
            "USER=root",
            "LANG=C.UTF-8",
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "TERM=xterm-256color",
            "TMPDIR=/tmp",
            shell, "-c",
            command,
        ))

        return flags
    }

    // ================================================================
    // Execute a command in proot (install mode) and return output.
    // Used during bootstrap for apt, npm, chmod, etc.
    // ================================================================
    internal fun runInProotSync(
        command: String,
        timeoutSeconds: Long = 900,
        mountStorage: Boolean = false,
        operationId: String? = null,
        continuationKey: CommandOwnerKey? = null,
        scopedEnvironment: Map<String, String> = emptyMap(),
    ): String {
        require(continuationKey == null || continuationKey.operationId == operationId) {
            "continuation operation identity mismatch"
        }
        if (operationId != null && cancelledOperations.remove(operationId)) {
            throw InterruptedException("operation cancelled")
        }
        require(validScopedEnvironment(scopedEnvironment)) {
            "invalid scoped command environment"
        }
        val cmd = buildInstallCommand(
            command,
            mountStorage,
            preserveScopedEnvironment = scopedEnvironment.isNotEmpty(),
        )
        val env = prootEnv().toMutableMap().apply { putAll(scopedEnvironment) }
        // Keep this immutable while the reader thread is alive so a slow EOF
        // cannot race cleanup and emit an unredacted trailing line.
        val secretValues = scopedEnvironment.values.sortedByDescending(String::length)
        val process = try {
            try {
                if (continuationKey == null) {
                    startDirectCommand(cmd, env, operationId, scopedEnvironment.keys)
                } else {
                    startContinuationCommand(
                        cmd = cmd,
                        env = env,
                        key = continuationKey,
                        timeoutSeconds = timeoutSeconds,
                        operationId = operationId,
                        scopedEnvironmentKeys = scopedEnvironment.keys,
                    )
                }
            } catch (error: Exception) {
                val safeMessage = redactCredentialValues(
                    error.message ?: "scoped command start failed",
                    secretValues,
                )
                if (scopedEnvironment.isNotEmpty()) {
                    throw IllegalStateException(safeMessage)
                }
                throw error
            }
        } finally {
            scopedEnvironment.keys.forEach(env::remove)
        }
        val output = StringBuilder()
        val errorLines = StringBuilder()
        val outputLock = Any()
        var readerFailure: Exception? = null

        val readerThread = Thread {
            BufferedReader(InputStreamReader(process.inputStream)).use { reader ->
                var line: String?
                while (reader.readLine().also { line = it } != null) {
                    val l = line ?: continue
                    if (l.contains("proot warning") || l.contains("can't sanitize")) {
                        continue
                    }
                    val safeLine = redactCredentialValues(l, secretValues)
                    synchronized(outputLock) {
                        output.appendLine(safeLine)
                        // Collect error-relevant lines (skip apt download noise)
                        if (!safeLine.startsWith("Get:") && !safeLine.startsWith("Fetched ") &&
                            !safeLine.startsWith("Hit:") && !safeLine.startsWith("Ign:") &&
                            !safeLine.contains(" kB]") && !safeLine.contains(" MB]") &&
                            !safeLine.startsWith("Reading package") &&
                            !safeLine.startsWith("Building dependency") &&
                            !safeLine.startsWith("Reading state") &&
                            !safeLine.startsWith("The following") &&
                            !safeLine.startsWith("Need to get") &&
                            !safeLine.startsWith("After this") &&
                            safeLine.trim().isNotEmpty()) {
                            errorLines.appendLine(safeLine)
                        }
                    }
                }
            }
        }.apply {
            isDaemon = true
            setUncaughtExceptionHandler { _, e ->
                if (e is Exception) readerFailure = e
            }
            start()
        }

        return try {
            val exited = try {
                process.waitFor(timeoutSeconds, TimeUnit.SECONDS)
            } catch (e: InterruptedException) {
                retireRunningCommand(process, operationId, continuationKey)
                Thread.currentThread().interrupt()
                throw e
            }
            if (!exited) {
                retireRunningCommand(process, operationId, continuationKey)
                readerThread.join(1000)
                val partialOutput = synchronized(outputLock) {
                    output.toString().takeLast(3000)
                }
                val suffix = if (partialOutput.isBlank()) {
                    ""
                } else {
                    " Partial output:\n$partialOutput"
                }
                throw RuntimeException("Command timed out after ${timeoutSeconds}s.$suffix")
            }
            readerThread.join(1000)
            readerFailure?.let { throw it }

            val exitCode = process.exitValue()
            if (exitCode != 0) {
                val errorOutput = synchronized(outputLock) {
                    errorLines.toString().takeLast(3000).ifEmpty {
                        output.toString().takeLast(3000)
                    }
                }
                throw RuntimeException(
                    "Command failed (exit code $exitCode): $errorOutput"
                )
            }

            synchronized(outputLock) { output.toString() }
        } finally {
            if (continuationKey == null && operationId != null) {
                activeOperations.remove(operationId, process)
                cancelledOperations.remove(operationId)
            }
        }
    }

    /** The historical 2.4/4201 path: no durable admission state before exec. */
    private fun startDirectCommand(
        command: List<String>,
        environment: Map<String, String>,
        operationId: String?,
        scopedEnvironmentKeys: Set<String>,
    ): Process {
        val process = startConfiguredProcess(command, environment, scopedEnvironmentKeys)
        if (operationId == null) return process

        val existing = activeOperations.putIfAbsent(operationId, process)
        if (existing != null) {
            if (process.isAlive) process.destroyForcibly()
            throw IllegalStateException("operation already active")
        }
        if (cancelledOperations.contains(operationId)) {
            destroyDirectProcess(operationId, process)
            cancelledOperations.remove(operationId)
            throw InterruptedException("operation cancelled")
        }
        return process
    }

    private fun startContinuationCommand(
        cmd: List<String>,
        env: Map<String, String>,
        key: CommandOwnerKey,
        timeoutSeconds: Long,
        operationId: String?,
        scopedEnvironmentKeys: Set<String>,
    ): Process {
        val coordinator = cleanupCoordinator
            ?: throw IllegalStateException("durable command launch gate unavailable")
        val preparation = coordinator.prepareLaunch(
            key,
            candidateId = null,
            deadlineEpochMs = System.currentTimeMillis() +
                TimeUnit.SECONDS.toMillis(timeoutSeconds.coerceAtLeast(1L)),
        )
        if (preparation.outcome !=
            DurableLaunchRegistrationOutcome.DURABLY_REGISTERED_BACKSTOP_SCHEDULED) {
            throw IllegalStateException(
                "durable command launch unavailable: ${preparation.failureReason ?: preparation.outcome}",
            )
        }
        val gatedCommand = buildList {
            add("/system/bin/sh")
            add(requireNotNull(preparation.wrapperPath))
            add(requireNotNull(preparation.attemptDirectoryPath))
            add(requireNotNull(preparation.launchToken))
            add(requireNotNull(preparation.parentProcessId).toString())
            add(requireNotNull(preparation.appUid).toString())
            add("--")
            addAll(cmd)
        }

        val attemptId = requireNotNull(preparation.attemptId)
        val launchToken = requireNotNull(preparation.launchToken)
        val cancelledBeforeSpawn = operationId != null && cancelledOperations.contains(operationId)
        if (cancelledBeforeSpawn ||
            !coordinator.validateLaunchCapability(key, null, attemptId, launchToken)) {
            coordinator.acknowledgeLaunchAbandoned(key, null, attemptId, launchToken)
            coordinator.requestCleanup(key)
            if (cancelledBeforeSpawn) throw InterruptedException("operation cancelled")
            throw IllegalStateException("command launch capability was revoked before spawn")
        }
        val process = try {
            startConfiguredProcess(gatedCommand, env, scopedEnvironmentKeys)
        } catch (error: Exception) {
            coordinator.acknowledgeLaunchAbandoned(key, null, attemptId, launchToken)
            throw error
        }
        val ownedProcess = JavaOwnedCommandProcess(process)
        var processId = javaProcessId(process)
        var token: PidGenerationToken? = null
        for (attempt in 0 until 50) {
            if (processId == null) {
                processId = coordinator.waitingLaunchProcessId(
                    key,
                    null,
                    attemptId,
                    launchToken,
                )
            }
            val expected = processId
            if (expected != null) {
                val candidate = coordinator.activateWaitingLaunch(
                    key,
                    candidateId = null,
                    attemptId = attemptId,
                    launchToken = launchToken,
                    expectedProcessId = expected,
                    probe = AndroidCleanupPidAccess.probe,
                )
                if (candidate != null) {
                    token = candidate
                    break
                }
            }
            Thread.sleep(20L)
        }
        if (token == null) {
            while (processId == null && process.isAlive) {
                processId = coordinator.waitingLaunchProcessId(
                    key,
                    null,
                    attemptId,
                    launchToken,
                )
                if (processId == null) Thread.sleep(100L)
            }
            if (processId == null) {
                coordinator.requestCleanup(key)
                NativeCommandContinuationOwner.registry.cancel(key)
                throw IllegalStateException("command launch wrapper exited before PID handshake")
            }
            while (process.isAlive) {
                coordinator.requestWaitingLaunchCleanup(
                    key,
                    candidateId = null,
                    attemptId = attemptId,
                    launchToken = launchToken,
                    expectedProcessId = requireNotNull(processId),
                    probe = AndroidCleanupPidAccess.probe,
                )
                coordinator.reconcile()
                if (process.isAlive) Thread.sleep(100L)
            }
            coordinator.requestWaitingLaunchCleanup(
                key,
                candidateId = null,
                attemptId = attemptId,
                launchToken = launchToken,
                expectedProcessId = requireNotNull(processId),
                probe = AndroidCleanupPidAccess.probe,
            )
            NativeCommandContinuationOwner.registry.cancel(key)
            throw IllegalStateException("command launch wrapper handshake failed")
        }
        run {
            var attachReceipt: CandidateReceipt
            do {
                attachReceipt = NativeCommandContinuationOwner.registry.attachAgent(
                    key,
                    ownedProcess,
                    beforeNativeOwnership = {
                        coordinator.isActiveLaunch(
                            key,
                            null,
                            attemptId,
                            launchToken,
                            token,
                        )
                    },
                    beforeSignal = { coordinator.requestCleanup(key) },
                )
                if (attachReceipt == CandidateReceipt.UNKNOWN) {
                    Thread.sleep(100L)
                }
            } while (attachReceipt == CandidateReceipt.UNKNOWN)
            if (attachReceipt != CandidateReceipt.NATIVE_OWNS) {
                if (attachReceipt == CandidateReceipt.NATIVE_DISPOSED) {
                    coordinator.complete(key)
                } else {
                    coordinator.requestCleanup(key)
                }
                throw IllegalStateException(
                    "foreground continuation lost before command attach: $attachReceipt"
                )
            }
        }
        if (!coordinator.releaseLaunch(
                key,
                null,
                attemptId,
                launchToken,
                token,
            )) {
            coordinator.requestCleanup(key)
            NativeCommandContinuationOwner.registry.cancel(key)
            throw IllegalStateException("command launch GO commit failed")
        }
        return process
    }

    private fun configuredProcessBuilder(
        command: List<String>,
        environment: Map<String, String>,
    ): ProcessBuilder = ProcessBuilder(command).apply {
        // CRITICAL: Clear inherited Android JVM environment. PRoot needs only
        // its loader variables; the guest environment is created by env -i.
        this.environment().clear()
        this.environment().putAll(environment)
        redirectErrorStream(true)
    }

    private fun startConfiguredProcess(
        command: List<String>,
        environment: Map<String, String>,
        scopedEnvironmentKeys: Set<String>,
    ): Process {
        val builder = configuredProcessBuilder(command, environment)
        return try {
            processStarter(builder)
        } finally {
            scopedEnvironmentKeys.forEach(builder.environment()::remove)
        }
    }

    private fun validScopedEnvironment(environment: Map<String, String>): Boolean {
        if (environment.isEmpty()) return true
        if (environment.keys != SCOPED_ENVIRONMENT_KEYS) return false
        return validScopedValue(environment["LARKSUITE_CLI_APP_ID"], 256) &&
            validScopedValue(environment["LARKSUITE_CLI_APP_SECRET"], 512)
    }

    private fun validScopedValue(value: String?, maxLength: Int): Boolean =
        value != null && value.isNotEmpty() && value.length <= maxLength &&
            value.none { it.code < 0x20 || it.code == 0x7f }

    private fun redactCredentialValues(line: String, values: List<String>): String =
        values.fold(line) { redacted, value -> redacted.replace(value, "[REDACTED]") }

    private fun retireRunningCommand(
        process: Process,
        operationId: String?,
        continuationKey: CommandOwnerKey?,
    ) {
        if (continuationKey != null) {
            AgentTaskService.cancelCommand(
                continuationKey.sessionId,
                continuationKey.operationId,
            )
        } else {
            destroyDirectProcess(operationId, process)
        }
    }

    private fun destroyDirectProcess(operationId: String?, process: Process) {
        val ownsProcess = operationId == null || activeOperations.remove(operationId, process)
        if (ownsProcess && process.isAlive) process.destroyForcibly()
    }

    private fun javaProcessId(process: Process): Int? = try {
        val value = Process::class.java.getMethod("pid").invoke(process) as? Long
        value?.takeIf { it in 1..Int.MAX_VALUE }?.toInt()
    } catch (_: Exception) {
        null
    }

    fun cancelOperation(operationId: String) {
        cancelledOperations.add(operationId)
        activeOperations[operationId]?.let { destroyDirectProcess(operationId, it) }
    }

    fun finishOperation(operationId: String) {
        if (!activeOperations.containsKey(operationId)) {
            cancelledOperations.remove(operationId)
        }
    }

    // ================================================================
    // I5 — run-scoped MCP stdio bridge
    //
    // Starts one guest MCP server per (runId, serverId) with a writable stdin
    // and separate stdout/stderr pipes, and registers it so a run end, a
    // cancellation, or a foreground-service teardown can kill it. There is no
    // MCP supervisor.
    //
    // Environment is an allowlist, never inheritance: the guest gets only the
    // fixed baseline (HOME, PATH, LANG, TMPDIR) plus keys the user typed for
    // this server. Values are written to an app-private launch script instead of
    // the process argument vector so they are not visible in `/proc/*/cmdline`.
    // ================================================================

    private val mcpEnvKey = Regex("^[A-Za-z_][A-Za-z0-9_]*$")

    private fun safeMcpSegment(value: String): String =
        value.replace(Regex("[^A-Za-z0-9._-]"), "_").take(120).ifEmpty { "default" }

    private fun shellSingleQuote(value: String): String =
        "'" + value.replace("'", "'\\''") + "'"

    /**
     * Launches one start: creates its directory and writes its script through
     * the fd-relative native broker.
     *
     * The app home is bind-mounted writable into the guest, so every level of
     * this tree is attacker-reachable. The native call opens each component with
     * O_NOFOLLOW relative to its verified parent, checks the opened directory's
     * identity, and writes the script with CREATE_NEW; a symlinked or swapped
     * component makes it fail closed instead of being followed. The identity it
     * returns is what the cleanup paths later have to match.
     */
    internal fun writeMcpLaunchScript(
        runId: String,
        serverId: String,
        environment: Map<String, String>,
        startName: String,
    ): McpLaunchScript {
        val home = File(homeDir).absolutePath
        val runSegment = safeMcpSegment(runId)
        val serverSegment = safeMcpSegment(serverId)
        val body = buildMcpLaunchScriptBody(environment)
        val created = try {
            SecureImportNative.createMcpLaunchScript(
                home,
                runSegment,
                serverSegment,
                startName,
                body,
            )
        } catch (error: Throwable) {
            // A missing native broker must fail closed, never fall back to a
            // pathname write inside a guest-writable tree.
            null
        }
        if (created == null || created.size < 2 ||
            created[0].isNullOrEmpty() || created[1].isNullOrEmpty()
        ) {
            throw IllegalStateException("MCP launch directory unavailable")
        }
        val relative = ".mcp/$runSegment/$serverSegment/$startName"
        return McpLaunchScript(
            homeDir = home,
            runSegment = runSegment,
            serverSegment = serverSegment,
            startName = startName,
            identity = created[1],
            hostPath = File(created[0]),
            guestPath = "/root/home/$relative/launch.sh",
        )
    }

    /** The allowlisted environment exactly as the guest shell reads it. */
    private fun buildMcpLaunchScriptBody(environment: Map<String, String>): String {
        val body = StringBuilder("#!/bin/sh\n")
        for ((key, value) in environment) {
            if (!mcpEnvKey.matches(key)) continue
            body.append("export ").append(key).append('=')
                .append(shellSingleQuote(value.replace("\u0000", ""))).append('\n')
        }
        body.append("exec \"$@\"\n")
        return body.toString()
    }

    /** Launch-script housekeeping for this manager's home directory. */
    internal fun sweepStaleMcpLaunchScripts(
        maxAgeMs: Long = MCP_LAUNCH_SCRIPT_STALE_MS,
    ): Int = sweepStaleMcpLaunchScriptsIn(File(homeDir), maxAgeMs)

    /** proot invocation for a run-scoped MCP child, cwd under the workspace. */
    private fun buildMcpStdioCommand(
        guestScriptPath: String,
        command: String,
        args: List<String>,
    ): List<String> {
        val flags = commonProotFlags(mountStorage = false).toMutableList()
        val cwdIndex = flags.indexOf("--cwd=/root")
        if (cwdIndex >= 0) flags[cwdIndex] = "--cwd=/root/workspace"
        val arch = ArchUtils.getArch()
        val machine = if (arch == "arm") "armv7l" else arch
        val kernelRelease = "\\Linux\\localhost\\$FAKE_KERNEL_RELEASE" +
            "\\$FAKE_KERNEL_VERSION\\$machine\\localdomain\\-1\\"
        flags.add(1, "--root-id")
        flags.add(2, "--kernel-release=$kernelRelease")
        flags.addAll(
            listOf(
                "/usr/bin/env", "-i",
                "HOME=/root",
                "LANG=C.UTF-8",
                "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                "TMPDIR=/tmp",
                "/bin/sh", guestScriptPath,
                command,
            )
        )
        flags.addAll(args)
        return flags
    }

    private fun mcpProcessBuilder(
        command: List<String>,
        environment: Map<String, String>,
    ): ProcessBuilder = ProcessBuilder(command).apply {
        this.environment().clear()
        this.environment().putAll(environment)
        // stdout must stay pure JSON-RPC; stderr is read on its own pipe.
    }

    /**
     * Starts one run-scoped MCP child.
     *
     * [readinessTimeoutSeconds] bounds only the startup/initialize window: a
     * child that has produced no output at all inside it is stopped, while a
     * child that answered is left alone for as long as its run needs it.
     */
    internal fun startMcpStdio(
        runId: String,
        serverId: String,
        command: String,
        args: List<String>,
        environment: Map<String, String>,
        readinessTimeoutSeconds: Long,
        emit: (Map<String, Any>) -> Unit,
    ): Map<String, Any> {
        if (runId.isBlank() || serverId.isBlank() || command.isBlank()) {
            return mapOf(
                "ok" to false,
                "reasonCode" to "invalid_request",
                "message" to "runId, serverId and command are required",
            )
        }
        if (!environment.keys.all { mcpEnvKey.matches(it) }) {
            return mapOf(
                "ok" to false,
                "reasonCode" to "invalid_env",
                "message" to "MCP environment contains an invalid key",
            )
        }
        if (McpStdioRegistry.get(runId, serverId) != null) {
            return mapOf(
                "ok" to false,
                "reasonCode" to "already_running",
                "message" to "this MCP server already runs for the run",
            )
        }
        // Capture the lifecycle this start belongs to before spawning anything:
        // a teardown that lands while the process is coming up bumps the epoch
        // and this child is refused instead of outliving the run.
        val epoch = McpStdioRegistry.currentEpoch()
        val sessionToken = UUID.randomUUID().toString()
        // Each start owns a fresh directory whose identity the cleanup paths
        // have to match before they may delete anything.
        val startName = UUID.randomUUID().toString().replace("-", "")
        // Leftovers from a crashed start never outlive the next one.
        sweepStaleMcpLaunchScripts()
        val script: McpLaunchScript
        val guestScriptPath: String
        try {
            script = writeMcpLaunchScript(runId, serverId, environment, startName)
            guestScriptPath = script.guestPath
        } catch (error: Exception) {
            return mapOf(
                "ok" to false,
                "reasonCode" to "launch_script_failed",
                "message" to (error.message ?: "launch script failed"),
            )
        }
        // A torn-down engine or activity must never turn an MCP event into a
        // crash on a reader, watcher, or teardown thread.
        val safeEmit: (Map<String, Any>) -> Unit = { event ->
            try {
                emit(event)
            } catch (_: Throwable) {
                // Dart is gone; the run is over either way.
            }
        }
        val commandLine = buildMcpStdioCommand(guestScriptPath, command, args)
        val process = try {
            processStarter(mcpProcessBuilder(commandLine, prootEnv()))
        } catch (error: Exception) {
            deleteMcpLaunchScript(script)
            return mapOf(
                "ok" to false,
                "reasonCode" to "proot_start_failed",
                "message" to (error.message ?: "proot start failed"),
            )
        }
        val child = McpStdioRegistry.Child(
            runId = runId,
            serverId = serverId,
            process = process,
            script = script,
            sessionToken = sessionToken,
            epoch = epoch,
            emit = safeEmit,
        )
        when (McpStdioRegistry.register(child)) {
            McpRegisterResult.REGISTERED -> Unit
            McpRegisterResult.ALREADY_RUNNING -> {
                process.destroyForcibly()
                deleteMcpLaunchScript(script)
                return mapOf(
                    "ok" to false,
                    "reasonCode" to "already_running",
                    "message" to "this MCP server already runs for the run",
                )
            }
            McpRegisterResult.TEARDOWN -> {
                // The service or engine was torn down while this child was
                // starting: it must not survive that teardown.
                process.destroyForcibly()
                deleteMcpLaunchScript(script)
                return mapOf(
                    "ok" to false,
                    "reasonCode" to "lifecycle_closed",
                    "message" to "MCP children are stopped for this lifecycle",
                )
            }
        }
        startMcpReaders(child, safeEmit)
        scheduleMcpReadinessTimeout(child, readinessTimeoutSeconds)
        return mapOf("ok" to true, "sessionToken" to sessionToken)
    }

    /**
     * The only path that reports a natural exit: it waits on the process itself
     * rather than inferring the exit from a closed pipe. A stdout EOF is not an
     * exit (the child may still be draining stderr or hanging on to a dead
     * protocol), so the terminal event belongs to this watcher.
     */
    internal fun startMcpExitWatcher(child: McpStdioRegistry.Child) {
        Thread {
            val exitCode = try {
                child.process.waitFor()
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                -1
            }
            if (child.terminateOnce(null, exitCode)) {
                child.script?.let { deleteMcpLaunchScript(it) }
            }
        }.apply { isDaemon = true; name = "mcp-exit-${child.serverId}" }.start()
    }

    private fun startMcpReaders(
        child: McpStdioRegistry.Child,
        emit: (Map<String, Any>) -> Unit,
    ) {
        startMcpExitWatcher(child)
        val stdoutThread = Thread {
            readMcpStream(child, child.process.inputStream, "stdout", emit)
            reapAfterStdoutClosed(child)
        }.apply { isDaemon = true; name = "mcp-stdout-${child.serverId}" }
        val stderrThread = Thread {
            readMcpStream(child, child.process.errorStream, "stderr", emit)
        }.apply { isDaemon = true; name = "mcp-stderr-${child.serverId}" }
        stdoutThread.start()
        stderrThread.start()
    }

    /**
     * A closed stdout means this child can never answer another request again,
     * but it does not prove the process is gone. Give it a bounded grace period
     * to exit on its own, then stop it, so the request waiting on it always
     * settles instead of hanging until the Dart-side request timeout.
     */
    internal fun reapAfterStdoutClosed(child: McpStdioRegistry.Child) {
        if (child.finished) return
        val exited = try {
            child.process.waitFor(MCP_STDOUT_EOF_GRACE_MS, TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        }
        if (exited || child.finished) return
        // Token-scoped: a successor that reused this key must not be stopped
        // because its predecessor's stdout closed late.
        McpStdioRegistry.stopServerIfTokenMatches(
            child.runId,
            child.serverId,
            child.sessionToken,
            "stdout_closed_without_exit",
        )
    }

    /**
     * Reads one MCP stdio stream with a hard line-size cap and a bounded line
     * rate. A line that exceeds [MCP_MAX_LINE_BYTES] or a stream that exceeds
     * [MCP_MAX_LINES_PER_SECOND] destroys the child, emits exactly one bounded
     * error, and drops the offending bytes, so a hostile or broken guest can
     * neither exhaust host memory nor flood the transcript.
     */
    internal fun readMcpStream(
        child: McpStdioRegistry.Child,
        stream: java.io.InputStream,
        name: String,
        emit: (Map<String, Any>) -> Unit,
    ) {
        val input = if (stream is BufferedInputStream) {
            stream
        } else {
            BufferedInputStream(stream)
        }
        val pending = ByteArrayOutputStream()
        var windowStartNanos = System.nanoTime()
        var windowLines = 0

        fun terminate(reasonCode: String, message: String) {
            emit(
                mapOf(
                    "event" to "error",
                    "runId" to child.runId,
                    "serverId" to child.serverId,
                    "sessionToken" to child.sessionToken,
                    "stream" to name,
                    "reasonCode" to reasonCode,
                    "message" to message,
                )
            )
            // The kill path publishes the single terminal event for the child
            // (Child.terminateOnce), so a guard failure can never leave Dart
            // waiting on a child that is already being torn down. The token
            // keeps a late guard from a replaced child off its successor.
            McpStdioRegistry.stopServerIfTokenMatches(
                child.runId,
                child.serverId,
                child.sessionToken,
                reasonCode,
            )
        }

        fun dispatchLine(bytes: ByteArray): Boolean {
            // Any output proves the child is alive: it survived its readiness
            // window and must never be killed for being slow afterwards.
            child.markReady()
            var length = bytes.size
            if (length > 0 && bytes[length - 1] == '\r'.code.toByte()) length--
            val now = System.nanoTime()
            if (now - windowStartNanos >= NANOS_PER_SECOND) {
                windowStartNanos = now
                windowLines = 0
            }
            windowLines++
            if (windowLines > MCP_MAX_LINES_PER_SECOND) {
                terminate(
                    "rate_limit_exceeded",
                    "MCP $name exceeded $MCP_MAX_LINES_PER_SECOND lines per second",
                )
                return false
            }
            emit(
                mapOf(
                    "event" to "line",
                    "runId" to child.runId,
                    "serverId" to child.serverId,
                    "sessionToken" to child.sessionToken,
                    "stream" to name,
                    "line" to String(bytes, 0, length, Charsets.UTF_8),
                )
            )
            return true
        }

        try {
            val chunk = ByteArray(MCP_READ_CHUNK_BYTES)
            while (true) {
                if (child.finished) return
                val read = input.read(chunk)
                if (read == -1) break
                var start = 0
                var index = 0
                while (index < read) {
                    if (chunk[index] == '\n'.code.toByte()) {
                        pending.write(chunk, start, index - start)
                        if (pending.size() > MCP_MAX_LINE_BYTES) {
                            terminate(
                                "line_too_long",
                                "MCP $name line exceeded $MCP_MAX_LINE_BYTES bytes",
                            )
                            return
                        }
                        val line = pending.toByteArray()
                        pending.reset()
                        if (!dispatchLine(line)) return
                        start = index + 1
                    }
                    index++
                }
                if (start < read) pending.write(chunk, start, read - start)
                if (pending.size() > MCP_MAX_LINE_BYTES) {
                    terminate(
                        "line_too_long",
                        "MCP $name line exceeded $MCP_MAX_LINE_BYTES bytes",
                    )
                    return
                }
            }
            if (pending.size() > 0 && !child.finished) {
                // A final line without a trailing newline behaves as readLine().
                dispatchLine(pending.toByteArray())
            }
        } catch (_: Exception) {
            // The pipe closes on kill; the exit event carries the outcome.
        }
    }

    /**
     * Bounds only the startup/initialize readiness window.
     *
     * A child that has produced no output inside [readinessSeconds] never came
     * up (the client sends initialize as soon as the start returns), so it is
     * stopped and its caller settles. A child that answered is left running: a
     * long tool call, a slow model turn, or a server idle between calls is never
     * killed for taking time.
     */
    internal fun scheduleMcpReadinessTimeout(
        child: McpStdioRegistry.Child,
        readinessSeconds: Long,
    ) {

        if (readinessSeconds <= 0) return
        val timer = Thread {
            try {
                Thread.sleep(TimeUnit.SECONDS.toMillis(readinessSeconds))
            } catch (_: InterruptedException) {
                return@Thread
            }
            if (child.finished || child.ready) return@Thread
            logWarning("MCP child was not ready in time: ${child.serverId}")
            // The kill path publishes the terminal event (reason=readiness
            // timeout) even when the child refuses to die.
            McpStdioRegistry.stopServerIfTokenMatches(
                child.runId,
                child.serverId,
                child.sessionToken,
                "readiness_timeout",
            )
        }.apply { isDaemon = true; name = "mcp-readiness-${child.serverId}" }
        timer.start()
    }

    /**
     * android.util.Log is a throwing stub in plain JVM unit tests, so a log
     * line must never be able to take a timer or a reaper thread down.
     */
    private fun logWarning(message: String) {
        try {
            Log.w(TAG, message)
        } catch (_: Throwable) {
            // Logging is best effort here.
        }
    }

    internal fun writeMcpStdio(
        runId: String,
        serverId: String,
        line: String,
        sessionToken: String? = null,
    ): Boolean {
        // A stale token belongs to a previous child of this key: its frames must
        // never reach the child that replaced it.
        val child = McpStdioRegistry.getIfTokenMatches(runId, serverId, sessionToken)
            ?: return false
        if (child.finished) return false
        // The cap covers the whole frame: payload plus its newline terminator.
        // A UTF-16 char is at most 3 UTF-8 bytes in the BMP, so the char count
        // is a cheap first bound that rejects an oversized frame before any
        // copy is allocated.
        if (line.length + 1 > MCP_MAX_STDIN_LINE_BYTES) return false
        val bytes = (line + "\n").toByteArray(Charsets.UTF_8)
        if (bytes.size > MCP_MAX_STDIN_LINE_BYTES) return false
        return try {
            // One frame at a time per child: concurrent writers would interleave
            // bytes and produce invalid JSON-RPC.
            var wrote = false
            synchronized(child.stdinLock) {
                if (!child.finished) {
                    child.process.outputStream.write(bytes)
                    child.process.outputStream.flush()
                    wrote = true
                }
            }
            wrote
        } catch (_: Exception) {
            // The caller reports the failure to Dart, which settles the pending
            // request and tears the client down.
            false
        }
    }

    internal fun closeMcpStdin(
        runId: String,
        serverId: String,
        sessionToken: String? = null,
    ): Boolean {
        val child = McpStdioRegistry.getIfTokenMatches(runId, serverId, sessionToken)
            ?: return false
        return try {
            // Closing stdin takes the same lock as a frame write, so a close
            // can never land in the middle of a half-written frame.
            synchronized(child.stdinLock) {
                child.process.outputStream.close()
            }
            true
        } catch (_: Exception) {
            false
        }
    }

}
