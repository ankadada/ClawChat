package com.anka.clawbot

import java.net.URLEncoder
import java.nio.charset.StandardCharsets

internal data class ToolApprovalPendingIntentIdentity(
    val action: String,
    val data: String
) {
    companion object {
        fun create(
            actionPrefix: String,
            sessionId: String,
            approvalId: String,
            approved: Boolean
        ): ToolApprovalPendingIntentIdentity {
            val decision = if (approved) "approve" else "deny"
            fun encode(value: String): String = URLEncoder.encode(
                value,
                StandardCharsets.UTF_8.name()
            ).replace("+", "%20")
            return ToolApprovalPendingIntentIdentity(
                action = "$actionPrefix.${decision.uppercase()}",
                data = "clawchat-approval://${encode(sessionId)}/${encode(approvalId)}/$decision"
            )
        }
    }
}

internal object ToolApprovalNotificationCapability {
    fun isVisible(
        permissionGranted: Boolean,
        notificationsEnabled: Boolean,
        channelExists: Boolean,
        channelEnabled: Boolean
    ): Boolean = permissionGranted &&
        notificationsEnabled &&
        channelExists &&
        channelEnabled
}

internal class ToolApprovalCallbackOwnership<T : Any> {
    data class Owner<T>(val generation: Long, val value: T)
    data class Attachment<T>(
        val owner: Owner<T>,
        val invalidatedGeneration: Long?
    )

    private var nextGeneration = 0L
    var current: Owner<T>? = null
        private set

    fun attach(value: T): Attachment<T> {
        val previous = current
        val owner = Owner(++nextGeneration, value)
        current = owner
        return Attachment(owner, previous?.generation)
    }

    fun detach(value: T, generation: Long): Long? {
        val owner = current
        if (owner?.value !== value || owner.generation != generation) return null
        current = null
        return generation
    }
}

internal data class ToolApprovalNotificationState(
    val sessionId: String,
    val approvalId: String,
    val toolName: String,
    val risk: String,
    private var deliveryOwnerGeneration: Long? = null
) {
    val decisionInFlight: Boolean
        get() = deliveryOwnerGeneration != null

    fun beginDecision(
        sessionId: String,
        approvalId: String,
        ownerGeneration: Long
    ): Boolean {
        if (decisionInFlight ||
            this.sessionId != sessionId ||
            this.approvalId != approvalId) {
            return false
        }
        deliveryOwnerGeneration = ownerGeneration
        return true
    }

    fun acknowledge(ownerGeneration: Long): Boolean {
        if (deliveryOwnerGeneration != ownerGeneration) return false
        deliveryOwnerGeneration = null
        return true
    }

    fun deliveryFailed(ownerGeneration: Long): Boolean {
        if (deliveryOwnerGeneration != ownerGeneration) return false
        deliveryOwnerGeneration = null
        return true
    }
}
