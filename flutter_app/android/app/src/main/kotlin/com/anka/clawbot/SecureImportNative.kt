package com.anka.clawbot

/** JNI-only security broker. Absence of the native library fails imports closed. */
object SecureImportNative {
    init {
        System.loadLibrary("secure_import")
    }

    external fun importHostFile(
        sourcePath: String,
        uploadsPath: String,
        finalName: String,
        operationId: String,
        maxBytes: Long
    ): Array<String>

    external fun readFileBounded(
        rootPath: String,
        relativePath: String,
        operationId: String,
        maxBytes: Long
    ): ByteArray?

    /**
     * Descriptor-relative bounded byte read for a scoped rootfs path.
     *
     * Each component is opened with `O_NOFOLLOW` relative to its verified
     * parent, the final file is opened with `O_NOFOLLOW | O_NONBLOCK`, and
     * `fstat` on the opened descriptor must report a regular file with one
     * link. The identity is re-checked after the read. Returns null for a
     * missing file; every rejection is a SecurityException.
     */
    external fun readRootfsBytesBounded(
        rootPath: String,
        relativePath: String,
        operationId: String,
        maxBytes: Long
    ): ByteArray?

    /**
     * Lists one directory descriptor-relative: every component is opened with
     * O_NOFOLLOW below [rootPath], the opened directory's identity is verified,
     * and children are read with fstatat(AT_SYMLINK_NOFOLLOW) so a link is
     * reported as a link instead of being followed.
     *
     * Returns one row per entry, "name\ttype\tsize\tmtime", or null when the
     * scope root or a component is missing, symlinked or not a directory.
     */
    external fun listRootfsDirectoryBounded(
        rootPath: String,
        relativePath: String,
        maxEntries: Int
    ): Array<String>?

    /**
     * Unlinks one plain file through its parent directory descriptor. A
     * symlinked or non-regular node is refused; a file that is already gone
     * counts as success.
     */
    external fun deleteRootfsFileBounded(
        rootPath: String,
        relativePath: String
    ): Boolean

    /**
     * Writes one file through its parent directory descriptor, with
     * O_CREAT | O_EXCL | O_NOFOLLOW when [createNew] is set. Returns false when
     * the name already exists (never overwriting a share) or the path is unsafe.
     */
    external fun writeRootfsFileBounded(
        rootPath: String,
        relativePath: String,
        body: String,
        createNew: Boolean
    ): Boolean

    /**
     * Creates a directory path (all missing levels) below [rootPath],
     * descriptor-relative: every level is created with mkdirat and re-opened
     * with O_DIRECTORY | O_NOFOLLOW, and the opened directory's identity is
     * verified, so a linked or swapped component fails closed. Returns false
     * when the path is unsafe or a component is not a real directory.
     */
    external fun createRootfsDirectoryBounded(
        rootPath: String,
        relativePath: String
    ): Boolean

    external fun cancelOperation(operationId: String)
    external fun finishOperation(operationId: String)
    external fun acknowledgeImport(
        uploadsPath: String,
        finalName: String,
        operationId: String,
        expectedSize: Long,
        expectedSha256: String
    )
    external fun discardImport(
        uploadsPath: String,
        finalName: String,
        operationId: String,
        expectedSize: Long,
        expectedSha256: String
    )
    external fun reconcileImports(uploadsPath: String)
    external fun listPendingImports(uploadsPath: String, maxEntries: Int): Array<String>

    /**
     * Creates one MCP launch-script directory below [homeDir] and writes the
     * script into it, entirely descriptor-relative: every component is opened
     * with O_NOFOLLOW and verified against its directory identity, and the
     * script itself is created with CREATE_NEW + NOFOLLOW.
     *
     * The app home is bind-mounted writable into the guest, so those parents are
     * attacker-reachable; a symlinked or swapped component makes this return
     * null (fail closed) instead of writing through the link.
     *
     * Returns {hostPath, identity} where identity is the "device:inode" of the
     * start directory this call created, which the cleanup paths require before
     * they delete anything.
     */
    external fun createMcpLaunchScript(
        homeDir: String,
        runSegment: String,
        serverSegment: String,
        startName: String,
        scriptBody: String
    ): Array<String>?

    /**
     * Removes one launch-script directory without following a symlink and only
     * when the directory still is the one [expectedIdentity] describes. Returns
     * true when it is gone (deleted or already absent).
     */
    external fun deleteMcpLaunchDirectory(
        homeDir: String,
        runSegment: String,
        serverSegment: String,
        startName: String,
        expectedIdentity: String
    ): Boolean

    /**
     * Removes launch-script directories that no live child owns. Live starts are
     * matched by identity, symlinked levels are unlinked rather than followed,
     * and directories inside the caller's grace window are left alone.
     *
     * Returns the number of removed entries, or -1 when the tree was not usable.
     */
    external fun sweepMcpLaunchDirectories(
        homeDir: String,
        maxAgeMs: Long,
        liveIdentities: Array<String>
    ): Int
}
