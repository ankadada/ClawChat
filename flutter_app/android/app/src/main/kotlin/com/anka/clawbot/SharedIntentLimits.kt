package com.anka.clawbot

import java.nio.charset.StandardCharsets

/**
 * Bounds for content that arrives from an exported share Intent.
 *
 * `MainActivity` is `exported`, so any installed app can send it an
 * `ACTION_SEND` / `ACTION_SEND_MULTIPLE` Intent. The text, subject, and stream
 * URI list are therefore hostile input and must be bounded before they are
 * copied into the Dart isolate.
 */
internal object SharedIntentLimits {
    /** Maximum UTF-8 bytes kept from `EXTRA_TEXT`. */
    const val MAX_TEXT_BYTES = 64 * 1024

    /** Maximum UTF-8 bytes kept from `EXTRA_SUBJECT`. */
    const val MAX_SUBJECT_BYTES = 1024

    /** Maximum stream / clip-data URIs enumerated from one Intent. */
    const val MAX_STREAM_URIS = 64

    internal data class Truncation(val text: String, val droppedBytes: Int)

    internal data class BoundedItems<T>(val items: List<T>, val droppedCount: Int)

    /**
     * Collects non-null values in order until [limit] distinct items are kept.
     *
     * Deduplication happens *before* the limit is applied: a repeated value is
     * never counted as dropped and never consumes one of the [limit] slots, so
     * an exporter that repeats the same URI cannot crowd out a real attachment.
     * Only distinct values beyond the limit are reported in [BoundedItems.droppedCount].
     */
    fun <T> collectDistinct(
        limit: Int,
        keyOf: (T) -> String,
        values: Sequence<T?>
    ): BoundedItems<T> {
        require(limit > 0)
        val items = ArrayList<T>(minOf(limit, 16))
        val seen = HashSet<String>(minOf(limit * 2, 128))
        var dropped = 0
        for (value in values) {
            if (value == null) continue
            if (!seen.add(keyOf(value))) continue
            if (items.size >= limit) {
                dropped++
                continue
            }
            items.add(value)
        }
        return BoundedItems(items, dropped)
    }

    /**
     * Truncates [value] to at most [maxBytes] UTF-8 bytes without splitting a
     * multi-byte code point, and reports how many bytes were dropped.
     */
    private val imageMimeTypesByExtension = mapOf(
        "png" to "image/png",
        "jpg" to "image/jpeg",
        "jpeg" to "image/jpeg",
        "gif" to "image/gif",
        "webp" to "image/webp",
        "bmp" to "image/bmp",
        "heic" to "image/heic"
    )

    /**
     * Image MIME type for one shared file name, or null when the extension is
     * not a supported image. Used only as a last resort for file:// shares,
     * where the ContentResolver reports no type and the sending app may omit
     * Intent.type; nothing is imported unless the result starts with image/.
     */
    fun imageMimeTypeForName(name: String): String? {
        val extension = name.substringAfterLast('.', "").lowercase()
        return imageMimeTypesByExtension[extension]
    }

    /**
     * User-facing reason for a shared stream the app could not open.
     *
     * A file:// share carries no read grant: scoped storage makes the sender's
     * path unreadable (EACCES) and widening that read would mean arbitrary
     * path access, which this app never does. The copy therefore names the
     * action that works instead of pretending the share is supported.
     */
    fun unreadableSharedStreamMessage(fileScheme: Boolean): String = if (fileScheme) {
        "无法读取分享的文件：发送方没有授予读取权限。请改用系统文件选择器，或从支持 content:// 分享的应用重试。"
    } else {
        "无法读取分享的文件：来源可能已失效，请重新分享或改用系统文件选择器。"
    }

    fun truncateUtf8(value: String, maxBytes: Int): Truncation {
        if (maxBytes <= 0) {
            return Truncation("", value.toByteArray(StandardCharsets.UTF_8).size)
        }
        val bytes = value.toByteArray(StandardCharsets.UTF_8)
        if (bytes.size <= maxBytes) return Truncation(value, 0)
        var end = maxBytes
        // Back off over continuation bytes so the cut lands on a code point
        // boundary and the truncated string is still valid UTF-8.
        while (end > 0 && (bytes[end].toInt() and 0xC0) == 0x80) {
            end--
        }
        if (end == 0) return Truncation("", bytes.size)
        return Truncation(
            String(bytes, 0, end, StandardCharsets.UTF_8),
            bytes.size - end
        )
    }
}
