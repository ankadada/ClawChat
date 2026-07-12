package com.anka.clawbot

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files
import java.security.MessageDigest

class VerifiedApkUpdateTest {
    @Test
    fun validFileAndIntentPlanAreAccepted() {
        val cache = Files.createTempDirectory("apk-update-test")
        val root = Files.createDirectories(cache.resolve("updates"))
        val apk = Files.write(root.resolve("verified-androidApp-2-object.apk"), byteArrayOf(1, 2, 3))
        val digest = sha256(byteArrayOf(1, 2, 3))

        val verified = VerifiedApkUpdate.verify(apk.toString(), root.toFile(), 3, digest)
        assertEquals(apk.toRealPath().toFile(), verified)
        val plan = VerifiedApkUpdate.intentPlan("com.anka.clawbot")
        assertEquals("com.anka.clawbot.updates", plan.authority)
        assertEquals("application/vnd.android.package-archive", plan.mimeType)
        assertTrue(plan.grantReadPermission)
    }

    @Test
    fun containmentTypeSizeAndDigestAreRejected() {
        val cache = Files.createTempDirectory("apk-update-reject")
        val root = Files.createDirectories(cache.resolve("updates"))
        val outside = Files.write(cache.resolve("outside.apk"), byteArrayOf(1, 2, 3))
        val directory = Files.createDirectories(root.resolve("directory.apk"))
        val apk = Files.write(root.resolve("verified-androidApp-2-object.apk"), byteArrayOf(1, 2, 3))
        val digest = sha256(byteArrayOf(1, 2, 3))

        assertFails { VerifiedApkUpdate.verify(outside.toString(), root.toFile(), 3, digest) }
        assertFails { VerifiedApkUpdate.verify(directory.toString(), root.toFile(), 3, digest) }
        assertFails { VerifiedApkUpdate.verify(apk.toString(), root.toFile(), 4, digest) }
        assertFails { VerifiedApkUpdate.verify(apk.toString(), root.toFile(), 3, "0".repeat(64)) }
    }

    @Test
    fun symlinkAndProviderScopeEscapeAreRejected() {
        val cache = Files.createTempDirectory("apk-update-link")
        val root = Files.createDirectories(cache.resolve("updates"))
        val target = Files.write(root.resolve("target.apk"), byteArrayOf(1))
        val link = root.resolve("verified-androidApp-2-link.apk")
        try {
            Files.createSymbolicLink(link, target)
            assertFails {
                VerifiedApkUpdate.verify(link.toString(), root.toFile(), 1, sha256(byteArrayOf(1)))
            }
        } catch (_: UnsupportedOperationException) {
            // The remaining containment assertions are still executable.
        }
        assertFails {
            VerifiedApkUpdate.verify(
                root.resolve("../escape.apk").toString(),
                root.toFile(),
                1,
                sha256(byteArrayOf(1))
            )
        }
    }

    private fun sha256(bytes: ByteArray): String = MessageDigest
        .getInstance("SHA-256")
        .digest(bytes)
        .joinToString("") { "%02x".format(it.toInt() and 0xff) }

    private fun assertFails(block: () -> Unit) {
        try {
            block()
            throw AssertionError("expected verification failure")
        } catch (_: IllegalArgumentException) {
            // Expected fail-closed result.
        }
    }
}
