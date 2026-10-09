package app.becklink.flutter

import com.android.installreferrer.api.InstallReferrerClient.InstallReferrerResponse
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * The `getInstallReferrer` answers (doc/platform-channel.md): how Play's results map to the
 * statuses Dart reads (`readInstallReferrer`), and which of them end the reading for the process.
 */
internal class InstallReferrerAnswersTest {
    private val referrer = "click_id=01K6ZPWR5N7Y3A9S2D4F6G8HJK"

    @Test
    fun foundPassesTheReferrerUnchangedWithItsTimestamps() {
        val answer = InstallReferrerAnswers.found(referrer, 1_791_374_400L, 1_791_374_460L)

        assertEquals(
            mapOf<String, Any>(
                "status" to "ok",
                "raw_referrer" to referrer,
                "click_timestamp_seconds" to 1_791_374_400L,
                "install_begin_timestamp_seconds" to 1_791_374_460L,
            ),
            answer,
        )
    }

    @Test
    fun foundTurnsAMissingReferrerIntoAnEmptyString() {
        val answer = InstallReferrerAnswers.found(null, 0L, 0L)

        assertEquals("", answer["raw_referrer"])
        assertEquals("ok", answer["status"])
    }

    @Test
    fun foundReportsNegativeTimestampsAsUnknown() {
        val answer = InstallReferrerAnswers.found(referrer, -5L, -1L)

        assertEquals(0L, answer["click_timestamp_seconds"])
        assertEquals(0L, answer["install_begin_timestamp_seconds"])
    }

    @Test
    fun mapsPermanentSetupFailuresToTheirStatus() {
        assertEquals(
            "feature_not_supported",
            InstallReferrerAnswers.failureStatus(InstallReferrerResponse.FEATURE_NOT_SUPPORTED),
        )
        assertEquals(
            "developer_error",
            InstallReferrerAnswers.failureStatus(InstallReferrerResponse.DEVELOPER_ERROR),
        )
        assertEquals(
            "permission_error",
            InstallReferrerAnswers.failureStatus(InstallReferrerResponse.PERMISSION_ERROR),
        )
    }

    @Test
    fun mapsPassingAndUnknownFailuresToServiceUnavailable() {
        for (code in listOf(
            InstallReferrerResponse.SERVICE_UNAVAILABLE,
            InstallReferrerResponse.SERVICE_DISCONNECTED,
            // A code newer than this library version must never end the reading for good.
            99,
        )) {
            assertEquals(
                mapOf<String, Any>("status" to "service_unavailable"),
                InstallReferrerAnswers.failure(code),
            )
        }
    }

    @Test
    fun onlyServiceUnavailableLetsALaterCallReadAgain() {
        assertFalse(InstallReferrerAnswers.isFinal(InstallReferrerAnswers.serviceUnavailable))
        assertTrue(InstallReferrerAnswers.isFinal(InstallReferrerAnswers.found(referrer, 0L, 0L)))
        assertTrue(
            InstallReferrerAnswers.isFinal(
                InstallReferrerAnswers.failure(InstallReferrerResponse.FEATURE_NOT_SUPPORTED),
            ),
        )
        assertTrue(
            InstallReferrerAnswers.isFinal(
                InstallReferrerAnswers.failure(InstallReferrerResponse.PERMISSION_ERROR),
            ),
        )
    }
}
