import Foundation

/// The rules for the pasteboard click URL (IOS-005, contract section 9.3, `doc/platform-channel.md`
/// `readPasteboardUrl`): which host patterns Dart may name, and which pasteboard text counts as a
/// click URL. Kept identical to Dart's `lib/src/platform/pasteboard_click_url.dart`, which checks
/// the answer again, so a bug here cannot pass anything else on. Pure functions, so XCTest can
/// cover them without a pasteboard.
enum PasteboardClickURL {
  /// Longest click URL accepted, in UTF-16 code units as Dart counts them (LNK-002).
  static let maxLength = 2048

  /// Most host patterns one read accepts; it only bounds the work per call.
  static let maxHostPatterns = 100

  private static let httpsPrefix = "https://"
  private static let defaultPortSuffix = ":443"
  private static let clickPathPrefix = "/_c/"
  private static let wildcardPrefix = "*."

  private static let ulidLength = 26
  private static let ulidFirstCharacters = Set("01234567")
  // Crockford base 32, either case: no I, L, O or U.
  private static let ulidCharacters = Set(
    "0123456789ABCDEFGHJKMNPQRSTVWXYZabcdefghjkmnpqrstvwxyz")

  private static let labelCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
  private static let maxLabelLength = 63

  /// Whether `patterns` is a usable `allowed_hosts` argument: 1 to `maxHostPatterns` entries, each
  /// a lowercase host of at least two labels (`go.acme.com`), optionally after `*.`
  /// (`*.becklinks.com`).
  static func areValidHostPatterns(_ patterns: [String]) -> Bool {
    guard !patterns.isEmpty, patterns.count <= maxHostPatterns else { return false }
    return patterns.allSatisfy(isHostPattern)
  }

  /// Whether lowercase `host` matches `pattern`: equal to it, or, for `*.` and a host, exactly one
  /// more label in front (`*.becklinks.com` matches `acme.becklinks.com`, not `becklinks.com` or
  /// `a.b.becklinks.com`).
  static func matches(host: String, pattern: String) -> Bool {
    guard pattern.hasPrefix(wildcardPrefix) else { return host == pattern }
    // ".becklinks.com": the label in front of it must be the only one.
    let suffix = pattern.dropFirst(wildcardPrefix.count - 1)
    guard host.count > suffix.count, host.hasSuffix(suffix) else { return false }
    return isLabel(host.dropLast(suffix.count))
  }

  /// `text` unchanged when it is `https://{host}/_c/{ULID}` and nothing else (no user info, no
  /// port other than 443, no query, no fragment, at most `maxLength` long) with a host matching
  /// one of `allowedHosts`; otherwise `nil`.
  ///
  /// Parsed by hand rather than with `URLComponents`, whose leniency changed between iOS
  /// versions; the accepted form is narrow and ASCII only.
  static func clickURL(in text: String, allowedHosts: [String]) -> String? {
    guard text.utf16.count <= maxLength, text.allSatisfy(\.isASCII) else { return nil }
    guard text.prefix(httpsPrefix.count).lowercased() == httpsPrefix else { return nil }
    let rest = text.dropFirst(httpsPrefix.count)
    guard let pathStart = rest.firstIndex(of: "/") else { return nil }

    var authority = rest[..<pathStart]
    if authority.hasSuffix(defaultPortSuffix) {
      authority = authority.dropLast(defaultPortSuffix.count)
    }
    // A user info part (`@`) or another port leaves characters no pattern contains.
    let host = authority.lowercased()
    guard allowedHosts.contains(where: { matches(host: host, pattern: $0) }) else { return nil }

    let path = rest[pathStart...]
    guard path.hasPrefix(clickPathPrefix) else { return nil }
    // A query or fragment ends up here and fails the ULID check.
    guard isULID(path.dropFirst(clickPathPrefix.count)) else { return nil }
    return text
  }

  private static func isHostPattern(_ pattern: String) -> Bool {
    let host =
      pattern.hasPrefix(wildcardPrefix) ? pattern.dropFirst(wildcardPrefix.count) : pattern[...]
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    // At least two labels, so a pattern can never be as broad as `*.app`.
    return labels.count >= 2 && labels.allSatisfy { isLabel($0) }
  }

  private static func isLabel<Label: StringProtocol>(_ label: Label) -> Bool {
    guard !label.isEmpty, label.count <= maxLabelLength,
      let first = label.first, let last = label.last,
      first != "-", last != "-"
    else { return false }
    return label.allSatisfy { labelCharacters.contains($0) }
  }

  private static func isULID(_ value: Substring) -> Bool {
    guard value.count == ulidLength, let first = value.first,
      ulidFirstCharacters.contains(first)
    else { return false }
    return value.allSatisfy { ulidCharacters.contains($0) }
  }
}
