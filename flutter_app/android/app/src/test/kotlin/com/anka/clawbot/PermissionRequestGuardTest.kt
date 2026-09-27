package com.anka.clawbot

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
}
