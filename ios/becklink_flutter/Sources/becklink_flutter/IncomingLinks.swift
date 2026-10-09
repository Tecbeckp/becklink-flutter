import Foundation

/// Routes every URL iOS hands the app to exactly one of `getInitialLink` and the link event
/// channel (`doc/platform-channel.md`): the launch link goes to `getInitialLink` until Dart has
/// asked for it, everything else to the stream.
///
/// Apps on the app delegate life cycle get a launch link twice: in the launch options and then
/// again through `application(_:open:options:)` or `application(_:continue:restorationHandler:)`.
/// The second report is dropped. Scene-based apps get it once, in the connection options.
///
/// Main thread only, like every app delegate, scene and channel callback, so it needs no lock.
final class IncomingLinks {
  /// How long after launch the app delegate path may still deliver the launch link a second time.
  /// The repeat comes right after `application(_:didFinishLaunchingWithOptions:)`; the bound only
  /// keeps a launch whose repeat never came (the app vetoed the URL) from hiding a later tap.
  static let launchRepeatWindow: TimeInterval = 60

  private struct ExpectedRepeat {
    let kind: LinkDeliveryKind
    /// `nil` when the launch options named only the activity type: then the repeat is the launch
    /// link itself, not a copy of one already reported.
    let url: String?
    let deadline: Date

    func matches(_ url: URL, kind: LinkDeliveryKind) -> Bool {
      guard kind == self.kind else { return false }
      return self.url == nil || self.url == url.absoluteString
    }
  }

  private let stream: LinkStream
  private let now: () -> Date

  private var initialLink: LinkPayload?
  private var initialLinkRequested = false
  private var expectedRepeats: [ExpectedRepeat] = []

  /// `now` is the device clock; tests replace it.
  init(stream: LinkStream, now: @escaping () -> Date = { Date() }) {
    self.stream = stream
    self.now = now
  }

  /// The answer to `getInitialLink`: the launch link the first time, `nil` afterwards (also after
  /// a Flutter hot restart, which keeps this native object). A launch link that arrives after
  /// this call goes to the stream, so it is not lost.
  func takeInitialLink() -> LinkPayload? {
    initialLinkRequested = true
    let link = initialLink
    initialLink = nil
    return link
  }

  /// A link from the app delegate's launch options.
  func receive(appLaunch link: AppLaunchLink) {
    let deadline = now().addingTimeInterval(Self.launchRepeatWindow)
    switch link {
    case .openURL(let url):
      reportLaunch(url)
      expectedRepeats.append(
        ExpectedRepeat(kind: .openURL, url: url.absoluteString, deadline: deadline))
    case .webActivity(let url):
      reportLaunch(url)
      expectedRepeats.append(
        ExpectedRepeat(kind: .webActivity, url: url.absoluteString, deadline: deadline))
    case .webActivityToFollow:
      expectedRepeats.append(ExpectedRepeat(kind: .webActivity, url: nil, deadline: deadline))
    }
  }

  /// A URL from a scene's connection options: the launch link, or a link that reconnected a
  /// scene iOS had discarded while the app kept running (then Dart has asked already and it goes
  /// to the stream).
  func receive(sceneLaunch url: URL) {
    reportLaunch(url)
  }

  /// A URL delivered through `application(_:open:options:)`,
  /// `application(_:continue:restorationHandler:)` or their scene equivalents.
  func receive(_ url: URL, kind: LinkDeliveryKind) {
    let current = now()
    expectedRepeats.removeAll { $0.deadline < current }
    if let index = expectedRepeats.firstIndex(where: { $0.matches(url, kind: kind) }) {
      let expected = expectedRepeats.remove(at: index)
      if expected.url == nil {
        reportLaunch(url)
      }
      return
    }
    guard let link = LinkPayload(url: url, receivedAt: current) else { return }
    stream.send(link)
  }

  private func reportLaunch(_ url: URL) {
    guard let link = LinkPayload(url: url, receivedAt: now()) else { return }
    if initialLinkRequested || initialLink != nil {
      stream.send(link)
    } else {
      initialLink = link
    }
  }
}
