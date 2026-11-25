import Foundation
import LaerCore
import Security
import WebKit

/// Keeps the itslearning session cookies in the Keychain, because WebKit discards session cookies
/// when the app quits. Identity-provider cookies stay out, and nothing else stores these values.
@MainActor
struct SessionVault {
    private static let service = "app.laer.Laer.session"

    let site: Site

    private var hosts: [String] {
        [site.baseURL.host() ?? "", "resource.itslearning.com"]
    }

    /// False when the Keychain refused the write; the previously saved cookies stay as they were.
    @discardableResult
    func save(from store: WKHTTPCookieStore, isCurrent: () -> Bool = { true }) async -> Bool {
        let cookies = CookieScope.filter(await store.allCookies(), forHosts: hosts)
        guard isCurrent() else { return false }
        let records = cookies.compactMap(Self.record(from:))
        guard let data = try? JSONEncoder().encode(records) else { return false }
        return Keychain.upsert(baseQuery, data: data, operation: "session save")
    }

    /// Puts saved cookies back before the first page loads. Returns how many were restored.
    @discardableResult
    func restore(into store: WKHTTPCookieStore) async -> Int {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status != errSecSuccess, status != errSecItemNotFound { Keychain.report("session load", status) }
        guard status == errSecSuccess,
              let data = item as? Data,
              let records = try? JSONDecoder().decode([Record].self, from: data) else { return 0 }
        let cookies = records.compactMap(Self.cookie(from:))
        for cookie in cookies {
            await store.setCookie(cookie)
        }
        return cookies.count
    }

    /// True when no saved cookies remain afterwards, including when there were none.
    @discardableResult
    func clear() -> Bool {
        Keychain.delete(baseQuery, operation: "session clear")
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: String(site.customerId),
        ]
    }

    private struct Record: Codable {
        var name: String
        var value: String
        var domain: String
        var path: String
        var secure: Bool
        var httpOnly: Bool
        var expires: Date?
    }

    private static func record(from cookie: HTTPCookie) -> Record? {
        // A cookie that is not HTTPS-only never leaves WebKit's own store.
        guard cookie.isSecure else { return nil }
        return Record(name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path, secure: cookie.isSecure, httpOnly: cookie.isHTTPOnly, expires: cookie.expiresDate)
    }

    private static func cookie(from record: Record) -> HTTPCookie? {
        if let expires = record.expires, expires < Date() { return nil }
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: record.name, .value: record.value, .domain: record.domain, .path: record.path, .secure: "TRUE",
        ]
        if record.httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let expires = record.expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)
    }
}
