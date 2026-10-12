import Foundation
import Security

/// The few Keychain calls Worklens needs, as generic passwords.
///
/// OAuth refresh tokens are the one secret Worklens holds that the user did not type into `.env`,
/// so they go in the Keychain rather than into `DATA_DIR` — the user can see, audit and revoke
/// them in Keychain Access, and a backup of the data folder carries no credentials.
public enum Keychain {
    public enum Failure: Error, CustomStringConvertible, Equatable {
        case status(OSStatus, String)

        public var description: String {
            switch self {
            case let .status(code, operation):
                let message = SecCopyErrorMessageString(code, nil) as String? ?? "OSStatus \(code)"
                return "Keychain \(operation) failed: \(message)"
            }
        }
    }

    public static func set(_ data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // Available after first unlock so a background sync survives a locked screen, but
            // never synced to iCloud and never leaving this device.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw Failure.status(update, "update") }

        let add = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        guard add == errSecSuccess else { throw Failure.status(add, "add") }
    }

    public static func get(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.status(status, "read") }
        return item as? Data
    }

    /// The first account stored under `service`, for "which Google account is connected?" when
    /// nothing has told us the address yet.
    public static func firstAccount(service: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.status(status, "list") }
        return (items as? [[String: Any]])?
            .compactMap { $0[kSecAttrAccount as String] as? String }
            .sorted()
            .first
    }

    @discardableResult
    public static func delete(service: String, account: String) throws -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw Failure.status(status, "delete") }
        return true
    }
}
