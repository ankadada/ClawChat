package com.anka.clawbot

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class ProcessManagerDirectTest {
    @Test
    fun nativeScopedLarkParserRequiresExactScopeAndEnvironmentPair() {
        val validEnvironment = mapOf(
            "LARKSUITE_CLI_APP_ID" to "test-app-id",
            "LARKSUITE_CLI_APP_SECRET" to "test-app-secret",
        )

        assertEquals(emptyMap<String, String>(), parseScopedLarkEnvironment(null, null))
        assertEquals(emptyMap<String, String>(), parseScopedLarkEnvironment(false, null))
        assertNull(parseScopedLarkEnvironment(true, null))
        assertNull(parseScopedLarkEnvironment(true, emptyMap<String, String>()))
        assertNull(parseScopedLarkEnvironment(false, validEnvironment))
        assertNull(parseScopedLarkEnvironment(false, emptyMap<String, String>()))
        assertNull(parseScopedLarkEnvironment("true", validEnvironment))
        assertEquals(validEnvironment, parseScopedLarkEnvironment(true, validEnvironment))
    }

    @Test
    fun mcpStreamOversizedLineTerminatesChildAndDropsBytes() {
        val manager = mcpTestManager()
        val process = McpStreamFakeProcess()
        val serverId = "oversized"
        val child = McpStdioRegistry.Child("run-mcp-cap", serverId, process, null, "tok-1") {}
        assertEquals(McpRegisterResult.REGISTERED, McpStdioRegistry.register(child))
        val events = mutableListOf<Map<String, Any>>()
        val oversized = ByteArray(ProcessManager.MCP_MAX_LINE_BYTES + 4096) {
            'a'.code.toByte()
        }

        manager.readMcpStream(
            child,
            ByteArrayInputStream(oversized),
            "stdout",
        ) { events.add(it) }

        val errors = events.filter { it["event"] == "error" }
        assertEquals(1, errors.size)
        assertEquals("line_too_long", errors.single()["reasonCode"])
        assertTrue(events.none { it["event"] == "line" })
        assertTrue(process.destroyCount.get() >= 1)
        assertNull(McpStdioRegistry.get(child.runId, serverId))
    }

    @Test
    fun mcpStreamNormalJsonLineStillPassesThrough() {
        val manager = mcpTestManager()
        val process = McpStreamFakeProcess()
        val serverId = "normal"
        val child = McpStdioRegistry.Child("run-mcp-normal", serverId, process, null, "tok-2") {}
        assertEquals(McpRegisterResult.REGISTERED, McpStdioRegistry.register(child))
        val events = mutableListOf<Map<String, Any>>()
        val line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}"

        manager.readMcpStream(
            child,
            ByteArrayInputStream((line + "\n").toByteArray()),
            "stdout",
        ) { events.add(it) }

        assertEquals(listOf(line), events.filter { it["event"] == "line" }.map { it["line"] })
        assertTrue(events.none { it["event"] == "error" })
        assertEquals(0, process.destroyCount.get())
        McpStdioRegistry.stopServer(child.runId, serverId)
    }

    @Test
    fun mcpStreamLineRateExcessTerminatesChild() {
        val manager = mcpTestManager()
        val process = McpStreamFakeProcess()
        val serverId = "flood"
        val child = McpStdioRegistry.Child("run-mcp-flood", serverId, process, null, "tok-3") {}
        assertEquals(McpRegisterResult.REGISTERED, McpStdioRegistry.register(child))
        val events = mutableListOf<Map<String, Any>>()
        val payload = buildString {
            repeat(ProcessManager.MCP_MAX_LINES_PER_SECOND + 5) { index ->
                append("{\"n\":")
                append(index)
                append("}\n")
            }
        }

        manager.readMcpStream(
            child,
            ByteArrayInputStream(payload.toByteArray()),
            "stdout",
        ) { events.add(it) }

        assertEquals(
            ProcessManager.MCP_MAX_LINES_PER_SECOND,
            events.count { it["event"] == "line" },
        )
        val errors = events.filter { it["event"] == "error" }
        assertEquals(1, errors.size)
        assertEquals("rate_limit_exceeded", errors.single()["reasonCode"])
        assertTrue(process.destroyCount.get() >= 1)
        assertNull(McpStdioRegistry.get(child.runId, serverId))
    }

    @Test
    fun mcpStdoutEofIsNotAnExitAndKeepsTheChildRegistered() {
        val manager = mcpTestManager()
        val process = McpStreamFakeProcess()
        val serverId = "eof"
        val events = mutableListOf<Map<String, Any>>()
        val child = McpStdioRegistry.Child("run-mcp-eof", serverId, process, null, "tok-4") {
            events.add(it)
        }
        assertEquals(McpRegisterResult.REGISTERED, McpStdioRegistry.register(child))

        manager.readMcpStream(
            child,
            ByteArrayInputStream(ByteArray(0)),
            "stdout",
        ) { events.add(it) }

        // EOF only means this pipe closed: it must not be reported as an exit
        // while the process itself is still alive.
        assertTrue(events.none { it["event"] == "exit" })
        assertEquals(child, McpStdioRegistry.get(child.runId, serverId))
        assertFalse(child.finished)
        assertEquals(0, process.destroyCount.get())
        McpStdioRegistry.stopServer(child.runId, serverId)
    }

    @Test
    fun mcpStdoutEofReapsAWedgedChildAndPublishesOneExit() {
        val manager = mcpTestManager()
        val process = TimeoutProcess()
        val serverId = "wedged"
        val events = mutableListOf<Map<String, Any>>()
        val child = McpStdioRegistry.Child("run-mcp-wedged", serverId, process, null, "tok-5") {
            events.add(it)
        }
        assertEquals(McpRegisterResult.REGISTERED, McpStdioRegistry.register(child))

        // The child closed stdout and then ignored its grace period.
        manager.reapAfterStdoutClosed(child)

        // The terminal event is published before the force-kill, which the reap
        // thread performs once the grace period is over.
        val exits = events.filter { it["event"] == "exit" }
        assertEquals(1, exits.size)
        assertEquals("stdout_closed_without_exit", exits.single()["reason"])
        assertNull(McpStdioRegistry.get(child.runId, serverId))
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
        while (process.destroyCount.get() == 0 && System.nanoTime() < deadline) {
            Thread.sleep(10)
        }
        assertTrue(process.destroyCount.get() >= 1)
    }

    @Test
    fun mcpStdoutEofLetsAChildThatExitsLeaveTheEventToTheWatcher() {
        val manager = mcpTestManager()
        val process = McpStreamFakeProcess()
        val serverId = "eof-exiting"
        val events = mutableListOf<Map<String, Any>>()
        val child = McpStdioRegistry.Child("run-mcp-eof-exit", serverId, process, null, "tok-6") {
            events.add(it)
        }
        assertEquals(McpRegisterResult.REGISTERED, McpStdioRegistry.register(child))

        manager.reapAfterStdoutClosed(child)

        // The process exited on its own inside the grace period: no kill, and no
        // terminal event from this path (the exit watcher owns it).
        assertTrue(events.none { it["event"] == "exit" })
        assertEquals(0, process.destroyCount.get())
        McpStdioRegistry.stopServer(child.runId, serverId)
    }

    @Test
    fun mcpStopPublishesExactlyOneTerminalEvent() {
        val process = McpStreamFakeProcess()
        val serverId = "stop-once"
        val events = mutableListOf<Map<String, Any>>()
        val child = McpStdioRegistry.Child("run-mcp-stop-once", serverId, process, null, "tok-7") {
            events.add(it)
        }
        assertEquals(McpRegisterResult.REGISTERED, McpStdioRegistry.register(child))

        McpStdioRegistry.stopServer(child.runId, serverId, "run_finished")
        McpStdioRegistry.stopServer(child.runId, serverId, "run_finished")
        McpStdioRegistry.stopAll("foreground_service_stopped")

        val exits = events.filter { it["event"] == "exit" }
        assertEquals(1, exits.size)
        assertEquals("run_finished", exits.single()["reason"])
        assertTrue(child.finished)
        assertNull(McpStdioRegistry.get(child.runId, serverId))
    }

    @Test
    fun mcpServiceTeardownPublishesTerminalEventsForEveryChild() {
        val first = McpStreamFakeProcess()
        val second = McpStreamFakeProcess()
        val events = mutableListOf<Map<String, Any>>()
        val firstChild = McpStdioRegistry.Child("run-mcp-stopall", "one", first, null, "tok-8") {
            events.add(it)
        }
        val secondChild = McpStdioRegistry.Child("run-mcp-stopall", "two", second, null, "tok-9") {
            events.add(it)
        }
        assertEquals(McpRegisterResult.REGISTERED, McpStdioRegistry.register(firstChild))
        assertEquals(McpRegisterResult.REGISTERED, McpStdioRegistry.register(secondChild))

        McpStdioRegistry.stopAll("foreground_service_stopped")

        assertEquals(0, McpStdioRegistry.activeCount())
        val exits = events.filter { it["event"] == "exit" }
        assertEquals(2, exits.size)
        assertTrue(exits.all { it["reason"] == "foreground_service_stopped" })
        assertEquals(setOf("one", "two"), exits.map { it["serverId"] }.toSet())
        assertTrue(firstChild.finished)
        assertTrue(secondChild.finished)
    }

    @Test
    fun mcpLateTerminalEventCannotUnregisterAFreshChild() {
        val stale = McpStreamFakeProcess()
        val fresh = McpStreamFakeProcess()
        val serverId = "same-key"
        val staleChild = McpStdioRegistry.Child("run-mcp-replaced", serverId, stale, null, "tok-10") {}
        assertEquals(McpRegisterResult.REGISTERED, McpStdioRegistry.register(staleChild))
        McpStdioRegistry.remove(staleChild.runId, serverId)

        val freshChild = McpStdioRegistry.Child("run-mcp-replaced", serverId, fresh, null, "tok-11") {}
        assertEquals(McpRegisterResult.REGISTERED, McpStdioRegistry.register(freshChild))

        // The stale child's terminal event must not evict the live child.
        staleChild.terminateOnce("late", -1)
        assertEquals(freshChild, McpStdioRegistry.get(staleChild.runId, serverId))
        assertFalse(freshChild.finished)
        McpStdioRegistry.stopServer(freshChild.runId, serverId)
    }

    @Test
    fun mcpStdinCapIsTheWholeFrameIncludingNewline() {
        val manager = mcpTestManager()
        val process = McpStdinRecordingProcess()
        val serverId = "stdin-exact-cap"
        val child = McpStdioRegistry.Child("run-mcp-stdin-exact", serverId, process, null, "tok-12") {}
        assertEquals(McpRegisterResult.REGISTERED, McpStdioRegistry.register(child))
        val cap = ProcessManager.MCP_MAX_STDIN_LINE_BYTES

        // Payload + "\n" == cap is the largest frame that fits.
        val atCap = "a".repeat(cap - 1)
        assertTrue(manager.writeMcpStdio(child.runId, serverId, atCap))
        assertEquals(cap, process.writtenText().toByteArray(Charsets.UTF_8).size)

        // One byte more is over the cap, not "exactly at" it.
        val overCap = "a".repeat(cap)
        assertFalse(manager.writeMcpStdio(child.runId, serverId, overCap))
        assertEquals(cap, process.writtenText().toByteArray(Charsets.UTF_8).size)
        McpStdioRegistry.stopServer(child.runId, serverId)
    }

    @Test
    fun mcpStdinFailureStaysReportedThroughTheTerminalEvent() {
        val manager = mcpTestManager()
        val process = McpStdinFailingProcess()
        val serverId = "stdin-failure-then-stop"
        val events = mutableListOf<Map<String, Any>>()
        val child = McpStdioRegistry.Child("run-mcp-stdin-failure-stop", serverId, process, null, "tok-13") {
            events.add(it)
        }
        assertEquals(McpRegisterResult.REGISTERED, McpStdioRegistry.register(child))

        assertFalse(manager.writeMcpStdio(child.runId, serverId, "{\"id\":1}"))
        McpStdioRegistry.stopServer(child.runId, serverId, "write_failed")

        assertEquals(1, events.count { it["event"] == "exit" })
    }

    @Test
    fun mcpExitWatcherPublishesTheExitOfAChildThatIsAlreadyGone() {
        val manager = mcpTestManager()
        val process = McpStreamFakeProcess()
        val serverId = "already-gone"
        val events =
            java.util.Collections.synchronizedList(mutableListOf<Map<String, Any>>())
        val child = McpStdioRegistry.Child("run-mcp-exit-watcher", serverId, process, null, "tok-14") {
            events.add(it)
        }
        assertEquals(McpRegisterResult.REGISTERED, McpStdioRegistry.register(child))

        manager.startMcpExitWatcher(child)

        // The child was gone before the watcher attached: Dart still gets its
        // one terminal event, and the key is free for a fresh start.
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
        while (events.none { it["event"] == "exit" } && System.nanoTime() < deadline) {
            Thread.sleep(10)
        }

        val exits = events.filter { it["event"] == "exit" }
        assertEquals(1, exits.size)
        assertEquals(143, exits.single()["exitCode"])
        assertNull(McpStdioRegistry.get(child.runId, serverId))
    }

    @Test
    fun mcpRegisterRejectsAStartThatOverlappedATeardown() {
        val process = McpStreamFakeProcess()
        val serverId = "overlapped"
        // A start captures the epoch before it spawns; the teardown below
        // happens while that start is still coming up.
        val overlapped = McpStdioRegistry.Child(
            "run-mcp-overlapped",
            serverId,
            process,
            null,
            "tok-overlapped",
        ) {}
        val overlappedEpoch = overlapped.epoch

        McpStdioRegistry.stopAll("foreground_service_stopped")

        // The process was already spawned by the caller, so a refusal here is
        // what keeps it from outliving the teardown.
        assertEquals(
            McpRegisterResult.TEARDOWN,
            McpStdioRegistry.register(overlapped),
        )
        assertEquals(overlappedEpoch + 1, McpStdioRegistry.currentEpoch())

        // A start that belongs to the new lifecycle is accepted.
        val after = McpStdioRegistry.Child(
            "run-mcp-overlapped",
            serverId,
            McpStreamFakeProcess(),
            null,
            "tok-after",
        ) {}
        assertEquals(McpRegisterResult.REGISTERED, McpStdioRegistry.register(after))
        McpStdioRegistry.stopServer(after.runId, after.serverId)
    }

    @Test
    fun mcpClosedEpochRefusesRegistrationsUntilAnEngineReopensIt() {
        McpStdioRegistry.closeEpoch("engine_detached")
        val whileClosed = McpStdioRegistry.Child(
            "run-mcp-closed-epoch",
            "closed",
            McpStreamFakeProcess(),
            null,
            "tok-closed",
        ) {}
        assertEquals(
            McpRegisterResult.TEARDOWN,
            McpStdioRegistry.register(whileClosed),
        )

        McpStdioRegistry.openEpoch()
        val afterReopen = McpStdioRegistry.Child(
            "run-mcp-closed-epoch",
            "closed",
            McpStreamFakeProcess(),
            null,
            "tok-reopened",
        ) {}
        assertEquals(
            McpRegisterResult.REGISTERED,
            McpStdioRegistry.register(afterReopen),
        )
        McpStdioRegistry.stopServer(afterReopen.runId, afterReopen.serverId)
    }

    @Test
    fun mcpStartThatRacesStopAllNeverStaysRegistered() {
        // Children that registered before the teardown must be drained by it.
        val settled = (0 until 4).map { index ->
            McpStdioRegistry.Child(
                "run-mcp-race",
                "settled-$index",
                McpStreamFakeProcess(),
                null,
                "tok-settled-$index",
            ) {}
        }
        settled.forEach {
            assertEquals(McpRegisterResult.REGISTERED, McpStdioRegistry.register(it))
        }

        // Children whose start is still in flight when the teardown lands.
        val inFlight = (0 until 4).map { index ->
            McpStdioRegistry.Child(
                "run-mcp-race",
                "inflight-$index",
                McpStreamFakeProcess(),
                null,
                "tok-inflight-$index",
            ) {}
        }
        val results = java.util.Collections.synchronizedList(
            mutableListOf<Pair<McpStdioRegistry.Child, McpRegisterResult>>()
        )
        val start = java.util.concurrent.CountDownLatch(1)
        val threads = inFlight.map { child ->
            Thread {
                start.await()
                results.add(child to McpStdioRegistry.register(child))
            }.apply { isDaemon = true }
        }
        threads.forEach { it.start() }
        val teardown = Thread {
            start.await()
            McpStdioRegistry.stopAll("foreground_service_stopped")
        }.apply { isDaemon = true }
        teardown.start()
        start.countDown()
        threads.forEach { it.join(10_000) }
        teardown.join(10_000)

        // Nothing that started around the teardown may still be registered, and
        // the ones that were live before it are finished.
        assertEquals(0, McpStdioRegistry.activeCount())
        assertTrue(settled.all { it.finished })
        assertEquals(4, results.size)
        for ((child, result) in results) {
            // Either the start lost the race and was refused, or it registered
            // first and the teardown drained it: never left running.
            assertTrue(
                result == McpRegisterResult.TEARDOWN ||
                    (result == McpRegisterResult.REGISTERED && child.finished),
            )
            assertNull(McpStdioRegistry.get(child.runId, child.serverId))
        }
    }

    @Test
    fun mcpStaleTokenCannotWriteCloseOrStopTheNewChild() {
        val manager = mcpTestManager()
        val runId = "run-mcp-token"
        val serverId = "token"
        val firstProcess = McpStdinRecordingProcess()
        val first = McpStdioRegistry.Child(
            runId,
            serverId,
            firstProcess,
            null,
            "token-first",
        ) {}
        assertEquals(McpRegisterResult.REGISTERED, McpStdioRegistry.register(first))
        McpStdioRegistry.stopServer(runId, serverId, "restart")

        val secondProcess = McpStdinRecordingProcess()
        val second = McpStdioRegistry.Child(
            runId,
            serverId,
            secondProcess,
            null,
            "token-second",
        ) {}
        assertEquals(McpRegisterResult.REGISTERED, McpStdioRegistry.register(second))

        // The previous child's token must not reach the child that replaced it.
        assertFalse(manager.writeMcpStdio(runId, serverId, "{\"id\":1}", "token-first"))
        assertFalse(manager.closeMcpStdin(runId, serverId, "token-first"))
        McpStdioRegistry.stopServerIfTokenMatches(runId, serverId, "token-first")
        assertEquals(second, McpStdioRegistry.get(runId, serverId))
        assertFalse(second.finished)
        assertEquals("", secondProcess.writtenText())

        // The live token still works.
        assertTrue(manager.writeMcpStdio(runId, serverId, "{\"id\":2}", "token-second"))
        assertTrue(secondProcess.writtenText().startsWith("{\"id\":2}"))
        McpStdioRegistry.stopServerIfTokenMatches(runId, serverId, "token-second")
        assertTrue(second.finished)
    }

    @Test
    fun mcpDelayedLineFromAPreviousChildIsNotAttributedToTheNewOne() {
        val runId = "run-mcp-delayed"
        val serverId = "delayed"
        val oldEvents = mutableListOf<Map<String, Any>>()
        val oldChild = McpStdioRegistry.Child(
            runId,
            serverId,
            McpStreamFakeProcess(),
            null,
            "token-old",
        ) { oldEvents.add(it) }
        assertEquals(McpRegisterResult.REGISTERED, McpStdioRegistry.register(oldChild))
        McpStdioRegistry.stopServer(runId, serverId, "restart")

        val newChild = McpStdioRegistry.Child(
            runId,
            serverId,
            McpStreamFakeProcess(),
            null,
            "token-new",
        ) {}
        assertEquals(McpRegisterResult.REGISTERED, McpStdioRegistry.register(newChild))

        // A delayed event from the old child carries the old token, and the
        // registry still points at the new child: nothing was swapped.
        assertEquals("token-new", McpStdioRegistry.get(runId, serverId)?.sessionToken)
        assertEquals(1, oldEvents.count { it["event"] == "exit" })
        assertEquals("token-old", oldEvents.single { it["event"] == "exit" }["sessionToken"])
        McpStdioRegistry.stopServer(runId, serverId)
    }

    @Test
    fun mcpReadinessTimerStopsAChildThatNeverProducedOutput() {
        val process = McpStdinRecordingProcess()
        val serverId = "never-ready"
        val events =
            java.util.Collections.synchronizedList(mutableListOf<Map<String, Any>>())
        val child = McpStdioRegistry.Child(
            "run-mcp-never-ready",
            serverId,
            process,
            null,
            "tok-never-ready",
        ) { events.add(it) }
        assertEquals(McpRegisterResult.REGISTERED, McpStdioRegistry.register(child))

        mcpTestManager().scheduleMcpReadinessTimeout(child, 1)

        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
        while (events.none { it["event"] == "exit" } && System.nanoTime() < deadline) {
            Thread.sleep(10)
        }
        val exits = events.filter { it["event"] == "exit" }
        assertEquals(1, exits.size)
        assertEquals("readiness_timeout", exits.single()["reason"])
        assertNull(McpStdioRegistry.get(child.runId, serverId))
    }

    @Test
    fun mcpReadyChildSurvivesItsReadinessWindowAndKeepsRunning() {
        val process = McpStdinRecordingProcess()
        val serverId = "long-running"
        val events =
            java.util.Collections.synchronizedList(mutableListOf<Map<String, Any>>())
        val child = McpStdioRegistry.Child(
            "run-mcp-long-running",
            serverId,
            process,
            null,
            "tok-long-running",
        ) { events.add(it) }
        assertEquals(McpRegisterResult.REGISTERED, McpStdioRegistry.register(child))

        // The child answered on stdout, so it is past the handshake.
        val manager = mcpTestManager()
        manager.readMcpStream(
            child,
            ByteArrayInputStream("{\"jsonrpc\":\"2.0\",\"id\":1}\n".toByteArray()),
            "stdout",
        ) { events.add(it) }
        assertTrue(child.ready)

        manager.scheduleMcpReadinessTimeout(child, 1)
        // Three times the readiness window with a long-running tool call in
        // flight: the old lifetime timer would have killed it here.
        Thread.sleep(3_000)

        assertTrue(events.none { it["event"] == "exit" })
        assertFalse(child.finished)
        assertEquals(child, McpStdioRegistry.get(child.runId, serverId))
        assertEquals(0, process.maxConcurrentWriters.get())
        McpStdioRegistry.stopServer(child.runId, serverId)
    }

    @Test
    fun mcpLaunchScriptFailsClosedWithoutTheNativeBroker() {
        val root = Files.createTempDirectory("mcp-launch-no-native").toFile()
        val manager = ProcessManager(
            filesDir = root.absolutePath,
            nativeLibDir = File(root, "lib").absolutePath,
            cleanupCoordinator = null,
        )
        try {
            // The JVM has no JNI broker. The Kotlin layer must refuse rather
            // than fall back to a pathname write inside a guest-writable tree.
            assertThrows(IllegalStateException::class.java) {
                manager.writeMcpLaunchScript("run-1", "server-1", emptyMap(), "start-1")
            }
            // Nothing was created by Kotlin itself.
            assertFalse(File(root, "home/.mcp").exists())
            // The sweep and the delete stay no-ops instead of crashing.
            assertEquals(0, manager.sweepStaleMcpLaunchScripts())
            val script = McpLaunchScript(
                homeDir = File(root, "home").absolutePath,
                runSegment = "run-1",
                serverSegment = "server-1",
                startName = "start-1",
                identity = "1:2",
                hostPath = File(root, "home/.mcp/run-1/server-1/start-1/launch.sh"),
                guestPath = "/root/home/.mcp/run-1/server-1/start-1/launch.sh",
            )
            ProcessManager.deleteMcpLaunchScript(script)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun mcpLaunchScriptGuestPathPointsAtItsOwnStartDirectory() {
        val script = McpLaunchScript(
            homeDir = "/data/user/0/com.anka.clawbot/files/home",
            runSegment = "run-1",
            serverSegment = "server-1",
            startName = "abcdef",
            identity = "42:7",
            hostPath = File("/data/user/0/com.anka.clawbot/files/home/.mcp/run-1/server-1/abcdef/launch.sh"),
            guestPath = "/root/home/.mcp/run-1/server-1/abcdef/launch.sh",
        )

        assertEquals("42:7", script.identity)
        assertEquals(
            script.hostPath.absolutePath,
            script.homeDir + "/.mcp/" + script.runSegment + "/" + script.serverSegment +
                "/" + script.startName + "/launch.sh",
        )
        assertEquals(
            script.guestPath,
            "/root/home/.mcp/" + script.runSegment + "/" + script.serverSegment +
                "/" + script.startName + "/launch.sh",
        )
        assertTrue(script.guestPath.endsWith(script.hostPath.name))
    }

    @Test
    fun mcpDelayedStopRunSparesASameKeyReplacement() {
        val runId = "run-mcp-late-stop"
        val serverId = "server"
        val first = McpStdioRegistry.Child(
            runId,
            serverId,
            McpStreamFakeProcess(),
            null,
            "token-first",
        ) {}
        assertEquals(McpRegisterResult.REGISTERED, McpStdioRegistry.register(first))
        // The first child's lifecycle ends; the same key is then reused.
        McpStdioRegistry.stopServerIfTokenMatches(runId, serverId, "token-first", "replaced")
        assertTrue(first.finished)

        val replacement = McpStdioRegistry.Child(
            runId,
            serverId,
            McpStreamFakeProcess(),
            null,
            "token-replacement",
        ) {}
        assertEquals(McpRegisterResult.REGISTERED, McpStdioRegistry.register(replacement))

        // A delayed stopRun issued by the first child's owner lists only its own
        // token: the replacement must survive.
        McpStdioRegistry.stopRun(runId, "run_finished", setOf("token-first"))
        assertEquals(replacement, McpStdioRegistry.get(runId, serverId))
        assertFalse(replacement.finished)

        // The owner of the replacement stops it with its own token.
        McpStdioRegistry.stopRun(runId, "run_finished", setOf("token-replacement"))
        assertTrue(replacement.finished)
        assertNull(McpStdioRegistry.get(runId, serverId))
    }

    @Test
    fun mcpStopRunWithNoTokensStillSweepsTheWholeRun() {
        val first = McpStdioRegistry.Child(
            "run-mcp-sweep-run",
            "one",
            McpStreamFakeProcess(),
            null,
            "token-one",
        ) {}
        val second = McpStdioRegistry.Child(
            "run-mcp-sweep-run",
            "two",
            McpStreamFakeProcess(),
            null,
            "token-two",
        ) {}
        val otherRun = McpStdioRegistry.Child(
            "run-mcp-other-run",
            "one",
            McpStreamFakeProcess(),
            null,
            "token-other",
        ) {}
        assertEquals(McpRegisterResult.REGISTERED, McpStdioRegistry.register(first))
        assertEquals(McpRegisterResult.REGISTERED, McpStdioRegistry.register(second))
        assertEquals(McpRegisterResult.REGISTERED, McpStdioRegistry.register(otherRun))

        McpStdioRegistry.stopRun("run-mcp-sweep-run")

        assertTrue(first.finished)
        assertTrue(second.finished)
        assertFalse(otherRun.finished)
        assertEquals(otherRun, McpStdioRegistry.get("run-mcp-other-run", "one"))
        McpStdioRegistry.stopServer(otherRun.runId, otherRun.serverId)
    }

    @Test
    fun mcpConcurrentStopRunNeverTakesDownTheReplacement() {
        val runId = "run-mcp-race-stop"
        val serverId = "server"
        val first = McpStdioRegistry.Child(
            runId,
            serverId,
            McpStreamFakeProcess(),
            null,
            "token-old",
        ) {}
        assertEquals(McpRegisterResult.REGISTERED, McpStdioRegistry.register(first))
        McpStdioRegistry.stopServerIfTokenMatches(runId, serverId, "token-old", "replaced")

        val replacement = McpStdioRegistry.Child(
            runId,
            serverId,
            McpStreamFakeProcess(),
            null,
            "token-new",
        ) {}
        assertEquals(McpRegisterResult.REGISTERED, McpStdioRegistry.register(replacement))

        val start = java.util.concurrent.CountDownLatch(1)
        val stoppers = (0 until 4).map {
            Thread {
                start.await()
                repeat(50) {
                    // The previous child's owner keeps issuing its delayed stop.
                    McpStdioRegistry.stopRun(runId, "run_finished", setOf("token-old"))
                }
            }.apply { isDaemon = true }
        }
        stoppers.forEach { it.start() }
        start.countDown()
        stoppers.forEach { it.join(10_000) }

        assertEquals(replacement, McpStdioRegistry.get(runId, serverId))
        assertFalse(replacement.finished)
        McpStdioRegistry.stopRun(runId, "run_finished", setOf("token-new"))
        assertTrue(replacement.finished)
    }

    @Test
    fun mcpStdinRejectsOversizedLineWithoutWriting() {
        val manager = mcpTestManager()
        val process = McpStdinRecordingProcess()
        val serverId = "stdin-cap"
        val child = McpStdioRegistry.Child("run-mcp-stdin-cap", serverId, process, null, "tok-15") {}
        assertEquals(McpRegisterResult.REGISTERED, McpStdioRegistry.register(child))

        val oversizedChars = "a".repeat(ProcessManager.MCP_MAX_STDIN_LINE_BYTES + 1)
        assertFalse(manager.writeMcpStdio(child.runId, serverId, oversizedChars))
        assertEquals(0, process.writtenText().length)

        // Multi-byte text can pass the char bound and still exceed the byte cap.
        val oversizedBytes =
            "字".repeat((ProcessManager.MCP_MAX_STDIN_LINE_BYTES / 3) + 1)
        assertFalse(manager.writeMcpStdio(child.runId, serverId, oversizedBytes))
        assertEquals(0, process.writtenText().length)
        McpStdioRegistry.stopServer(child.runId, serverId)
    }

    @Test
    fun mcpStdinSerializesConcurrentWritersPerChild() {
        val manager = mcpTestManager()
        val process = McpStdinRecordingProcess()
        val serverId = "stdin-serial"
        val child = McpStdioRegistry.Child("run-mcp-stdin-serial", serverId, process, null, "tok-16") {}
        assertEquals(McpRegisterResult.REGISTERED, McpStdioRegistry.register(child))
        val lines = (0 until 16).map { "{\"jsonrpc\":\"2.0\",\"id\":$it}" }
        val results = java.util.Collections.synchronizedList(mutableListOf<Boolean>())

        val threads = lines.map { line ->
            Thread {
                results.add(manager.writeMcpStdio(child.runId, serverId, line))
            }.apply { isDaemon = true }
        }
        threads.forEach { it.start() }
        threads.forEach { it.join(5_000) }

        assertEquals(16, results.count { it })
        assertEquals(1, process.maxConcurrentWriters.get())
        assertEquals(lines.toSet(), process.writtenText().trim().lines().toSet())
        McpStdioRegistry.stopServer(child.runId, serverId)
    }

    @Test
    fun mcpStdinWriteFailureReportsFalseAndKeepsChildRegistered() {
        val manager = mcpTestManager()
        val process = McpStdinFailingProcess()
        val serverId = "stdin-failure"
        val child = McpStdioRegistry.Child("run-mcp-stdin-failure", serverId, process, null, "tok-17") {}
        assertEquals(McpRegisterResult.REGISTERED, McpStdioRegistry.register(child))

        assertFalse(manager.writeMcpStdio(child.runId, serverId, "{\"id\":1}"))
        assertEquals(child, McpStdioRegistry.get(child.runId, serverId))
        McpStdioRegistry.stopServer(child.runId, serverId)
    }

    private fun mcpTestManager(): ProcessManager {
        val root = Files.createTempDirectory("mcp-stream-test").toFile()
        return ProcessManager(
            filesDir = root.absolutePath,
            nativeLibDir = File(root, "lib").absolutePath,
            cleanupCoordinator = null,
        )
    }

    @Test
    fun freshDirectEchoStartsRealProotWithoutCoordinator() = withManager { manager, starts ->
        val output = manager.runInProotSync(
            command = "echo ok",
            timeoutSeconds = 30,
            operationId = "echo-operation",
            continuationKey = null,
        )

        assertEquals("ok\n", output)
        assertEquals(1, starts.size)
        assertTrue(starts.single().first().endsWith("/libproot.so"))
        assertFalse(starts.single().contains("/system/bin/sh"))
    }

    @Test
    fun genericDirectProcessEnvironmentContainsNoCredentialNames() {
        val root = Files.createTempDirectory("generic-secret-free-env").toFile()
        var launchEnvironment = emptyMap<String, String>()
        val manager = ProcessManager(
            filesDir = root.absolutePath,
            nativeLibDir = File(root, "lib").absolutePath,
            cleanupCoordinator = null,
            processStarter = { builder ->
                launchEnvironment = builder.environment().toMap()
                CompletedProcess("not-present\n")
            },
        )

        try {
            assertEquals(
                "not-present\n",
                manager.runInProotSync("env", operationId = "generic-environment"),
            )
            assertTrue(launchEnvironment.keys.none { it.startsWith("FEISHU_") })
            assertTrue(launchEnvironment.keys.none { it.startsWith("LARKSUITE_") })
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun scopedEnvironmentUsesOnlyApprovedLarkKeysAndNeverPlacesValuesInArgv() {
        val root = Files.createTempDirectory("scoped-lark-env").toFile()
        val appId = "scoped-app-id-sentinel"
        val appSecret = "scoped-secret-$appId-sentinel"
        val builders = mutableListOf<ProcessBuilder>()
        val launchEnvironments = mutableListOf<Set<String>>()
        val manager = ProcessManager(
            filesDir = root.absolutePath,
            nativeLibDir = File(root, "lib").absolutePath,
            cleanupCoordinator = null,
            processStarter = { builder ->
                builders += builder
                launchEnvironments += builder.environment().keys.toSet()
                CompletedProcess("$appId\n$appSecret\n")
            },
        )

        try {
            val output = manager.runInProotSync(
                command = "lark-cli configure",
                operationId = "scoped-operation",
                scopedEnvironment = mapOf(
                    "LARKSUITE_CLI_APP_ID" to appId,
                    "LARKSUITE_CLI_APP_SECRET" to appSecret,
                ),
            )

            assertEquals("[REDACTED]\n[REDACTED]\n", output)
            assertEquals(1, builders.size)
            val builder = builders.single()
            assertTrue(builder.command().contains("/bin/sh"))
            assertTrue(builder.command().contains("lark-cli configure"))
            assertTrue(builder.command().none { it.contains(appId) || it.contains(appSecret) })
            assertEquals(
                setOf(
                    "PROOT_TMP_DIR", "PROOT_LOADER", "PROOT_LOADER_32", "LD_LIBRARY_PATH",
                    "LARKSUITE_CLI_APP_ID", "LARKSUITE_CLI_APP_SECRET",
                ),
                launchEnvironments.single(),
            )
            // The credential keys are removed from the mutable ProcessBuilder after start.
            assertTrue(builder.environment().keys.none { it.startsWith("LARKSUITE_CLI_") })
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun scopedStartFailureRedactsCredentialValuesFromException() {
        val root = Files.createTempDirectory("scoped-lark-failure").toFile()
        val appId = "start-failure-id-sentinel"
        val appSecret = "start-failure-secret-sentinel"
        val manager = ProcessManager(
            filesDir = root.absolutePath,
            nativeLibDir = File(root, "lib").absolutePath,
            cleanupCoordinator = null,
            processStarter = { throw IllegalStateException("failed $appId $appSecret") },
        )

        try {
            val error = assertThrows(IllegalStateException::class.java) {
                manager.runInProotSync(
                    command = "lark-cli configure",
                    operationId = "scoped-start-failure",
                    scopedEnvironment = mapOf(
                        "LARKSUITE_CLI_APP_ID" to appId,
                        "LARKSUITE_CLI_APP_SECRET" to appSecret,
                    ),
                )
            }
            assertFalse(error.message!!.contains(appId))
            assertFalse(error.message!!.contains(appSecret))
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun malformedScopedEnvironmentFailsClosedBeforeProcessBuilder() {
        val root = Files.createTempDirectory("scoped-lark-invalid").toFile()
        var starts = 0
        val manager = ProcessManager(
            filesDir = root.absolutePath,
            nativeLibDir = File(root, "lib").absolutePath,
            cleanupCoordinator = null,
            processStarter = {
                starts++
                CompletedProcess("unexpected")
            },
        )

        try {
            assertThrows(IllegalArgumentException::class.java) {
                manager.runInProotSync(
                    command = "lark-cli configure",
                    operationId = "scoped-invalid",
                    scopedEnvironment = mapOf("UNAPPROVED_KEY" to "value"),
                )
            }
            assertEquals(0, starts)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun oneHundredDirectCommandsCreateNoDurableLaunches() = withManager { manager, starts ->
        repeat(100) { index ->
            assertEquals(
                "ok\n",
                manager.runInProotSync(
                    command = "echo $index",
                    timeoutSeconds = 30,
                    operationId = "operation-$index",
                ),
            )
        }

        assertEquals(100, starts.size)
        assertTrue(starts.all { it.first().endsWith("/libproot.so") })
        assertTrue(starts.none { it.contains("/system/bin/sh") })
    }

    @Test
    fun corruptLegacyLedgerIsNotConsultedByDirectCommand() {
        val root = Files.createTempDirectory("direct-legacy-ledger").toFile()
        val ledgerReads = AtomicInteger()
        val coordinator = CommandCleanupCoordinator(
            ledger = object : CommandCleanupLedger {
                override fun read(): CleanupLedgerRead {
                    ledgerReads.incrementAndGet()
                    return CleanupLedgerRead.Corrupt("legacy-corrupt")
                }

                override fun write(records: List<CommandCleanupRecord>): Boolean = false
            },
            disposer = CleanupProcessDisposer {
                CleanupDisposalAttempt(ProcessDisposalResult.RETRYABLE_UNKNOWN)
            },
            immediateScheduler = CleanupImmediateScheduler { _, _ -> },
            backstop = object : CleanupBackstop {
                override fun schedule(minimumLatencyMs: Long): Boolean = false
                override fun cancel() = Unit
            },
        )
        val manager = ProcessManager(
            filesDir = root.absolutePath,
            nativeLibDir = File(root, "lib").absolutePath,
            cleanupCoordinator = coordinator,
            processStarter = { CompletedProcess("ok\n") },
        )

        assertEquals("ok\n", manager.runInProotSync("echo ok", operationId = "direct"))
        assertEquals(0, ledgerReads.get())
        root.deleteRecursively()
    }

    @Test
    fun unresolvedLegacyStatesRemainCleanupOnlyForDirectCommands() {
        for (state in listOf(
            CleanupDisposalState.ACTIVE,
            CleanupDisposalState.BACKSTOP_PENDING,
        )) {
            val root = Files.createTempDirectory("direct-legacy-state").toFile()
            val record = CommandCleanupRecord(
                recordId = "legacy-${state.name}",
                owner = CommandContinuationOwner.AGENT_BASH,
                sessionHash = "session-hash",
                operationHash = "operation-hash",
                candidateHash = null,
                attemptHash = "attempt-hash",
                launchTokenHash = "token-hash",
                parentProcessId = 41,
                parentStartTimeTicks = 410L,
                processId = if (state == CleanupDisposalState.ACTIVE) 42 else 0,
                startTimeTicks = if (state == CleanupDisposalState.ACTIVE) 420L else 0L,
                deadlineEpochMs = Long.MAX_VALUE,
                launchExpiresEpochMs = Long.MAX_VALUE,
                disposalState = state,
                disposalVersion = 1L,
            )
            val coordinator = CommandCleanupCoordinator(
                ledger = object : CommandCleanupLedger {
                    override fun read(): CleanupLedgerRead = CleanupLedgerRead.Success(listOf(record))
                    override fun write(records: List<CommandCleanupRecord>): Boolean = true
                },
                disposer = CleanupProcessDisposer {
                    CleanupDisposalAttempt(ProcessDisposalResult.RETRYABLE_UNKNOWN)
                },
                immediateScheduler = CleanupImmediateScheduler { _, _ -> },
                backstop = object : CleanupBackstop {
                    override fun schedule(minimumLatencyMs: Long): Boolean = true
                    override fun cancel() = Unit
                },
                launchDirectory = File(root, "invalid-or-stale-launch-root"),
                recoveryProbe = PidProcessProbe { PidProbeResult.RetryableUnknown },
            )
            coordinator.initialize()
            assertTrue(coordinator.reconcile())
            val manager = ProcessManager(
                filesDir = root.absolutePath,
                nativeLibDir = File(root, "lib").absolutePath,
                cleanupCoordinator = coordinator,
                processStarter = { CompletedProcess("ok\n") },
            )

            assertEquals(
                "ok\n",
                manager.runInProotSync("echo ok", operationId = "direct-${state.name}"),
            )
            assertTrue(coordinator.recordsForTest().isNotEmpty())
            root.deleteRecursively()
        }
    }

    @Test
    fun directCancellationDestroysExactChildOnce() {
        val root = Files.createTempDirectory("direct-cancel").toFile()
        val process = BlockingProcess()
        val manager = ProcessManager(
            filesDir = root.absolutePath,
            nativeLibDir = File(root, "lib").absolutePath,
            cleanupCoordinator = null,
            processStarter = { process },
        )
        val finished = CountDownLatch(1)
        val worker = Thread {
            try {
                manager.runInProotSync("echo ok", 30, operationId = "cancel-me")
            } catch (_: RuntimeException) {
                // A killed direct process reports its non-zero exit.
            } finally {
                finished.countDown()
            }
        }

        worker.start()
        assertTrue(process.waiting.await(5, TimeUnit.SECONDS))
        manager.cancelOperation("cancel-me")
        assertTrue(finished.await(5, TimeUnit.SECONDS))
        assertEquals(1, process.destroyCount.get())
        root.deleteRecursively()
    }

    @Test
    fun directTimeoutDestroysExactChildOnce() {
        val root = Files.createTempDirectory("direct-timeout").toFile()
        val process = TimeoutProcess()
        val manager = ProcessManager(
            filesDir = root.absolutePath,
            nativeLibDir = File(root, "lib").absolutePath,
            cleanupCoordinator = null,
            processStarter = { process },
        )

        assertThrows(RuntimeException::class.java) {
            manager.runInProotSync("echo ok", 1, operationId = "timeout")
        }
        assertEquals(1, process.destroyCount.get())
        root.deleteRecursively()
    }

    private fun withManager(block: (ProcessManager, MutableList<List<String>>) -> Unit) {
        val root = Files.createTempDirectory("direct-proot").toFile()
        val starts = mutableListOf<List<String>>()
        val manager = ProcessManager(
            filesDir = root.absolutePath,
            nativeLibDir = File(root, "lib").absolutePath,
            cleanupCoordinator = null,
            processStarter = { builder ->
                starts += builder.command().toList()
                CompletedProcess("ok\n")
            },
        )
        try {
            block(manager, starts)
        } finally {
            root.deleteRecursively()
        }
    }

    private class McpStdinRecordingProcess : Process() {
        private val buffer = ByteArrayOutputStream()
        private val activeWriters = AtomicInteger()
        val maxConcurrentWriters = AtomicInteger()
        private var alive = true

        override fun getOutputStream(): OutputStream = object : OutputStream() {
            override fun write(b: Int) = write(byteArrayOf(b.toByte()), 0, 1)

            override fun write(b: ByteArray, off: Int, len: Int) {
                val now = activeWriters.incrementAndGet()
                maxConcurrentWriters.accumulateAndGet(now) { previous, current ->
                    maxOf(previous, current)
                }
                try {
                    // Widen the race window so an unserialized writer is caught.
                    Thread.sleep(2)
                    synchronized(buffer) { buffer.write(b, off, len) }
                } finally {
                    activeWriters.decrementAndGet()
                }
            }
        }

        fun writtenText(): String =
            synchronized(buffer) { buffer.toString(Charsets.UTF_8.name()) }

        override fun getInputStream(): InputStream = ByteArrayInputStream(ByteArray(0))
        override fun getErrorStream(): InputStream = ByteArrayInputStream(ByteArray(0))
        override fun waitFor(): Int {
            alive = false
            return 0
        }

        override fun waitFor(timeout: Long, unit: TimeUnit): Boolean {
            alive = false
            return true
        }

        override fun exitValue(): Int = if (alive) throw IllegalThreadStateException() else 0
        override fun destroy() {
            alive = false
        }

        override fun destroyForcibly(): Process {
            destroy()
            return this
        }

        override fun isAlive(): Boolean = alive
    }

    private class McpStdinFailingProcess : Process() {
        private var alive = true

        override fun getOutputStream(): OutputStream = object : OutputStream() {
            override fun write(b: Int) {
                throw java.io.IOException("stdin closed")
            }

            override fun write(b: ByteArray, off: Int, len: Int) {
                throw java.io.IOException("stdin closed")
            }
        }

        override fun getInputStream(): InputStream = ByteArrayInputStream(ByteArray(0))
        override fun getErrorStream(): InputStream = ByteArrayInputStream(ByteArray(0))
        override fun waitFor(): Int {
            alive = false
            return 0
        }

        override fun waitFor(timeout: Long, unit: TimeUnit): Boolean {
            alive = false
            return true
        }

        override fun exitValue(): Int = if (alive) throw IllegalThreadStateException() else 0
        override fun destroy() {
            alive = false
        }

        override fun destroyForcibly(): Process {
            destroy()
            return this
        }

        override fun isAlive(): Boolean = alive
    }

    private class McpStreamFakeProcess : Process() {
        val destroyCount = AtomicInteger()
        private var alive = true

        override fun getOutputStream(): OutputStream = ByteArrayOutputStream()
        override fun getInputStream(): InputStream = ByteArrayInputStream(ByteArray(0))
        override fun getErrorStream(): InputStream = ByteArrayInputStream(ByteArray(0))
        override fun waitFor(): Int {
            alive = false
            return 143
        }

        override fun waitFor(timeout: Long, unit: TimeUnit): Boolean {
            alive = false
            return true
        }

        override fun exitValue(): Int = if (alive) throw IllegalThreadStateException() else 143
        override fun destroy() {
            destroyCount.incrementAndGet()
            alive = false
        }

        override fun destroyForcibly(): Process {
            destroy()
            return this
        }

        override fun isAlive(): Boolean = alive
    }

    private open class CompletedProcess(output: String) : Process() {
        private val input = ByteArrayInputStream(output.toByteArray())
        private val error = ByteArrayInputStream(ByteArray(0))
        private val sink = ByteArrayOutputStream()
        protected var alive = false

        override fun getOutputStream(): OutputStream = sink
        override fun getInputStream(): InputStream = input
        override fun getErrorStream(): InputStream = error
        override fun waitFor(): Int = 0
        override fun waitFor(timeout: Long, unit: TimeUnit): Boolean = true
        override fun exitValue(): Int = if (alive) throw IllegalThreadStateException() else 0
        override fun destroy() {
            alive = false
        }
        override fun destroyForcibly(): Process {
            destroy()
            return this
        }
        override fun isAlive(): Boolean = alive
    }

    private class BlockingProcess : CompletedProcess("") {
        val waiting = CountDownLatch(1)
        val destroyCount = AtomicInteger()
        private val released = CountDownLatch(1)

        init {
            alive = true
        }

        override fun waitFor(timeout: Long, unit: TimeUnit): Boolean {
            waiting.countDown()
            released.await(timeout, unit)
            return !alive
        }

        override fun exitValue(): Int = if (alive) throw IllegalThreadStateException() else 143

        override fun destroyForcibly(): Process {
            destroyCount.incrementAndGet()
            alive = false
            released.countDown()
            return this
        }
    }

    private class TimeoutProcess : CompletedProcess("") {
        val destroyCount = AtomicInteger()

        init {
            alive = true
        }

        override fun waitFor(timeout: Long, unit: TimeUnit): Boolean = false

        override fun destroyForcibly(): Process {
            destroyCount.incrementAndGet()
            alive = false
            return this
        }
    }
}
