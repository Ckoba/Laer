import Foundation
import LaerCore
import OSLog
import Security

/// Stores OAuth tokens in the Keychain. Nothing else keeps them.
struct TokenVault {
    private static let service = "app.laer.Laer.oauth"

    let site: Site

    func load() -> OAuthTokens? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound { Keychain.report("token load", status) }
            return nil
        }
        return try? JSONDecoder().decode(OAuthTokens.self, from: data)
    }

    /// False when the Keychain refused the write; the previous tokens, if any, are left as they were.
    @discardableResult
    func save(_ tokens: OAuthTokens) -> Bool {
        guard let data = try? JSONEncoder().encode(tokens) else { return false }
        return Keychain.upsert(baseQuery, data: data, operation: "token save")
    }

    /// True when no tokens remain afterwards, including when there were none.
    @discardableResult
    func clear() -> Bool {
        Keychain.delete(baseQuery, operation: "token clear")
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: String(site.customerId),
        ]
    }
}

/// Shared Keychain writes for the vaults. Failures are logged by operation and status code only.
enum Keychain {
    private static let log = Logger(subsystem: "app.laer.Laer", category: "keychain")

    /// Updates the item in place, or adds it when missing. Returns false on any other status.
    static func upsert(_ query: [String: Any], data: Data, operation: String) -> Bool {
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else {
            report(operation, updated)
            return false
        }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else {
            report(operation, added)
            return false
        }
        return true
    }

    /// True when the item is gone afterwards.
    static func delete(_ query: [String: Any], operation: String) -> Bool {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            report(operation, status)
            return false
        }
        return true
    }

    static func report(_ operation: String, _ status: OSStatus) {
        let category = switch status {
        case errSecInteractionNotAllowed: "locked"
        case errSecAuthFailed, errSecUserCanceled: "denied"
        case errSecMissingEntitlement: "entitlement"
        case errSecDuplicateItem: "duplicate"
        case errSecDecode, errSecParam: "invalid"
        default: "other"
        }
        log.error("\(operation, privacy: .public) failed: \(category, privacy: .public) status \(status, privacy: .public)")
    }
}
