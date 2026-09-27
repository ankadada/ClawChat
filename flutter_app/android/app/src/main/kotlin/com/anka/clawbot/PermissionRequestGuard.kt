package com.anka.clawbot

/** Outcome of one runtime-permission ask. */
internal enum class PermissionAskResult {
    /** Already granted: the action may run. */
    GRANTED,

    /** The system dialog was just raised (at most once per permission). */
    REQUESTED,

    /**
     * Denied before and the system will not show the dialog again, so only
     * Settings can fix it. Re-asking would silently do nothing.
     */
    PERMANENTLY_DENIED,
}

/**
 * Caps runtime permission prompts to one per permission per activity lifetime
 * and classifies a denied permission as permanently denied.
 *
 * A denied permission must not re-open the system dialog on every tool call in
 * the same run (§7.2). Later calls re-check the live grant and return
 * `permission_required` / `permission_permanently_denied` without prompting
 * again, so the user can grant it from Settings and the next call succeeds.
 *
 * `classify` is deliberately free of Android types: the caller passes the two
 * live facts (`granted`, `showRationale`) so the decision is unit-testable.
 */
internal class PermissionRequestGuard {
    private val requested = mutableSetOf<String>()

    /** True only for the first ask for [permission]. */
    fun shouldRequest(permission: String): Boolean = requested.add(permission)

    /**
     * Classifies the current state of [permission].
     *
     * [showRationale] comes from
     * `ActivityCompat.shouldShowRequestPermissionRationale`. It is false both
     * before the first ask and after a permanent denial; the recorded ask tells
     * the two apart.
     */
    fun classify(
        permission: String,
        granted: Boolean,
        showRationale: Boolean,
    ): PermissionAskResult = when {
        granted -> PermissionAskResult.GRANTED
        requested.contains(permission) && !showRationale ->
            PermissionAskResult.PERMANENTLY_DENIED
        else -> PermissionAskResult.REQUESTED
    }

    /** Records that the system dialog for [permission] was raised. */
    fun recordRequested(permission: String) {
        requested.add(permission)
    }

    fun reset() {
        requested.clear()
    }
}
