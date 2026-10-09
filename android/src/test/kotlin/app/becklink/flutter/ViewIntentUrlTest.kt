package app.becklink.flutter

import android.content.Intent
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test

/**
 * `viewIntentUrl()` decides which intents carry a URL delivery to report (doc/platform-channel.md,
 * "Link payload"). Pure, so it runs on the JVM without Android: the `Intent` constants are
 * compile-time constants.
 */
internal class ViewIntentUrlTest {
    private val appLink = "https://acme.becklinks.com/summer24?ref=newsletter"

    @Test
    fun reportsTheUrlOfAViewIntentUnchanged() {
        assertEquals(appLink, viewIntentUrl(Intent.ACTION_VIEW, appLink, 0))
    }

    @Test
    fun reportsEverySchemeAndHostForDartToClassify() {
        val customScheme = "myapp://becklink?url=https%3A%2F%2Facme.becklinks.com%2Fsummer24"
        val oauthCallback = "myapp://oauth/callback?code=abc"

        assertEquals(customScheme, viewIntentUrl(Intent.ACTION_VIEW, customScheme, 0))
        assertEquals(oauthCallback, viewIntentUrl(Intent.ACTION_VIEW, oauthCallback, 0))
    }

    @Test
    fun keepsOtherIntentFlags() {
        val flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP

        assertEquals(appLink, viewIntentUrl(Intent.ACTION_VIEW, appLink, flags))
    }

    @Test
    fun ignoresIntentsThatAreNotViewIntents() {
        assertNull(viewIntentUrl(Intent.ACTION_MAIN, appLink, 0))
        assertNull(viewIntentUrl(Intent.ACTION_SEND, appLink, 0))
        assertNull(viewIntentUrl(null, appLink, 0))
    }

    @Test
    fun ignoresAViewIntentWithoutData() {
        assertNull(viewIntentUrl(Intent.ACTION_VIEW, null, 0))
        assertNull(viewIntentUrl(Intent.ACTION_VIEW, "", 0))
    }

    @Test
    fun ignoresTheReplayedIntentOfAnAppReopenedFromRecents() {
        val fromRecents =
            Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY or Intent.FLAG_ACTIVITY_NEW_TASK

        assertNull(viewIntentUrl(Intent.ACTION_VIEW, appLink, fromRecents))
    }

    @Test
    fun boundsTheUrlLengthAtSixteenKibibytes() {
        val prefix = "https://acme.becklinks.com/x?pad="
        val longest = prefix + "a".repeat(MAX_LINK_URL_LENGTH - prefix.length)
        val tooLong = longest + "a"

        assertEquals(MAX_LINK_URL_LENGTH, longest.length)
        assertEquals(longest, viewIntentUrl(Intent.ACTION_VIEW, longest, 0))
        assertNull(viewIntentUrl(Intent.ACTION_VIEW, tooLong, 0))
    }

    @Test
    fun linkPayloadMatchesTheChannelShapeAndHidesTheUrl() {
        val payload = LinkPayload(appLink, 1_791_374_400_123L)

        assertEquals(
            mapOf<String, Any>("url" to appLink, "received_at_ms" to 1_791_374_400_123L),
            payload.toMap(),
        )
        assertFalse(payload.toString().contains("newsletter"))
    }
}
