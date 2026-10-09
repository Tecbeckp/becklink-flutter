package app.becklink.flutter

import android.content.Intent
import android.os.Handler
import io.flutter.plugin.common.MethodChannel
import java.util.Collections
import java.util.WeakHashMap

/**
 * Routes the URLs Android hands to the app (`doc/platform-channel.md`): the URL of the intent that
 * launched the activity this engine first attaches to goes to `getInitialLink`, handed out once;
 * every later delivery goes to the link event channel. Each delivery is reported exactly once,
 * through one of the two. One instance per Flutter engine; main thread only.
 *
 * An activity recreated by Android (configuration change, process restore with saved state) brings
 * back the intent it was launched with, which was already reported. Flutter attaches plugins to
 * the new activity before it restores the saved state, so the URL of an attach waits until the
 * main thread has finished creating the activity: [onActivityRecreated] can still drop it then.
 */
internal class IncomingLinks(
    private val stream: LinkStreamHandler,
    private val main: Handler = NativeThreads.main,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    /** Whether the first attached activity was settled, so [launchLink] is final. */
    private var launchLinkSettled = false

    /** The launch URL until Dart takes it; `null` once handed out or when there was none. */
    private var launchLink: LinkPayload? = null

    /** `getInitialLink` calls that came before any activity was attached (prewarmed engine). */
    private val launchLinkRequests = mutableListOf<MethodChannel.Result>()

    /** The URL of the activity attached last, while it may still turn out to be a recreation. */
    private var attachedActivityLink: LinkPayload? = null
    private var settlePending = false
    private val settleRunnable = Runnable { settleAttachedActivity() }

    /** A new activity was attached (not a reattach after a configuration change). */
    fun onActivityAttached(intent: Intent?) {
        if (settlePending) settleAttachedActivity()
        attachedActivityLink = intent?.let { takeDelivery(it) }
        settlePending = true
        // Runs after the activity's onCreate, which is where Flutter restores the saved state.
        main.post(settleRunnable)
    }

    /**
     * The activity attached last was recreated from saved state in which this plugin had already
     * seen it, so its launch intent was reported before.
     */
    fun onActivityRecreated() {
        attachedActivityLink = null
    }

    fun onNewIntent(intent: Intent) {
        // Keeps arrival order: the attached activity's URL came first. Its saved state was
        // restored during onCreate, before any new intent can reach the activity.
        if (settlePending) settleAttachedActivity()
        takeDelivery(intent)?.let { stream.send(it) }
    }

    fun getInitialLink(result: MethodChannel.Result) {
        if (!launchLinkSettled) {
            launchLinkRequests.add(result)
            return
        }
        result.success(handOutLaunchLink())
    }

    /** The engine is going away: nothing is reported any more and nobody waits for an answer. */
    fun dispose() {
        main.removeCallbacks(settleRunnable)
        settlePending = false
        attachedActivityLink = null
        launchLinkRequests.clear()
        stream.dispose()
    }

    private fun settleAttachedActivity() {
        main.removeCallbacks(settleRunnable)
        settlePending = false
        val link = attachedActivityLink
        attachedActivityLink = null
        if (!launchLinkSettled) {
            launchLinkSettled = true
            launchLink = link
            val waiting = launchLinkRequests.toList()
            launchLinkRequests.clear()
            waiting.forEach { it.success(handOutLaunchLink()) }
        } else if (link != null) {
            // A later activity of an engine that keeps running (cached engine, add-to-app): Dart is
            // already past its launch, so this is a link received while running.
            stream.send(link)
        }
    }

    // Once per engine, so a Flutter hot restart, which keeps the engine, gets null.
    private fun handOutLaunchLink(): Map<String, Any>? {
        val link = launchLink
        launchLink = null
        return link?.toMap()
    }

    private fun takeDelivery(intent: Intent): LinkPayload? {
        val url = viewIntentUrl(intent.action, intent.dataString, intent.flags) ?: return null
        // The same Intent object comes back when an engine is reattached to an activity it saw
        // before, or a new engine attaches to a recreated activity in this process.
        if (!reportedIntents.add(intent)) return null
        return LinkPayload(url, clock())
    }

    private companion object {
        // Process-wide because a recreated activity can get a new engine and so a new plugin
        // instance. Intent has identity equality; weak keys let finished activities' intents go.
        val reportedIntents: MutableSet<Intent> =
            Collections.newSetFromMap(WeakHashMap<Intent, Boolean>())
    }
}
