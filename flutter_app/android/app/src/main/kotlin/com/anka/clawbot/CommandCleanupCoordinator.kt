package com.anka.clawbot

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.os.Build
import android.system.Os
import android.system.OsConstants
import android.util.Log
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.nio.file.attribute.PosixFilePermission
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.zip.CRC32

internal enum class CleanupDisposalState {
    ACTIVE,
    CLEANUP_REQUESTED,
    SIGNAL_INTENT,
    SPAWN_CAPABILITY_ISSUED,
    CLAIMED,
    PID_STAGED,
    RELEASED,
    CONSUMED,
    CANCEL_REQUESTED,
    CANCELLED,
    BACKSTOP_PENDING,
}

private val PRE_LAUNCH_STATES = setOf(
    CleanupDisposalState.SPAWN_CAPABILITY_ISSUED,
    CleanupDisposalState.CLAIMED,
    CleanupDisposalState.PID_STAGED,
    CleanupDisposalState.CANCEL_REQUESTED,
    CleanupDisposalState.CANCELLED,
    CleanupDisposalState.BACKSTOP_PENDING,
)

private val CleanupDisposalState.isPreLaunch: Boolean
    get() = this in PRE_LAUNCH_STATES

/** Metadata-only crash-recovery record. Never add command data or environment. */
internal data class CommandCleanupRecord(
    val recordId: String,
    val owner: CommandContinuationOwner,
    val sessionHash: String,
    val operationHash: String,
    val candidateHash: String?,
    val attemptHash: String?,
    val launchTokenHash: String?,
    val parentProcessId: Int,
    val parentStartTimeTicks: Long,
    val processId: Int,
    val startTimeTicks: Long,
    val deadlineEpochMs: Long,
    val launchExpiresEpochMs: Long,
    val disposalState: CleanupDisposalState,
    val disposalVersion: Long,
)

internal sealed interface CleanupLedgerRead {
    data class Success(
        val records: List<CommandCleanupRecord>,
        val generation: Long = 0L,
    ) : CleanupLedgerRead
    data class Corrupt(val reason: String) : CleanupLedgerRead
}

internal interface CommandCleanupLedger {
    fun read(): CleanupLedgerRead
    fun write(records: List<CommandCleanupRecord>): Boolean
}

internal interface CleanupLedgerFileOps {
    fun exists(file: File): Boolean
    fun read(file: File): ByteArray
    fun writeAndSync(file: File, bytes: ByteArray)
    fun atomicReplace(source: File, destination: File)
    fun syncParent(directory: File)
    fun delete(file: File)
}

internal object NioCleanupLedgerFileOps : CleanupLedgerFileOps {
    override fun exists(file: File): Boolean = file.exists()
    override fun read(file: File): ByteArray = FileInputStream(file).use { it.readBytes() }
    override fun writeAndSync(file: File, bytes: ByteArray) {
        FileOutputStream(file).use { output ->
            output.write(bytes)
            output.flush()
            output.fd.sync()
        }
    }

    override fun atomicReplace(source: File, destination: File) {
        Files.move(
            source.toPath(),
            destination.toPath(),
            StandardCopyOption.ATOMIC_MOVE,
            StandardCopyOption.REPLACE_EXISTING,
        )
    }

    override fun syncParent(directory: File) {
        java.nio.channels.FileChannel.open(
            directory.toPath(),
            StandardOpenOption.READ,
        ).use { it.force(true) }
    }

    override fun delete(file: File) {
        Files.deleteIfExists(file.toPath())
    }
}

internal object AndroidCleanupLedgerFileOps : CleanupLedgerFileOps by NioCleanupLedgerFileOps {
    override fun syncParent(directory: File) {
        val descriptor = Os.open(
            directory.absolutePath,
            OsConstants.O_RDONLY,
            0,
        )
        try {
            Os.fsync(descriptor)
        } finally {
            Os.close(descriptor)
        }
    }
}

internal data class LaunchEntryMetadata(
    val deviceId: Long,
    val inode: Long,
    val uid: Int,
    val permissions: Int,
    val linkCount: Int,
    val size: Long,
    val isDirectory: Boolean,
    val isRegularFile: Boolean,
    val isSymbolicLink: Boolean,
)

internal interface LaunchSecureFileOps {
    fun metadata(path: File): LaunchEntryMetadata?
    fun listEntries(path: File): List<File>?
    fun listEntriesIfSame(path: File, expected: LaunchEntryMetadata): List<File>?
    fun createDirectoryExclusive(path: File): Boolean
    fun createFileExclusive(path: File, bytes: ByteArray): Boolean
    fun readFile(path: File, maxBytes: Int): ByteArray?
    fun sameFile(first: File, second: File): Boolean
    fun deleteFile(path: File): Boolean
    fun deleteFileIfSame(path: File, expected: LaunchEntryMetadata): Boolean
    fun deleteEmptyDirectoryIfSame(path: File, expected: LaunchEntryMetadata): Boolean
    fun syncParent(path: File): Boolean
}

internal object NioLaunchSecureFileOps : LaunchSecureFileOps {
    override fun metadata(path: File): LaunchEntryMetadata? = try {
        val nio = path.toPath()
        val options = arrayOf(LinkOption.NOFOLLOW_LINKS)
        val uid = (Files.getAttribute(nio, "unix:uid", *options) as Number).toInt()
        val mode = (Files.getAttribute(nio, "unix:mode", *options) as Number).toInt()
        val links = (Files.getAttribute(nio, "unix:nlink", *options) as Number).toInt()
        val deviceId = (Files.getAttribute(nio, "unix:dev", *options) as Number).toLong()
        val inode = (Files.getAttribute(nio, "unix:ino", *options) as Number).toLong()
        val size = (Files.getAttribute(nio, "basic:size", *options) as Number).toLong()
        LaunchEntryMetadata(
            deviceId = deviceId,
            inode = inode,
            uid = uid,
            permissions = mode and 0x1ff,
            linkCount = links,
            size = size,
            isDirectory = Files.isDirectory(nio, LinkOption.NOFOLLOW_LINKS),
            isRegularFile = Files.isRegularFile(nio, LinkOption.NOFOLLOW_LINKS),
            isSymbolicLink = Files.isSymbolicLink(nio),
        )
    } catch (_: Exception) {
        null
    }

    override fun listEntries(path: File): List<File>? = try {
        Files.newDirectoryStream(path.toPath()).use { stream ->
            stream.map { it.toFile() }.toList()
        }
    } catch (_: Exception) {
        null
    }

    override fun listEntriesIfSame(
        path: File,
        expected: LaunchEntryMetadata,
    ): List<File>? {
        val before = metadata(path) ?: return null
        if (!sameStableIdentity(before, expected) || !before.isDirectory || before.isSymbolicLink) {
            return null
        }
        val entries = listEntries(path) ?: return null
        val after = metadata(path) ?: return null
        return entries.takeIf { sameStableIdentity(after, expected) }
    }

    override fun createDirectoryExclusive(path: File): Boolean = try {
        Files.createDirectory(path.toPath())
        Files.setPosixFilePermissions(
            path.toPath(),
            setOf(
                PosixFilePermission.OWNER_READ,
                PosixFilePermission.OWNER_WRITE,
                PosixFilePermission.OWNER_EXECUTE,
            ),
        )
        syncParent(requireNotNull(path.parentFile))
    } catch (_: Exception) {
        false
    }

    override fun createFileExclusive(path: File, bytes: ByteArray): Boolean = try {
        java.nio.channels.FileChannel.open(
            path.toPath(),
            StandardOpenOption.CREATE_NEW,
            StandardOpenOption.WRITE,
            LinkOption.NOFOLLOW_LINKS,
        ).use { channel ->
            var buffer = java.nio.ByteBuffer.wrap(bytes)
            while (buffer.hasRemaining()) channel.write(buffer)
            channel.force(true)
        }
        Files.setPosixFilePermissions(
            path.toPath(),
            setOf(PosixFilePermission.OWNER_READ, PosixFilePermission.OWNER_WRITE),
        )
        syncParent(requireNotNull(path.parentFile))
    } catch (_: Exception) {
        false
    }

    override fun readFile(path: File, maxBytes: Int): ByteArray? {
        return try {
            val meta = metadata(path) ?: return null
            if (!meta.isRegularFile || meta.isSymbolicLink || meta.size !in 1..maxBytes.toLong()) {
                return null
            }
            Files.newInputStream(path.toPath(), LinkOption.NOFOLLOW_LINKS).use { input ->
                val bytes = ByteArray(maxBytes + 1)
                var size = 0
                while (size < bytes.size) {
                    val count = input.read(bytes, size, bytes.size - size)
                    if (count < 0) break
                    size += count
                }
                if (size > maxBytes) null else bytes.copyOf(size)
            }
        } catch (_: Exception) {
            null
        }
    }

    override fun sameFile(first: File, second: File): Boolean = try {
        Files.isSameFile(first.toPath(), second.toPath())
    } catch (_: Exception) {
        false
    }

    override fun deleteFile(path: File): Boolean = try {
        Files.delete(path.toPath())
        syncParent(requireNotNull(path.parentFile))
    } catch (_: Exception) {
        false
    }

    override fun deleteFileIfSame(path: File, expected: LaunchEntryMetadata): Boolean {
        return try {
            val current = metadata(path) ?: return false
            if (current != expected || !current.isRegularFile || current.isSymbolicLink) return false
            Files.delete(path.toPath())
            syncParent(requireNotNull(path.parentFile))
        } catch (_: Exception) {
            false
        }
    }

    override fun deleteEmptyDirectoryIfSame(
        path: File,
        expected: LaunchEntryMetadata,
    ): Boolean {
        return try {
            val current = metadata(path) ?: return false
            if (!sameStableIdentity(current, expected) || !current.isDirectory ||
                current.isSymbolicLink || listEntriesIfSame(path, expected)?.isNotEmpty() != false) {
                return false
            }
            Files.delete(path.toPath())
            syncParent(requireNotNull(path.parentFile))
        } catch (_: Exception) {
            false
        }
    }

    override fun syncParent(path: File): Boolean = try {
        NioCleanupLedgerFileOps.syncParent(path)
        true
    } catch (_: Exception) {
        false
    }

    private fun sameStableIdentity(
        current: LaunchEntryMetadata?,
        expected: LaunchEntryMetadata,
    ): Boolean = current != null && current.deviceId == expected.deviceId &&
        current.inode == expected.inode && current.uid == expected.uid &&
        current.permissions == expected.permissions
}

/**
 * App-private, checksummed, atomic cleanup ledger.
 *
 * Schema 1 is accepted and migrated in memory. Schema 2 adds disposalVersion;
 * schema 3 adds the launch-handshake deadline; schema 4 adds launch-attempt
 * hashes and a predecessor generation; schema 5 binds an issued capability
 * to the exact app-parent PID generation.
 * A corrupt/truncated ledger is never partially interpreted.
 */
internal class AtomicCommandCleanupLedger(
    private val file: File,
    private val writeSchemaVersion: Int = CURRENT_SCHEMA,
    private val fileOps: CleanupLedgerFileOps = NioCleanupLedgerFileOps,
) : CommandCleanupLedger {
    private val nextFile = File(file.parentFile, "${file.name}.next")
    private var lastGeneration = 0L

    @Synchronized
    override fun read(): CleanupLedgerRead {
        val main = readCandidate(file)
        val next = readCandidate(nextFile)
        val selected = when {
            main == null && next == null -> return CleanupLedgerRead.Success(emptyList(), 0L)
            main == null && next is LedgerCandidate.Valid &&
                next.generation == 1L && next.previousGeneration == 0L -> {
                if (!promoteNext()) return corrupt("next promotion failed")
                next
            }
            main is LedgerCandidate.Valid -> {
                when (next) {
                    null -> main
                    is LedgerCandidate.Invalid -> {
                        if (!deleteNextDurably()) return corrupt("invalid next deletion failed")
                        main
                    }
                    is LedgerCandidate.Valid -> when {
                        next.generation == main.generation + 1L &&
                            next.previousGeneration == main.generation -> {
                            if (!promoteNext()) return corrupt("next promotion failed")
                            next
                        }
                        next.generation < main.generation -> {
                            if (!deleteNextDurably()) return corrupt("stale next deletion failed")
                            main
                        }
                        next.generation == main.generation &&
                            next.previousGeneration == main.previousGeneration &&
                            next.envelope.contentEquals(main.envelope) -> {
                            if (!deleteNextDurably()) return corrupt("duplicate next deletion failed")
                            main
                        }
                        else -> return corrupt("unverifiable ledger generation chain")
                    }
                }
            }
            else -> return corrupt("no valid durable envelope")
        }
        lastGeneration = maxOf(lastGeneration, selected.generation)
        return CleanupLedgerRead.Success(selected.records, selected.generation)
    }

    @Synchronized
    override fun write(records: List<CommandCleanupRecord>): Boolean {
        if (writeSchemaVersion !in 1..CURRENT_SCHEMA || records.size > MAX_RECORDS ||
            records.any { !valid(it) } ||
            records.map { it.recordId }.toSet().size != records.size) return false
        if (lastGeneration == 0L &&
            (fileOps.exists(file) || fileOps.exists(nextFile)) &&
            read() !is CleanupLedgerRead.Success) return false
        return try {
            file.parentFile?.mkdirs()
            val payload = encodePayload(writeSchemaVersion, records)
            if (payload.size > MAX_LEDGER_BYTES) return false
            val generation = lastGeneration + 1L
            val envelopeWithoutCrc = ByteArrayOutputStream().use { bytes ->
                DataOutputStream(bytes).use { output ->
                    output.writeInt(MAGIC)
                    output.writeInt(writeSchemaVersion)
                    output.writeLong(generation)
                    if (writeSchemaVersion >= 4) output.writeLong(lastGeneration)
                    output.writeInt(payload.size)
                    output.writeInt(records.size)
                    output.write(payload)
                }
                bytes.toByteArray()
            }
            val complete = ByteArrayOutputStream().use { bytes ->
                bytes.write(envelopeWithoutCrc)
                DataOutputStream(bytes).use { output ->
                    output.writeLong(CRC32().apply { update(envelopeWithoutCrc) }.value)
                }
                bytes.toByteArray()
            }
            fileOps.writeAndSync(nextFile, complete)
            fileOps.atomicReplace(nextFile, file)
            fileOps.syncParent(requireNotNull(file.parentFile))
            lastGeneration = generation
            true
        } catch (_: Exception) {
            false
        }
    }

    private sealed interface LedgerCandidate {
        data class Valid(
            val generation: Long,
            val previousGeneration: Long,
            val records: List<CommandCleanupRecord>,
            val envelope: ByteArray,
        ) : LedgerCandidate
        data class Invalid(val generationHint: Long?) : LedgerCandidate
    }

    private fun readCandidate(candidateFile: File): LedgerCandidate? {
        if (!fileOps.exists(candidateFile)) return null
        return try {
            val bytes = fileOps.read(candidateFile)
            val generationHint = generationHint(bytes)
            fun invalid() = LedgerCandidate.Invalid(generationHint)
            if (bytes.size < LEGACY_HEADER_BYTES + CRC_BYTES) return invalid()
            val bodySize = bytes.size - CRC_BYTES
            val expectedCrc = DataInputStream(
                ByteArrayInputStream(bytes, bodySize, CRC_BYTES),
            ).readLong()
            val actualCrc = CRC32().apply { update(bytes, 0, bodySize) }.value
            if (expectedCrc != actualCrc) return invalid()
            val input = DataInputStream(ByteArrayInputStream(bytes, 0, bodySize))
            if (input.readInt() != MAGIC) return invalid()
            val schema = input.readInt()
            if (schema !in 1..CURRENT_SCHEMA) return invalid()
            val generation = input.readLong()
            if (generation <= 0L) return invalid()
            val previousGeneration = if (schema >= 4) input.readLong() else generation - 1L
            if (previousGeneration < 0L || previousGeneration >= generation) return invalid()
            val payloadSize = input.readInt()
            val recordCount = input.readInt()
            if (payloadSize < 0 || payloadSize > MAX_LEDGER_BYTES ||
                recordCount !in 0..MAX_RECORDS || input.available() != payloadSize) {
                return invalid()
            }
            val payload = ByteArray(payloadSize)
            input.readFully(payload)
            if (input.available() != 0) return invalid()
            val decoded = decodePayload(schema, payload, recordCount)
            if (decoded is CleanupLedgerRead.Success) {
                LedgerCandidate.Valid(generation, previousGeneration, decoded.records, bytes)
            } else {
                invalid()
            }
        } catch (_: Exception) {
            LedgerCandidate.Invalid(null)
        }
    }

    private fun generationHint(bytes: ByteArray): Long? {
        return try {
            if (bytes.size < 16) return null
            val input = DataInputStream(ByteArrayInputStream(bytes))
            input.readInt()
            input.readInt()
            input.readLong().takeIf { it > 0L }
        } catch (_: Exception) {
            null
        }
    }

    private fun promoteNext(): Boolean = try {
        fileOps.atomicReplace(nextFile, file)
        fileOps.syncParent(requireNotNull(file.parentFile))
        true
    } catch (_: Exception) {
        false
    }

    private fun deleteNextDurably(): Boolean = try {
        if (fileOps.exists(nextFile)) {
            fileOps.delete(nextFile)
            fileOps.syncParent(requireNotNull(file.parentFile))
        }
        true
    } catch (_: Exception) {
        false
    }

    private fun encodePayload(
        schema: Int,
        records: List<CommandCleanupRecord>,
    ): ByteArray = ByteArrayOutputStream().use { bytes ->
        DataOutputStream(bytes).use { output ->
            output.writeInt(records.size)
            for (record in records) {
                output.writeUTF(record.recordId)
                output.writeInt(record.owner.ordinal)
                output.writeUTF(record.sessionHash)
                output.writeUTF(record.operationHash)
                output.writeBoolean(record.candidateHash != null)
                record.candidateHash?.let(output::writeUTF)
                if (schema >= 4) {
                    output.writeBoolean(record.attemptHash != null)
                    record.attemptHash?.let(output::writeUTF)
                    output.writeBoolean(record.launchTokenHash != null)
                    record.launchTokenHash?.let(output::writeUTF)
                }
                if (schema >= 5) {
                    output.writeInt(record.parentProcessId)
                    output.writeLong(record.parentStartTimeTicks)
                }
                output.writeInt(record.processId)
                output.writeLong(record.startTimeTicks)
                output.writeLong(record.deadlineEpochMs)
                output.writeInt(record.disposalState.ordinal)
                if (schema >= 2) output.writeLong(record.disposalVersion)
                if (schema >= 3) output.writeLong(record.launchExpiresEpochMs)
            }
        }
        bytes.toByteArray()
    }

    private fun decodePayload(
        schema: Int,
        payload: ByteArray,
        expectedCount: Int,
    ): CleanupLedgerRead {
        val records = DataInputStream(ByteArrayInputStream(payload)).use { input ->
            val count = input.readInt()
            if (count != expectedCount || count !in 0..MAX_RECORDS) {
                return corrupt("record count")
            }
            buildList(count) {
                repeat(count) {
                    val recordId = input.readUTF()
                    val owner = CommandContinuationOwner.entries.getOrNull(input.readInt())
                        ?: return corrupt("owner")
                    val sessionHash = input.readUTF()
                    val operationHash = input.readUTF()
                    val candidateHash = if (input.readBoolean()) input.readUTF() else null
                    val attemptHash = if (schema >= 4 && input.readBoolean()) input.readUTF() else null
                    val launchTokenHash =
                        if (schema >= 4 && input.readBoolean()) input.readUTF() else null
                    val parentProcessId = if (schema >= 5) input.readInt() else 0
                    val parentStartTimeTicks = if (schema >= 5) input.readLong() else 0L
                    val processId = input.readInt()
                    val startTimeTicks = input.readLong()
                    val deadlineEpochMs = input.readLong()
                    val stateOrdinal = input.readInt()
                    val disposalState = if (schema >= 4) {
                        CleanupDisposalState.entries.getOrNull(stateOrdinal)
                    } else {
                        when (stateOrdinal) {
                            0 -> CleanupDisposalState.ACTIVE
                            1 -> CleanupDisposalState.CLEANUP_REQUESTED
                            2 -> CleanupDisposalState.SIGNAL_INTENT
                            3 -> CleanupDisposalState.SPAWN_CAPABILITY_ISSUED
                            4 -> CleanupDisposalState.BACKSTOP_PENDING
                            else -> null
                        }
                    } ?: return corrupt("state")
                    val disposalVersion = if (schema >= 2) input.readLong() else 1L
                    val record = CommandCleanupRecord(
                        recordId = recordId,
                        owner = owner,
                        sessionHash = sessionHash,
                        operationHash = operationHash,
                        candidateHash = candidateHash,
                        attemptHash = attemptHash,
                        launchTokenHash = launchTokenHash,
                        parentProcessId = parentProcessId,
                        parentStartTimeTicks = parentStartTimeTicks,
                        processId = processId,
                        startTimeTicks = startTimeTicks,
                        deadlineEpochMs = deadlineEpochMs,
                        launchExpiresEpochMs = if (schema >= 3) input.readLong()
                        else deadlineEpochMs,
                        disposalState = disposalState,
                        disposalVersion = disposalVersion,
                    )
                    if (!valid(record)) return corrupt("invalid record")
                    add(record)
                }
            }.also {
                if (input.available() != 0) return corrupt("trailing payload")
            }
        }
        if (records.map { it.recordId }.toSet().size != records.size) {
            return corrupt("duplicate record")
        }
        return CleanupLedgerRead.Success(records)
    }

    private fun valid(record: CommandCleanupRecord): Boolean =
        record.recordId.length == 64 &&
            record.recordId.all { it in '0'..'9' || it in 'a'..'f' } &&
            record.sessionHash.length == 64 &&
            record.sessionHash.all { it in '0'..'9' || it in 'a'..'f' } &&
            record.operationHash.length == 64 &&
            record.operationHash.all { it in '0'..'9' || it in 'a'..'f' } &&
            (record.candidateHash == null ||
                (record.candidateHash.length == 64 &&
                    record.candidateHash.all { it in '0'..'9' || it in 'a'..'f' })) &&
            (record.attemptHash == null ||
                (record.attemptHash.length == 64 &&
                    record.attemptHash.all { it in '0'..'9' || it in 'a'..'f' })) &&
            (record.launchTokenHash == null ||
                (record.launchTokenHash.length == 64 &&
                    record.launchTokenHash.all { it in '0'..'9' || it in 'a'..'f' })) &&
            ((record.attemptHash == null) == (record.launchTokenHash == null)) &&
            (!record.disposalState.isPreLaunch || record.attemptHash != null) &&
            (!record.disposalState.isPreLaunch ||
                (record.parentProcessId > 0 && record.parentStartTimeTicks > 0L)) &&
            record.parentProcessId >= 0 && record.parentStartTimeTicks >= 0L &&
            record.processId >= 0 && record.startTimeTicks >= 0L &&
            record.deadlineEpochMs > 0L && record.launchExpiresEpochMs > 0L &&
            record.disposalVersion > 0L &&
            (record.disposalState in setOf(
                CleanupDisposalState.SPAWN_CAPABILITY_ISSUED,
                CleanupDisposalState.BACKSTOP_PENDING,
                CleanupDisposalState.CLAIMED,
                CleanupDisposalState.CANCEL_REQUESTED,
                CleanupDisposalState.CANCELLED,
            ) ||
                record.processId > 0)

    private fun corrupt(reason: String) = CleanupLedgerRead.Corrupt(reason)

    companion object {
        private const val MAGIC = 0x43434C44
        private const val CURRENT_SCHEMA = 5
        private const val LEGACY_HEADER_BYTES = 24
        private const val CRC_BYTES = 8
        private const val MAX_RECORDS = 512
        private const val MAX_LEDGER_BYTES = 1024 * 1024
    }
}

internal fun interface CleanupImmediateScheduler {
    fun schedule(delayMs: Long, action: () -> Unit)
}

internal interface CleanupBackstop {
    fun schedule(minimumLatencyMs: Long): Boolean
    fun cancel()
}

internal data class CleanupDisposalAttempt(
    val result: ProcessDisposalResult,
)

internal fun interface CleanupProcessDisposer {
    fun dispose(record: CommandCleanupRecord): CleanupDisposalAttempt
}

internal data class LiveCleanupIdentity(
    val key: CommandOwnerKey,
    val candidateId: String?,
)

internal enum class DurableLaunchRegistrationOutcome {
    DURABLY_REGISTERED_BACKSTOP_SCHEDULED,
    DURABLY_REGISTERED_BACKSTOP_PENDING,
    FAILED_OR_CORRUPT,
}

internal data class CommandLaunchPreparation(
    val outcome: DurableLaunchRegistrationOutcome,
    val wrapperPath: String? = null,
    val attemptDirectoryPath: String? = null,
    val stagingPath: String? = null,
    val goPath: String? = null,
    val parentProcessId: Int? = null,
    val appUid: Int? = null,
    val attemptId: String? = null,
    val launchToken: String? = null,
)

private data class LaunchPaths(
    val rootDirectory: File,
    val wrapperFile: File,
    val attemptDirectory: File,
    val claimFile: File,
    val goFile: File,
    val consumedFile: File,
    val revokedFile: File,
)

private data class IssuedLaunchCapability(
    val attemptId: String,
    val launchToken: String,
    val paths: LaunchPaths,
)

/**
 * One process-wide crash cleanup coordinator. The registry remains live SSOT;
 * this ledger only blocks/reconciles processes that can outlive app services.
 */
internal class CommandCleanupCoordinator(
    private val ledger: CommandCleanupLedger,
    private val disposer: CleanupProcessDisposer,
    private val immediateScheduler: CleanupImmediateScheduler,
    private val backstop: CleanupBackstop,
    private val launchDirectory: File? = null,
    private val launchFileOps: LaunchSecureFileOps = NioLaunchSecureFileOps,
    private val recoveryProbe: PidProcessProbe? = null,
    private val parentProcessId: () -> Int = { android.os.Process.myPid() },
    private val currentUid: () -> Int = {
        val source = launchDirectory ?: File(".")
        (Files.getAttribute(source.toPath(), "unix:uid", LinkOption.NOFOLLOW_LINKS) as Number)
            .toInt()
    },
    private val nowEpochMs: () -> Long = System::currentTimeMillis,
    private val onDefinitive: (CommandCleanupRecord, LiveCleanupIdentity?) -> Unit = { _, _ -> },
) {
    private val lock = Any()
    private val records = linkedMapOf<String, CommandCleanupRecord>()
    private val liveIdentities = mutableMapOf<String, LiveCleanupIdentity>()
    private val inFlight = mutableSetOf<String>()
    private val recoveryPendingIds = mutableSetOf<String>()
    private val issuedCapabilities = mutableMapOf<String, IssuedLaunchCapability>()
    private var loaded = false
    private var corrupt = false
    private var retryScheduled = false

    fun initialize() {
        synchronized(lock) { loadLocked() }
    }

    fun canAdmit(owner: CommandContinuationOwner, sessionId: String): Boolean {
        reconcile()
        val hash = sessionHash(owner, sessionId)
        return synchronized(lock) {
            loadLocked()
            !corrupt && records.values.none { it.owner == owner && it.sessionHash == hash }
        }
    }

    fun requestSessionCleanup(
        owner: CommandContinuationOwner,
        sessionId: String,
    ): Boolean {
        val hash = sessionHash(owner, sessionId)
        val persisted = synchronized(lock) {
            loadLocked()
            if (corrupt) return@synchronized false
            var changed = false
            for ((id, record) in records.toMap()) {
                if (record.owner != owner || record.sessionHash != hash) continue
                if (record.disposalState.isPreLaunch) {
                    val cancelled = record.copy(
                        disposalState = CleanupDisposalState.CANCEL_REQUESTED,
                        disposalVersion = record.disposalVersion + 1L,
                    )
                    records[id] = cancelled
                    createRevocationLocked(cancelled)
                    recoveryPendingIds.add(id)
                    changed = true
                } else if (record.disposalState != CleanupDisposalState.SIGNAL_INTENT) {
                    records[id] = record.copy(
                        disposalState = CleanupDisposalState.SIGNAL_INTENT,
                        disposalVersion = record.disposalVersion + 1L,
                    )
                    changed = true
                }
            }
            if (!changed || ledger.write(records.values.toList())) {
                scheduleLocked(immediate = true)
                true
            } else {
                corrupt = true
                false
            }
        }
        if (persisted) reconcile()
        return persisted
    }

    fun prepareLaunch(
        key: CommandOwnerKey,
        candidateId: String?,
        deadlineEpochMs: Long,
    ): CommandLaunchPreparation = synchronized(lock) {
        loadLocked()
        if (corrupt || deadlineEpochMs <= nowEpochMs()) {
            return@synchronized CommandLaunchPreparation(
                DurableLaunchRegistrationOutcome.FAILED_OR_CORRUPT,
            )
        }
        val sessionHash = sessionHash(key.owner, key.sessionId)
        val id = recordId(key.owner, sessionHash, key.operationId, candidateId)
        val existing = records[id]
        if (existing != null) {
            val exact = existing.owner == key.owner &&
                existing.operationHash == opaqueIdHash("operation", key.operationId) &&
                existing.candidateHash == candidateId?.let { opaqueIdHash("candidate", it) }
            val issued = issuedCapabilities[id]
            if (!exact || issued == null || existing.disposalState !in setOf(
                    CleanupDisposalState.SPAWN_CAPABILITY_ISSUED,
                    CleanupDisposalState.BACKSTOP_PENDING,
                ) || !matchesCapability(existing, issued.attemptId, issued.launchToken)) {
                return@synchronized CommandLaunchPreparation(
                    DurableLaunchRegistrationOutcome.FAILED_OR_CORRUPT,
                )
            }
            liveIdentities[id] = LiveCleanupIdentity(key, candidateId)
            return@synchronized finishBackstopRegistrationLocked(existing, issued)
        }
        if (records.values.any { it.owner == key.owner && it.sessionHash == sessionHash }) {
            return@synchronized CommandLaunchPreparation(
                DurableLaunchRegistrationOutcome.FAILED_OR_CORRUPT,
            )
        }
        val now = nowEpochMs()
        val parentPid = parentProcessId().takeIf { it > 0 }
            ?: return@synchronized CommandLaunchPreparation(
                DurableLaunchRegistrationOutcome.FAILED_OR_CORRUPT,
            )
        val parentGeneration = (recoveryProbe?.read(parentPid) as? PidProbeResult.Present)
            ?.startTimeTicks ?: return@synchronized CommandLaunchPreparation(
            DurableLaunchRegistrationOutcome.FAILED_OR_CORRUPT,
        )
        val issued = issueCapabilityLocked()
            ?: return@synchronized CommandLaunchPreparation(
                DurableLaunchRegistrationOutcome.FAILED_OR_CORRUPT,
            )
        val record = CommandCleanupRecord(
            recordId = id,
            owner = key.owner,
            sessionHash = sessionHash,
            operationHash = opaqueIdHash("operation", key.operationId),
            candidateHash = candidateId?.let { opaqueIdHash("candidate", it) },
            attemptHash = opaqueIdHash("attempt", issued.attemptId),
            launchTokenHash = opaqueIdHash("launch-token", issued.launchToken),
            parentProcessId = parentPid,
            parentStartTimeTicks = parentGeneration,
            processId = 0,
            startTimeTicks = 0L,
            deadlineEpochMs = deadlineEpochMs,
            launchExpiresEpochMs = (now + LAUNCH_HANDSHAKE_TIMEOUT_MS)
                .coerceAtMost(deadlineEpochMs),
            disposalState = CleanupDisposalState.SPAWN_CAPABILITY_ISSUED,
            disposalVersion = 1L,
        )
        val next = records.values.toMutableList().apply { add(record) }
        if (!ledger.write(next)) {
            return@synchronized CommandLaunchPreparation(
                DurableLaunchRegistrationOutcome.FAILED_OR_CORRUPT,
            )
        }
        records[id] = record
        issuedCapabilities[id] = issued
        liveIdentities[id] = LiveCleanupIdentity(key, candidateId)
        finishBackstopRegistrationLocked(record, issued)
    }

    fun validateLaunchCapability(
        key: CommandOwnerKey,
        candidateId: String?,
        attemptId: String,
        launchToken: String,
    ): Boolean = synchronized(lock) {
        loadLocked()
        if (corrupt) return@synchronized false
        val record = records[exactRecordId(key, candidateId)] ?: return@synchronized false
        if (record.disposalState != CleanupDisposalState.SPAWN_CAPABILITY_ISSUED ||
            !matchesCapability(record, attemptId, launchToken)) return@synchronized false
        val paths = pathsForRecord(record) ?: return@synchronized false
        validateAttemptDirectory(paths, claimed = false) &&
            listOf(
                paths.claimFile,
                paths.goFile,
                paths.consumedFile,
                paths.revokedFile,
            ).all { launchFileOps.metadata(it) == null } &&
            launchFileOps.listEntries(paths.attemptDirectory)?.isEmpty() == true
    }

    fun acknowledgeLaunchAbandoned(
        key: CommandOwnerKey,
        candidateId: String?,
        attemptId: String,
        launchToken: String,
    ): Boolean = synchronized(lock) {
        loadLocked()
        if (corrupt) return@synchronized false
        val id = exactRecordId(key, candidateId)
        val existing = records[id] ?: return@synchronized false
        if (!existing.disposalState.isPreLaunch ||
            !matchesCapability(existing, attemptId, launchToken)) return@synchronized false
        val cancelled = if (existing.disposalState == CleanupDisposalState.CANCEL_REQUESTED) {
            existing
        } else {
            existing.copy(
                disposalState = CleanupDisposalState.CANCEL_REQUESTED,
                disposalVersion = existing.disposalVersion + 1L,
            ).also { pending ->
                val next = records.toMutableMap().apply { put(id, pending) }
                if (!ledger.write(next.values.toList())) return@synchronized false
                records[id] = pending
            }
        }
        val paths = pathsForRecord(cancelled) ?: return@synchronized false
        if (!validateAttemptDirectory(paths, claimed = true)) {
            return@synchronized recoverInvalidAttemptLocked(cancelled, paths, exactAbandon = true)
        }
        if (!createRevocationLocked(cancelled)) return@synchronized false
        val normalized = normalizePublishedClaim(paths)
        val staged = if (normalized) readStagedIdentity(paths.claimFile) else null
        val exactClaim = staged?.takeIf {
            cancelled.launchTokenHash == opaqueIdHash("launch-token", it.launchToken)
        }
        if (exactClaim != null) {
            recoveryPendingIds.add(id)
            scheduleLocked(immediate = true)
            return@synchronized false
        }
        val retired = retireRecordLocked(cancelled)
        if (retired) bestEffortCleanupKnownValidAttempt(cancelled)
        retired
    }

    fun activateWaitingLaunch(
        key: CommandOwnerKey,
        candidateId: String?,
        attemptId: String,
        launchToken: String,
        expectedProcessId: Int,
        probe: PidProcessProbe,
    ): PidGenerationToken? = synchronized(lock) {
        loadLocked()
        if (corrupt || expectedProcessId <= 0) return@synchronized null
        val id = exactRecordId(key, candidateId)
        val record = records[id] ?: return@synchronized null
        if (record.disposalState !in setOf(
                CleanupDisposalState.SPAWN_CAPABILITY_ISSUED,
                CleanupDisposalState.CLAIMED,
                CleanupDisposalState.PID_STAGED,
        ) || !matchesCapability(record, attemptId, launchToken)) return@synchronized null
        val paths = pathsForRecord(record) ?: return@synchronized null
        if (!validateAttemptDirectory(paths, claimed = true)) return@synchronized null
        if (!normalizePublishedClaim(paths)) return@synchronized null
        val staged = readStagedIdentity(paths.claimFile) ?: return@synchronized null
        if (staged.launchToken != launchToken || staged.processId != expectedProcessId) {
            return@synchronized null
        }
        if (record.processId > 0 &&
            (record.processId != staged.processId || record.startTimeTicks != staged.startTimeTicks)) {
            return@synchronized null
        }
        val claimedRecord = if (record.disposalState == CleanupDisposalState.SPAWN_CAPABILITY_ISSUED) {
            record.copy(
                processId = staged.processId,
                startTimeTicks = staged.startTimeTicks,
                disposalState = CleanupDisposalState.CLAIMED,
                disposalVersion = record.disposalVersion + 1L,
            ).also { claimed ->
                val claimedRecords = records.toMutableMap().apply { put(id, claimed) }
                if (!ledger.write(claimedRecords.values.toList())) return@synchronized null
                records[id] = claimed
            }
        } else {
            record
        }
        val observed = probe.read(staged.processId) as? PidProbeResult.Present
            ?: return@synchronized null
        if (observed.startTimeTicks != staged.startTimeTicks) return@synchronized null
        val stagedRecord = claimedRecord.copy(
            processId = staged.processId,
            startTimeTicks = staged.startTimeTicks,
            disposalState = CleanupDisposalState.PID_STAGED,
            disposalVersion = claimedRecord.disposalVersion + 1L,
        )
        val stagedRecords = records.toMutableMap().apply { put(id, stagedRecord) }
        if (!ledger.write(stagedRecords.values.toList())) return@synchronized null
        records[id] = stagedRecord
        val active = stagedRecord.copy(
            disposalState = CleanupDisposalState.ACTIVE,
            disposalVersion = stagedRecord.disposalVersion + 1L,
        )
        val next = records.toMutableMap().apply { put(id, active) }
        if (!ledger.write(next.values.toList())) return@synchronized null
        records[id] = active
        liveIdentities[id] = LiveCleanupIdentity(key, candidateId)
        PidGenerationToken(staged.processId, staged.startTimeTicks)
    }

    fun waitingLaunchProcessId(
        key: CommandOwnerKey,
        candidateId: String?,
        attemptId: String,
        launchToken: String,
    ): Int? = synchronized(lock) {
        loadLocked()
        val record = records[exactRecordId(key, candidateId)] ?: return@synchronized null
        if (!matchesCapability(record, attemptId, launchToken)) return@synchronized null
        if (!record.disposalState.isPreLaunch) return@synchronized record.processId.takeIf { it > 0 }
        val paths = pathsForRecord(record) ?: return@synchronized null
        if (!validateAttemptDirectory(paths, claimed = true)) return@synchronized null
        if (!normalizePublishedClaim(paths)) return@synchronized null
        readStagedIdentity(paths.claimFile)?.takeIf { it.launchToken == launchToken }?.processId
    }

    /**
     * Converts a failed pre-attach wrapper into durable cleanup ownership.
     * The parent-created PID is accepted only for the exact pending candidate
     * and only after its /proc generation is readable; no signal is permitted
     * while generation is unknown.
     */
    fun requestWaitingLaunchCleanup(
        key: CommandOwnerKey,
        candidateId: String?,
        attemptId: String,
        launchToken: String,
        expectedProcessId: Int,
        probe: PidProcessProbe,
    ): Boolean = synchronized(lock) {
        loadLocked()
        if (corrupt || expectedProcessId <= 0) return@synchronized false
        val id = exactRecordId(key, candidateId)
        val existing = records[id] ?: return@synchronized false
        if (!matchesCapability(existing, attemptId, launchToken)) return@synchronized false
        if (!existing.disposalState.isPreLaunch) {
            return@synchronized existing.disposalState == CleanupDisposalState.SIGNAL_INTENT
        }
        val record = if (existing.disposalState == CleanupDisposalState.CANCEL_REQUESTED) {
            existing
        } else {
            existing.copy(
                disposalState = CleanupDisposalState.CANCEL_REQUESTED,
                disposalVersion = existing.disposalVersion + 1L,
            ).also { cancelled ->
                val next = records.toMutableMap().apply { put(id, cancelled) }
                if (!ledger.write(next.values.toList())) return@synchronized false
                records[id] = cancelled
            }
        }
        val paths = pathsForRecord(record) ?: return@synchronized false
        if (!validateAttemptDirectory(paths, claimed = true)) {
            recoverInvalidAttemptLocked(record, paths, exactAbandon = false)
            return@synchronized false
        }
        if (!createRevocationLocked(record)) return@synchronized false
        if (!normalizePublishedClaim(paths)) return@synchronized false
        val staged = readStagedIdentity(paths.claimFile)
        if (staged == null) {
            recoveryPendingIds.add(id)
            scheduleLocked(immediate = true)
            return@synchronized false
        }
        if (staged.launchToken != launchToken || staged.processId != expectedProcessId) {
            return@synchronized false
        }
        when (val observed = probe.read(staged.processId)) {
            PidProbeResult.RetryableUnknown -> {
                recoveryPendingIds.add(id)
                scheduleLocked(immediate = true)
                false
            }
            PidProbeResult.Missing -> {
                removeDefinitivePendingLaunchLocked(record)
                !corrupt
            }
            is PidProbeResult.Present -> {
                if (observed.startTimeTicks != staged.startTimeTicks) {
                    removeDefinitivePendingLaunchLocked(record)
                    return@synchronized !corrupt
                }
                val intent = record.copy(
                    processId = staged.processId,
                    startTimeTicks = observed.startTimeTicks,
                    disposalState = CleanupDisposalState.SIGNAL_INTENT,
                    disposalVersion = record.disposalVersion + 1L,
                )
                val next = records.toMutableMap().apply { put(id, intent) }
                if (!ledger.write(next.values.toList())) return@synchronized false
                records[id] = intent
                scheduleLocked(immediate = true)
                true
            }
        }
    }

    fun isActiveLaunch(
        key: CommandOwnerKey,
        candidateId: String?,
        attemptId: String,
        launchToken: String,
        token: PidGenerationToken,
    ): Boolean = synchronized(lock) {
        loadLocked()
        val record = records[exactRecordId(key, candidateId)] ?: return@synchronized false
        if (!matchesCapability(record, attemptId, launchToken)) return@synchronized false
        record.disposalState == CleanupDisposalState.ACTIVE &&
            record.processId == token.processId && record.startTimeTicks == token.startTimeTicks
    }

    fun releaseLaunch(
        key: CommandOwnerKey,
        candidateId: String?,
        attemptId: String,
        launchToken: String,
        token: PidGenerationToken,
    ): Boolean = synchronized(lock) {
        loadLocked()
        val id = exactRecordId(key, candidateId)
        val record = records[id] ?: return@synchronized false
        if (!matchesCapability(record, attemptId, launchToken) ||
            record.disposalState != CleanupDisposalState.ACTIVE ||
            record.processId != token.processId || record.startTimeTicks != token.startTimeTicks) {
            return@synchronized false
        }
        val paths = pathsForRecord(record) ?: return@synchronized false
        if (!validateAttemptDirectory(paths, claimed = true) ||
            launchFileOps.metadata(paths.revokedFile) != null) return@synchronized false
        val released = record.copy(
            disposalState = CleanupDisposalState.RELEASED,
            disposalVersion = record.disposalVersion + 1L,
        )
        val next = records.toMutableMap().apply { put(id, released) }
        if (!ledger.write(next.values.toList())) return@synchronized false
        records[id] = released
        val payload = "$launchToken\n${token.processId}\n${token.startTimeTicks}\n"
            .toByteArray(Charsets.UTF_8)
        launchFileOps.createFileExclusive(paths.goFile, payload) &&
            validatePrivateRegularFile(paths.goFile, payload.size.toLong())
    }

    fun requestCleanup(
        key: CommandOwnerKey,
        candidateId: String? = null,
    ): Boolean = synchronized(lock) {
        loadLocked()
        if (corrupt) return@synchronized false
        val id = recordId(key.owner, sessionHash(key.owner, key.sessionId), key.operationId, candidateId)
        val record = records[id] ?: return@synchronized false
        liveIdentities[id] = LiveCleanupIdentity(key, candidateId)
        if (record.disposalState.isPreLaunch) {
            val cancelled = if (record.disposalState == CleanupDisposalState.CANCEL_REQUESTED) {
                record
            } else {
                record.copy(
                    disposalState = CleanupDisposalState.CANCEL_REQUESTED,
                    disposalVersion = record.disposalVersion + 1L,
                )
            }
            val next = records.toMutableMap().apply { put(id, cancelled) }
            if (cancelled !== record && !ledger.write(next.values.toList())) {
                return@synchronized false
            }
            records[id] = cancelled
            recoveryPendingIds.add(id)
            createRevocationLocked(cancelled)
            scheduleLocked(immediate = true)
            return@synchronized true
        }
        val requestedState = CleanupDisposalState.SIGNAL_INTENT
        if (record.disposalState != requestedState) {
            val pending = record.copy(
                disposalState = requestedState,
                disposalVersion = record.disposalVersion + 1L,
            )
            val next = records.toMutableMap().apply { put(id, pending) }
            if (!ledger.write(next.values.toList())) return@synchronized false
            records[id] = pending
        }
        scheduleLocked(immediate = true)
        true
    }

    fun complete(key: CommandOwnerKey, candidateId: String? = null): Boolean = synchronized(lock) {
        loadLocked()
        if (corrupt) return@synchronized false
        val id = recordId(key.owner, sessionHash(key.owner, key.sessionId), key.operationId, candidateId)
        val record = records[id] ?: return@synchronized true
        val definitive = if (record.disposalState.isPreLaunch) {
            false
        } else {
            when (val observed = recoveryProbe?.read(record.processId)) {
                PidProbeResult.Missing -> true
                is PidProbeResult.Present -> observed.startTimeTicks != record.startTimeTicks
                PidProbeResult.RetryableUnknown, null -> false
            }
        }
        if (!definitive) {
            if (record.disposalState.isPreLaunch) {
                createRevocationLocked(record)
                recoveryPendingIds.add(id)
            } else if (record.disposalState != CleanupDisposalState.SIGNAL_INTENT) {
                val pending = record.copy(
                    disposalState = CleanupDisposalState.SIGNAL_INTENT,
                    disposalVersion = record.disposalVersion + 1L,
                )
                val next = records.toMutableMap().apply { put(id, pending) }
                if (!ledger.write(next.values.toList())) return@synchronized false
                records[id] = pending
            }
            scheduleLocked(immediate = true)
            return@synchronized false
        }
        val retired = retireRecordLocked(record)
        if (retired) bestEffortCleanupKnownValidAttempt(record)
        retired
    }

    fun reconcile(): Boolean {
        val due = synchronized(lock) {
            loadLocked()
            if (corrupt) return true
            val now = nowEpochMs()
            reconcilePendingLaunchesLocked(now)
            val selected = records.values.filter {
                it.recordId !in inFlight &&
                    !it.disposalState.isPreLaunch &&
                    (it.disposalState == CleanupDisposalState.CLEANUP_REQUESTED ||
                        it.disposalState == CleanupDisposalState.SIGNAL_INTENT ||
                        it.deadlineEpochMs <= now)
            }
            val durable = mutableListOf<CommandCleanupRecord>()
            for (record in selected) {
                val current = records[record.recordId] ?: continue
                val signalIntent = if (current.disposalState == CleanupDisposalState.SIGNAL_INTENT) {
                    current
                } else {
                    current.copy(
                        disposalState = CleanupDisposalState.SIGNAL_INTENT,
                        disposalVersion = current.disposalVersion + 1L,
                    )
                }
                if (signalIntent !== current) {
                    val next = records.toMutableMap().apply {
                        put(record.recordId, signalIntent)
                    }
                    if (!ledger.write(next.values.toList())) {
                        corrupt = true
                        break
                    }
                    records[record.recordId] = signalIntent
                }
                durable.add(signalIntent)
            }
            durable.also { claimed -> inFlight.addAll(claimed.map { it.recordId }) }
        }
        for (record in due) {
            val attempt = try {
                disposer.dispose(record)
            } catch (_: Exception) {
                CleanupDisposalAttempt(ProcessDisposalResult.RETRYABLE_UNKNOWN)
            }
            if (attempt.result == ProcessDisposalResult.RETRYABLE_UNKNOWN) {
                synchronized(lock) {
                    inFlight.remove(record.recordId)
                    val current = records[record.recordId] ?: return@synchronized
                    check(current.disposalState == CleanupDisposalState.SIGNAL_INTENT)
                }
            } else {
                val liveIdentity = synchronized(lock) { liveIdentities[record.recordId] }
                val removed = synchronized(lock) {
                    inFlight.remove(record.recordId)
                    val retired = retireRecordLocked(record)
                    if (retired) bestEffortCleanupKnownValidAttempt(record)
                    retired
                }
                if (removed) {
                    try {
                        onDefinitive(record, liveIdentity)
                    } catch (e: Exception) {
                        Log.w("ClawChat", "Cleanup registry reconciliation failed", e)
                    }
                }
            }
        }
        return synchronized(lock) {
            retryScheduled = false
            scheduleLocked()
            corrupt || records.isNotEmpty()
        }
    }

    internal fun recordsForTest(): List<CommandCleanupRecord> = synchronized(lock) {
        loadLocked()
        records.values.toList()
    }

    internal fun isCorruptForTest(): Boolean = synchronized(lock) {
        loadLocked()
        corrupt
    }

    private fun finishBackstopRegistrationLocked(
        record: CommandCleanupRecord,
        issued: IssuedLaunchCapability,
    ): CommandLaunchPreparation {
        val scheduled = scheduleLocked(forceBackstopDelayMs = MIN_RETRY_MS)
        if (!scheduled) {
            val pending = record.copy(
                disposalState = CleanupDisposalState.BACKSTOP_PENDING,
                disposalVersion = record.disposalVersion + 1L,
            )
            val next = records.toMutableMap().apply { put(record.recordId, pending) }
            if (!ledger.write(next.values.toList())) {
                corrupt = true
                return CommandLaunchPreparation(
                    DurableLaunchRegistrationOutcome.FAILED_OR_CORRUPT,
                )
            }
            records[record.recordId] = pending
            return CommandLaunchPreparation(
                DurableLaunchRegistrationOutcome.DURABLY_REGISTERED_BACKSTOP_PENDING,
            )
        }
        if (record.disposalState == CleanupDisposalState.BACKSTOP_PENDING) {
            val ready = record.copy(
                disposalState = CleanupDisposalState.SPAWN_CAPABILITY_ISSUED,
                disposalVersion = record.disposalVersion + 1L,
            )
            val next = records.toMutableMap().apply { put(record.recordId, ready) }
            if (!ledger.write(next.values.toList())) {
                corrupt = true
                return CommandLaunchPreparation(
                    DurableLaunchRegistrationOutcome.FAILED_OR_CORRUPT,
                )
            }
            records[record.recordId] = ready
        }
        return CommandLaunchPreparation(
            DurableLaunchRegistrationOutcome.DURABLY_REGISTERED_BACKSTOP_SCHEDULED,
            wrapperPath = issued.paths.wrapperFile.absolutePath,
            attemptDirectoryPath = issued.paths.attemptDirectory.absolutePath,
            stagingPath = issued.paths.claimFile.absolutePath,
            goPath = issued.paths.goFile.absolutePath,
            parentProcessId = record.parentProcessId.takeIf { it > 0 },
            appUid = currentUid().takeIf { it >= 0 },
            attemptId = issued.attemptId,
            launchToken = issued.launchToken,
        )
    }

    private fun exactRecordId(key: CommandOwnerKey, candidateId: String?): String {
        val sessionHash = sessionHash(key.owner, key.sessionId)
        return recordId(key.owner, sessionHash, key.operationId, candidateId)
    }

    private fun issueCapabilityLocked(): IssuedLaunchCapability? {
        val wrapper = prepareLaunchRootAndWrapperLocked() ?: return null
        repeat(MAX_CAPABILITY_ATTEMPTS) {
            val attemptId = randomHex(CAPABILITY_BYTES)
            val launchToken = randomHex(CAPABILITY_BYTES)
            val attemptHash = opaqueIdHash("attempt", attemptId)
            val paths = launchPaths(wrapper, attemptHash) ?: return null
            if (!launchFileOps.createDirectoryExclusive(paths.attemptDirectory)) return@repeat
            if (!validateAttemptDirectory(paths, claimed = false)) {
                return@repeat
            }
            return IssuedLaunchCapability(attemptId, launchToken, paths)
        }
        return null
    }

    private fun prepareLaunchRootAndWrapperLocked(): File? {
        val directory = launchDirectory?.toPath()?.toAbsolutePath()?.normalize()?.toFile()
            ?: return null
        return try {
            if (launchFileOps.metadata(directory) == null &&
                !launchFileOps.createDirectoryExclusive(directory)) return null
            if (!validateLaunchRoot(directory)) return null
            val wrapper = File(directory, WRAPPER_FILE_NAME)
            if (Files.isSymbolicLink(wrapper.toPath())) return null
            if (!wrapper.exists() || wrapper.readText() != WRAPPER_SOURCE) {
                val temporary = File(directory, "$WRAPPER_FILE_NAME.next")
                if (Files.isSymbolicLink(temporary.toPath())) return null
                Files.deleteIfExists(temporary.toPath())
                Files.newOutputStream(
                    temporary.toPath(),
                    StandardOpenOption.CREATE_NEW,
                    StandardOpenOption.WRITE,
                    LinkOption.NOFOLLOW_LINKS,
                ).use { output ->
                    output.write(WRAPPER_SOURCE.toByteArray(Charsets.UTF_8))
                    output.flush()
                }
                setPrivateFilePermissions(temporary)
                Files.move(
                    temporary.toPath(),
                    wrapper.toPath(),
                    StandardCopyOption.REPLACE_EXISTING,
                    StandardCopyOption.ATOMIC_MOVE,
                )
            }
            setPrivateFilePermissions(wrapper)
            val metadata = launchFileOps.metadata(wrapper) ?: return null
            if (!metadata.isRegularFile || metadata.isSymbolicLink ||
                metadata.uid != currentUid() || metadata.permissions != PRIVATE_FILE_MODE ||
                metadata.linkCount != 1) return null
            wrapper
        } catch (_: Exception) {
            null
        }
    }

    private fun launchPaths(wrapper: File, attemptHash: String): LaunchPaths? {
        if (!attemptHash.matches(Regex("^[a-f0-9]{64}$"))) return null
        val root = launchDirectory?.toPath()?.toAbsolutePath()?.normalize()?.toFile() ?: return null
        if (wrapper.toPath().toAbsolutePath().normalize().parent != root.toPath()) return null
        val attempt = root.toPath().resolve("attempt-$attemptHash").normalize().toFile()
        if (attempt.toPath().parent != root.toPath()) return null
        return LaunchPaths(
            rootDirectory = root,
            wrapperFile = wrapper,
            attemptDirectory = attempt,
            claimFile = File(attempt, CLAIM_FILE_NAME),
            goFile = File(attempt, GO_FILE_NAME),
            consumedFile = File(attempt, CONSUMED_FILE_NAME),
            revokedFile = File(attempt, REVOKED_FILE_NAME),
        )
    }

    private fun pathsForRecord(record: CommandCleanupRecord): LaunchPaths? {
        val root = launchDirectory?.toPath()?.toAbsolutePath()?.normalize()?.toFile() ?: return null
        val wrapper = File(root, WRAPPER_FILE_NAME)
        return record.attemptHash?.let { launchPaths(wrapper, it) }
    }

    private enum class AttemptNodeClassification {
        VALID,
        MISSING,
        INVALID_ATTEMPT,
        INVALID_ROOT,
    }

    private fun validateLaunchRoot(root: File): Boolean {
        val expected = launchDirectory?.toPath()?.toAbsolutePath()?.normalize() ?: return false
        if (root.toPath() != expected) return false
        val metadata = launchFileOps.metadata(root) ?: return false
        if (!metadata.isDirectory || metadata.isSymbolicLink ||
            metadata.uid != currentUid() || metadata.permissions != PRIVATE_DIRECTORY_MODE) {
            return false
        }
        val entries = launchFileOps.listEntries(root) ?: return false
        if (entries.isEmpty()) return true
        val anchors = entries.filter {
            it.name == WRAPPER_FILE_NAME || it.name == "$WRAPPER_FILE_NAME.next"
        }
        return anchors.isNotEmpty() && anchors.all(::isSafeRootAnchor)
    }

    private fun isSafeRootAnchor(entry: File): Boolean {
        val metadata = launchFileOps.metadata(entry) ?: return false
        return metadata.isRegularFile && !metadata.isSymbolicLink &&
            metadata.uid == currentUid() && metadata.permissions == PRIVATE_FILE_MODE &&
            metadata.linkCount == 1
    }

    private fun classifyAttemptNode(
        paths: LaunchPaths,
        claimed: Boolean = true,
    ): AttemptNodeClassification {
        if (!validateLaunchRoot(paths.rootDirectory)) {
            return AttemptNodeClassification.INVALID_ROOT
        }
        if (paths.attemptDirectory.toPath().toAbsolutePath().normalize().parent !=
            paths.rootDirectory.toPath()) {
            return AttemptNodeClassification.INVALID_ATTEMPT
        }
        val attempt = launchFileOps.metadata(paths.attemptDirectory)
            ?: return AttemptNodeClassification.MISSING
        val linkCountValid = if (claimed) {
            attempt.linkCount in 2..MAX_HOST_ATTEMPT_LINKS
        } else {
            attempt.linkCount == 2
        }
        val structurallyValid = attempt.isDirectory && !attempt.isSymbolicLink &&
            attempt.uid == currentUid() && attempt.permissions == PRIVATE_DIRECTORY_MODE &&
            linkCountValid
        if (!structurallyValid) return AttemptNodeClassification.INVALID_ATTEMPT
        val entries = launchFileOps.listEntries(paths.attemptDirectory)
            ?: return AttemptNodeClassification.INVALID_ATTEMPT
        return if (entries.all(::isSafeAttemptEntry)) {
            AttemptNodeClassification.VALID
        } else {
            AttemptNodeClassification.INVALID_ATTEMPT
        }
    }

    private fun isSafeAttemptEntry(entry: File): Boolean {
        val name = entry.name
        val knownName = name in KNOWN_ATTEMPT_ENTRIES ||
            name.removePrefix(CLAIM_TEMP_PREFIX).let { suffix ->
                name.startsWith(CLAIM_TEMP_PREFIX) && suffix.matches(Regex("^[1-9][0-9]*$"))
            }
        if (!knownName) return false
        val metadata = launchFileOps.metadata(entry) ?: return false
        if (metadata.isSymbolicLink || metadata.uid != currentUid()) return false
        return if (name == RELEASE_CLAIM_DIRECTORY_NAME) {
            metadata.isDirectory && metadata.permissions == PRIVATE_DIRECTORY_MODE
        } else {
            metadata.isRegularFile && metadata.permissions == PRIVATE_FILE_MODE &&
                metadata.linkCount in 1..2 && metadata.size in 0..MAX_CAPABILITY_FILE_BYTES.toLong()
        }
    }

    private fun validateAttemptDirectory(paths: LaunchPaths, claimed: Boolean): Boolean {
        return classifyAttemptNode(paths, claimed) == AttemptNodeClassification.VALID
    }

    private fun validatePrivateRegularFile(
        file: File,
        exactSize: Long? = null,
        expectedLinkCount: Int = 1,
    ): Boolean {
        val metadata = launchFileOps.metadata(file) ?: return false
        return metadata.isRegularFile && !metadata.isSymbolicLink &&
            metadata.uid == currentUid() && metadata.permissions == PRIVATE_FILE_MODE &&
            metadata.linkCount == expectedLinkCount &&
            (exactSize == null || metadata.size == exactSize)
    }

    private data class StagedLaunchIdentity(
        val launchToken: String,
        val processId: Int,
        val startTimeTicks: Long,
    )

    private fun readStagedIdentity(
        file: File,
        expectedLinkCount: Int = 1,
    ): StagedLaunchIdentity? {
        if (!validatePrivateRegularFile(file, expectedLinkCount = expectedLinkCount)) return null
        val bytes = launchFileOps.readFile(file, MAX_CAPABILITY_FILE_BYTES) ?: return null
        val parts = bytes.toString(Charsets.UTF_8).split('\n')
        if (parts.size != 4 || parts.last().isNotEmpty()) return null
        val token = parts[0]
        if (!token.matches(Regex("^[a-f0-9]{${CAPABILITY_BYTES * 2}}$"))) return null
        val processId = parts[1].toIntOrNull()?.takeIf { it > 0 } ?: return null
        val generation = parts[2].toLongOrNull()?.takeIf { it > 0L } ?: return null
        return StagedLaunchIdentity(token, processId, generation)
    }

    private fun normalizePublishedClaim(paths: LaunchPaths): Boolean {
        if (!validateAttemptDirectory(paths, claimed = true)) return false
        val metadata = launchFileOps.metadata(paths.claimFile) ?: return true
        if (metadata.linkCount == 1) return validatePrivateRegularFile(paths.claimFile)
        if (metadata.linkCount != 2 || !validatePrivateRegularFile(
                paths.claimFile,
                expectedLinkCount = 2,
            )) return false
        val entries = launchFileOps.listEntries(paths.attemptDirectory) ?: return false
        val candidates = entries.filter { it.name.startsWith(CLAIM_TEMP_PREFIX) }
        if (candidates.isEmpty()) return validatePrivateRegularFile(paths.claimFile)
        if (candidates.size != 1) return false
        val temporary = candidates.single()
        if (!hasExactLexicalParent(temporary, paths.attemptDirectory) ||
            !temporary.name.removePrefix(CLAIM_TEMP_PREFIX).matches(Regex("^[1-9][0-9]*$")) ||
            !validateBoundedClaimTemporary(temporary)) {
            return publishedClaimWonUnlinkRace(paths, temporary)
        }
        if (!launchFileOps.sameFile(paths.claimFile, temporary)) {
            return publishedClaimWonUnlinkRace(paths, temporary)
        }
        if (!launchFileOps.deleteFile(temporary)) {
            return publishedClaimWonUnlinkRace(paths, temporary)
        }
        return validatePrivateRegularFile(paths.claimFile)
    }

    private fun publishedClaimWonUnlinkRace(paths: LaunchPaths, temporary: File): Boolean =
        launchFileOps.metadata(temporary) == null && validatePrivateRegularFile(paths.claimFile)

    private fun validateBoundedClaimTemporary(file: File): Boolean {
        val metadata = launchFileOps.metadata(file) ?: return false
        return metadata.isRegularFile && !metadata.isSymbolicLink &&
            metadata.uid == currentUid() && metadata.permissions == PRIVATE_FILE_MODE &&
            metadata.linkCount == 2 && metadata.size in 0..MAX_CAPABILITY_FILE_BYTES.toLong()
    }

    private fun matchesCapability(
        record: CommandCleanupRecord,
        attemptId: String,
        launchToken: String,
    ): Boolean = attemptId.length == CAPABILITY_BYTES * 2 &&
        launchToken.length == CAPABILITY_BYTES * 2 &&
        record.attemptHash == opaqueIdHash("attempt", attemptId) &&
        record.launchTokenHash == opaqueIdHash("launch-token", launchToken)

    private fun createRevocationLocked(record: CommandCleanupRecord): Boolean {
        val paths = pathsForRecord(record) ?: return false
        if (!validateAttemptDirectory(paths, claimed = true)) return false
        val existing = launchFileOps.metadata(paths.revokedFile)
        if (existing != null) return validatePrivateRegularFile(paths.revokedFile, REVOCATION.size.toLong())
        return launchFileOps.createFileExclusive(paths.revokedFile, REVOCATION) &&
            validatePrivateRegularFile(paths.revokedFile, REVOCATION.size.toLong())
    }

    private fun hasExactLexicalParent(child: File, parent: File): Boolean =
        child.toPath().toAbsolutePath().normalize().parent ==
            parent.toPath().toAbsolutePath().normalize()

    private fun recoverInvalidAttemptLocked(
        record: CommandCleanupRecord,
        paths: LaunchPaths,
        exactAbandon: Boolean,
    ): Boolean {
        if (classifyAttemptNode(paths, claimed = true) == AttemptNodeClassification.VALID) return false
        val parentDefinitive = when (val parent = recoveryProbe?.read(record.parentProcessId)) {
            PidProbeResult.Missing -> true
            is PidProbeResult.Present -> parent.startTimeTicks != record.parentStartTimeTicks
            PidProbeResult.RetryableUnknown, null -> false
        }
        if (!exactAbandon && !parentDefinitive) {
            recoveryPendingIds.add(record.recordId)
            scheduleLocked(immediate = true)
            return false
        }
        return retireRecordLocked(record)
    }

    /**
     * Reclaims only the finite artifacts of one still-bound, app-created attempt.
     * Durable authority has already been retired before this is called. Any
     * validation failure, substitution, or I/O failure leaves a non-authoritative
     * residual and never recreates ledger or JobScheduler work.
     *
     * Java/NIO cannot unlink by an open directory handle on every supported API.
     * The attempt is app-private and all coordinator cleanup is serialized by
     * [lock]; each deletion therefore performs an immediate no-follow dev+inode
     * comparison, while the root and attempt identities are rechecked at every
     * seam. A dead wrapper is required before process-backed callers reach here.
     */
    private fun bestEffortCleanupKnownValidAttempt(record: CommandCleanupRecord): Boolean {
        return try {
            val paths = pathsForRecord(record) ?: return false
            val rootIdentity = launchFileOps.metadata(paths.rootDirectory)
                ?.takeIf(::isPrivateRootMetadata) ?: return false
            if (!hasExactLexicalParent(paths.wrapperFile, paths.rootDirectory) ||
                !isSafeRootAnchor(paths.wrapperFile)) return false
            val attemptIdentity = launchFileOps.metadata(paths.attemptDirectory)
                ?.takeIf(::isPrivateAttemptMetadata) ?: return false
            if (!hasExactLexicalParent(paths.attemptDirectory, paths.rootDirectory) ||
                !sameBoundAttempt(paths, rootIdentity, attemptIdentity)) return false

            val entries = launchFileOps.listEntriesIfSame(
                paths.attemptDirectory,
                attemptIdentity,
            ) ?: return false
            if (!sameBoundAttempt(paths, rootIdentity, attemptIdentity)) return false
            val byName = entries.associateBy { it.name }
            if (byName.size != entries.size || entries.any { !isSafeAttemptEntry(it) }) return false
            val temporaryEntries = entries.filter { it.name.startsWith(CLAIM_TEMP_PREFIX) }
            if (temporaryEntries.size > 1) return false

            val claim = byName[CLAIM_FILE_NAME]
            val temporary = temporaryEntries.singleOrNull()
            val claimMetadata = claim?.let { cleanupClaimMetadata(record, it) }
            if (claim != null && claimMetadata == null) return false
            val temporaryMetadata = temporary?.let { cleanupClaimMetadata(record, it) }
            if (temporary != null) {
                val expectedTemporary = temporaryMetadata ?: return false
                if (claim == null || claimMetadata?.linkCount != 2 ||
                    expectedTemporary.linkCount != 2 ||
                    !sameEntryIdentity(claimMetadata, expectedTemporary) ||
                    !launchFileOps.sameFile(claim, temporary)) return false
            } else if (claimMetadata?.linkCount == 2) {
                return false
            }

            val go = byName[GO_FILE_NAME]
            val consumed = byName[CONSUMED_FILE_NAME]
            if (go != null && consumed != null) return false
            val goMetadata = go?.let { cleanupReleaseMetadata(record, it) }
            val consumedMetadata = consumed?.let { cleanupReleaseMetadata(record, it) }
            if ((go != null && goMetadata == null) ||
                (consumed != null && consumedMetadata == null) ||
                ((go != null || consumed != null) && claim == null)) return false

            val revoked = byName[REVOKED_FILE_NAME]
            val revokedMetadata = revoked?.let { cleanupRevocationMetadata(it) }
            if (revoked != null && revokedMetadata == null) return false

            val releaseClaim = byName[RELEASE_CLAIM_DIRECTORY_NAME]
            val releaseMetadata = releaseClaim?.let { launchFileOps.metadata(it) }
            if (releaseClaim != null) {
                val expectedRelease = releaseMetadata ?: return false
                if (!isPrivateDirectoryMetadata(expectedRelease) ||
                    launchFileOps.listEntriesIfSame(
                        releaseClaim,
                        expectedRelease,
                    )?.isEmpty() != true) return false
            }

            fun deleteFile(file: File?, metadata: LaunchEntryMetadata?): Boolean {
                if (file == null) return true
                val expected = metadata ?: return false
                return sameBoundAttempt(paths, rootIdentity, attemptIdentity) &&
                    launchFileOps.deleteFileIfSame(file, expected)
            }

            if (!deleteFile(temporary, temporaryMetadata)) return false
            val refreshedClaimMetadata = if (temporary == null) {
                claimMetadata
            } else {
                claim?.let { cleanupClaimMetadata(record, it) }
                    ?.takeIf { claimMetadata != null && sameEntryIdentity(it, claimMetadata) }
            }
            if (claim != null && refreshedClaimMetadata == null) return false
            if (!deleteFile(go, goMetadata) || !deleteFile(consumed, consumedMetadata) ||
                !deleteFile(revoked, revokedMetadata) ||
                !deleteFile(claim, refreshedClaimMetadata)) return false
            if (releaseClaim != null) {
                val expected = releaseMetadata ?: return false
                if (!sameBoundAttempt(paths, rootIdentity, attemptIdentity) ||
                    !launchFileOps.deleteEmptyDirectoryIfSame(releaseClaim, expected)) return false
            }
            if (!sameBoundAttempt(paths, rootIdentity, attemptIdentity) ||
                launchFileOps.listEntriesIfSame(
                    paths.attemptDirectory,
                    attemptIdentity,
                )?.isEmpty() != true) return false
            val finalAttempt = launchFileOps.metadata(paths.attemptDirectory)
                ?.takeIf { sameEntryIdentity(it, attemptIdentity) } ?: return false
            launchFileOps.deleteEmptyDirectoryIfSame(paths.attemptDirectory, finalAttempt) &&
                launchFileOps.syncParent(paths.rootDirectory)
        } catch (_: Exception) {
            false
        }
    }

    private fun cleanupClaimMetadata(
        record: CommandCleanupRecord,
        file: File,
    ): LaunchEntryMetadata? {
        val metadata = launchFileOps.metadata(file) ?: return null
        if (!metadata.isRegularFile || metadata.isSymbolicLink ||
            metadata.uid != currentUid() || metadata.permissions != PRIVATE_FILE_MODE ||
            metadata.linkCount !in 1..2 || metadata.size !in 1..MAX_CAPABILITY_FILE_BYTES.toLong()) {
            return null
        }
        val staged = readStagedIdentity(file, metadata.linkCount) ?: return null
        if (record.launchTokenHash != opaqueIdHash("launch-token", staged.launchToken)) return null
        if (record.processId > 0 &&
            (record.processId != staged.processId || record.startTimeTicks != staged.startTimeTicks)) {
            return null
        }
        return metadata
    }

    private fun cleanupReleaseMetadata(
        record: CommandCleanupRecord,
        file: File,
    ): LaunchEntryMetadata? {
        if (record.processId <= 0 || record.startTimeTicks <= 0L) return null
        val metadata = launchFileOps.metadata(file) ?: return null
        if (!metadata.isRegularFile || metadata.isSymbolicLink ||
            metadata.uid != currentUid() || metadata.permissions != PRIVATE_FILE_MODE ||
            metadata.linkCount != 1 || metadata.size !in 1..MAX_CAPABILITY_FILE_BYTES.toLong()) {
            return null
        }
        val released = readStagedIdentity(file) ?: return null
        return metadata.takeIf {
            record.launchTokenHash == opaqueIdHash("launch-token", released.launchToken) &&
                record.processId == released.processId &&
                record.startTimeTicks == released.startTimeTicks
        }
    }

    private fun cleanupRevocationMetadata(file: File): LaunchEntryMetadata? {
        val metadata = launchFileOps.metadata(file) ?: return null
        if (!metadata.isRegularFile || metadata.isSymbolicLink ||
            metadata.uid != currentUid() || metadata.permissions != PRIVATE_FILE_MODE ||
            metadata.linkCount != 1 || metadata.size != REVOCATION.size.toLong()) return null
        return metadata.takeIf {
            launchFileOps.readFile(file, REVOCATION.size)?.contentEquals(REVOCATION) == true
        }
    }

    private fun isPrivateDirectoryMetadata(metadata: LaunchEntryMetadata): Boolean =
        metadata.isDirectory && !metadata.isSymbolicLink && metadata.uid == currentUid() &&
            metadata.permissions == PRIVATE_DIRECTORY_MODE

    private fun isPrivateRootMetadata(metadata: LaunchEntryMetadata): Boolean =
        isPrivateDirectoryMetadata(metadata) &&
            metadata.linkCount in 2..MAX_LAUNCH_ROOT_LINKS

    private fun isPrivateAttemptMetadata(metadata: LaunchEntryMetadata): Boolean =
        isPrivateDirectoryMetadata(metadata) && metadata.linkCount in 2..MAX_HOST_ATTEMPT_LINKS

    private fun sameBoundDirectory(file: File, expected: LaunchEntryMetadata): Boolean {
        val current = launchFileOps.metadata(file) ?: return false
        return isPrivateDirectoryMetadata(current) && sameEntryIdentity(current, expected)
    }

    private fun sameBoundAttempt(
        paths: LaunchPaths,
        root: LaunchEntryMetadata,
        attempt: LaunchEntryMetadata,
    ): Boolean = sameBoundDirectory(paths.rootDirectory, root) &&
        sameBoundDirectory(paths.attemptDirectory, attempt)

    private fun sameEntryIdentity(
        first: LaunchEntryMetadata,
        second: LaunchEntryMetadata,
    ): Boolean = first.deviceId == second.deviceId && first.inode == second.inode

    private fun retireRecordLocked(record: CommandCleanupRecord): Boolean {
        // Durable authority retirement is intentionally independent from filesystem
        // deletion. Recovery never walks, renames, or removes a replaceable attempt
        // path; any residual is non-authoritative and a future launch uses a fresh
        // high-entropy attempt id.
        val next = records.toMutableMap().apply { remove(record.recordId) }
        if (!ledger.write(next.values.toList())) {
            corrupt = true
            return false
        }
        records.remove(record.recordId)
        liveIdentities.remove(record.recordId)
        recoveryPendingIds.remove(record.recordId)
        issuedCapabilities.remove(record.recordId)
        scheduleLocked()
        return true
    }

    private fun setPrivateFilePermissions(file: File) {
        Files.setPosixFilePermissions(
            file.toPath(),
            setOf(PosixFilePermission.OWNER_READ, PosixFilePermission.OWNER_WRITE),
        )
    }

    private fun reconcilePendingLaunchesLocked(now: Long) {
        val probe = recoveryProbe ?: return
        for (record in records.values.toList()) {
            if (!record.disposalState.isPreLaunch) continue
            val recovering = record.recordId in recoveryPendingIds
            val cancelled = record.disposalState in setOf(
                CleanupDisposalState.CANCEL_REQUESTED,
                CleanupDisposalState.CANCELLED,
            )
            if (!recovering && !cancelled && now < record.launchExpiresEpochMs) continue
            val paths = pathsForRecord(record) ?: continue
            if (!validateAttemptDirectory(paths, claimed = true)) {
                recoverInvalidAttemptLocked(record, paths, exactAbandon = false)
                continue
            }
            if ((recovering || cancelled || now >= record.launchExpiresEpochMs) &&
                !createRevocationLocked(record)) continue
            val normalized = normalizePublishedClaim(paths)
            val staged = if (normalized) readStagedIdentity(paths.claimFile) else null
            val exactClaim = staged?.takeIf {
                record.launchTokenHash == opaqueIdHash("launch-token", it.launchToken)
            }
            if (exactClaim == null) {
                if (record.disposalState == CleanupDisposalState.BACKSTOP_PENDING &&
                    !backstop.schedule(MIN_RETRY_MS)) continue
                when (val parent = probe.read(record.parentProcessId)) {
                    PidProbeResult.RetryableUnknown -> Unit
                    PidProbeResult.Missing -> removeDefinitivePendingLaunchLocked(record)
                    is PidProbeResult.Present -> if (
                        parent.startTimeTicks != record.parentStartTimeTicks
                    ) {
                        removeDefinitivePendingLaunchLocked(record)
                    }
                }
                continue
            }
            when (val generation = probe.read(exactClaim.processId)) {
                PidProbeResult.RetryableUnknown -> Unit
                PidProbeResult.Missing -> removeDefinitivePendingLaunchLocked(record)
                is PidProbeResult.Present -> {
                    if (generation.startTimeTicks != exactClaim.startTimeTicks) {
                        removeDefinitivePendingLaunchLocked(record)
                        continue
                    }
                    val signalIntent = record.copy(
                        processId = exactClaim.processId,
                        startTimeTicks = generation.startTimeTicks,
                        disposalState = CleanupDisposalState.SIGNAL_INTENT,
                        disposalVersion = record.disposalVersion + 1L,
                    )
                    val next = records.toMutableMap().apply {
                        put(record.recordId, signalIntent)
                    }
                    if (!ledger.write(next.values.toList())) {
                        corrupt = true
                        return
                    }
                    records[record.recordId] = signalIntent
                }
            }
        }
    }

    private fun removeDefinitivePendingLaunchLocked(record: CommandCleanupRecord) {
        val retired = retireRecordLocked(record)
        if (retired) bestEffortCleanupKnownValidAttempt(record)
    }

    private fun loadLocked() {
        if (loaded) return
        loaded = true
        when (val read = ledger.read()) {
            is CleanupLedgerRead.Corrupt -> {
                corrupt = true
                backstop.schedule(MIN_RETRY_MS)
            }
            is CleanupLedgerRead.Success -> {
                // Records loaded in a fresh process have no live registry owner.
                // Treat them as orphans immediately, regardless of deadline.
                for (record in read.records) {
                    recoveryPendingIds.add(record.recordId)
                    records[record.recordId] = record.copy(
                        disposalState = when (record.disposalState) {
                            CleanupDisposalState.SIGNAL_INTENT ->
                                CleanupDisposalState.SIGNAL_INTENT
                            in PRE_LAUNCH_STATES -> record.disposalState
                            else -> CleanupDisposalState.CLEANUP_REQUESTED
                        },
                        disposalVersion = record.disposalVersion + 1L,
                    )
                }
                if (records.isNotEmpty()) {
                    if (!ledger.write(records.values.toList())) corrupt = true
                    scheduleLocked(immediate = true)
                }
            }
        }
    }

    private fun scheduleLocked(
        immediate: Boolean = false,
        forceBackstopDelayMs: Long? = null,
    ): Boolean {
        if (corrupt) {
            backstop.schedule(MIN_RETRY_MS)
            return false
        }
        if (records.isEmpty()) {
            backstop.cancel()
            return true
        }
        val now = nowEpochMs()
        val delay = if (forceBackstopDelayMs != null) {
            forceBackstopDelayMs
        } else if (immediate || records.values.any {
                it.disposalState == CleanupDisposalState.CLEANUP_REQUESTED ||
                    it.disposalState == CleanupDisposalState.SIGNAL_INTENT
            }) {
            0L
        } else if (records.values.any {
                it.disposalState.isPreLaunch
            }) {
            MIN_RETRY_MS
        } else {
            (records.values.minOf { it.deadlineEpochMs } - now).coerceAtLeast(0L)
        }
        val backstopAccepted = try {
            backstop.schedule(delay)
        } catch (_: Exception) {
            false
        }
        if (delay == 0L && !retryScheduled) {
            retryScheduled = true
            immediateScheduler.schedule(MIN_RETRY_MS) { reconcile() }
        }
        return backstopAccepted
    }

    companion object {
        const val MIN_RETRY_MS = 500L
        const val LAUNCH_HANDSHAKE_TIMEOUT_MS = 30_000L
        private const val CAPABILITY_BYTES = 32
        private const val MAX_CAPABILITY_ATTEMPTS = 8
        private const val MAX_CAPABILITY_FILE_BYTES = 256
        private const val MAX_HOST_ATTEMPT_LINKS = 10
        private const val MAX_LAUNCH_ROOT_LINKS = 1024
        private const val PRIVATE_DIRECTORY_MODE = 0x1c0
        private const val PRIVATE_FILE_MODE = 0x180
        private const val WRAPPER_FILE_NAME = "command_launch_gate.sh"
        private const val CLAIM_FILE_NAME = "claim"
        private const val CLAIM_TEMP_PREFIX = "claim.tmp."
        private const val GO_FILE_NAME = "go"
        private const val CONSUMED_FILE_NAME = "go.consumed"
        private const val REVOKED_FILE_NAME = "revoked"
        private const val RELEASE_CLAIM_DIRECTORY_NAME = "release-claim"
        private val KNOWN_ATTEMPT_ENTRIES = setOf(
            CLAIM_FILE_NAME,
            GO_FILE_NAME,
            CONSUMED_FILE_NAME,
            REVOKED_FILE_NAME,
            RELEASE_CLAIM_DIRECTORY_NAME,
        )
        private val REVOCATION = "revoked\n".toByteArray(Charsets.UTF_8)
        private val WRAPPER_SOURCE = """#!/system/bin/sh
umask 077
attempt=${'$'}1
launch_token=${'$'}2
expected_parent=${'$'}3
expected_uid=${'$'}4
shift 4
[ "${'$'}1" = "--" ] || exit 126
shift
durable_sync() {
  if [ -x /system/bin/sync ]; then
    /system/bin/sync "${'$'}1"
  else
    sync "${'$'}1"
  fi
}
[ "${'$'}PPID" = "${'$'}expected_parent" ] || exit 123
[ -d "${'$'}attempt" ] && [ ! -L "${'$'}attempt" ] || exit 122
attempt_uid=${'$'}(stat -c %u "${'$'}attempt" 2>/dev/null || stat -f %u "${'$'}attempt" 2>/dev/null)
attempt_mode=${'$'}(stat -c %a "${'$'}attempt" 2>/dev/null || stat -f %Lp "${'$'}attempt" 2>/dev/null)
attempt_links=${'$'}(stat -c %h "${'$'}attempt" 2>/dev/null || stat -f %l "${'$'}attempt" 2>/dev/null)
[ "${'$'}attempt_uid" = "${'$'}expected_uid" ] || exit 122
[ "${'$'}attempt_mode" = "700" ] || exit 122
if [ "${'$'}attempt_links" != "2" ]; then
  [ "${'$'}(uname -s 2>/dev/null)" = "Darwin" ] && [ "${'$'}attempt_links" = "3" ] || exit 122
fi
[ ! -e "${'$'}attempt/revoked" ] && [ ! -L "${'$'}attempt/revoked" ] || exit 121
start_ticks=${'$'}(
  IFS= read -r stat_line < "/proc/${'$'}${'$'}/stat" || exit 1
  set -- ${'$'}stat_line
  [ "${'$'}#" -ge 22 ] || exit 1
  shift 21
  printf '%s\n' "${'$'}1"
)
[ -n "${'$'}start_ticks" ] || { [ ! -d /proc ] && start_ticks=1; }
case "${'$'}start_ticks" in ''|*[!0-9]*) exit 119 ;; esac
claim_temp="${'$'}attempt/claim.tmp.${'$'}${'$'}"
[ ! -e "${'$'}claim_temp" ] && [ ! -L "${'$'}claim_temp" ] || exit 118
(set -C; printf '%s\n%s\n%s\n' "${'$'}launch_token" "${'$'}${'$'}" "${'$'}start_ticks" > "${'$'}claim_temp") || exit 118
durable_sync "${'$'}claim_temp" || { rm -f "${'$'}claim_temp"; exit 118; }
[ ! -e "${'$'}attempt/revoked" ] && [ ! -L "${'$'}attempt/revoked" ] || { rm -f "${'$'}claim_temp"; exit 121; }
ln "${'$'}claim_temp" "${'$'}attempt/claim" 2>/dev/null || { rm -f "${'$'}claim_temp"; exit 120; }
durable_sync "${'$'}attempt" || exit 118
[ ! -e "${'$'}attempt/revoked" ] && [ ! -L "${'$'}attempt/revoked" ] || { rm -f "${'$'}claim_temp"; exit 121; }
# Durable publication barrier: unlink the now-redundant twin, then persist the directory again.
rm -f "${'$'}claim_temp" || exit 118
durable_sync "${'$'}attempt" || exit 118
while [ ! -e "${'$'}attempt/go" ] && [ ! -L "${'$'}attempt/go" ]; do
  [ -d "${'$'}attempt" ] && [ ! -L "${'$'}attempt" ] || exit 122
  [ "${'$'}PPID" = "${'$'}expected_parent" ] || exit 123
  kill -0 "${'$'}expected_parent" 2>/dev/null || exit 124
  [ ! -e "${'$'}attempt/revoked" ] && [ ! -L "${'$'}attempt/revoked" ] || exit 121
  sleep 1
done
[ "${'$'}PPID" = "${'$'}expected_parent" ] || exit 123
[ -f "${'$'}attempt/go" ] && [ ! -L "${'$'}attempt/go" ] || exit 117
go_meta=${'$'}(stat -c '%u:%a:%h:%s' "${'$'}attempt/go" 2>/dev/null || stat -f '%u:%Lp:%l:%z' "${'$'}attempt/go" 2>/dev/null) || exit 117
go_size=${'$'}{go_meta##*:}
[ "${'$'}go_meta" = "${'$'}expected_uid:600:1:${'$'}go_size" ] || exit 117
case "${'$'}go_size" in ''|*[!0-9]*) exit 117 ;; esac
[ "${'$'}go_size" -gt 0 ] && [ "${'$'}go_size" -le 256 ] || exit 117
{
  IFS= read -r go_token || exit 116
  IFS= read -r go_pid || exit 116
  IFS= read -r go_ticks || exit 116
  if IFS= read -r extra; then exit 116; fi
} < "${'$'}attempt/go"
[ "${'$'}go_token" = "${'$'}launch_token" ] || exit 116
[ "${'$'}go_pid" = "${'$'}${'$'}" ] || exit 116
[ "${'$'}go_ticks" = "${'$'}start_ticks" ] || exit 116
mkdir "${'$'}attempt/release-claim" || exit 115
[ ! -e "${'$'}attempt/go.consumed" ] && [ ! -L "${'$'}attempt/go.consumed" ] || exit 115
mv "${'$'}attempt/go" "${'$'}attempt/go.consumed" || exit 115
[ ! -e "${'$'}attempt/revoked" ] && [ ! -L "${'$'}attempt/revoked" ] || exit 121
exec "${'$'}@"
"""

        private fun randomHex(size: Int): String = ByteArray(size).also {
            SecureRandom().nextBytes(it)
        }.joinToString("") { "%02x".format(it) }

        fun sessionHash(owner: CommandContinuationOwner, sessionId: String): String =
            sha256("${owner.name}\u0000$sessionId")

        fun recordId(
            owner: CommandContinuationOwner,
            sessionHash: String,
            operationId: String,
            candidateId: String?,
        ): String = sha256(
            "${owner.name}\u0000$sessionHash\u0000$operationId\u0000${candidateId.orEmpty()}"
        )

        fun opaqueIdHash(kind: String, value: String): String =
            sha256("$kind\u0000$value")

        private fun sha256(value: String): String = MessageDigest.getInstance("SHA-256")
            .digest(value.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
    }
}

private class ExecutorCleanupScheduler : CleanupImmediateScheduler {
    private val executor = Executors.newSingleThreadScheduledExecutor { runnable ->
        Thread(runnable, "ClawChatCommandCleanup").apply { isDaemon = true }
    }
    private var future: ScheduledFuture<*>? = null

    @Synchronized
    override fun schedule(delayMs: Long, action: () -> Unit) {
        if (future?.isDone == false) return
        future = executor.schedule(
            {
                synchronized(this) { future = null }
                action()
            },
            delayMs,
            TimeUnit.MILLISECONDS,
        )
    }
}

private class AndroidCleanupBackstop(private val context: Context) : CleanupBackstop {
    private val scheduler get() = context.getSystemService(JobScheduler::class.java)

    override fun schedule(minimumLatencyMs: Long): Boolean {
        val latency = minimumLatencyMs.coerceIn(
            CommandCleanupCoordinator.MIN_RETRY_MS,
            MAX_JOB_DELAY_MS,
        )
        val info = JobInfo.Builder(
            JOB_ID,
            ComponentName(context, CommandCleanupJobService::class.java),
        )
            .setMinimumLatency(latency)
            .setOverrideDeadline((latency + MAX_JOB_JITTER_MS).coerceAtMost(MAX_JOB_DELAY_MS))
            .setBackoffCriteria(MIN_JOB_BACKOFF_MS, JobInfo.BACKOFF_POLICY_LINEAR)
            .setPersisted(true)
            .build()
        return try {
            scheduler.schedule(info) == JobScheduler.RESULT_SUCCESS
        } catch (e: Exception) {
            Log.w("ClawChat", "Unable to schedule durable command cleanup", e)
            false
        }
    }

    override fun cancel() {
        scheduler.cancel(JOB_ID)
    }

    companion object {
        const val JOB_ID = 0x43434C
        const val MIN_JOB_BACKOFF_MS = 10_000L
        const val MAX_JOB_JITTER_MS = 5_000L
        const val MAX_JOB_DELAY_MS = 60_000L
    }
}

internal object AndroidCleanupPidAccess {
    val probe = PidProcessProbe { processId ->
        val stat = File("/proc/$processId/stat")
        if (!stat.exists()) {
            PidProbeResult.Missing
        } else {
            try {
                val contents = stat.readText()
                val fields = contents.substring(contents.lastIndexOf(')') + 1)
                    .trim().split(Regex("\\s+"))
                fields.getOrNull(19)?.toLongOrNull()?.let(PidProbeResult::Present)
                    ?: PidProbeResult.RetryableUnknown
            } catch (_: java.io.FileNotFoundException) {
                PidProbeResult.Missing
            } catch (_: Exception) {
                PidProbeResult.RetryableUnknown
            }
        }
    }
    val signaler = PidProcessSignaler(android.os.Process::killProcess)
}

internal object CommandCleanupCoordinatorProvider {
    @Volatile
    private var instance: CommandCleanupCoordinator? = null

    fun get(context: Context): CommandCleanupCoordinator = instance ?: synchronized(this) {
        instance ?: create(context.applicationContext).also { coordinator ->
            instance = coordinator
            coordinator.initialize()
            coordinator.reconcile()
        }
    }

    private fun create(context: Context): CommandCleanupCoordinator {
        // Force-stop suppresses persisted jobs until the user launches the app;
        // this provider then reconciles before any command admission. After a
        // reboot the persisted job runs, observes the old generation as gone,
        // and clears the durable block without signalling a reused PID.
        val ledger = AtomicCommandCleanupLedger(
            File(context.noBackupFilesDir, "command_cleanup_ledger_v2.bin"),
            fileOps = AndroidCleanupLedgerFileOps,
        )
        return CommandCleanupCoordinator(
            ledger = ledger,
            disposer = CleanupProcessDisposer { record ->
                val process = PidOwnedCommandProcess.fromGeneration(
                    record.processId,
                    record.startTimeTicks,
                    AndroidCleanupPidAccess.probe,
                    AndroidCleanupPidAccess.signaler,
                )
                val result = process.dispose(
                    signal = true,
                )
                CleanupDisposalAttempt(result)
            },
            immediateScheduler = ExecutorCleanupScheduler(),
            backstop = AndroidCleanupBackstop(context),
            launchDirectory = File(context.noBackupFilesDir, "command_launch_gate_v1"),
            recoveryProbe = AndroidCleanupPidAccess.probe,
            currentUid = { android.os.Process.myUid() },
            onDefinitive = { record, liveIdentity ->
                if (liveIdentity != null) {
                    val liveKey = liveIdentity.key
                    if (record.owner == CommandContinuationOwner.TERMINAL &&
                        liveIdentity.candidateId != null) {
                        NativeCommandContinuationOwner.registry.cancelTerminal(
                            liveKey,
                            liveIdentity.candidateId,
                        )
                        TerminalSessionService.onCoordinatorCleanup()
                    } else if (record.owner == CommandContinuationOwner.AGENT_BASH) {
                        NativeCommandContinuationOwner.registry.cancel(liveKey)
                        AgentTaskService.onCoordinatorCleanup(liveKey)
                    }
                }
            },
        )
    }
}

class CommandCleanupJobService : JobService() {
    override fun onStartJob(params: JobParameters): Boolean {
        Thread({
            val pending = CommandCleanupCoordinatorProvider.get(applicationContext).reconcile()
            jobFinished(params, pending)
        }, "ClawChatCleanupJob").start()
        return true
    }

    override fun onStopJob(params: JobParameters): Boolean = true
}
