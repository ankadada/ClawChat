package com.anka.clawbot

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class RootfsBytesReadTest {
    private val rootfsDir = "/data/user/0/com.anka.clawbot/files/rootfs/alpine"

    private class RecordedCall(
        val rootPath: String,
        val relativePath: String,
        val operationId: String,
        val maxBytes: Long
    )

    @Test
    fun deepestGrantedRootWins() {
        val location = resolveRootfsReadLocation(
            rootfsDir = rootfsDir,
            path = "/root/workspace/images/plot.png",
            allowedRoots = listOf("/", "/root/workspace"),
        )

        assertEquals("$rootfsDir/root/workspace", location.rootHostPath)
        assertEquals("images/plot.png", location.relativePath)
    }

    @Test
    fun aPlatformSymlinkAboveTheRootfsIsCanonicalized() {
        // Some devices expose the app files dir through a platform symlink
        // (e.g. /data/user/0 ...). The JNI broker compares the root with its
        // own realpath, so the base must arrive canonical, otherwise every
        // preview read fails closed on that device.
        val temp = java.nio.file.Files.createTempDirectory("rootfs-read-")
        try {
            val real = java.nio.file.Files.createDirectories(
                temp.resolve("real/rootfs/alpine")
            )
            val link = temp.resolve("link")
            java.nio.file.Files.createSymbolicLink(
                link,
                temp.resolve("real")
            )

            val location = resolveRootfsReadLocation(
                rootfsDir = "$link/rootfs/alpine",
                path = "/root/workspace/shared/note.md",
                allowedRoots = listOf("/root/workspace"),
            )

            assertEquals(
                real.toFile().canonicalPath + "/root/workspace",
                location.rootHostPath
            )
            assertEquals("shared/note.md", location.relativePath)
        } finally {
            temp.toFile().deleteRecursively()
        }
    }

    @Test
    fun aSymlinkInsideTheGrantedScopeStaysLexical() {
        // The guard the JNI broker applies is on the granted part: a guest
        // planted symlink there must not be followed, so the scope stays
        // exactly as resolved instead of being canonicalized away.
        val temp = java.nio.file.Files.createTempDirectory("rootfs-scope-")
        try {
            val base = java.nio.file.Files.createDirectories(
                temp.resolve("rootfs/alpine/root")
            )
            val elsewhere = java.nio.file.Files.createDirectories(
                temp.resolve("elsewhere")
            )
            java.nio.file.Files.createSymbolicLink(
                base.resolve("workspace"),
                elsewhere
            )

            val location = resolveRootfsReadLocation(
                rootfsDir = temp.resolve("rootfs/alpine").toString(),
                path = "/root/workspace/shared/note.md",
                allowedRoots = listOf("/root/workspace"),
            )

            assertEquals(
                temp.resolve("rootfs/alpine").toFile().canonicalPath +
                    "/root/workspace",
                location.rootHostPath
            )
            assertEquals("shared/note.md", location.relativePath)
        } finally {
            temp.toFile().deleteRecursively()
        }
    }

    @Test
    fun aReaderRejectionIsClassifiedForTheDeviceLog() {
        val reasons = mutableListOf<String>()
        val result = readScopedRootfsBytes(
            rootfsDir = rootfsDir,
            path = "/root/workspace/shared/note.md",
            allowedRoots = listOf("/root/workspace"),
            maxBytes = 64L * 1024L,
            operationId = newRootfsReadOperationId(),
            reader = { _, _, _, _ ->
                throw SecurityException(
                    "bounded read rejected: relative file missing"
                )
            },
            onRejected = { reasons.add(it) },
        )

        // Fail closed exactly as before, but with a classification that a
        // device logcat can show.
        assertNull(result)
        assertEquals(
            listOf("bounded read rejected: relative file missing"),
            reasons
        )
    }

    @Test
    fun aMissingBrokerIsClassifiedWithoutCrashing() {
        val reasons = mutableListOf<String>()
        val result = readScopedRootfsBytes(
            rootfsDir = rootfsDir,
            path = "/root/workspace/shared/note.md",
            allowedRoots = listOf("/root/workspace"),
            maxBytes = 64L * 1024L,
            operationId = newRootfsReadOperationId(),
            reader = { _, _, _, _ -> throw UnsatisfiedLinkError("no jni") },
            onRejected = { reasons.add(it) },
        )

        assertNull(result)
        assertEquals(listOf("native broker unavailable"), reasons)
    }

    @Test
    fun aSingleGrantedRootIsUsedDirectly() {
        val location = resolveRootfsReadLocation(
            rootfsDir = rootfsDir,
            path = "/root/workspace/a.png",
            allowedRoots = listOf("/root/workspace"),
        )

        assertEquals("$rootfsDir/root/workspace", location.rootHostPath)
        assertEquals("a.png", location.relativePath)
    }

    @Test
    fun scopeViolationsAndTraversalFailClosed() {
        assertThrows(SecurityException::class.java) {
            resolveRootfsReadLocation(rootfsDir, "/etc/passwd", listOf("/root/workspace"))
        }
        assertThrows(SecurityException::class.java) {
            resolveRootfsReadLocation(rootfsDir, "/root/workspace/../etc/passwd", listOf("/"))
        }
        assertThrows(SecurityException::class.java) {
            resolveRootfsReadLocation(rootfsDir, "/root/workspace", listOf("/root/workspace"))
        }
        assertThrows(SecurityException::class.java) {
            resolveRootfsReadLocation(rootfsDir, "/root/workspace/a\\b", listOf("/"))
        }
        assertThrows(SecurityException::class.java) {
            resolveRootfsReadLocation(rootfsDir, "/root/workspace/a", emptyList())
        }
    }

    @Test
    fun rootGrantKeepsEveryPathBelowIt() {
        val location = resolveRootfsReadLocation(
            rootfsDir = "$rootfsDir/",
            path = "/usr/share/thing.bin",
            allowedRoots = listOf("/"),
        )

        assertEquals(rootfsDir, location.rootHostPath)
        assertEquals("usr/share/thing.bin", location.relativePath)
    }

    @Test
    fun readerReceivesTheResolvedRootAndCappedBudget() {
        var call: RecordedCall? = null
        val reader = RootfsBytesReader { rootPath, relativePath, operationId, maxBytes ->
            call = RecordedCall(rootPath, relativePath, operationId, maxBytes)
            byteArrayOf(1, 2, 3)
        }

        val bytes = readScopedRootfsBytes(
            rootfsDir = rootfsDir,
            path = "/root/workspace/images/plot.png",
            allowedRoots = listOf("/root/workspace"),
            maxBytes = MAX_ROOTFS_BYTES_READ * 4,
            operationId = "a".repeat(32),
            reader = reader,
        )

        assertArrayEquals(byteArrayOf(1, 2, 3), bytes)
        val recorded = requireNotNull(call)
        assertEquals("$rootfsDir/root/workspace", recorded.rootPath)
        assertEquals("images/plot.png", recorded.relativePath)
        assertEquals("a".repeat(32), recorded.operationId)
        assertEquals(MAX_ROOTFS_BYTES_READ, recorded.maxBytes)
    }

    @Test
    fun aNonPositiveBudgetNeverReachesTheReader() {
        var called = false
        val reader = RootfsBytesReader { _, _, _, _ ->
            called = true
            byteArrayOf(1)
        }

        assertNull(
            readScopedRootfsBytes(rootfsDir, "/root/workspace/a.png", listOf("/"), 0L, "a".repeat(32), reader)
        )
        assertFalse(called)
    }

    @Test
    fun aReaderRejectionBecomesNull() {
        val rejecting = RootfsBytesReader { _, _, _, _ ->
            throw SecurityException("bounded read failed")
        }

        assertNull(
            readScopedRootfsBytes(
                rootfsDir,
                "/root/workspace/a.png",
                listOf("/"),
                MAX_ROOTFS_BYTES_READ,
                "a".repeat(32),
                rejecting,
            )
        )
    }

    @Test
    fun aMissingBrokerBecomesNullInsteadOfCrashing() {
        val missingBroker = RootfsBytesReader { _, _, _, _ ->
            throw UnsatisfiedLinkError("secure_import")
        }

        assertNull(
            readScopedRootfsBytes(
                rootfsDir,
                "/root/workspace/a.png",
                listOf("/"),
                MAX_ROOTFS_BYTES_READ,
                "a".repeat(32),
                missingBroker,
            )
        )
    }

    @Test
    fun aScopeViolationIsNotSwallowedByTheReader() {
        var called = false
        val reader = RootfsBytesReader { _, _, _, _ ->
            called = true
            byteArrayOf(1)
        }

        assertThrows(SecurityException::class.java) {
            readScopedRootfsBytes(
                rootfsDir,
                "/etc/passwd",
                listOf("/root/workspace"),
                MAX_ROOTFS_BYTES_READ,
                "a".repeat(32),
                reader,
            )
        }
        assertFalse(called)
    }

    @Test
    fun operationIdsAre32LowercaseHexCharacters() {
        repeat(8) {
            val id = newRootfsReadOperationId()
            assertTrue(id.matches(Regex("^[a-f0-9]{32}$")))
        }
    }
}
