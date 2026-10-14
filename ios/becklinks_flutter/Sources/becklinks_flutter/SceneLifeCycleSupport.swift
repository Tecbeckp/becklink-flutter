import Flutter
import ObjectiveC

/// Scene life-cycle events for plugins (`FlutterSceneLifeCycleDelegate`,
/// `FlutterPluginRegistrar.addSceneDelegate(_:)`) exist from Flutter 3.38, and scene-based apps
/// (the default template from then on) deliver links only through them. This plugin also builds
/// against Flutter 3.27 headers, which have neither, so both are looked up at run time instead of
/// being named in code.
enum SceneLifeCycleSupport {
  private static let protocolName = "FlutterSceneLifeCycleDelegate"
  private static let addSceneDelegate = NSSelectorFromString("addSceneDelegate:")

  /// Declares `pluginClass` a `FlutterSceneLifeCycleDelegate` when this Flutter has scene events
  /// and `registrar` takes scene delegates; returns whether it does.
  ///
  /// Call it before `addApplicationDelegate`: Flutter checks the conformance there (it warns about
  /// plugins without scene support) and again before replaying scene events to plugins through
  /// their app delegate methods, which would otherwise report each link a second time. The
  /// plugin implements the scene methods it needs with their Objective-C selectors; Flutter calls
  /// only the ones it responds to.
  static func adopt(_ pluginClass: AnyClass, registrar: FlutterPluginRegistrar) -> Bool {
    guard registrar.responds(to: addSceneDelegate),
      let sceneDelegateProtocol = objc_getProtocol(protocolName)
    else { return false }
    if !class_conformsToProtocol(pluginClass, sceneDelegateProtocol) {
      _ = class_addProtocol(pluginClass, sceneDelegateProtocol)
    }
    return true
  }

  /// Registers `plugin` for scene events; only after `adopt` returned `true`.
  static func register(_ plugin: NSObject, with registrar: FlutterPluginRegistrar) {
    // `addSceneDelegate:` returns nothing, so the unmanaged result is never touched.
    _ = registrar.perform(addSceneDelegate, with: plugin)
  }
}
