import Flutter
import Security
import XCTest

@testable import becklink_flutter

// Native unit tests of the plugin's Swift layer run inside the example app's test target. They
// cover the pure parts; the pasteboard and the Keychain themselves need a device and a user.

final class RunnerTests: XCTestCase {

  func testUnknownMethodAnswersNotImplemented() {
    let plugin = BeckLinkPlugin()
    let call = FlutterMethodCall(methodName: "unknownMethod", arguments: nil)

    let replied = expectation(description: "result callback is called")
    plugin.handle(call) { result in
      XCTAssertIdentical(result as? NSObject, FlutterMethodNotImplemented)
      replied.fulfill()
    }
    waitForExpectations(timeout: 1)
  }

  func testInvalidArgumentsAreRefusedWithoutEchoingThem() {
    let plugin = BeckLinkPlugin()
    let call = FlutterMethodCall(
      methodName: "saveInstallIdSeed", arguments: ["install_id": "user@example.com"])

    let replied = expectation(description: "result callback is called")
    plugin.handle(call) { result in
      let error = result as? FlutterError
      XCTAssertEqual(error?.code, "invalid_arguments")
      XCTAssertFalse(error?.message?.contains("user@example.com") ?? true)
      replied.fulfill()
    }
    waitForExpectations(timeout: 1)
  }
}

/// `PasteboardClickURL`: the same rules as Dart's `pasteboard_click_url.dart` (contract section
/// 9.3, `doc/platform-channel.md` `readPasteboardUrl`).
final class PasteboardClickURLTests: XCTestCase {
  private let ulid = "01K6ZPWR5N7Y3A9S2D4F6G8HJK"
  private let hosts = ["*.becklinks.com", "go.acme.com"]

  func testAcceptsAClickURLOfAnAllowedHostUnchanged() {
    let accepted = [
      "https://acme.becklinks.com/_c/\(ulid)",
      "https://go.acme.com/_c/\(ulid)",
      "https://ACME.becklinks.com/_c/\(ulid.lowercased())",
      "HTTPS://acme.becklinks.com/_c/\(ulid)",
      "https://acme.becklinks.com:443/_c/\(ulid)",
    ]
    for text in accepted {
      XCTAssertEqual(PasteboardClickURL.clickURL(in: text, allowedHosts: hosts), text, text)
    }
  }

  func testRefusesEverythingElse() {
    let refused = [
      "http://acme.becklinks.com/_c/\(ulid)",
      "https://becklinks.com/_c/\(ulid)",
      "https://a.b.becklinks.com/_c/\(ulid)",
      "https://evilbecklinks.com/_c/\(ulid)",
      "https://acme.becklinks.com.evil.com/_c/\(ulid)",
      "https://user@acme.becklinks.com/_c/\(ulid)",
      "https://acme.becklinks.com:8443/_c/\(ulid)",
      "https://acme.becklinks.com/_c/\(ulid)?x=1",
      "https://acme.becklinks.com/_c/\(ulid)#x",
      "https://acme.becklinks.com/_c/\(ulid)/",
      "https://acme.becklinks.com/summer24",
      // A ULID starts with 0-7 and has no I, L, O or U.
      "https://acme.becklinks.com/_c/8\(ulid.dropFirst())",
      "https://acme.becklinks.com/_c/0\(String(repeating: "I", count: 25))",
      "https://acme.becklinks.com/_c/\(ulid.dropFirst())",
      "https://x.go.acme.com/_c/\(ulid)",
      "https://acm\u{E9}.becklinks.com/_c/\(ulid)",
      " https://acme.becklinks.com/_c/\(ulid)",
      "https://acme.becklinks.com/_c/\(ulid) ",
      "https://acme.becklinks.com",
      "",
    ]
    for text in refused {
      XCTAssertNil(PasteboardClickURL.clickURL(in: text, allowedHosts: hosts), text)
    }
  }

  func testRefusesTextOverTheLengthLimit() {
    let text =
      "https://acme.becklinks.com/_c/\(ulid)"
      + String(repeating: "a", count: PasteboardClickURL.maxLength)

    XCTAssertNil(PasteboardClickURL.clickURL(in: text, allowedHosts: hosts))
  }

  func testAWildcardMatchesExactlyOneMoreLabel() {
    XCTAssertTrue(PasteboardClickURL.matches(host: "acme.becklinks.com", pattern: "*.becklinks.com"))
    XCTAssertFalse(PasteboardClickURL.matches(host: "becklinks.com", pattern: "*.becklinks.com"))
    XCTAssertFalse(PasteboardClickURL.matches(host: "a.b.becklinks.com", pattern: "*.becklinks.com"))
    XCTAssertFalse(PasteboardClickURL.matches(host: "evilbecklinks.com", pattern: "*.becklinks.com"))
    XCTAssertTrue(PasteboardClickURL.matches(host: "go.acme.com", pattern: "go.acme.com"))
    XCTAssertFalse(PasteboardClickURL.matches(host: "x.go.acme.com", pattern: "go.acme.com"))
  }

  func testHostPatternsAreLowercaseHostsOfTwoOrMoreLabels() {
    XCTAssertTrue(PasteboardClickURL.areValidHostPatterns(["*.becklinks.com"]))
    XCTAssertTrue(PasteboardClickURL.areValidHostPatterns(["go.acme.com", "*.becklinks.com"]))
    let invalid = [
      "*.app", "localhost", "Go.acme.com", "-acme.com", "acme-.com", "acme..com",
      "*.*.becklinks.com", "acme.com:443",
    ]
    for pattern in invalid {
      XCTAssertFalse(PasteboardClickURL.areValidHostPatterns([pattern]), pattern)
    }
  }

  func testAllowsOneToOneHundredPatterns() {
    let hundred = (0..<100).map { "h\($0).example.com" }

    XCTAssertFalse(PasteboardClickURL.areValidHostPatterns([]))
    XCTAssertTrue(PasteboardClickURL.areValidHostPatterns(hundred))
    XCTAssertFalse(PasteboardClickURL.areValidHostPatterns(hundred + ["h100.example.com"]))
  }
}

/// The Keychain install ID seed: the answers Dart reads (`getInstallIdSeed`) and the values
/// `saveInstallIdSeed` accepts. The Keychain itself is not touched.
final class InstallIdKeychainTests: XCTestCase {
  private let installId = "3f6c1b9e-8d2a-4c47-9b1e-5a7d2c8e4f10"

  func testAFoundSeedIsAnsweredUnchanged() {
    let answer = BeckLinkPlugin.installIdSeedAnswer(for: .found(installId))

    XCTAssertEqual(answer as? String, installId)
  }

  func testNoSeedIsAnsweredWithNil() {
    XCTAssertNil(BeckLinkPlugin.installIdSeedAnswer(for: .absent))
  }

  func testAKeychainThatCannotBeReadIsAnErrorNotNil() {
    let answer = BeckLinkPlugin.installIdSeedAnswer(
      for: .unavailable(errSecInteractionNotAllowed))

    let error = answer as? FlutterError
    XCTAssertNotNil(error)
    XCTAssertEqual(error?.code, "keychain_unavailable")
  }

  func testOnlyALowercaseCanonicalUUIDIsAnInstallId() {
    XCTAssertTrue(InstallIdKeychain.isInstallId(installId))
    XCTAssertFalse(InstallIdKeychain.isInstallId(installId.uppercased()))
    XCTAssertFalse(
      InstallIdKeychain.isInstallId(installId.replacingOccurrences(of: "-", with: "")))
    XCTAssertFalse(InstallIdKeychain.isInstallId("user@example.com"))
    XCTAssertFalse(InstallIdKeychain.isInstallId(""))
  }
}

/// The link payload the native layer sends for one URL delivery (`doc/platform-channel.md`).
final class LinkPayloadTests: XCTestCase {
  func testCarriesTheURLAndTheReceiveTimeInMilliseconds() throws {
    let url = try XCTUnwrap(URL(string: "https://acme.becklinks.com/summer24?ref=newsletter"))
    let payload = try XCTUnwrap(
      LinkPayload(url: url, receivedAt: Date(timeIntervalSince1970: 1_700_000_000.0015)))

    XCTAssertEqual(payload.url, "https://acme.becklinks.com/summer24?ref=newsletter")
    XCTAssertEqual(payload.receivedAtMilliseconds, 1_700_000_000_001)
    let value = payload.channelValue
    XCTAssertEqual(value["url"] as? String, payload.url)
    XCTAssertEqual((value["received_at_ms"] as? NSNumber)?.int64Value, 1_700_000_000_001)
  }

  func testDropsAnOverLongURL() throws {
    let path = String(repeating: "a", count: LinkPayload.maxURLLength)
    let url = try XCTUnwrap(URL(string: "https://acme.becklinks.com/\(path)"))

    XCTAssertNil(LinkPayload(url: url, receivedAt: Date()))
  }
}
