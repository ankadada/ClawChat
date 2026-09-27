package com.anka.clawbot

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PermissionRequestGuardTest {
    @Test
    fun eachPermissionIsRequestedAtMostOnce() {
        val guard = PermissionRequestGuard()
        assertTrue(guard.shouldRequest("android.permission.READ_SMS"))
        assertFalse(guard.shouldRequest("android.permission.READ_SMS"))
        assertFalse(guard.shouldRequest("android.permission.READ_SMS"))
    }

    @Test
    fun distinctPermissionsTrackIndependently() {
        val guard = PermissionRequestGuard()
        assertTrue(guard.shouldRequest("android.permission.READ_SMS"))
        assertTrue(guard.shouldRequest("android.permission.READ_CONTACTS"))
        assertFalse(guard.shouldRequest("android.permission.READ_SMS"))
    }

    @Test
    fun resetAllowsAReask() {
        val guard = PermissionRequestGuard()
        assertTrue(guard.shouldRequest("android.permission.READ_SMS"))
        guard.reset()
        assertTrue(guard.shouldRequest("android.permission.READ_SMS"))
    }

    @Test
    fun grantedPermissionNeedsNoAsk() {
        val guard = PermissionRequestGuard()
        assertEquals(
            PermissionAskResult.GRANTED,
            guard.classify("android.permission.READ_SMS", granted = true, showRationale = false),
        )
    }

    @Test
    fun firstAskIsRequested() {
        val guard = PermissionRequestGuard()
        assertEquals(
            PermissionAskResult.REQUESTED,
            guard.classify("android.permission.READ_SMS", granted = false, showRationale = false),
        )
    }

    @Test
    fun deniedWithVisibleRationaleStaysRecoverable() {
        val guard = PermissionRequestGuard()
        assertTrue(guard.shouldRequest("android.permission.READ_SMS"))
        assertEquals(
            // The dialog can still be shown again, so this is a normal denial.
            PermissionAskResult.REQUESTED,
            guard.classify("android.permission.READ_SMS", granted = false, showRationale = true),
        )
    }

    @Test
    fun deniedWithoutRationaleIsPermanentlyDenied() {
        val guard = PermissionRequestGuard()
        assertTrue(guard.shouldRequest("android.permission.READ_SMS"))
        assertEquals(
            // Asked once, refused, and the system will not show the dialog
            // again: only Settings can fix it.
            PermissionAskResult.PERMANENTLY_DENIED,
            guard.classify("android.permission.READ_SMS", granted = false, showRationale = false),
        )
    }

    @Test
    fun revocationAfterGrantIsReportedAsRequestedAgain() {
        val guard = PermissionRequestGuard()
        assertTrue(guard.shouldRequest("android.permission.READ_CONTACTS"))
        // Granted, then revoked from Settings while the run was alive.
        assertEquals(
            PermissionAskResult.REQUESTED,
            guard.classify("android.permission.READ_CONTACTS", granted = false, showRationale = true),
        )
        assertFalse(
            // The re-ask is still capped at one dialog per activity lifetime.
            guard.shouldRequest("android.permission.READ_CONTACTS"),
        )
    }

    @Test
    fun resetClearsPermanentDenialClassification() {
        val guard = PermissionRequestGuard()
        guard.shouldRequest("android.permission.READ_SMS")
        guard.reset()
        assertEquals(
            PermissionAskResult.REQUESTED,
            guard.classify("android.permission.READ_SMS", granted = false, showRationale = false),
        )
    }
}
