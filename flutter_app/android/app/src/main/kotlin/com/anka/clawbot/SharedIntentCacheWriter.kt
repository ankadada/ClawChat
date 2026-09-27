package com.anka.clawbot

import java.io.File
import java.io.IOException
import java.util.UUID

/**
 * File operations used by [SharedIntentCacheWriter].
 *
 * The production implementation is a direct [File] call; tests inject a fake
 * to fail a specific rename so the rollback paths can be exercised without a
 * broken filesystem.
 */
internal interface SharedIntentCacheFileOps {
    /** Moves [from] onto [to]. Returns false when the move did not happen. */
    fun rename(from: File, to: File): Boolean

    /** Deletes [file]. Returns false when it is still there. */
    fun delete(file: File): Boolean

    companion object {
        val DEFAULT: SharedIntentCacheFileOps = object : SharedIntentCacheFileOps {
            override fun rename(from: File, to: File): Boolean = from.renameTo(to)

            override fun delete(file: File): Boolean = file.delete()
        }
    }
}

/**
 * Two-phase write for the exported share-image cache.
 *
 * The payload is copied into a random `.part` file first. Only after that copy
 * completed is the quota plan computed, and only then are the victims *moved*
 * into a staging directory — never deleted outright. The final name is
 * published by an atomic rename:
 *
 *  - a failed, interrupted, or partial copy deletes the temp file and leaves
 *    the cache untouched (no eviction happened yet);
 *  - a failed publish or a failed post-eviction re-check moves every staged
 *    victim back to its original name, so a transient rename error cannot
 *    permanently lose cached images;
 *  - only a successful publish discards the staged victims, and any staging
 *    directory left behind by a killed process is reclaimed before the next
 *    write;
 *  - a copy that cannot fit the quota is rejected before any eviction.
 */
internal object SharedIntentCacheWriter {
    /** `.part` files older than this are leftovers of a killed copy. */
    const val STALE_TEMP_AGE_MS = 60L * 60L * 1000L

    /** Directory that holds eviction victims until the publish succeeded. */
    const val STAGING_DIR_NAME = ".evict"

    private const val TEMP_PREFIX = "shared-intent-"
    private const val TEMP_SUFFIX = ".part"
    private const val STAGED_SUFFIX = ".evicted"

    private data class StagedVictim(val original: File, val staged: File)

    /**
     * Copies one shared image into [directory] and returns the published file.
     *
     * [writeTo] receives a fresh temp file that already lives in [directory],
     * writes the payload into it, and returns nothing; the byte count is read
     * from the temp file itself so a writer that forgot to flush cannot
     * under-report the size.
     *
     * @throws IllegalArgumentException when the payload is empty, larger than
     *   [maxSingleFileBytes], or cannot fit the cache quota.
     * @throws IOException when the directory, the eviction staging, or the
     *   publish step is unavailable.
     */
    fun store(
        directory: File,
        finalName: String,
        maxSingleFileBytes: Long,
        quotaTotalBytes: Long = SharedIntentCacheQuota.MAX_TOTAL_BYTES,
        quotaMaxFiles: Int = SharedIntentCacheQuota.MAX_FILES,
        nowMs: Long = System.currentTimeMillis(),
        staleTempAgeMs: Long = STALE_TEMP_AGE_MS,
        fileOps: SharedIntentCacheFileOps = SharedIntentCacheFileOps.DEFAULT,
        writeTo: (File) -> Unit
    ): File {
        if (!directory.exists() && !directory.mkdirs()) {
            throw IOException("share image cache is unavailable")
        }
        reclaimStaging(directory, fileOps)
        deleteStaleTemps(directory, nowMs, staleTempAgeMs, fileOps)
        val temp = File.createTempFile(TEMP_PREFIX, TEMP_SUFFIX, directory)
        var staged: List<StagedVictim> = emptyList()
        try {
            writeTo(temp)
            val written = temp.length()
            if (written <= 0L || written > maxSingleFileBytes) {
                throw IllegalArgumentException("shared image size is invalid")
            }
            val entries = topLevelFiles(directory)
                .filter { it.absolutePath != temp.absolutePath }
                .map { SharedIntentCacheQuota.Entry(it.absolutePath, it.length(), it.lastModified()) }
            val plan = SharedIntentCacheQuota.plan(
                entries = entries,
                incomingBytes = written,
                maxTotalBytes = quotaTotalBytes,
                maxFiles = quotaMaxFiles
            )
            if (!plan.accepted) {
                throw IllegalArgumentException(
                    "shared image cache quota of $quotaTotalBytes bytes is full"
                )
            }
            // Move, do not delete: a publish failure below restores them.
            staged = stageVictims(directory, plan.deletePaths, fileOps)
            // Re-check the real directory after staging: a move that silently
            // did nothing (or failed) must not let the new file exceed the cap.
            val remaining = topLevelFiles(directory)
                .filter { it.absolutePath != temp.absolutePath }
            if (remaining.size + 1 > quotaMaxFiles ||
                remaining.sumOf { it.length() } + written > quotaTotalBytes
            ) {
                throw IllegalArgumentException(
                    "shared image cache could not free enough space"
                )
            }
            val published = File(directory, finalName)
            if (!fileOps.rename(temp, published)) {
                throw IOException("share image could not be published")
            }
            // Publish succeeded: the victims are now genuinely evicted.
            for (victim in staged) {
                fileOps.delete(victim.staged)
            }
            reclaimStagingDirectory(directory, fileOps)
            return published
        } catch (error: Throwable) {
            restoreVictims(staged, fileOps)
            fileOps.delete(temp)
            reclaimStagingDirectory(directory, fileOps)
            throw error
        }
    }

    private fun topLevelFiles(directory: File): List<File> =
        directory.listFiles()?.filter { it.isFile }.orEmpty()

    /**
     * Moves every victim into the staging directory. When one move fails, the
     * victims moved so far are restored before the error is rethrown.
     */
    private fun stageVictims(
        directory: File,
        deletePaths: List<String>,
        fileOps: SharedIntentCacheFileOps
    ): List<StagedVictim> {
        if (deletePaths.isEmpty()) return emptyList()
        val staging = File(directory, STAGING_DIR_NAME)
        if (!staging.exists() && !staging.mkdirs()) {
            throw IOException("share image eviction staging is unavailable")
        }
        val moved = mutableListOf<StagedVictim>()
        try {
            for (path in deletePaths) {
                val original = File(path)
                val staged = File(
                    staging,
                    "${original.name}.${UUID.randomUUID()}$STAGED_SUFFIX"
                )
                if (!fileOps.rename(original, staged)) {
                    throw IOException("share image eviction failed")
                }
                moved += StagedVictim(original, staged)
            }
            return moved
        } catch (error: Throwable) {
            restoreVictims(moved, fileOps)
            throw error
        }
    }

    /**
     * Best-effort rollback: put every staged victim back under its original
     * name. A victim whose original name is occupied again is left staged and
     * reclaimed by the next write.
     */
    private fun restoreVictims(
        victims: List<StagedVictim>,
        fileOps: SharedIntentCacheFileOps
    ) {
        for (victim in victims.asReversed()) {
            if (!victim.staged.exists()) continue
            if (victim.original.exists()) continue
            if (!fileOps.rename(victim.staged, victim.original)) {
                // Best effort only; the staging directory is reclaimed next time.
            }
        }
    }

    /** Removes leftovers of a killed process before a new write starts. */
    private fun reclaimStaging(directory: File, fileOps: SharedIntentCacheFileOps) {
        try {
            val staging = File(directory, STAGING_DIR_NAME)
            staging.listFiles()?.forEach { fileOps.delete(it) }
        } catch (_: Exception) {
            // Best effort: whatever remains is reclaimed by a later write.
        }
    }

    private fun reclaimStagingDirectory(directory: File, fileOps: SharedIntentCacheFileOps) {
        try {
            val staging = File(directory, STAGING_DIR_NAME)
            if (staging.listFiles()?.isEmpty() == true) {
                fileOps.delete(staging)
            }
        } catch (_: Exception) {
            // Best effort; an empty staging directory is harmless.
        }
    }

    private fun deleteStaleTemps(
        directory: File,
        nowMs: Long,
        staleTempAgeMs: Long,
        fileOps: SharedIntentCacheFileOps
    ) {
        val cutoff = nowMs - staleTempAgeMs
        if (staleTempAgeMs <= 0L || cutoff <= 0L) return
        try {
            directory.listFiles()?.forEach { file ->
                if (file.isFile &&
                    file.name.endsWith(TEMP_SUFFIX) &&
                    file.lastModified() > 0L &&
                    file.lastModified() < cutoff
                ) {
                    fileOps.delete(file)
                }
            }
        } catch (_: Exception) {
            // Best effort: whatever remains is still counted by the quota plan.
        }
    }
}
