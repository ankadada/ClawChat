package com.anka.clawbot

import java.io.File
import java.io.IOException
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class SharedIntentCacheWriterTest {
    private fun tempDir(): File =
        Files.createTempDirectory("share-cache-writer").toFile().apply {
            deleteOnExit()
        }

    private fun File.entries(): List<String> =
        listFiles()?.filter { it.isFile }?.map { it.name }?.sorted().orEmpty()

    private fun stagingFiles(dir: File): List<String> =
        File(dir, SharedIntentCacheWriter.STAGING_DIR_NAME)
            .listFiles()
            ?.filter { it.isFile }
            ?.map { it.name }
            ?.sorted()
            .orEmpty()

    private class FailingOps(
        private val shouldFail: (from: File, to: File) -> Boolean,
    ) : SharedIntentCacheFileOps {
        override fun rename(from: File, to: File): Boolean =
            if (shouldFail(from, to)) false else from.renameTo(to)

        override fun delete(file: File): Boolean = file.delete()
    }

    private fun write(dir: File, name: String, size: Int, modifiedAt: Long) {
        val file = File(dir, name)
        file.writeBytes(ByteArray(size) { 7 })
        file.setLastModified(modifiedAt)
    }

    @Test
    fun publishesTheFinalFileWithoutLeavingATemp() {
        val dir = tempDir()

        val published = SharedIntentCacheWriter.store(
            directory = dir,
            finalName = "image-1.png",
            maxSingleFileBytes = 1024,
        ) { temp ->
            temp.writeBytes(ByteArray(512) { 3 })
        }

        assertEquals("image-1.png", published.name)
        assertEquals(512L, published.length())
        assertEquals(listOf("image-1.png"), dir.entries())
        assertTrue(dir.entries().none { it.endsWith(".part") })
    }

    @Test
    fun aFailedWriteLeavesNoEntryAndNoTemp() {
        val dir = tempDir()
        write(dir, "existing-1.png", 10, 1L)

        val error = assertThrows(IOException::class.java) {
            SharedIntentCacheWriter.store(
                directory = dir,
                finalName = "failed.png",
                maxSingleFileBytes = 1024,
            ) { temp ->
                temp.writeBytes(ByteArray(64) { 1 })
                throw IOException("provider interrupted")
            }
        }

        assertEquals("provider interrupted", error.message)
        // The old entry survives and no partial entry appears.
        assertEquals(listOf("existing-1.png"), dir.entries())
    }

    @Test
    fun aPartiallyWrittenPayloadIsDiscarded() {
        val dir = tempDir()

        assertThrows(IOException::class.java) {
            SharedIntentCacheWriter.store(
                directory = dir,
                finalName = "partial.png",
                maxSingleFileBytes = 1024,
            ) { temp ->
                temp.outputStream().use { output ->
                    output.write(ByteArray(32) { 2 })
                    output.flush()
                }
                throw IOException("connection reset")
            }
        }

        assertTrue(dir.entries().isEmpty())
    }

    @Test
    fun anEmptyOrOversizedPayloadIsRejected() {
        val dir = tempDir()

        assertThrows(IllegalArgumentException::class.java) {
            SharedIntentCacheWriter.store(
                directory = dir,
                finalName = "empty.png",
                maxSingleFileBytes = 1024,
            ) { temp ->
                temp.writeBytes(ByteArray(0))
            }
        }

        assertThrows(IllegalArgumentException::class.java) {
            SharedIntentCacheWriter.store(
                directory = dir,
                finalName = "huge.png",
                maxSingleFileBytes = 16,
            ) { temp ->
                temp.writeBytes(ByteArray(64) { 4 })
            }
        }

        assertTrue(dir.entries().isEmpty())
    }

    @Test
    fun aPayloadThatCannotFitTheQuotaIsRejectedWithoutEvicting() {
        val dir = tempDir()
        write(dir, "oldest.png", 6, 1L)
        write(dir, "newer.png", 3, 2L)

        assertThrows(IllegalArgumentException::class.java) {
            SharedIntentCacheWriter.store(
                directory = dir,
                finalName = "cannot-fit.png",
                maxSingleFileBytes = 1024,
                quotaTotalBytes = 10,
                quotaMaxFiles = 8,
            ) { temp ->
                temp.writeBytes(ByteArray(11) { 5 })
            }
        }

        // A doomed write never deletes an existing entry.
        assertEquals(listOf("newer.png", "oldest.png"), dir.entries())
    }

    @Test
    fun evictionIsCommittedOnlyAfterTheCopySucceeded() {
        val dir = tempDir()
        write(dir, "oldest.png", 6, 1L)
        write(dir, "newer.png", 3, 2L)

        val published = SharedIntentCacheWriter.store(
            directory = dir,
            finalName = "fresh.png",
            maxSingleFileBytes = 1024,
            quotaTotalBytes = 10,
            quotaMaxFiles = 8,
        ) { temp ->
            temp.writeBytes(ByteArray(5) { 9 })
        }

        assertEquals("fresh.png", published.name)
        assertEquals(listOf("fresh.png", "newer.png"), dir.entries())
        assertTrue(dir.entries().none { it.endsWith(".part") })
    }

    @Test
    fun theFileCountQuotaEvictsTheOldestEntry() {
        val dir = tempDir()
        write(dir, "first.png", 1, 1L)
        write(dir, "second.png", 1, 2L)

        SharedIntentCacheWriter.store(
            directory = dir,
            finalName = "third.png",
            maxSingleFileBytes = 1024,
            quotaTotalBytes = 1_000L,
            quotaMaxFiles = 2,
        ) { temp ->
            temp.writeBytes(ByteArray(1) { 8 })
        }

        assertEquals(listOf("second.png", "third.png"), dir.entries())
    }

    @Test
    fun staleTempsAreReapedBeforeANewWrite() {
        val dir = tempDir()
        val stale = File(dir, "shared-intent-stale.part")
        stale.writeBytes(ByteArray(4) { 1 })
        stale.setLastModified(System.currentTimeMillis() - 2L * 60L * 60L * 1000L)

        val published = SharedIntentCacheWriter.store(
            directory = dir,
            finalName = "fresh.png",
            maxSingleFileBytes = 1024,
        ) { temp ->
            temp.writeBytes(ByteArray(2) { 2 })
        }

        assertEquals("fresh.png", published.name)
        assertEquals(listOf("fresh.png"), dir.entries())
        assertFalse(stale.exists())
    }

    @Test
    fun aFreshTempIsNotReapedWhileAnotherCopyIsRunning() {
        val dir = tempDir()
        val active = File(dir, "shared-intent-active.part")
        active.writeBytes(ByteArray(4) { 1 })

        SharedIntentCacheWriter.store(
            directory = dir,
            finalName = "fresh.png",
            maxSingleFileBytes = 1024,
        ) { temp ->
            temp.writeBytes(ByteArray(2) { 2 })
        }

        assertTrue(active.exists())
    }

    @Test
    fun aFailedPublishRestoresTheEvictedVictims() {
        val dir = tempDir()
        write(dir, "oldest.png", 6, 1L)
        write(dir, "newer.png", 3, 2L)
        val ops = FailingOps { _, to -> to.name == "fresh.png" }

        assertThrows(IOException::class.java) {
            SharedIntentCacheWriter.store(
                directory = dir,
                finalName = "fresh.png",
                maxSingleFileBytes = 1024,
                quotaTotalBytes = 10,
                quotaMaxFiles = 8,
                fileOps = ops,
            ) { temp ->
                temp.writeBytes(ByteArray(5) { 9 })
            }
        }

        // The eviction is rolled back: both images are back under their names,
        // the new file was never published, and no temp/staging remains.
        assertEquals(listOf("newer.png", "oldest.png"), dir.entries())
        assertEquals(6L, File(dir, "oldest.png").length())
        assertEquals(3L, File(dir, "newer.png").length())
        assertFalse(File(dir, "fresh.png").exists())
        assertTrue(stagingFiles(dir).isEmpty())
    }

    @Test
    fun aFailedPostEvictionRecheckKeepsTheCacheIntact() {
        val dir = tempDir()
        write(dir, "oldest.png", 6, 1L)
        write(dir, "newer.png", 3, 2L)
        // Moves report success but never happen, so the re-check still sees
        // the victim and must abort without publishing.
        val ops = object : SharedIntentCacheFileOps {
            override fun rename(from: File, to: File): Boolean = true

            override fun delete(file: File): Boolean = file.delete()
        }

        assertThrows(IllegalArgumentException::class.java) {
            SharedIntentCacheWriter.store(
                directory = dir,
                finalName = "fresh.png",
                maxSingleFileBytes = 1024,
                quotaTotalBytes = 10,
                quotaMaxFiles = 8,
                fileOps = ops,
            ) { temp ->
                temp.writeBytes(ByteArray(5) { 9 })
            }
        }

        assertEquals(listOf("newer.png", "oldest.png"), dir.entries())
        assertFalse(File(dir, "fresh.png").exists())
        assertTrue(stagingFiles(dir).isEmpty())
    }

    @Test
    fun aFailedStagingRenameRestoresTheAlreadyMovedVictims() {
        val dir = tempDir()
        write(dir, "a.png", 4, 1L)
        write(dir, "b.png", 4, 2L)
        write(dir, "c.png", 4, 3L)
        val ops = FailingOps { from, _ -> from.name == "b.png" }

        assertThrows(IOException::class.java) {
            SharedIntentCacheWriter.store(
                directory = dir,
                finalName = "fresh.png",
                maxSingleFileBytes = 1024,
                quotaTotalBytes = 10,
                quotaMaxFiles = 8,
                fileOps = ops,
            ) { temp ->
                temp.writeBytes(ByteArray(4) { 9 })
            }
        }

        assertEquals(listOf("a.png", "b.png", "c.png"), dir.entries())
        assertFalse(File(dir, "fresh.png").exists())
        assertTrue(stagingFiles(dir).isEmpty())
    }

    @Test
    fun aSuccessfulPublishDiscardsTheStagedVictims() {
        val dir = tempDir()
        write(dir, "oldest.png", 6, 1L)
        write(dir, "newer.png", 3, 2L)

        val published = SharedIntentCacheWriter.store(
            directory = dir,
            finalName = "fresh.png",
            maxSingleFileBytes = 1024,
            quotaTotalBytes = 10,
            quotaMaxFiles = 8,
        ) { temp ->
            temp.writeBytes(ByteArray(5) { 9 })
        }

        assertEquals("fresh.png", published.name)
        assertEquals(listOf("fresh.png", "newer.png"), dir.entries())
        assertTrue(stagingFiles(dir).isEmpty())
        assertFalse(File(dir, "oldest.png").exists())
    }

    @Test
    fun aStagingDirectoryLeftByAKilledProcessIsReclaimed() {
        val dir = tempDir()
        val staging = File(dir, SharedIntentCacheWriter.STAGING_DIR_NAME).apply { mkdirs() }
        File(staging, "leftover.evicted").writeBytes(ByteArray(3) { 1 })

        SharedIntentCacheWriter.store(
            directory = dir,
            finalName = "fresh.png",
            maxSingleFileBytes = 1024,
        ) { temp ->
            temp.writeBytes(ByteArray(2) { 2 })
        }

        assertEquals(listOf("fresh.png"), dir.entries())
        assertTrue(stagingFiles(dir).isEmpty())
    }
}
