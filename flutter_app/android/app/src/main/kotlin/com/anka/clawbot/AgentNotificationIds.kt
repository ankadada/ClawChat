package com.anka.clawbot

/**
 * Notification ids for agent sessions.
 *
 * Each session owns a stable, distinct id in both the foreground-service range
 * and the completion range, so parallel sessions never overwrite each other's
 * notification and a completion notice cannot replace a live run's notice.
 */
internal object AgentNotificationIds {
    /** Foreground/status notification id for one session. */
    fun session(sessionId: String): Int =
        (sessionId.hashCode() and 0x7FFFFFFF) % 100000 + 10000

    /** Completion notification id for one session. */
    fun completion(sessionId: String): Int =
        (sessionId.hashCode() and 0x7FFFFFFF) % 100000 + 110000
}
