package com.anka.clawbot

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * I3 regression guard: the agent bash flag builder must never bind shared
 * Android storage for an agent command.
 *
 * `ProcessManager.runInProotSync()` (the agent bash path) builds its argv with
 * `buildInstallCommand(command, mountStorage)`. Agent bash always passes
 * `mountStorage = false`, so no `--bind=/storage` flag may appear. If a future
 * change makes `/storage` a default bind, this test fails before a device test.
 */
class AgentBashStorageBindTest {
    @Test
    fun agentInstallCommandNeverBindsSharedStorage() {
        withManager { manager ->
            val flags = manager.buildInstallCommand("echo ok", mountStorage = false)

            assertTrue(
                "agent command flags must not mention /storage: $flags",
                flags.none { it.contains("/storage") },
            )
            assertTrue(
                "agent command flags must not mention /sdcard: $flags",
                flags.none { it.contains("/sdcard") },
            )
        }
    }

    @Test
    fun agentInstallCommandStorageBindIsOptInOnly() {
        withManager { manager ->
            val flags = manager.buildInstallCommand("echo ok", mountStorage = false)
            // The opt-in constants are documented here so a rename cannot move
            // the bind into the default path unnoticed.
            assertFalse(flags.contains("--bind=/storage:/storage"))
            assertFalse(flags.contains("--bind=/storage/emulated/0:/sdcard"))
        }
    }

    @Test
    fun agentCommandStillBindsTheCoreDeviceTrees() {
        val root = Files.createTempDirectory("agent-bash-storage").toFile()
        try {
            val manager = ProcessManager(
                filesDir = root.absolutePath,
                nativeLibDir = File(root, "lib").absolutePath,
                cleanupCoordinator = null,
                processStarter = { throw AssertionError("must not start a process") },
            )
            val flags = manager.buildInstallCommand("echo ok", mountStorage = false)
            // Removing /storage must not remove the core mounts the guest needs.
            assertTrue(flags.contains("--bind=/dev"))
            assertTrue(flags.contains("--bind=/proc"))
            assertTrue(flags.contains("--bind=/sys"))
            assertTrue(flags.contains("--rootfs=${root.absolutePath}/rootfs/alpine"))
        } finally {
            root.deleteRecursively()
        }
    }

    private fun withManager(block: (ProcessManager) -> Unit) {
        val root = Files.createTempDirectory("agent-bash-storage").toFile()
        try {
            val manager = ProcessManager(
                filesDir = root.absolutePath,
                nativeLibDir = File(root, "lib").absolutePath,
                cleanupCoordinator = null,
                processStarter = { throw AssertionError("must not start a process") },
            )
            block(manager)
        } finally {
            root.deleteRecursively()
        }
    }
}
