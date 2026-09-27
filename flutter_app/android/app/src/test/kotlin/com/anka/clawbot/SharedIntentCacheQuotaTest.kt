package com.anka.clawbot

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SharedIntentCacheQuotaTest {
    private fun entry(
        path: String,
        size: Long,
        lastModified: Long
    ) = SharedIntentCacheQuota.Entry(path, size, lastModified)

    @Test
    fun aFileThatFitsKeepsEveryEntry() {
        val entries = listOf(
            entry("a", 1_000L, 1L),
            entry("b", 2_000L, 2L),
        )

        val plan = SharedIntentCacheQuota.plan(entries, 3_000L)

        assertTrue(plan.accepted)
        assertTrue(plan.deletePaths.isEmpty())
    }

    @Test
    fun repeatedIntentsDeleteOldestUntilTheNewFileFits() {
        val perFile = SharedIntentCacheQuota.MAX_TOTAL_BYTES / 8L
        val entries = (0 until 8).map { index ->
            entry("cache-$index", perFile, index.toLong())
        }

        val plan = SharedIntentCacheQuota.plan(entries, perFile)

        assertTrue(plan.accepted)
        assertEquals(listOf("cache-0"), plan.deletePaths)
    }

    @Test
    fun oldestIsDeletedFirstEvenWhenNewerFilesAreLarger() {
        val entries = listOf(
            entry("newest", 10L, 30L),
            entry("oldest", 10L, 10L),
            entry("middle", 10L, 20L),
        )
        val incoming = SharedIntentCacheQuota.MAX_TOTAL_BYTES

        val plan = SharedIntentCacheQuota.plan(entries, incoming)

        assertTrue(plan.accepted)
        assertEquals(listOf("oldest", "middle", "newest"), plan.deletePaths)
    }

    @Test
    fun fileCountQuotaIsEnforced() {
        val entries = (0 until SharedIntentCacheQuota.MAX_FILES).map { index ->
            entry("file-$index", 1L, index.toLong())
        }

        val plan = SharedIntentCacheQuota.plan(entries, 1L)

        assertTrue(plan.accepted)
        assertEquals(listOf("file-0"), plan.deletePaths)
    }

    @Test
    fun aFileLargerThanTheWholeQuotaIsRejectedWithoutDeletingAnything() {
        val entries = listOf(entry("existing", 1_000L, 1L))

        val plan = SharedIntentCacheQuota.plan(
            entries,
            SharedIntentCacheQuota.MAX_TOTAL_BYTES + 1L
        )

        assertFalse(plan.accepted)
        assertTrue(plan.deletePaths.isEmpty())
    }

    @Test
    fun nonPositiveIncomingSizeIsRejected() {
        val plan = SharedIntentCacheQuota.plan(emptyList(), 0L)

        assertFalse(plan.accepted)
        assertTrue(plan.deletePaths.isEmpty())
    }

    @Test
    fun anEmptyCacheAcceptsOneFileWithinTheQuota() {
        val plan = SharedIntentCacheQuota.plan(
            emptyList(),
            SharedIntentCacheQuota.MAX_TOTAL_BYTES
        )

        assertTrue(plan.accepted)
        assertTrue(plan.deletePaths.isEmpty())
    }

    @Test
    fun repeatedIntentsNeverPushTheCachePastTheQuota() {
        // One ACTION_SEND_MULTIPLE for a full nine-image Intent, repeated far
        // more often than any cache quota should survive.
        val perImage = 3L * 1024L * 1024L
        val entries = mutableListOf<SharedIntentCacheQuota.Entry>()
        var writeIndex = 0L

        repeat(200) {
            val plan = SharedIntentCacheQuota.plan(entries, perImage)
            assertTrue(plan.accepted)
            val deleted = plan.deletePaths.toSet()
            entries.removeAll { it.path in deleted }
            entries += SharedIntentCacheQuota.Entry(
                path = "shared-$writeIndex",
                size = perImage,
                lastModified = writeIndex
            )
            writeIndex += 1

            assertTrue(
                entries.sumOf { entry -> entry.size } <=
                    SharedIntentCacheQuota.MAX_TOTAL_BYTES
            )
            assertTrue(entries.size <= SharedIntentCacheQuota.MAX_FILES)
        }
    }
}
