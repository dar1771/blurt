import BlurtEngine
import Foundation
import Security

/// A separate item for each running app identity; never shares the dictation API key.
enum ClipboardSyncStorage {
  static var enabledKey: String { ClipboardSyncSettingsStore.enabledKey }
  static var deviceKey: String { ClipboardSyncSettingsStore.deviceKey }
  nonisolated static var service: String {
    (Bundle.main.bundleIdentifier ?? HostIdentity.current.subsystem) + ".clipboard-sync"
  }
  nonisolated static var cacheURL: URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent(service, isDirectory: true)
  }

  static func readKey() throws -> Data? {
    var query = keyQuery
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else { throw StorageError.keychain }
    return data
  }

  static func saveKey(_ key: Data?) throws {
    if let key {
      let status = SecItemUpdate(keyQuery as CFDictionary, [kSecValueData: key] as CFDictionary)
      if status == errSecItemNotFound {
        var query = keyQuery
        query[kSecValueData] = key
        query[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw StorageError.keychain }
      } else if status != errSecSuccess {
        throw StorageError.keychain
      }
    } else {
      let status = SecItemDelete(keyQuery as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else { throw StorageError.keychain }
    }
  }

  static func removeCache() throws {
    if FileManager.default.fileExists(atPath: cacheURL.path) {
      try FileManager.default.removeItem(at: cacheURL)
    }
  }

  private static var keyQuery: [CFString: Any] {
    [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "group-key"]
  }

  enum StorageError: LocalizedError {
    case keychain
    var errorDescription: String? { "Не удалось прочитать или сохранить код группы в Связке ключей." }
  }
}
