import Foundation

/// The SDK's own folder for Dart's `state.json` and `events.json`: `Library/Application
/// Support/becklink`, kept out of backups (contract P26: a restored or migrated device is a new
/// install).
enum SdkStorageDirectory {
  private static let folderName = "becklink"

  /// Creates the folder if missing, marks it excluded from backup and returns its absolute path.
  /// Blocking file system work: call it off the main thread.
  ///
  /// The exclusion is set on every call because a restore or copy can drop it, and only on this
  /// folder, never on Application Support itself, which holds the app's own data.
  static func prepare() throws -> String {
    let fileManager = FileManager.default
    let applicationSupport = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    var folder = applicationSupport.appendingPathComponent(folderName, isDirectory: true)
    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try folder.setResourceValues(values)
    return folder.path
  }
}
