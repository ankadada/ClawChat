package com.anka.clawbot

import java.util.UUID

/**
 * Reads a bounded byte range from one file below an already-verified root.
 *
 * The production reader is [SecureImportNative.readRootfsBytesBounded], a
 * descriptor-relative JNI walk (`openat` with `O_NOFOLLOW` on every component,
 * `O_NONBLOCK` on the final file, `fstat` type / link-count verification and a
 * post-read identity check). Host tests inject a fake through
 * [readScopedRootfsBytes].
 */
internal fun interface RootfsBytesReader {
    fun read(
        rootPath: String,
        relativePath: String,
        operationId: String,
        maxBytes: Long
    ): ByteArray?
}

/** Hard cap for one rootfs byte read (matches `MainActivity.MAX_TOOL_RESULT_IMAGE_BYTES`). */
internal const val MAX_ROOTFS_BYTES_READ = 2L * 1024L * 1024L

/** Fresh 32-hex id for the JNI broker's operation lease. */
internal fun newRootfsReadOperationId(): String =
    UUID.randomUUID().toString().replace("-", "")

/**
 * Normalizes a virtual rootfs path: separators collapse, `.` is dropped, and
 * `..`, NUL and backslashes are rejected outright.
 */
internal fun normalizeRootfsVirtualPath(path: String): String {
    if (path.indexOf('\u0000') >= 0 || path.contains('\\')) {
        throw SecurityException("Invalid rootfs path")
    }
    val segments = mutableListOf<String>()
    for (segment in path.split('/')) {
        if (segment.isEmpty() || segment == ".") continue
        if (segment == "..") throw SecurityException("Path traversal detected")
        segments.add(segment)
    }
    return if (segments.isEmpty()) "/" else "/" + segments.joinToString("/")
}

internal fun isRootfsPathInsideScope(path: String, scope: String): Boolean =
    scope == "/" || path == scope || path.startsWith("$scope/")

internal data class ResolvedRootfsRead(
    val rootHostPath: String,
    val relativePath: String
)

/**
 * Resolves a scoped virtual path to the host root the JNI walk starts from and
 * the path relative to it.
 *
 * The deepest granted root that contains the path wins, so a `/root/workspace`
 * grant never widens to `/`. The host root is left lexical on purpose: the JNI
 * broker rejects a root that is not its own `realpath`, so a guest-created
 * symlink in the scope chain fails closed instead of being followed.
 */
internal fun resolveRootfsReadLocation(
    rootfsDir: String,
    path: String,
    allowedRoots: List<String>
): ResolvedRootfsRead {
    if (allowedRoots.isEmpty()) throw SecurityException("No filesystem scope granted")
    val virtualPath = normalizeRootfsVirtualPath(path)
    val scopes = allowedRoots.map { normalizeRootfsVirtualPath(it) }
    val scope = scopes
        .filter { isRootfsPathInsideScope(virtualPath, it) }
        .maxByOrNull { it.length }
        ?: throw SecurityException("Path is outside the granted filesystem scope")
    val relative = virtualPath.removePrefix(scope).trimStart('/')
    if (relative.isEmpty()) throw SecurityException("Path is not a file")
    val base = rootfsDir.trimEnd('/')
    // The app-owned rootfs base can sit under a platform symlink (for example
    // /data/user/0 on some devices), which the JNI broker rejects when it
    // compares the root with its own realpath. Canonicalize the base once:
    // the granted scope stays lexical, so a guest-created symlink inside the
    // rootfs is still rejected by that same check.
    val canonicalBase = try {
        java.io.File(base).canonicalPath
    } catch (_: Exception) {
        base
    }
    val rootHostPath = if (scope == "/") canonicalBase else canonicalBase + scope
    return ResolvedRootfsRead(rootHostPath, relative)
}

/**
 * Scope check + descriptor-relative bounded read. A scope violation throws
 * [SecurityException]; a reader rejection (missing, empty, symlink, hard link,
 * special node, oversized, changed during the read) returns null so the caller
 * keeps the text form.
 */
internal fun readScopedRootfsBytes(
    rootfsDir: String,
    path: String,
    allowedRoots: List<String>,
    maxBytes: Long,
    operationId: String,
    reader: RootfsBytesReader,
    onRejected: ((String) -> Unit)? = null
): ByteArray? {
    if (maxBytes <= 0L) {
        onRejected?.invoke("budget rejected")
        return null
    }
    val location = resolveRootfsReadLocation(rootfsDir, path, allowedRoots)
    val bounded = minOf(maxBytes, MAX_ROOTFS_BYTES_READ)
    return try {
        reader.read(location.rootHostPath, location.relativePath, operationId, bounded)
    } catch (error: SecurityException) {
        // Safe classification for the device log: it says which check refused
        // the read (canonical root, component walk, size, identity) without
        // any file contents or credentials.
        onRejected?.invoke(error.message ?: "security rejection")
        null
    } catch (_: LinkageError) {
        // A missing or unloadable broker must fail closed, not crash the tool
        // result. ART reports a failed native load as UnsatisfiedLinkError and
        // later references as NoClassDefFoundError, both LinkageError.
        onRejected?.invoke("native broker unavailable")
        null
    }
}
