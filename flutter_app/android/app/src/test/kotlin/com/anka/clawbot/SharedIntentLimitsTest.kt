package com.anka.clawbot

import java.nio.charset.StandardCharsets
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SharedIntentLimitsTest {
    @Test
    fun anUnreadableFileSharePointsAtTheWorkingAlternative() {
        // Scoped storage makes a sender's file:// path unreadable; the app
        // must say what to do instead of claiming the share is supported.
        val fileMessage = SharedIntentLimits.unreadableSharedStreamMessage(
            fileScheme = true
        )
        assertTrue(fileMessage.contains("content://"))
        assertTrue(fileMessage.contains("系统文件选择器"))

        val contentMessage = SharedIntentLimits.unreadableSharedStreamMessage(
            fileScheme = false
        )
        assertFalse(contentMessage.contains("content://"))
    }

    @Test
    fun imageMimeIsInferredFromTheFileNameForFileShares() {
        // A file:// share has no ContentResolver type; the extension is the
        // only signal left when the sender omits Intent.type.
        assertEquals(
            "image/png",
            SharedIntentLimits.imageMimeTypeForName("/storage/shared/DCIM/a.PNG")
        )
        assertEquals(
            "image/jpeg",
            SharedIntentLimits.imageMimeTypeForName("photo.jpeg")
        )
        assertEquals(
            "image/webp",
            SharedIntentLimits.imageMimeTypeForName("clip.webp")
        )
    }

    @Test
    fun unknownOrMissingExtensionsStayUnsupported() {
        assertEquals(null, SharedIntentLimits.imageMimeTypeForName("notes.txt"))
        assertEquals(null, SharedIntentLimits.imageMimeTypeForName("no-extension"))
        assertEquals(null, SharedIntentLimits.imageMimeTypeForName("archive.zip"))
    }

    @Test
    fun contentWithinTheCapIsUnchanged() {
        val value = "hello 世界"
        val result = SharedIntentLimits.truncateUtf8(value, 1024)

        assertEquals(value, result.text)
        assertEquals(0, result.droppedBytes)
    }

    @Test
    fun oversizedAsciiTextIsTruncatedToTheByteCap() {
        val value = "a".repeat(100)
        val result = SharedIntentLimits.truncateUtf8(value, 10)

        assertEquals("a".repeat(10), result.text)
        assertEquals(90, result.droppedBytes)
        assertTrue(
            result.text.toByteArray(StandardCharsets.UTF_8).size <= 10
        )
    }

    @Test
    fun truncationNeverSplitsAMultiByteCodePoint() {
        val value = "字".repeat(10)
        val result = SharedIntentLimits.truncateUtf8(value, 7)

        assertEquals("字字", result.text)
        assertTrue(result.text.toByteArray(StandardCharsets.UTF_8).size <= 7)
        assertEquals(
            result.text,
            String(
                result.text.toByteArray(StandardCharsets.UTF_8),
                StandardCharsets.UTF_8
            )
        )
        assertFalse(result.text.contains('\uFFFD'))
    }

    @Test
    fun aCapSmallerThanTheFirstCodePointDropsEverything() {
        val result = SharedIntentLimits.truncateUtf8("字", 1)

        assertEquals("", result.text)
        assertEquals(3, result.droppedBytes)
    }

    @Test
    fun shareLimitsStayBounded() {
        assertTrue(SharedIntentLimits.MAX_TEXT_BYTES in 1..(1024 * 1024))
        assertTrue(SharedIntentLimits.MAX_SUBJECT_BYTES <= SharedIntentLimits.MAX_TEXT_BYTES)
        assertEquals(64, SharedIntentLimits.MAX_STREAM_URIS)
    }

    private fun collect(vararg values: String?): SharedIntentLimits.BoundedItems<String> =
        SharedIntentLimits.collectDistinct(
            limit = SharedIntentLimits.MAX_STREAM_URIS,
            keyOf = { it },
            values = values.asSequence()
        )

    @Test
    fun duplicateUrisNeverConsumeTheCap() {
        // The reviewer scenario: an exporter repeats one URI up to the cap,
        // then sends a genuinely new attachment that must still be kept.
        val duplicates = List(SharedIntentLimits.MAX_STREAM_URIS) {
            "content://same/1"
        }
        val result = SharedIntentLimits.collectDistinct(
            limit = SharedIntentLimits.MAX_STREAM_URIS,
            keyOf = { it },
            values = (duplicates + listOf("content://fresh/2")).asSequence()
        )

        assertEquals(
            listOf("content://same/1", "content://fresh/2"),
            result.items
        )
        assertEquals(0, result.droppedCount)
    }

    @Test
    fun onlyDistinctValuesBeyondTheCapAreDropped() {
        val distinct = (0 until SharedIntentLimits.MAX_STREAM_URIS + 1).map {
            "content://item/$it"
        }
        val withDuplicateTail = distinct + distinct.first()
        val result = SharedIntentLimits.collectDistinct(
            limit = SharedIntentLimits.MAX_STREAM_URIS,
            keyOf = { it },
            values = withDuplicateTail.asSequence()
        )

        assertEquals(SharedIntentLimits.MAX_STREAM_URIS, result.items.size)
        assertEquals(1, result.droppedCount)
        assertTrue(result.items.none { it == "content://item/${SharedIntentLimits.MAX_STREAM_URIS}" })
    }

    @Test
    fun nullCandidatesAreSkippedAndOrderIsPreserved() {
        val result = collect("a", null, "b", "a", null)

        assertEquals(listOf("a", "b"), result.items)
        assertEquals(0, result.droppedCount)
    }

    @Test
    fun theDistinctValueOrderDecidesWhichAttachmentSurvives() {
        val result = collect("first", "second", "third")

        assertEquals(listOf("first", "second", "third"), result.items)
    }
}
