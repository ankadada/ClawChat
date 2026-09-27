package com.anka.clawbot

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The file browser's *policy*: virtual-path normalization, granted-scope
 * containment and row parsing. The filesystem walk itself is descriptor-relative
 * in the native broker, so its behaviour is executed by the host harness
 * (rootfs_browser_io_host_test.cpp) instead of being re-implemented here.
 */
class RootfsDirectoryListerTest {
    private val rootfs = "/data/user/0/com.anka.clawbot/files/rootfs/alpine"

    @Test
    fun resolvesTheDeepestGrantedScopeAndKeepsTheRelativePath() {
        val workspace = RootfsDirectoryLister.resolveScopedDirectory(
            rootfs,
            "/root/workspace/docs/sub",
            listOf("/root/workspace")
        )
        assertEquals(rootfs + "/root/workspace", workspace.rootHostPath)
        assertEquals("docs/sub", workspace.relativePath)

        // A deeper grant wins over a wider one.
        val nested = RootfsDirectoryLister.resolveScopedDirectory(
            rootfs,
            "/root/workspace/docs/sub",
            listOf("/root/workspace", "/root/workspace/docs")
        )
        assertEquals(rootfs + "/root/workspace/docs", nested.rootHostPath)
        assertEquals("sub", nested.relativePath)

        // Listing the scope root itself is allowed: the relative path is empty.
        val scopeRoot = RootfsDirectoryLister.resolveScopedDirectory(
            rootfs,
            "/root/workspace",
            listOf("/root/workspace")
        )
        assertEquals(rootfs + "/root/workspace", scopeRoot.rootHostPath)
        assertEquals("", scopeRoot.relativePath)
    }

    @Test
    fun refusesPathsOutsideTheGrantedScope() {
        assertThrows(SecurityException::class.java) {
            RootfsDirectoryLister.resolveScopedDirectory(
                rootfs,
                "/etc",
                listOf("/root/workspace")
            )
        }
        assertThrows(SecurityException::class.java) {
            RootfsDirectoryLister.resolveScopedDirectory(
                rootfs,
                "/root/workspace",
                listOf("/root/workspace/docs")
            )
        }
        assertThrows(SecurityException::class.java) {
            RootfsDirectoryLister.resolveScopedDirectory(rootfs, "/root/workspace", emptyList())
        }
        assertThrows(SecurityException::class.java) {
            RootfsDirectoryLister.resolveScopedDirectory(
                rootfs,
                "/root/workspace/../etc",
                listOf("/root/workspace")
            )
        }
        assertThrows(SecurityException::class.java) {
            RootfsDirectoryLister.resolveScopedDirectory(
                rootfs,
                "/root/workspace/..\u0000/etc",
                listOf("/root/workspace")
            )
        }
        assertThrows(SecurityException::class.java) {
            RootfsDirectoryLister.resolveScopedDirectory(
                rootfs,
                "/root/workspace/..\\etc",
                listOf("/root/workspace")
            )
        }
    }

    @Test
    fun listingFailsClosedWhenTheNativeBrokerIsUnavailable() {
        // No JNI in a plain JVM test: the lister must refuse rather than fall
        // back to a pathname walk.
        assertThrows(SecurityException::class.java) {
            RootfsDirectoryLister.list(
                rootfs,
                "/root/workspace",
                listOf("/root/workspace")
            )
        }
    }

    @Test
    fun parsesBrokerRowsIncludingTabsAndLinks() {
        val directory = RootfsDirectoryLister.parseRow(
            "sub\td\t0\t1700000000000",
            "/root/workspace"
        )
        assertEquals("sub", directory!!.name)
        assertTrue(directory.isDirectory)
        assertEquals("/root/workspace/sub", directory.path)
        assertEquals(1700000000000L, directory.modifiedEpochMs)

        val link = RootfsDirectoryLister.parseRow(
            "linked\tl\t12\t0",
            "/root/workspace"
        )
        assertTrue(link!!.isSymbolicLink)
        // A link is never a directory the browser may descend into.
        assertEquals(false, link.isDirectory)

        val file = RootfsDirectoryLister.parseRow("a\tb.txt\tf\t5\t3", "/root/workspace")
        assertEquals("a\tb.txt", file!!.name)
        assertEquals(5L, file.sizeBytes)

        assertNull(RootfsDirectoryLister.parseRow("broken", "/root/workspace"))
        assertNull(RootfsDirectoryLister.parseRow("\td\t0\t0", "/root/workspace"))
    }
}
