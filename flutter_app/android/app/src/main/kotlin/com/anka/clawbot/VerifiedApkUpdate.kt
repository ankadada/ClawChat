package com.anka.clawbot

import java.io.File
import java.nio.file.Files
import java.security.MessageDigest

internal object VerifiedApkUpdate {
    const val APK_MIME = "application/vnd.android.package-archive"

    data class IntentPlan(
        val authority: String,
        val mimeType: String,
        val grantReadPermission: Boolean
    )

    fun verify(
        path: String,
        updateRoot: File,
        expectedSize: Long,
        expectedSha256: String
    ): File {
        require(expectedSize > 0L) { "invalid APK size" }
        require(expectedSha256.matches(Regex("^[a-f0-9]{64}$"))) {
            "invalid APK digest"
        }
        val root = updateRoot.canonicalFile.toPath()
        val requestedFile = File(path).absoluteFile
        val requested = requestedFile.parentFile.canonicalFile
            .toPath()
            .resolve(requestedFile.name)
            .normalize()
        require(requested.startsWith(root)) { "APK is outside update staging" }
        require(!Files.isSymbolicLink(requested)) { "APK may not be a symlink" }
        require(Files.isRegularFile(requested)) { "APK must be a regular file" }
        val resolved = requested.toRealPath()
        require(resolved.startsWith(root)) { "APK resolves outside update staging" }
        require(Files.size(resolved) == expectedSize) { "APK size mismatch" }
        val digest = MessageDigest.getInstance("SHA-256")
        Files.newInputStream(resolved).use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        val actual = digest.digest().joinToString("") {
            "%02x".format(it.toInt() and 0xff)
        }
        require(actual == expectedSha256) { "APK digest mismatch" }
        return resolved.toFile()
    }

    fun intentPlan(packageName: String): IntentPlan {
        require(packageName.matches(Regex("^[A-Za-z0-9_.]+$"))) {
            "invalid package name"
        }
        return IntentPlan(
            authority = "$packageName.updates",
            mimeType = APK_MIME,
            grantReadPermission = true
        )
    }
}
