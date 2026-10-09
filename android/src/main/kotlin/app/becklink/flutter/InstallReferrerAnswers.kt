package app.becklink.flutter

import com.android.installreferrer.api.InstallReferrerClient.InstallReferrerResponse

/**
 * The `getInstallReferrer` answers of the platform channel (`doc/platform-channel.md`). Pure
 * functions without Android types, so JVM unit tests can cover the mapping.
 */
internal object InstallReferrerAnswers {
    const val STATUS_OK = "ok"
    const val STATUS_SERVICE_UNAVAILABLE = "service_unavailable"
    const val STATUS_FEATURE_NOT_SUPPORTED = "feature_not_supported"
    const val STATUS_DEVELOPER_ERROR = "developer_error"
    const val STATUS_PERMISSION_ERROR = "permission_error"

    private const val KEY_STATUS = "status"
    private const val KEY_RAW_REFERRER = "raw_referrer"
    private const val KEY_CLICK_TIMESTAMP = "click_timestamp_seconds"
    private const val KEY_INSTALL_BEGIN_TIMESTAMP = "install_begin_timestamp_seconds"

    /** Play's service could not be reached now; a later read may succeed. */
    val serviceUnavailable: Map<String, Any> = mapOf(KEY_STATUS to STATUS_SERVICE_UNAVAILABLE)

    /**
     * Play's answer to a successful read. The referrer goes to Dart unchanged (contract section
     * 9.2); Play's `null` becomes an empty string, which carries no click either. Unknown or
     * nonsensical timestamps become `0`, the contract's "unknown".
     */
    fun found(
        rawReferrer: String?,
        clickTimestampSeconds: Long,
        installBeginTimestampSeconds: Long,
    ): Map<String, Any> =
        mapOf(
            KEY_STATUS to STATUS_OK,
            KEY_RAW_REFERRER to (rawReferrer ?: ""),
            KEY_CLICK_TIMESTAMP to clickTimestampSeconds.coerceAtLeast(0L),
            KEY_INSTALL_BEGIN_TIMESTAMP to installBeginTimestampSeconds.coerceAtLeast(0L),
        )

    /**
     * The answer for a setup response code other than `OK`. `SERVICE_DISCONNECTED` and codes newer
     * than this library version count as `service_unavailable`, the only status Dart may retry, so
     * an unknown code never ends the reading for good.
     */
    fun failure(responseCode: Int): Map<String, Any> =
        mapOf(KEY_STATUS to failureStatus(responseCode))

    fun failureStatus(responseCode: Int): String =
        when (responseCode) {
            InstallReferrerResponse.FEATURE_NOT_SUPPORTED -> STATUS_FEATURE_NOT_SUPPORTED
            InstallReferrerResponse.DEVELOPER_ERROR -> STATUS_DEVELOPER_ERROR
            InstallReferrerResponse.PERMISSION_ERROR -> STATUS_PERMISSION_ERROR
            else -> STATUS_SERVICE_UNAVAILABLE
        }

    /**
     * Whether [answer] is final for this process: a referrer or a permanent failure is kept and
     * returned again; only `service_unavailable` lets a later call read again.
     */
    fun isFinal(answer: Map<String, Any>): Boolean =
        answer[KEY_STATUS] != STATUS_SERVICE_UNAVAILABLE
}
