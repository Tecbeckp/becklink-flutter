import UIKit

/// App and device details for the `context` of SDK API requests (contract section 7.1), as
/// `getDeviceContext` reports them. Dart trims, cuts and checks the values and adds `platform`.
///
/// Holds no identifier of the device or the user (contract section 12, IOS-006): never IDFA or
/// IDFV, never `UIDevice.name`, which people set to their own name. `device_model` is a hardware
/// model identifier shared by every device of that model.
enum DeviceContextReader {
  /// Reads the details; call it on the main thread (`UIDevice`).
  static func read() -> [String: Any] {
    [
      "os_version": UIDevice.current.systemVersion,
      "device_model": orNull(hardwareModel()),
      "locale": orNull(Locale.preferredLanguages.first),
      "app_version": orNull(infoString("CFBundleShortVersionString")),
      "app_build": orNull(infoString("CFBundleVersion")),
    ]
  }

  private static func infoString(_ key: String) -> String? {
    Bundle.main.object(forInfoDictionaryKey: key) as? String
  }

  /// The model identifier such as `iPhone16,2`; on the simulator, the simulated model's rather
  /// than the Mac's architecture.
  private static func hardwareModel() -> String? {
    #if targetEnvironment(simulator)
      if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"],
        !simulated.isEmpty
      {
        return simulated
      }
    #endif
    var system = utsname()
    guard uname(&system) == 0 else { return nil }
    let machine = withUnsafeBytes(of: &system.machine) { bytes in
      String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
    return machine.isEmpty ? nil : machine
  }

  // The platform channel contract sends `null` for a value that cannot be read.
  private static func orNull(_ value: String?) -> Any {
    guard let value, !value.isEmpty else { return NSNull() }
    return value
  }
}
