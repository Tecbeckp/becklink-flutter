package app.becklink.flutter

import android.content.Context
import android.os.RemoteException
import com.android.installreferrer.api.InstallReferrerClient
import com.android.installreferrer.api.InstallReferrerClient.InstallReferrerResponse
import com.android.installreferrer.api.InstallReferrerStateListener
import io.flutter.plugin.common.MethodChannel

/**
 * Reads the Google Play Install Referrer (AND-005, contract section 9.2) with Google's
 * `installreferrer` library, as `doc/platform-channel.md` describes for `getInstallReferrer`:
 * - at most one read at a time per process: concurrent calls share it;
 * - a referrer or a permanent failure is kept for the process and answered again without IPC;
 *   only `service_unavailable` lets a later call read again;
 * - a service that disconnects is connected once more (Play may update itself in the background);
 * - the whole read, the retry included, is bounded by [READ_TIMEOUT_MS];
 * - every connection is ended, whatever the outcome.
 *
 * The state lives on the main thread, where the library delivers its callbacks. Only the referrer
 * request itself, a synchronous IPC into the Play Store's process, runs in the background. Never
 * throws: a device without the Play Store answers `service_unavailable` from the library.
 */
internal class InstallReferrerReader private constructor(
    private val context: Context,
) {
    private var finalAnswer: Map<String, Any>? = null
    private val waiting = mutableListOf<MethodChannel.Result>()
    private var reading = false
    private var connection: Connection? = null
    private var pendingRetry: Runnable? = null
    private val deadline = Runnable { finish(InstallReferrerAnswers.serviceUnavailable) }

    /** One connection attempt; callbacks of an attempt that is no longer [connection] are stale. */
    private class Connection(
        val client: InstallReferrerClient,
        val retriesLeft: Int,
    )

    fun read(result: MethodChannel.Result) {
        val known = finalAnswer
        if (known != null) {
            result.success(known)
            return
        }
        waiting.add(result)
        if (reading) return
        reading = true
        NativeThreads.main.postDelayed(deadline, READ_TIMEOUT_MS)
        connect(MAX_RETRIES)
    }

    private fun connect(retriesLeft: Int) {
        val client =
            try {
                InstallReferrerClient.newBuilder(context).build()
            } catch (e: RuntimeException) {
                finish(InstallReferrerAnswers.serviceUnavailable)
                return
            }
        val attempt = Connection(client, retriesLeft)
        connection = attempt
        val listener =
            object : InstallReferrerStateListener {
                // Posted even when already on the main thread: the library may call back from
                // inside startConnection, and this keeps the state changes out of that call.
                override fun onInstallReferrerSetupFinished(responseCode: Int) {
                    NativeThreads.onMain { onSetupFinished(attempt, responseCode) }
                }

                override fun onInstallReferrerServiceDisconnected() {
                    NativeThreads.onMain { onDisconnected(attempt) }
                }
            }
        try {
            client.startConnection(listener)
        } catch (e: RuntimeException) {
            // A refused bind (SecurityException on some devices) is the contract's "bind failure".
            finish(InstallReferrerAnswers.serviceUnavailable)
        }
    }

    private fun onSetupFinished(
        attempt: Connection,
        responseCode: Int,
    ) {
        if (attempt !== connection) return
        when (responseCode) {
            InstallReferrerResponse.OK -> requestReferrer(attempt)
            InstallReferrerResponse.SERVICE_DISCONNECTED -> retryOrGiveUp(attempt)
            else -> finish(InstallReferrerAnswers.failure(responseCode))
        }
    }

    private fun onDisconnected(attempt: Connection) {
        if (attempt !== connection) return
        retryOrGiveUp(attempt)
    }

    private fun requestReferrer(attempt: Connection) {
        NativeThreads.runInBackground {
            // null: the service went away during the request, which a new connection may fix.
            val answer: Map<String, Any>? =
                try {
                    val details = attempt.client.installReferrer
                    InstallReferrerAnswers.found(
                        rawReferrer = details.installReferrer,
                        clickTimestampSeconds = details.referrerClickTimestampSeconds,
                        installBeginTimestampSeconds = details.installBeginTimestampSeconds,
                    )
                } catch (e: RemoteException) {
                    null
                } catch (e: IllegalStateException) {
                    // The library's "not connected": the service disconnected before the request.
                    null
                } catch (e: RuntimeException) {
                    // Also the late outcome of a request the deadline already ended, which is
                    // stale below.
                    InstallReferrerAnswers.serviceUnavailable
                }
            NativeThreads.onMain {
                if (attempt === connection) {
                    if (answer == null) retryOrGiveUp(attempt) else finish(answer)
                }
            }
        }
    }

    private fun retryOrGiveUp(attempt: Connection) {
        close(attempt)
        if (attempt.retriesLeft <= 0) {
            finish(InstallReferrerAnswers.serviceUnavailable)
            return
        }
        // A short pause: a disconnect usually means the Play Store is restarting after an update.
        val retry =
            Runnable {
                pendingRetry = null
                connect(attempt.retriesLeft - 1)
            }
        pendingRetry = retry
        NativeThreads.main.postDelayed(retry, RETRY_DELAY_MS)
    }

    private fun finish(answer: Map<String, Any>) {
        NativeThreads.main.removeCallbacks(deadline)
        pendingRetry?.let { NativeThreads.main.removeCallbacks(it) }
        pendingRetry = null
        connection?.let { close(it) }
        reading = false
        if (InstallReferrerAnswers.isFinal(answer)) finalAnswer = answer
        val replies = waiting.toList()
        waiting.clear()
        replies.forEach { it.success(answer) }
    }

    private fun close(attempt: Connection) {
        if (connection === attempt) connection = null
        try {
            attempt.client.endConnection()
        } catch (e: RuntimeException) {
            // Never bound, or already unbound by the system; nothing is left to release.
        }
    }

    companion object {
        /** The native wait for one read, the retry included; Dart itself waits 15 s. */
        private const val READ_TIMEOUT_MS = 10_000L
        private const val RETRY_DELAY_MS = 1_000L
        private const val MAX_RETRIES = 1

        private var shared: InstallReferrerReader? = null

        /**
         * The reader of this process, shared by every Flutter engine so Play is asked once per
         * process. Main thread only.
         */
        fun forProcess(context: Context): InstallReferrerReader =
            shared ?: InstallReferrerReader(context.applicationContext).also { shared = it }
    }
}
