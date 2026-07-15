package com.anka.clawbot

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class BackgroundTaskNativeLeaseTest {
    @Test
    fun cancelledStartHandshakeCannotReportEstablishedLease() {
        val request = BackgroundTaskLeaseStartRequest()

        assertTrue(request.begin())
        request.cancel()

        assertFalse(request.finish(established = true))
        assertFalse(request.result.get())
    }

    @Test
    fun collidingOwnersReceiveDistinctStableNotificationIds() {
        // "Aa" and "BB" have the same Java/Kotlin String hashCode.
        val allocator = OwnerScopedNotificationIdAllocator(base = 210_000)

        val first = allocator.allocate("Aa")
        val second = allocator.allocate("BB")

        assertNotEquals(first, second)
        assertTrue(first == allocator.allocate("Aa"))
        assertTrue(second == allocator.allocate("BB"))
        allocator.release("Aa")
        assertTrue(second == allocator.allocate("BB"))
    }
}
