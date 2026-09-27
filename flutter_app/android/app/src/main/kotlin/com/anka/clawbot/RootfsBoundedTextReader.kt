package com.anka.clawbot

import java.nio.ByteBuffer
import java.nio.channels.SeekableByteChannel
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.OpenOption
import java.nio.file.Path
import java.nio.file.StandardOpenOption

/**
 * Bounded UTF-8 text read for the `read_file` host path.
 *
 * The previous implementation read the whole file into memory before Dart
 * truncated the formatted result at 100000 characters, so a large (or
 * adversarial) file under the granted workspace cost its full size in native
 * memory. This reader never allocates more than the byte cap and never returns
 * more than the character cap, and it appends the existing truncation marker so
 * the model can see the file was cut.
 *
 * The Dart side keeps its own 100000-character guard as a second line of
 * defense; this is the first. The bounded *bytes* read used for tool-result
 * images lives in [RootfsBytesReader] / the JNI broker, which is
 * descriptor-relative; this object only serves the text path.
 */
internal object RootfsBoundedTextReader {
    /** Character cap for the returned text, matching the Dart guard. */
    const val MAX_CHARS: Int = 100_000

    /** UTF-8 byte cap: never buffer more than this from the file. */
    const val MAX_BYTES: Int = 400_000

    /** The marker Dart already used for a truncated read. */
    const val TRUNCATION_MARKER: String = "\n\n[File truncated]"

    /** Reads [path], following the platform's normal open rules. */
    fun read(path: Path): String =
        Files.newByteChannel(path, setOf<OpenOption>(StandardOpenOption.READ))
            .use { bounded(it) }

    /**
     * Reads [path] without following a final symlink, matching the scope rules
     * the caller already applied.
     */
    fun readNoFollow(path: Path): String =
        Files.newByteChannel(
            path,
            setOf<OpenOption>(StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS),
        ).use { bounded(it) }

    private fun bounded(channel: SeekableByteChannel): String {
        val size = channel.size()
        val byteBudget = minOf(size, MAX_BYTES.toLong()).toInt()
        val bytes = ByteArray(byteBudget)
        val buffer = ByteBuffer.wrap(bytes)
        var filled = 0
        while (buffer.hasRemaining()) {
            // A non-positive read means EOF (0 would otherwise loop forever).
            val read = channel.read(buffer)
            if (read <= 0) break
            filled += read
        }
        // Cutting mid-sequence can only affect the final character, which is at
        // or after the cut point; replacement is preferable to throwing.
        val decoded = String(bytes, 0, filled, StandardCharsets.UTF_8)
        val boundedText = if (decoded.length > MAX_CHARS) {
            decoded.substring(0, MAX_CHARS)
        } else {
            decoded
        }
        val truncated = size > MAX_BYTES.toLong() || boundedText.length != decoded.length
        return if (truncated) boundedText + TRUNCATION_MARKER else boundedText
    }
}
