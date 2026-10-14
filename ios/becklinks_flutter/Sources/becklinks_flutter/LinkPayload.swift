import Foundation

/// One URL delivery from the operating system, in the shape `getInitialLink` and the link event
/// channel carry (`doc/platform-channel.md`, "Link payload").
struct LinkPayload: Equatable {
  /// Longest URL reported, in UTF-16 code units as Dart counts them. Far above any real link; it
  /// only bounds what another app can push into this one through a crafted URL.
  static let maxURLLength = 16 * 1024

  /// The URL exactly as received (`URL.absoluteString`).
  let url: String

  /// Device clock, in milliseconds since the Unix epoch, when iOS handed the URL over. Dart uses
  /// it as the direct open's `opened_at` and, with `url`, to tell one delivery reported twice from
  /// the same link opened twice, so it is stamped once per delivery.
  let receivedAtMilliseconds: Int64

  /// Returns `nil` for an empty or over-long URL, which is then not reported at all.
  init?(url: URL, receivedAt: Date) {
    let text = url.absoluteString
    guard !text.isEmpty, text.utf16.count <= Self.maxURLLength else { return nil }
    self.url = text
    receivedAtMilliseconds = Int64((receivedAt.timeIntervalSince1970 * 1000).rounded(.down))
  }

  /// The map sent over the platform channel.
  var channelValue: [String: Any] {
    ["url": url, "received_at_ms": NSNumber(value: receivedAtMilliseconds)]
  }
}
