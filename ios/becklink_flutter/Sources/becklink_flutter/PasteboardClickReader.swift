import UIKit

/// Reads the click URL that the redirect's landing page copied before opening the App Store
/// (IOS-005, contract section 9.3), at most once per process.
///
/// Dart calls it only when the app enabled the pasteboard and only before first-open, and keeps
/// the "once per install" rule itself. Here the pasteboard is first asked, without reading it and
/// so without the system paste prompt, whether it probably holds a web URL; only then is the text
/// read, and it leaves this class only when it is a click URL of an allowed host. The pasteboard
/// is never written or cleared, and its text is never logged or kept otherwise.
///
/// Main thread only: `UIPasteboard` is used on the main thread, and the state needs no lock.
final class PasteboardClickReader {
  /// One reader per process, shared by every Flutter engine, so the pasteboard is read once.
  static let shared = PasteboardClickReader()

  private struct Request {
    let allowedHosts: [String]
    let completion: (String?) -> Void
  }

  private enum State {
    case idle
    case reading([Request])
    case finished(String?)
  }

  private static let probableWebURL: PartialKeyPath<UIPasteboard.DetectedValues> =
    \UIPasteboard.DetectedValues.probableWebURL

  private let pasteboard: UIPasteboard
  private var state = State.idle

  init(pasteboard: UIPasteboard = .general) {
    self.pasteboard = pasteboard
  }

  /// Calls `completion` on the main thread with the click URL, or `nil`. `allowedHosts` must
  /// already be checked with `PasteboardClickURL.areValidHostPatterns`. Calls after the first get
  /// the first result (when its host is allowed for them too) without touching the pasteboard.
  func read(allowedHosts: [String], completion: @escaping (String?) -> Void) {
    let request = Request(allowedHosts: allowedHosts, completion: completion)
    switch state {
    case .finished(let clickURL):
      completion(Self.answer(clickURL, for: request))
    case .reading(let pending):
      state = .reading(pending + [request])
    case .idle:
      state = .reading([request])
      // Pattern detection does not notify the user; the completion queue is not documented.
      pasteboard.detectPatterns(for: [Self.probableWebURL]) { detection in
        let probablyURL = (try? detection.get())?.contains(Self.probableWebURL) ?? false
        DispatchQueue.main.async {
          self.finish(probablyURL: probablyURL)
        }
      }
    }
  }

  private func finish(probablyURL: Bool) {
    guard case .reading(let requests) = state else { return }
    var clickURL: String?
    if probablyURL, let text = pasteboard.string {
      // Reading the text is what may show the system paste prompt.
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      let allowedHosts = requests.flatMap(\.allowedHosts)
      clickURL = PasteboardClickURL.clickURL(in: trimmed, allowedHosts: allowedHosts)
    }
    state = .finished(clickURL)
    for request in requests {
      request.completion(Self.answer(clickURL, for: request))
    }
  }

  private static func answer(_ clickURL: String?, for request: Request) -> String? {
    guard let clickURL else { return nil }
    return PasteboardClickURL.clickURL(in: clickURL, allowedHosts: request.allowedHosts)
  }
}
