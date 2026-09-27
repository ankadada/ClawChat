package com.anka.clawbot

import android.app.Notification
import android.content.Context
import android.os.Build

/** Lock-screen safe title and body for a notification. */
internal data class PublicNotificationCopy(
    val title: String,
    val text: String
)

/**
 * Lock-screen copy shared by every agent notification.
 *
 * A notification that carries user content (a reply preview, a session title,
 * a command, a URL, or a phone number) must be `VISIBILITY_PRIVATE` and must
 * provide a `publicVersion` built from one of these generic copies. The public
 * version is what a secure lock screen renders, so the functions here never
 * receive or return the sensitive text itself.
 */
internal object NotificationPrivacy {
    private const val APP_NAME = "ClawChat"

    fun sessionStatus(status: String): PublicNotificationCopy = when (status) {
        "complete" -> PublicNotificationCopy(APP_NAME, "机器任务完成，请在应用内查看")
        "error" -> PublicNotificationCopy(APP_NAME, "机器任务出错，请在应用内查看")
        "thinking" -> PublicNotificationCopy(APP_NAME, "机器正在执行任务")
        "streaming" -> PublicNotificationCopy(APP_NAME, "机器正在执行任务")
        "tooling" -> PublicNotificationCopy(APP_NAME, "机器正在执行任务")
        else -> PublicNotificationCopy(APP_NAME, "机器正在执行任务")
    }

    fun backgroundTask(needsReview: Boolean): PublicNotificationCopy =
        if (needsReview) {
            PublicNotificationCopy(APP_NAME, "有后台任务等待处理，请在应用内查看")
        } else {
            PublicNotificationCopy(APP_NAME, "后台任务正在执行")
        }

    /**
     * The multi-task group summary never carries a session title: a group
     * summary can surface on a lock screen, and titles are user content.
     */
    fun summary(activeCount: Int): PublicNotificationCopy =
        PublicNotificationCopy(APP_NAME, "$activeCount 个机器任务运行中")

    fun completion(): PublicNotificationCopy =
        PublicNotificationCopy(APP_NAME, "机器任务完成，请在应用内查看")

    fun toolAutoApproved(): PublicNotificationCopy =
        PublicNotificationCopy(APP_NAME, "有工具已自动允许执行，请在应用内查看")
}

/**
 * Builds the redacted copy the system shows on a lock screen for a
 * [Notification.VISIBILITY_PRIVATE] notification. It intentionally has no
 * content intent and no actions: tapping it only opens the app through the
 * private notification once the device is unlocked.
 */
@Suppress("DEPRECATION")
internal fun buildPublicNotification(
    context: Context,
    channelId: String,
    copy: PublicNotificationCopy
): Notification {
    val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        Notification.Builder(context, channelId)
    } else {
        Notification.Builder(context)
    }
    return builder
        .setSmallIcon(R.mipmap.ic_launcher)
        .setContentTitle(copy.title)
        .setContentText(copy.text)
        .setOnlyAlertOnce(true)
        .setCategory(Notification.CATEGORY_SERVICE)
        .setPriority(Notification.PRIORITY_LOW)
        .setVisibility(Notification.VISIBILITY_PRIVATE)
        .build()
}
