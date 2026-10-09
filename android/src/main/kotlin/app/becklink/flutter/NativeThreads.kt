package app.becklink.flutter

import android.os.Handler
import android.os.Looper
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * The two kinds of thread the native layer uses: channel replies and all plugin state live on the
 * main thread, blocking work (disk, package manager, Play Store IPC) runs in the background so the
 * app's start is never held up (§29: `configure()` stays under 20 ms).
 */
internal object NativeThreads {
    val main: Handler by lazy { Handler(Looper.getMainLooper()) }

    // A cached pool rather than one thread: a Play Store IPC that hangs must not hold up the
    // storage or device-context answers queued behind it. Idle threads end after a minute, so an
    // app that is not using the SDK right now keeps no thread alive.
    private val background: ExecutorService by lazy {
        Executors.newCachedThreadPool { task ->
            Thread(task, "becklink-native").apply { isDaemon = true }
        }
    }

    /** Runs [work] off the main thread; [work] must catch its own failures and post its reply. */
    fun runInBackground(work: () -> Unit) {
        background.execute { work() }
    }

    /** Runs [work] on the main thread, after whatever the main thread is doing now. */
    fun onMain(work: () -> Unit) {
        main.post { work() }
    }
}
