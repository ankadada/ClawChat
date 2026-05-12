package com.anka.clawbot

import android.content.Context
import android.util.Log
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.os.Build
import android.system.Os
import java.io.BufferedInputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.zip.GZIPInputStream
import org.apache.commons.compress.archivers.tar.TarArchiveEntry
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream

class BootstrapManager(
    private val context: Context,
    private val filesDir: String,
    private val nativeLibDir: String
) {
    private val rootfsDir = "$filesDir/rootfs/alpine"
    private val tmpDir = "$filesDir/tmp"
    private val homeDir = "$filesDir/home"
    private val configDir = "$filesDir/config"
    private val libDir = "$filesDir/lib"

    fun setupDirectories() {
        listOf(rootfsDir, tmpDir, homeDir, configDir, "$homeDir/.clawchat", libDir).forEach {
            File(it).mkdirs()
        }
        // Termux's proot links against libtalloc.so.2 but Android extracts it
        // as libtalloc.so (jniLibs naming convention). Create a copy with the
        // correct SONAME so the dynamic linker finds it.
        setupLibtalloc()
        // Create fake /proc and /sys files for proot bind mounts
        setupFakeSysdata()
    }

    private fun setupLibtalloc() {
        val source = File("$nativeLibDir/libtalloc.so")
        val target = File("$libDir/libtalloc.so.2")
        if (source.exists() && !target.exists()) {
            source.copyTo(target)
            target.setExecutable(true)
        }
    }

    fun isBootstrapComplete(): Boolean {
        val rootfs = File(rootfsDir)
        val busybox = File("$rootfsDir/bin/busybox")
        val binSh = java.nio.file.Paths.get("$rootfsDir/bin/sh")
        val apkDb = File("$rootfsDir/lib/apk/db/installed")
        // Alpine symlinks (/bin/sh -> /bin/busybox) use absolute paths that
        // resolve correctly inside proot but are dangling on the host.
        // File.exists() follows symlinks and returns false for them.
        // Use Files.isSymbolicLink() to check the symlink itself exists,
        // or check the real busybox binary directly.
        return rootfs.exists()
            && (busybox.exists() || java.nio.file.Files.isSymbolicLink(binSh))
            && apkDb.exists()
    }

    fun getBootstrapStatus(): Map<String, Any> {
        val rootfsExists = File(rootfsDir).exists()
        val busyboxExists = File("$rootfsDir/bin/busybox").exists()
        // Alpine symlinks use absolute paths (e.g. /bin/sh -> /bin/busybox)
        // that are dangling on the host. Use Files.isSymbolicLink() to detect
        // the symlink itself without following it.
        val binShExists = busyboxExists
            || java.nio.file.Files.isSymbolicLink(java.nio.file.Paths.get("$rootfsDir/bin/sh"))
        val binBashExists = java.nio.file.Files.isSymbolicLink(
            java.nio.file.Paths.get("$rootfsDir/bin/bash"))
        val apkDbExists = File("$rootfsDir/lib/apk/db/installed").exists()
        val pythonExists = File("$rootfsDir/usr/bin/python3").exists()
            || java.nio.file.Files.isSymbolicLink(java.nio.file.Paths.get("$rootfsDir/usr/bin/python3"))
        val curlExists = File("$rootfsDir/usr/bin/curl").exists()
            || java.nio.file.Files.isSymbolicLink(java.nio.file.Paths.get("$rootfsDir/usr/bin/curl"))
        return mapOf(
            "rootfsExists" to rootfsExists,
            "binShExists" to binShExists,
            "binBashExists" to binBashExists,
            "pythonInstalled" to pythonExists,
            "curlInstalled" to curlExists,
            "rootfsPath" to rootfsDir,
            "complete" to (rootfsExists && (binShExists || binBashExists) && apkDbExists)
        )
    }

    fun extractRootfs(tarPath: String) {
        val rootfs = File(rootfsDir)
        // Clean up any previous failed extraction
        if (rootfs.exists()) {
            deleteRecursively(rootfs)
        }
        rootfs.mkdirs()

        // Pure Java extraction using Apache Commons Compress.
        // Two-phase approach:
        //   Phase 1: Extract directories, regular files, and hard links (as copies).
        //   Phase 2: Create all symlinks (deferred so directory structure exists first).
        // This handles tarball entry ordering issues (e.g., bin/bash before bin→usr/bin).
        val deferredSymlinks = mutableListOf<Pair<String, String>>() // target, path
        var entryCount = 0
        var fileCount = 0
        var symlinkCount = 0
        var extractionError: Exception? = null

        try {
            FileInputStream(tarPath).use { fis ->
                BufferedInputStream(fis, 256 * 1024).use { bis ->
                    GZIPInputStream(bis).use { gis ->
                        TarArchiveInputStream(gis).use { tis ->
                            var entry: TarArchiveEntry? = tis.nextEntry
                            while (entry != null) {
                                entryCount++
                                val name = entry.name
                                    .removePrefix("./")
                                    .removePrefix("/")

                                if (name.isEmpty() || name.startsWith("dev/") || name == "dev") {
                                    entry = tis.nextEntry
                                    continue
                                }

                                val outFile = File(rootfsDir, name)

                                when {
                                    entry.isDirectory -> {
                                        outFile.mkdirs()
                                    }
                                    entry.isSymbolicLink -> {
                                        // Defer symlinks to phase 2
                                        deferredSymlinks.add(
                                            Pair(entry.linkName, outFile.absolutePath)
                                        )
                                        symlinkCount++
                                    }
                                    entry.isLink -> {
                                        // Hard link → copy the target file
                                        val target = entry.linkName
                                            .removePrefix("./")
                                            .removePrefix("/")
                                        val targetFile = File(rootfsDir, target)
                                        outFile.parentFile?.mkdirs()
                                        try {
                                            if (targetFile.exists()) {
                                                targetFile.copyTo(outFile, overwrite = true)
                                                if (targetFile.canExecute()) {
                                                    outFile.setExecutable(true, false)
                                                }
                                                fileCount++
                                            }
                                        } catch (e: Exception) {
                                            Log.w("BootstrapManager", "Failed to extract hardlink: ${entry.name} -> $target", e)
                                        }
                                    }
                                    else -> {
                                        // Regular file
                                        outFile.parentFile?.mkdirs()
                                        FileOutputStream(outFile).use { fos ->
                                            val buf = ByteArray(65536)
                                            var len: Int
                                            while (tis.read(buf).also { len = it } != -1) {
                                                fos.write(buf, 0, len)
                                            }
                                        }
                                        outFile.setReadable(true, false)
                                        outFile.setWritable(true, false)
                                        val mode = entry.mode
                                        if (mode == 0 || mode and 0b001_001_001 != 0) {
                                            val path = name.lowercase()
                                            if (mode and 0b001_001_001 != 0 ||
                                                path.contains("/bin/") ||
                                                path.contains("/sbin/") ||
                                                path.endsWith(".sh") ||
                                                path.contains("/lib/apt/methods/")) {
                                                outFile.setExecutable(true, false)
                                            }
                                        }
                                        fileCount++
                                    }
                                }

                                entry = tis.nextEntry
                            }
                        }
                    }
                }
            }
        } catch (e: Exception) {
            extractionError = e
        }

        if (entryCount == 0) {
            throw RuntimeException(
                "Extraction failed: tarball appears empty or corrupt. " +
                "Error: ${extractionError?.message ?: "none"}"
            )
        }

        if (extractionError != null && fileCount < 100) {
            throw RuntimeException(
                "Extraction failed after $entryCount entries ($fileCount files): " +
                "${extractionError!!.message}"
            )
        }

        // Phase 2: Create all symlinks now that the directory structure exists.
        var symlinkErrors = 0
        var lastSymlinkError = ""
        for ((target, path) in deferredSymlinks) {
            try {
                val file = File(path)
                if (file.exists()) {
                    if (file.isDirectory) {
                        val linkTarget = if (target.startsWith("/")) {
                            target.removePrefix("/")
                        } else {
                            val parent = file.parentFile?.absolutePath ?: rootfsDir
                            File(parent, target).relativeTo(File(rootfsDir)).path
                        }
                        val realTargetDir = File(rootfsDir, linkTarget)
                        if (realTargetDir.exists() && realTargetDir.isDirectory) {
                            file.listFiles()?.forEach { child ->
                                val dest = File(realTargetDir, child.name)
                                if (!dest.exists()) {
                                    child.renameTo(dest)
                                }
                            }
                        }
                        deleteRecursively(file)
                    } else {
                        file.delete()
                    }
                }
                file.parentFile?.mkdirs()
                Os.symlink(target, path)
            } catch (e: Exception) {
                symlinkErrors++
                lastSymlinkError = "$path -> $target: ${e.message}"
            }
        }

        // Verify extraction — check for the real busybox binary (the only
        // non-symlink executable in Alpine minirootfs) AND/OR the /bin/sh
        // symlink. The symlinks use absolute paths (e.g. /bin/sh -> /bin/busybox)
        // that resolve correctly inside proot but are dangling on the host.
        // File.exists() follows symlinks and returns false, so we use
        // Files.isSymbolicLink() to check the symlink node itself.
        val busyboxFile = File("$rootfsDir/bin/busybox")
        val binShLink = java.nio.file.Paths.get("$rootfsDir/bin/sh")
        if (!busyboxFile.exists() && !java.nio.file.Files.isSymbolicLink(binShLink)) {
            throw RuntimeException(
                "Extraction failed: neither busybox binary nor sh symlink found in rootfs. " +
                "Processed $entryCount entries, $fileCount files, " +
                "$symlinkCount symlinks (${symlinkErrors} symlink errors). " +
                "Last symlink error: $lastSymlinkError. " +
                "bin exists: ${File("$rootfsDir/bin").exists()}. " +
                "Extraction error: ${extractionError?.message ?: "none"}"
            )
        }

        // Post-extraction: configure rootfs for proot compatibility
        configureRootfs()

        // Clean up tarball
        File(tarPath).delete()
    }

    /**
     * Write configuration files that make the rootfs work correctly under proot.
     * Called automatically after extraction.
     */
    private fun configureRootfs() {
        // 1. 配置 Alpine apk 镜像源
        val apkReposDir = File("$rootfsDir/etc/apk")
        apkReposDir.mkdirs()
        File(apkReposDir, "repositories").writeText(
            "https://dl-cdn.alpinelinux.org/alpine/v3.21/main\n" +
            "https://dl-cdn.alpinelinux.org/alpine/v3.21/community\n"
        )

        // 2. 确保必要目录存在
        listOf(
            "$rootfsDir/etc/ssl/certs",
            "$rootfsDir/tmp",
            "$rootfsDir/var/tmp",
            "$rootfsDir/root",
            "$rootfsDir/root/workspace",
            "$rootfsDir/root/.clawchat",
            "$rootfsDir/run",
            "$rootfsDir/dev/shm",
        ).forEach { File(it).mkdirs() }

        // 3. /etc/hosts
        val hosts = File("$rootfsDir/etc/hosts")
        if (!hosts.exists() || !hosts.readText().contains("localhost")) {
            hosts.writeText(
                "127.0.0.1   localhost.localdomain localhost\n" +
                "::1         localhost.localdomain localhost\n"
            )
        }

        // 4. /tmp 权限
        val tmpDir = File("$rootfsDir/tmp")
        tmpDir.mkdirs()
        tmpDir.setReadable(true, false)
        tmpDir.setWritable(true, false)
        tmpDir.setExecutable(true, false)

        // 5. 修复 bin 目录权限
        fixBinPermissions()

        // 6. 注册 Android 用户/组
        registerAndroidUsers()
    }

    /**
     * Ensure all files in executable directories have the execute bit set.
     * Java's File API doesn't support full Unix permissions, so tar extraction
     * may leave some binaries without +x, causing "Could not exec dpkg" (error 100).
     */
    private fun fixBinPermissions() {
        val recursiveExecDirs = listOf(
            "$rootfsDir/usr/bin",
            "$rootfsDir/usr/sbin",
            "$rootfsDir/usr/local/bin",
            "$rootfsDir/usr/local/sbin",
            "$rootfsDir/usr/libexec",
            "$rootfsDir/bin",
            "$rootfsDir/sbin",
        )
        for (dirPath in recursiveExecDirs) {
            val dir = File(dirPath)
            if (dir.exists() && dir.isDirectory) {
                fixExecRecursive(dir)
            }
        }
        // Also fix shared libraries (dpkg, apt, etc. link against them)
        val libDirs = listOf(
            "$rootfsDir/usr/lib",
            "$rootfsDir/lib",
        )
        for (dirPath in libDirs) {
            val dir = File(dirPath)
            if (dir.exists() && dir.isDirectory) {
                fixSharedLibsRecursive(dir)
            }
        }
    }

    /** Recursively set +rx on all regular files in a directory tree. */
    private fun fixExecRecursive(dir: File) {
        dir.listFiles()?.forEach { file ->
            if (file.isDirectory) {
                fixExecRecursive(file)
            } else if (file.isFile) {
                file.setReadable(true, false)
                file.setExecutable(true, false)
            }
        }
    }

    private fun fixSharedLibsRecursive(dir: File) {
        dir.listFiles()?.forEach { file ->
            if (file.isDirectory) {
                fixSharedLibsRecursive(file)
            } else if (file.name.endsWith(".so") || file.name.contains(".so.")) {
                file.setReadable(true, false)
                file.setExecutable(true, false)
            }
        }
    }

    /**
     * Register Android UID/GID in the rootfs user databases,
     * matching what proot-distro does during installation.
     * This ensures dpkg/apt can resolve user/group names.
     */
    private fun registerAndroidUsers() {
        val uid = android.os.Process.myUid()
        val gid = uid // On Android, primary GID == UID

        // Ensure files are writable
        for (name in listOf("passwd", "shadow", "group", "gshadow")) {
            val f = File("$rootfsDir/etc/$name")
            if (f.exists()) f.setWritable(true, false)
        }

        // Add Android app user to /etc/passwd
        val passwd = File("$rootfsDir/etc/passwd")
        if (passwd.exists()) {
            val content = passwd.readText()
            if (!content.contains("aid_android")) {
                passwd.appendText("aid_android:x:$uid:$gid:Android:/:/sbin/nologin\n")
            }
        }

        // Add to /etc/shadow
        val shadow = File("$rootfsDir/etc/shadow")
        if (shadow.exists()) {
            val content = shadow.readText()
            if (!content.contains("aid_android")) {
                shadow.appendText("aid_android:*:18446:0:99999:7:::\n")
            }
        }

        // Add Android groups to /etc/group
        val group = File("$rootfsDir/etc/group")
        if (group.exists()) {
            val content = group.readText()
            // Add common Android groups that packages might reference
            val groups = mapOf(
                "aid_inet" to 3003,       // Internet access
                "aid_net_raw" to 3004,    // Raw sockets
                "aid_sdcard_rw" to 1015,  // SD card write
                "aid_android" to gid,     // App's own group
            )
            for ((name, id) in groups) {
                if (!content.contains(name)) {
                    group.appendText("$name:x:$id:root,aid_android\n")
                }
            }
        }

        // Add to /etc/gshadow
        val gshadow = File("$rootfsDir/etc/gshadow")
        if (gshadow.exists()) {
            val content = gshadow.readText()
            val groups = listOf("aid_inet", "aid_net_raw", "aid_sdcard_rw", "aid_android")
            for (name in groups) {
                if (!content.contains(name)) {
                    gshadow.appendText("$name:*::root,aid_android\n")
                }
            }
        }
    }

    private fun deleteRecursively(file: File) {
        // CRITICAL: Do NOT follow symlinks — the rootfs contains symlinks
        // to /storage/emulated/0 (sdcard). Following them would delete the
        // user's photos, downloads, and other real files.

        // Path boundary check: refuse to delete anything outside filesDir.
        // This is a secondary safeguard against accidental data loss (#67, #63).
        // Use absolutePath (not canonicalPath) so symlinks are NOT resolved,
        // preventing symlink-based traversal. Symlinks are handled separately below.
        try {
            val normalizedBase = File(filesDir).absolutePath.let {
                if (it.endsWith(File.separator)) it else it + File.separator
            }
            if (!file.absolutePath.startsWith(normalizedBase)) {
                return
            }
        } catch (_: Exception) {
            return // If we can't resolve the path, don't risk deleting
        }

        try {
            val path = file.toPath()
            if (java.nio.file.Files.isSymbolicLink(path)) {
                file.delete()
                return
            }
        } catch (_: Exception) {}
        if (file.isDirectory) {
            file.listFiles()?.forEach { deleteRecursively(it) }
        }
        file.delete()
    }

    /**
     * Read DNS servers from Android's active network. Falls back to
     * Google DNS (8.8.8.8, 8.8.4.4) if system DNS is unavailable (#60).
     */
    private fun getSystemDnsServers(): String {
        try {
            val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            if (cm != null) {
                val network = cm.activeNetwork
                if (network != null) {
                    val linkProps: LinkProperties? = cm.getLinkProperties(network)
                    val dnsServers = linkProps?.dnsServers
                    if (dnsServers != null && dnsServers.isNotEmpty()) {
                        val lines = dnsServers.joinToString("\n") { "nameserver ${it.hostAddress}" }
                        // Always append Google DNS as fallback
                        return "$lines\nnameserver 8.8.8.8\n"
                    }
                }
            }
        } catch (_: Exception) {}
        return "nameserver 8.8.8.8\nnameserver 8.8.4.4\n"
    }

    fun writeResolvConf() {
        val content = getSystemDnsServers()
        // Try context.filesDir first (Android-guaranteed), fall back to
        // string-based configDir. Always call mkdirs() unconditionally. (#40)
        try {
            val dir = File(context.filesDir, "config")
            dir.mkdirs()
            File(dir, "resolv.conf").writeText(content)
        } catch (_: Exception) {
            // Fallback: use the string-based path
            File(configDir).mkdirs()
            File(configDir, "resolv.conf").writeText(content)
        }

        // Also write directly into rootfs /etc/resolv.conf so DNS works
        // even if the bind-mount fails or hasn't been set up yet (#40).
        try {
            val rootfsResolv = File(rootfsDir, "etc/resolv.conf")
            rootfsResolv.parentFile?.mkdirs()
            rootfsResolv.writeText(content)
        } catch (_: Exception) {}
    }

    private fun validateRootfsPath(path: String): File {
        val file = File(rootfsDir, path)
        val normalizedBase = File(rootfsDir).canonicalPath.let {
            if (it.endsWith(File.separator)) it else it + File.separator
        }
        if (!file.canonicalPath.startsWith(normalizedBase)) {
            throw SecurityException("Path traversal detected: $path")
        }
        return file
    }

    /** Read a file from inside the rootfs (e.g. /root/.openclaw/openclaw.json). */
    fun readRootfsFile(path: String): String? {
        val file = validateRootfsPath(path)
        return if (file.exists()) file.readText() else null
    }

    /** Write content to a file inside the rootfs, creating parent dirs as needed. */
    fun writeRootfsFile(path: String, content: String) {
        val file = validateRootfsPath(path)
        file.parentFile?.mkdirs()
        file.writeText(content)
    }

    /**
     * Create fake /proc and /sys files that are bind-mounted into proot.
     * Android restricts access to many /proc entries; proot-distro works
     * around this by providing static fake data. We replicate that approach.
     */
    fun setupFakeSysdata() {
        val procDir = File("$configDir/proc_fakes")
        val sysDir = File("$configDir/sys_fakes")
        procDir.mkdirs()
        sysDir.mkdirs()

        // /proc/loadavg
        File(procDir, "loadavg").writeText("0.12 0.07 0.02 2/165 765\n")

        // /proc/stat — matching proot-distro (8 CPUs)
        File(procDir, "stat").writeText(
            "cpu  1957 0 2877 93280 262 342 254 87 0 0\n" +
            "cpu0 31 0 226 12027 82 10 4 9 0 0\n" +
            "cpu1 45 0 290 11498 21 9 8 7 0 0\n" +
            "cpu2 52 0 401 11730 36 15 6 10 0 0\n" +
            "cpu3 42 0 268 11677 31 12 5 8 0 0\n" +
            "cpu4 789 0 720 11364 26 100 83 18 0 0\n" +
            "cpu5 486 0 438 11685 42 86 60 13 0 0\n" +
            "cpu6 314 0 336 11808 45 68 52 11 0 0\n" +
            "cpu7 198 0 198 11491 25 42 36 11 0 0\n" +
            "intr 63361 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n" +
            "ctxt 38014093\n" +
            "btime 1694292441\n" +
            "processes 26442\n" +
            "procs_running 1\n" +
            "procs_blocked 0\n" +
            "softirq 75663 0 5903 6 25375 10774 0 243 11685 0 21677\n"
        )

        // /proc/uptime
        File(procDir, "uptime").writeText("124.08 932.80\n")

        // /proc/version — fake kernel info matching proot-distro v4.37.0
        File(procDir, "version").writeText(
            "Linux version ${ProcessManager.FAKE_KERNEL_RELEASE} (proot@termux) " +
            "(gcc (GCC) 13.3.0, GNU ld (GNU Binutils) 2.42) " +
            "${ProcessManager.FAKE_KERNEL_VERSION}\n"
        )

        // /proc/vmstat — matching proot-distro format
        File(procDir, "vmstat").writeText(
            "nr_free_pages 1743136\n" +
            "nr_zone_inactive_anon 179281\n" +
            "nr_zone_active_anon 7183\n" +
            "nr_zone_inactive_file 22858\n" +
            "nr_zone_active_file 51328\n" +
            "nr_zone_unevictable 642\n" +
            "nr_zone_write_pending 0\n" +
            "nr_mlock 0\n" +
            "nr_slab_reclaimable 7520\n" +
            "nr_slab_unreclaimable 10776\n" +
            "pgpgin 198292\n" +
            "pgpgout 7674\n" +
            "pswpin 0\n" +
            "pswpout 0\n" +
            "pgalloc_dma 0\n" +
            "pgalloc_dma32 0\n" +
            "pgalloc_normal 44669136\n" +
            "pgfree 46674674\n" +
            "pgactivate 1085674\n" +
            "pgdeactivate 340776\n" +
            "pglazyfree 139872\n" +
            "pgfault 37291463\n" +
            "pgmajfault 6854\n" +
            "pgrefill 480634\n"
        )

        // /proc/sys/kernel/cap_last_cap
        File(procDir, "cap_last_cap").writeText("40\n")

        // /proc/sys/fs/inotify/max_user_watches
        File(procDir, "max_user_watches").writeText("4096\n")

        // /proc/sys/crypto/fips_enabled — libgcrypt reads this on startup;
        // missing/unreadable on Android causes apt HTTP method to SIGABRT
        File(procDir, "fips_enabled").writeText("0\n")

        // Empty file for /sys/fs/selinux bind
        File(sysDir, "empty").writeText("")
    }
}
