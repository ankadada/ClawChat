package com.anka.clawbot

/**
 * Disk budget for the exported share-image cache.
 *
 * `MainActivity` is exported, so any installed app can send
 * `ACTION_SEND` / `ACTION_SEND_MULTIPLE` again and again. One Intent may copy
 * up to `MainActivity.MAX_SHARED_IMAGES` images, so without a total budget the
 * cache directory grows until the device runs out of space. This policy is a
 * pure function so it can be unit tested without the Android framework; the
 * caller performs the deletes.
 */
internal object SharedIntentCacheQuota {
    /** Total bytes the cache directory may hold, including the incoming file. */
    const val MAX_TOTAL_BYTES = 64L * 1024L * 1024L

    /** Total files the cache directory may hold, including the incoming file. */
    const val MAX_FILES = 64

    internal data class Entry(
        val path: String,
        val size: Long,
        val lastModified: Long
    )

    internal data class Plan(
        val deletePaths: List<String>,
        val accepted: Boolean
    )

    /**
     * Plans deletes for [entries] so that one more file of [incomingBytes]
     * fits. Oldest entries are removed first. When the incoming file cannot
     * fit even with an empty cache, the plan is rejected and no deletes are
     * planned.
     *
     * [maxTotalBytes] and [maxFiles] default to the production budget; tests
     * pass a small budget to exercise eviction and rejection cheaply.
     */
    fun plan(
        entries: List<Entry>,
        incomingBytes: Long,
        maxTotalBytes: Long = MAX_TOTAL_BYTES,
        maxFiles: Int = MAX_FILES
    ): Plan {
        if (incomingBytes <= 0L) return Plan(emptyList(), false)

        val oldestFirst = entries.sortedWith(
            compareBy({ it.lastModified }, { it.path })
        )
        var totalBytes = entries.sumOf { it.size }
        var fileCount = entries.size
        val deletePaths = mutableListOf<String>()
        var index = 0

        while (index < oldestFirst.size &&
            (totalBytes + incomingBytes > maxTotalBytes ||
                fileCount + 1 > maxFiles)
        ) {
            val victim = oldestFirst[index++]
            totalBytes -= victim.size
            fileCount -= 1
            deletePaths += victim.path
        }

        val accepted = totalBytes + incomingBytes <= maxTotalBytes &&
            fileCount + 1 <= maxFiles
        if (!accepted) {
            return Plan(deletePaths = emptyList(), accepted = false)
        }
        return Plan(deletePaths, accepted = true)
    }
}
