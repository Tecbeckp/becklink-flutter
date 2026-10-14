import Flutter

/// The native side of the link event channel (`app.becklink.flutter/links`): links received while
/// the app runs, held until Dart listens.
///
/// Main thread only, like every Flutter channel and app delegate callback, so it needs no lock.
final class LinkStream: NSObject, FlutterStreamHandler {
  /// Links kept while nobody listens; the oldest are dropped first (platform channel contract).
  static let bufferLimit = 16

  private var sink: FlutterEventSink?
  private var buffered: [LinkPayload] = []

  /// Sends `link` to Dart, or keeps it until Dart listens.
  func send(_ link: LinkPayload) {
    if let sink {
      sink(link.channelValue)
      return
    }
    buffered.append(link)
    if buffered.count > Self.bufferLimit {
      buffered.removeFirst(buffered.count - Self.bufferLimit)
    }
  }

  // FlutterEventChannel cancels the previous sink before a new `listen` (hot restart), so the
  // newest listener always gets the buffered links.
  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    sink = events
    let pending = buffered
    buffered.removeAll()
    for link in pending {
      events(link.channelValue)
    }
    return nil
  }

  // Never sends an error or end-of-stream: Dart ignores both, and links may still follow.
  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }
}
