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
    /** The exact destination shown to the user, when the tool has one. */
    val detail: String? = null,
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

/// Chooses the notification BigText while an approval is pending.
///
/// When the approval carries an exact destination, BigText must be the
/// approval preview that contains it and must not fall back to the session
/// preview, so a later status update cannot replace the URL.
internal object ApprovalNotificationText {
    fun bigText(
        approvalDetail: String?,
        approvalPreview: String,
        sessionPreview: String
    ): String =
        if (!approvalDetail.isNullOrBlank()) {
            approvalPreview
        } else {
            sessionPreview.ifBlank { approvalPreview }
        }

    /**
     * Lock-screen safe copy for a pending tool approval.
     *
     * This text is what a secure lock screen renders through
     * `Notification.setPublicVersion`. It must stay generic: no approval
     * detail, tool arguments, URL, phone number, or command. The full detail is
     * only in the in-app approval card and the private notification body.
     */
    fun publicCopy(approval: ToolApprovalNotificationState): ToolApprovalPublicCopy =
        if (approval.decisionInFlight) {
            ToolApprovalPublicCopy(
                title = "工具审批等待处理",
                text = "正在提交工具审批决定"
            )
        } else {
            ToolApprovalPublicCopy(
                title = "工具审批等待处理",
                text = "有工具审批等待你的确认，请在应用内查看"
            )
        }
}

/** Lock-screen safe title and body for a waiting tool approval. */
internal data class ToolApprovalPublicCopy(
    val title: String,
    val text: String
)
