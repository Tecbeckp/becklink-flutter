package app.becklink.flutter

import io.flutter.plugin.common.EventChannel
import java.util.ArrayDeque

/**
 * Native side of the `app.becklink.flutter/links` event channel: URLs received while the app
 * runs.
 *
 * Until Dart listens, links wait here in arrival order (the newest [MAX_BUFFERED]); `onListen`
 * sends them all, then live links follow. After `onCancel` links are buffered again. Flutter's
 * `EventChannel` calls `onCancel` before a repeated `onListen` (hot restart), so the newest
 * listener always replaces the previous one. Never sends an error or end-of-stream: Dart ignores
 * both.
 *
 * Main thread only, like every `EventSink` call.
 */
internal class LinkStreamHandler : EventChannel.StreamHandler {
    private val buffered = ArrayDeque<Map<String, Any>>()
    private var sink: EventChannel.EventSink? = null

    fun send(link: LinkPayload) {
        val payload = link.toMap()
        val current = sink
        if (current != null) {
            current.success(payload)
            return
        }
        if (buffered.size >= MAX_BUFFERED) buffered.pollFirst()
        buffered.addLast(payload)
    }

    override fun onListen(
        arguments: Any?,
        events: EventChannel.EventSink?,
    ) {
        sink = events
        if (events == null) return
        while (true) {
            val next = buffered.pollFirst() ?: break
            events.success(next)
        }
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    /** Forgets the listener and every buffered link; the engine is going away. */
    fun dispose() {
        sink = null
        buffered.clear()
    }

    private companion object {
        const val MAX_BUFFERED = 16
    }
}
