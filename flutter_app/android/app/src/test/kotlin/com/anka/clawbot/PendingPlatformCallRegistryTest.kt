package com.anka.clawbot

import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PendingPlatformCallRegistryTest {
    private class FakeResult : MethodChannel.Result {
        var successValue: Any? = null
        var successCount = 0
        var errorCode: String? = null
        var errorMessage: String? = null
        var errorCount = 0
        var notImplementedCount = 0

        override fun success(result: Any?) {
            successCount++
            successValue = result
        }

        override fun error(code: String, message: String?, details: Any?) {
            errorCount++
            errorCode = code
            errorMessage = message
        }

        override fun notImplemented() {
            notImplementedCount++
        }
    }

    @Test
    fun settledCallsLeaveThePendingSet() {
        val registry = PendingPlatformCallRegistry()
        val first = FakeResult()
        val second = FakeResult()
        val third = FakeResult()

        registry.track(first).success("ok")
        registry.track(second).error("E", "boom", null)
        registry.track(third).notImplemented()

        assertEquals(0, registry.pendingCount())
        assertEquals("ok", first.successValue)
        assertEquals("E", second.errorCode)
        assertEquals(1, third.notImplementedCount)
    }

    @Test
    fun destroyFailsEveryPendingCallExactlyOnce() {
        val registry = PendingPlatformCallRegistry()
        val first = FakeResult()
        val second = FakeResult()
        val trackedFirst = registry.track(first)
        val trackedSecond = registry.track(second)
        assertEquals(2, registry.pendingCount())

        assertEquals(2, registry.close("ACTIVITY_DESTROYED", "destroyed"))
        assertEquals(0, registry.pendingCount())
        assertEquals(1, first.errorCount)
        assertEquals("ACTIVITY_DESTROYED", first.errorCode)
        assertEquals(1, second.errorCount)

        // A late native answer must not be delivered after the failure.
        trackedFirst.success("late")
        trackedSecond.notImplemented()
        assertEquals(0, first.successCount)
        assertEquals(0, second.notImplementedCount)

        // A second drain has nothing to fail.
        assertEquals(0, registry.close("ACTIVITY_DESTROYED", "destroyed"))
    }

    @Test
    fun aCallAnsweredAfterTheDrainDoesNotReenterTheTrackedSet() {
        val registry = PendingPlatformCallRegistry()
        val result = FakeResult()
        val tracked = registry.track(result)

        registry.close("ENGINE_DETACHED", "detached")
        tracked.success("ignored")
        assertEquals(0, registry.pendingCount())
        assertNull(result.successValue)
        assertTrue(result.errorCount == 1)
    }

    @Test
    fun trackAfterCloseFailsImmediatelyAndStaysOutOfThePendingSet() {
        val registry = PendingPlatformCallRegistry()
        assertEquals(0, registry.close("ACTIVITY_DESTROYED", "destroyed"))

        val late = FakeResult()
        val tracked = registry.track(late)

        // The activity is gone: this call must fail now instead of waiting for
        // an answer that can never arrive.
        assertEquals(1, late.errorCount)
        assertEquals("ACTIVITY_DESTROYED", late.errorCode)
        assertEquals(0, registry.pendingCount())

        // A later answer from the deferred work is ignored.
        tracked.success("late")
        assertEquals(0, late.successCount)
        // Closing again keeps the first reason and finds nothing to fail.
        assertEquals(0, registry.close("ENGINE_DETACHED", "detached"))
        val afterSecondClose = FakeResult()
        registry.track(afterSecondClose)
        assertEquals("ACTIVITY_DESTROYED", afterSecondClose.errorCode)
    }

    @Test
    fun concurrentTracksAndCloseNeverLeaveACallUnsettled() {
        val registry = PendingPlatformCallRegistry()
        val threads = 8
        val perThread = 64
        val results = java.util.Collections.synchronizedList(mutableListOf<FakeResult>())
        val start = java.util.concurrent.CountDownLatch(1)
        val workers = (0 until threads).map { index ->
            Thread {
                start.await()
                repeat(perThread) { step ->
                    val result = FakeResult()
                    results.add(result)
                    val tracked = registry.track(result)
                    // Half of the callers answer themselves, the rest race the
                    // teardown; either way the result must settle exactly once.
                    if ((index + step) % 2 == 0) tracked.success("ok")
                }
            }.apply { isDaemon = true }
        }
        workers.forEach { it.start() }
        val closer = Thread {
            start.await()
            registry.close("ACTIVITY_DESTROYED", "destroyed")
        }.apply { isDaemon = true }
        closer.start()
        start.countDown()
        workers.forEach { it.join(10_000) }
        closer.join(10_000)

        assertEquals(0, registry.pendingCount())
        assertEquals(threads * perThread, results.size)
        for (result in results) {
            val settled = result.successCount + result.errorCount + result.notImplementedCount
            assertEquals(1, settled)
        }
        // Everything that did not answer itself was failed by the close.
        assertTrue(results.any { it.errorCode == "ACTIVITY_DESTROYED" })
    }
}
