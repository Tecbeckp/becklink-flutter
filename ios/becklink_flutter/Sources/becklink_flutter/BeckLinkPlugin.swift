import Flutter
import UIKit

/// iOS entry point of the becklink_flutter plugin; the wire contract is `doc/platform-channel.md`.
///
/// Deliberately thin: the Dart layer owns networking, storage and attribution, so this class only
/// does what Dart cannot reach on iOS: incoming links, the storage folder, the Keychain install ID
/// seed, the opt-in pasteboard read and device details.
///
/// Links are observed, never claimed: every app and scene delegate method returns `false`, because
/// Flutter stops at the first plugin that returns `true`, which would hide OAuth callbacks and
/// other URLs from other plugins and from Flutter's own router.
public final class BeckLinkPlugin: NSObject, FlutterPlugin {
  private static let methodChannelName = "app.becklink.flutter/methods"
  private static let linkChannelName = "app.becklink.flutter/links"

  /// File system and Keychain work, kept off the main thread so `configure()` stays under 20 ms
  /// (§29). Serial and shared by every engine, so a seed save and a later read keep their order.
  private static let workQueue = DispatchQueue(
    label: "app.becklink.flutter.work", qos: .userInitiated)

  private let linkStream: LinkStream
  private let incomingLinks: IncomingLinks

  override init() {
    let stream = LinkStream()
    linkStream = stream
    incomingLinks = IncomingLinks(stream: stream)
    super.init()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let plugin = BeckLinkPlugin()
    let messenger = registrar.messenger()
    registrar.addMethodCallDelegate(
      plugin, channel: FlutterMethodChannel(name: methodChannelName, binaryMessenger: messenger))
    FlutterEventChannel(name: linkChannelName, binaryMessenger: messenger)
      .setStreamHandler(plugin.linkStream)

    // Before addApplicationDelegate, which checks the scene conformance this adds.
    let receivesSceneEvents = SceneLifeCycleSupport.adopt(BeckLinkPlugin.self, registrar: registrar)
    registrar.addApplicationDelegate(plugin)
    if receivesSceneEvents {
      SceneLifeCycleSupport.register(plugin, with: registrar)
    }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getInitialLink":
      result(incomingLinks.takeInitialLink()?.channelValue)
    case "getStorageDirectory":
      getStorageDirectory(result: result)
    case "getInstallIdSeed":
      getInstallIdSeed(result: result)
    case "saveInstallIdSeed":
      saveInstallIdSeed(call, result: result)
    case "getInstallReferrer":
      // Play's install referrer has no iOS counterpart; iOS uses the pasteboard instead.
      result(nil)
    case "readPasteboardUrl":
      readPasteboardUrl(call, result: result)
    case "getDeviceContext":
      result(DeviceContextReader.read())
    default:
      // Answering unknown methods keeps Dart from awaiting a reply that never comes.
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Methods

  private func getStorageDirectory(result: @escaping FlutterResult) {
    Self.workQueue.async {
      let answer: Any
      do {
        answer = try SdkStorageDirectory.prepare()
      } catch {
        // Domain and code only: the description can contain the container path.
        let nsError = error as NSError
        answer = FlutterError(
          code: "storage_unavailable",
          message: "Could not prepare the SDK folder (\(nsError.domain) \(nsError.code))",
          details: nil)
      }
      DispatchQueue.main.async { result(answer) }
    }
  }

  private func getInstallIdSeed(result: @escaping FlutterResult) {
    Self.workQueue.async {
      let answer = Self.installIdSeedAnswer(for: InstallIdKeychain.read())
      DispatchQueue.main.async { result(answer) }
    }
  }

  /// The `getInstallIdSeed` answer for a Keychain read: the seed, `nil` when there is none, or a
  /// `keychain_unavailable` error, never `nil`, when the Keychain cannot be read now (Dart would
  /// otherwise mint a new install ID and overwrite the real one). Pure, so XCTest covers it.
  static func installIdSeedAnswer(for readResult: InstallIdKeychain.ReadResult) -> Any? {
    switch readResult {
    case .found(let seed):
      return seed
    case .absent:
      return nil
    case .unavailable(let status):
      return FlutterError(
        code: "keychain_unavailable",
        message: "The Keychain cannot be read now (OSStatus \(status))",
        details: nil)
    }
  }

  private func saveInstallIdSeed(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let arguments = call.arguments as? [String: Any],
      let installId = arguments["install_id"] as? String,
      InstallIdKeychain.isInstallId(installId)
    else {
      // The message never repeats the value.
      result(Self.invalidArguments("install_id must be a lowercase UUID"))
      return
    }
    Self.workQueue.async {
      let stored = InstallIdKeychain.save(installId)
      DispatchQueue.main.async { result(stored) }
    }
  }

  private func readPasteboardUrl(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let arguments = call.arguments as? [String: Any],
      let allowedHosts = arguments["allowed_hosts"] as? [String],
      PasteboardClickURL.areValidHostPatterns(allowedHosts)
    else {
      result(
        Self.invalidArguments(
          "allowed_hosts must be 1 to \(PasteboardClickURL.maxHostPatterns) host patterns"))
      return
    }
    PasteboardClickReader.shared.read(allowedHosts: allowedHosts) { clickURL in
      result(clickURL)
    }
  }

  private static func invalidArguments(_ message: String) -> FlutterError {
    FlutterError(code: "invalid_arguments", message: message, details: nil)
  }

  // MARK: - App delegate life cycle (apps without scenes)

  public func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [AnyHashable: Any] = [:]
  ) -> Bool {
    for link in AppLaunchLink.links(in: launchOptions) {
      incomingLinks.receive(appLaunch: link)
    }
    // `false` would veto the app's launch.
    return true
  }

  public func application(
    _ application: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    incomingLinks.receive(url, kind: .openURL)
    return false
  }

  public func application(
    _ application: UIApplication,
    continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([Any]) -> Void
  ) -> Bool {
    if let url = webpageURL(of: userActivity) {
      incomingLinks.receive(url, kind: .webActivity)
    }
    return false
  }

  // MARK: - Scene life cycle (Flutter 3.38+, see SceneLifeCycleSupport)

  // The Objective-C selectors are spelled out: Flutter calls these through them, and on older
  // Flutter versions the compiler has no protocol to derive them from.

  @objc(scene:willConnectToSession:options:)
  public func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions?
  ) -> Bool {
    // `nil` when another plugin claimed the connection options before this one.
    guard let connectionOptions else { return false }
    for url in launchURLs(in: connectionOptions) {
      incomingLinks.receive(sceneLaunch: url)
    }
    return false
  }

  @objc(scene:openURLContexts:)
  public func scene(_ scene: UIScene, openURLContexts urlContexts: Set<UIOpenURLContext>) -> Bool {
    for context in urlContexts {
      incomingLinks.receive(context.url, kind: .openURL)
    }
    return false
  }

  @objc(scene:continueUserActivity:)
  public func scene(_ scene: UIScene, continue userActivity: NSUserActivity) -> Bool {
    if let url = webpageURL(of: userActivity) {
      incomingLinks.receive(url, kind: .webActivity)
    }
    return false
  }
}
