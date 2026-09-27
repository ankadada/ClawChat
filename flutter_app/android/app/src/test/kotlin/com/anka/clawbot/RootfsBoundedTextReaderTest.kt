package com.anka.clawbot

import java.nio.charset.StandardCharsets
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The `read_file` host path must never return more than the bounded cap and
 * must never buffer the whole file. These run on the JVM without Android.
 */
class RootfsBoundedTextReaderTest {

    @Test
    fun `small file is returned unchanged with no marker`() {
        val file = Files.createTempFile("bounded-small", ".txt")
        try {
            val text = "hello\nworld\n"
            Files.write(file, text.toByteArray(StandardCharsets.UTF_8))

            val result = RootfsBoundedTextReader.read(file)

            assertEquals(text, result)
            assertFalse(result.contains(RootfsBoundedTextReader.TRUNCATION_MARKER))
        } finally {
            Files.deleteIfExists(file)
        }
    }

    @Test
    fun `large ascii file is capped and marked`() {
        val file = Files.createTempFile("bounded-large", ".txt")
        try {
            val size = 1_000_000
            val content = ByteArray(size) { 'a'.code.toByte() }
            Files.write(file, content)

            val result = RootfsBoundedTextReader.read(file)

            assertEquals(
                RootfsBoundedTextReader.MAX_CHARS +
                    RootfsBoundedTextReader.TRUNCATION_MARKER.length,
                result.length,
            )
            assertTrue(result.endsWith(RootfsBoundedTextReader.TRUNCATION_MARKER))
            assertEquals("a", result.substring(0, 1))
        } finally {
            Files.deleteIfExists(file)
        }
    }

    @Test
    fun `large multibyte file is capped below the byte budget and marked`() {
        val file = Files.createTempFile("bounded-multibyte", ".txt")
        try {
            val chars = 200_000
            val builder = StringBuilder(chars)
            repeat(chars) { builder.append('\u4E2D') }
            Files.write(file, builder.toString().toByteArray(StandardCharsets.UTF_8))

            val result = RootfsBoundedTextReader.read(file)

            assertTrue(result.endsWith(RootfsBoundedTextReader.TRUNCATION_MARKER))
            assertEquals(
                RootfsBoundedTextReader.MAX_CHARS +
                    RootfsBoundedTextReader.TRUNCATION_MARKER.length,
                result.length,
            )
        } finally {
            Files.deleteIfExists(file)
        }
    }

    @Test
    fun `result never exceeds the character cap plus the marker`() {
        val file = Files.createTempFile("bounded-any", ".txt")
        try {
            // Exactly the byte cap: the read must stay bounded and the text
            // must still not exceed the character cap.
            Files.write(file, ByteArray(RootfsBoundedTextReader.MAX_BYTES) { 'x'.code.toByte() })
            val atCap = RootfsBoundedTextReader.read(file)
            assertTrue(
                atCap.length <=
                    RootfsBoundedTextReader.MAX_CHARS +
                    RootfsBoundedTextReader.TRUNCATION_MARKER.length,
            )

            // One byte past the cap with 4-byte characters.
            val over = Files.createTempFile("bounded-over", ".txt")
            try {
                val emoji = "\uD83D\uDE00" // U+1F600, 4 UTF-8 bytes
                val builder = StringBuilder()
                repeat(RootfsBoundedTextReader.MAX_BYTES / 4 + 1) { builder.append(emoji) }
                Files.write(over, builder.toString().toByteArray(StandardCharsets.UTF_8))
                val overResult = RootfsBoundedTextReader.read(over)
                assertTrue(
                    overResult.length <=
                        RootfsBoundedTextReader.MAX_CHARS +
                        RootfsBoundedTextReader.TRUNCATION_MARKER.length,
                )
                assertTrue(overResult.endsWith(RootfsBoundedTextReader.TRUNCATION_MARKER))
            } finally {
                Files.deleteIfExists(over)
            }
        } finally {
            Files.deleteIfExists(file)
        }
    }

    @Test
    fun `no-follow variant matches the bounded read for a regular file`() {
        val file = Files.createTempFile("bounded-nofollow", ".txt")
        try {
            val size = 500_000
            Files.write(file, ByteArray(size) { 'b'.code.toByte() })

            assertEquals(
                RootfsBoundedTextReader.read(file),
                RootfsBoundedTextReader.readNoFollow(file),
            )
        } finally {
            Files.deleteIfExists(file)
        }
    }
}
