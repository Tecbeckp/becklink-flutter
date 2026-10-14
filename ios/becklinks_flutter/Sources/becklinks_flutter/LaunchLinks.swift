import UIKit

/// How iOS handed a URL to the app.
enum LinkDeliveryKind: Equatable {
  /// A URL to open: `application(_:open:options:)` or `scene(_:openURLContexts:)` (custom schemes).
  case openURL
  /// A Universal Link: the `webpageURL` of an `NSUserActivityTypeBrowsingWeb` activity.
  case webActivity
}

/// A link that launched an app using the app delegate life cycle, as its launch options name it.
enum AppLaunchLink: Equatable {
  /// A URL to open (`UIApplication.LaunchOptionsKey.url`).
  case openURL(URL)
  /// A Universal Link whose activity the launch options carry.
  case webActivity(URL)
  /// A Universal Link launch whose activity the launch options do not carry; iOS hands it over
  /// through `application(_:continue:restorationHandler:)` right after launch.
  case webActivityToFollow

  /// The links in `launchOptions`, as `application(_:didFinishLaunchingWithOptions:)` receives
  /// them; scene-based apps get `nil` options there and the link in the scene's connection
  /// options instead.
  static func links(in launchOptions: [AnyHashable: Any]) -> [AppLaunchLink] {
    var links: [AppLaunchLink] = []
    if let url = launchOptions[UIApplication.LaunchOptionsKey.url.rawValue] as? URL {
      links.append(.openURL(url))
    }
    let activityKey = UIApplication.LaunchOptionsKey.userActivityDictionary.rawValue
    if let activityInfo = launchOptions[activityKey] as? [AnyHashable: Any] {
      if let link = webActivityLink(in: activityInfo) {
        links.append(link)
      }
    }
    return links
  }

  private static func webActivityLink(in activityInfo: [AnyHashable: Any]) -> AppLaunchLink? {
    // The activity sits under a key UIKit does not publish, so it is found by its class.
    let activity = activityInfo.values.first { $0 is NSUserActivity } as? NSUserActivity
    if let activity {
      guard let url = webpageURL(of: activity) else { return nil }
      return .webActivity(url)
    }
    let typeKey = UIApplication.LaunchOptionsKey.userActivityType.rawValue
    guard (activityInfo[typeKey] as? String) == NSUserActivityTypeBrowsingWeb else { return nil }
    return .webActivityToFollow
  }
}

/// The URLs in a scene's connection options: what launched the app, or reconnected a scene iOS
/// had discarded. iOS reports them nowhere else.
func launchURLs(in connectionOptions: UIScene.ConnectionOptions) -> [URL] {
  let webLinks = connectionOptions.userActivities.compactMap(webpageURL(of:))
  let openedURLs = connectionOptions.urlContexts.map(\.url)
  return webLinks + openedURLs
}

/// The Universal Link an activity carries, or `nil` for any other activity (Handoff, Spotlight).
func webpageURL(of activity: NSUserActivity) -> URL? {
  guard activity.activityType == NSUserActivityTypeBrowsingWeb else { return nil }
  return activity.webpageURL
}
