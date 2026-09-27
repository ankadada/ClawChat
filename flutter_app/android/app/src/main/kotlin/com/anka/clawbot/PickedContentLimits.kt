package com.anka.clawbot

/**
 * Size contract for a `content://` document staged from the system file picker.
 *
 * The picker hands the app an unbounded provider stream, so the copy must be
 * bounded before any byte is written. A declared size above the cap is rejected
 * without opening the stream at all: the user picked a file the app cannot
 * import, and the caller needs a specific, actionable error instead of a
 * generic staging failure.
 */
internal object PickedContentLimits {
    /** Hard cap for one staged document (50 MiB). */
    const val MAX_BYTES = 50L * 1024L * 1024L

    /** The caller asked for a limit outside `1..MAX_BYTES`. */
    const val ERROR_INVALID = "PICKED_CONTENT_INVALID"

    /** The document is larger than the allowed limit. */
    const val ERROR_TOO_LARGE = "PICKED_CONTENT_TOO_LARGE"

    /** The provider could not be read (or the copy failed for any other reason). */
    const val ERROR_UNAVAILABLE = "PICKED_CONTENT_UNAVAILABLE"

    const val DETAIL_LIMIT_BYTES = "limitBytes"
    const val DETAIL_ACTUAL_BYTES = "actualBytes"

    fun isValidLimit(maxBytes: Long): Boolean = maxBytes in 1..MAX_BYTES

    /** True when the provider-declared size already proves the file is too big. */
    fun exceedsDeclaredLimit(declaredBytes: Long?, maxBytes: Long): Boolean =
        declaredBytes != null && declaredBytes > maxBytes

    /** True when the bytes read so far exceed the limit. */
    fun exceedsStreamedLimit(totalBytes: Long, maxBytes: Long): Boolean =
        totalBytes > maxBytes
}

/**
 * Thrown when a picked document exceeds the caller's limit.
 *
 * Carries the numbers so the platform channel can report a size-specific error
 * instead of collapsing every failure into "unable to stage".
 */
internal class PickedContentTooLargeException(
    val limitBytes: Long,
    val actualBytes: Long?
) : Exception("picked content exceeds the size limit")
