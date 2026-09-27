package com.anka.clawbot

import android.app.NotificationManager

/**
 * One Android notification channel: identity plus the alert behaviour that
 * Android freezes at creation time.
 */
internal data class NotificationChannelSpec(
    val id: String,
    val name: String,
    val description: String,
    val importance: Int,
    /** Lock screen copy never carries session text; enforced per notification. */
    val lockscreenPrivate: Boolean = true,
) {
    companion object {
        /** Android refuses to re-tune a channel, so ids are versioned. */
        const val LEGACY_MAIN_ID = "clawchat_main"
        const val STATUS_ID = "clawchat_status_v2"
        const val APPROVAL_ID = "clawchat_approval_v1"
        const val COMPLETION_ID = "clawchat_agent_complete_v2"
    }
}

/**
 * Channel classification (§5 AND-4): progress/status notifications stay silent,
 * while anything that waits on the user (tool approval, background task review,
 * finished reply) uses an alerting channel.
 *
 * Approval prompts previously shared the low-importance status channel, so the
 * device could stay silent while an agent was blocked on a decision. The
 * separation below is the fix and is unit-tested with plain JVM assertions.
 */
internal object NotificationChannelCatalog {
    val status = NotificationChannelSpec(
        id = NotificationChannelSpec.STATUS_ID,
        name = "ClawChat 运行状态",
        description = "会话进度与后台任务状态，静默更新",
        importance = NotificationManager.IMPORTANCE_LOW,
    )

    val approval = NotificationChannelSpec(
        id = NotificationChannelSpec.APPROVAL_ID,
        name = "ClawChat 待确认操作",
        description = "需要你确认的工具审批与后台任务复查",
        importance = NotificationManager.IMPORTANCE_HIGH,
    )

    val completion = NotificationChannelSpec(
        id = NotificationChannelSpec.COMPLETION_ID,
        name = "ClawChat Agent",
        description = "AI 任务完成提醒",
        importance = NotificationManager.IMPORTANCE_HIGH,
    )

    /** Legacy channel kept so already-posted notifications stay updatable. */
    val legacyMain = NotificationChannelSpec(
        id = NotificationChannelSpec.LEGACY_MAIN_ID,
        name = "ClawChat",
        description = "旧版通知通道（仅用于更新既有通知）",
        importance = NotificationManager.IMPORTANCE_LOW,
    )

    val specs: List<NotificationChannelSpec> =
        listOf(status, approval, completion, legacyMain)

    /** Channel for a session/task notification that may be blocked on a user. */
    fun forSession(needsUserAction: Boolean): NotificationChannelSpec =
        if (needsUserAction) approval else status

    fun forBackgroundTask(needsReview: Boolean): NotificationChannelSpec =
        if (needsReview) approval else status
}
