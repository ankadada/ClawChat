package com.anka.clawbot

/**
 * One directory entry as the file browser sees it.
 */
internal data class RootfsDirectoryEntry(
    val name: String,
    /** Guest (virtual) path, ready to be handed back to the scoped APIs. */
    val path: String,
    val isDirectory: Boolean,
    val isSymbolicLink: Boolean,
    val sizeBytes: Long,
    val modifiedEpochMs: Long
)

internal data class RootfsDirectoryListing(
    val entries: List<RootfsDirectoryEntry>,
    val truncated: Boolean
)

/**
 * Lists one directory inside a granted rootfs scope.
 *
 * The scope policy (virtual-path normalization, granted-scope containment) lives
 * here and is unit-tested on the JVM; the filesystem walk itself is
 * descriptor-relative in SecureImportNative.listRootfsDirectoryBounded, because a
 * pathname check followed by a pathname use can be swapped by the guest that
 * writes the same tree.
 */
internal object RootfsDirectoryLister {
    /** Hard cap on returned entries, whatever the caller asks for. */
    const val MAX_ENTRIES = 500

    /** Default page size for the file browser. */
    const val DEFAULT_MAX_ENTRIES = 200

    internal data class ScopedDirectory(
        val rootHostPath: String,
        val relativePath: String
    )

    /**
     * Resolves a guest path to the host root the broker walks from and the path
     * relative to it. The deepest granted scope wins, so a /root/workspace grant
     * never widens to the rootfs root, and the scope root itself is allowed here
     * (listing a scope root is listing the workspace root).
     */
    internal fun resolveScopedDirectory(
        rootfsDir: String,
        path: String,
        allowedRoots: List<String>
    ): ScopedDirectory {
        if (allowedRoots.isEmpty()) {
            throw SecurityException("No filesystem scope granted")
        }
        val virtualPath = normalizeRootfsVirtualPath(path)
        val scopes = allowedRoots.map { normalizeRootfsVirtualPath(it) }
        val scope = scopes
            .filter { isRootfsPathInsideScope(virtualPath, it) }
            .maxByOrNull { it.length }
            ?: throw SecurityException("Path is outside the granted filesystem scope")
        val base = rootfsDir.trimEnd('/')
        val rootHostPath = if (scope == "/") base else base + scope
        return ScopedDirectory(
            rootHostPath = rootHostPath,
            relativePath = virtualPath.removePrefix(scope).trimStart('/')
        )
    }

    fun list(
        rootfsDir: String,
        path: String,
        allowedRoots: List<String>,
        maxEntries: Int = DEFAULT_MAX_ENTRIES
    ): RootfsDirectoryListing {
        val scoped = resolveScopedDirectory(rootfsDir, path, allowedRoots)
        val virtualRoot = normalizeRootfsVirtualPath(path)
        val limit = maxEntries.coerceIn(1, MAX_ENTRIES)
        val rows = try {
            SecureImportNative.listRootfsDirectoryBounded(
                scoped.rootHostPath,
                scoped.relativePath,
                limit + 1
            )
        } catch (_: Throwable) {
            // A missing or unloadable broker must fail closed, not crash.
            null
        } ?: throw SecurityException("Directory is not accessible")

        val entries = ArrayList<RootfsDirectoryEntry>(rows.size)
        for (row in rows) {
            val parsed = parseRow(row, virtualRoot) ?: continue
            entries.add(parsed)
        }
        val truncated = entries.size > limit
        val page = if (truncated) entries.subList(0, limit).toList() else entries
        return RootfsDirectoryListing(entries = page, truncated = truncated)
    }

    /**
     * Row format from the broker: name, type (d / f / l), size, mtime. The name
     * comes first and may itself contain tabs, so only the three trailing fields
     * are positional.
     */
    internal fun parseRow(row: String, virtualRoot: String): RootfsDirectoryEntry? {
        val parts = row.split('\t')
        if (parts.size < 4) return null
        val name = parts.subList(0, parts.size - 3).joinToString("\t")
        if (name.isEmpty()) return null
        val type = parts[parts.size - 3]
        val size = parts[parts.size - 2].toLongOrNull() ?: 0L
        val modified = parts[parts.size - 1].toLongOrNull() ?: 0L
        return RootfsDirectoryEntry(
            name = name,
            path = if (virtualRoot == "/") "/" + name else virtualRoot + "/" + name,
            isDirectory = type == "d",
            isSymbolicLink = type == "l",
            sizeBytes = size,
            modifiedEpochMs = modified
        )
    }
}
