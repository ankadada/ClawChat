package com.anka.clawbot

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PickedContentLimitsTest {
    @Test
    fun theCapMatchesTheDartWorkspaceImportBudget() {
        // AttachmentBudget.maxWorkspaceImportBytes is 50 MiB on the Dart side.
        assertEquals(50L * 1024L * 1024L, PickedContentLimits.MAX_BYTES)
    }

    @Test
    fun limitsOutsideOneByteToTheCapAreInvalid() {
        assertFalse(PickedContentLimits.isValidLimit(0))
        assertFalse(PickedContentLimits.isValidLimit(-1))
        assertFalse(PickedContentLimits.isValidLimit(PickedContentLimits.MAX_BYTES + 1))
        assertTrue(PickedContentLimits.isValidLimit(1))
        assertTrue(PickedContentLimits.isValidLimit(PickedContentLimits.MAX_BYTES))
    }

    @Test
    fun aDeclaredSizeAboveTheLimitIsRejectedBeforeOpeningTheStream() {
        val limit = 25L * 1024L * 1024L
        assertTrue(PickedContentLimits.exceedsDeclaredLimit(60L * 1024L * 1024L, limit))
        assertFalse(PickedContentLimits.exceedsDeclaredLimit(limit, limit))
        assertFalse(PickedContentLimits.exceedsDeclaredLimit(limit - 1, limit))
        // An unknown declared size is not proof of anything: the streamed
        // counter still bounds the copy.
        assertFalse(PickedContentLimits.exceedsDeclaredLimit(null, limit))
        assertTrue(PickedContentLimits.exceedsStreamedLimit(limit + 1, limit))
        assertFalse(PickedContentLimits.exceedsStreamedLimit(limit, limit))
    }

    @Test
    fun theTooLargeErrorCarriesBothNumbers() {
        val error = PickedContentTooLargeException(
            limitBytes = PickedContentLimits.MAX_BYTES,
            actualBytes = 60L * 1024L * 1024L,
        )
        assertEquals(PickedContentLimits.MAX_BYTES, error.limitBytes)
        assertEquals(60L * 1024L * 1024L, error.actualBytes)
    }

    @Test
    fun errorCodesAreDistinctFromTheGenericPlatformCodes() {
        val codes = setOf(
            PickedContentLimits.ERROR_INVALID,
            PickedContentLimits.ERROR_TOO_LARGE,
            PickedContentLimits.ERROR_UNAVAILABLE,
        )
        assertEquals(3, codes.size)
        assertFalse(codes.contains("INVALID_ARGS"))
        assertFalse(codes.contains("PICKED_CONTENT_ERROR"))
    }
}
