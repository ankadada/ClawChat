package com.anka.clawbot

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ToolApprovalNotificationStateTest {
    @Test
    fun disabledPermissionManagerOrChannelCannotEnterHiddenWait() {
        assertTrue(
            ToolApprovalNotificationCapability.isVisible(true, true, true, true)
        )
        assertFalse(
            ToolApprovalNotificationCapability.isVisible(false, true, true, true)
        )
        assertFalse(
            ToolApprovalNotificationCapability.isVisible(true, false, true, true)
        )
        assertFalse(
            ToolApprovalNotificationCapability.isVisible(true, true, false, true)
        )
        assertFalse(
            ToolApprovalNotificationCapability.isVisible(true, true, true, false)
        )
    }

    @Test
    fun pendingIntentIdentityCannotRetargetAcrossSessionOperationOrDecision() {
        val firstApprove = ToolApprovalPendingIntentIdentity.create(
            "approval",
            "session-a",
            "operation-a",
            true
        )
        val firstDeny = ToolApprovalPendingIntentIdentity.create(
            "approval",
            "session-a",
            "operation-a",
            false
        )
        val secondSession = ToolApprovalPendingIntentIdentity.create(
            "approval",
            "session-b",
            "operation-a",
            true
        )
        val secondOperation = ToolApprovalPendingIntentIdentity.create(
            "approval",
            "session-a",
            "operation-b",
            true
        )

        assertFalse(firstApprove == firstDeny)
        assertFalse(firstApprove == secondSession)
        assertFalse(firstApprove == secondOperation)
    }

    @Test
    fun callbackOwnershipDetachesExactlyAndRejectsLateOldOwner() {
        val ownership = ToolApprovalCallbackOwnership<Any>()
        val first = Any()
        val second = Any()
        val firstAttachment = ownership.attach(first)
        val secondAttachment = ownership.attach(second)

        assertTrue(
            secondAttachment.invalidatedGeneration ==
                firstAttachment.owner.generation
        )
        assertTrue(ownership.current?.value === second)
        assertTrue(
            ownership.detach(first, firstAttachment.owner.generation) == null
        )
        assertTrue(ownership.current?.value === second)
        assertTrue(
            ownership.detach(second, secondAttachment.owner.generation) ==
                secondAttachment.owner.generation
        )
        assertTrue(ownership.current == null)
    }

    @Test
    fun exactDecisionIsSingleFlightAndRetryableAfterDeliveryFailure() {
        val state = ToolApprovalNotificationState(
            sessionId = "session-a",
            approvalId = "run-a:operation-a",
            toolName = "bash",
            risk = "dangerous"
        )

        assertTrue(state.beginDecision("session-a", "run-a:operation-a", 1))
        assertFalse(state.beginDecision("session-a", "run-a:operation-a", 1))
        assertFalse(state.deliveryFailed(2))
        assertTrue(state.deliveryFailed(1))
        assertTrue(state.beginDecision("session-a", "run-a:operation-a", 2))
        assertFalse(state.acknowledge(1))
        assertTrue(state.acknowledge(2))
    }

    @Test
    fun staleSessionAndOperationCannotResolveCurrentApproval() {
        val state = ToolApprovalNotificationState(
            sessionId = "session-a",
            approvalId = "operation-a",
            toolName = "bash",
            risk = "dangerous"
        )

        assertFalse(state.beginDecision("session-b", "operation-a", 1))
        assertFalse(state.beginDecision("session-a", "operation-b", 1))
        assertTrue(state.beginDecision("session-a", "operation-a", 1))
    }

    @Test
    fun bigTextPrefersTheApprovalPreviewWhileADetailIsPending() {
        val preview = "web_fetch (moderate) 等待你的明确批准：https://evil.example/x"

        // A pending approval with a URL keeps the approval preview, even when
        // a later status update changed the session preview.
        assertEquals(
            preview,
            ApprovalNotificationText.bigText(
                "https://evil.example/x",
                preview,
                "tooling · 正在读取日历"
            )
        )

        // Without a detail the session preview is used, falling back to the
        // approval preview when the session preview is blank.
        assertEquals(
            "session body",
            ApprovalNotificationText.bigText(null, preview, "session body")
        )
        assertEquals(
            preview,
            ApprovalNotificationText.bigText(null, preview, "")
        )
    }

    @Test
    fun lockScreenCopyNeverContainsTheApprovalDetailOrArguments() {
        val detail = "https://evil.example/x?phone=+15551234567&cmd=rm%20-rf%20/root"
        val state = ToolApprovalNotificationState(
            sessionId = "session-a",
            approvalId = "approval-a",
            toolName = "bash",
            risk = "high",
            detail = detail
        )

        val copy = ApprovalNotificationText.publicCopy(state)
        val leaked = listOf(
            detail,
            "https://",
            "evil.example",
            "+15551234567",
            "rm -rf",
            "rm%20-rf",
            "/root",
            "bash",
            "high"
        )
        for (fragment in leaked) {
            assertFalse("public title leaked $fragment", copy.title.contains(fragment))
            assertFalse("public text leaked $fragment", copy.text.contains(fragment))
        }
        assertTrue(copy.title.contains("工具审批"))
        assertTrue(copy.text.contains("工具审批"))

        // The in-flight variant stays generic too.
        val inFlight = ToolApprovalNotificationState(
            sessionId = "session-a",
            approvalId = "approval-a",
            toolName = "bash",
            risk = "high",
            detail = detail
        )
        assertTrue(inFlight.beginDecision("session-a", "approval-a", 1L))
        val inFlightCopy = ApprovalNotificationText.publicCopy(inFlight)
        assertFalse(inFlightCopy.title.contains(detail))
        assertFalse(inFlightCopy.text.contains(detail))
        assertFalse(inFlightCopy.text.contains("bash"))
    }

    @Test
    fun lockScreenCopyNeverLeaksACredentialBearingDestination() {
        // A destination that embeds a credential, a phone number and a command.
        val detail =
            "https://api.example/v1?api_key=sk-live-9f8e7d6c5b4a&token=Bearer%20abc123" +
                "&cmd=curl%20-H%20%22Authorization:%20Bearer%20xyz%22%20/root/.env"
        val state = ToolApprovalNotificationState(
            sessionId = "session-secret",
            approvalId = "approval-secret",
            toolName = "web_fetch",
            risk = "high",
            detail = detail
        )

        val copy = ApprovalNotificationText.publicCopy(state)
        val secrets = listOf(
            detail,
            "sk-live-9f8e7d6c5b4a",
            "api_key",
            "token",
            "Bearer",
            "abc123",
            "Authorization",
            "/root/.env",
            "web_fetch",
            "session-secret",
            "approval-secret"
        )
        for (fragment in secrets) {
            assertFalse("public title leaked $fragment", copy.title.contains(fragment))
            assertFalse("public text leaked $fragment", copy.text.contains(fragment))
        }

        // The unlocked BigText deliberately keeps the destination (the user must
        // confirm it), so this asserts the lock screen is what stays generic.
        assertEquals(
            "确认工具审批",
            ApprovalNotificationText.bigText(
                detail,
                "确认工具审批",
                "session preview"
            )
        )
    }
}
