package com.anka.clawbot

/**
 * Caps runtime permission prompts to one per permission per activity lifetime.
 *
 * A denied permission must not re-open the system dialog on every tool call in
 * the same run (§7.2). Later calls re-check the live grant and return
 * `permission_required` without prompting again, so the user can grant it from
 * Settings and the next call succeeds.
 */
internal class PermissionRequestGuard {
    private val requested = mutableSetOf<String>()

    /** True only for the first ask for [permission]. */
    fun shouldRequest(permission: String): Boolean = requested.add(permission)

    fun reset() {
        requested.clear()
    }
}
