package com.anka.clawbot

import android.app.NotificationManager
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationChannelCatalogTest {
    @Test
    fun everyChannelIdIsDistinct() {
        val ids = NotificationChannelCatalog.specs.map { it.id }
        assertEquals(ids.size, ids.toSet().size)
    }

    @Test
    fun statusChannelIsSilent() {
        assertEquals(
            NotificationManager.IMPORTANCE_LOW,
            NotificationChannelCatalog.status.importance,
        )
    }

    @Test
    fun approvalAndCompletionChannelsAlert() {
        // An agent blocked on approval must not sit on a silent channel.
        assertTrue(
            NotificationChannelCatalog.approval.importance >=
                NotificationManager.IMPORTANCE_HIGH,
        )
        assertTrue(
            NotificationChannelCatalog.completion.importance >=
                NotificationManager.IMPORTANCE_HIGH,
        )
        assertNotEquals(
            NotificationChannelCatalog.status.id,
            NotificationChannelCatalog.approval.id,
        )
    }

    @Test
    fun noChannelIsDisabled() {
        NotificationChannelCatalog.specs.forEach { spec ->
            assertNotEquals(
                "channel ${spec.id} must not be IMPORTANCE_NONE",
                NotificationManager.IMPORTANCE_NONE,
                spec.importance,
            )
        }
    }

    @Test
    fun everyChannelKeepsTheLockScreenPrivate() {
        NotificationChannelCatalog.specs.forEach { spec ->
            assertTrue("channel ${spec.id} must stay private", spec.lockscreenPrivate)
        }
    }

    @Test
    fun sessionNotificationUsesTheApprovalChannelOnlyWhenBlocked() {
        assertEquals(
            NotificationChannelCatalog.approval.id,
            NotificationChannelCatalog.forSession(needsUserAction = true).id,
        )
        assertEquals(
            NotificationChannelCatalog.status.id,
            NotificationChannelCatalog.forSession(needsUserAction = false).id,
        )
        assertEquals(
            NotificationChannelCatalog.approval.id,
            NotificationChannelCatalog.forBackgroundTask(needsReview = true).id,
        )
        assertEquals(
            NotificationChannelCatalog.status.id,
            NotificationChannelCatalog.forBackgroundTask(needsReview = false).id,
        )
    }
}
