package com.anka.clawbot

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class AgentNotificationIdsTest {
    @Test
    fun eachSessionKeepsAStableId() {
        assertEquals(
            AgentNotificationIds.session("session-a"),
            AgentNotificationIds.session("session-a"),
        )
        assertEquals(
            AgentNotificationIds.completion("session-a"),
            AgentNotificationIds.completion("session-a"),
        )
    }

    @Test
    fun parallelSessionsDoNotCollide() {
        val sessions = List(64) { "parallel-session-$it" }
        val statusIds = sessions.map { AgentNotificationIds.session(it) }
        val completionIds = sessions.map { AgentNotificationIds.completion(it) }
        assertEquals(sessions.size, statusIds.toSet().size)
        assertEquals(sessions.size, completionIds.toSet().size)
        // A completion notice must never replace a live run's notice.
        assertEquals(
            emptySet<Int>(),
            statusIds.toSet().intersect(completionIds.toSet()),
        )
    }

    @Test
    fun idsStayInPositiveAndroidRanges() {
        for (session in listOf("a", "session-with-a-very-long-name-1234567890", "")) {
            val status = AgentNotificationIds.session(session)
            val completion = AgentNotificationIds.completion(session)
            assert(status in 10000..109999) { "status id out of range: $status" }
            assert(completion in 110000..209999) {
                "completion id out of range: $completion"
            }
            assertNotEquals(status, completion)
        }
    }
}
