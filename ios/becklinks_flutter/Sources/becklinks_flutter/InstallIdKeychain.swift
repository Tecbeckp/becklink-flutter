import Foundation
import Security

/// The install ID seed kept in the Keychain, outside the app container, so a reinstall on the
/// same device keeps the install ID (contract sections 8.2 and 12, P26).
///
/// One generic-password item, `AfterFirstUnlockThisDeviceOnly` and not synchronizable: readable
/// in the background once the device was unlocked after boot, and never carried to another device
/// by a backup or iCloud Keychain (§42: a device change is a new install). Keychain calls block:
/// call these off the main thread.
enum InstallIdKeychain {
  /// What reading the item found.
  enum ReadResult: Equatable {
    /// The stored text. Dart checks that it is a UUID and replaces it otherwise.
    case found(String)
    /// No item: the first install on this device, or the item was removed.
    case absent
    /// The Keychain could not be read now, most often `errSecInteractionNotAllowed` before the
    /// first unlock after a reboot. Never reported as absent, or Dart would mint a new install ID
    /// and overwrite the real one.
    case unavailable(OSStatus)
  }

  private static let service = "app.becklink.flutter"
  private static let account = "install_id"

  private static var itemQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  /// Whether `value` is what `saveInstallIdSeed` accepts: a UUID in lowercase canonical form.
  static func isInstallId(_ value: String) -> Bool {
    guard let uuid = UUID(uuidString: value) else { return false }
    return uuid.uuidString.lowercased() == value
  }

  static func read() -> ReadResult {
    var query = itemQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    switch status {
    case errSecSuccess:
      // Bytes that are not UTF-8 decode to text that is not a UUID, which Dart replaces; that
      // repairs the item instead of failing on every launch.
      let data = (item as? Data) ?? Data()
      return .found(String(decoding: data, as: UTF8.self))
    case errSecItemNotFound:
      return .absent
    default:
      return .unavailable(status)
    }
  }

  /// Adds or updates the item; returns whether it is stored.
  static func save(_ installId: String) -> Bool {
    let attributes: [String: Any] = [
      kSecValueData as String: Data(installId.utf8),
      // Also on update, so an item written with another class is moved to this one.
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let updateStatus = SecItemUpdate(itemQuery as CFDictionary, attributes as CFDictionary)
    guard updateStatus == errSecItemNotFound else { return updateStatus == errSecSuccess }

    var newItem = itemQuery.merging(attributes) { _, new in new }
    newItem[kSecAttrSynchronizable as String] = false
    let addStatus = SecItemAdd(newItem as CFDictionary, nil)
    if addStatus == errSecDuplicateItem {
      // Another process sharing the item (an app extension) added it in between.
      return SecItemUpdate(itemQuery as CFDictionary, attributes as CFDictionary) == errSecSuccess
    }
    return addStatus == errSecSuccess
  }
}
