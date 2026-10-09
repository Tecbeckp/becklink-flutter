package app.becklink.flutter

import android.content.Intent

/**
 * One delivery of a URL by the operating system, in the shape of the platform channel's link
 * payload (`doc/platform-channel.md`, "Link payload").
 *
 * [receivedAtMs] is stamped once, when the native layer takes the URL from its intent, and never
 * again: it is the direct open's `opened_at`, and together with [url] it lets Dart's dedupe tell
 * one delivery reported twice from the same link opened twice.
 */
internal class LinkPayload(
    val url: String,
    val receivedAtMs: Long,
) {
    fun toMap(): Map<String, Any> =
        mapOf(
            KEY_URL to url,
            KEY_RECEIVED_AT_MS to receivedAtMs,
        )

    // The query string can carry user data (contract section 12), so the URL is never printed.
    override fun toString(): String =
        "LinkPayload(urlLength=${url.length}, receivedAtMs=$receivedAtMs)"

    private companion object {
        const val KEY_URL = "url"
        const val KEY_RECEIVED_AT_MS = "received_at_ms"
    }
}

/**
 * Longest URL handed to Dart, in UTF-16 code units, matching Dart's `maxPlatformUrlLength`. Far
 * above any real link; it only bounds what another app can push into this one through a crafted
 * intent.
 */
internal const val MAX_LINK_URL_LENGTH = 16 * 1024

/**
 * The URL an intent delivers, or `null` when it delivers nothing to report:
 * - not `ACTION_VIEW`, or no data, or a URL longer than [MAX_LINK_URL_LENGTH];
 * - `FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY`: Android replays the task's original intent when the
 *   user reopens the app from Recents, and that URL was reported when it first arrived.
 *
 * Every scheme and host is reported (App Links and custom schemes alike): Dart decides which URLs
 * are Beck Link URLs (contract section 9.1) and never sends the others anywhere.
 */
internal fun viewIntentUrl(
    action: String?,
    dataString: String?,
    flags: Int,
): String? {
    if (action != Intent.ACTION_VIEW) return null
    if ((flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0) return null
    if (dataString.isNullOrEmpty() || dataString.length > MAX_LINK_URL_LENGTH) return null
    return dataString
}
