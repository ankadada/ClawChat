package com.anka.clawbot

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationPrivacyTest {
    private val sensitiveFragments = listOf(
        "http://",
        "https://",
        "@",
        "/root",
        "rm -rf",
        "session",
        "会话",
        "127.0.0.1",
        "+1",
        "tool:",
        "bash",
    )

    @Test
    fun everyAgentStatusHasAGenericLockScreenCopy() {
        val copies = listOf(
            "thinking",
            "streaming",
            "tooling",
            "complete",
            "error",
            "unknown-status",
        ).map { NotificationPrivacy.sessionStatus(it) }

        for (copy in copies) {
            assertEquals("ClawChat", copy.title)
            assertTrue(copy.text.isNotBlank())
            for (fragment in sensitiveFragments) {
                assertFalse(
                    "status copy leaked $fragment",
                    copy.title.contains(fragment) || copy.text.contains(fragment)
                )
            }
        }
        assertTrue(
            NotificationPrivacy.sessionStatus("complete").text.contains("完成")
        )
        assertTrue(NotificationPrivacy.sessionStatus("error").text.contains("出错"))
    }

    @Test
    fun backgroundTaskSummaryAndCompletionCopiesStayGeneric() {
        val needsReview = NotificationPrivacy.backgroundTask(needsReview = true)
        val running = NotificationPrivacy.backgroundTask(needsReview = false)
        val summary = NotificationPrivacy.summary(activeCount = 3)
        val completion = NotificationPrivacy.completion()
        val autoApproved = NotificationPrivacy.toolAutoApproved()

        assertFalse(needsReview.text == running.text)
        assertTrue(summary.text.contains("3"))
        assertTrue(completion.text.contains("完成"))

        for (copy in listOf(needsReview, running, summary, completion, autoApproved)) {
            assertEquals("ClawChat", copy.title)
            assertTrue(copy.text.isNotBlank())
            for (fragment in sensitiveFragments) {
                assertFalse(
                    "public copy leaked $fragment",
                    copy.title.contains(fragment) || copy.text.contains(fragment)
                )
            }
        }
    }
}
