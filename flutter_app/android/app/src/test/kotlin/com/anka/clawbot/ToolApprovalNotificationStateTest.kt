package com.anka.clawbot

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
}
