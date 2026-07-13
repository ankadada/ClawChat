package com.anka.clawbot

import android.os.Build
import android.os.Environment
import android.util.Log
import java.io.BufferedReader
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
internal class ProcessManager(
    private val filesDir: String,
    private val nativeLibDir: String,
    private val cleanupCoordinator: CommandCleanupCoordinator? = null,
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
    fun buildInstallCommand(command: String, mountStorage: Boolean = false): List<String> {
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
    ): String {
        require(continuationKey == null || continuationKey.operationId == operationId) {
            "continuation operation identity mismatch"
        }
        if (operationId != null && cancelledOperations.contains(operationId)) {
            throw InterruptedException("operation cancelled")
        }
        val cmd = buildInstallCommand(command, mountStorage)
        val env = prootEnv()
        val coordinator = cleanupCoordinator
            ?: throw IllegalStateException("durable command launch gate unavailable")
        val internalOperationId = operationId ?: UUID.randomUUID().toString()
        val gateKey = continuationKey ?: CommandOwnerKey(
            CommandContinuationOwner.AGENT_BASH,
            "internal-proot-$internalOperationId",
            internalOperationId,
        )
        val ownsReservation = continuationKey == null
        if (ownsReservation) {
            val reserve = NativeCommandContinuationOwner.registry.reserve(
                gateKey,
                TimeUnit.SECONDS.toMillis(timeoutSeconds.coerceAtLeast(1L)),
            )
            if (reserve != CommandReserveOutcome.NEW) {
                throw IllegalStateException("internal command launch reservation failed: $reserve")
            }
        }
        val preparation = coordinator.prepareLaunch(
            gateKey,
            candidateId = null,
            deadlineEpochMs = System.currentTimeMillis() +
                TimeUnit.SECONDS.toMillis(timeoutSeconds.coerceAtLeast(1L)),
        )
        if (preparation.outcome !=
            DurableLaunchRegistrationOutcome.DURABLY_REGISTERED_BACKSTOP_SCHEDULED) {
            if (ownsReservation) NativeCommandContinuationOwner.registry.cancel(gateKey)
            throw IllegalStateException(
                "durable command launch backstop unavailable: ${preparation.outcome}",
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

        val pb = ProcessBuilder(gatedCommand)
        // CRITICAL: Clear inherited Android JVM environment.
        // Without this, LD_PRELOAD, CLASSPATH, DEX2OAT vars leak into
        // proot and break fork+exec. proot-distro uses `env -i` on the
        // guest side AND runs from a clean Termux shell on the host side.
        // We must explicitly clear() since Android's ProcessBuilder
        // inherits the full JVM environment.
        pb.environment().clear()
        pb.environment().putAll(env)
        pb.redirectErrorStream(true)

        val attemptId = requireNotNull(preparation.attemptId)
        val launchToken = requireNotNull(preparation.launchToken)
        val cancelledBeforeSpawn = operationId != null && cancelledOperations.contains(operationId)
        if (cancelledBeforeSpawn ||
            !coordinator.validateLaunchCapability(gateKey, null, attemptId, launchToken)) {
            coordinator.acknowledgeLaunchAbandoned(gateKey, null, attemptId, launchToken)
            coordinator.requestCleanup(gateKey)
            if (ownsReservation) NativeCommandContinuationOwner.registry.cancel(gateKey)
            if (cancelledBeforeSpawn) throw InterruptedException("operation cancelled")
            throw IllegalStateException("command launch capability was revoked before spawn")
        }
        val process = try {
            pb.start()
        } catch (error: Exception) {
            coordinator.acknowledgeLaunchAbandoned(gateKey, null, attemptId, launchToken)
            if (ownsReservation) NativeCommandContinuationOwner.registry.cancel(gateKey)
            throw error
        }
        val ownedProcess = JavaOwnedCommandProcess(process)
        var processId = javaProcessId(process)
        var token: PidGenerationToken? = null
        for (attempt in 0 until 50) {
            if (processId == null) {
                processId = coordinator.waitingLaunchProcessId(
                    gateKey,
                    null,
                    attemptId,
                    launchToken,
                )
            }
            val expected = processId
            if (expected != null) {
                val candidate = coordinator.activateWaitingLaunch(
                    gateKey,
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
                    gateKey,
                    null,
                    attemptId,
                    launchToken,
                )
                if (processId == null) Thread.sleep(100L)
            }
            if (processId == null) {
                coordinator.requestCleanup(gateKey)
                NativeCommandContinuationOwner.registry.cancel(gateKey)
                throw IllegalStateException("command launch wrapper exited before PID handshake")
            }
            while (process.isAlive) {
                coordinator.requestWaitingLaunchCleanup(
                    gateKey,
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
                gateKey,
                candidateId = null,
                attemptId = attemptId,
                launchToken = launchToken,
                expectedProcessId = requireNotNull(processId),
                probe = AndroidCleanupPidAccess.probe,
            )
            NativeCommandContinuationOwner.registry.cancel(gateKey)
            throw IllegalStateException("command launch wrapper handshake failed")
        }
        val legacyOwned = operationId != null && continuationKey == null
        run {
            var attachReceipt: CandidateReceipt
            do {
                attachReceipt = NativeCommandContinuationOwner.registry.attachAgent(
                    gateKey,
                    ownedProcess,
                    beforeNativeOwnership = {
                        coordinator.isActiveLaunch(
                            gateKey,
                            null,
                            attemptId,
                            launchToken,
                            token,
                        )
                    },
                    beforeSignal = { coordinator.requestCleanup(gateKey) },
                )
                if (attachReceipt == CandidateReceipt.UNKNOWN) {
                    Thread.sleep(100L)
                }
            } while (attachReceipt == CandidateReceipt.UNKNOWN)
            if (attachReceipt != CandidateReceipt.NATIVE_OWNS) {
                if (attachReceipt == CandidateReceipt.NATIVE_DISPOSED) {
                    coordinator.complete(gateKey)
                } else {
                    coordinator.requestCleanup(gateKey)
                }
                throw IllegalStateException(
                    "foreground continuation lost before command attach: $attachReceipt"
                )
            }
        }
        if (!coordinator.releaseLaunch(
                gateKey,
                null,
                attemptId,
                launchToken,
                token,
            )) {
            coordinator.requestCleanup(gateKey)
            NativeCommandContinuationOwner.registry.cancel(gateKey)
            throw IllegalStateException("command launch GO commit failed")
        }
        if (operationId != null && continuationKey == null) {
            val existing = activeOperations.putIfAbsent(operationId, process)
            if (existing != null) {
                retireGatedCommand(gateKey, signal = true)
                throw IllegalStateException("operation already active")
            }
            if (cancelledOperations.contains(operationId)) {
                retireGatedCommand(gateKey, signal = true)
                activeOperations.remove(operationId, process)
                throw InterruptedException("operation cancelled")
            }
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
                    synchronized(outputLock) {
                        output.appendLine(l)
                        // Collect error-relevant lines (skip apt download noise)
                        if (!l.startsWith("Get:") && !l.startsWith("Fetched ") &&
                            !l.startsWith("Hit:") && !l.startsWith("Ign:") &&
                            !l.contains(" kB]") && !l.contains(" MB]") &&
                            !l.startsWith("Reading package") && !l.startsWith("Building dependency") &&
                            !l.startsWith("Reading state") && !l.startsWith("The following") &&
                            !l.startsWith("Need to get") && !l.startsWith("After this") &&
                            l.trim().isNotEmpty()) {
                            errorLines.appendLine(l)
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

        val exited = try {
            process.waitFor(timeoutSeconds, TimeUnit.SECONDS)
        } catch (e: InterruptedException) {
            if (continuationKey != null) {
                AgentTaskService.cancelCommand(
                    continuationKey.sessionId,
                    continuationKey.operationId,
                )
            } else {
                retireGatedCommand(gateKey, signal = true)
            }
            Thread.currentThread().interrupt()
            throw e
        } finally {
            if (legacyOwned && operationId != null) {
                activeOperations.remove(operationId, process)
                cancelledOperations.remove(operationId)
            }
        }
        if (!exited) {
            if (continuationKey != null) {
                AgentTaskService.cancelCommand(
                    continuationKey.sessionId,
                    continuationKey.operationId,
                )
            } else {
                retireGatedCommand(gateKey, signal = true)
            }
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

        if (ownsReservation) retireGatedCommand(gateKey, signal = false)

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

        return synchronized(outputLock) { output.toString() }
    }

    private fun retireGatedCommand(key: CommandOwnerKey, signal: Boolean) {
        val result = if (signal) {
            NativeCommandContinuationOwner.registry.cancel(
                key,
                beforeSignal = { cleanupCoordinator?.requestCleanup(key) == true },
            )
        } else {
            NativeCommandContinuationOwner.registry.finish(key)
        }
        if (result.outcome == CommandRetireOutcome.RETIRED ||
            result.outcome == CommandRetireOutcome.ALREADY_RETIRED) {
            cleanupCoordinator?.complete(key)
        } else if (result.outcome == CommandRetireOutcome.RETRYABLE_UNKNOWN) {
            cleanupCoordinator?.requestCleanup(key)
        }
    }

    private fun javaProcessId(process: Process): Int? = try {
        val value = Process::class.java.getMethod("pid").invoke(process) as? Long
        value?.takeIf { it in 1..Int.MAX_VALUE }?.toInt()
    } catch (_: Exception) {
        null
    }

    fun cancelOperation(operationId: String) {
        cancelledOperations.add(operationId)
        activeOperations[operationId]?.destroyForcibly()
    }

    fun finishOperation(operationId: String) {
        if (!activeOperations.containsKey(operationId)) {
            cancelledOperations.remove(operationId)
        }
    }

}
